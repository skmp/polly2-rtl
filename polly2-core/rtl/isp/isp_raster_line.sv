//
// isp_raster_line - evaluate a LANES-pixel span of a scanline, PIPELINED, in
// ABSOLUTE SCREEN COORDINATES (0..2047), on the uniform *_spp_ro FP units.
//
// For screen pixel (x,y), x,y in 0..2047, sampled at the pixel EDGE (.0) or the
// pixel CENTRE (.5) per `half` (HALF_OFFSET.fpu_pixel_half_offset):
//    Xhs_n(x) = Cn + DXn*y - DYn*x        (n = 12,23,31,41)
//    inside_n = Xhs_n > 0 || (tl[n] && Xhs_n == 0)   (refsw2 top-left rule:
//               exactly-on-edge samples belong only to top-left edges; C is
//               EXACT, the rule lives here in the compare - a C bias cannot
//               survive the fp sums)
//    invW(x)  = c_invw + ddx*x + ddy*y
//
// WHAT CHANGED vs the tile-relative version:
//   * x/y are 11-bit ABSOLUTE screen coordinates, not 5-bit tile-local, so the
//     plane constants Cn / c_invw are anchored at the SCREEN origin and setup no
//     longer subtracts a per-tile origin. The caller forms the coordinate by
//     CONCATENATION - tile bases are 32-aligned, so {tile, offset} needs no adder.
//   * the coordinate reaches the multipliers as a FLOAT from coord_f32 (1 cycle),
//     which also folds in the +0.5 pixel-centre offset. The old path multiplied a
//     float by a 5-bit INTEGER (fp_mul_i5), which cannot express a half-pixel and
//     could not have addressed a 2048-wide range.
//   * every FP unit is now a uniform registered-output *_spp_ro: fp_mul16_spp_ro
//     (2 clk) for the products, fp_add24_spp_ro (4 clk) for the sums. The old
//     hand-split fp_add24_s1/fp_add24_s2 pair (2 clk) is gone.
//
// PRECISION NOTE (deliberate, per the rework decision): fp_mul16 truncates its
// multiplicands to 16-bit significands. A coordinate up to 2047.5 needs 12 of
// those bits, so the coordinate operand carries ~4 bits of slack at the top of the
// range - far less than the tile-local 0..31 form had. The top-left rule's
// exactness does NOT depend on the product (it lives in the fp_ge compare against a
// next_down'd line base), but coverage of near-degenerate edges at large screen
// coordinates is more sensitive than before. raster_topleft_tb is the guard.
//
// Pipeline (in_valid -> out_valid after LAT+1 cycles):
//   c   : coord_f32: x,y (+half) -> float                          (1 clk)
//   s1  : DXn*y, ddy*y                          fp_mul16_spp_ro    (2 clk)
//   s2  : ebase = Cn + DXn*y ; wbase = c_invw + ddy*y
//                                               fp_add24_spp_ro    (4 clk)
//   f   : top-left fold, next_down(ebase) on non-top-left edges    (1 clk)
//   s3  : DYn*x, ddx*x                          fp_mul16_spp_ro    (2 clk)
//   s4  : edge ordering cmp ebase>=DY*x         fp_ge              (1 clk)
//         invW = wbase + ddx*x                  fp_add24_spp_ro    (4 clk)
// The edge bits land 3 cycles before invW, so they are delayed to meet it (EDGEDLY).
//
// Numerics per spec: the edge inside tests need only the SIGN of ebase - DY*x, and
// the sign of a float subtract is exactly the ordering predicate, so they are fp_ge
// magnitude compares - bit-exact vs an fp_add24 sub (incl. +0 on exact cancellation,
// which is only reachable at shamt==0, and the underflow flush keeping s_big).
//
// SHIFT-REGISTER RAM INFERENCE MUST BE OFF HERE. The operand-alignment delay chains
// below (xf_dl, dy*_d, ddx_d, probe_d, tl_dl, eb*_m, ge_dl) are uniform-depth shift
// registers, which Quartus happily converts into altshift_taps backed by M10K. That is
// exactly wrong for these: they sit BETWEEN pipeline stages on the datapath, so a RAM
// access lands on the critical path, and they spend block RAM (11 M10K in this module
// alone, including one per fp_ge instance) in a design already at 98% M10K.
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
module isp_raster_line #(
    parameter integer LANES = 8
) (
    input             clk,
    input             reset,
    input             in_valid,
    input      [10:0] y,           // ABSOLUTE screen row  (tile base | tile offset)
    input      [10:0] x_base,      // ABSOLUTE screen col of lane 0, LANES-aligned
    input             half,        // 0 = sample pixel edge, 1 = pixel centre (+0.5)

    input      [31:0] c1,c2,c3,c4,
    input      [31:0] dx12,dx23,dx31,dx41,
    input      [31:0] dy12,dy23,dy31,dy41,
    input      [31:0] ddx,ddy,c_invw,
    input      [3:0]  tl,           // {tl41,tl31,tl23,tl12} IsTopLeft per edge

    // ---- CORNER-PROBE mode (the "257th step"): trivial per-tile reject, REUSING this
    // pipeline's adders/multipliers (no duplicate FP hw). When `probe` is asserted with
    // `in_valid`, the coordinate muxes feed each edge ITS OWN max corner instead of the
    // chunk grid: Xhs_n is affine, so the tile max is at y*=(DXn>=0?tile_hi:tile_lo) and
    // x*=(DYn<=0?tile_hi:tile_lo). If any edge's max-corner Xhs_n < 0, the whole 32x32
    // tile is outside that edge -> reject. In ABSOLUTE coordinates the tile corners come
    // from the issued coordinate itself: the tile is 32-aligned, so its rows span
    // {y[10:5],5'd0} .. {y[10:5],5'd31} and likewise for x - no extra port needed.
    // `probe_reject` is valid together with out_valid (same LAT) for a probe issue.
    input             probe,
    output reg               probe_reject,   // reject verdict (valid when probe_valid)
    output reg               probe_valid,    // 1-cyc: a probe issue's verdict is on the bus

    output reg               out_valid,
    output reg [LANES-1:0]    inside_mask,
    output reg [32*LANES-1:0] invw_flat,
    // echo of this chunk's coords (aligned with out_valid) so a streaming consumer can
    // address the depth/tag buffer for the results as they emerge, back-to-back,
    // without stalling the issue side. These stay TILE-LOCAL (5 bit): they address the
    // per-tile buffers, whatever coordinate space the SAMPLING uses.
    // per-issue sideband index: rides the pipe with x/y so a chaining consumer can look
    // up the owning triangle's identity (tag/mode) at exit time even when several
    // triangles' chunks are in flight back-to-back. Widened to 3 bits with the deeper
    // pipe (see peel_core: the slot count must exceed the pipe depth / min issue gap).
    input      [2:0]          qi,
    output reg [2:0]          out_qi,
    output reg [4:0]          out_x,
    output reg [4:0]          out_y
);
    // stage latencies of the uniform FP units
    localparam integer L_CONV = 1;   // coord_f32
    localparam integer L_MUL  = 2;   // fp_mul16_spp_ro
    localparam integer L_ADD  = 4;   // fp_add24_spp_ro
    localparam integer L_GE   = 1;   // fp_ge
    localparam integer L_FOLD = 1;   // the top-left next_down register
    // issue -> im0/iw0 INCLUSIVE: conv + mul + add + fold + mul + add + the im0/iw0
    // register itself. That last +1 is not bookkeeping: `inside_mask <= im0` in the
    // output stage samples im0 one cycle BEFORE it presents, so LAT must count the im0
    // register or the mask lands against the NEXT chunk's out_x/out_y (per-chunk
    // horizontal smearing). The old tile-local LAT=6 counted its s4b register the same
    // way. The edge path reaches the same depth: conv+mul+add+fold+mul+ge+EDGEDLY+1.
    localparam integer LAT     = L_CONV + L_MUL + L_ADD + L_FOLD + L_MUL + L_ADD + 1;  // 15
    // the edge path is shorter than the invW path (fp_ge vs fp_add24_spp_ro)
    localparam integer EDGEDLY = L_ADD - L_GE;                                     // 3
    // tl is consumed at the fold, which sits on the s2 result
    localparam integer TLDLY   = L_CONV + L_MUL + L_ADD;                           // 7
    // x float / DY / ddx must arrive at the s3 issue point, i.e. after the fold
    localparam integer XDLY    = L_MUL + L_ADD + L_FOLD;                           // 7

    genvar gi;
    integer pp, lx;

    // ==================================================================
    // STAGE c: coordinate -> float. `half` folds the pixel-centre offset in.
    // Per-lane x is a CONCATENATION, not an add: x_base is LANES-aligned and the tile
    // base is 32-aligned, so lane gi's column is x_base | gi.
    // The probe needs the tile's corner rows/cols too, so y and x each get two extra
    // converters for the tile extremes; the per-edge witness select is then a float
    // mux (in the old integer-multiplicand form the witness was a 5-bit mux into
    // fp_mul_i5 - now it happens one stage earlier, on the converted value).
    // ==================================================================
    wire [10:0] y_lo = {y[10:5], 5'd0};        // tile's first row
    wire [10:0] y_hi = {y[10:5], 5'd31};       // tile's last row
    wire [10:0] x_lo = {x_base[10:5], 5'd0};   // tile's first column
    wire [10:0] x_hi = {x_base[10:5], 5'd31};  // tile's last column

    wire [31:0] yf, yf_lo, yf_hi;
    coord_f32 u_cy   (.clk(clk),.en(1'b1),.coord(y),   .half(half),.f(yf));
    coord_f32 u_cylo (.clk(clk),.en(1'b1),.coord(y_lo),.half(half),.f(yf_lo));
    coord_f32 u_cyhi (.clk(clk),.en(1'b1),.coord(y_hi),.half(half),.f(yf_hi));

    wire [31:0] xf [0:LANES-1];
    generate for (gi = 0; gi < LANES; gi = gi + 1) begin : cvx
        coord_f32 u_cx (.clk(clk),.en(1'b1),.coord(x_base | 11'(gi)),.half(half),.f(xf[gi]));
    end endgenerate
    wire [31:0] xf_lo, xf_hi;
    coord_f32 u_cxlo (.clk(clk),.en(1'b1),.coord(x_lo),.half(half),.f(xf_lo));
    coord_f32 u_cxhi (.clk(clk),.en(1'b1),.coord(x_hi),.half(half),.f(xf_hi));

`ifndef SYNTHESIS
    always @(posedge clk) if (!reset && in_valid && ((x_base % LANES) != 0))
        $error("isp_raster_line %m: x_base=%0d is not LANES(%0d)-aligned - the per-lane column concatenation is invalid",
               x_base, LANES);
`endif

    // The coefficients are stable across an issue, but the coordinate is now a
    // REGISTERED float, so the witness selects and the coefficient copies feeding s1
    // must align with it: delay `probe` and the coefficients by L_CONV.
    reg probe_c;
    always @(posedge clk) if (reset) probe_c <= 1'b0; else probe_c <= in_valid && probe;
    reg [31:0] dx12_c,dx23_c,dx31_c,dx41_c, dy12_c,dy23_c,dy31_c,dy41_c;
    reg [31:0] c1_c,c2_c,c3_c,c4_c, ddx_c,ddy_c,cinvw_c;
    always @(posedge clk) begin
        dx12_c<=dx12; dx23_c<=dx23; dx31_c<=dx31; dx41_c<=dx41;
        dy12_c<=dy12; dy23_c<=dy23; dy31_c<=dy31; dy41_c<=dy41;
        c1_c<=c1; c2_c<=c2; c3_c<=c3; c4_c<=c4;
        ddx_c<=ddx; ddy_c<=ddy; cinvw_c<=c_invw;
    end

    // per-edge y witness: the max corner is the tile's LAST row when DX >= 0, its
    // FIRST row when DX < 0 (same rule the tile-local form applied to y*=31 / y*=0).
    wire [31:0] y12 = probe_c ? (dx12_c[31] ? yf_lo : yf_hi) : yf;
    wire [31:0] y23 = probe_c ? (dx23_c[31] ? yf_lo : yf_hi) : yf;
    wire [31:0] y31 = probe_c ? (dx31_c[31] ? yf_lo : yf_hi) : yf;
    wire [31:0] y41 = probe_c ? (dx41_c[31] ? yf_lo : yf_hi) : yf;

    // ==================================================================
    // s1: DXn*y, ddy*y   (fp_mul16_spp_ro, 2 clk)
    // ==================================================================
    wire [31:0] dx12y,dx23y,dx31y,dx41y, ddyy;
    fp_mul16_spp_ro m_dx12y(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(dx12_c),.b(y12),.out_valid(),.y(dx12y));
    fp_mul16_spp_ro m_dx23y(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(dx23_c),.b(y23),.out_valid(),.y(dx23y));
    fp_mul16_spp_ro m_dx31y(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(dx31_c),.b(y31),.out_valid(),.y(dx31y));
    fp_mul16_spp_ro m_dx41y(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(dx41_c),.b(y41),.out_valid(),.y(dx41y));
    // invW never uses a probe witness - the probe only decides coverage.
    fp_mul16_spp_ro m_ddyy (.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(ddy_c), .b(yf), .out_valid(),.y(ddyy));

    // the C / c_invw operands meet the s1 results at s2: delay by L_MUL.
    reg [31:0] c1_1[0:L_MUL-1], c2_1[0:L_MUL-1], c3_1[0:L_MUL-1], c4_1[0:L_MUL-1], cw_1[0:L_MUL-1];
    always @(posedge clk) begin
        c1_1[0]<=c1_c; c2_1[0]<=c2_c; c3_1[0]<=c3_c; c4_1[0]<=c4_c; cw_1[0]<=cinvw_c;
        for (pp=1; pp<L_MUL; pp=pp+1) begin
            c1_1[pp]<=c1_1[pp-1]; c2_1[pp]<=c2_1[pp-1];
            c3_1[pp]<=c3_1[pp-1]; c4_1[pp]<=c4_1[pp-1]; cw_1[pp]<=cw_1[pp-1];
        end
    end

    // ==================================================================
    // s2: ebase = Cn + DXn*y ; wbase = c_invw + ddy*y   (fp_add24_spp_ro, 4 clk)
    // ==================================================================
    wire [31:0] eb1,eb2,eb3,eb4, wbase;
    fp_add24_spp_ro e1a(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(c1_1[L_MUL-1]),.b_in(dx12y),.sub(1'b0),.out_valid(),.y(eb1));
    fp_add24_spp_ro e2a(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(c2_1[L_MUL-1]),.b_in(dx23y),.sub(1'b0),.out_valid(),.y(eb2));
    fp_add24_spp_ro e3a(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(c3_1[L_MUL-1]),.b_in(dx31y),.sub(1'b0),.out_valid(),.y(eb3));
    fp_add24_spp_ro e4a(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(c4_1[L_MUL-1]),.b_in(dx41y),.sub(1'b0),.out_valid(),.y(eb4));
    fp_add24_spp_ro wba(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(cw_1[L_MUL-1]),.b_in(ddyy), .sub(1'b0),.out_valid(),.y(wbase));

    // ---- top-left rule folded into the LINE BASE, once per line per edge (NOT per
    // lane): for finite floats  a > b  <=>  next_down(a) >= b  (exactly), so a
    // non-top-left edge gets its base stepped one float toward -inf and the per-lane
    // fp_ge stays the plain inclusive compare. (A bias on C itself cannot work: it
    // washes out of C + DX*y depending on per-pixel exponent alignment, and a raw C-1
    // wrapped C=+0 to -NaN, dropping every tile whose origin lies exactly on the edge.)
    // next_down(+-0) is the smallest negative DENORMAL: fp_ge is a pure ordering
    // compare, so it orders denormals correctly even though the adders flush them.
    function [31:0] fdown(input [31:0] f);
        fdown = (f[30:0] == 31'd0) ? 32'h80000001
              : f[31] ? (f + 32'd1) : (f - 32'd1);
    endfunction
    // tl must ride the pipe to HERE, else a back-to-back triangle chain (the consumer
    // re-latches its inputs 1 cycle after the last issue) corrupts the in-flight
    // chunk's top-left rule (exact-on-edge pixels flip).
    reg [3:0] tl_dl [0:TLDLY-1];
    always @(posedge clk) begin
        tl_dl[0] <= tl;
        for (pp=1; pp<TLDLY; pp=pp+1) tl_dl[pp] <= tl_dl[pp-1];
    end
    wire [3:0] tl_s2 = tl_dl[TLDLY-1];
    reg [31:0] eb1_3,eb2_3,eb3_3,eb4_3, wbase_3;
    always @(posedge clk) begin
        eb1_3<=tl_s2[0]?eb1:fdown(eb1); eb2_3<=tl_s2[1]?eb2:fdown(eb2);
        eb3_3<=tl_s2[2]?eb3:fdown(eb3); eb4_3<=tl_s2[3]?eb4:fdown(eb4);
        wbase_3<=wbase;
    end

    // ---- per-lane x float + the DY/ddx coefficients, delayed to the s3 issue point
    //      (past the s1 mul, the s2 add and the fold), so DY*x meets the folded line
    //      base at s4. The two tile-extreme x floats ride along for the probe. ----
    reg [31:0] xf_dl [0:LANES-1][0:XDLY-1];
    reg [31:0] xlo_dl [0:XDLY-1], xhi_dl [0:XDLY-1];
    reg [31:0] dy12_d[0:XDLY-1], dy23_d[0:XDLY-1], dy31_d[0:XDLY-1], dy41_d[0:XDLY-1];
    reg [31:0] ddx_d [0:XDLY-1];
    reg        probe_d[0:XDLY-1];
    always @(posedge clk) begin
        for (lx=0; lx<LANES; lx=lx+1) xf_dl[lx][0] <= xf[lx];
        xlo_dl[0]<=xf_lo; xhi_dl[0]<=xf_hi;
        dy12_d[0]<=dy12_c; dy23_d[0]<=dy23_c; dy31_d[0]<=dy31_c; dy41_d[0]<=dy41_c;
        ddx_d[0]<=ddx_c;   probe_d[0]<=probe_c;
        for (pp=1; pp<XDLY; pp=pp+1) begin
            for (lx=0; lx<LANES; lx=lx+1) xf_dl[lx][pp] <= xf_dl[lx][pp-1];
            xlo_dl[pp]<=xlo_dl[pp-1]; xhi_dl[pp]<=xhi_dl[pp-1];
            dy12_d[pp]<=dy12_d[pp-1]; dy23_d[pp]<=dy23_d[pp-1];
            dy31_d[pp]<=dy31_d[pp-1]; dy41_d[pp]<=dy41_d[pp-1];
            ddx_d[pp]<=ddx_d[pp-1];   probe_d[pp]<=probe_d[pp-1];
        end
    end
    wire [31:0] dy12_s = dy12_d[XDLY-1], dy23_s = dy23_d[XDLY-1];
    wire [31:0] dy31_s = dy31_d[XDLY-1], dy41_s = dy41_d[XDLY-1];
    wire [31:0] ddx_s  = ddx_d[XDLY-1];
    wire        probe_s= probe_d[XDLY-1];

    reg [LANES-1:0]    im0;
    reg [32*LANES-1:0] iw0;
    reg                pr_rej0;

    generate
      for (gi = 0; gi < LANES; gi = gi + 1) begin : px
        wire [31:0] xg = xf_dl[gi][XDLY-1];
        // PROBE: only LANE 0's compares are consumed (probe_lane below), so only lane 0
        // pays for the per-edge witness mux. Each edge takes its own x max corner: Xhs =
        // Cn+DXn*y-DYn*x, so -DYn*x is maximized at the tile's LAST column when DYn < 0
        // and at its FIRST column otherwise. (The other lanes' results are discarded on
        // a probe issue - out_valid is suppressed for it.)
        wire [31:0] xk12, xk23, xk31, xk41;
        if (gi == 0) begin : wit
            assign xk12 = probe_s ? (dy12_s[31] ? xhi_dl[XDLY-1] : xlo_dl[XDLY-1]) : xg;
            assign xk23 = probe_s ? (dy23_s[31] ? xhi_dl[XDLY-1] : xlo_dl[XDLY-1]) : xg;
            assign xk31 = probe_s ? (dy31_s[31] ? xhi_dl[XDLY-1] : xlo_dl[XDLY-1]) : xg;
            assign xk41 = probe_s ? (dy41_s[31] ? xhi_dl[XDLY-1] : xlo_dl[XDLY-1]) : xg;
        end else begin : nowit
            assign xk12 = xg; assign xk23 = xg; assign xk31 = xg; assign xk41 = xg;
        end

        // ---- s3: DYn*x, ddx*x  (fp_mul16_spp_ro, 2 clk) ----
        wire [31:0] dy12x,dy23x,dy31x,dy41x, ddxx;
        fp_mul16_spp_ro mdy12(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(dy12_s),.b(xk12),.out_valid(),.y(dy12x));
        fp_mul16_spp_ro mdy23(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(dy23_s),.b(xk23),.out_valid(),.y(dy23x));
        fp_mul16_spp_ro mdy31(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(dy31_s),.b(xk31),.out_valid(),.y(dy31x));
        fp_mul16_spp_ro mdy41(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(dy41_s),.b(xk41),.out_valid(),.y(dy41x));
        fp_mul16_spp_ro mddx (.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),.a(ddx_s), .b(xg),  .out_valid(),.y(ddxx));

        // the folded line bases meet the s3 products at s4: delay by L_MUL. These are
        // line-base values (independent of the lane), but the delay registers live per
        // lane so the fanout to LANES compare inputs is broken up.
        reg [31:0] eb1_m[0:L_MUL-1], eb2_m[0:L_MUL-1], eb3_m[0:L_MUL-1], eb4_m[0:L_MUL-1];
        reg [31:0] wb_m [0:L_MUL-1];
        integer q;
        always @(posedge clk) begin
            eb1_m[0]<=eb1_3; eb2_m[0]<=eb2_3; eb3_m[0]<=eb3_3; eb4_m[0]<=eb4_3; wb_m[0]<=wbase_3;
            for (q=1; q<L_MUL; q=q+1) begin
                eb1_m[q]<=eb1_m[q-1]; eb2_m[q]<=eb2_m[q-1];
                eb3_m[q]<=eb3_m[q-1]; eb4_m[q]<=eb4_m[q-1]; wb_m[q]<=wb_m[q-1];
            end
        end

        // ---- s4: edge ordering compares (fp_ge, 1 clk) + invW sum (fp_add24, 4 clk) ----
        wire ge1,ge2,ge3,ge4;
        fp_ge cmp1(.clk(clk),.a(eb1_m[L_MUL-1]),.b(dy12x),.ge(ge1));
        fp_ge cmp2(.clk(clk),.a(eb2_m[L_MUL-1]),.b(dy23x),.ge(ge2));
        fp_ge cmp3(.clk(clk),.a(eb3_m[L_MUL-1]),.b(dy31x),.ge(ge3));
        fp_ge cmp4(.clk(clk),.a(eb4_m[L_MUL-1]),.b(dy41x),.ge(ge4));
        wire [31:0] iw;
        fp_add24_spp_ro iwa(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),
                            .a(wb_m[L_MUL-1]),.b_in(ddxx),.sub(1'b0),.out_valid(),.y(iw));

        // the edge bits are ready EDGEDLY cycles before invW - delay them to meet it.
        reg [3:0] ge_dl [0:EDGEDLY-1];
        integer g;
        always @(posedge clk) begin
            ge_dl[0] <= {ge4,ge3,ge2,ge1};
            for (g=1; g<EDGEDLY; g=g+1) ge_dl[g] <= ge_dl[g-1];
        end
        wire [3:0] gev = ge_dl[EDGEDLY-1];

        always @(posedge clk) begin
            im0[gi] <= &gev;
            iw0[32*gi +: 32] <= iw;
        end
        // PROBE: lane 0's compares test the 4 edges at their tile-MAX corners. Reject if
        // ANY edge's max corner is strictly outside (the whole tile is then outside it).
        if (gi == 0) begin : probe_lane
            always @(posedge clk) pr_rej0 <= ~(&gev);
        end
      end
    endgenerate

    // ---- valid / sideband pipe. x and y are echoed TILE-LOCAL (the tile buffers are
    //      addressed per tile), so only the low 5 bits travel. ----
    reg [LAT-1:0] vpipe;
    reg [LAT-1:0] ppipe;   // probe flag, LAT-deep (aligned with vpipe)
    reg [4:0] xpipe [0:LAT-1];
    reg [4:0] ypipe [0:LAT-1];
    reg [2:0] qpipe [0:LAT-1];
    always @(posedge clk) begin
        if (reset) begin vpipe <= '0; ppipe <= '0; end
        else begin
            vpipe <= {vpipe[LAT-2:0], in_valid};
            ppipe <= {ppipe[LAT-2:0], (in_valid && probe)};
        end
        xpipe[0] <= x_base[4:0]; ypipe[0] <= y[4:0]; qpipe[0] <= qi;
        for (pp = 1; pp < LAT; pp = pp + 1) begin
            xpipe[pp] <= xpipe[pp-1]; ypipe[pp] <= ypipe[pp-1];
            qpipe[pp] <= qpipe[pp-1];
        end
    end

    // Final output register: re-time inside_mask/invw_flat here so they land on the
    // SAME cycle as out_valid/out_x/out_y.
    always @(posedge clk) begin
        // A PROBE issue must NOT look like a real rastered chunk to the consumer:
        // suppress out_valid on probe cycles so no stage-B write / inflight accounting
        // fires for it. Only probe_reject carries the probe result.
        out_valid    <= vpipe[LAT-1] & ~ppipe[LAT-1];
        out_x        <= xpipe[LAT-1];
        out_y        <= ypipe[LAT-1];
        out_qi       <= qpipe[LAT-1];
        inside_mask  <= im0;
        invw_flat    <= iw0;
        // probe_reject/probe_valid align with the (suppressed) out_valid slot;
        // probe_valid marks the cycle a probe issue's verdict is on the bus.
        probe_valid  <= ppipe[LAT-1];
        probe_reject <= pr_rej0 & ppipe[LAT-1];
    end
endmodule

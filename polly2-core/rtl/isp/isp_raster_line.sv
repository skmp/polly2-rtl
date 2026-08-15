//
// isp_raster_line - evaluate a LANES-pixel span of a scanline, PIPELINED, in
// ABSOLUTE SCREEN COORDINATES (0..2047).
//
// For screen pixel (x,y), x,y in 0..2047, sampled at the pixel EDGE (.0) or the
// pixel CENTRE (.5) per `half` (HALF_OFFSET.fpu_pixel_half_offset):
//    Xhs_n(x) = Cn + DXn*y - DYn*x        (n = 12,23,31,41)
//    inside_n = Xhs_n > 0 || (tl[n] && Xhs_n == 0)   (refsw2 top-left rule)
//    invW(x)  = c_invw + ddx*x + ddy*y
//
// ============================================================================
// SHARED-EXPONENT FIXED POINT (replaces the per-lane FP datapath)
// ============================================================================
// The lane expansion is no longer floating point. Per issue, each channel is
// reduced to a BASE and a STEP at a shared exponent, and the LANES lane values
// are produced by a doubling tree of plain two's-complement adders:
//
//    V(lane) = base + step*lane      lane = 0 .. LANES-1
//
// so there are no per-lane multiplies, no per-lane FP alignment, and (for the
// edges) no per-lane compare - just the sign of an integer.
//
// WHAT FEEDS THE TREE. The row term AND the column origin are folded into the
// base by ONE fused 3-input FP add per channel:
//
//    base_n = Cn + DXn*y + (-DYn*x_base)      step_n = -DYn
//    base_w = c_invw + ddy*y + ddx*x_base     step_w = +ddx
//
// Folding -DYn*x_base in is what makes the absolute-coordinate form affordable:
// the lane offset that remains is 0..LANES-1, so the shared exponent needs only
// HEAD = log2(LANES) bits of headroom instead of the 11 an absolute x would
// demand. It costs one extra multiply per channel per issue (shared by every
// lane) and nothing per lane.
//
// THE SHARED EXPONENT is an upper bound, not a normalization:
//    E = max(expof(base), expof(step))
// and both operands are aligned into a two's-complement field whose MSB for an
// E-exponent value sits at bit MSBP, leaving HEAD bits of growth for the sum of
// LANES terms and (FXW-2-HEAD-24) guard bits below the significand. A value
// more than that many binades below E flushes to zero (the shift amount is
// saturated - the difference is unbounded below and would otherwise wrap into
// the MSBs).
//
// ALIGNMENT TRUNCATES THE MAGNITUDE, TOWARD ZERO - this is load-bearing, not a
// detail. Watertightness across a shared edge depends on the two triangles'
// coefficients being exact negations of each other: with C,DX,DY negated, the
// fused add (sign-magnitude, truncating) yields exactly -base, the exponents are
// identical so E is identical, and truncating the MAGNITUDE gives exactly
// -align(x). The fixed-point tree is exact, so V_B(lane) == -V_A(lane) for every
// lane, and the top-left rule below then awards an exactly-on-edge sample to
// exactly one of the two. An arithmetic (floor) shift, or the round-to-nearest
// bias that a "+0.5 ULP round bit" would inject, breaks that antisymmetry and
// with it every shared edge in the scene: floor turns a strictly-inside sample
// into a tie on one side and an outside on the other, which is a CRACK.
//
// THE TOP-LEFT RULE IS NOW DIRECT. In FP this module could not test "> 0"
// cheaply, so a non-top-left edge had its line base stepped one float toward
// -inf (next_down) and the per-lane compare stayed inclusive. In fixed point the
// sign and the zero of V are both to hand, so the rule is written as it reads:
//      inside_n = tl[n] ? (V_n >= 0) : (V_n > 0)
// and next_down/fdown is gone. A degenerate row (base == step == 0) still gives
// inside = tl[n], exactly as the folded form did.
//
// DEPTH KEEPS ITS CONVENTIONS. invW is normalized back to f32 on the way out
// (leading-one search + shift + exponent), because every consumer - the peel
// compare, the tile buffers, the span ring, the shade RCP - takes a float and
// relies on positive floats ordering like unsigned ints. Only the four edge
// channels skip normalization, and they only ever needed a sign. invW's sign is
// stripped downstream (peel_core drop_sign) exactly as before.
//
// PRECISION vs THE OLD PATH. Strictly better, and different. The products were
// fp_mul24 - 24-bit significands - and a coordinate up to 2047.5 already spent
// 12 of those bits; the fixed-point form carries the full 24-bit significands of
// the folded base and the step. Expect small coverage changes on near-degenerate
// edges and small invW changes: this is a re-baseline, not a bit-exact rework.
//
// COST. At LANES=32 the old form was 160 fp_mul16 + 128 fp_ge + 32 fp_add24.
// This is 10 fp_mul24 + 5 fp_add3_24 + 155 FXW-bit adders + 32 normalizers,
// which is what makes a full 32-pixel tile row per clock affordable at all.
//
// NEXT LEVER (not taken here): V(lane) is monotonic in lane because step is
// constant, so every edge's inside_mask is a contiguous run and the 31 adders
// could collapse to a crossing-point search. That trades the tree for a divide.
//
// SHIFT-REGISTER RAM INFERENCE MUST BE OFF HERE. The operand-alignment delay
// chains are uniform-depth shift registers, which Quartus happily converts into
// altshift_taps backed by M10K. That is exactly wrong for these: they sit
// BETWEEN pipeline stages on the datapath, so a RAM access lands on the critical
// path, in a design already tight on M10K.
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
module isp_raster_line import tsp_pkg::*; #(
    parameter integer LANES = 32,
    // Fixed-point field width. Must hold sign + HEAD growth bits + a 24-bit
    // significand; everything beyond that is guard precision for a step whose
    // exponent is below the base's.
    parameter integer FXW   = 48
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
    // The witness now enters at the COLUMN FOLD (one multiply per edge, shared by the
    // lanes) instead of at a per-lane multiply, so lane 0's value IS the probe value:
    // V_n(0) == base_n == Xhs_n at that edge's max corner. The verdict therefore comes
    // out of the same compare the raster uses - probe and sweep cannot disagree.
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
    // triangles' chunks are in flight back-to-back.
    input      [2:0]          qi,
    output reg [2:0]          out_qi,
    output reg [4:0]          out_x,
    output reg [4:0]          out_y
);
    // ---- channel numbering: 0..3 = edges 12/23/31/41, 4 = invW ----
    localparam integer NCH  = 5;
    localparam integer WCH  = 4;                 // the invW channel's index

    // ---- fixed-point geometry ----
    localparam integer HEAD = $clog2(LANES);     // growth bits: sum of LANES terms
    localparam integer MSBP = FXW - 2 - HEAD;    // bit index of an E-exponent MSB
    localparam integer SHL  = MSBP - 23;         // significand placement shift

    // ---- stage latencies ----
    localparam integer L_CONV = 1;   // coord_f32
    localparam integer L_MUL  = 2;   // fp_mul24_spp_ro
    localparam integer L_ADD3 = 4;   // fp_add3_24_spp_ro (fused C + DX*y - DY*x)
    localparam integer L_ALGN = 1;   // exponent max + the two alignment shifts
    localparam integer NST    = (HEAD + 1) / 2;   // tree stages: two levels each
    // issue -> im0/iw0 INCLUSIVE. That last +1 is not bookkeeping: `inside_mask <= im0`
    // in the output stage samples im0 one cycle BEFORE it presents, so LAT must count
    // the im0 register or the mask lands against the NEXT chunk's out_x/out_y.
    // EXPORTED via tsp_pkg::isp_raster_lat() so peel_core's corner-probe countdown
    // (CR_LAT) tracks this pipe instead of hardcoding its depth. The local stage
    // constants above are the documentation; the function is the contract.
    localparam integer LAT    = isp_raster_lat(LANES);
`ifndef SYNTHESIS
    initial if (LAT != L_CONV + L_MUL + L_ADD3 + L_ALGN + NST + 1)
        $fatal(1, "isp_raster_line: tsp_pkg::isp_raster_lat(%0d)=%0d disagrees with the pipe (%0d)",
               LANES, LAT, L_CONV + L_MUL + L_ADD3 + L_ALGN + NST + 1);
`endif
    // the step coefficient is consumed at the align stage
    localparam integer STPDLY = L_MUL + L_ADD3;
    // tl is consumed combinationally at the im0 register, i.e. one cycle before it
    localparam integer TLDLY  = LAT - 1;

    genvar gi, gc, gs;
    integer pp, n, j;

    // ==================================================================
    // Alignment / normalization primitives
    // ==================================================================

    // Align a float to the shared exponent E. TRUNCATES THE MAGNITUDE (round toward
    // zero) so align(-x) == -align(x) exactly - see the header: shared-edge
    // watertightness rests on it. DaZ, matching the FP units.
    function automatic signed [FXW-1:0] align_fx(input [31:0] f, input [7:0] E);
        reg [7:0]     e;
        reg [FXW-1:0] mag;
        reg [8:0]     sh;
        begin
            e   = f[30:23];
            sh  = {1'b0, E} - {1'b0, e};        // E is the max, so never negative
            if (e == 8'd0 || sh > 9'(FXW-1)) mag = {FXW{1'b0}};
            else mag = (FXW'({1'b1, f[22:0]}) << SHL) >> sh[5:0];
            align_fx = f[31] ? -$signed(mag) : $signed(mag);
        end
    endfunction

    // Normalize a fixed-point lane value back to f32 at shared exponent E.
    // Underflow flushes to zero and overflow saturates, as the FP units do.
    function automatic [31:0] fx_to_f32(input signed [FXW-1:0] v, input [7:0] E);
        reg [FXW-1:0] mag;
        reg           s;
        reg [23:0]    m;
        integer       p, i, ex;
        begin
            s   = v[FXW-1];
            mag = s ? FXW'(-v) : FXW'(v);
            p   = -1;
            for (i = 0; i < FXW-1; i = i + 1) if (mag[i]) p = i;
            ex  = E + p - MSBP;
            if (p < 0 || ex <= 0)  fx_to_f32 = 32'd0;
            else if (ex > 255)     fx_to_f32 = {s, 8'hFF, 23'h7FFFFF};
            else begin
                m = (p >= 23) ? FXW'(mag >> (p - 23)) : FXW'(mag << (23 - p));
                fx_to_f32 = {s, ex[7:0], m[22:0]};
            end
        end
    endfunction

    function automatic [7:0] emax(input [31:0] a, input [31:0] b);
        emax = (a[30:23] > b[30:23]) ? a[30:23] : b[30:23];
    endfunction

    // negate a float (exact): the step for an edge is -DYn
    function automatic [31:0] fneg(input [31:0] f);
        fneg = {~f[31], f[30:0]};
    endfunction

    // ==================================================================
    // STAGE c: coordinate -> float. `half` folds the pixel-centre offset in.
    // Only SIX converters now (was LANES+4): the lane offset never reaches a
    // multiplier, so no per-lane x float is needed - just the chunk origin and
    // the tile extremes the probe witnesses use.
    // ==================================================================
    wire [10:0] y_lo = {y[10:5], 5'd0};        // tile's first row
    wire [10:0] y_hi = {y[10:5], 5'd31};       // tile's last row
    wire [10:0] x_lo = {x_base[10:5], 5'd0};   // tile's first column
    wire [10:0] x_hi = {x_base[10:5], 5'd31};  // tile's last column

    wire [31:0] yf, yf_lo, yf_hi, xf_b, xf_lo, xf_hi;
    coord_f32 u_cy   (.clk(clk),.en(1'b1),.coord(y),     .half(half),.f(yf));
    coord_f32 u_cylo (.clk(clk),.en(1'b1),.coord(y_lo),  .half(half),.f(yf_lo));
    coord_f32 u_cyhi (.clk(clk),.en(1'b1),.coord(y_hi),  .half(half),.f(yf_hi));
    coord_f32 u_cxb  (.clk(clk),.en(1'b1),.coord(x_base),.half(half),.f(xf_b));
    coord_f32 u_cxlo (.clk(clk),.en(1'b1),.coord(x_lo),  .half(half),.f(xf_lo));
    coord_f32 u_cxhi (.clk(clk),.en(1'b1),.coord(x_hi),  .half(half),.f(xf_hi));

`ifndef SYNTHESIS
    always @(posedge clk) if (!reset && in_valid && ((x_base % LANES) != 0))
        $error("isp_raster_line %m: x_base=%0d is not LANES(%0d)-aligned - the lane column concatenation is invalid",
               x_base, LANES);
`endif

    // The coefficients are stable across an issue, but the coordinate is now a
    // REGISTERED float, so the witness selects and the coefficient copies feeding s1
    // must align with it: delay `probe` and the coefficients by L_CONV.
    reg probe_c;
    always @(posedge clk) if (reset) probe_c <= 1'b0; else probe_c <= in_valid && probe;
    reg [31:0] dxc [0:3], dyc [0:3], cc [0:3];
    reg [31:0] ddx_c, ddy_c, cinvw_c;
    always @(posedge clk) begin
        dxc[0]<=dx12; dxc[1]<=dx23; dxc[2]<=dx31; dxc[3]<=dx41;
        dyc[0]<=dy12; dyc[1]<=dy23; dyc[2]<=dy31; dyc[3]<=dy41;
        cc [0]<=c1;   cc [1]<=c2;   cc [2]<=c3;   cc [3]<=c4;
        ddx_c<=ddx;   ddy_c<=ddy;   cinvw_c<=c_invw;
    end

    // ==================================================================
    // s1: the row product and the COLUMN-ORIGIN product, per channel (10 muls).
    //   edges : DXn*y_witness , DYn*x_witness
    //   invW  : ddy*y , ddx*x_base
    // Probe witnesses: y* = (DXn < 0) ? tile_lo : tile_hi ; x* = (DYn < 0) ? hi : lo.
    // ==================================================================
    wire [31:0] p_row [0:NCH-1];   // DXn*y  / ddy*y
    wire [31:0] p_col [0:NCH-1];   // DYn*x  / ddx*x

    generate
      for (gc = 0; gc < 4; gc = gc + 1) begin : emul
        wire [31:0] yw = probe_c ? (dxc[gc][31] ? yf_lo : yf_hi) : yf;
        wire [31:0] xw = probe_c ? (dyc[gc][31] ? xf_hi : xf_lo) : xf_b;
        fp_mul24_spp_ro m_r(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),
                            .a(dxc[gc]),.b(yw),.out_valid(),.y(p_row[gc]));
        fp_mul24_spp_ro m_c(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),
                            .a(dyc[gc]),.b(xw),.out_valid(),.y(p_col[gc]));
      end
    endgenerate
    // invW never uses a probe witness - the probe only decides coverage.
    fp_mul24_spp_ro m_wr(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),
                         .a(ddy_c),.b(yf),  .out_valid(),.y(p_row[WCH]));
    fp_mul24_spp_ro m_wc(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),
                         .a(ddx_c),.b(xf_b),.out_valid(),      .y(p_col[WCH]));

    // the C / c_invw operands meet the s1 products at the fused add: delay by L_MUL.
    reg [31:0] c_d [0:NCH-1][0:L_MUL-1];
    always @(posedge clk) begin
        for (n = 0; n < 4; n = n + 1) c_d[n][0] <= cc[n];
        c_d[WCH][0] <= cinvw_c;
        for (n = 0; n < NCH; n = n + 1)
            for (pp = 1; pp < L_MUL; pp = pp + 1) c_d[n][pp] <= c_d[n][pp-1];
    end

    // ==================================================================
    // s2: ONE fused 3-input add per channel folds the row term AND the column
    // origin into the base (4 clk):
    //     edges : base = Cn + DXn*y + (-DYn*x)      (the negation is a sign flip,
    //     invW  : base = c_invw + ddy*y + ddx*x      exact, so the fused add's
    //                                                sign-magnitude symmetry holds)
    // ==================================================================
    wire [31:0] base_f [0:NCH-1];
    generate
      for (gc = 0; gc < NCH; gc = gc + 1) begin : fold
        wire [31:0] third = (gc == WCH) ? p_col[gc] : fneg(p_col[gc]);
        fp_add3_24_spp_ro u_a(.clk(clk),.reset(reset),.stall(1'b0),.in_valid(1'b1),
                              .a(c_d[gc][L_MUL-1]),.b(p_row[gc]),.c(third),
                              .out_valid(),.y(base_f[gc]));
      end
    endgenerate

    // the STEP coefficient (-DYn / +ddx) must reach the align stage with its base
    reg [31:0] stp_d [0:NCH-1][0:STPDLY-1];
    always @(posedge clk) begin
        for (n = 0; n < 4; n = n + 1) stp_d[n][0] <= fneg(dyc[n]);
        stp_d[WCH][0] <= ddx_c;
        for (n = 0; n < NCH; n = n + 1)
            for (pp = 1; pp < STPDLY; pp = pp + 1) stp_d[n][pp] <= stp_d[n][pp-1];
    end

    // ==================================================================
    // s3: shared exponent + alignment. One exponent compare and two shifts per
    // channel, per ISSUE - this is the whole "setup" cost of the fixed-point form.
    // ==================================================================
    (* ramstyle = "logic" *) reg signed [FXW-1:0] al_base [0:NCH-1];
    (* ramstyle = "logic" *) reg signed [FXW-1:0] al_step [0:NCH-1];
    (* ramstyle = "logic" *) reg        [7:0]     al_e    [0:NCH-1];
    always @(posedge clk) begin : align_stage
        reg [7:0] E;
        for (n = 0; n < NCH; n = n + 1) begin
            E          = emax(base_f[n], stp_d[n][STPDLY-1]);
            al_e[n]    <= E;
            al_base[n] <= align_fx(base_f[n],            E);
            al_step[n] <= align_fx(stp_d[n][STPDLY-1],   E);
        end
    end

    // ==================================================================
    // s4..: the doubling tree. Stage s covers levels 2s and 2s+1, so lanes
    // 0 .. 4^(s+1)-1 are live after it; the shifts are hardwired.
    //   level L:  V[j + 2^L] = V[j] + (step << L),  j < 2^L
    // Only the lanes a stage actually produces are registered (the rest of each
    // array has no driver and disappears), which is why the cuts land where they
    // do: registering all LANES at every level would cost several thousand flops
    // for values that do not exist yet.
    // ==================================================================
    (* ramstyle = "logic" *) reg signed [FXW-1:0] tv   [0:NST-1][0:NCH-1][0:LANES-1];
    (* ramstyle = "logic" *) reg signed [FXW-1:0] tstp [0:NST-1][0:NCH-1];
    (* ramstyle = "logic" *) reg        [7:0]     tex  [0:NST-1][0:NCH-1];

    generate
      for (gs = 0; gs < NST; gs = gs + 1) begin : tstage
        localparam integer LV   = 2*gs;
        localparam integer NIN  = ((1<<LV)     > LANES) ? LANES : (1<<LV);
        localparam integer NMID = ((1<<(LV+1)) > LANES) ? LANES : (1<<(LV+1));
        localparam integer NOUT = ((1<<(LV+2)) > LANES) ? LANES : (1<<(LV+2));
        for (gc = 0; gc < NCH; gc = gc + 1) begin : tch
          always @(posedge clk) begin : tree
            reg signed [FXW-1:0] cur [0:LANES-1];
            reg signed [FXW-1:0] mid [0:LANES-1];
            reg signed [FXW-1:0] stp;
            integer k;
            stp = (gs == 0) ? al_step[gc] : tstp[gs-1][gc];
            for (k = 0; k < NIN; k = k + 1)
                cur[k] = (gs == 0) ? al_base[gc] : tv[gs-1][gc][k];
            // level LV
            for (k = 0; k < NIN; k = k + 1) begin
                mid[k] = cur[k];
                if (NIN + k < NMID) mid[NIN + k] = cur[k] + (stp <<< LV);
            end
            // level LV+1 (absent when the stage already produced every lane)
            for (k = 0; k < NMID; k = k + 1) begin
                tv[gs][gc][k] <= mid[k];
                if (NMID + k < NOUT) tv[gs][gc][NMID + k] <= mid[k] + (stp <<< (LV+1));
            end
            tstp[gs][gc] <= stp;
            tex [gs][gc] <= (gs == 0) ? al_e[gc] : tex[gs-1][gc];
          end
        end
      end
    endgenerate

    // ==================================================================
    // Result stage: the edges need only a sign and a zero, invW gets normalized.
    // Both land in one register, so the two paths stay co-aligned (the old form
    // needed EDGEDLY to hold the edge bits back for the slower invW adder).
    // ==================================================================
    reg [3:0] tl_dl [0:TLDLY-1];
    always @(posedge clk) begin
        tl_dl[0] <= tl;
        for (pp = 1; pp < TLDLY; pp = pp + 1) tl_dl[pp] <= tl_dl[pp-1];
    end
    wire [3:0] tl_r = tl_dl[TLDLY-1];

    reg [LANES-1:0]    im0;
    reg [32*LANES-1:0] iw0;
    reg                pr_rej0;

    // inside_n(lane): the top-left rule, written as it reads. tl -> ">= 0", else
    // "> 0". No next_down anywhere.
    function automatic ins_test(input signed [FXW-1:0] v, input t);
        // sign bit and zero directly: no signed-vs-unsigned-literal ambiguity, and
        // it is the cheap form (a sign bit and one OR reduction).
        ins_test = t ? ~v[FXW-1] : (~v[FXW-1] & (|v));
    endfunction

    always @(posedge clk) begin : result_stage
        reg [3:0] ge;
        for (j = 0; j < LANES; j = j + 1) begin
            for (n = 0; n < 4; n = n + 1)
                ge[n] = ins_test(tv[NST-1][n][j], tl_r[n]);
            im0[j] <= &ge;
            iw0[32*j +: 32] <= fx_to_f32(tv[NST-1][WCH][j], tex[NST-1][WCH]);
            // PROBE: lane 0's value IS Xhs_n at that edge's max corner, because the
            // witness entered at the column fold. Reject if ANY edge's max corner is
            // outside - the whole tile is then outside that edge.
            if (j == 0) pr_rej0 <= ~(&ge);
        end
    end

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
        probe_valid  <= ppipe[LAT-1];
        probe_reject <= pr_rej0 & ppipe[LAT-1];
    end
endmodule

//
// isp_raster_line - evaluate a LANES-pixel span of a scanline, PIPELINED, at
// INTEGER TILE-LOCAL COORDINATES (0..31).
//
// isp_setup_streamed anchors the plane constants at the TILE ORIGIN PLUS THE
// HALF-PIXEL: C = DY*XL - DX*YT off an anchor vertex, so subtracting (origin + h)
// from the vertices yields DY*(XL-h) - DX*(YT-h) = C_tile + h*(DX - DY), which is
// the value AT THE SAMPLE POINT - for free, since coord_f32 already emits
// (2*coord + half)/2. There is therefore no half-pixel term anywhere in this
// module, and what it samples is a plain integer offset within the tile:
//     C_h + DX*y_local - DY*x_local
//       == C_screen + DX*(y_abs+h) - DY*(x_abs+h)
// Re-applying `half` here would double-count it. raster_topleft_tb sweeps both
// half=0 and half=1 and is the guard.
//
// For tile-local pixel (x,y), x,y in 0..31:
//    Xhs_n(x) = Cn + DXn*y - DYn*x        (n = 12,23,31,41)
//    inside_n = Xhs_n > 0 || (tl[n] && Xhs_n == 0)   (refsw2 top-left rule)
//    invW(x)  = c_invw + ddx*x + ddy*y
//
// ============================================================================
// SHARED-EXPONENT FIXED POINT - ADDS AND SHIFTS ONLY
// ============================================================================
// Per channel the whole evaluation is
//
//    V(x,y) = cst + rowc*y + colc*x        x, y in 0..31
//      edges : cst = Cn      rowc = +DXn   colc = -DYn   (sign flip, exact)
//      invW  : cst = c_invw  rowc = +ddy   colc = +ddx
//
// with the three coefficients aligned ONCE, per issue, into a two's-complement
// field at a shared exponent E = max of their exponents. After that alignment
// there is no multiplier and no floating-point unit anywhere: the row and column
// terms are five-term shift-add trees (the multiplicands are 5-bit tile-local
// integers) and the LANES lane values come out of a doubling tree of plain adders,
// V[j + 2^L] = V[j] + (colc << L). The standing per-lane cost is one adder per
// channel; the front is amortized over all LANES lanes.
//
// THE SHARED EXPONENT is an upper bound, not a normalization. HEAD growth bits sit
// above the significand because |V| <= (1 + 31 + 31) * max(|cst|,|rowc|,|colc|),
// which is the TILE span - it does not depend on the lane count. Below the
// significand are guard bits; a coefficient more than that many binades under E
// flushes to zero (the shift amount is saturated - the difference is unbounded
// below and would otherwise wrap into the MSBs).
//
// ALIGNMENT TRUNCATES THE MAGNITUDE, TOWARD ZERO - this is load-bearing, not a
// detail. Watertightness across a shared edge depends on the two triangles'
// coefficients being exact negations of each other: the exponents are identical so
// E is identical, and truncating the MAGNITUDE gives exactly -align(x). The
// fixed-point evaluation is then exact, so V_B(lane) == -V_A(lane) for every lane,
// and the top-left rule awards an exactly-on-edge sample to exactly one of the two.
// An arithmetic (floor) shift, or the round-to-nearest bias a "+0.5 ULP round bit"
// would inject, breaks that antisymmetry and with it every shared edge in the
// scene: floor turns a strictly-inside sample into a tie on one side and an outside
// on the other, which is a CRACK.
//
// THE TOP-LEFT RULE IS A SIGN BIT. Written as it reads - inside = tl ? V >= 0 :
// V > 0 - it needs a full-width zero-detect per edge PER LANE, which at 32 lanes is
// four 48-bit OR-reduces per lane and one of the largest items in the block. But V
// is an exact integer, so V > 0 <=> V - 1 >= 0: subtracting one from the BASE of a
// non-top-left edge, ONCE PER ISSUE, turns both cases into a plain sign test and
// the per-lane cost of the rule drops to reading one bit. Watertightness is
// untouched, because exactly one of a shared edge's two triangles has tl set, so
// exactly one gets the -1 and exactly one claims the tie. (This is what the old FP
// path's next_down trick was reaching for; in integers it is exact.)
//
// EDGE CHANNELS ARE NARROWER THAN invW. An edge only ever produces a sign, so its
// guard bits buy nothing except exactness of the tie - and an edge value flushing
// below the field's resolution is benign, since both triangles of a shared edge
// flush identically and the tl rule still decides. EW=32 leaves ~2^-25 pixel of
// edge-position error, far below anything observable, and takes a third off the
// four edge channels' adders and pipeline registers. invW keeps the full FXW field:
// its value IS the depth.
//
// DEPTH KEEPS ITS CONVENTIONS. invW is normalized back to f32 on the way out,
// because every consumer - the peel compare, the tile buffers, the span ring, the
// shade RCP - takes a float, and the compare is ACROSS primitives whose shared
// exponents differ, so it cannot be done in the tile's fixed point. The normalizer
// is a SINGLE left-normalizing shifter: the leading-one search and the shift are
// the same 6-level structure, rather than a priority-encoded LZC feeding a separate
// barrel shifter, and rather than the two-direction (>> or <<) shift the obvious
// implementation reaches for. invW's sign is stripped downstream (peel_core
// drop_sign) exactly as before.
//
// PRECISION. The only rounding in the whole evaluation is the initial alignment
// truncation of the three coefficients - everything after it is exact. That
// replaced two compounding error sources: per-lane fp_mul16 products (16-bit
// significands, of which an absolute coordinate up to 2047.5 already ate 12), and,
// larger, the near-total cancellation of two screen-scale numbers to land a
// tile-scale answer on every single pixel. Measured on raster_topleft_tb, worst
// invW relative error went 6.719e-06 (absolute coordinates, FP datapath) ->
// 1.567e-07, against a 2.440e-04 tolerance. Coverage still changes slightly on
// near-degenerate edges: this is a re-baseline, not a bit-exact rework.
//
// COST. At LANES=32 the old form was 160 fp_mul16 + 128 fp_ge + 32 fp_add24 plus
// 36 coord_f32. This is zero multipliers and zero FP units.
//
// NEXT LEVER (not taken here): V(lane) is monotonic in lane because colc is
// constant, so every edge's inside_mask is a contiguous run and its LANES-1 adders
// could collapse to a ~5-step crossing search. That moves the exact-tie handling
// into a divider, where the negation-symmetry argument has to be re-made.
//
// SHIFT-REGISTER RAM INFERENCE MUST BE OFF HERE. The operand delay chains are
// uniform-depth shift registers, which Quartus happily converts into altshift_taps
// backed by M10K. That is exactly wrong for these: they sit BETWEEN pipeline stages
// on the datapath, so a RAM access lands on the critical path, in a design already
// tight on M10K.
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
module isp_raster_line import tsp_pkg::*; #(
    parameter integer LANES = 32,
    // invW field width: sign + HEAD growth bits + a 24-bit significand, and the
    // rest guard precision for a coefficient whose exponent is below the shared one.
    parameter integer FXW   = 48,
    // edge field width - sign only, see the header. Must be >= 31.
    parameter integer EW    = 32
) (
    input             clk,
    input             reset,
    input             in_valid,
    input      [4:0]  y,           // TILE-LOCAL row (0..31)
    input      [4:0]  x_base,      // TILE-LOCAL col of lane 0 (0..31), LANES-aligned

    input      [31:0] c1,c2,c3,c4,
    input      [31:0] dx12,dx23,dx31,dx41,
    input      [31:0] dy12,dy23,dy31,dy41,
    input      [31:0] ddx,ddy,c_invw,
    input      [3:0]  tl,           // {tl41,tl31,tl23,tl12} IsTopLeft per edge

    // ---- CORNER-PROBE mode (the "257th step"): trivial per-tile reject, REUSING
    // this pipeline (no duplicate hardware). With `probe` asserted alongside
    // `in_valid`, each edge is fed ITS OWN max corner instead of the chunk grid:
    // Xhs_n is affine, so the tile max is at y* = (DXn < 0) ? 0 : 31 and
    // x* = (DYn < 0) ? 31 : 0 - CONSTANTS, now that the coordinate is tile-local
    // (the absolute form had to derive them from the issued coordinate). If any
    // edge's max-corner Xhs_n is outside, the whole 32x32 tile is outside that edge
    // -> reject. Lane 0 IS the probe value (its lane offset is zero), so the verdict
    // comes out of the same compare the sweep uses and the two cannot disagree.
    // `probe_reject` is valid together with out_valid (same LAT) for a probe issue.
    input             probe,
    output reg               probe_reject,   // reject verdict (valid when probe_valid)
    output reg               probe_valid,    // 1-cyc: a probe issue's verdict is on the bus

    output reg               out_valid,
    output reg [LANES-1:0]    inside_mask,
    output reg [32*LANES-1:0] invw_flat,
    // echo of this chunk's coords (aligned with out_valid) so a streaming consumer
    // can address the depth/tag buffer for the results as they emerge, back-to-back,
    // without stalling the issue side.
    // per-issue sideband index: rides the pipe with x/y so a chaining consumer can
    // look up the owning triangle's identity (tag/mode) at exit time even when
    // several triangles' chunks are in flight back-to-back.
    input      [2:0]          qi,
    output reg [2:0]          out_qi,
    output reg [4:0]          out_x,
    output reg [4:0]          out_y
);
    // ---- channel numbering: 0..3 = edges 12/23/31/41, 4 = invW ----
    localparam integer NCH  = 5;
    localparam integer WCH  = 4;                 // the invW channel's index

    // ---- fixed-point geometry ----
    // HEAD is the growth headroom: |V| <= (1 + 31 + 31) * max(coefficients) < 2^6 *
    // max - SIX bits, set by the TILE span, not by the lane count. (A probe issue
    // can drive a DISCARDED lane past that; two's-complement wrap is harmless there
    // because only lane 0's verdict is consumed and out_valid is suppressed.)
    localparam integer HEAD = 6;
    localparam integer LB   = $clog2(LANES);     // lane-index bits

    // ---- stage latencies ----
    localparam integer L_IN   = 1;   // input register (coefficients + coords + probe)
    localparam integer L_ALGN = 1;   // 3-way exponent max + three alignment shifts
    localparam integer L_PROD = 1;   // rowc*y and colc*x_base (5-term shift-add trees)
    localparam integer L_BASE = 1;   // cst + rowc*y + colc*x_base - !tl
    localparam integer NST    = (LB + 1) / 2;    // tree stages: two levels each
    // issue -> im0/iw0 INCLUSIVE. That last +1 is not bookkeeping: `inside_mask <=
    // im0` in the output stage samples im0 one cycle BEFORE it presents, so LAT must
    // count the im0 register or the mask lands against the NEXT chunk's out_x/out_y.
    // EXPORTED via tsp_pkg::isp_raster_lat() so peel_core's corner-probe countdown
    // (CR_LAT) tracks this pipe instead of hardcoding its depth. The local stage
    // constants above are the documentation; the function is the contract.
    localparam integer LAT    = isp_raster_lat(LANES);
`ifndef SYNTHESIS
    initial if (LAT != L_IN + L_ALGN + L_PROD + L_BASE + NST + 1)
        $fatal(1, "isp_raster_line: tsp_pkg::isp_raster_lat(%0d)=%0d disagrees with the pipe (%0d)",
               LANES, LAT, L_IN + L_ALGN + L_PROD + L_BASE + NST + 1);
`endif
    // tl is consumed at the BASE stage (it rides in as the -1), so it meets the
    // products there rather than travelling to the result stage.
    localparam integer TLDLY = L_IN + L_ALGN + L_PROD;

    genvar gc, gs, gl;
    integer pp;

    // ==================================================================
    // Shared helpers
    // ==================================================================

    // Align a float into a W-wide two's-complement field at shared exponent E.
    // TRUNCATES THE MAGNITUDE (round toward zero) so align(-x) == -align(x) exactly
    // - see the header, shared-edge watertightness rests on it. DaZ, matching the FP
    // units. Returned at FXW; a narrower channel takes the low W bits, which is the
    // correct two's-complement value because |result| < 2^(W-1).
    function automatic signed [FXW-1:0] align_fx(input [31:0] f, input [7:0] E,
                                                 input integer W);
        reg [7:0]     e;
        reg [FXW-1:0] mag;
        reg [8:0]     sh;
        integer       shl;
        begin
            shl = (W - 2 - HEAD) - 23;          // significand placement
            e   = f[30:23];
            sh  = {1'b0, E} - {1'b0, e};        // E is the max, so never negative
            if (e == 8'd0 || sh > 9'(W-1)) mag = {FXW{1'b0}};
            else mag = (FXW'({1'b1, f[22:0]}) << shl) >> sh[5:0];
            align_fx = f[31] ? -$signed(mag) : $signed(mag);
        end
    endfunction

    function automatic [7:0] emax3(input [31:0] a, input [31:0] b, input [31:0] c);
        reg [7:0] m;
        begin
            m = (a[30:23] > b[30:23]) ? a[30:23] : b[30:23];
            emax3 = (c[30:23] > m) ? c[30:23] : m;
        end
    endfunction

    // negate a float (exact): an edge's column coefficient is -DYn
    function automatic [31:0] fneg(input [31:0] f);
        fneg = {~f[31], f[30:0]};
    endfunction

    // ==================================================================
    // s0: register the inputs. Nothing converts a coordinate - y and x_base ARE the
    // multiplicands, as plain 5-bit integers, so the six coord_f32 instances are
    // gone along with the ten FP multipliers and the five fused 3-input FP adds that
    // used to stand between them and the fixed-point field.
    // ==================================================================
    reg probe_c;
    always @(posedge clk) if (reset) probe_c <= 1'b0; else probe_c <= in_valid && probe;
    reg [31:0] ch_cst [0:NCH-1], ch_row [0:NCH-1], ch_col [0:NCH-1];
    reg [31:0] dxc [0:3], dyc [0:3];
    reg  [4:0] y_c, xb_c;
    always @(posedge clk) begin
        dxc[0]<=dx12; dxc[1]<=dx23; dxc[2]<=dx31; dxc[3]<=dx41;
        dyc[0]<=dy12; dyc[1]<=dy23; dyc[2]<=dy31; dyc[3]<=dy41;
        ch_cst[0]<=c1; ch_cst[1]<=c2; ch_cst[2]<=c3; ch_cst[3]<=c4;
        ch_row[0]<=dx12; ch_row[1]<=dx23; ch_row[2]<=dx31; ch_row[3]<=dx41;
        ch_col[0]<=fneg(dy12); ch_col[1]<=fneg(dy23);
        ch_col[2]<=fneg(dy31); ch_col[3]<=fneg(dy41);
        ch_cst[WCH]<=c_invw; ch_row[WCH]<=ddy; ch_col[WCH]<=ddx;
        y_c <= y; xb_c <= x_base;
    end

`ifndef SYNTHESIS
    always @(posedge clk) if (!reset && in_valid && ((x_base % LANES) != 0))
        $error("isp_raster_line %m: x_base=%0d is not LANES(%0d)-aligned - the lane column concatenation is invalid",
               x_base, LANES);
`endif

    // probe witnesses (constants now that the coordinate is tile-local). invW never
    // uses one: the probe only decides coverage.
    wire [4:0] y_sel [0:NCH-1];
    wire [4:0] x_sel [0:NCH-1];
    generate
      for (gc = 0; gc < 4; gc = gc + 1) begin : wit
        assign y_sel[gc] = probe_c ? (dxc[gc][31] ? 5'd0  : 5'd31) : y_c;
        assign x_sel[gc] = probe_c ? (dyc[gc][31] ? 5'd31 : 5'd0 ) : xb_c;
      end
    endgenerate
    assign y_sel[WCH] = y_c;
    assign x_sel[WCH] = xb_c;

    // tl to the base stage, where it becomes the -1
    reg [3:0] tl_dl [0:TLDLY-1];
    always @(posedge clk) begin
        tl_dl[0] <= tl;
        for (pp = 1; pp < TLDLY; pp = pp + 1) tl_dl[pp] <= tl_dl[pp-1];
    end
    wire [3:0] tl_b = tl_dl[TLDLY-1];

    // ==================================================================
    // Per-channel datapath, at the channel's own width. Only the RESULTS leave the
    // generate: one sign bit per lane for each edge, and the full field per lane for
    // invW - so nothing outside has to know the widths differ.
    // ==================================================================
    wire [LANES-1:0]      e_neg  [0:3];         // per-lane sign bit (1 = outside)
    wire signed [FXW-1:0] w_lane [0:LANES-1];   // invW lane values
    wire [7:0]            w_exp;                // invW shared exponent

    generate
      for (gc = 0; gc < NCH; gc = gc + 1) begin : ch
        localparam integer W = (gc == WCH) ? FXW : EW;

        // ---- s1: shared exponent + alignment. The only barrel shifters on the
        // path; everything after this is adds. ----
        reg signed [W-1:0] al_cst, al_row, al_col;
        reg        [7:0]   al_e;
        reg        [4:0]   al_y, al_x;
        always @(posedge clk) begin : align_stage
            reg [7:0] E;
            E      = emax3(ch_cst[gc], ch_row[gc], ch_col[gc]);
            al_e   <= E;
            al_cst <= align_fx(ch_cst[gc], E, W);
            al_row <= align_fx(ch_row[gc], E, W);
            al_col <= align_fx(ch_col[gc], E, W);
            al_y   <= y_sel[gc];
            al_x   <= x_sel[gc];
        end

        // ---- s2: the two products, as balanced five-term shift-add trees. The
        // multiplicands are 5-bit tile-local integers - no multiplier, no DSP.
        // (Hand-balanced: a `+=` loop would synthesize as a 5-deep chain.) ----
        wire signed [W-1:0] r0 = al_y[0] ? al_row       : {W{1'b0}};
        wire signed [W-1:0] r1 = al_y[1] ? (al_row<<<1) : {W{1'b0}};
        wire signed [W-1:0] r2 = al_y[2] ? (al_row<<<2) : {W{1'b0}};
        wire signed [W-1:0] r3 = al_y[3] ? (al_row<<<3) : {W{1'b0}};
        wire signed [W-1:0] r4 = al_y[4] ? (al_row<<<4) : {W{1'b0}};
        wire signed [W-1:0] k0 = al_x[0] ? al_col       : {W{1'b0}};
        wire signed [W-1:0] k1 = al_x[1] ? (al_col<<<1) : {W{1'b0}};
        wire signed [W-1:0] k2 = al_x[2] ? (al_col<<<2) : {W{1'b0}};
        wire signed [W-1:0] k3 = al_x[3] ? (al_col<<<3) : {W{1'b0}};
        wire signed [W-1:0] k4 = al_x[4] ? (al_col<<<4) : {W{1'b0}};

        reg signed [W-1:0] pr_cst, pr_row, pr_col, pr_stp;
        reg        [7:0]   pr_e;
        always @(posedge clk) begin
            pr_row <= ((r0 + r1) + (r2 + r3)) + r4;
            pr_col <= ((k0 + k1) + (k2 + k3)) + k4;
            pr_cst <= al_cst;
            pr_stp <= al_col;               // per-lane step: x advances by 1
            pr_e   <= al_e;
        end

        // ---- s3: the base. The top-left rule rides in here as a -1 on non-top-left
        // edges, which is what lets the per-lane test be a bare sign bit. ----
        // (index clamped: tl_b is 4 wide and gc reaches WCH=4, which the && would
        // mask but the select still has to elaborate)
        localparam integer TLI = (gc < 4) ? gc : 0;
        wire tl_sub = (gc != WCH) && !tl_b[TLI];
        reg signed [W-1:0] al_base, al_step;
        reg        [7:0]   al_e2;
        always @(posedge clk) begin
            al_base <= ((pr_cst + pr_row) + pr_col) - {{(W-1){1'b0}}, tl_sub};
            al_step <= pr_stp;
            al_e2   <= pr_e;
        end

        // ---- the doubling tree. Stage s covers levels 2s and 2s+1, so lanes
        // 0 .. 4^(s+1)-1 are live after it; the shifts are hardwired. Only the lanes
        // a stage actually produces are registered (the rest have no driver and
        // disappear), which is why the cuts land where they do: registering all
        // LANES at every level would cost thousands of flops for values that do not
        // exist yet. ----
        (* ramstyle = "logic" *) reg signed [W-1:0] tv   [0:NST-1][0:LANES-1];
        (* ramstyle = "logic" *) reg signed [W-1:0] tstp [0:NST-1];
        (* ramstyle = "logic" *) reg        [7:0]   tex  [0:NST-1];

        for (gs = 0; gs < NST; gs = gs + 1) begin : tstage
          localparam integer LV   = 2*gs;
          localparam integer NIN  = ((1<<LV)     > LANES) ? LANES : (1<<LV);
          localparam integer NMID = ((1<<(LV+1)) > LANES) ? LANES : (1<<(LV+1));
          localparam integer NOUT = ((1<<(LV+2)) > LANES) ? LANES : (1<<(LV+2));
          always @(posedge clk) begin : tree
            reg signed [W-1:0] cur [0:LANES-1];
            reg signed [W-1:0] mid [0:LANES-1];
            reg signed [W-1:0] stp;
            integer k;
            stp = (gs == 0) ? al_step : tstp[gs-1];
            for (k = 0; k < NIN; k = k + 1)
                cur[k] = (gs == 0) ? al_base : tv[gs-1][k];
            for (k = 0; k < NIN; k = k + 1) begin          // level LV
                mid[k] = cur[k];
                if (NIN + k < NMID) mid[NIN + k] = cur[k] + (stp <<< LV);
            end
            for (k = 0; k < NMID; k = k + 1) begin         // level LV+1
                tv[gs][k] <= mid[k];
                if (NMID + k < NOUT) tv[gs][NMID + k] <= mid[k] + (stp <<< (LV+1));
            end
            tstp[gs] <= stp;
            tex [gs] <= (gs == 0) ? al_e2 : tex[gs-1];
          end
        end

        // ---- results out of the generate ----
        if (gc == WCH) begin : g_w
            for (gl = 0; gl < LANES; gl = gl + 1) begin : lo
                assign w_lane[gl] = tv[NST-1][gl];
            end
            assign w_exp = tex[NST-1];
        end else begin : g_e
            for (gl = 0; gl < LANES; gl = gl + 1) begin : lo
                assign e_neg[gc][gl] = tv[NST-1][gl][W-1];
            end
        end
      end
    endgenerate

    // ==================================================================
    // Result stage. Each edge is one sign bit (the -1 folded into the base did the
    // rest); invW normalizes back to f32.
    // ==================================================================

    // Normalize a fixed-point invW to f32 at shared exponent E. This runs 32 times,
    // once per lane, and is the largest thing left in the block - so it is built for
    // exactly the contract it has, and nothing more:
    //
    //  * invW IS POSITIVE (hardware contract - peel_core's drop_sign and every
    //    downstream unsigned depth compare already rest on it), so there is no
    //    magnitude step. The 47-bit two's-complement negate a general fixed->float
    //    convert needs is not built: it would sit in SERIES with the shifter, on the
    //    critical path, 32 times over. The output sign is a constant 0.
    //    (Lanes OUTSIDE the triangle can hold a negative interpolant - the plane
    //    extends past the edges - and their top bit is simply dropped here. That is
    //    don't-care: inside_mask gates them out before any compare sees them.)
    //  * ONE left-normalizing shifter. The leading-one search and the shift are the
    //    same 6-level structure, so there is no separate priority-encoded LZC, and
    //    no second (right) shifter of the kind `(p>=23) ? mag>>(p-23) : mag<<(23-p)`
    //    reaches for. Synthesis trims each level to the bits that can still reach the
    //    24-bit output window.
    //  * ZERO needs no 47-bit OR-reduce: it is exactly the case where every level of
    //    the search fires, i.e. nz == 63 - a 6-bit compare on a value already formed.
    //
    // Underflow flushes to zero and overflow saturates, as the FP units do.
    localparam integer MSBW = FXW - 2;             // top magnitude bit
    localparam integer MSBP = FXW - 2 - HEAD;      // where an E-exponent MSB sits
    function automatic [31:0] fx_to_f32(input [FXW-2:0] mag, input [7:0] E);
        reg [FXW-2:0] t;
        reg     [5:0] nz;
        integer       ex;
        begin
            t  = mag;
            nz = 6'd0;
            if (t[MSBW -: 32] == 32'd0) begin nz = nz + 6'd32; t = t << 32; end
            if (t[MSBW -: 16] == 16'd0) begin nz = nz + 6'd16; t = t << 16; end
            if (t[MSBW -:  8] ==  8'd0) begin nz = nz + 6'd8;  t = t <<  8; end
            if (t[MSBW -:  4] ==  4'd0) begin nz = nz + 6'd4;  t = t <<  4; end
            if (t[MSBW -:  2] ==  2'd0) begin nz = nz + 6'd2;  t = t <<  2; end
            if (t[MSBW]       ==  1'b0) begin nz = nz + 6'd1;  t = t <<  1; end
            // the leading one now sits at MSBW, so it started at MSBW - nz
            ex = E + (MSBW - nz) - MSBP;
            if (nz == 6'd63 || ex <= 0) fx_to_f32 = 32'd0;   // zero / underflow
            else if (ex > 255)          fx_to_f32 = {1'b0, 8'hFF, 23'h7FFFFF};
            else                        fx_to_f32 = {1'b0, ex[7:0], t[MSBW-1 -: 23]};
        end
    endfunction

    reg [LANES-1:0]    im0;
    reg [32*LANES-1:0] iw0;
    reg                pr_rej0;

    integer j;
    always @(posedge clk) begin : result_stage
        for (j = 0; j < LANES; j = j + 1) begin
            im0[j] <= ~(e_neg[0][j] | e_neg[1][j] | e_neg[2][j] | e_neg[3][j]);
            iw0[32*j +: 32] <= fx_to_f32(w_lane[j][FXW-2:0], w_exp);
        end
        // PROBE: lane 0's value IS Xhs_n at that edge's max corner. Reject if ANY
        // edge's max corner is outside - the whole tile is then outside it.
        pr_rej0 <= e_neg[0][0] | e_neg[1][0] | e_neg[2][0] | e_neg[3][0];
    end

    // ---- valid / sideband pipe ----
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
        xpipe[0] <= x_base; ypipe[0] <= y; qpipe[0] <= qi;
        for (pp = 1; pp < LAT; pp = pp + 1) begin
            xpipe[pp] <= xpipe[pp-1]; ypipe[pp] <= ypipe[pp-1];
            qpipe[pp] <= qpipe[pp-1];
        end
    end

    // Final output register: re-time inside_mask/invw_flat here so they land on the
    // SAME cycle as out_valid/out_x/out_y.
    always @(posedge clk) begin
        // A PROBE issue must NOT look like a real rastered chunk to the consumer:
        // suppress out_valid on probe cycles so no stage-B write / inflight
        // accounting fires for it. Only probe_reject carries the probe result.
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

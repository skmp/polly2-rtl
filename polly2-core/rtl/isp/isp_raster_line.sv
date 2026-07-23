//
// isp_raster_line - evaluate a LANES-pixel span of a scanline, PIPELINED, for
// opaque render mode. Registers between every FP sub-level (mul, add-align,
// add-normalize) so the max path is ~one FP sub-op and the design closes timing.
//
// For tile-local pixel (x,y), x,y in 0..31 (pixel-center ignored):
//    Xhs_n(x) = Cn + DXn*y - DYn*x        (n = 12,23,31,41)
//    inside_n = Xhs_n > 0 || (tl[n] && Xhs_n == 0)   (refsw2 top-left rule:
//               exactly-on-edge samples belong only to top-left edges; C is
//               EXACT, the rule lives here in the compare - a C bias cannot
//               survive the fp sums)
//    invW(x)  = c_invw + ddx*x + ddy*y
//
// Pipeline (in_valid -> out_valid after LAT cycles):
//   s1  : DXn*y, ddy*y                          (fp_mul_i5)
//   s2a : ebase/wbase align (Cn + DXn*y)        (fp_add24_s1)
//   s2b : ebase/wbase normalize                 (fp_add24_s2)
//   s3  : DYn*x, ddx*x                           (fp_mul_i5)
//   s4a : edge ordering cmp ebase>=DY*x (fp_ge); invW align (fp_add24_s1)
//   s4b : invW normalize -> inside, invW        (fp_add24_s2)
//
// Numerics per spec: pixel-index products use the fast 16x5 multiplier; sums use
// fp_add24 (split align|normalize here for timing). The edge inside tests need
// only the SIGN of ebase - DY*x, and the sign of a float subtract is exactly
// the ordering predicate, so they are fp_ge magnitude compares - bit-exact vs
// the former fp_add24 sub (incl. +0 on exact cancellation, which is only
// reachable at shamt==0, and the underflow flush keeping s_big).
//
module isp_raster_line #(
    parameter integer LANES = 8
) (
    input             clk,
    input             reset,
    input             in_valid,
    input      [4:0]  y,
    input      [4:0]  x_base,

    input      [31:0] c1,c2,c3,c4,
    input      [31:0] dx12,dx23,dx31,dx41,
    input      [31:0] dy12,dy23,dy31,dy41,
    input      [31:0] ddx,ddy,c_invw,
    input      [3:0]  tl,           // {tl41,tl31,tl23,tl12} IsTopLeft per edge

    // ---- CORNER-PROBE mode (the "257th step"): trivial per-tile reject, REUSING this
    // pipeline's adders/multipliers (no duplicate FP hw). When `probe` is asserted with
    // `in_valid`, s1/s3 evaluate each edge at ITS OWN max corner instead of the chunk grid:
    // Xhs_n is affine, so the tile max is at y*=(DXn>=0?31:0), x*=(DYn<=0?31:0). If any
    // edge's max-corner Xhs_n < 0, the whole 32x32 tile is outside that edge -> reject.
    // `probe_reject` is valid together with out_valid (same LAT) for a probe issue.
    input             probe,
    output reg               probe_reject,   // reject verdict (valid when probe_valid)
    output reg               probe_valid,    // 1-cyc: a probe issue's verdict is on the bus

    output reg               out_valid,
    output reg [LANES-1:0]    inside_mask,
    output reg [32*LANES-1:0] invw_flat,
    // echo of this chunk's tile coords (aligned with out_valid) so a streaming
    // consumer can address the depth/tag buffer for the results as they emerge,
    // back-to-back, without stalling the issue side.
    output reg [4:0]          out_x,
    output reg [4:0]          out_y
);
    localparam integer LAT = 6;

    // s4b-stage results, re-timed by the final output register (below) so all
    // outputs are co-aligned for back-to-back streaming.
    reg [LANES-1:0]    im0;
    reg [32*LANES-1:0] iw0;
    reg                pr_rej0;   // probe reject at the s4b stage (lane 0), retimed below

    reg [LAT-1:0] vpipe;
    reg [LAT-1:0] ppipe;   // probe flag, LAT-deep (aligned with vpipe)
    // x_base / y travel the full LAT-deep pipe so they arrive with out_valid.
    reg [4:0] xpipe [0:LAT-1];
    reg [4:0] ypipe [0:LAT-1];
    integer pp;
    always @(posedge clk) begin
        if (reset) begin vpipe <= '0; ppipe <= '0; end
        else begin
            vpipe <= {vpipe[LAT-2:0], in_valid};
            ppipe <= {ppipe[LAT-2:0], (in_valid && probe)};
        end
        xpipe[0] <= x_base; ypipe[0] <= y;
        for (pp = 1; pp < LAT; pp = pp + 1) begin
            xpipe[pp] <= xpipe[pp-1]; ypipe[pp] <= ypipe[pp-1];
        end
    end
    // PROBE flag must travel WITH the data so the witness selects fire at the right stage
    // (the sweep chunks share this pipeline right behind the probe and must NOT use the
    // witnesses). s1 witness uses the live issue-cycle `probe` (s1 muls are at issue). The
    // s3 x-witness mul runs at cyc3 (same stage as xb2b, 3 regs after x_base), so delay the
    // issue flag exactly 3 cycles to align. (A 2-cycle delay is one cycle EARLY -> the mul
    // uses the sweep x instead of the witness -> spurious rejects; only masked when `probe`
    // was held as a level across the whole probe transit.)
    wire pr_s1 = probe;                 // s1 y-witness select (combinational at issue)
    reg  pr_a, pr_b, pr_s3;             // s3 x-witness select (issue flag, 3 regs deep)
    always @(posedge clk) begin
        if (reset) begin pr_a <= 1'b0; pr_b <= 1'b0; pr_s3 <= 1'b0; end
        else begin pr_a <= (in_valid && probe); pr_b <= pr_a; pr_s3 <= pr_b; end
    end

    // carry x_base to stage 3 (line base stages don't need it)
    reg [4:0] xb1, xb2a, xb2b;
    always @(posedge clk) begin xb1<=x_base; xb2a<=xb1; xb2b<=xb2a; end

    // ---- s1: DXn*y, ddy*y ----
    // In PROBE mode each edge uses its own y-witness (y*=31 if DXn>=0 else 0) so the
    // pipeline evaluates that edge's tile-max corner; else the normal shared chunk row y.
    wire [4:0] y12 = pr_s1 ? (dx12[31] ? 5'd0 : 5'd31) : y;
    wire [4:0] y23 = pr_s1 ? (dx23[31] ? 5'd0 : 5'd31) : y;
    wire [4:0] y31 = pr_s1 ? (dx31[31] ? 5'd0 : 5'd31) : y;
    wire [4:0] y41 = pr_s1 ? (dx41[31] ? 5'd0 : 5'd31) : y;
    wire [31:0] dx12y_c,dx23y_c,dx31y_c,dx41y_c, ddyy_c;
    fp_mul_i5 m_dx12y(.f(dx12),.k(y12),.y(dx12y_c));
    fp_mul_i5 m_dx23y(.f(dx23),.k(y23),.y(dx23y_c));
    fp_mul_i5 m_dx31y(.f(dx31),.k(y31),.y(dx31y_c));
    fp_mul_i5 m_dx41y(.f(dx41),.k(y41),.y(dx41y_c));
    fp_mul_i5 m_ddyy (.f(ddy), .k(y),.y(ddyy_c));
    reg [31:0] dx12y,dx23y,dx31y,dx41y, ddyy;
    reg [31:0] c1_1,c2_1,c3_1,c4_1,cinvw_1;
    always @(posedge clk) begin
        dx12y<=dx12y_c; dx23y<=dx23y_c; dx31y<=dx31y_c; dx41y<=dx41y_c; ddyy<=ddyy_c;
        c1_1<=c1; c2_1<=c2; c3_1<=c3; c4_1<=c4; cinvw_1<=c_invw;
    end

    // ---- s2a: base align (Cn + DXn*y ; c_invw + ddy*y) ----
    wire [24:0] eb1s,eb2s,eb3s,eb4s, wbs; wire [7:0] eb1e,eb2e,eb3e,eb4e,wbe;
    wire eb1g,eb2g,eb3g,eb4g,wbg;
    fp_add24_s1 e1a(.a(c1_1),.b_in(dx12y),.sub(1'b0),.sum(eb1s),.e_big(eb1e),.s_big(eb1g));
    fp_add24_s1 e2a(.a(c2_1),.b_in(dx23y),.sub(1'b0),.sum(eb2s),.e_big(eb2e),.s_big(eb2g));
    fp_add24_s1 e3a(.a(c3_1),.b_in(dx31y),.sub(1'b0),.sum(eb3s),.e_big(eb3e),.s_big(eb3g));
    fp_add24_s1 e4a(.a(c4_1),.b_in(dx41y),.sub(1'b0),.sum(eb4s),.e_big(eb4e),.s_big(eb4g));
    fp_add24_s1 wba(.a(cinvw_1),.b_in(ddyy),.sub(1'b0),.sum(wbs),.e_big(wbe),.s_big(wbg));
    reg [24:0] eb1s_r,eb2s_r,eb3s_r,eb4s_r,wbs_r; reg [7:0] eb1e_r,eb2e_r,eb3e_r,eb4e_r,wbe_r;
    reg eb1g_r,eb2g_r,eb3g_r,eb4g_r,wbg_r;
    reg [31:0] dy12_2,dy23_2,dy31_2,dy41_2,ddx_2;
    always @(posedge clk) begin
        eb1s_r<=eb1s;eb2s_r<=eb2s;eb3s_r<=eb3s;eb4s_r<=eb4s;wbs_r<=wbs;
        eb1e_r<=eb1e;eb2e_r<=eb2e;eb3e_r<=eb3e;eb4e_r<=eb4e;wbe_r<=wbe;
        eb1g_r<=eb1g;eb2g_r<=eb2g;eb3g_r<=eb3g;eb4g_r<=eb4g;wbg_r<=wbg;
        dy12_2<=dy12;dy23_2<=dy23;dy31_2<=dy31;dy41_2<=dy41;ddx_2<=ddx;
    end

    // ---- s2b: base normalize -> eb1..eb4, wbase ----
    wire [31:0] eb1_c,eb2_c,eb3_c,eb4_c,wbase_c;
    fp_add24_s2 e1b(.sum(eb1s_r),.e_big(eb1e_r),.s_big(eb1g_r),.y(eb1_c));
    fp_add24_s2 e2b(.sum(eb2s_r),.e_big(eb2e_r),.s_big(eb2g_r),.y(eb2_c));
    fp_add24_s2 e3b(.sum(eb3s_r),.e_big(eb3e_r),.s_big(eb3g_r),.y(eb3_c));
    fp_add24_s2 e4b(.sum(eb4s_r),.e_big(eb4e_r),.s_big(eb4g_r),.y(eb4_c));
    fp_add24_s2 wbb(.sum(wbs_r),.e_big(wbe_r),.s_big(wbg_r),.y(wbase_c));
    reg [31:0] eb1,eb2,eb3,eb4,wbase;
    reg [31:0] dy12_3,dy23_3,dy31_3,dy41_3,ddx_3;
    always @(posedge clk) begin
        eb1<=eb1_c;eb2<=eb2_c;eb3<=eb3_c;eb4<=eb4_c;wbase<=wbase_c;
        dy12_3<=dy12_2;dy23_3<=dy23_2;dy31_3<=dy31_2;dy41_3<=dy41_2;ddx_3<=ddx_2;
    end

    // s3 stage-align of the edge bases: these are line-base values (independent of
    // x/lane), so ONE shared copy fans out to all LANES' s4a adders rather than a
    // redundant per-lane register (was 5*32 FF x LANES; now 5*32 FF total).
    //
    // Top-left rule (refsw2: inside = Xhs > 0 || (T && Xhs == 0)) folded in HERE,
    // once per line per edge - NOT per lane: for finite floats
    //     a > b   <=>   next_down(a) >= b     (exactly),
    // so a non-top-left edge gets its line base stepped one float toward -inf and
    // the per-lane fp_ge stays the plain inclusive compare. (A bias on C itself
    // cannot work: it washes out of C + DX*y depending on per-pixel exponent
    // alignment, and the old raw C-1 wrapped C=+0 to -NaN, dropping every tile
    // whose origin lies exactly on the edge.) next_down(+-0) is the smallest
    // negative DENORMAL: fp_ge is a pure ordering compare, so it orders denormals
    // correctly even though the adders flush them.
    function [31:0] fdown(input [31:0] f);
        fdown = (f[30:0] == 31'd0) ? 32'h80000001
              : f[31] ? (f + 32'd1) : (f - 32'd1);
    endfunction
    reg [31:0] eb1_3,eb2_3,eb3_3,eb4_3,wbase_3;
    always @(posedge clk) begin
        eb1_3<=tl[0]?eb1:fdown(eb1); eb2_3<=tl[1]?eb2:fdown(eb2);
        eb3_3<=tl[2]?eb3:fdown(eb3); eb4_3<=tl[3]?eb4:fdown(eb4);
        wbase_3<=wbase;
    end

    genvar gi;
    generate
      for (gi = 0; gi < LANES; gi = gi + 1) begin : px
        wire [4:0] x = xb2b + gi[4:0];       // absolute column at stage 3
        // ---- s3: DYn*x, ddx*x ----
        // PROBE mode: each edge uses its own x-witness (x*=31 if DYn<=0 i.e. DYn[31], else
        // 0) so the pipeline evaluates that edge's tile-MAX corner. Xhs = Cn+DXn*y-DYn*x, so
        // -DYn*x is maximized at x=31 when DYn<0. Only lane 0 is used by the probe consumer.
        wire [4:0] xk12 = pr_s3 ? (dy12_3[31] ? 5'd31 : 5'd0) : x;
        wire [4:0] xk23 = pr_s3 ? (dy23_3[31] ? 5'd31 : 5'd0) : x;
        wire [4:0] xk31 = pr_s3 ? (dy31_3[31] ? 5'd31 : 5'd0) : x;
        wire [4:0] xk41 = pr_s3 ? (dy41_3[31] ? 5'd31 : 5'd0) : x;
        wire [31:0] dy12x_c,dy23x_c,dy31x_c,dy41x_c, ddxx_c;
        fp_mul_i5 mdy12(.f(dy12_3),.k(xk12),.y(dy12x_c));
        fp_mul_i5 mdy23(.f(dy23_3),.k(xk23),.y(dy23x_c));
        fp_mul_i5 mdy31(.f(dy31_3),.k(xk31),.y(dy31x_c));
        fp_mul_i5 mdy41(.f(dy41_3),.k(xk41),.y(dy41x_c));
        fp_mul_i5 mddx (.f(ddx_3), .k(x),.y(ddxx_c));
        reg [31:0] dy12x,dy23x,dy31x,dy41x, ddxx;
        always @(posedge clk) begin
            dy12x<=dy12x_c;dy23x<=dy23x_c;dy31x<=dy31x_c;dy41x<=dy41x_c;ddxx<=ddxx_c;
        end

        // ---- s4a: edge ordering compares + invW align ----
        // inside_n = "sign of (eb_n - DYn*x) clear" = (eb_n >= DYn*x): the 4
        // edge fp_add24 pairs collapse to fp_ge compares (see fp_ge.sv for the
        // bit-exactness argument); only invW, whose VALUE is consumed
        // downstream, keeps the real adder. fp_ge registers its output, which
        // IS the s4a->s4b pipe register for the edge bits.
        wire ge1,ge2,ge3,ge4;
        fp_ge cmp1(.clk(clk),.a(eb1_3),.b(dy12x),.ge(ge1));
        fp_ge cmp2(.clk(clk),.a(eb2_3),.b(dy23x),.ge(ge2));
        fp_ge cmp3(.clk(clk),.a(eb3_3),.b(dy31x),.ge(ge3));
        fp_ge cmp4(.clk(clk),.a(eb4_3),.b(dy41x),.ge(ge4));
        wire [24:0] ws; wire [7:0] we; wire wg;
        fp_add24_s1 iwa(.a(wbase_3),.b_in(ddxx),.sub(1'b0),.sum(ws),.e_big(we),.s_big(wg));
        reg [24:0] ws_r; reg [7:0] we_r; reg wg_r;
        always @(posedge clk) begin
            ws_r<=ws;we_r<=we;wg_r<=wg;
        end

        // ---- s4b: invW normalize -> outputs ----
        wire [31:0] iw;
        fp_add24_s2 iwb(.sum(ws_r),.e_big(we_r),.s_big(wg_r),.y(iw));
        // s4b register -> internal (im0/iw0); aligned one cycle EARLIER than the
        // final output register below.
        always @(posedge clk) begin
            im0[gi] <= ge1 & ge2 & ge3 & ge4;
            iw0[32*gi +: 32] <= iw;
        end
        // PROBE: lane 0's compares test the 4 edges at their tile-MAX corners.
        // Reject if ANY edge's max corner is strictly outside (whole tile is
        // then outside that edge).
        if (gi == 0) begin : probe_lane
            always @(posedge clk)
                pr_rej0 <= ~(ge1 & ge2 & ge3 & ge4);
        end
      end
    endgenerate

    // Final output register: re-time inside_mask/invw_flat here so they land on
    // the SAME cycle as out_valid/out_x/out_y. (Previously mask/invw appeared one
    // cycle BEFORE out_valid, which only worked when the issue side held data
    // stable; a back-to-back stream needs them aligned.)
    always @(posedge clk) begin
        // A PROBE issue must NOT look like a real rastered chunk to the consumer: suppress
        // out_valid on probe cycles so no stage-B write / inflight accounting fires for it.
        // Only probe_reject carries the probe result.
        out_valid    <= vpipe[LAT-1] & ~ppipe[LAT-1];
        out_x        <= xpipe[LAT-1];
        out_y        <= ypipe[LAT-1];
        inside_mask  <= im0;
        invw_flat    <= iw0;
        // probe_reject/probe_valid align with the (suppressed) out_valid slot; probe_valid
        // marks the cycle a probe issue's verdict is on the bus.
        probe_valid  <= ppipe[LAT-1];
        probe_reject <= pr_rej0 & ppipe[LAT-1];
    end
endmodule

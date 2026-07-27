//
// isp_setup_streamed - STREAMED ISP setup (II=15) on registered-output pipelined FP
// units, with QUAD support.
//
// Facelift of the old 4-way mac16 interleave into the SAME shape as tsp_setup_stream:
// a statically-scheduled pipeline where every register-to-register path goes through
// exactly one *_spp_ro pipeline stage (or a shallow registered select), so there are
// no fat combinational float clouds and no multicycle SDC anywhere.
//
//   * units: 3x fp_add24_spp_ro (4clk, A0/A1/A2), 1x fp_add3_24_spp_ro (4clk, A3),
//     4x fp_mul24_spp_ro (2clk, M0..M3, full 1.23 mantissa), 1x fp_rcp_faster (5clk).
//   * ALL sign handling is a SIGN-BIT FLIP ({~f[31],f[30:0]}), never a multiply:
//     the 8 post-sgn edge deltas, the reused negated diffs (X3-X1 = -(X1-X3), ...),
//     -Aa/-Ba into the ddx/ddy products, and the subtractions folded into A3 addends.
//   * min-magnitude anchors: each edge constant Cn is anchored at the smaller
//     max(|XL|,|YT|) of ITS two endpoints; the invW plane c at the smallest of
//     v1/v2/v3 (same rationale/tournament as isp_setup_min).
//
// QUADS (refsw2 RenderQuadArray -> RasterizeTriangle(v1,v2,v3,&v4)): when `quad` is
// asserted the entry carries a 4th vertex (x4,y4):
//   DX31 = sgn*(X3-X4)  DY31 = sgn*(Y3-Y4)   DX41 = sgn*(X4-X1)  DY41 = sgn*(Y4-Y1)
//   C4   = DY41*XL4a - DX41*YT4a (anchored over v4/v1);  T3/T4 = istl(DX,DY)
// For a TRIANGLE (quad=0) the 4th edge degenerates to the classic fallback:
//   DX31 = sgn*(X3-X1)  DY31 = sgn*(Y3-Y1)  DX41 = DY41 = 0  C4 = 1.0 (no bias)
// The invW plane, tri_area, sign and cull ALWAYS use v1/v2/v3 only (refsw2's
// PlaneStepper3 ignores v4); the bbox includes v4 when quad. v4's Z is never read,
// so there is no z4 port.
//
// -------------------------------------------------------------------------------
// BUFFERING CONTRACT (as tsp_setup_stream): input-UNBUFFERED - the triangle inputs
// feed only the latch registers, sampled on (in_valid && in_ready); the producer
// holds them stable that cycle. Output-BUFFERED - every output is a register.
// (Exception, documented: in_ready is rdy_r AND NOT stall - one gate off two
// registered signals + out_ready - so a retire blocked by !out_ready cannot
// falsely accept a triangle.) Internally every *_spp_ro input comes from a register
// or a registered unit output (live output-bus reads are registered unit outputs).
//
// -------------------------------------------------------------------------------
// PIPELINING MODEL. One 6-bit `cnt` drives the per-triangle FRONT phase (cnt 1..15:
// operand fetch, diffs, area, anchors, sgn). At cnt==15 the triangle's TAIL is handed
// to a 16-deep pulse shift register d[1..16] (+ a parity bit alongside), which keeps
// shifting through latches of LATER triangles - so a new triangle can latch every 15
// cycles while up to two older tails drain. Per-triangle values that must survive
// past the next latch are PING-PONG BANKED [0:1] on a parity bit that alternates per
// latch; the tail taps read their own triangle's bank via the carried parity.
// All bank writes land at relative cnt >= 2 and all reads by relative cnt 31, so two
// banks suffice for any latch spacing >= 15 (next-next triangle's earliest bank
// write is at +30+2 = rel 32 > 31). Unit-issue slots were checked pairwise: within
// each unit the largest slot difference is 13 < 15, so NO structural conflict exists
// for any latch spacing >= 15 either.
//
// Unit latencies (operands/valid registered at end of cnt K -> result y readable
// during cnt K+L+1): mul24 L=2 (read @K+3), add24/add3 L=4 (read @K+5), rcp L=5
// (in_valid during K+1 -> y during K+6). "Live" reads take y exactly at its read cnt.
//
// FRONT (cnt-driven; sel @N -> A-lane result @N+5):
//   sel1: A0=X1-X3    A1=Y2-Y3    A2=Y1-Y3     [@6]
//   sel2: A0=X2-X3    A1=X1-X2    A2=Y1-Y2     [@7]
//   sel3: A0=Z2-Z1    A1=Z3-Z1    A2=X3-Wx     [@8]   (Wv = quad ? v4 : v1)
//   sel4: A0=Y3-Wy    A1=X4-X1    A2=Y4-Y1     [@9]
//   sel5: A0=X1-XB    A1=Y1-YB    A2=X2-XB     [@10]
//   sel6: A0=Y2-YB    A1=X3-XB    A2=Y3-YB     [@11]
//   sel7: A0=X4-XB    A1=Y4-YB                 [@12]
//   @2 bank tag/isp/pt/quad; bbox floors @2, subs @3, min/max @4/@5, clamp+bank @6
//   @7 M0/M1 = area products (P1's X2-X3 read LIVE off A0)      [@10]
//   @9 M0..M3 = Aa/Ba products (negations folded into operands) [@12]
//   @9 area_go: A0 = P0 - P1 (both LIVE off M0/M1)              [@14]
//   @12/@13 A3 = Aa / Ba (products LIVE off M0..M3)             [@17/@18]
//   @13 anchor tournaments; rc_go (rcp x = area LIVE @14 -> rc_y @19)
//   @14 capture area; sgn/cull -> bank; 8 sgn-FLIPPED edge deltas -> bank
//   @15 tl1..4 = istl(DX,DY); M0..M3 = C1/C2 partials (DY*XLa, DX*YTa) [@18]
//   @15 seed tail: d[1] <= 1 (d[i] == relative cnt 15+i)
// TAIL (d-tap driven, parity-banked reads):
//   d1 (16): M0..M3 = C3/C4 partials                            [@19]
//   d2 (17): Aa <= A3.y
//   d3 (18): Ba <= A3.y; A3 = C1 (partials LIVE); hold C2a/C2b
//   d4 (19): A3 = C3 (LIVE); hold C4a/C4b; M0/M1 = ddx/ddy = -Aa*rc_y (rc_y LIVE)
//   d5 (20): A3 = C2 (held)          d6 (21): A3 = C4 (held)
//   d7 (22): ddx/ddy <= M0/M1.y; M2/M3 = ddx*aXL / ddy*aYT (ddx LIVE)  [@25]
//   d8..d11 (23..26): c1/c3/c2/c4 <= A3.y (+top-left -1ulp bias; c4 quad mux)
//   d10 (25): A3 = c_invw = aZ - f0 - f1 (partials LIVE)        [@30]
//   d15 (30): c_invw <= A3.y
//   d16 (31): RETIRE -> all outputs registered, out_valid pulses next cycle.
//
// Latency latch -> out_valid: 32 clks. Sustained throughput: one triangle / 15 clks.
// BACKPRESSURE: if !out_ready at the retire tap, `stall` freezes the WHOLE pipe
// (cnt, d, banks, every spp_ro stage) losslessly until out_ready.
//
module isp_setup_streamed (
    input             clk,
    input             reset,

    // input: accept a triangle when in_valid && in_ready
    input             in_valid,
    output            in_ready,
    input      [31:0] isp_word,
    input      [31:0] in_tag,     // opaque payload carried through
    input             in_pt,      // list-kind (PT) payload carried through
    input             quad,       // 1: entry is a quad (x4/y4 valid)
    input      [31:0] x1, input [31:0] y1, input [31:0] z1,
    input      [31:0] x2, input [31:0] y2, input [31:0] z2,
    input      [31:0] x3, input [31:0] y3, input [31:0] z3,
    input      [31:0] x4, input [31:0] y4,
    input      [31:0] xbase, input [31:0] ybase,

    output            busy,
    input             out_ready,
    output reg        out_valid,
    output reg [31:0] out_tag,
    output reg        out_pt,
    output reg [31:0] out_isp,
    output reg        sgn_neg,
    output reg        cull,
    output reg [31:0] dx12, output reg [31:0] dx23, output reg [31:0] dx31, output reg [31:0] dx41,
    output reg [31:0] dy12, output reg [31:0] dy23, output reg [31:0] dy31, output reg [31:0] dy41,
    output reg [31:0] c1,   output reg [31:0] c2,   output reg [31:0] c3,   output reg [31:0] c4,
    output reg [3:0]  out_tl,   // {tl4,tl3,tl2,tl1}: IsTopLeft per edge (raster compare)
    output reg [31:0] ddx_invw, output reg [31:0] ddy_invw, output reg [31:0] c_invw,
    output reg [4:0]  bx0, output reg [4:0] bx1, output reg [4:0] by0, output reg [4:0] by1
);
    localparam [31:0] ONE = 32'h3f800000, ZERO = 32'd0;

    // ---------------- helpers (identical numerics to isp_setup_min) ----------------
    function fzero(input [31:0] f); fzero=(f[30:0]==31'd0); endfunction
    function fneg (input [31:0] f); fneg = f[31]&&(f[30:0]!=31'd0); endfunction
    function fpos (input [31:0] f); fpos = !f[31]&&(f[30:0]!=31'd0); endfunction
    function istl(input [31:0] fdx, input [31:0] fdy);   // IsTopLeft on sgn-normalized edges
        istl=(fzero(fdy)&&fpos(fdx))||fneg(fdy); endfunction
    function [31:0] fnegf(input [31:0] f); fnegf={~f[31],f[30:0]}; endfunction
    // NOTE on the top-left rule: C is NOT biased. The old "-1 raw ulp on C
    // when not top-left" wrapped C=+0 to 0xFFFFFFFF (-NaN, exponent FF),
    // which dominated every Xhs sum - any tile whose origin lies exactly on
    // a non-top-left edge lost the WHOLE triangle (alternating black 32x32
    // holes along shared fullscreen-quad diagonals, RE:CV intro). And any
    // finite bias washes out of (C + DX*y) vs DY*x depending on per-pixel
    // exponent alignment. So the rule lives in the RASTER compare instead
    // (refsw2 refsw_tile.cpp: inside = Xhs > 0 || (T && Xhs == 0)); setup
    // exports the four T flags on out_tl.
    // NOTE on -0: a flipped zero delta yields -0 (the old mac16 path's add stage
    // normalized these to +0). Harmless: every consumer path (raster Xhs / invW
    // sums) re-derives the sign through an fp adder, and those pack +0 on exact
    // cancellation; istl uses fzero. So no zero-normalizing logic is spent here.
    // anchor magnitude: max(|XL|,|YT|) reduced to biased exponent
    function [7:0] amag(input [31:0] xl, input [31:0] yt);
        amag = (xl[30:23] > yt[30:23]) ? xl[30:23] : yt[30:23]; endfunction

    // ---------------- tile-local bbox (float->int floor), saturated ----------------
    function automatic signed [15:0] f2i_floor(input [31:0] f);
        integer e, sh; reg [31:0] mag; reg [11:0] sat;
        begin
            e = f[30:23] - 127;
            if (f[30:23] == 8'd0 || e < 0) mag = 0;
            else if (e >= 11) mag = 32'h7FFFFFFF;           // |v| >= 2048 -> saturate
            else begin sh = 23 - e; mag = {8'b0, 1'b1, f[22:0]} >> sh; end
            sat = (mag > 32'd2047) ? 12'd2047 : mag[11:0];
            f2i_floor = f[31] ? -{4'b0, sat} : {4'b0, sat};
        end
    endfunction
    function automatic [4:0] clamp5(input signed [15:0] v);
        begin
            if (v < 0) clamp5 = 5'd0; else if (v > 31) clamp5 = 5'd31; else clamp5 = v[4:0];
        end
    endfunction
    function automatic signed [15:0] mn2(input signed [15:0] a, input signed [15:0] b);
        mn2 = (a < b) ? a : b; endfunction
    function automatic signed [15:0] mx2(input signed [15:0] a, input signed [15:0] b);
        mx2 = (a > b) ? a : b; endfunction

    // ================================================================
    // latched triangle (input-unbuffered: written only on latch)
    // ================================================================
    reg [31:0] X1,Y1,Z1, X2,Y2,Z2, X3,Y3,Z3, X4,Y4, XB,YB;
    reg [31:0] ISPW, TAGr;
    reg        PTr, Qr;

    // ================================================================
    // control: front cnt (1..15) + tail pulse SR (d[1..16], parity alongside)
    // ================================================================
    reg        front;
    reg [5:0]  cnt;
    reg        cur_par;            // bank parity of the triangle in the FRONT phase
    reg [16:1] d;                  // d[i] high during relative cnt 15+i
    reg [16:1] dpar;               // that pulse's triangle bank parity
    reg        rdy;

    // retire tap + global lossless freeze on output backpressure
    wire       stall = d[16] && !out_ready;
    assign     in_ready = rdy && !stall;
    wire       latch_now = in_valid && in_ready;
    assign     busy = front || (|d);

    // ================================================================
    // ping-pong BANKED per-triangle results (write rel>=2, read <= rel 31)
    // ================================================================
    reg [31:0] bTAG [0:1], bISP [0:1];
    reg        bPT  [0:1], bQ   [0:1], bSGN [0:1], bCULL[0:1];
    reg [4:0]  bBX0 [0:1], bBX1 [0:1], bBY0 [0:1], bBY1 [0:1];
    reg [31:0] bDX12[0:1], bDX23[0:1], bDX31[0:1], bDX41[0:1];
    reg [31:0] bDY12[0:1], bDY23[0:1], bDY31[0:1], bDY41[0:1];

    // ---------------- single-copy scratch (lifetime < 15 verified per value) -------
    reg [31:0] dX1X3,dY2Y3,dY1Y3;          // @6
    reg [31:0] dX2X3,dX1X2,dY1Y2;          // @7
    reg [31:0] dZ2Z1,dZ3Z1,dX3W;           // @8
    reg [31:0] dY3W,dX41d,dY41d;           // @9
    reg [31:0] XL1,YT1,XL2;                // @10
    reg [31:0] YT2,XL3,YT3;                // @11
    reg [31:0] XL4,YT4;                    // @12
    reg [31:0] e1XL,e1YT, e2XL,e2YT, e3XL,e3YT, e4XL,e4YT;   // @13, read <= @16
    reg [31:0] aZ,aXL,aYT;                 // @13, read <= @25
    reg        tl1,tl2,tl3,tl4;            // @15, read <= @26
    reg [3:0]  sc_tl;                      // {tl4,tl3,tl2,tl1} captured @23 for retire
    reg [31:0] Aa,Ba;                      // @17/@18, read @19
    reg [31:0] C2a,C2b, C4a,C4b;           // @18/@19, read @20/@21
    reg [31:0] ddx,ddy;                    // @22, read @31
    reg [31:0] sc_c1,sc_c2,sc_c3,sc_c4;    // @23..26, read @31
    reg [31:0] sc_cinvw;                   // @30, read @31

    // ---------------- bbox pipeline (front phase) ----------------
    // Five shallow stages (@2 floors, @3 origin subs, @4 pairwise min/max, @5 final
    // min/max, @6 clamp+bank): floor's barrel shift, the 16-bit subtract, the quad
    // mux and the compare tree each get their own reg-to-reg hop - the fused
    // floor+sub+mux version missed 100 MHz by ~1.2 ns.
    reg signed [15:0] fX1r,fX2r,fX3r,fX4r, fY1r,fY2r,fY3r,fY4r, fXBr,fYBr;
    reg signed [15:0] lXa,lXb,lXc,lXd, lYa,lYb,lYc,lYd;
    reg signed [15:0] bxmnab,bxmncd,bxmxab,bxmxcd, bymnab,bymncd,bymxab,bymxcd;
    reg signed [15:0] bxmn,bxmx,bymn,bymx;

    // ================================================================
    // A0/A1/A2 subtract lanes: GEO operand REGISTER (sel @N -> issue @N+1) so the
    // wide cnt-mux is off the adder S1 path. A0 doubles as the area subtract via
    // the registered area_go_r pulse (operands read LIVE off M0/M1).
    // ================================================================
    reg [31:0] g0a_c,g0b_c, g1a_c,g1b_c, g2a_c,g2b_c;
    reg        g0v_c,g1v_c,g2v_c;
    wire [31:0] Wx = Qr ? X4 : X1;
    wire [31:0] Wy = Qr ? Y4 : Y1;
    always @(*) begin
        g0a_c=X1; g0b_c=X3; g1a_c=Y2; g1b_c=Y3; g2a_c=Y1; g2b_c=Y3;
        g0v_c=1'b0; g1v_c=1'b0; g2v_c=1'b0;
        case (cnt)
            6'd1: begin g0a_c=X1;g0b_c=X3;g0v_c=1;  g1a_c=Y2;g1b_c=Y3;g1v_c=1;  g2a_c=Y1;g2b_c=Y3;g2v_c=1; end
            6'd2: begin g0a_c=X2;g0b_c=X3;g0v_c=1;  g1a_c=X1;g1b_c=X2;g1v_c=1;  g2a_c=Y1;g2b_c=Y2;g2v_c=1; end
            6'd3: begin g0a_c=Z2;g0b_c=Z1;g0v_c=1;  g1a_c=Z3;g1b_c=Z1;g1v_c=1;  g2a_c=X3;g2b_c=Wx;g2v_c=1; end
            6'd4: begin g0a_c=Y3;g0b_c=Wy;g0v_c=1;  g1a_c=X4;g1b_c=X1;g1v_c=1;  g2a_c=Y4;g2b_c=Y1;g2v_c=1; end
            6'd5: begin g0a_c=X1;g0b_c=XB;g0v_c=1;  g1a_c=Y1;g1b_c=YB;g1v_c=1;  g2a_c=X2;g2b_c=XB;g2v_c=1; end
            6'd6: begin g0a_c=Y2;g0b_c=YB;g0v_c=1;  g1a_c=X3;g1b_c=XB;g1v_c=1;  g2a_c=Y3;g2b_c=YB;g2v_c=1; end
            6'd7: begin g0a_c=X4;g0b_c=XB;g0v_c=1;  g1a_c=Y4;g1b_c=YB;g1v_c=1; end
            default: ;
        endcase
    end
    reg [31:0] g0a_r,g0b_r, g1a_r,g1b_r, g2a_r,g2b_r;
    reg        g0v_r,g1v_r,g2v_r;
    reg        area_go_r;

    wire [31:0] a0_y,a1_y,a2_y;
    fp_add24_spp_ro A0 (.clk(clk),.reset(reset),.stall(stall),.in_valid(g0v_r || area_go_r),
        .a(area_go_r ? m0_y : g0a_r), .b_in(area_go_r ? m1_y : g0b_r), .sub(1'b1),
        .out_valid(), .y(a0_y));
    fp_add24_spp_ro A1 (.clk(clk),.reset(reset),.stall(stall),.in_valid(g1v_r),
        .a(g1a_r), .b_in(g1b_r), .sub(1'b1), .out_valid(), .y(a1_y));
    fp_add24_spp_ro A2 (.clk(clk),.reset(reset),.stall(stall),.in_valid(g2v_r),
        .a(g2a_r), .b_in(g2b_r), .sub(1'b1), .out_valid(), .y(a2_y));

    // ================================================================
    // M0..M3 multiplier lanes (operands pre-registered)
    // ================================================================
    reg [31:0] m0a,m0b, m1a,m1b, m2a,m2b, m3a,m3b;
    reg        m0v,m1v,m2v,m3v;
    wire [31:0] m0_y,m1_y,m2_y,m3_y;
    fp_mul24_spp_ro M0 (.clk(clk),.reset(reset),.stall(stall),.in_valid(m0v),.a(m0a),.b(m0b),.out_valid(),.y(m0_y));
    fp_mul24_spp_ro M1 (.clk(clk),.reset(reset),.stall(stall),.in_valid(m1v),.a(m1a),.b(m1b),.out_valid(),.y(m1_y));
    fp_mul24_spp_ro M2 (.clk(clk),.reset(reset),.stall(stall),.in_valid(m2v),.a(m2a),.b(m2b),.out_valid(),.y(m2_y));
    fp_mul24_spp_ro M3 (.clk(clk),.reset(reset),.stall(stall),.in_valid(m3v),.a(m3a),.b(m3b),.out_valid(),.y(m3_y));

    // ================================================================
    // A3: 3-input add - Aa, Ba, C1..C4, c_invw (7 issues, slots verified disjoint)
    // ================================================================
    reg [31:0] a3a,a3b,a3c; reg a3v;
    wire [31:0] a3_y;
    fp_add3_24_spp_ro A3 (.clk(clk),.reset(reset),.stall(stall),.in_valid(a3v),
        .a(a3a),.b(a3b),.c(a3c),.out_valid(),.y(a3_y));

    // ================================================================
    // reciprocal 1/tri_area (x = area LIVE off A0 during the rc_go_r cycle)
    // ================================================================
    reg  rc_go_r;
    wire [31:0] rc_y;
    fp_rcp_faster u_rcp (.clk(clk),.reset(reset),.stall(stall),
        .in_valid(rc_go_r), .x(a0_y), .out_valid(), .y(rc_y));

    integer i;
    always @(posedge clk) begin
        if (reset) begin
            front<=0; cnt<=0; cur_par<=0; d<='0; dpar<='0; rdy<=1'b1; out_valid<=0;
            g0v_r<=0; g1v_r<=0; g2v_r<=0; m0v<=0; m1v<=0; m2v<=0; m3v<=0; a3v<=0;
            area_go_r<=0; rc_go_r<=0;
        end else begin
            out_valid <= 1'b0;
            if (!stall) begin
                // ---- handshake: rdy asserts during cnt 15 (earliest re-latch), so
                //      consecutive latches are >= 15 apart; when idle it stays high. ----
                if (latch_now)                 rdy <= 1'b0;
                else if (front && cnt==6'd14)  rdy <= 1'b1;

                // ---- latch a new triangle (flip the bank parity for it) ----
                if (latch_now) begin
                    X1<=x1;Y1<=y1;Z1<=z1; X2<=x2;Y2<=y2;Z2<=z2; X3<=x3;Y3<=y3;Z3<=z3;
                    X4<=x4;Y4<=y4; XB<=xbase;YB<=ybase;
                    ISPW<=isp_word; TAGr<=in_tag; PTr<=in_pt; Qr<=quad;
                    cur_par <= ~cur_par;
                    front<=1'b1; cnt<=6'd1;
                end else begin
                    if (front && cnt==6'd15) front<=1'b0;
                    cnt <= (cnt==6'd63) ? cnt : cnt+6'd1;
                end

                // ---- tail pulse SR: seed at cnt15, shift EVERY (unstalled) clock ----
                d[1]    <= front && (cnt==6'd15);
                dpar[1] <= cur_par;
                for (i=2; i<=16; i=i+1) begin d[i]<=d[i-1]; dpar[i]<=dpar[i-1]; end

                // ---- GEO subtract operand registration (sel N -> issue N+1) ----
                g0a_r<=g0a_c; g0b_r<=g0b_c; g0v_r<=g0v_c && front;
                g1a_r<=g1a_c; g1b_r<=g1b_c; g1v_r<=g1v_c && front;
                g2a_r<=g2a_c; g2b_r<=g2b_c; g2v_r<=g2v_c && front;
                area_go_r <= front && (cnt==6'd9);    // A0 area sub in @10 -> y @14
                rc_go_r   <= front && (cnt==6'd13);   // rcp in @14 (x=area live) -> y @19

                if (front) begin
                    // ---- FRONT captures ----
                    if (cnt==6'd6)  begin dX1X3<=a0_y; dY2Y3<=a1_y; dY1Y3<=a2_y; end
                    if (cnt==6'd7)  begin dX2X3<=a0_y; dX1X2<=a1_y; dY1Y2<=a2_y; end
                    if (cnt==6'd8)  begin dZ2Z1<=a0_y; dZ3Z1<=a1_y; dX3W<=a2_y; end
                    if (cnt==6'd9)  begin dY3W<=a0_y; dX41d<=a1_y; dY41d<=a2_y; end
                    if (cnt==6'd10) begin XL1<=a0_y; YT1<=a1_y; XL2<=a2_y; end
                    if (cnt==6'd11) begin YT2<=a0_y; XL3<=a1_y; YT3<=a2_y; end
                    if (cnt==6'd12) begin XL4<=a0_y; YT4<=a1_y; end

                    // ---- payload bank (rel 2: latch regs -> bank, survives re-latch) ----
                    if (cnt==6'd2) begin
                        bTAG[cur_par]<=TAGr; bISP[cur_par]<=ISPW;
                        bPT[cur_par]<=PTr;   bQ[cur_par]<=Qr;
                    end

                    // ---- bbox: floors @2, origin subs (+quad mux) @3, pairwise
                    //      min/max @4, final min/max @5, clamp+bank @6 ----
                    if (cnt==6'd2) begin
                        fX1r<=f2i_floor(X1); fX2r<=f2i_floor(X2);
                        fX3r<=f2i_floor(X3); fX4r<=f2i_floor(X4);
                        fY1r<=f2i_floor(Y1); fY2r<=f2i_floor(Y2);
                        fY3r<=f2i_floor(Y3); fY4r<=f2i_floor(Y4);
                        fXBr<=f2i_floor(XB); fYBr<=f2i_floor(YB);
                    end
                    if (cnt==6'd3) begin
                        lXa<=fX1r-fXBr; lXb<=fX2r-fXBr; lXc<=fX3r-fXBr;
                        lXd<=(Qr ? fX4r : fX1r)-fXBr;
                        lYa<=fY1r-fYBr; lYb<=fY2r-fYBr; lYc<=fY3r-fYBr;
                        lYd<=(Qr ? fY4r : fY1r)-fYBr;
                    end
                    if (cnt==6'd4) begin
                        bxmnab<=mn2(lXa,lXb); bxmncd<=mn2(lXc,lXd);
                        bxmxab<=mx2(lXa,lXb); bxmxcd<=mx2(lXc,lXd);
                        bymnab<=mn2(lYa,lYb); bymncd<=mn2(lYc,lYd);
                        bymxab<=mx2(lYa,lYb); bymxcd<=mx2(lYc,lYd);
                    end
                    if (cnt==6'd5) begin
                        bxmn<=mn2(bxmnab,bxmncd); bxmx<=mx2(bxmxab,bxmxcd);
                        bymn<=mn2(bymnab,bymncd); bymx<=mx2(bymxab,bymxcd);
                    end
                    if (cnt==6'd6) begin
                        bBX0[cur_par]<=clamp5(bxmn); bBX1[cur_par]<=clamp5(bxmx+16'sd1);
                        bBY0[cur_par]<=clamp5(bymn); bBY1[cur_par]<=clamp5(bymx+16'sd1);
                    end

                    // ---- anchors @13 (all XL/YT visible; Z1..Z3 still this triangle's) ----
                    if (cnt==6'd13) begin
                        // per-edge min-mag anchor: smaller max(|XL|,|YT|) of the edge's ends
                        if (amag(XL2,YT2)<amag(XL1,YT1)) begin e1XL<=XL2;e1YT<=YT2; end
                        else                             begin e1XL<=XL1;e1YT<=YT1; end
                        if (amag(XL3,YT3)<amag(XL2,YT2)) begin e2XL<=XL3;e2YT<=YT3; end
                        else                             begin e2XL<=XL2;e2YT<=YT2; end
                        if (Qr) begin   // edge3 = v3..v4 for quads, v3..v1 for tris
                            if (amag(XL4,YT4)<amag(XL3,YT3)) begin e3XL<=XL4;e3YT<=YT4; end
                            else                             begin e3XL<=XL3;e3YT<=YT3; end
                        end else begin
                            if (amag(XL1,YT1)<amag(XL3,YT3)) begin e3XL<=XL1;e3YT<=YT1; end
                            else                             begin e3XL<=XL3;e3YT<=YT3; end
                        end
                        if (amag(XL1,YT1)<amag(XL4,YT4)) begin e4XL<=XL1;e4YT<=YT1; end
                        else                             begin e4XL<=XL4;e4YT<=YT4; end
                        // invW plane anchor: min over v1/v2/v3 (same priority as setup_min)
                        if (amag(XL2,YT2)<amag(XL1,YT1) && amag(XL2,YT2)<=amag(XL3,YT3)) begin
                            aZ<=Z2; aXL<=XL2; aYT<=YT2;
                        end else if (amag(XL3,YT3)<amag(XL1,YT1)) begin
                            aZ<=Z3; aXL<=XL3; aYT<=YT3;
                        end else begin
                            aZ<=Z1; aXL<=XL1; aYT<=YT1;
                        end
                    end

                    // ---- @14: area LIVE on a0_y -> sign, cull, sgn-FLIPPED edges (bank) ----
                    if (cnt==6'd14) begin
                        bSGN[cur_par] <= fpos(a0_y);
                        begin : cb
                          reg [1:0] cm; reg wrong;
                          cm=ISPW[28:27];
                          wrong=(cm[0]==1'b0&&fneg(a0_y))||(cm[0]==1'b1&&fpos(a0_y));
                          bCULL[cur_par]<=(cm>=2'd2)&&wrong;
                        end
                        // sgn = -1 iff area > 0: pure sign-bit flips, NO multiplies
                        bDX12[cur_par] <= fpos(a0_y) ? fnegf(dX1X2) : dX1X2;
                        bDX23[cur_par] <= fpos(a0_y) ? fnegf(dX2X3) : dX2X3;
                        bDX31[cur_par] <= fpos(a0_y) ? fnegf(dX3W)  : dX3W;
                        bDX41[cur_par] <= Qr ? (fpos(a0_y) ? fnegf(dX41d) : dX41d) : ZERO;
                        bDY12[cur_par] <= fpos(a0_y) ? fnegf(dY1Y2) : dY1Y2;
                        bDY23[cur_par] <= fpos(a0_y) ? fnegf(dY2Y3) : dY2Y3;
                        bDY31[cur_par] <= fpos(a0_y) ? fnegf(dY3W)  : dY3W;
                        bDY41[cur_par] <= Qr ? (fpos(a0_y) ? fnegf(dY41d) : dY41d) : ZERO;
                    end
                    // ---- @15: top-left flags on the sgn-normalized edges ----
                    if (cnt==6'd15) begin
                        tl1<=istl(bDX12[cur_par],bDY12[cur_par]);
                        tl2<=istl(bDX23[cur_par],bDY23[cur_par]);
                        tl3<=istl(bDX31[cur_par],bDY31[cur_par]);
                        tl4<=istl(bDX41[cur_par],bDY41[cur_par]);
                    end
                end

                // ================= multiplier issue (front + tail) =================
                m0v<=1'b0; m1v<=1'b0; m2v<=1'b0; m3v<=1'b0;
                // @7: area products P0=(X1-X3)(Y2-Y3), P1=(Y1-Y3)(X2-X3); the X2-X3
                //     diff lands THIS cycle -> read it LIVE off A0. [y @10]
                if (front && cnt==6'd7) begin
                    m0a<=dX1X3; m0b<=dY2Y3; m0v<=1'b1;
                    m1a<=dY1Y3; m1b<=a0_y;  m1v<=1'b1;
                end
                // @9: Aa/Ba products, negations folded into operands (sign flips only):
                //     Aa = (z3-z1)(Y2-Y1) + (z1-z2)(Y3-Y1)
                //     Ba = (X3-X1)(z2-z1) + (X1-X2)(z3-z1)      [y @12]
                if (front && cnt==6'd9) begin
                    m0a<=dZ3Z1;        m0b<=fnegf(dY1Y2); m0v<=1'b1;
                    m1a<=fnegf(dZ2Z1); m1b<=fnegf(dY1Y3); m1v<=1'b1;
                    m2a<=fnegf(dX1X3); m2b<=dZ2Z1;        m2v<=1'b1;
                    m3a<=dX1X2;        m3b<=dZ3Z1;        m3v<=1'b1;
                end
                // @15: C1/C2 partials (edges 1,2)  [y @18]
                if (front && cnt==6'd15) begin
                    m0a<=bDY12[cur_par]; m0b<=e1XL; m0v<=1'b1;
                    m1a<=bDX12[cur_par]; m1b<=e1YT; m1v<=1'b1;
                    m2a<=bDY23[cur_par]; m2b<=e2XL; m2v<=1'b1;
                    m3a<=bDX23[cur_par]; m3b<=e2YT; m3v<=1'b1;
                end
                // d1 (16): C3/C4 partials (edges 3,4)  [y @19]
                if (d[1]) begin
                    m0a<=bDY31[dpar[1]]; m0b<=e3XL; m0v<=1'b1;
                    m1a<=bDX31[dpar[1]]; m1b<=e3YT; m1v<=1'b1;
                    m2a<=bDY41[dpar[1]]; m2b<=e4XL; m2v<=1'b1;
                    m3a<=bDX41[dpar[1]]; m3b<=e4YT; m3v<=1'b1;
                end
                // d4 (19): ddx/ddy = -Aa*rcy / -Ba*rcy (rc_y LIVE this cycle)  [y @22]
                if (d[4]) begin
                    m0a<=fnegf(Aa); m0b<=rc_y; m0v<=1'b1;
                    m1a<=fnegf(Ba); m1b<=rc_y; m1v<=1'b1;
                end
                // d7 (22): c_invw partials ddx*aXL / ddy*aYT (ddx/ddy LIVE)  [y @25]
                if (d[7]) begin
                    ddx<=m0_y; ddy<=m1_y;
                    m2a<=m0_y; m2b<=aXL; m2v<=1'b1;
                    m3a<=m1_y; m3b<=aYT; m3v<=1'b1;
                end

                // ================= A3 issue (front + tail; slots disjoint) =================
                a3v<=1'b0;
                if (front && cnt==6'd12) begin a3a<=m0_y; a3b<=m1_y; a3c<=ZERO; a3v<=1'b1; end // Aa [y @17]
                if (front && cnt==6'd13) begin a3a<=m2_y; a3b<=m3_y; a3c<=ZERO; a3v<=1'b1; end // Ba [y @18]
                if (d[3])  begin a3a<=m0_y; a3b<=fnegf(m1_y); a3c<=ZERO; a3v<=1'b1;            // C1 [y @23]
                                 C2a<=m2_y; C2b<=m3_y; end
                if (d[4])  begin a3a<=m0_y; a3b<=fnegf(m1_y); a3c<=ZERO; a3v<=1'b1;            // C3 [y @24]
                                 C4a<=m2_y; C4b<=m3_y; end
                if (d[5])  begin a3a<=C2a; a3b<=fnegf(C2b); a3c<=ZERO; a3v<=1'b1; end          // C2 [y @25]
                if (d[6])  begin a3a<=C4a; a3b<=fnegf(C4b); a3c<=ZERO; a3v<=1'b1; end          // C4 [y @26]
                if (d[10]) begin a3a<=aZ; a3b<=fnegf(m2_y); a3c<=fnegf(m3_y); a3v<=1'b1; end   // c_invw [y @30]

                // ---- A3 result captures ----
                if (d[2])  Aa<=a3_y;
                if (d[3])  Ba<=a3_y;
                // edge constants: EXACT (top-left rule is in the raster
                // compare via out_tl - see the note at fnegf)
                if (d[8])  begin sc_c1 <= a3_y; sc_tl <= {tl4, tl3, tl2, tl1}; end
                if (d[9])  sc_c3 <= a3_y;
                if (d[10]) sc_c2 <= a3_y;
                if (d[11]) sc_c4 <= bQ[dpar[11]] ? a3_y : ONE;
                if (d[15]) sc_cinvw <= a3_y;

                // ================= retire (d16, rel 31) =================
                if (d[16]) begin
                    out_valid <= 1'b1;
                    out_tag <= bTAG[dpar[16]]; out_isp <= bISP[dpar[16]];
                    out_pt  <= bPT [dpar[16]];
                    sgn_neg <= bSGN[dpar[16]]; cull    <= bCULL[dpar[16]];
                    dx12<=bDX12[dpar[16]]; dx23<=bDX23[dpar[16]];
                    dx31<=bDX31[dpar[16]]; dx41<=bDX41[dpar[16]];
                    dy12<=bDY12[dpar[16]]; dy23<=bDY23[dpar[16]];
                    dy31<=bDY31[dpar[16]]; dy41<=bDY41[dpar[16]];
                    c1<=sc_c1; c2<=sc_c2; c3<=sc_c3; c4<=sc_c4;
                    out_tl<=sc_tl;
                    ddx_invw<=ddx; ddy_invw<=ddy; c_invw<=sc_cinvw;
                    bx0<=bBX0[dpar[16]]; bx1<=bBX1[dpar[16]];
                    by0<=bBY0[dpar[16]]; by1<=bBY1[dpar[16]];
                end
            end
        end
    end
endmodule

//
// tsp_setup_stream - STREAMED (II=4) replacement for tsp_setup_min.
//
// Same math (refsw IPs3::Setup), same ports, but a throughput pipeline: one plane
// enters every 4 clocks (II=4), so a 10-plane triangle streams in ~40 clocks +
// fill/drain instead of the old 2-context state machine's ~257.
//
// A per-triangle GEO preamble computes the shared constants (edge deltas, tile anchors,
// area, 1/area) once; then enabled planes stream through a 7-stage pipeline that advances
// one stage every 4-clock "window". Within a window, the datapath is time-shared across
// the stages (each stage holds a DIFFERENT plane, so every op reads that stage's stable
// registers -> all ops in the window are independent).
//
// Micro-schedule (window phases 0..3; the pipeline ADVANCES at ph==3 = "tick"). To avoid
// a capture-vs-advance race, units are DRIVEN only at ph0/ph1 (their combinational result
// is captured at ph1/ph2, both stable by the ph3 tick); ph2/ph3 are idle slack.
//   4x fp_mul16  (mg0..3) : ph0 -> mC[0..3]      ph1 -> ddx,ddy,f0,f1
//   2x fp_mul16  (pmA,B)  : prime uv (z*uv)                (only for U/V planes)
//   2x fp_mul_c9 (pcA,B)  : prime colour (z*chan)          (only for col/ofs planes)
//   2x fp_add24  (aX,aY)  : ph0 -> da2,da3        ph1 -> Aa,Ba
//   1x fp_add3_24 (a3)    : ph0 -> c = a1 - ddx*XL1 - ddy*YT1   (folds the old t/c 2-step)
//   1x fp_rcp_fast        : 1/area (once/triangle)
// mg0/mg1 are reused for the GEO area products (pipeline empty in the preamble).
//
// The clean direct adds + the 3-way c (single normalize) are slightly MORE accurate than
// the old unit's *1.0-mac chains, so outputs differ in the low mantissa bits (validated
// to <1e-3 relative error vs the old unit on 48320 real menu2 planes).
//
// Pipeline stages (a plane advances one per window):
//   S0 prime : p1,p2,p3 = z_i*attr_i
//   S1 da    : da2=p2-p1, da3=p3-p1
//   S2 mC    : c0=da3*Y2Y1 c1=da2*Y3Y1 c2=X3X1*da2 c3=X2X1*da3
//   S3 AaBa  : Aa=c0-c1, Ba=c2-c3
//   S4 ddxy  : ddx=-Aa*rcy, ddy=-Ba*rcy
//   S5 mF    : f0=ddx*XL1, f1=ddy*YT1
//   S6 c     : c=a1-f0-f1  -> EMIT
//
module tsp_setup_stream (
    input             clk,
    input             reset,
    input             start,
    output reg        done,

    input             gouraud,
    input             texture,
    input             offset,

    input      [31:0] x1,y1,z1, x2,y2,z2, x3,y3,z3,
    input      [31:0] xbase, ybase,
    input      [31:0] u1,v1, u2,v2, u3,v3,
    input      [31:0] col1,col2,col3,
    input      [31:0] ofs1,ofs2,ofs3,

    output reg        plane_valid,
    output reg [3:0]  plane_idx,
    output reg [31:0] o_ddx, output reg [31:0] o_ddy, output reg [31:0] o_c
);
    function [31:0] fneg(input [31:0] f); fneg = {~f[31], f[30:0]}; endfunction
    function signed [8:0] chan(input [31:0] c, input [1:0] ch);
        case (ch) 0:chan=$signed({1'b0,c[7:0]});   1:chan=$signed({1'b0,c[15:8]});
                  2:chan=$signed({1'b0,c[23:16]}); 3:chan=$signed({1'b0,c[31:24]}); endcase
    endfunction

    // ---------------- latched triangle ----------------
    reg [31:0] Z [0:2];
    reg [31:0] U [0:2], V [0:2], CO [0:2], OF [0:2];
    reg [31:0] XB, YB, Xv[0:2], Yv[0:2];
    reg        g_r, tex_r, ofs_r;

    // ---------------- per-triangle GEO constants ----------------
    reg [31:0] Y2Y1, Y3Y1, X3X1, X2X1, XL1, YT1, rcy;

    // ================= shared combinational arithmetic =================
    reg  [31:0] mg0a,mg0b, mg1a,mg1b, mg2a,mg2b, mg3a,mg3b;
    wire [31:0] mg0y,mg1y,mg2y,mg3y;
    fp_mul16 u_mg0 (.a(mg0a), .b(mg0b), .y(mg0y));
    fp_mul16 u_mg1 (.a(mg1a), .b(mg1b), .y(mg1y));
    fp_mul16 u_mg2 (.a(mg2a), .b(mg2b), .y(mg2y));
    fp_mul16 u_mg3 (.a(mg3a), .b(mg3b), .y(mg3y));

    reg  [31:0] pmAa,pmAb, pmBa,pmBb;  wire [31:0] pmAy,pmBy;
    fp_mul16 u_pmA (.a(pmAa), .b(pmAb), .y(pmAy));
    fp_mul16 u_pmB (.a(pmBa), .b(pmBb), .y(pmBy));
    reg  [31:0] pcAf,pcBf; reg signed [8:0] pcAk,pcBk;  wire [31:0] pcAy,pcBy;
    fp_mul_c9 u_pcA (.f(pcAf), .k(pcAk), .y(pcAy));
    fp_mul_c9 u_pcB (.f(pcBf), .k(pcBk), .y(pcBy));

    reg  [31:0] aXa,aXb; reg aXs;  wire [31:0] aXy;
    reg  [31:0] aYa,aYb; reg aYs;  wire [31:0] aYy;
    fp_add24 u_aX (.a(aXa), .b_in(aXb), .sub(aXs), .y(aXy));
    fp_add24 u_aY (.a(aYa), .b_in(aYb), .sub(aYs), .y(aYy));
    reg  [31:0] a3a,a3b,a3c;  wire [31:0] a3y;
    fp_add3_24 u_a3 (.a(a3a), .b(a3b), .c(a3c), .y(a3y));

    // GEO delta adders. The old unit routed the FIRST operand through mac16's *1.0, which
    // truncates its mantissa to 15 bits (t15 below); we match that so the deltas -> area ->
    // rc_y -> mC -> Aa/Ba -> ddx/ddy are BIT-EXACT to the old unit (the tiny delta diff
    // would otherwise be amplified by the Aa=mC0-mC1 cancellation into large ddx error).
    function [31:0] t15(input [31:0] x); t15 = {x[31:8], 8'b0}; endfunction
    wire [31:0] d_y2y1,d_y3y1,d_x3x1,d_x2x1,d_xl1,d_yt1;
    fp_add24 gd0 (.a(t15(Yv[1])), .b_in(Yv[0]), .sub(1'b1), .y(d_y2y1));
    fp_add24 gd1 (.a(t15(Yv[2])), .b_in(Yv[0]), .sub(1'b1), .y(d_y3y1));
    fp_add24 gd2 (.a(t15(Xv[2])), .b_in(Xv[0]), .sub(1'b1), .y(d_x3x1));
    fp_add24 gd3 (.a(t15(Xv[1])), .b_in(Xv[0]), .sub(1'b1), .y(d_x2x1));
    fp_add24 gd4 (.a(t15(Xv[0])), .b_in(XB),    .sub(1'b1), .y(d_xl1));
    fp_add24 gd5 (.a(t15(Yv[0])), .b_in(YB),    .sub(1'b1), .y(d_yt1));
    // area = X2X1*Y3Y1 - X3X1*Y2Y1 (products on mg0/mg1 in preamble, dedicated sub)
    wire [31:0] area_w;
    fp_add24 ga (.a(mg0y), .b_in(mg1y), .sub(1'b1), .y(area_w));

    reg        rc_req; reg [31:0] rc_in; wire rc_ack; wire [31:0] rc_y;
    fp_rcp_fast u_rcp (.clk(clk),.reset(reset),.stall(1'b0),.in_valid(rc_req),.x(rc_in),
                       .out_valid(rc_ack),.y(rc_y));

    // ================= top FSM =================
    localparam G_IDLE=0, G_DELT=1, G_AREA=2, G_AMUL=3, G_RCP=4, G_STREAM=5;
    reg [2:0] gs;
    reg [1:0] ph;
    wire tick = (gs==G_STREAM) && (ph==2'd3);

    // ---------------- plane sequencer ----------------
    reg [3:0] nextp;
    function plane_en(input [3:0] i);
        plane_en = (i<=1) ? tex_r : (i<=5) ? 1'b1 : ofs_r; endfunction
    reg [3:0] inj_idx; reg inj_v; integer pp;
    always @(*) begin
        inj_idx = 4'd10; inj_v = 1'b0;
        for (pp = 9; pp >= 0; pp = pp - 1)
            if (pp >= nextp && plane_en(pp[3:0])) begin inj_idx = pp[3:0]; inj_v = 1'b1; end
    end
    wire       inj_uv  = (inj_idx <= 4'd1);
    // colour/offset channel = plane-2 (col 2..5 -> 0..3) or plane-6 (ofs 6..9 -> 0..3);
    // (inj_idx-2)&3 covers both (6..9 - 2 = 4..7, &3 = 0..3).
    wire [1:0] inj_chn = inj_idx[1:0] - 2'd2;

    // ---------------- pipeline stage registers ----------------
    reg        sv0,sv1,sv2,sv3,sv4,sv5;
    reg [3:0]  i0,i1,i2,i3,i4,i5;
    reg [31:0] s0p1,s0p2,s0p3;
    reg [31:0] s1da2,s1da3,s1p1;
    reg [31:0] s2c0,s2c1,s2c2,s2c3,s2p1;
    reg [31:0] s3aa,s3ba,s3p1;
    reg [31:0] s4dx,s4dy,s4p1;
    reg [31:0] s5dx,s5dy,s5f0,s5f1,s5p1;

    // capture regs (t*): written at ph1/ph2, consumed by the ph3 advance
    reg [31:0] tc0,tc1,tc2,tc3, tdx,tdy, tf0,tf1;
    reg [31:0] tda2,tda3, taa,tba, tc;
    reg [31:0] tp1,tp2,tp3;

    // prime attr for the entering plane, per vertex ph (drive uses these)
    // uv float:
    function [31:0] uvsel(input [1:0] vph); uvsel = (inj_idx==4'd0) ? U[vph] : V[vph]; endfunction
    // colour/offset word (gouraud -> per-vertex, flat -> vertex 3):
    function [31:0] colsel(input [1:0] vph);
        colsel = (inj_idx<=4'd5) ? (g_r ? CO[vph] : CO[2]) : (g_r ? OF[vph] : OF[2]);
    endfunction

    // =========================================================================
    always @(posedge clk) begin
        if (reset) begin
            gs<=G_IDLE; done<=0; plane_valid<=0; rc_req<=0; ph<=0;
            sv0<=0;sv1<=0;sv2<=0;sv3<=0;sv4<=0;sv5<=0;
        end else begin
            done<=0; plane_valid<=0; rc_req<=0;

            case (gs)
            G_IDLE: if (start) begin
                Z[0]<=z1;Z[1]<=z2;Z[2]<=z3;
                Xv[0]<=x1;Xv[1]<=x2;Xv[2]<=x3; Yv[0]<=y1;Yv[1]<=y2;Yv[2]<=y3;
                U[0]<=u1;U[1]<=u2;U[2]<=u3; V[0]<=v1;V[1]<=v2;V[2]<=v3;
                CO[0]<=col1;CO[1]<=col2;CO[2]<=col3; OF[0]<=ofs1;OF[1]<=ofs2;OF[2]<=ofs3;
                XB<=xbase; YB<=ybase; g_r<=gouraud; tex_r<=texture; ofs_r<=offset;
                gs<=G_DELT;
            end
            G_DELT: begin
                Y2Y1<=d_y2y1; Y3Y1<=d_y3y1; X3X1<=d_x3x1; X2X1<=d_x2x1;
                XL1 <=d_xl1;  YT1 <=d_yt1;
                gs<=G_AREA;
            end
            G_AREA: begin
                // drive the two area products on mg0/mg1 (pipeline empty here)
                mg0a<=X2X1; mg0b<=Y3Y1; mg1a<=X3X1; mg1b<=Y2Y1;
                gs<=G_AMUL;
            end
            G_AMUL: begin
                // products ready (mg0y,mg1y) -> area_w = mg0y-mg1y ; request reciprocal
                rc_in<=area_w; rc_req<=1'b1;
                gs<=G_RCP;
            end
            G_RCP: if (rc_ack) begin
                rcy<=rc_y;
                nextp<=0; ph<=0;
                sv0<=0;sv1<=0;sv2<=0;sv3<=0;sv4<=0;sv5<=0;
                gs<=G_STREAM;
            end

            G_STREAM: begin
                ph <= ph + 2'd1;

                // ---- DRIVE units (ph0, ph1 only; ph2/ph3 idle) ----
                if (ph==2'd0) begin
                    // geo mC (S1->S2)
                    mg0a<=s1da3; mg0b<=Y2Y1; mg1a<=s1da2; mg1b<=Y3Y1;
                    mg2a<=X3X1;  mg2b<=s1da2; mg3a<=X2X1; mg3b<=s1da3;
                    // adds da2,da3 (S0->S1)
                    aXa<=s0p2; aXb<=s0p1; aXs<=1'b1;
                    aYa<=s0p3; aYb<=s0p1; aYs<=1'b1;
                    // prime v1,v2 (entering plane)
                    pmAa<=Z[0]; pmAb<=uvsel(0);  pmBa<=Z[1]; pmBb<=uvsel(1);
                    pcAf<=Z[0]; pcAk<=chan(colsel(0),inj_chn);
                    pcBf<=Z[1]; pcBk<=chan(colsel(1),inj_chn);
                    // 3-way c (S5->S6)
                    a3a<=s5p1; a3b<=fneg(s5f0); a3c<=fneg(s5f1);
                end else if (ph==2'd1) begin
                    // geo ddx,ddy (S3->S4) + f0,f1 (S4->S5)
                    mg0a<=fneg(s3aa); mg0b<=rcy; mg1a<=fneg(s3ba); mg1b<=rcy;
                    mg2a<=s4dx; mg2b<=XL1;  mg3a<=s4dy; mg3b<=YT1;
                    // adds Aa,Ba (S2->S3)
                    aXa<=s2c0; aXb<=s2c1; aXs<=1'b1;
                    aYa<=s2c2; aYb<=s2c3; aYs<=1'b1;
                    // prime v3
                    pmAa<=Z[2]; pmAb<=uvsel(2);
                    pcAf<=Z[2]; pcAk<=chan(colsel(2),inj_chn);
                end

                // ---- CAPTURE unit outputs (ph1 <- ph0 drive; ph2 <- ph1 drive) ----
                if (ph==2'd1) begin
                    tc0<=mg0y; tc1<=mg1y; tc2<=mg2y; tc3<=mg3y;      // mC
                    tda2<=aXy; tda3<=aYy;                            // da
                    tp1 <= inj_uv ? pmAy : pcAy;
                    tp2 <= inj_uv ? pmBy : pcBy;
                    tc  <= a3y;                                      // c
                end else if (ph==2'd2) begin
                    tdx<=mg0y; tdy<=mg1y; tf0<=mg2y; tf1<=mg3y;      // ddx,ddy,f0,f1
                    taa<=aXy; tba<=aYy;                              // Aa,Ba
                    tp3 <= inj_uv ? pmAy : pcAy;
                end

                // ---- ADVANCE the pipeline at tick (ph3); all t* stable ----
                // Emit the plane LEAVING S5 (its c is in tc, computed this window; its
                // ddx/ddy are s5dx/s5dy). S6 IS the output register.
                if (ph==2'd3) begin
                    plane_valid <= sv5; plane_idx <= i5;
                    o_ddx<=s5dx; o_ddy<=s5dy; o_c<=tc;
                    sv5<=sv4; i5<=i4; s5dx<=s4dx; s5dy<=s4dy; s5f0<=tf0; s5f1<=tf1; s5p1<=s4p1;
                    sv4<=sv3; i4<=i3; s4dx<=tdx; s4dy<=tdy; s4p1<=s3p1;
                    sv3<=sv2; i3<=i2; s3aa<=taa; s3ba<=tba; s3p1<=s2p1;
                    sv2<=sv1; i2<=i1; s2c0<=tc0; s2c1<=tc1; s2c2<=tc2; s2c3<=tc3; s2p1<=s1p1;
                    sv1<=sv0; i1<=i0; s1da2<=tda2; s1da3<=tda3; s1p1<=s0p1;
                    sv0<=inj_v; i0<=inj_idx; s0p1<=tp1; s0p2<=tp2; s0p3<=tp3;
                    if (inj_v) nextp <= inj_idx + 4'd1;

                    if (!inj_v && !sv0 && !sv1 && !sv2 && !sv3 && !sv4 && !sv5) begin
                        done<=1'b1; gs<=G_IDLE;
                    end
                end
            end
            default: gs<=G_IDLE;
            endcase
        end
    end
endmodule

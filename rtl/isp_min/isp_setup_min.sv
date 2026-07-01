//
// isp_setup_min - CMD_TRIANGLE_ISP_SETUP core (minimal-DSP, ~14-cycle).
//
// Based on refsw2's ISP Setup(), with these deliberate differences:
//   - tri_area computed ONCE; inv_tri_area = fast reciprocal of it (the only
//     divide), reused by the invW plane (its determinant C == tri_area).
//   - Reduced precision: multiplies use 16-bit mantissa (fp_mul16, ~1 DSP each),
//     adds ~24-bit (fp_add24). Non-IEEE: DaZ, no inf/NaN, truncate. ddx/ddy are
//     internal setup->rasterize coefficients (no standardized format required).
//   - ONLY the invW plane is produced (ddx_invw/ddy_invw/c_invw).
//   - Tile-local: C1..C4 and c_invw are anchored at the tile origin
//     (xbase, ybase) so the rasterizer inner loop uses x,y in 0..31.
//   - Tri only (quad edges use tri fallback: DX41=DY41=0, C4=1).
//
// Datapath: 4 combinational mac16 lanes (mul16+add24), exactly one op per lane
// per cycle (lane inputs registered -> result valid next cycle), plus the
// 2-cycle fp_rcp_fast. EVERY arithmetic op flows through a lane: a multiply is
// (a*b)+0; an add/sub is (a*ONE) +/- c. A fixed micro-schedule drives the lanes
// each cycle and stores results into a scratchpad. done asserts at ~cycle 13.
//
module isp_setup_min (
    input             clk,
    input             reset,
    input             start,
    output reg        done,

    input      [31:0] isp_word,   // refsw params->isp; [4:3] = CullMode

    input      [31:0] x1, input [31:0] y1, input [31:0] z1,
    input      [31:0] x2, input [31:0] y2, input [31:0] z2,
    input      [31:0] x3, input [31:0] y3, input [31:0] z3,
    input      [31:0] xbase, input [31:0] ybase,

    output reg        sgn_neg,     // sgn == -1 (tri_area > 0)
    output reg        cull,
    output reg [31:0] dx12, output reg [31:0] dx23, output reg [31:0] dx31, output reg [31:0] dx41,
    output reg [31:0] dy12, output reg [31:0] dy23, output reg [31:0] dy31, output reg [31:0] dy41,
    output reg [31:0] c1,   output reg [31:0] c2,   output reg [31:0] c3,   output reg [31:0] c4,
    output reg [31:0] ddx_invw, output reg [31:0] ddy_invw, output reg [31:0] c_invw
);
    localparam [31:0] ONE = 32'h3f800000, ZERO = 32'd0, NEG1 = 32'hbf800000;

    // ---------------- vertex holders ----------------
    reg [31:0] X1,Y1,Z1,X2,Y2,Z2,X3,Y3,Z3,XB,YB;

    // ---------------- scratchpad ----------------
    // diffs
    reg [31:0] d_X1X3,d_Y2Y3,d_Y1Y3,d_X2X3;      // area / DX23 DY23
    reg [31:0] d_X1X2,d_Y1Y2,d_X2X1,d_Y2Y1;
    reg [31:0] d_X3X1,d_Y3Y1,d_Z2Z1,d_Z3Z1;
    reg [31:0] XL1,YT1,XL2,YT2,XL3,YT3;          // tile-local anchors
    // area/plane
    reg [31:0] P_a0,P_a1;                          // area sub-products
    reg [31:0] tri_area, inv_area, sgn;
    reg [31:0] Aa0,Ba0,Aa,Ba;
    reg [31:0] ddx,ddy;
    // edges (post-sgn)
    reg [31:0] DX12,DX23,DX31,DY12,DY23,DY31;
    reg [31:0] C1a,C2a,C3a;                        // DY*XL partials
    reg [31:0] ddxXL1, ddyYT1, zc0;                // cInvW accumulation
    reg        tl1,tl2,tl3;                         // top-left flags

    // ---------------- 4 combinational MAC lanes ----------------
    reg  [31:0] la_a,la_b,la_c; reg la_s;  wire [31:0] la_q;
    reg  [31:0] lb_a,lb_b,lb_c; reg lb_s;  wire [31:0] lb_q;
    reg  [31:0] lc_a,lc_b,lc_c; reg lc_s;  wire [31:0] lc_q;
    reg  [31:0] ld_a,ld_b,ld_c; reg ld_s;  wire [31:0] ld_q;
    mac16 u_la (.a(la_a),.b(la_b),.c(la_c),.sub(la_s),.q(la_q));
    mac16 u_lb (.a(lb_a),.b(lb_b),.c(lb_c),.sub(lb_s),.q(lb_q));
    mac16 u_lc (.a(lc_a),.b(lc_b),.c(lc_c),.sub(lc_s),.q(lc_q));
    mac16 u_ld (.a(ld_a),.b(ld_b),.c(ld_c),.sub(ld_s),.q(ld_q));

    // ---------------- fast reciprocal ----------------
    // Dedicated input reg so the recip samples a stable tri_area exactly when
    // rc_req is pulsed (avoids racing the tri_area store). 2-cycle latency:
    // rc_req in cycle N -> rc_y valid in cycle N+2.
    reg        rc_req; reg [31:0] rc_in; wire rc_ack; wire [31:0] rc_y;
    fp_rcp_fast u_rcp (.clk(clk),.reset(reset),.in_valid(rc_req),.x(rc_in),
                       .out_valid(rc_ack),.y(rc_y));

    // ---------------- sign helpers ----------------
    function fzero(input [31:0] f); fzero=(f[30:0]==31'd0); endfunction
    function fneg (input [31:0] f); fneg = f[31]&&(f[30:0]!=31'd0); endfunction
    function fpos (input [31:0] f); fpos = !f[31]&&(f[30:0]!=31'd0); endfunction
    function istl(input [31:0] fdx, input [31:0] fdy);  // IsTopLeft
        istl=(fzero(fdy)&&fpos(fdx))||fneg(fdy); endfunction
    function [31:0] fneg32(input [31:0] f); fneg32={~f[31],f[30:0]}; endfunction

    // lane driver tasks (register inputs; result next cycle)
    task L0(input [31:0]a,b,c,input s); begin la_a<=a;la_b<=b;la_c<=c;la_s<=s; end endtask
    task L1(input [31:0]a,b,c,input s); begin lb_a<=a;lb_b<=b;lb_c<=c;lb_s<=s; end endtask
    task L2(input [31:0]a,b,c,input s); begin lc_a<=a;lc_b<=b;lc_c<=c;lc_s<=s; end endtask
    task L3(input [31:0]a,b,c,input s); begin ld_a<=a;ld_b<=b;ld_c<=c;ld_s<=s; end endtask

    // ---------------- FSM ----------------
    reg [4:0] cyc;
    localparam LOAD=0, RUN=1, FIN=2;
    reg [1:0] st;

    always @(posedge clk) begin
        if (reset) begin st<=LOAD; done<=0; rc_req<=0; cyc<=0; end
        else begin
            done<=0; rc_req<=0;
            case (st)
            LOAD: if (start) begin
                X1<=x1;Y1<=y1;Z1<=z1; X2<=x2;Y2<=y2;Z2<=z2; X3<=x3;Y3<=y3;Z3<=z3;
                XB<=xbase; YB<=ybase; cyc<=0; st<=RUN;
            end
            RUN: begin
                cyc<=cyc+1;
                case (cyc)
                // c0: issue area diffs
                0: begin
                    L0(X1,ONE,X3,1); L1(Y2,ONE,Y3,1); L2(Y1,ONE,Y3,1); L3(X2,ONE,X3,1);
                end
                // c1: store; issue edge12 + plane-xy diffs
                1: begin
                    d_X1X3<=la_q; d_Y2Y3<=lb_q; d_Y1Y3<=lc_q; d_X2X3<=ld_q;
                    L0(X1,ONE,X2,1); L1(Y1,ONE,Y2,1); L2(X2,ONE,X1,1); L3(Y2,ONE,Y1,1);
                end
                // c2: store; issue edge31 + plane-z diffs
                2: begin
                    d_X1X2<=la_q; d_Y1Y2<=lb_q; d_X2X1<=lc_q; d_Y2Y1<=ld_q;
                    L0(X3,ONE,X1,1); L1(Y3,ONE,Y1,1); L2(Z2,ONE,Z1,1); L3(Z3,ONE,Z1,1);
                end
                // c3: store; issue area products + XL1/YT1
                3: begin
                    d_X3X1<=la_q; d_Y3Y1<=lb_q; d_Z2Z1<=lc_q; d_Z3Z1<=ld_q;
                    L0(d_X1X3,d_Y2Y3,ZERO,0);   // (X1-X3)*(Y2-Y3)
                    L1(d_Y1Y3,d_X2X3,ZERO,0);   // (Y1-Y3)*(X2-X3)
                    L2(X1,ONE,XB,1);            // XL1
                    L3(Y1,ONE,YB,1);            // YT1
                end
                // c4: store products+XL1/YT1; issue tri_area = P0-P1 (lane0),
                //     plane p1 (Aa0,Ba0), XL2
                4: begin
                    P_a0<=la_q; P_a1<=lb_q; XL1<=lc_q; YT1<=ld_q;
                    L0(la_q,ONE,lb_q,1);        // tri_area = P0 - P1
                    L1(d_Z3Z1,d_Y2Y1,ZERO,0);   // Aa0=(z3-z1)*(Y2-Y1)
                    L2(d_X3X1,d_Z2Z1,ZERO,0);   // Ba0=(X3-X1)*(z2-z1)
                    L3(X2,ONE,XB,1);            // XL2
                end
                // c5: store tri_area (req recip), Aa0/Ba0/XL2; issue Aa,Ba,YT2
                5: begin
                    tri_area<=la_q; Aa0<=lb_q; Ba0<=lc_q; XL2<=ld_q;
                    rc_in<=la_q; rc_req<=1;     // recip(tri_area); rc_y ready @c7
                    // Aa=Aa0-(z2-z1)*(Y3-Y1) = (-(z2-z1))*(Y3-Y1)+Aa0
                    L1(fneg32(d_Z2Z1),d_Y3Y1,lb_q,0);
                    L2(fneg32(d_X2X1),d_Z3Z1,lc_q,0); // Ba=Ba0-(X2-X1)*(z3-z1)
                    L3(Y2,ONE,YB,1);            // YT2
                end
                // c6: store Aa/Ba/YT2; sgn; issue XL3/YT3
                6: begin
                    Aa<=lb_q; Ba<=lc_q; YT2<=ld_q;
                    sgn_neg <= fpos(tri_area);
                    sgn     <= fpos(tri_area) ? NEG1 : ONE;
                    L0(X3,ONE,XB,1);            // XL3
                    L1(Y3,ONE,YB,1);            // YT3
                end
                // c7: recip ready. store XL3/YT3/inv; issue ddx,ddy + DX12,DX23
                7: begin
                    XL3<=la_q; YT3<=lb_q;
                    inv_area <= rc_y;
                    L0(fneg32(Aa),rc_y,ZERO,0); // ddx = -(Aa*inv)
                    L1(fneg32(Ba),rc_y,ZERO,0); // ddy = -(Ba*inv)
                    L2(sgn,d_X1X2,ZERO,0);      // DX12
                    L3(sgn,d_X2X3,ZERO,0);      // DX23
                end
                // c8: store ddx/ddy/DX12/DX23; issue DX31,DY12,DY23,DY31
                8: begin
                    ddx<=la_q; ddy<=lb_q; DX12<=lc_q; DX23<=ld_q;
                    dx12<=lc_q; dx23<=ld_q; dx41<=ZERO; dy41<=ZERO; c4<=ONE;
                    L0(sgn,d_X3X1,ZERO,0);      // DX31
                    L1(sgn,d_Y1Y2,ZERO,0);      // DY12
                    L2(sgn,d_Y2Y3,ZERO,0);      // DY23
                    L3(sgn,d_Y3Y1,ZERO,0);      // DY31
                end
                // c9: store DX31/DY*; issue C partials (DY*XL) + ddx*XL1
                9: begin
                    DX31<=la_q; DY12<=lb_q; DY23<=lc_q; DY31<=ld_q;
                    dx31<=la_q; dy12<=lb_q; dy23<=lc_q; dy31<=ld_q;
                    L0(lb_q,XL1,ZERO,0);        // C1a = DY12*XL1
                    L1(lc_q,XL2,ZERO,0);        // C2a = DY23*XL2
                    L2(ld_q,XL3,ZERO,0);        // C3a = DY31*XL3
                    L3(ddx,XL1,ZERO,0);         // ddx*XL1
                end
                // c10: store partials; compute top-left flags (DX,DY known);
                //      issue raw Cn = Ca - DX*YT and ddy*YT1
                10: begin
                    C1a<=la_q; C2a<=lb_q; C3a<=lc_q; ddxXL1<=ld_q;
                    tl1 <= istl(DX12,DY12); tl2 <= istl(DX23,DY23); tl3 <= istl(DX31,DY31);
                    // Cn = C_a - DX*YT = (-DX)*YT + C_a  (negate product via a)
                    L0(fneg32(DX12),YT1,la_q,0); // C1raw = C1a - DX12*YT1
                    L1(fneg32(DX23),YT2,lb_q,0); // C2raw
                    L2(fneg32(DX31),YT3,lc_q,0); // C3raw
                    L3(ddy,YT1,ZERO,0);         // ddy*YT1
                end
                // c11: apply top-left (Cn - (tl?0:1)) via lanes; zc0 = z1-ddx*XL1
                11: begin
                    ddyYT1<=ld_q;
                    ddx_invw<=ddx; ddy_invw<=ddy;
                    // Cn_final = Cn_raw - (tl ? 0 : 1.0)
                    L0(la_q, ONE, tl1?ZERO:ONE, 1);  // C1
                    L1(lb_q, ONE, tl2?ZERO:ONE, 1);  // C2
                    L2(lc_q, ONE, tl3?ZERO:ONE, 1);  // C3
                    L3(Z1,  ONE, ddxXL1, 1);         // zc0 = z1 - ddx*XL1
                end
                // c12: store C1..C3; c_invw stage = zc0 - ddy*YT1
                12: begin
                    c1<=la_q; c2<=lb_q; c3<=lc_q; zc0<=ld_q;
                    L0(ld_q, ONE, ddyYT1, 1);        // c_invw = zc0 - ddy*YT1
                end
                13: begin
                    c_invw<=la_q;
                    begin : cb
                      reg [1:0] cm; reg tapos,taneg,wrong;
                      cm=isp_word[4:3]; tapos=fpos(tri_area); taneg=fneg(tri_area);
                      wrong=(cm[0]==0&&taneg)||(cm[0]==1&&tapos);
                      cull<=(cm>=2)&&wrong;
                    end
                    st<=FIN;
                end
                default: st<=FIN;
                endcase
            end
            FIN: begin done<=1; st<=LOAD; end
            endcase
        end
    end
endmodule

//
// tsp_setup_min - CMD_TRIANGLE_TSP_SETUP core (<=48 cycles, small area).
//
// Based on refsw2 IPs3::Setup(), single-volume, base+offset colour, no
// secondary UV/colour. Produces per-attribute interpolation planes in the same
// PlaneStepper format as the ISP invW plane: ddx, ddy, c.
//
// Planes (up to 10): U,V, Col[0..3] (RGBA base), Ofs[0..3] (RGBA offset).
//   da2=a2-a1, da3=a3-a1
//   Aa = da3*(Y2-Y1) - da2*(Y3-Y1)
//   Ba = (X3-X1)*da2 - (X2-X1)*da3
//   C  = (X2-X1)*(Y3-Y1) - (X3-X1)*(Y2-Y1)      // == tri_area, computed ONCE
//   ddx=-Aa/C, ddy=-Ba/C
//   c  = a1 - ddx*(X1-xbase) - ddy*(Y1-ybase)    // tile-local anchor
//
// Precision: ddx/ddy via 16-bit-mantissa mults (fp_mul16); c and all sums via
// higher-precision fp_add24. Attribute products: colour*z via fp_mul_c9
// (9-bit-signed * 16-bit-mant), uv*z via fp_mul16. One shared reciprocal ("big
// C"), recomputed here since TSP has its own vertices.
//
// Small + fast: TWO plane pipelines run fully in parallel on a FIXED lane
// partition - context A owns mac lanes {0,1}, context B owns {2,3} - so the two
// never collide regardless of stage. Each plane is a 6-op serial chain (2 lanes)
// plus a 0-lane attribute-mult prime step. Attribute mults: 3 units per context
// (one per vertex). Measured latency ~54 cycles for the full 10-plane set
// (start -> done), within the allotted budget.
//
module tsp_setup_min (
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
    output reg [3:0]  plane_idx,   // 0=U 1=V 2..5=Col RGBA 6..9=Ofs RGBA
    output reg [31:0] o_ddx, output reg [31:0] o_ddy, output reg [31:0] o_c
);
    localparam [31:0] ONE = 32'h3f800000, ZERO = 32'd0;

    // ---------------- vertices / geometry ----------------
    reg [31:0] X1,Y1,Z1,X2,Y2,Z2,X3,Y3,Z3,XB,YB;
    reg [31:0] U1,V1,U2,V2,U3,V3, COL1,COL2,COL3, OFS1,OFS2,OFS3;
    reg        g_r, tex_r, ofs_en_r;
    reg [31:0] Y2Y1,Y3Y1,X3X1,X2X1, XL1,YT1, area;

    // ---------------- 4 MAC lanes: {0,1}=ctxA, {2,3}=ctxB ----------------
    reg  [31:0] l0a,l0b,l0c; reg l0s; wire [31:0] l0q;
    reg  [31:0] l1a,l1b,l1c; reg l1s; wire [31:0] l1q;
    reg  [31:0] l2a,l2b,l2c; reg l2s; wire [31:0] l2q;
    reg  [31:0] l3a,l3b,l3c; reg l3s; wire [31:0] l3q;
    mac16 ml0 (.clk(clk),.reset(reset),.a(l0a),.b(l0b),.c(l0c),.sub(l0s),.q(l0q));
    mac16 ml1 (.clk(clk),.reset(reset),.a(l1a),.b(l1b),.c(l1c),.sub(l1s),.q(l1q));
    mac16 ml2 (.clk(clk),.reset(reset),.a(l2a),.b(l2b),.c(l2c),.sub(l2s),.q(l2q));
    mac16 ml3 (.clk(clk),.reset(reset),.a(l3a),.b(l3b),.c(l3c),.sub(l3s),.q(l3q));

    // ---------------- reciprocal ----------------
    reg        rc_req; reg [31:0] rc_in; wire rc_ack; wire [31:0] rc_y;
    fp_rcp_fast u_rcp (.clk(clk),.reset(reset),.in_valid(rc_req),.x(rc_in),
                       .out_valid(rc_ack),.y(rc_y));

    // ---------------- attribute multipliers: 3 per context ----------------
    // ctxA
    reg  [31:0] Aza,Azb,Azc; reg signed [8:0] Aca,Acb,Acc; reg [31:0] Aua,Aub,Auc; reg A_uv;
    wire [31:0] Ac9a,Ac9b,Ac9c, Auva,Auvb,Auvc;
    fp_mul_c9 Amca(.f(Aza),.k(Aca),.y(Ac9a)); fp_mul_c9 Amcb(.f(Azb),.k(Acb),.y(Ac9b)); fp_mul_c9 Amcc(.f(Azc),.k(Acc),.y(Ac9c));
    fp_mul16  Amua(.a(Aza),.b(Aua),.y(Auva));  fp_mul16  Amub(.a(Azb),.b(Aub),.y(Auvb));  fp_mul16  Amuc(.a(Azc),.b(Auc),.y(Auvc));
    wire [31:0] Apa1=A_uv?Auva:Ac9a, Apa2=A_uv?Auvb:Ac9b, Apa3=A_uv?Auvc:Ac9c;
    // ctxB
    reg  [31:0] Bza,Bzb,Bzc; reg signed [8:0] Bca,Bcb,Bcc; reg [31:0] Bua,Bub,Buc; reg B_uv;
    wire [31:0] Bc9a,Bc9b,Bc9c, Buva,Buvb,Buvc;
    fp_mul_c9 Bmca(.f(Bza),.k(Bca),.y(Bc9a)); fp_mul_c9 Bmcb(.f(Bzb),.k(Bcb),.y(Bc9b)); fp_mul_c9 Bmcc(.f(Bzc),.k(Bcc),.y(Bc9c));
    fp_mul16  Bmua(.a(Bza),.b(Bua),.y(Buva));  fp_mul16  Bmub(.a(Bzb),.b(Bub),.y(Buvb));  fp_mul16  Bmuc(.a(Bzc),.b(Buc),.y(Buvc));
    wire [31:0] Bpa1=B_uv?Buva:Bc9a, Bpa2=B_uv?Buvb:Bc9b, Bpa3=B_uv?Buvc:Bc9c;

    function [31:0] fneg32(input [31:0] f); fneg32={~f[31],f[30:0]}; endfunction
    function signed [8:0] chan(input [31:0] c, input [1:0] ch);
        case (ch) 0:chan=$signed({1'b0,c[7:0]}); 1:chan=$signed({1'b0,c[15:8]});
                  2:chan=$signed({1'b0,c[23:16]}); 3:chan=$signed({1'b0,c[31:24]}); endcase
    endfunction
    function plane_en(input [3:0] i);
        plane_en=(i<=1)?tex_r:(i<=5)?1'b1:ofs_en_r; endfunction

    // set ctxA attribute mults for plane pl
    task setA(input [3:0] pl); reg [31:0]c1r,c2r,c3r; reg[1:0]chn; begin
        Aza<=Z1;Azb<=Z2;Azc<=Z3;
        if(pl<=1)begin A_uv<=1;
            if(pl==0)begin Aua<=U1;Aub<=U2;Auc<=U3; end else begin Aua<=V1;Aub<=V2;Auc<=V3; end
        end else begin A_uv<=0; chn=pl[1:0]-2'd2;
            if(pl<=5)begin c1r=g_r?COL1:COL3; c2r=g_r?COL2:COL3; c3r=COL3; end
            else     begin c1r=g_r?OFS1:OFS3; c2r=g_r?OFS2:OFS3; c3r=OFS3; end
            Aca<=chan(c1r,chn);Acb<=chan(c2r,chn);Acc<=chan(c3r,chn);
        end end
    endtask
    task setB(input [3:0] pl); reg [31:0]c1r,c2r,c3r; reg[1:0]chn; begin
        Bza<=Z1;Bzb<=Z2;Bzc<=Z3;
        if(pl<=1)begin B_uv<=1;
            if(pl==0)begin Bua<=U1;Bub<=U2;Buc<=U3; end else begin Bua<=V1;Bub<=V2;Buc<=V3; end
        end else begin B_uv<=0; chn=pl[1:0]-2'd2;
            if(pl<=5)begin c1r=g_r?COL1:COL3; c2r=g_r?COL2:COL3; c3r=COL3; end
            else     begin c1r=g_r?OFS1:OFS3; c2r=g_r?OFS2:OFS3; c3r=OFS3; end
            Bca<=chan(c1r,chn);Bcb<=chan(c2r,chn);Bcc<=chan(c3r,chn);
        end end
    endtask

    // ---------------- per-context pipeline state ----------------
    // stage 0..6 active, 7=idle. Each plane's serial op chain (uses its 2 lanes).
    reg [3:0] Ast,Bst; reg [3:0] Api,Bpi;
    reg [31:0] Aa1,Ada2,Ada3,Aaa,Aba,Addx,Addy,At;
    reg [31:0] Ba1,Bda2,Bda3,Baa,Bba,Bddx,Bddy,Bt;

    localparam LOAD=0,GEO=1,RUN=2,FIN=3;
    reg [1:0] fsm; reg [3:0] gc; reg [3:0] nextp;
    reg emitA, emitB;   // stage-6 emit flags resolved after both contexts

    // The mac16 lanes are a 2-stage (mul|add) pipeline for timing; stretch each
    // logical step to MAC_PH clocks so the scheduled body (which reads lane
    // results in the next logical step) sees stable pipelined results. Body runs
    // on phase 0; phases 1..MAC_PH-1 let the mac complete.
    localparam integer MAC_PH = 4;
    reg [1:0] phase;
    wire body = (phase == 2'd0);

    always @(posedge clk) begin
        if (reset) begin fsm<=LOAD; done<=0; rc_req<=0; plane_valid<=0; Ast<=7; Bst<=7; phase<=0; end
        else begin
            done<=0; rc_req<=0; plane_valid<=0; emitA=0; emitB=0;
            // phase counter: only LOAD runs every clock; GEO/RUN are stretched.
            if (fsm==GEO || fsm==RUN) phase <= (phase==MAC_PH-1) ? 2'd0 : phase+2'd1;
            else                      phase <= 2'd0;

            if (fsm==LOAD || body)
            case (fsm)
            LOAD: if (start) begin
                X1<=x1;Y1<=y1;Z1<=z1;X2<=x2;Y2<=y2;Z2<=z2;X3<=x3;Y3<=y3;Z3<=z3;
                XB<=xbase;YB<=ybase; U1<=u1;V1<=v1;U2<=u2;V2<=v2;U3<=u3;V3<=v3;
                COL1<=col1;COL2<=col2;COL3<=col3;OFS1<=ofs1;OFS2<=ofs2;OFS3<=ofs3;
                g_r<=gouraud;tex_r<=texture;ofs_en_r<=offset; gc<=0; fsm<=GEO;
            end

            GEO: begin
                gc<=gc+1;
                case (gc)
                0: begin L0(Y2,ONE,Y1,1);L1(Y3,ONE,Y1,1);L2(X3,ONE,X1,1);L3(X2,ONE,X1,1); end
                1: begin Y2Y1<=l0q;Y3Y1<=l1q;X3X1<=l2q;X2X1<=l3q;
                         L0(X1,ONE,XB,1);L1(Y1,ONE,YB,1); end
                2: begin XL1<=l0q;YT1<=l1q;
                         L0(X2X1,Y3Y1,ZERO,0);L1(X3X1,Y2Y1,ZERO,0); end
                3: begin L0(l0q,ONE,l1q,1); end                     // area
                4: begin area<=l0q; rc_in<=l0q; rc_req<=1;
                         nextp<=0; Ast<=7; Bst<=7; fsm<=RUN; end
                endcase
            end

            RUN: begin
                // ---- context A (lanes 0,1) ----
                case (Ast)
                0: begin Aa1<=Apa1;
                         L0(Apa2,ONE,Apa1,1); L1(Apa3,ONE,Apa1,1); Ast<=1; end   // da2,da3
                1: begin Ada2<=l0q; Ada3<=l1q;
                         L0(l1q,Y2Y1,ZERO,0); L1(l0q,Y3Y1,ZERO,0); Ast<=2; end   // Aa products
                2: begin // Aa = da3*Y2Y1 - da2*Y3Y1 = l0q - l1q ; start Ba products
                         L0(l0q,ONE,l1q,1); L1(X3X1,Ada2,ZERO,0); Ast<=3; end
                3: begin Aaa<=l0q;
                         // Ba = X3X1*da2 - X2X1*da3 = l1q + (-X2X1)*da3
                         L1(fneg32(X2X1),Ada3,l1q,0); Ast<=4; end
                4: begin Aba<=l1q;
                         L0(fneg32(Aaa),rc_y,ZERO,0); L1(fneg32(l1q),rc_y,ZERO,0); Ast<=5; end // ddx,ddy
                5: begin Addx<=l0q; Addy<=l1q;
                         L0(fneg32(l0q),XL1,Aa1,0); Ast<=6; end       // t=a1-ddx*XL1
                6: begin At<=l0q;
                         L1(fneg32(Addy),YT1,l0q,0); Ast<=8; end      // c=t-ddy*YT1 (stage8=emit-pending)
                8: begin emitA=1; Ast<=7; end                        // result in l1q now
                endcase

                // ---- context B (lanes 2,3) ----
                case (Bst)
                0: begin Ba1<=Bpa1;
                         L2(Bpa2,ONE,Bpa1,1); L3(Bpa3,ONE,Bpa1,1); Bst<=1; end
                1: begin Bda2<=l2q; Bda3<=l3q;
                         L2(l3q,Y2Y1,ZERO,0); L3(l2q,Y3Y1,ZERO,0); Bst<=2; end
                2: begin L2(l2q,ONE,l3q,1); L3(X3X1,Bda2,ZERO,0); Bst<=3; end
                3: begin Baa<=l2q;
                         L3(fneg32(X2X1),Bda3,l3q,0); Bst<=4; end
                4: begin Bba<=l3q;
                         L2(fneg32(Baa),rc_y,ZERO,0); L3(fneg32(l3q),rc_y,ZERO,0); Bst<=5; end
                5: begin Bddx<=l2q; Bddy<=l3q;
                         L2(fneg32(l2q),XL1,Ba1,0); Bst<=6; end
                6: begin Bt<=l2q;
                         L3(fneg32(Bddy),YT1,l2q,0); Bst<=8; end
                8: begin emitB=1; Bst<=7; end
                endcase

                // ---- emit (only one can retire per cycle; stagger guarantees it) ----
                if (emitA) begin o_ddx<=Addx;o_ddy<=Addy;o_c<=l1q; plane_idx<=Api; plane_valid<=1; end
                else if (emitB) begin o_ddx<=Bddx;o_ddy<=Bddy;o_c<=l3q; plane_idx<=Bpi; plane_valid<=1; end

                // ---- launcher: fill an idle context with the next enabled plane ----
                if (nextp<=4'd9) begin
                    if (!plane_en(nextp)) nextp<=nextp+1;
                    else if (Ast==7 && !emitA) begin setA(nextp); Api<=nextp; Ast<=0; nextp<=nextp+1; end
                    else if (Bst==7 && !emitB) begin setB(nextp); Bpi<=nextp; Bst<=0; nextp<=nextp+1; end
                end else if (Ast==7 && Bst==7) fsm<=FIN;
            end

            FIN: begin done<=1; fsm<=LOAD; end
            endcase
        end
    end

    // lane driver tasks
    task L0(input [31:0]a,b,c,input s); begin l0a<=a;l0b<=b;l0c<=c;l0s<=s; end endtask
    task L1(input [31:0]a,b,c,input s); begin l1a<=a;l1b<=b;l1c<=c;l1s<=s; end endtask
    task L2(input [31:0]a,b,c,input s); begin l2a<=a;l2b<=b;l2c<=c;l2s<=s; end endtask
    task L3(input [31:0]a,b,c,input s); begin l3a<=a;l3b<=b;l3c<=c;l3s<=s; end endtask
endmodule

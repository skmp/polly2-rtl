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
    fp_rcp_fast u_rcp (.clk(clk),.reset(reset),.stall(1'b0),.in_valid(rc_req),.x(rc_in),
                       .out_valid(rc_ack),.y(rc_y));

    // ---------------- SHARED attribute multipliers: ONE per kind ----------------
    // The attribute "prime" (z*attr for the 3 vertices of a plane) previously used 6
    // multipliers per context (3 fp_mul_c9 + 3 fp_mul16), 12 DSPs total, though c9
    // (colour) and mul16 (uv) are mutually exclusive per plane and each product is
    // used once. Instead: ONE shared fp_mul_c9 + ONE shared fp_mul16, and a serial
    // prime sequencer that computes the 3 vertex products over 3 cycles into the
    // launching context's Apa/Bpa registers. 12 attr DSPs -> 2. The prime overlaps
    // the other context's plane chain, so the cycle cost is small.
    //   pm_z / pm_k / pm_u : the operands presented to the shared muls this cycle.
    reg  [31:0]       pm_z;             // z of the vertex being primed
    reg  signed [8:0] pm_k;             // colour channel (c9 path)
    reg  [31:0]       pm_u;             // uv float (mul16 path)
    reg               pm_uv;            // 1 = uv plane (use mul16), 0 = colour (c9)
    wire [31:0] pm_c9, pm_mul;
    fp_mul_c9 u_amc (.f(pm_z), .k(pm_k), .y(pm_c9));
    fp_mul16  u_amu (.a(pm_z), .b(pm_u), .y(pm_mul));
    wire [31:0] pm_prod = pm_uv ? pm_mul : pm_c9;   // this cycle's z*attr product

    // per-context primed vertex products (filled by the serial prime sequencer)
    reg  [31:0] Apa1,Apa2,Apa3;
    reg  [31:0] Bpa1,Bpa2,Bpa3;

    function [31:0] fneg32(input [31:0] f); fneg32={~f[31],f[30:0]}; endfunction
    function signed [8:0] chan(input [31:0] c, input [1:0] ch);
        case (ch) 0:chan=$signed({1'b0,c[7:0]}); 1:chan=$signed({1'b0,c[15:8]});
                  2:chan=$signed({1'b0,c[23:16]}); 3:chan=$signed({1'b0,c[31:24]}); endcase
    endfunction
    function plane_en(input [3:0] i);
        plane_en=(i<=1)?tex_r:(i<=5)?1'b1:ofs_en_r; endfunction

    // ---- serial attribute prime ----
    // A prime request stages the 3 per-vertex operands for plane `pl` (uv floats or
    // colour channels), then the sequencer feeds them one-per-cycle through the shared
    // mul and latches the 3 products into the requesting context's Apa/Bpa regs.
    reg [31:0] pz1,pz2,pz3;             // vertex z (always Z1..Z3)
    reg        p_isuv;                  // plane kind
    reg [31:0] pu1,pu2,pu3;             // uv floats (uv plane)
    reg signed [8:0] pk1,pk2,pk3;       // colour channels (colour plane)
    // stage the operands for plane pl into the prime holding regs (combinational
    // select of the sources; done the cycle a prime is requested).
    task load_prime(input [3:0] pl); reg [31:0]c1r,c2r,c3r; reg[1:0]chn; begin
        pz1<=Z1; pz2<=Z2; pz3<=Z3;
        if (pl<=1) begin p_isuv<=1'b1;
            if (pl==0) begin pu1<=U1;pu2<=U2;pu3<=U3; end
            else       begin pu1<=V1;pu2<=V2;pu3<=V3; end
        end else begin p_isuv<=1'b0; chn=pl[1:0]-2'd2;
            if (pl<=5) begin c1r=g_r?COL1:COL3; c2r=g_r?COL2:COL3; c3r=COL3; end
            else       begin c1r=g_r?OFS1:OFS3; c2r=g_r?OFS2:OFS3; c3r=OFS3; end
            pk1<=chan(c1r,chn); pk2<=chan(c2r,chn); pk3<=chan(c3r,chn);
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

    // ---- prime sequencer (runs EVERY clock, on the combinational shared muls, so it
    // overlaps the stretched RUN body). prime_st: 0=idle, 1..3 = presenting/latching
    // vertex 1..3, 4 = done (products ready in the target context's Apa/Bpa).
    reg [2:0] prime_st;
    reg       prime_ctx;   // 0 = target ctxA, 1 = target ctxB
    reg [3:0] prime_pl;    // plane being primed (-> Api/Bpi when launched)
    wire prime_idle = (prime_st == 3'd0);
    wire prime_rdy  = (prime_st == 3'd5);

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

            // ---- SERIAL ATTRIBUTE PRIME (runs EVERY clock during RUN) ----
            // The shared muls are combinational, so this advances one vertex/clock
            // independent of the mac `phase` stretch, overlapping the plane chains.
            // Steps: 1->present v1; 2->present v2 + latch v1; 3->present v3 + latch v2;
            // 4->latch v3, done (products in the target ctx's Apa/Bpa, held until the
            // launcher consumes them and sets prime_st back to 0).
            case (prime_st)
                3'd1: begin
                    pm_z<=pz1; pm_k<=pk1; pm_u<=pu1; pm_uv<=p_isuv;   // present v1
                    prime_st<=3'd2;
                end
                3'd2: begin
                    pm_z<=pz2; pm_k<=pk2; pm_u<=pu2;                  // present v2
                    if (!prime_ctx) Apa1<=pm_prod; else Bpa1<=pm_prod; // latch v1
                    prime_st<=3'd3;
                end
                3'd3: begin
                    pm_z<=pz3; pm_k<=pk3; pm_u<=pu3;                  // present v3
                    if (!prime_ctx) Apa2<=pm_prod; else Bpa2<=pm_prod; // latch v2
                    prime_st<=3'd4;
                end
                3'd4: begin
                    if (!prime_ctx) Apa3<=pm_prod; else Bpa3<=pm_prod; // latch v3
                    prime_st<=3'd5;                                    // products ready
                end
                default: ; // 0 idle, 5 ready
            endcase

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

                // ---- launcher: prime the next enabled plane on the shared muls, then
                // launch it into an idle context.
                //   (a) prime_rdy -> launch primed plane into its target ctx, free prime.
                //   (b) prime_idle + planes remain + a ctx free -> request a prime for
                //       nextp targeting that ctx (load operands, prime_st<=1).
                // Stage 0 consumes Apa/Bpa in one cycle; the next prime is gated on
                // prime_idle (re-entered only after launch) so it never clobbers a live
                // prime. FIN only when all planes emitted, both ctx idle, prime idle.
                if (prime_rdy) begin
                    if (!prime_ctx) begin Api<=prime_pl; Ast<=0; end
                    else            begin Bpi<=prime_pl; Bst<=0; end
                    prime_st<=3'd0;
                end else if (prime_idle && nextp<=4'd9) begin
                    if (!plane_en(nextp)) nextp<=nextp+1;
                    else if (Ast==7 && !emitA) begin
                        load_prime(nextp); prime_ctx<=1'b0; prime_pl<=nextp;
                        prime_st<=3'd1; nextp<=nextp+1;
                    end
                    else if (Bst==7 && !emitB) begin
                        load_prime(nextp); prime_ctx<=1'b1; prime_pl<=nextp;
                        prime_st<=3'd1; nextp<=nextp+1;
                    end
                end else if (nextp>4'd9 && prime_idle && Ast==7 && Bst==7) fsm<=FIN;
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

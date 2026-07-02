//
// isp_setup_streamed - 4-way INTERLEAVED isp_setup_min.
//
// isp_setup_min runs one triangle through a 14-step micro-schedule where each
// logical step is stretched to MAC_PH=4 real clocks (the 3-stage pipelined mac16
// must settle before the next dependent step reads it). That leaves the 4 mac
// lanes idle 3 of every 4 clocks. This version fills those idle slots by
// INTERLEAVING 4 INDEPENDENT triangles: real clock t services slot (t mod 4), so
// each of the 4 slots is serviced once per 4 clocks - exactly the MAC_PH cadence -
// and the lanes are busy every clock. Throughput: one triangle retired ~every 14
// clocks (II~=14/tri vs 56/tri), SAME 4 mac lanes (no extra DSP).
//
// Timing (the subtle part): mac16 latency is exactly 4 clocks (input reg -> comb
// mul -> p_r -> sum_r -> q_r) and the interleave depth NS is also 4, so the mac
// output la_q..ld_q at any clock holds the result of the op that the CURRENTLY
// serviced slot issued exactly 4 clocks (= one of its service turns) ago. Each
// slot therefore reads la_q..ld_q DIRECTLY - no result latch needed (L == NS, the
// interleave self-aligns). Every scratchpad register is per-slot ([0:3]). CRUCIAL:
// EVERY lane must issue an op EVERY clock (dummy 0*1+0 when a step doesn't use a
// lane) - a clock that leaves a lane un-driven re-feeds stale inputs and shifts
// the per-lane slot<->result mapping, corrupting other slots.
//
// Streaming interface: in_valid/in_ready accept a triangle into a free slot; when
// a slot finishes, out_valid pulses for one clock with that triangle's planes.
// The consumer must accept out_valid every clock it can appear (it appears at most
// once per 4 clocks, so a 1-deep skid in the consumer suffices; isp_core's plane
// FIFO does this).
//
module isp_setup_streamed (
    input             clk,
    input             reset,

    // input: accept a triangle when in_valid && in_ready
    input             in_valid,
    output            in_ready,
    input      [31:0] isp_word,
    input      [31:0] in_tag,     // opaque payload carried through with the triangle
    input      [31:0] x1, input [31:0] y1, input [31:0] z1,
    input      [31:0] x2, input [31:0] y2, input [31:0] z2,
    input      [31:0] x3, input [31:0] y3, input [31:0] z3,
    input      [31:0] xbase, input [31:0] ybase,

    output            busy,        // 1 = at least one slot has a triangle in flight
    // output: one-clock pulse per retired triangle, gated by out_ready. A slot that
    // reaches retire when !out_ready HOLDS (stays at c14, keeps its result) and
    // retries the next time it is serviced -> no dropped triangles under backpressure.
    input             out_ready,
    output reg        out_valid,
    output reg [31:0] out_tag,     // in_tag of the retiring triangle
    output reg [31:0] out_isp,     // isp_word of the retiring triangle
    output reg        sgn_neg,
    output reg        cull,
    output reg [31:0] dx12, output reg [31:0] dx23, output reg [31:0] dx31, output reg [31:0] dx41,
    output reg [31:0] dy12, output reg [31:0] dy23, output reg [31:0] dy31, output reg [31:0] dy41,
    output reg [31:0] c1,   output reg [31:0] c2,   output reg [31:0] c3,   output reg [31:0] c4,
    output reg [31:0] ddx_invw, output reg [31:0] ddy_invw, output reg [31:0] c_invw,
    output reg [4:0]  bx0, output reg [4:0] bx1, output reg [4:0] by0, output reg [4:0] by1
);
    localparam [31:0] ONE = 32'h3f800000, ZERO = 32'd0, NEG1 = 32'hbf800000;
    localparam integer NS = 4;    // interleave depth = MAC_PH

    // ---------------- per-slot vertex holders ----------------
    reg [31:0] X1[0:NS-1],Y1[0:NS-1],Z1[0:NS-1];
    reg [31:0] X2[0:NS-1],Y2[0:NS-1],Z2[0:NS-1];
    reg [31:0] X3[0:NS-1],Y3[0:NS-1],Z3[0:NS-1];
    reg [31:0] XB[0:NS-1],YB[0:NS-1];
    reg [31:0] ISPW[0:NS-1];
    reg [31:0] TAG[0:NS-1];       // opaque payload carried through

    // ---------------- per-slot scratchpad ----------------
    reg [31:0] d_X1X3[0:NS-1],d_Y2Y3[0:NS-1],d_Y1Y3[0:NS-1],d_X2X3[0:NS-1];
    reg [31:0] d_X1X2[0:NS-1],d_Y1Y2[0:NS-1],d_X2X1[0:NS-1],d_Y2Y1[0:NS-1];
    reg [31:0] d_X3X1[0:NS-1],d_Y3Y1[0:NS-1],d_Z2Z1[0:NS-1],d_Z3Z1[0:NS-1];
    reg [31:0] XL1[0:NS-1],YT1[0:NS-1],XL2[0:NS-1],YT2[0:NS-1],XL3[0:NS-1],YT3[0:NS-1];
    reg [31:0] P_a0[0:NS-1],P_a1[0:NS-1];
    reg [31:0] tri_area[0:NS-1],inv_area[0:NS-1],sgn[0:NS-1];
    reg [31:0] Aa0[0:NS-1],Ba0[0:NS-1],Aa[0:NS-1],Ba[0:NS-1];
    reg [31:0] ddx[0:NS-1],ddy[0:NS-1];
    reg [31:0] DX12[0:NS-1],DX23[0:NS-1],DX31[0:NS-1],DY12[0:NS-1],DY23[0:NS-1],DY31[0:NS-1];
    reg [31:0] C1a[0:NS-1],C2a[0:NS-1],C3a[0:NS-1];
    reg [31:0] ddxXL1[0:NS-1],ddyYT1[0:NS-1],zc0[0:NS-1];
    reg        tl1[0:NS-1],tl2[0:NS-1],tl3[0:NS-1];
    // per-slot outputs accumulated during the schedule (copied out at retire)
    reg [31:0] o_dx12[0:NS-1],o_dx23[0:NS-1],o_dx31[0:NS-1];
    reg [31:0] o_dy12[0:NS-1],o_dy23[0:NS-1],o_dy31[0:NS-1];
    reg [31:0] o_c1[0:NS-1],o_c2[0:NS-1],o_c3[0:NS-1];
    reg [31:0] o_ddx[0:NS-1],o_ddy[0:NS-1],o_cinvw[0:NS-1];
    reg        o_sgnneg[0:NS-1], o_cull[0:NS-1];

    // per-slot control
    reg        slot_busy[0:NS-1];
    reg [4:0]  cyc[0:NS-1];        // logical step 0..14 for each slot
    assign busy = slot_busy[0] | slot_busy[1] | slot_busy[2] | slot_busy[3];

    // ---------------- 4 combinational MAC lanes (shared) ----------------
    reg  [31:0] la_a,la_b,la_c; reg la_s;  wire [31:0] la_q;
    reg  [31:0] lb_a,lb_b,lb_c; reg lb_s;  wire [31:0] lb_q;
    reg  [31:0] lc_a,lc_b,lc_c; reg lc_s;  wire [31:0] lc_q;
    reg  [31:0] ld_a,ld_b,ld_c; reg ld_s;  wire [31:0] ld_q;
    mac16 u_la (.clk(clk),.reset(reset),.a(la_a),.b(la_b),.c(la_c),.sub(la_s),.q(la_q));
    mac16 u_lb (.clk(clk),.reset(reset),.a(lb_a),.b(lb_b),.c(lb_c),.sub(lb_s),.q(lb_q));
    mac16 u_lc (.clk(clk),.reset(reset),.a(lc_a),.b(lc_b),.c(lc_c),.sub(lc_s),.q(lc_q));
    mac16 u_ld (.clk(clk),.reset(reset),.a(ld_a),.b(ld_b),.c(ld_c),.sub(ld_s),.q(ld_q));

    // mac16 latency = 4 clocks (input-reg -> comb mul -> p_r -> sum_r -> q_r), and
    // NS=4, so the slot serviced THIS clock reads la_q..ld_q DIRECTLY: la_q now
    // holds the result of the op this same slot issued exactly 4 clocks ago. No
    // per-slot result latch is needed (the interleave self-aligns, L==NS).

    // ---------------- 4 reciprocals (one per slot, pipelined 3-cycle) ----------------
    // Each slot owns a reciprocal so slots never contend; all are pipelined.
    reg        rc_req[0:NS-1]; reg [31:0] rc_in[0:NS-1];
    wire       rc_ack[0:NS-1]; wire [31:0] rc_y[0:NS-1];
    reg        rc_done[0:NS-1]; reg [31:0] inv_reg[0:NS-1];
    genvar gs;
    generate
      for (gs=0; gs<NS; gs=gs+1) begin : rcp
        fp_rcp_fast u_rcp (.clk(clk),.reset(reset),.stall(1'b0),
            .in_valid(rc_req[gs]),.x(rc_in[gs]),.out_valid(rc_ack[gs]),.y(rc_y[gs]));
        always @(posedge clk) begin
            if (reset || rc_req[gs]) rc_done[gs] <= 1'b0;
            else if (rc_ack[gs])     begin rc_done[gs] <= 1'b1; inv_reg[gs] <= rc_y[gs]; end
        end
      end
    endgenerate

    // ---------------- sign / helper functions (identical to isp_setup_min) --------
    function fzero(input [31:0] f); fzero=(f[30:0]==31'd0); endfunction
    function fneg (input [31:0] f); fneg = f[31]&&(f[30:0]!=31'd0); endfunction
    function fpos (input [31:0] f); fpos = !f[31]&&(f[30:0]!=31'd0); endfunction
    function istl(input [31:0] fdx, input [31:0] fdy);
        istl=(fzero(fdy)&&fpos(fdx))||fneg(fdy); endfunction
    function [31:0] fneg32(input [31:0] f); fneg32={~f[31],f[30:0]}; endfunction

    // ---------------- tile-local bbox (float->int floor), per retiring slot -------
    function automatic signed [15:0] f2i_floor(input [31:0] f);
        integer e, sh; reg signed [31:0] mag;
        begin
            e = f[30:23] - 127;
            if (f[30:23] == 8'd0 || e < 0) mag = 0;
            else begin
                sh = 23 - e;
                if (sh <= 0) mag = {8'b0, 1'b1, f[22:0]} <<< (-sh);
                else         mag = {8'b0, 1'b1, f[22:0]} >>> sh;
            end
            f2i_floor = f[31] ? -mag[15:0] : mag[15:0];
        end
    endfunction
    function automatic [4:0] clamp5(input signed [15:0] v);
        begin
            if (v < 0) clamp5 = 5'd0; else if (v > 31) clamp5 = 5'd31; else clamp5 = v[4:0];
        end
    endfunction

    // ---------------- interleave control ----------------
    reg [1:0] phase;              // slot serviced this clock = phase (0..3)

    // a free slot to accept a new triangle into (must be the slot being serviced,
    // so its first op is issued this clock). We accept only when phase's slot is free.
    wire       accept = in_valid && !slot_busy[phase];
    assign in_ready = !slot_busy[phase];

    // lane driver tasks
    task L0(input [31:0]a,b,c,input s); begin la_a<=a;la_b<=b;la_c<=c;la_s<=s; end endtask
    task L1(input [31:0]a,b,c,input s); begin lb_a<=a;lb_b<=b;lb_c<=c;lb_s<=s; end endtask
    task L2(input [31:0]a,b,c,input s); begin lc_a<=a;lc_b<=b;lc_c<=c;lc_s<=s; end endtask
    task L3(input [31:0]a,b,c,input s); begin ld_a<=a;ld_b<=b;ld_c<=c;ld_s<=s; end endtask

    integer k;
    reg [1:0] sl;                 // slot serviced this clock (= phase)
    reg [31:0] qa,qb,qc,qd;       // this slot's latched mac results
    reg [1:0] cm; reg tapos,taneg,wrong;

    always @(posedge clk) begin
        if (reset) begin
            phase <= 2'd0; out_valid <= 1'b0;
            for (k=0;k<NS;k=k+1) begin slot_busy[k]<=1'b0; rc_req[k]<=1'b0; end
        end else begin
            out_valid <= 1'b0;
            for (k=0;k<NS;k=k+1) rc_req[k] <= 1'b0;
            phase <= phase + 2'd1;

            // mac16 latency == NS == 4, so la_q..ld_q THIS clock hold the result of
            // the op this same slot issued 4 clocks ago -> read them directly.
            sl = phase;                 // slot serviced this clock
            qa = la_q; qb = lb_q; qc = lc_q; qd = ld_q;

            // EVERY lane must issue an op EVERY clock: with mac latency == NS == 4,
            // each lane holds exactly one in-flight op per slot; a clock that leaves
            // a lane un-driven re-feeds stale inputs and shifts the slot<->result
            // mapping, corrupting OTHER slots. Default all lanes to a harmless dummy
            // (0*1+0 = 0); the scheduled step below overrides the lanes it uses.
            L0(ZERO,ONE,ZERO,0); L1(ZERO,ONE,ZERO,0);
            L2(ZERO,ONE,ZERO,0); L3(ZERO,ONE,ZERO,0);

            if (!slot_busy[sl]) begin
                // slot is free: accept a new triangle and issue its c0 ops
                if (accept) begin
                    X1[sl]<=x1;Y1[sl]<=y1;Z1[sl]<=z1; X2[sl]<=x2;Y2[sl]<=y2;Z2[sl]<=z2;
                    X3[sl]<=x3;Y3[sl]<=y3;Z3[sl]<=z3; XB[sl]<=xbase; YB[sl]<=ybase;
                    ISPW[sl]<=isp_word; TAG[sl]<=in_tag;
                    // c0: area diffs (a - c via sub, b=ONE)
                    L0(x1,ONE,x3,1); L1(y2,ONE,y3,1); L2(y1,ONE,y3,1); L3(x2,ONE,x3,1);
                    cyc[sl] <= 5'd1; slot_busy[sl] <= 1'b1;
                end
            end else begin
                // slot busy: run its scheduled step `cyc[sl]`, reading qa..qd
                case (cyc[sl])
                1: begin
                    d_X1X3[sl]<=qa; d_Y2Y3[sl]<=qb; d_Y1Y3[sl]<=qc; d_X2X3[sl]<=qd;
                    L0(X1[sl],ONE,X2[sl],1); L1(Y1[sl],ONE,Y2[sl],1); L2(X2[sl],ONE,X1[sl],1); L3(Y2[sl],ONE,Y1[sl],1);
                    cyc[sl]<=5'd2;
                end
                2: begin
                    d_X1X2[sl]<=qa; d_Y1Y2[sl]<=qb; d_X2X1[sl]<=qc; d_Y2Y1[sl]<=qd;
                    L0(X3[sl],ONE,X1[sl],1); L1(Y3[sl],ONE,Y1[sl],1); L2(Z2[sl],ONE,Z1[sl],1); L3(Z3[sl],ONE,Z1[sl],1);
                    cyc[sl]<=5'd3;
                end
                3: begin
                    d_X3X1[sl]<=qa; d_Y3Y1[sl]<=qb; d_Z2Z1[sl]<=qc; d_Z3Z1[sl]<=qd;
                    L0(d_X1X3[sl],d_Y2Y3[sl],ZERO,0);
                    L1(d_Y1Y3[sl],d_X2X3[sl],ZERO,0);
                    L2(X1[sl],ONE,XB[sl],1);
                    L3(Y1[sl],ONE,YB[sl],1);
                    cyc[sl]<=5'd4;
                end
                4: begin
                    P_a0[sl]<=qa; P_a1[sl]<=qb; XL1[sl]<=qc; YT1[sl]<=qd;
                    L0(qa,ONE,qb,1);                 // tri_area = P0 - P1
                    L1(d_Z3Z1[sl],d_Y2Y1[sl],ZERO,0);  // Aa0
                    L2(d_X3X1[sl],d_Z2Z1[sl],ZERO,0);  // Ba0
                    L3(X2[sl],ONE,XB[sl],1);           // XL2
                    cyc[sl]<=5'd5;
                end
                5: begin
                    tri_area[sl]<=qa;
                    cm=ISPW[sl][28:27];
                    wrong=(cm[0]==1'b0 && fneg(qa))||(cm[0]==1'b1 && fpos(qa));
                    if ((cm>=2'd2) && wrong) begin
                        // early cull: retire immediately with cull=1
                        o_cull[sl]<=1'b1; o_sgnneg[sl]<=fpos(qa);
                        cyc[sl]<=5'd14;               // -> retire
                    end else begin
                        Aa0[sl]<=qb; Ba0[sl]<=qc; XL2[sl]<=qd;
                        rc_in[sl]<=qa; rc_req[sl]<=1'b1;
                        L1(fneg32(d_Z2Z1[sl]),d_Y3Y1[sl],qb,0);  // Aa (L0 = default dummy)
                        L2(fneg32(d_X2X1[sl]),d_Z3Z1[sl],qc,0);  // Ba
                        L3(Y2[sl],ONE,YB[sl],1);                 // YT2
                        cyc[sl]<=5'd6;
                    end
                end
                6: begin
                    Aa[sl]<=qb; Ba[sl]<=qc; YT2[sl]<=qd;
                    o_sgnneg[sl] <= fpos(tri_area[sl]);
                    sgn[sl]      <= fpos(tri_area[sl]) ? NEG1 : ONE;
                    L0(X3[sl],ONE,XB[sl],1);           // XL3
                    L1(Y3[sl],ONE,YB[sl],1);           // YT3
                    cyc[sl]<=5'd7;
                end
                7: begin
                    // The reciprocal is a FIXED 3-cycle pipe, requested at c5. This
                    // slot is serviced every 4 clocks, so by c7 (8 clocks after c5)
                    // inv_reg[sl] has been valid for cycles - no wait needed.
                    XL3[sl]<=qa; YT3[sl]<=qb;          // c6 L0/L1 results
                    inv_area[sl]<=inv_reg[sl];
                    L0(fneg32(Aa[sl]),inv_reg[sl],ZERO,0);   // ddx = -(Aa*inv)
                    L1(fneg32(Ba[sl]),inv_reg[sl],ZERO,0);   // ddy = -(Ba*inv)
                    L2(sgn[sl],d_X1X2[sl],ZERO,0);           // DX12
                    L3(sgn[sl],d_X2X3[sl],ZERO,0);           // DX23
                    cyc[sl]<=5'd8;
                end
                8: begin
                    ddx[sl]<=qa; ddy[sl]<=qb; DX12[sl]<=qc; DX23[sl]<=qd;
                    o_dx12[sl]<=qc; o_dx23[sl]<=qd;
                    L0(sgn[sl],d_X3X1[sl],ZERO,0);     // DX31
                    L1(sgn[sl],d_Y1Y2[sl],ZERO,0);     // DY12
                    L2(sgn[sl],d_Y2Y3[sl],ZERO,0);     // DY23
                    L3(sgn[sl],d_Y3Y1[sl],ZERO,0);     // DY31
                    cyc[sl]<=5'd9;
                end
                9: begin
                    DX31[sl]<=qa; DY12[sl]<=qb; DY23[sl]<=qc; DY31[sl]<=qd;
                    o_dx31[sl]<=qa; o_dy12[sl]<=qb; o_dy23[sl]<=qc; o_dy31[sl]<=qd;
                    L0(qb,XL1[sl],ZERO,0);            // C1a = DY12*XL1
                    L1(qc,XL2[sl],ZERO,0);            // C2a = DY23*XL2
                    L2(qd,XL3[sl],ZERO,0);            // C3a = DY31*XL3
                    L3(ddx[sl],XL1[sl],ZERO,0);        // ddx*XL1
                    cyc[sl]<=5'd10;
                end
                10: begin
                    C1a[sl]<=qa; C2a[sl]<=qb; C3a[sl]<=qc; ddxXL1[sl]<=qd;
                    tl1[sl]<=istl(DX12[sl],DY12[sl]);
                    tl2[sl]<=istl(DX23[sl],DY23[sl]);
                    tl3[sl]<=istl(DX31[sl],DY31[sl]);
                    L0(fneg32(DX12[sl]),YT1[sl],qa,0); // C1raw
                    L1(fneg32(DX23[sl]),YT2[sl],qb,0); // C2raw
                    L2(fneg32(DX31[sl]),YT3[sl],qc,0); // C3raw
                    L3(ddy[sl],YT1[sl],ZERO,0);        // ddy*YT1
                    cyc[sl]<=5'd11;
                end
                11: begin
                    ddyYT1[sl]<=qd;
                    o_ddx[sl]<=ddx[sl]; o_ddy[sl]<=ddy[sl];
                    o_c1[sl]<= tl1[sl] ? qa : (qa - 32'd1);
                    o_c2[sl]<= tl2[sl] ? qb : (qb - 32'd1);
                    o_c3[sl]<= tl3[sl] ? qc : (qc - 32'd1);
                    L3(Z1[sl],ONE,ddxXL1[sl],1);       // zc0 = z1 - ddx*XL1
                    cyc[sl]<=5'd12;
                end
                12: begin
                    zc0[sl]<=qd;
                    L0(qd,ONE,ddyYT1[sl],1);          // c_invw = zc0 - ddy*YT1
                    cyc[sl]<=5'd13;
                end
                13: begin
                    o_cinvw[sl]<=qa;
                    cm=ISPW[sl][28:27]; tapos=fpos(tri_area[sl]); taneg=fneg(tri_area[sl]);
                    wrong=(cm[0]==0&&taneg)||(cm[0]==1&&tapos);
                    o_cull[sl]<=(cm>=2)&&wrong;
                    cyc[sl]<=5'd14;
                end
                14: begin
                    // RETIRE this slot - but ONLY if the consumer can take it. If
                    // !out_ready, hold at c14 (slot stays busy, keeps its result) and
                    // retry when this slot is next serviced. Never drop a triangle.
                    if (out_ready) begin
                        out_valid <= 1'b1;
                        out_tag   <= TAG[sl];
                        out_isp   <= ISPW[sl];
                        sgn_neg   <= o_sgnneg[sl];
                        cull      <= o_cull[sl];
                        dx12<=o_dx12[sl]; dx23<=o_dx23[sl]; dx31<=o_dx31[sl]; dx41<=ZERO;
                        dy12<=o_dy12[sl]; dy23<=o_dy23[sl]; dy31<=o_dy31[sl]; dy41<=ZERO;
                        c1<=o_c1[sl]; c2<=o_c2[sl]; c3<=o_c3[sl]; c4<=ONE;
                        ddx_invw<=o_ddx[sl]; ddy_invw<=o_ddy[sl]; c_invw<=o_cinvw[sl];
                        bx0<=clamp5(bxmin_s); bx1<=clamp5(bxmax_s+16'sd1);
                        by0<=clamp5(bymin_s); by1<=clamp5(bymax_s+16'sd1);
                        slot_busy[sl] <= 1'b0;
                    end
                    // else: stay at cyc[sl]==14, slot_busy stays 1 -> retry next turn
                end
                default: slot_busy[sl] <= 1'b0;
                endcase
            end
        end
    end

    // ---- per-slot bbox (combinational on the retiring slot's vertices) ----
    // computed for slot `s` (the one serviced this clock) so cyc==14 can latch it.
    wire signed [15:0] ob_s  = f2i_floor(XB[phase]);
    wire signed [15:0] obY_s = f2i_floor(YB[phase]);
    wire signed [15:0] lX1s = f2i_floor(X1[phase])-ob_s, lX2s = f2i_floor(X2[phase])-ob_s, lX3s = f2i_floor(X3[phase])-ob_s;
    wire signed [15:0] lY1s = f2i_floor(Y1[phase])-obY_s, lY2s = f2i_floor(Y2[phase])-obY_s, lY3s = f2i_floor(Y3[phase])-obY_s;
    wire signed [15:0] bxmin_s = (lX1s<lX2s?(lX1s<lX3s?lX1s:lX3s):(lX2s<lX3s?lX2s:lX3s));
    wire signed [15:0] bxmax_s = (lX1s>lX2s?(lX1s>lX3s?lX1s:lX3s):(lX2s>lX3s?lX2s:lX3s));
    wire signed [15:0] bymin_s = (lY1s<lY2s?(lY1s<lY3s?lY1s:lY3s):(lY2s<lY3s?lY2s:lY3s));
    wire signed [15:0] bymax_s = (lY1s>lY2s?(lY1s>lY3s?lY1s:lY3s):(lY2s>lY3s?lY2s:lY3s));
endmodule

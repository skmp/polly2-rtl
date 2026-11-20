// GENERATED: do not edit. tools/gen/gen_setup_prog.cpp (ISP_NM 3, ISP_NA 3, L_MUL 1, L_ADD 2, L_RCP 2):
// the ISP setup's microprograms, the operation graphs of refsw3's setup arithmetic (TRI, QUAD, MODIFIER TRI)
// list-scheduled onto p2_isp_alu (ARCHITECTURE 3.4.4, PLAN M4). Regenerate: make isp-prog; check: make
// isp-prog-check.
//
// Per class and step (pc) the micro-word: per multiplier, adder and the reciprocal, an issue with its operation,
// operand registers and the register its result goes to (readable L_<unit> steps later). Every value has its own
// register; the inputs (P2_ISP_R_EX0 .. P2_ISP_R_THIRD) are loaded when the primitive is accepted. The last step
// of a program (P2_ISP_LEN_<class> - 1) issues nothing: it is the hand-off write, the step a culled or bad
// primitive skips. The lengths are the scheduler's, never padded: the measured 16 / 19 [M tim 3.2] are a check
// on the parameters (ARCHITECTURE 6), reported by gen_setup_prog --sweep.
package p2_isp_prog_pkg;

  // the free parameters (ARCHITECTURE 6)
  localparam int P2_ISP_NM    = 3;   // multipliers
  localparam int P2_ISP_NA    = 3;   // adders
  localparam int P2_ISP_L_MUL = 1;   // latencies: issued at step s, readable from step s + L
  localparam int P2_ISP_L_ADD = 2;
  localparam int P2_ISP_L_RCP = 2;

  // the programs' lengths, the hand-off step included (the measured lengths are 16 a triangle and 19 a sprite)
  localparam int P2_ISP_LEN_TRI = 16;
  localparam int P2_ISP_LEN_QUAD = 18;
  localparam int P2_ISP_LEN_MOD = 16;
  localparam int P2_ISP_PC_BITS = 5;
  localparam logic [1:0] P2_ISP_CLS_TRI = 2'd0, P2_ISP_CLS_QUAD = 2'd1, P2_ISP_CLS_MOD = 2'd2;

  // the operand registers: the inputs first (loaded at the accept), then one per value
  localparam int P2_ISP_NREG = 106;
  localparam int P2_ISP_NIN  = 20;
  localparam int P2_ISP_RW   = 7;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_EX0 = 7'd0;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_EY0 = 7'd1;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_EX1 = 7'd2;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_EY1 = 7'd3;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_EX2 = 7'd4;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_EY2 = 7'd5;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_EX3 = 7'd6;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_EY3 = 7'd7;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZX0 = 7'd8;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZY0 = 7'd9;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZZ0 = 7'd10;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZX1 = 7'd11;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZY1 = 7'd12;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZZ1 = 7'd13;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZX2 = 7'd14;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZY2 = 7'd15;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZZ2 = 7'd16;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_TX = 7'd17;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_TY = 7'd18;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_THIRD = 7'd19;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PE21 = 7'd20;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PE12 = 7'd21;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_EE0 = 7'd22;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PE02 = 7'd23;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PE20 = 7'd24;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_EE1 = 7'd25;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PE10 = 7'd26;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PE01 = 7'd27;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_EE2 = 7'd28;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DETE12 = 7'd29;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DETE = 7'd30;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_C0 = 7'd31;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DX0 = 7'd32;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DY0 = 7'd33;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_FY0 = 7'd34;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_FX0 = 7'd35;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_FIRST0 = 7'd36;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_START0 = 7'd37;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_C1 = 7'd38;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DX1 = 7'd39;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DY1 = 7'd40;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_FY1 = 7'd41;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_FX1 = 7'd42;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_FIRST1 = 7'd43;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_START1 = 7'd44;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_C2 = 7'd45;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DX2 = 7'd46;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DY2 = 7'd47;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_FY2 = 7'd48;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_FX2 = 7'd49;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_FIRST2 = 7'd50;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_START2 = 7'd51;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PZ21 = 7'd52;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PZ12 = 7'd53;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZE0 = 7'd54;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PZ02 = 7'd55;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PZ20 = 7'd56;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZE1 = 7'd57;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PZ10 = 7'd58;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PZ01 = 7'd59;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZE2 = 7'd60;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DYZ0 = 7'd61;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DXZ0 = 7'd62;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_TA0 = 7'd63;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_TB0 = 7'd64;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_TC0 = 7'd65;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DYZ1 = 7'd66;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DXZ1 = 7'd67;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_TA1 = 7'd68;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_TB1 = 7'd69;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_TC1 = 7'd70;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DYZ2 = 7'd71;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DXZ2 = 7'd72;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_TA2 = 7'd73;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_TB2 = 7'd74;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_TC2 = 7'd75;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZA12 = 7'd76;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZA = 7'd77;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZB12 = 7'd78;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZB = 7'd79;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZC13 = 7'd80;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZC = 7'd81;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DETZ12 = 7'd82;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DETZ = 7'd83;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_INV0 = 7'd84;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZAX = 7'd85;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZBY = 7'd86;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZSAB = 7'd87;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZSABC = 7'd88;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZFIRST0 = 7'd89;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ARAW = 7'd90;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_BRAW = 7'd91;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZM12 = 7'd92;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZMSUM = 7'd93;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_ZMEAN = 7'd94;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PE23 = 7'd95;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PE32 = 7'd96;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PE30 = 7'd97;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_PE03 = 7'd98;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_C3 = 7'd99;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DX3 = 7'd100;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_DY3 = 7'd101;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_FY3 = 7'd102;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_FX3 = 7'd103;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_FIRST3 = 7'd104;
  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_START3 = 7'd105;

  // operations (p2_isp_alu)
  localparam logic [1:0] P2_ISP_MUL_E = 2'd0;   // Mul 24, swamped at 2^128 (the edge unit)
  localparam logic [1:0] P2_ISP_MUL_R = 2'd1;   // the depth setup's ranged mul
  localparam logic [1:0] P2_ISP_MUL_U = 2'd2;   // Mul 24, unranged (A, B)
  localparam logic [1:0] P2_ISP_ADD_E = 2'd0;   // Add 24 / 25, plain (the edge unit)
  localparam logic [1:0] P2_ISP_ADD_Z = 2'd1;   // the depth setup's addRule, the zero rule on
  localparam logic [1:0] P2_ISP_ADD_M1 = 2'd2;  // the mean's first sum (the corners' fractions)
  localparam logic [1:0] P2_ISP_ADD_M2 = 2'd3;  // the mean's second sum
  localparam logic [1:0] P2_ISP_PO_NONE = 2'd0, P2_ISP_PO_SW = 2'd1, P2_ISP_PO_SAT = 2'd2, P2_ISP_PO_PERP = 2'd3;

  typedef struct packed {
    logic                 v;
    logic [1:0]           op;
    logic                 swa;
    logic [P2_ISP_RW-1:0] ra;
    logic [P2_ISP_RW-1:0] rb;
    logic [P2_ISP_RW-1:0] rd;
  } p2_isp_mslot_t;

  typedef struct packed {
    logic                 v;
    logic [1:0]           op;
    logic                 sub;
    logic [1:0]           post;
    logic [P2_ISP_RW-1:0] ra;
    logic [P2_ISP_RW-1:0] rb;
    logic [P2_ISP_RW-1:0] rd;
  } p2_isp_aslot_t;

  typedef struct packed {
    logic                 v;
    logic [P2_ISP_RW-1:0] ra;
    logic [P2_ISP_RW-1:0] rd;
  } p2_isp_rslot_t;

  typedef struct packed {
    p2_isp_mslot_t [P2_ISP_NM-1:0] m;
    p2_isp_aslot_t [P2_ISP_NA-1:0] a;
    p2_isp_rslot_t                 r;
  } p2_isp_uword_t;

  // the microprogram ROM: the micro-word of step pc of class cls (all zero: no issue)
  function automatic p2_isp_uword_t p2_isp_prog(input logic [1:0] cls, input logic [P2_ISP_PC_BITS-1:0] pc);
    p2_isp_uword_t w;
    w = '0;
    case (cls)
      P2_ISP_CLS_TRI: begin
        case (pc)
          5'd0: begin
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd14, 7'd12, 7'd52};   // pz21
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd11, 7'd15, 7'd53};   // pz12
            w.m[2] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd11, 7'd9, 7'd58};   // pz10
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd12, 7'd15, 7'd61};   // dyz0
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd14, 7'd11, 7'd62};   // dxz0
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd15, 7'd9, 7'd66};   // dyz1
          end
          5'd1: begin
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd8, 7'd15, 7'd55};   // pz02
            w.m[2] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd14, 7'd9, 7'd56};   // pz20
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd8, 7'd12, 7'd59};   // pz01
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd8, 7'd14, 7'd67};   // dxz1
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd9, 7'd12, 7'd71};   // dyz2
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd11, 7'd8, 7'd72};   // dxz2
          end
          5'd2: begin
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd53, 7'd52, 7'd54};   // ze0
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd56, 7'd55, 7'd57};   // ze1
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd59, 7'd58, 7'd60};   // ze2
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd10, 7'd61, 7'd63};   // ta0
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd10, 7'd62, 7'd64};   // tb0
            w.m[2] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd13, 7'd66, 7'd68};   // ta1
          end
          5'd3: begin
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd0, 7'd2, 7'd32};   // dx0
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd1, 7'd3, 7'd33};   // dy0
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd13, 7'd67, 7'd69};   // tb1
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd16, 7'd71, 7'd73};   // ta2
            w.m[2] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd16, 7'd72, 7'd74};   // tb2
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd63, 7'd68, 7'd76};   // za12
          end
          5'd4: begin
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd4, 7'd3, 7'd20};   // pe21
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd2, 7'd4, 7'd39};   // dx1
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd3, 7'd5, 7'd40};   // dy1
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd10, 7'd54, 7'd65};   // tc0
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd16, 7'd60, 7'd75};   // tc2
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd64, 7'd69, 7'd78};   // zb12
          end
          5'd5: begin
            w.m[0] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd2, 7'd5, 7'd21};   // pe12
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd0, 7'd5, 7'd23};   // pe02
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd4, 7'd1, 7'd24};   // pe20
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd4, 7'd0, 7'd46};   // dx2
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd5, 7'd1, 7'd47};   // dy2
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd76, 7'd73, 7'd77};   // za
          end
          5'd6: begin
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd2, 7'd1, 7'd26};   // pe10
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd0, 7'd3, 7'd27};   // pe01
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd13, 7'd57, 7'd70};   // tc1
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd78, 7'd74, 7'd79};   // zb
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd65, 7'd75, 7'd80};   // zc13
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd54, 7'd57, 7'd82};   // detz12
          end
          5'd7: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd21, 7'd20, 7'd22};   // ee0
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd24, 7'd23, 7'd25};   // ee1
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd32, 7'd18, 7'd34};   // fy0
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd33, 7'd17, 7'd35};   // fx0
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd77, 7'd17, 7'd85};   // zax
            w.a[2] = {1'b1, P2_ISP_ADD_M1, 1'b0, 2'd0, 7'd10, 7'd13, 7'd92};   // zm12
          end
          5'd8: begin
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd27, 7'd26, 7'd28};   // ee2
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd39, 7'd18, 7'd41};   // fy1
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd40, 7'd17, 7'd42};   // fx1
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd80, 7'd70, 7'd81};   // zc
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd3, 7'd82, 7'd60, 7'd83};   // detZ
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd79, 7'd18, 7'd86};   // zby
          end
          5'd9: begin
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd1, 7'd22, 7'd25, 7'd29};   // dete12
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd26, 7'd27, 7'd31};   // c0
            w.m[0] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd46, 7'd18, 7'd48};   // fy2
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd47, 7'd17, 7'd49};   // fx2
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd85, 7'd86, 7'd87};   // zsab
          end
          5'd10: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd34, 7'd35, 7'd36};   // first0
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd20, 7'd21, 7'd38};   // c1
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd41, 7'd42, 7'd43};   // first1
            w.r = {1'b1, 7'd83, 7'd84};   // inv0
          end
          5'd11: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd23, 7'd24, 7'd45};   // c2
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd48, 7'd49, 7'd50};   // first2
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd87, 7'd81, 7'd88};   // zsabc
          end
          5'd12: begin
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd1, 7'd29, 7'd28, 7'd30};   // detE
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd2, 7'd36, 7'd31, 7'd37};   // start0
            w.m[0] = {1'b1, P2_ISP_MUL_U, 1'b0, 7'd77, 7'd84, 7'd90};   // Araw
            w.m[1] = {1'b1, P2_ISP_MUL_U, 1'b0, 7'd79, 7'd84, 7'd91};   // Braw
            w.a[0] = {1'b1, P2_ISP_ADD_M2, 1'b0, 2'd0, 7'd92, 7'd16, 7'd93};   // zmsum
          end
          5'd13: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd2, 7'd43, 7'd38, 7'd44};   // start1
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd2, 7'd50, 7'd45, 7'd51};   // start2
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd88, 7'd84, 7'd89};   // zfirst0
          end
          5'd14: begin
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd93, 7'd19, 7'd94};   // zmean
          end
          default: ;
        endcase
      end
      P2_ISP_CLS_QUAD: begin
        case (pc)
          5'd0: begin
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd14, 7'd12, 7'd52};   // pz21
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd11, 7'd15, 7'd53};   // pz12
            w.m[2] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd11, 7'd9, 7'd58};   // pz10
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd12, 7'd15, 7'd61};   // dyz0
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd14, 7'd11, 7'd62};   // dxz0
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd15, 7'd9, 7'd66};   // dyz1
          end
          5'd1: begin
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd8, 7'd15, 7'd55};   // pz02
            w.m[2] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd14, 7'd9, 7'd56};   // pz20
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd8, 7'd12, 7'd59};   // pz01
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd8, 7'd14, 7'd67};   // dxz1
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd9, 7'd12, 7'd71};   // dyz2
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd11, 7'd8, 7'd72};   // dxz2
          end
          5'd2: begin
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd53, 7'd52, 7'd54};   // ze0
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd56, 7'd55, 7'd57};   // ze1
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd59, 7'd58, 7'd60};   // ze2
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd10, 7'd61, 7'd63};   // ta0
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd10, 7'd62, 7'd64};   // tb0
            w.m[2] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd13, 7'd66, 7'd68};   // ta1
          end
          5'd3: begin
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd0, 7'd2, 7'd32};   // dx0
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd1, 7'd3, 7'd33};   // dy0
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd13, 7'd67, 7'd69};   // tb1
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd16, 7'd71, 7'd73};   // ta2
            w.m[2] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd16, 7'd72, 7'd74};   // tb2
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd63, 7'd68, 7'd76};   // za12
          end
          5'd4: begin
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd4, 7'd3, 7'd20};   // pe21
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd2, 7'd4, 7'd39};   // dx1
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd3, 7'd5, 7'd40};   // dy1
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd10, 7'd54, 7'd65};   // tc0
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd16, 7'd60, 7'd75};   // tc2
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd64, 7'd69, 7'd78};   // zb12
          end
          5'd5: begin
            w.m[0] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd2, 7'd5, 7'd21};   // pe12
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd0, 7'd5, 7'd23};   // pe02
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd4, 7'd1, 7'd24};   // pe20
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd4, 7'd6, 7'd46};   // dx2
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd5, 7'd7, 7'd47};   // dy2
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd76, 7'd73, 7'd77};   // za
          end
          5'd6: begin
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd2, 7'd1, 7'd26};   // pe10
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd0, 7'd3, 7'd27};   // pe01
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd6, 7'd0, 7'd100};   // dx3
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd7, 7'd1, 7'd101};   // dy3
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd13, 7'd57, 7'd70};   // tc1
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd78, 7'd74, 7'd79};   // zb
          end
          5'd7: begin
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd21, 7'd20, 7'd22};   // ee0
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd32, 7'd18, 7'd34};   // fy0
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd33, 7'd17, 7'd35};   // fx0
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd65, 7'd75, 7'd80};   // zc13
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd54, 7'd57, 7'd82};   // detz12
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd77, 7'd17, 7'd85};   // zax
          end
          5'd8: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd24, 7'd23, 7'd25};   // ee1
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd27, 7'd26, 7'd28};   // ee2
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd39, 7'd18, 7'd41};   // fy1
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd40, 7'd17, 7'd42};   // fx1
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd79, 7'd18, 7'd86};   // zby
            w.a[1] = {1'b1, P2_ISP_ADD_M1, 1'b0, 2'd0, 7'd10, 7'd13, 7'd92};   // zm12
          end
          5'd9: begin
            w.m[0] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd4, 7'd7, 7'd95};   // pe23
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd6, 7'd5, 7'd96};   // pe32
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd46, 7'd18, 7'd48};   // fy2
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd80, 7'd70, 7'd81};   // zc
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd3, 7'd82, 7'd60, 7'd83};   // detZ
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd85, 7'd86, 7'd87};   // zsab
          end
          5'd10: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd1, 7'd22, 7'd25, 7'd29};   // dete12
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd26, 7'd27, 7'd31};   // c0
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd34, 7'd35, 7'd36};   // first0
            w.m[0] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd47, 7'd17, 7'd49};   // fx2
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd6, 7'd1, 7'd97};   // pe30
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd0, 7'd7, 7'd98};   // pe03
          end
          5'd11: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd20, 7'd21, 7'd38};   // c1
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd41, 7'd42, 7'd43};   // first1
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd96, 7'd95, 7'd45};   // c2
            w.m[0] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd100, 7'd18, 7'd102};   // fy3
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd101, 7'd17, 7'd103};   // fx3
            w.r = {1'b1, 7'd83, 7'd84};   // inv0
          end
          5'd12: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd48, 7'd49, 7'd50};   // first2
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd98, 7'd97, 7'd99};   // c3
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd102, 7'd103, 7'd104};   // first3
          end
          5'd13: begin
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd1, 7'd29, 7'd28, 7'd30};   // detE
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd87, 7'd81, 7'd88};   // zsabc
            w.m[0] = {1'b1, P2_ISP_MUL_U, 1'b0, 7'd77, 7'd84, 7'd90};   // Araw
            w.m[1] = {1'b1, P2_ISP_MUL_U, 1'b0, 7'd79, 7'd84, 7'd91};   // Braw
            w.a[1] = {1'b1, P2_ISP_ADD_M2, 1'b0, 2'd0, 7'd92, 7'd16, 7'd93};   // zmsum
          end
          5'd14: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd2, 7'd36, 7'd31, 7'd37};   // start0
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd2, 7'd43, 7'd38, 7'd44};   // start1
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd2, 7'd50, 7'd45, 7'd51};   // start2
          end
          5'd15: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd2, 7'd104, 7'd99, 7'd105};   // start3
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd88, 7'd84, 7'd89};   // zfirst0
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd93, 7'd19, 7'd94};   // zmean
          end
          default: ;
        endcase
      end
      P2_ISP_CLS_MOD: begin
        case (pc)
          5'd0: begin
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd14, 7'd12, 7'd52};   // pz21
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd11, 7'd15, 7'd53};   // pz12
            w.m[2] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd11, 7'd9, 7'd58};   // pz10
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd12, 7'd15, 7'd61};   // dyz0
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd14, 7'd11, 7'd62};   // dxz0
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd15, 7'd9, 7'd66};   // dyz1
          end
          5'd1: begin
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd8, 7'd15, 7'd55};   // pz02
            w.m[2] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd14, 7'd9, 7'd56};   // pz20
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd8, 7'd12, 7'd59};   // pz01
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd8, 7'd14, 7'd67};   // dxz1
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd9, 7'd12, 7'd71};   // dyz2
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd11, 7'd8, 7'd72};   // dxz2
          end
          5'd2: begin
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd53, 7'd52, 7'd54};   // ze0
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd56, 7'd55, 7'd57};   // ze1
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b1, 2'd0, 7'd59, 7'd58, 7'd60};   // ze2
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd10, 7'd61, 7'd63};   // ta0
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd10, 7'd62, 7'd64};   // tb0
            w.m[2] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd13, 7'd66, 7'd68};   // ta1
          end
          5'd3: begin
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd0, 7'd2, 7'd32};   // dx0
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd1, 7'd3, 7'd33};   // dy0
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd13, 7'd67, 7'd69};   // tb1
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd16, 7'd71, 7'd73};   // ta2
            w.m[2] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd16, 7'd72, 7'd74};   // tb2
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd63, 7'd68, 7'd76};   // za12
          end
          5'd4: begin
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd4, 7'd3, 7'd20};   // pe21
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd2, 7'd4, 7'd39};   // dx1
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd3, 7'd5, 7'd40};   // dy1
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd10, 7'd54, 7'd65};   // tc0
            w.m[1] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd16, 7'd60, 7'd75};   // tc2
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd64, 7'd69, 7'd78};   // zb12
          end
          5'd5: begin
            w.m[0] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd2, 7'd5, 7'd21};   // pe12
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd0, 7'd5, 7'd23};   // pe02
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd4, 7'd1, 7'd24};   // pe20
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd4, 7'd0, 7'd46};   // dx2
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd0, 7'd5, 7'd1, 7'd47};   // dy2
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd76, 7'd73, 7'd77};   // za
          end
          5'd6: begin
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd2, 7'd1, 7'd26};   // pe10
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b0, 7'd0, 7'd3, 7'd27};   // pe01
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd13, 7'd57, 7'd70};   // tc1
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd78, 7'd74, 7'd79};   // zb
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd65, 7'd75, 7'd80};   // zc13
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd54, 7'd57, 7'd82};   // detz12
          end
          5'd7: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd21, 7'd20, 7'd22};   // ee0
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd24, 7'd23, 7'd25};   // ee1
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd32, 7'd18, 7'd34};   // fy0
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd33, 7'd17, 7'd35};   // fx0
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd77, 7'd17, 7'd85};   // zax
            w.a[2] = {1'b1, P2_ISP_ADD_M1, 1'b0, 2'd0, 7'd10, 7'd13, 7'd92};   // zm12
          end
          5'd8: begin
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd27, 7'd26, 7'd28};   // ee2
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd39, 7'd18, 7'd41};   // fy1
            w.m[2] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd40, 7'd17, 7'd42};   // fx1
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd80, 7'd70, 7'd81};   // zc
            w.a[1] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd3, 7'd82, 7'd60, 7'd83};   // detZ
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd79, 7'd18, 7'd86};   // zby
          end
          5'd9: begin
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd1, 7'd22, 7'd25, 7'd29};   // dete12
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd26, 7'd27, 7'd31};   // c0
            w.m[0] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd46, 7'd18, 7'd48};   // fy2
            w.m[1] = {1'b1, P2_ISP_MUL_E, 1'b1, 7'd47, 7'd17, 7'd49};   // fx2
            w.a[0] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd85, 7'd86, 7'd87};   // zsab
          end
          5'd10: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd34, 7'd35, 7'd36};   // first0
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd20, 7'd21, 7'd38};   // c1
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd41, 7'd42, 7'd43};   // first1
            w.r = {1'b1, 7'd83, 7'd84};   // inv0
          end
          5'd11: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd23, 7'd24, 7'd45};   // c2
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b1, 2'd1, 7'd48, 7'd49, 7'd50};   // first2
            w.a[2] = {1'b1, P2_ISP_ADD_Z, 1'b0, 2'd0, 7'd87, 7'd81, 7'd88};   // zsabc
          end
          5'd12: begin
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd1, 7'd29, 7'd28, 7'd30};   // detE
            w.a[2] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd2, 7'd36, 7'd31, 7'd37};   // start0
            w.m[0] = {1'b1, P2_ISP_MUL_U, 1'b0, 7'd77, 7'd84, 7'd90};   // Araw
            w.m[1] = {1'b1, P2_ISP_MUL_U, 1'b0, 7'd79, 7'd84, 7'd91};   // Braw
            w.a[0] = {1'b1, P2_ISP_ADD_M2, 1'b0, 2'd0, 7'd92, 7'd16, 7'd93};   // zmsum
          end
          5'd13: begin
            w.a[0] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd2, 7'd43, 7'd38, 7'd44};   // start1
            w.a[1] = {1'b1, P2_ISP_ADD_E, 1'b0, 2'd2, 7'd50, 7'd45, 7'd51};   // start2
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd88, 7'd84, 7'd89};   // zfirst0
          end
          5'd14: begin
            w.m[0] = {1'b1, P2_ISP_MUL_R, 1'b0, 7'd93, 7'd19, 7'd94};   // zmean
          end
          default: ;
        endcase
      end
      default: ;
    endcase
    return w;
  endfunction

endpackage

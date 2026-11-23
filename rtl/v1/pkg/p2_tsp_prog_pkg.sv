// GENERATED: do not edit. tools/gen/gen_tsp_prog.cpp (TSP_NM 4, TSP_NA 4, L_MUL 1, L_ADD 2, L_RCP 2):
// the TSP setup's microprograms, the operation graphs of refsw3's plane setup and MipSelect's K part per setup class,
// list-scheduled onto p2_tsp_alu (ARCHITECTURE 3.7.3, PLAN M9). Regenerate: make tsp-prog; check: make tsp-prog-check.
//
// Per class and step (pc) the micro-word: per multiplier, adder, the reciprocal and the store's write port an issue
// with its operation, operand registers and result register (readable L_<unit> steps later); a store write names
// its plane and its operands (W_PL: A0, B0, C0 and the flat branch's C). Every value has its own register; the
// inputs (P2_TSP_R_X0 .. ) are loaded when a job starts. A program ends with its last store write
// (P2_TSP_LEN_<class> - 1). The lengths are the scheduler's, never padded: the measured 39 / 48 / 64 / 49 / +5
// [M tim 3.7] are a check on the parameters (gen_tsp_prog --sweep, MT4).
package p2_tsp_prog_pkg;

  // the free parameters (ARCHITECTURE 6: TSP_NM, TSP_NA, the latencies)
  localparam int P2_TSP_NM    = 4;
  localparam int P2_TSP_NA    = 4;
  localparam int P2_TSP_L_MUL = 1;   // issued at step s, readable from step s + L
  localparam int P2_TSP_L_ADD = 2;
  localparam int P2_TSP_L_RCP = 2;

  // the setup classes (p2_tsp_setup chooses one a job)
  localparam int P2_TSP_NCLS = 10;
  localparam logic [3:0] P2_TSP_CLS_UNTEX = 4'd0;   // tex 0, offset planes none, mip no; length 20
  localparam logic [3:0] P2_TSP_CLS_TEX = 4'd1;   // tex 1, offset planes none, mip no; length 26
  localparam logic [3:0] P2_TSP_CLS_TEX_M0 = 4'd2;   // tex 1, offset planes none, mip DCalcCtrl 0; length 31
  localparam logic [3:0] P2_TSP_CLS_TEX_M1 = 4'd3;   // tex 1, offset planes none, mip DCalcCtrl 1; length 32
  localparam logic [3:0] P2_TSP_CLS_TEX_O = 4'd4;   // tex 1, offset planes computed, mip no; length 39
  localparam logic [3:0] P2_TSP_CLS_TEX_O_M0 = 4'd5;   // tex 1, offset planes computed, mip DCalcCtrl 0; length 44
  localparam logic [3:0] P2_TSP_CLS_TEX_O_M1 = 4'd6;   // tex 1, offset planes computed, mip DCalcCtrl 1; length 45
  localparam logic [3:0] P2_TSP_CLS_TEX_D = 4'd7;   // tex 1, offset planes dropped, mip no; length 29
  localparam logic [3:0] P2_TSP_CLS_TEX_D_M0 = 4'd8;   // tex 1, offset planes dropped, mip DCalcCtrl 0; length 34
  localparam logic [3:0] P2_TSP_CLS_TEX_D_M1 = 4'd9;   // tex 1, offset planes dropped, mip DCalcCtrl 1; length 36
  localparam int P2_TSP_PC_BITS = 6;
  // the programs' lengths (the last store write's step + 1)
  function automatic logic [P2_TSP_PC_BITS-1:0] p2_tsp_len(input logic [3:0] cls);
    case (cls)
      4'd0: return 6'd20;
      4'd1: return 6'd26;
      4'd2: return 6'd31;
      4'd3: return 6'd32;
      4'd4: return 6'd39;
      4'd5: return 6'd44;
      4'd6: return 6'd45;
      4'd7: return 6'd29;
      4'd8: return 6'd34;
      4'd9: return 6'd36;
      default: return 6'd1;
    endcase
  endfunction

  // the store's planes
  localparam logic [3:0] P2_TSP_PL_W = 4'd0;
  localparam logic [3:0] P2_TSP_PL_U = 4'd1;
  localparam logic [3:0] P2_TSP_PL_V = 4'd2;
  localparam logic [3:0] P2_TSP_PL_CB = 4'd3;
  localparam logic [3:0] P2_TSP_PL_CG = 4'd4;
  localparam logic [3:0] P2_TSP_PL_CR = 4'd5;
  localparam logic [3:0] P2_TSP_PL_CA = 4'd6;
  localparam logic [3:0] P2_TSP_PL_OB = 4'd7;
  localparam logic [3:0] P2_TSP_PL_OG = 4'd8;
  localparam logic [3:0] P2_TSP_PL_OR = 4'd9;
  localparam logic [3:0] P2_TSP_PL_OA = 4'd10;
  localparam int P2_TSP_NPLANE = 11;

  // the operand registers: the inputs first (loaded at a job's start), then one per value
  localparam int P2_TSP_NREG = 312;
  localparam int P2_TSP_NIN  = 41;
  localparam int P2_TSP_RW   = 9;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_X0 = 9'd0;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Y0 = 9'd1;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Z0 = 9'd2;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_X1 = 9'd3;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Y1 = 9'd4;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Z1 = 9'd5;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_X2 = 9'd6;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Y2 = 9'd7;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Z2 = 9'd8;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_THIRD = 9'd9;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATCB0 = 9'd10;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATCB1 = 9'd11;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATCB2 = 9'd12;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATCG0 = 9'd13;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATCG1 = 9'd14;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATCG2 = 9'd15;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATCR0 = 9'd16;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATCR1 = 9'd17;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATCR2 = 9'd18;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATCA0 = 9'd19;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATCA1 = 9'd20;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATCA2 = 9'd21;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATU0 = 9'd22;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATU1 = 9'd23;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATU2 = 9'd24;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATV0 = 9'd25;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATV1 = 9'd26;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATV2 = 9'd27;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_K2 = 9'd28;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATOB0 = 9'd29;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATOB1 = 9'd30;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATOB2 = 9'd31;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATOG0 = 9'd32;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATOG1 = 9'd33;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATOG2 = 9'd34;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATOR0 = 9'd35;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATOR1 = 9'd36;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATOR2 = 9'd37;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATOA0 = 9'd38;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATOA1 = 9'd39;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_ATOA2 = 9'd40;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_PXY21 = 9'd41;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_PXY12 = 9'd42;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_E0 = 9'd43;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_PXY02 = 9'd44;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_PXY20 = 9'd45;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_E1 = 9'd46;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_PXY10 = 9'd47;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_PXY01 = 9'd48;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_E2 = 9'd49;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_DY0 = 9'd50;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_DX0 = 9'd51;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_WA0 = 9'd52;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_WB0 = 9'd53;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_WC0 = 9'd54;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_DY1 = 9'd55;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_DX1 = 9'd56;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_WA1 = 9'd57;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_WB1 = 9'd58;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_WC1 = 9'd59;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_DY2 = 9'd60;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_DX2 = 9'd61;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_WA2 = 9'd62;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_WB2 = 9'd63;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_WC2 = 9'd64;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SAW01 = 9'd65;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SAW = 9'd66;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SBW01 = 9'd67;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SBW = 9'd68;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SCW02 = 9'd69;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SCW = 9'd70;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SDET01 = 9'd71;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SDET = 9'd72;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_INV = 9'd73;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_M01 = 9'd74;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_MSUM = 9'd75;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_MEAN = 9'd76;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_A0W = 9'd77;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_B0W = 9'd78;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_C0W = 9'd79;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TACB0 = 9'd80;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBCB0 = 9'd81;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCCB0 = 9'd82;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TACB1 = 9'd83;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBCB1 = 9'd84;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCCB1 = 9'd85;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TACB2 = 9'd86;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBCB2 = 9'd87;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCCB2 = 9'd88;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SA01CB = 9'd89;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SACB = 9'd90;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SB01CB = 9'd91;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SBCB = 9'd92;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SC01CB = 9'd93;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SCCB = 9'd94;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_CFCB = 9'd95;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_A0CB = 9'd96;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_B0CB = 9'd97;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_C0CB = 9'd98;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TACG0 = 9'd99;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBCG0 = 9'd100;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCCG0 = 9'd101;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TACG1 = 9'd102;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBCG1 = 9'd103;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCCG1 = 9'd104;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TACG2 = 9'd105;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBCG2 = 9'd106;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCCG2 = 9'd107;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SA01CG = 9'd108;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SACG = 9'd109;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SB01CG = 9'd110;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SBCG = 9'd111;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SC01CG = 9'd112;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SCCG = 9'd113;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_CFCG = 9'd114;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_A0CG = 9'd115;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_B0CG = 9'd116;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_C0CG = 9'd117;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TACR0 = 9'd118;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBCR0 = 9'd119;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCCR0 = 9'd120;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TACR1 = 9'd121;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBCR1 = 9'd122;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCCR1 = 9'd123;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TACR2 = 9'd124;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBCR2 = 9'd125;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCCR2 = 9'd126;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SA01CR = 9'd127;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SACR = 9'd128;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SB01CR = 9'd129;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SBCR = 9'd130;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SC01CR = 9'd131;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SCCR = 9'd132;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_CFCR = 9'd133;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_A0CR = 9'd134;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_B0CR = 9'd135;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_C0CR = 9'd136;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TACA0 = 9'd137;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBCA0 = 9'd138;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCCA0 = 9'd139;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TACA1 = 9'd140;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBCA1 = 9'd141;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCCA1 = 9'd142;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TACA2 = 9'd143;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBCA2 = 9'd144;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCCA2 = 9'd145;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SA01CA = 9'd146;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SACA = 9'd147;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SB01CA = 9'd148;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SBCA = 9'd149;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SC01CA = 9'd150;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SCCA = 9'd151;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_CFCA = 9'd152;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_A0CA = 9'd153;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_B0CA = 9'd154;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_C0CA = 9'd155;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAU0 = 9'd156;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBU0 = 9'd157;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCU0 = 9'd158;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAU1 = 9'd159;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBU1 = 9'd160;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCU1 = 9'd161;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAU2 = 9'd162;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBU2 = 9'd163;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCU2 = 9'd164;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SA01U = 9'd165;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SAU = 9'd166;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SB01U = 9'd167;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SBU = 9'd168;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SC01U = 9'd169;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SCU = 9'd170;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_CFU = 9'd171;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_A0U = 9'd172;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_B0U = 9'd173;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_C0U = 9'd174;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAV0 = 9'd175;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBV0 = 9'd176;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCV0 = 9'd177;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAV1 = 9'd178;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBV1 = 9'd179;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCV1 = 9'd180;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAV2 = 9'd181;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBV2 = 9'd182;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCV2 = 9'd183;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SA01V = 9'd184;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SAV = 9'd185;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SB01V = 9'd186;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SBV = 9'd187;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SC01V = 9'd188;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SCV = 9'd189;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_CFV = 9'd190;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_A0V = 9'd191;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_B0V = 9'd192;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_C0V = 9'd193;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_MINV = 9'd194;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_INV2 = 9'd195;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Q1UX = 9'd196;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Q2UX = 9'd197;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_NUX = 9'd198;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_NQUX = 9'd199;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Q1VX = 9'd200;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Q2VX = 9'd201;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_NVX = 9'd202;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_NQVX = 9'd203;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Q1UY = 9'd204;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Q2UY = 9'd205;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_NUY = 9'd206;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_NQUY = 9'd207;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Q1VY = 9'd208;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_Q2VY = 9'd209;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_NVY = 9'd210;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_NQVY = 9'd211;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_LHIX = 9'd212;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_LLOX = 9'd213;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_LSUMX = 9'd214;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_LLESSX = 9'd215;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_LENX = 9'd216;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_LHIY = 9'd217;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_LLOY = 9'd218;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_LSUMY = 9'd219;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_LLESSY = 9'd220;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_LENY = 9'd221;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_BEST0 = 9'd222;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_BEST = 9'd223;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_D1AU = 9'd224;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_D1BU = 9'd225;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_D1ABU = 9'd226;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_D1U = 9'd227;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_D1AV = 9'd228;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_D1BV = 9'd229;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_D1ABV = 9'd230;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_D1V = 9'd231;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_D1AW = 9'd232;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_D1BW = 9'd233;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_D1ABW = 9'd234;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_D1W = 9'd235;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAOB0 = 9'd236;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBOB0 = 9'd237;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCOB0 = 9'd238;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAOB1 = 9'd239;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBOB1 = 9'd240;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCOB1 = 9'd241;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAOB2 = 9'd242;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBOB2 = 9'd243;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCOB2 = 9'd244;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SA01OB = 9'd245;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SAOB = 9'd246;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SB01OB = 9'd247;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SBOB = 9'd248;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SC01OB = 9'd249;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SCOB = 9'd250;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_CFOB = 9'd251;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_A0OB = 9'd252;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_B0OB = 9'd253;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_C0OB = 9'd254;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAOG0 = 9'd255;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBOG0 = 9'd256;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCOG0 = 9'd257;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAOG1 = 9'd258;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBOG1 = 9'd259;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCOG1 = 9'd260;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAOG2 = 9'd261;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBOG2 = 9'd262;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCOG2 = 9'd263;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SA01OG = 9'd264;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SAOG = 9'd265;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SB01OG = 9'd266;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SBOG = 9'd267;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SC01OG = 9'd268;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SCOG = 9'd269;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_CFOG = 9'd270;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_A0OG = 9'd271;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_B0OG = 9'd272;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_C0OG = 9'd273;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAOR0 = 9'd274;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBOR0 = 9'd275;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCOR0 = 9'd276;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAOR1 = 9'd277;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBOR1 = 9'd278;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCOR1 = 9'd279;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAOR2 = 9'd280;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBOR2 = 9'd281;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCOR2 = 9'd282;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SA01OR = 9'd283;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SAOR = 9'd284;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SB01OR = 9'd285;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SBOR = 9'd286;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SC01OR = 9'd287;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SCOR = 9'd288;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_CFOR = 9'd289;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_A0OR = 9'd290;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_B0OR = 9'd291;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_C0OR = 9'd292;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAOA0 = 9'd293;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBOA0 = 9'd294;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCOA0 = 9'd295;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAOA1 = 9'd296;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBOA1 = 9'd297;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCOA1 = 9'd298;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TAOA2 = 9'd299;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TBOA2 = 9'd300;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_TCOA2 = 9'd301;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SA01OA = 9'd302;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SAOA = 9'd303;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SB01OA = 9'd304;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SBOA = 9'd305;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SC01OA = 9'd306;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_SCOA = 9'd307;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_CFOA = 9'd308;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_A0OA = 9'd309;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_B0OA = 9'd310;
  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_C0OA = 9'd311;

  // operations (p2_tsp_alu; p2_tsp_setup's store writes)
  localparam logic [2:0] P2_TSP_MUL_T = 3'd0, P2_TSP_MUL_K = 3'd1, P2_TSP_MUL_Q = 3'd2, P2_TSP_MUL_I2 = 3'd3,
                         P2_TSP_MUL_B = 3'd4, P2_TSP_MUL_P = 3'd5;
  localparam logic [2:0] P2_TSP_ADD_T = 3'd0, P2_TSP_ADD_W = 3'd1, P2_TSP_ADD_R = 3'd2, P2_TSP_ADD_N = 3'd3,
                         P2_TSP_ADD_LX = 3'd4, P2_TSP_ADD_LN = 3'd5, P2_TSP_ADD_BS = 3'd6, P2_TSP_ADD_P = 3'd7;
  localparam logic       P2_TSP_RCP_T = 1'b0, P2_TSP_RCP_M = 1'b1;
  localparam logic [1:0] P2_TSP_W_PL = 2'd0, P2_TSP_W_DR = 2'd1, P2_TSP_W_K = 2'd2;

  typedef struct packed {
    logic                 v;
    logic [2:0]           op;
    logic [P2_TSP_RW-1:0] ra;
    logic [P2_TSP_RW-1:0] rb;
    logic [P2_TSP_RW-1:0] rd;
  } p2_tsp_mslot_t;

  typedef struct packed {
    logic                 v;
    logic [2:0]           op;
    logic                 sub;
    logic [P2_TSP_RW-1:0] ra;
    logic [P2_TSP_RW-1:0] rb;
    logic [P2_TSP_RW-1:0] rd;
  } p2_tsp_aslot_t;

  typedef struct packed {
    logic                 v;
    logic                 op;
    logic [P2_TSP_RW-1:0] ra;
    logic [P2_TSP_RW-1:0] rd;
  } p2_tsp_rslot_t;

  typedef struct packed {
    logic                 v;
    logic [1:0]           op;
    logic [3:0]           plane;
    logic [3:0][P2_TSP_RW-1:0] r;
  } p2_tsp_wslot_t;

  typedef struct packed {
    p2_tsp_mslot_t [P2_TSP_NM-1:0] m;
    p2_tsp_aslot_t [P2_TSP_NA-1:0] a;
    p2_tsp_rslot_t                 r;
    p2_tsp_wslot_t                 w;
  } p2_tsp_uword_t;

  // the microprogram ROM: the micro-word of step pc of class cls (all zero: no issue)
  function automatic p2_tsp_uword_t p2_tsp_prog(input logic [3:0] cls, input logic [P2_TSP_PC_BITS-1:0] pc);
    p2_tsp_uword_t w;
    w = '0;
    case (cls)
      4'd0: begin   // UNTEX
        case (pc)
          6'd0: begin
            w.m[0] = {1'b1, 3'd0, 9'd6, 9'd4, 9'd41};   // MUL_T pxy21
            w.m[1] = {1'b1, 3'd0, 9'd3, 9'd7, 9'd42};   // MUL_T pxy12
            w.m[2] = {1'b1, 3'd0, 9'd0, 9'd7, 9'd44};   // MUL_T pxy02
            w.m[3] = {1'b1, 3'd0, 9'd6, 9'd1, 9'd45};   // MUL_T pxy20
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd4, 9'd7, 9'd50};   // ADD_T dy0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd6, 9'd3, 9'd51};   // ADD_T dx0
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd7, 9'd1, 9'd55};   // ADD_T dy1
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd0, 9'd6, 9'd56};   // ADD_T dx1
          end
          6'd1: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd42, 9'd41, 9'd43};   // ADD_T e0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd45, 9'd44, 9'd46};   // ADD_T e1
            w.m[0] = {1'b1, 3'd0, 9'd3, 9'd1, 9'd47};   // MUL_T pxy10
            w.m[1] = {1'b1, 3'd0, 9'd0, 9'd4, 9'd48};   // MUL_T pxy01
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd1, 9'd4, 9'd60};   // ADD_T dy2
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd3, 9'd0, 9'd61};   // ADD_T dx2
          end
          6'd2: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd48, 9'd47, 9'd49};   // ADD_T e2
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd50, 9'd52};   // MUL_T wa0
            w.m[1] = {1'b1, 3'd0, 9'd2, 9'd51, 9'd53};   // MUL_T wb0
            w.m[2] = {1'b1, 3'd0, 9'd5, 9'd55, 9'd57};   // MUL_T wa1
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd56, 9'd58};   // MUL_T wb1
            w.a[1] = {1'b1, 3'd1, 1'b0, 9'd2, 9'd5, 9'd74};   // ADD_W m01
          end
          6'd3: begin
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd43, 9'd54};   // MUL_T wc0
            w.m[1] = {1'b1, 3'd0, 9'd5, 9'd46, 9'd59};   // MUL_T wc1
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd52, 9'd57, 9'd65};   // ADD_T SaW01
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd53, 9'd58, 9'd67};   // ADD_T SbW01
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd43, 9'd46, 9'd71};   // ADD_T Sdet01
            w.m[2] = {1'b1, 3'd0, 9'd10, 9'd52, 9'd80};   // MUL_T taCB0
            w.m[3] = {1'b1, 3'd0, 9'd10, 9'd53, 9'd81};   // MUL_T tbCB0
          end
          6'd4: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd49, 9'd64};   // MUL_T wc2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd74, 9'd8, 9'd75};   // ADD_T msum
            w.m[1] = {1'b1, 3'd0, 9'd10, 9'd54, 9'd82};   // MUL_T tcCB0
            w.m[2] = {1'b1, 3'd0, 9'd11, 9'd57, 9'd83};   // MUL_T taCB1
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd58, 9'd84};   // MUL_T tbCB1
          end
          6'd5: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd54, 9'd64, 9'd69};   // ADD_T ScW02
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd71, 9'd49, 9'd72};   // ADD_T Sdet
            w.m[0] = {1'b1, 3'd0, 9'd11, 9'd59, 9'd85};   // MUL_T tcCB1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd80, 9'd83, 9'd89};   // ADD_T Sa01CB
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd81, 9'd84, 9'd91};   // ADD_T Sb01CB
            w.m[1] = {1'b1, 3'd0, 9'd13, 9'd52, 9'd99};   // MUL_T taCG0
            w.m[2] = {1'b1, 3'd0, 9'd13, 9'd53, 9'd100};   // MUL_T tbCG0
            w.m[3] = {1'b1, 3'd0, 9'd13, 9'd54, 9'd101};   // MUL_T tcCG0
          end
          6'd6: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd82, 9'd85, 9'd93};   // ADD_T Sc01CB
            w.m[0] = {1'b1, 3'd0, 9'd14, 9'd57, 9'd102};   // MUL_T taCG1
            w.m[1] = {1'b1, 3'd0, 9'd14, 9'd58, 9'd103};   // MUL_T tbCG1
            w.m[2] = {1'b1, 3'd0, 9'd14, 9'd59, 9'd104};   // MUL_T tcCG1
            w.m[3] = {1'b1, 3'd0, 9'd16, 9'd52, 9'd118};   // MUL_T taCR0
          end
          6'd7: begin
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd69, 9'd59, 9'd70};   // ADD_T ScW
            w.r = {1'b1, 1'b0, 9'd72, 9'd73};   // RCP_T inv
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd99, 9'd102, 9'd108};   // ADD_T Sa01CG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd100, 9'd103, 9'd110};   // ADD_T Sb01CG
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd101, 9'd104, 9'd112};   // ADD_T Sc01CG
            w.m[0] = {1'b1, 3'd0, 9'd16, 9'd53, 9'd119};   // MUL_T tbCR0
            w.m[1] = {1'b1, 3'd0, 9'd16, 9'd54, 9'd120};   // MUL_T tcCR0
            w.m[2] = {1'b1, 3'd0, 9'd17, 9'd57, 9'd121};   // MUL_T taCR1
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd58, 9'd122};   // MUL_T tbCR1
          end
          6'd8: begin
            w.m[0] = {1'b1, 3'd0, 9'd17, 9'd59, 9'd123};   // MUL_T tcCR1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd118, 9'd121, 9'd127};   // ADD_T Sa01CR
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd119, 9'd122, 9'd129};   // ADD_T Sb01CR
            w.m[1] = {1'b1, 3'd0, 9'd19, 9'd52, 9'd137};   // MUL_T taCA0
            w.m[2] = {1'b1, 3'd0, 9'd19, 9'd53, 9'd138};   // MUL_T tbCA0
            w.m[3] = {1'b1, 3'd0, 9'd19, 9'd54, 9'd139};   // MUL_T tcCA0
          end
          6'd9: begin
            w.m[3] = {1'b1, 3'd0, 9'd8, 9'd60, 9'd62};   // MUL_T wa2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd120, 9'd123, 9'd131};   // ADD_T Sc01CR
            w.m[0] = {1'b1, 3'd0, 9'd20, 9'd57, 9'd140};   // MUL_T taCA1
            w.m[1] = {1'b1, 3'd0, 9'd20, 9'd58, 9'd141};   // MUL_T tbCA1
            w.m[2] = {1'b1, 3'd0, 9'd20, 9'd59, 9'd142};   // MUL_T tcCA1
          end
          6'd10: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd61, 9'd63};   // MUL_T wb2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd65, 9'd62, 9'd66};   // ADD_T SaW
            w.m[1] = {1'b1, 3'd0, 9'd12, 9'd62, 9'd86};   // MUL_T taCB2
            w.m[2] = {1'b1, 3'd0, 9'd12, 9'd64, 9'd88};   // MUL_T tcCB2
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd62, 9'd105};   // MUL_T taCG2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd137, 9'd140, 9'd146};   // ADD_T Sa01CA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd138, 9'd141, 9'd148};   // ADD_T Sb01CA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd139, 9'd142, 9'd150};   // ADD_T Sc01CA
          end
          6'd11: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd67, 9'd63, 9'd68};   // ADD_T SbW
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd63, 9'd87};   // MUL_T tbCB2
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd89, 9'd86, 9'd90};   // ADD_T SaCB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd93, 9'd88, 9'd94};   // ADD_T ScCB
            w.m[1] = {1'b1, 3'd0, 9'd15, 9'd63, 9'd106};   // MUL_T tbCG2
            w.m[2] = {1'b1, 3'd0, 9'd15, 9'd64, 9'd107};   // MUL_T tcCG2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd108, 9'd105, 9'd109};   // ADD_T SaCG
            w.m[3] = {1'b1, 3'd0, 9'd18, 9'd62, 9'd124};   // MUL_T taCR2
          end
          6'd12: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd91, 9'd87, 9'd92};   // ADD_T SbCB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd110, 9'd106, 9'd111};   // ADD_T SbCG
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd112, 9'd107, 9'd113};   // ADD_T ScCG
            w.m[0] = {1'b1, 3'd0, 9'd18, 9'd63, 9'd125};   // MUL_T tbCR2
            w.m[1] = {1'b1, 3'd0, 9'd18, 9'd64, 9'd126};   // MUL_T tcCR2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd127, 9'd124, 9'd128};   // ADD_T SaCR
            w.m[2] = {1'b1, 3'd0, 9'd21, 9'd62, 9'd143};   // MUL_T taCA2
            w.m[3] = {1'b1, 3'd0, 9'd21, 9'd63, 9'd144};   // MUL_T tbCA2
          end
          6'd13: begin
            w.m[1] = {1'b1, 3'd0, 9'd75, 9'd9, 9'd76};   // MUL_T mean
            w.m[2] = {1'b1, 3'd0, 9'd66, 9'd73, 9'd77};   // MUL_T A0W
            w.m[3] = {1'b1, 3'd0, 9'd68, 9'd73, 9'd78};   // MUL_T B0W
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd129, 9'd125, 9'd130};   // ADD_T SbCR
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd131, 9'd126, 9'd132};   // ADD_T ScCR
            w.m[0] = {1'b1, 3'd0, 9'd21, 9'd64, 9'd145};   // MUL_T tcCA2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd146, 9'd143, 9'd147};   // ADD_T SaCA
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd148, 9'd144, 9'd149};   // ADD_T SbCA
          end
          6'd14: begin
            w.m[0] = {1'b1, 3'd0, 9'd70, 9'd73, 9'd79};   // MUL_T C0W
            w.m[1] = {1'b1, 3'd0, 9'd12, 9'd76, 9'd95};   // MUL_T CfCB
            w.m[2] = {1'b1, 3'd0, 9'd90, 9'd73, 9'd96};   // MUL_T A0CB
            w.m[3] = {1'b1, 3'd0, 9'd92, 9'd73, 9'd97};   // MUL_T B0CB
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd150, 9'd145, 9'd151};   // ADD_T ScCA
          end
          6'd15: begin
            w.w = {1'b1, 2'd0, 4'd0, 9'd76, 9'd79, 9'd78, 9'd77};   // W_PL wW
            w.m[0] = {1'b1, 3'd0, 9'd94, 9'd73, 9'd98};   // MUL_T C0CB
            w.m[1] = {1'b1, 3'd0, 9'd15, 9'd76, 9'd114};   // MUL_T CfCG
            w.m[2] = {1'b1, 3'd0, 9'd109, 9'd73, 9'd115};   // MUL_T A0CG
            w.m[3] = {1'b1, 3'd0, 9'd111, 9'd73, 9'd116};   // MUL_T B0CG
          end
          6'd16: begin
            w.w = {1'b1, 2'd0, 4'd3, 9'd95, 9'd98, 9'd97, 9'd96};   // W_PL wCB
            w.m[0] = {1'b1, 3'd0, 9'd113, 9'd73, 9'd117};   // MUL_T C0CG
            w.m[1] = {1'b1, 3'd0, 9'd18, 9'd76, 9'd133};   // MUL_T CfCR
            w.m[2] = {1'b1, 3'd0, 9'd128, 9'd73, 9'd134};   // MUL_T A0CR
            w.m[3] = {1'b1, 3'd0, 9'd130, 9'd73, 9'd135};   // MUL_T B0CR
          end
          6'd17: begin
            w.w = {1'b1, 2'd0, 4'd4, 9'd114, 9'd117, 9'd116, 9'd115};   // W_PL wCG
            w.m[0] = {1'b1, 3'd0, 9'd132, 9'd73, 9'd136};   // MUL_T C0CR
            w.m[1] = {1'b1, 3'd0, 9'd21, 9'd76, 9'd152};   // MUL_T CfCA
            w.m[2] = {1'b1, 3'd0, 9'd147, 9'd73, 9'd153};   // MUL_T A0CA
            w.m[3] = {1'b1, 3'd0, 9'd149, 9'd73, 9'd154};   // MUL_T B0CA
          end
          6'd18: begin
            w.w = {1'b1, 2'd0, 4'd5, 9'd133, 9'd136, 9'd135, 9'd134};   // W_PL wCR
            w.m[0] = {1'b1, 3'd0, 9'd151, 9'd73, 9'd155};   // MUL_T C0CA
          end
          6'd19: begin
            w.w = {1'b1, 2'd0, 4'd6, 9'd152, 9'd155, 9'd154, 9'd153};   // W_PL wCA
          end
          default: ;
        endcase
      end
      4'd1: begin   // TEX
        case (pc)
          6'd0: begin
            w.m[0] = {1'b1, 3'd0, 9'd6, 9'd4, 9'd41};   // MUL_T pxy21
            w.m[1] = {1'b1, 3'd0, 9'd3, 9'd7, 9'd42};   // MUL_T pxy12
            w.m[2] = {1'b1, 3'd0, 9'd0, 9'd7, 9'd44};   // MUL_T pxy02
            w.m[3] = {1'b1, 3'd0, 9'd6, 9'd1, 9'd45};   // MUL_T pxy20
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd4, 9'd7, 9'd50};   // ADD_T dy0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd6, 9'd3, 9'd51};   // ADD_T dx0
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd7, 9'd1, 9'd55};   // ADD_T dy1
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd0, 9'd6, 9'd56};   // ADD_T dx1
          end
          6'd1: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd42, 9'd41, 9'd43};   // ADD_T e0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd45, 9'd44, 9'd46};   // ADD_T e1
            w.m[0] = {1'b1, 3'd0, 9'd3, 9'd1, 9'd47};   // MUL_T pxy10
            w.m[1] = {1'b1, 3'd0, 9'd0, 9'd4, 9'd48};   // MUL_T pxy01
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd1, 9'd4, 9'd60};   // ADD_T dy2
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd3, 9'd0, 9'd61};   // ADD_T dx2
          end
          6'd2: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd48, 9'd47, 9'd49};   // ADD_T e2
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd50, 9'd52};   // MUL_T wa0
            w.m[1] = {1'b1, 3'd0, 9'd2, 9'd51, 9'd53};   // MUL_T wb0
            w.m[2] = {1'b1, 3'd0, 9'd5, 9'd55, 9'd57};   // MUL_T wa1
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd56, 9'd58};   // MUL_T wb1
            w.a[1] = {1'b1, 3'd1, 1'b0, 9'd2, 9'd5, 9'd74};   // ADD_W m01
          end
          6'd3: begin
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd43, 9'd54};   // MUL_T wc0
            w.m[1] = {1'b1, 3'd0, 9'd5, 9'd46, 9'd59};   // MUL_T wc1
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd52, 9'd57, 9'd65};   // ADD_T SaW01
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd53, 9'd58, 9'd67};   // ADD_T SbW01
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd43, 9'd46, 9'd71};   // ADD_T Sdet01
            w.m[2] = {1'b1, 3'd0, 9'd22, 9'd52, 9'd156};   // MUL_T taU0
            w.m[3] = {1'b1, 3'd0, 9'd22, 9'd53, 9'd157};   // MUL_T tbU0
          end
          6'd4: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd49, 9'd64};   // MUL_T wc2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd74, 9'd8, 9'd75};   // ADD_T msum
            w.m[1] = {1'b1, 3'd0, 9'd22, 9'd54, 9'd158};   // MUL_T tcU0
            w.m[2] = {1'b1, 3'd0, 9'd23, 9'd57, 9'd159};   // MUL_T taU1
            w.m[3] = {1'b1, 3'd0, 9'd23, 9'd58, 9'd160};   // MUL_T tbU1
          end
          6'd5: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd54, 9'd64, 9'd69};   // ADD_T ScW02
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd71, 9'd49, 9'd72};   // ADD_T Sdet
            w.m[0] = {1'b1, 3'd0, 9'd23, 9'd59, 9'd161};   // MUL_T tcU1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd156, 9'd159, 9'd165};   // ADD_T Sa01U
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd157, 9'd160, 9'd167};   // ADD_T Sb01U
            w.m[1] = {1'b1, 3'd0, 9'd25, 9'd52, 9'd175};   // MUL_T taV0
            w.m[2] = {1'b1, 3'd0, 9'd25, 9'd53, 9'd176};   // MUL_T tbV0
            w.m[3] = {1'b1, 3'd0, 9'd25, 9'd54, 9'd177};   // MUL_T tcV0
          end
          6'd6: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd158, 9'd161, 9'd169};   // ADD_T Sc01U
            w.m[0] = {1'b1, 3'd0, 9'd26, 9'd57, 9'd178};   // MUL_T taV1
            w.m[1] = {1'b1, 3'd0, 9'd26, 9'd58, 9'd179};   // MUL_T tbV1
            w.m[2] = {1'b1, 3'd0, 9'd26, 9'd59, 9'd180};   // MUL_T tcV1
            w.m[3] = {1'b1, 3'd0, 9'd10, 9'd52, 9'd80};   // MUL_T taCB0
          end
          6'd7: begin
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd69, 9'd59, 9'd70};   // ADD_T ScW
            w.r = {1'b1, 1'b0, 9'd72, 9'd73};   // RCP_T inv
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd175, 9'd178, 9'd184};   // ADD_T Sa01V
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd176, 9'd179, 9'd186};   // ADD_T Sb01V
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd177, 9'd180, 9'd188};   // ADD_T Sc01V
            w.m[0] = {1'b1, 3'd0, 9'd10, 9'd53, 9'd81};   // MUL_T tbCB0
            w.m[1] = {1'b1, 3'd0, 9'd10, 9'd54, 9'd82};   // MUL_T tcCB0
            w.m[2] = {1'b1, 3'd0, 9'd11, 9'd57, 9'd83};   // MUL_T taCB1
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd58, 9'd84};   // MUL_T tbCB1
          end
          6'd8: begin
            w.m[0] = {1'b1, 3'd0, 9'd11, 9'd59, 9'd85};   // MUL_T tcCB1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd80, 9'd83, 9'd89};   // ADD_T Sa01CB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd81, 9'd84, 9'd91};   // ADD_T Sb01CB
            w.m[1] = {1'b1, 3'd0, 9'd13, 9'd52, 9'd99};   // MUL_T taCG0
            w.m[2] = {1'b1, 3'd0, 9'd13, 9'd53, 9'd100};   // MUL_T tbCG0
            w.m[3] = {1'b1, 3'd0, 9'd13, 9'd54, 9'd101};   // MUL_T tcCG0
          end
          6'd9: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd82, 9'd85, 9'd93};   // ADD_T Sc01CB
            w.m[0] = {1'b1, 3'd0, 9'd14, 9'd57, 9'd102};   // MUL_T taCG1
            w.m[1] = {1'b1, 3'd0, 9'd14, 9'd58, 9'd103};   // MUL_T tbCG1
            w.m[2] = {1'b1, 3'd0, 9'd14, 9'd59, 9'd104};   // MUL_T tcCG1
            w.m[3] = {1'b1, 3'd0, 9'd16, 9'd52, 9'd118};   // MUL_T taCR0
          end
          6'd10: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd99, 9'd102, 9'd108};   // ADD_T Sa01CG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd100, 9'd103, 9'd110};   // ADD_T Sb01CG
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd101, 9'd104, 9'd112};   // ADD_T Sc01CG
            w.m[0] = {1'b1, 3'd0, 9'd16, 9'd53, 9'd119};   // MUL_T tbCR0
            w.m[1] = {1'b1, 3'd0, 9'd16, 9'd54, 9'd120};   // MUL_T tcCR0
            w.m[2] = {1'b1, 3'd0, 9'd17, 9'd57, 9'd121};   // MUL_T taCR1
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd58, 9'd122};   // MUL_T tbCR1
          end
          6'd11: begin
            w.m[0] = {1'b1, 3'd0, 9'd17, 9'd59, 9'd123};   // MUL_T tcCR1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd118, 9'd121, 9'd127};   // ADD_T Sa01CR
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd119, 9'd122, 9'd129};   // ADD_T Sb01CR
            w.m[1] = {1'b1, 3'd0, 9'd19, 9'd52, 9'd137};   // MUL_T taCA0
            w.m[2] = {1'b1, 3'd0, 9'd19, 9'd53, 9'd138};   // MUL_T tbCA0
            w.m[3] = {1'b1, 3'd0, 9'd19, 9'd54, 9'd139};   // MUL_T tcCA0
          end
          6'd12: begin
            w.m[3] = {1'b1, 3'd0, 9'd8, 9'd60, 9'd62};   // MUL_T wa2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd120, 9'd123, 9'd131};   // ADD_T Sc01CR
            w.m[0] = {1'b1, 3'd0, 9'd20, 9'd57, 9'd140};   // MUL_T taCA1
            w.m[1] = {1'b1, 3'd0, 9'd20, 9'd58, 9'd141};   // MUL_T tbCA1
            w.m[2] = {1'b1, 3'd0, 9'd20, 9'd59, 9'd142};   // MUL_T tcCA1
          end
          6'd13: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd61, 9'd63};   // MUL_T wb2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd65, 9'd62, 9'd66};   // ADD_T SaW
            w.m[1] = {1'b1, 3'd0, 9'd24, 9'd62, 9'd162};   // MUL_T taU2
            w.m[2] = {1'b1, 3'd0, 9'd24, 9'd64, 9'd164};   // MUL_T tcU2
            w.m[3] = {1'b1, 3'd0, 9'd27, 9'd62, 9'd181};   // MUL_T taV2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd137, 9'd140, 9'd146};   // ADD_T Sa01CA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd138, 9'd141, 9'd148};   // ADD_T Sb01CA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd139, 9'd142, 9'd150};   // ADD_T Sc01CA
          end
          6'd14: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd67, 9'd63, 9'd68};   // ADD_T SbW
            w.m[0] = {1'b1, 3'd0, 9'd24, 9'd63, 9'd163};   // MUL_T tbU2
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd165, 9'd162, 9'd166};   // ADD_T SaU
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd169, 9'd164, 9'd170};   // ADD_T ScU
            w.m[1] = {1'b1, 3'd0, 9'd27, 9'd63, 9'd182};   // MUL_T tbV2
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd64, 9'd183};   // MUL_T tcV2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd184, 9'd181, 9'd185};   // ADD_T SaV
            w.m[3] = {1'b1, 3'd0, 9'd12, 9'd62, 9'd86};   // MUL_T taCB2
          end
          6'd15: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd167, 9'd163, 9'd168};   // ADD_T SbU
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd186, 9'd182, 9'd187};   // ADD_T SbV
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd188, 9'd183, 9'd189};   // ADD_T ScV
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd63, 9'd87};   // MUL_T tbCB2
            w.m[1] = {1'b1, 3'd0, 9'd12, 9'd64, 9'd88};   // MUL_T tcCB2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd89, 9'd86, 9'd90};   // ADD_T SaCB
            w.m[2] = {1'b1, 3'd0, 9'd15, 9'd62, 9'd105};   // MUL_T taCG2
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd63, 9'd106};   // MUL_T tbCG2
          end
          6'd16: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd91, 9'd87, 9'd92};   // ADD_T SbCB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd93, 9'd88, 9'd94};   // ADD_T ScCB
            w.m[0] = {1'b1, 3'd0, 9'd15, 9'd64, 9'd107};   // MUL_T tcCG2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd108, 9'd105, 9'd109};   // ADD_T SaCG
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd110, 9'd106, 9'd111};   // ADD_T SbCG
            w.m[1] = {1'b1, 3'd0, 9'd18, 9'd62, 9'd124};   // MUL_T taCR2
            w.m[2] = {1'b1, 3'd0, 9'd18, 9'd63, 9'd125};   // MUL_T tbCR2
            w.m[3] = {1'b1, 3'd0, 9'd18, 9'd64, 9'd126};   // MUL_T tcCR2
          end
          6'd17: begin
            w.m[3] = {1'b1, 3'd0, 9'd75, 9'd9, 9'd76};   // MUL_T mean
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd112, 9'd107, 9'd113};   // ADD_T ScCG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd127, 9'd124, 9'd128};   // ADD_T SaCR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd129, 9'd125, 9'd130};   // ADD_T SbCR
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd131, 9'd126, 9'd132};   // ADD_T ScCR
            w.m[0] = {1'b1, 3'd0, 9'd21, 9'd62, 9'd143};   // MUL_T taCA2
            w.m[1] = {1'b1, 3'd0, 9'd21, 9'd63, 9'd144};   // MUL_T tbCA2
            w.m[2] = {1'b1, 3'd0, 9'd21, 9'd64, 9'd145};   // MUL_T tcCA2
          end
          6'd18: begin
            w.m[0] = {1'b1, 3'd0, 9'd66, 9'd73, 9'd77};   // MUL_T A0W
            w.m[1] = {1'b1, 3'd0, 9'd68, 9'd73, 9'd78};   // MUL_T B0W
            w.m[2] = {1'b1, 3'd0, 9'd70, 9'd73, 9'd79};   // MUL_T C0W
            w.m[3] = {1'b1, 3'd0, 9'd24, 9'd76, 9'd171};   // MUL_T CfU
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd146, 9'd143, 9'd147};   // ADD_T SaCA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd148, 9'd144, 9'd149};   // ADD_T SbCA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd150, 9'd145, 9'd151};   // ADD_T ScCA
          end
          6'd19: begin
            w.w = {1'b1, 2'd0, 4'd0, 9'd76, 9'd79, 9'd78, 9'd77};   // W_PL wW
            w.m[0] = {1'b1, 3'd0, 9'd166, 9'd73, 9'd172};   // MUL_T A0U
            w.m[1] = {1'b1, 3'd0, 9'd168, 9'd73, 9'd173};   // MUL_T B0U
            w.m[2] = {1'b1, 3'd0, 9'd170, 9'd73, 9'd174};   // MUL_T C0U
            w.m[3] = {1'b1, 3'd0, 9'd27, 9'd76, 9'd190};   // MUL_T CfV
          end
          6'd20: begin
            w.w = {1'b1, 2'd0, 4'd1, 9'd171, 9'd174, 9'd173, 9'd172};   // W_PL wU
            w.m[0] = {1'b1, 3'd0, 9'd185, 9'd73, 9'd191};   // MUL_T A0V
            w.m[1] = {1'b1, 3'd0, 9'd187, 9'd73, 9'd192};   // MUL_T B0V
            w.m[2] = {1'b1, 3'd0, 9'd189, 9'd73, 9'd193};   // MUL_T C0V
            w.m[3] = {1'b1, 3'd0, 9'd12, 9'd76, 9'd95};   // MUL_T CfCB
          end
          6'd21: begin
            w.w = {1'b1, 2'd0, 4'd2, 9'd190, 9'd193, 9'd192, 9'd191};   // W_PL wV
            w.m[0] = {1'b1, 3'd0, 9'd90, 9'd73, 9'd96};   // MUL_T A0CB
            w.m[1] = {1'b1, 3'd0, 9'd92, 9'd73, 9'd97};   // MUL_T B0CB
            w.m[2] = {1'b1, 3'd0, 9'd94, 9'd73, 9'd98};   // MUL_T C0CB
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd76, 9'd114};   // MUL_T CfCG
          end
          6'd22: begin
            w.w = {1'b1, 2'd0, 4'd3, 9'd95, 9'd98, 9'd97, 9'd96};   // W_PL wCB
            w.m[0] = {1'b1, 3'd0, 9'd109, 9'd73, 9'd115};   // MUL_T A0CG
            w.m[1] = {1'b1, 3'd0, 9'd111, 9'd73, 9'd116};   // MUL_T B0CG
            w.m[2] = {1'b1, 3'd0, 9'd113, 9'd73, 9'd117};   // MUL_T C0CG
            w.m[3] = {1'b1, 3'd0, 9'd18, 9'd76, 9'd133};   // MUL_T CfCR
          end
          6'd23: begin
            w.w = {1'b1, 2'd0, 4'd4, 9'd114, 9'd117, 9'd116, 9'd115};   // W_PL wCG
            w.m[0] = {1'b1, 3'd0, 9'd128, 9'd73, 9'd134};   // MUL_T A0CR
            w.m[1] = {1'b1, 3'd0, 9'd130, 9'd73, 9'd135};   // MUL_T B0CR
            w.m[2] = {1'b1, 3'd0, 9'd132, 9'd73, 9'd136};   // MUL_T C0CR
            w.m[3] = {1'b1, 3'd0, 9'd21, 9'd76, 9'd152};   // MUL_T CfCA
          end
          6'd24: begin
            w.w = {1'b1, 2'd0, 4'd5, 9'd133, 9'd136, 9'd135, 9'd134};   // W_PL wCR
            w.m[0] = {1'b1, 3'd0, 9'd147, 9'd73, 9'd153};   // MUL_T A0CA
            w.m[1] = {1'b1, 3'd0, 9'd149, 9'd73, 9'd154};   // MUL_T B0CA
            w.m[2] = {1'b1, 3'd0, 9'd151, 9'd73, 9'd155};   // MUL_T C0CA
          end
          6'd25: begin
            w.w = {1'b1, 2'd0, 4'd6, 9'd152, 9'd155, 9'd154, 9'd153};   // W_PL wCA
          end
          default: ;
        endcase
      end
      4'd2: begin   // TEX_M0
        case (pc)
          6'd0: begin
            w.m[0] = {1'b1, 3'd0, 9'd6, 9'd4, 9'd41};   // MUL_T pxy21
            w.m[1] = {1'b1, 3'd0, 9'd3, 9'd7, 9'd42};   // MUL_T pxy12
            w.m[2] = {1'b1, 3'd0, 9'd0, 9'd7, 9'd44};   // MUL_T pxy02
            w.m[3] = {1'b1, 3'd0, 9'd6, 9'd1, 9'd45};   // MUL_T pxy20
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd4, 9'd7, 9'd50};   // ADD_T dy0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd6, 9'd3, 9'd51};   // ADD_T dx0
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd7, 9'd1, 9'd55};   // ADD_T dy1
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd0, 9'd6, 9'd56};   // ADD_T dx1
          end
          6'd1: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd42, 9'd41, 9'd43};   // ADD_T e0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd45, 9'd44, 9'd46};   // ADD_T e1
            w.m[0] = {1'b1, 3'd0, 9'd3, 9'd1, 9'd47};   // MUL_T pxy10
            w.m[1] = {1'b1, 3'd0, 9'd0, 9'd4, 9'd48};   // MUL_T pxy01
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd1, 9'd4, 9'd60};   // ADD_T dy2
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd3, 9'd0, 9'd61};   // ADD_T dx2
          end
          6'd2: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd48, 9'd47, 9'd49};   // ADD_T e2
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd50, 9'd52};   // MUL_T wa0
            w.m[1] = {1'b1, 3'd0, 9'd2, 9'd51, 9'd53};   // MUL_T wb0
            w.m[2] = {1'b1, 3'd0, 9'd5, 9'd55, 9'd57};   // MUL_T wa1
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd56, 9'd58};   // MUL_T wb1
            w.a[1] = {1'b1, 3'd1, 1'b0, 9'd2, 9'd5, 9'd74};   // ADD_W m01
          end
          6'd3: begin
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd43, 9'd54};   // MUL_T wc0
            w.m[1] = {1'b1, 3'd0, 9'd5, 9'd46, 9'd59};   // MUL_T wc1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd52, 9'd57, 9'd65};   // ADD_T SaW01
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd53, 9'd58, 9'd67};   // ADD_T SbW01
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd43, 9'd46, 9'd71};   // ADD_T Sdet01
            w.m[2] = {1'b1, 3'd0, 9'd22, 9'd52, 9'd156};   // MUL_T taU0
            w.m[3] = {1'b1, 3'd0, 9'd22, 9'd53, 9'd157};   // MUL_T tbU0
          end
          6'd4: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd49, 9'd64};   // MUL_T wc2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd74, 9'd8, 9'd75};   // ADD_T msum
            w.m[1] = {1'b1, 3'd0, 9'd22, 9'd54, 9'd158};   // MUL_T tcU0
            w.m[2] = {1'b1, 3'd0, 9'd23, 9'd57, 9'd159};   // MUL_T taU1
            w.m[3] = {1'b1, 3'd0, 9'd23, 9'd58, 9'd160};   // MUL_T tbU1
          end
          6'd5: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd54, 9'd64, 9'd69};   // ADD_T ScW02
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd71, 9'd49, 9'd72};   // ADD_T Sdet
            w.m[0] = {1'b1, 3'd0, 9'd23, 9'd59, 9'd161};   // MUL_T tcU1
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd156, 9'd159, 9'd165};   // ADD_T Sa01U
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd157, 9'd160, 9'd167};   // ADD_T Sb01U
            w.m[1] = {1'b1, 3'd0, 9'd25, 9'd52, 9'd175};   // MUL_T taV0
            w.m[2] = {1'b1, 3'd0, 9'd25, 9'd53, 9'd176};   // MUL_T tbV0
            w.m[3] = {1'b1, 3'd0, 9'd25, 9'd54, 9'd177};   // MUL_T tcV0
          end
          6'd6: begin
            w.m[3] = {1'b1, 3'd0, 9'd8, 9'd60, 9'd62};   // MUL_T wa2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd158, 9'd161, 9'd169};   // ADD_T Sc01U
            w.m[0] = {1'b1, 3'd0, 9'd26, 9'd57, 9'd178};   // MUL_T taV1
            w.m[1] = {1'b1, 3'd0, 9'd26, 9'd58, 9'd179};   // MUL_T tbV1
            w.m[2] = {1'b1, 3'd0, 9'd26, 9'd59, 9'd180};   // MUL_T tcV1
          end
          6'd7: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd61, 9'd63};   // MUL_T wb2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd65, 9'd62, 9'd66};   // ADD_T SaW
            w.m[1] = {1'b1, 3'd0, 9'd24, 9'd62, 9'd162};   // MUL_T taU2
            w.m[2] = {1'b1, 3'd0, 9'd24, 9'd64, 9'd164};   // MUL_T tcU2
            w.m[3] = {1'b1, 3'd0, 9'd27, 9'd62, 9'd181};   // MUL_T taV2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd175, 9'd178, 9'd184};   // ADD_T Sa01V
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd176, 9'd179, 9'd186};   // ADD_T Sb01V
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd177, 9'd180, 9'd188};   // ADD_T Sc01V
            w.r = {1'b1, 1'b1, 9'd72, 9'd194};   // RCP_M minv
          end
          6'd8: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd67, 9'd63, 9'd68};   // ADD_T SbW
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd69, 9'd59, 9'd70};   // ADD_T ScW
            w.r = {1'b1, 1'b0, 9'd72, 9'd73};   // RCP_T inv
            w.m[0] = {1'b1, 3'd0, 9'd24, 9'd63, 9'd163};   // MUL_T tbU2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd165, 9'd162, 9'd166};   // ADD_T SaU
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd169, 9'd164, 9'd170};   // ADD_T ScU
            w.m[1] = {1'b1, 3'd0, 9'd27, 9'd63, 9'd182};   // MUL_T tbV2
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd64, 9'd183};   // MUL_T tcV2
            w.m[3] = {1'b1, 3'd0, 9'd10, 9'd52, 9'd80};   // MUL_T taCB0
          end
          6'd9: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd167, 9'd163, 9'd168};   // ADD_T SbU
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd184, 9'd181, 9'd185};   // ADD_T SaV
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd186, 9'd182, 9'd187};   // ADD_T SbV
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd188, 9'd183, 9'd189};   // ADD_T ScV
            w.m[1] = {1'b1, 3'd0, 9'd10, 9'd53, 9'd81};   // MUL_T tbCB0
            w.m[2] = {1'b1, 3'd0, 9'd10, 9'd54, 9'd82};   // MUL_T tcCB0
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd57, 9'd83};   // MUL_T taCB1
            w.m[0] = {1'b1, 3'd3, 9'd194, 9'd194, 9'd195};   // MUL_I2 inv2
          end
          6'd10: begin
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd58, 9'd84};   // MUL_T tbCB1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd80, 9'd83, 9'd89};   // ADD_T Sa01CB
            w.m[0] = {1'b1, 3'd1, 9'd170, 9'd66, 9'd196};   // MUL_K q1ux
            w.m[1] = {1'b1, 3'd1, 9'd166, 9'd70, 9'd197};   // MUL_K q2ux
            w.m[2] = {1'b1, 3'd1, 9'd170, 9'd68, 9'd205};   // MUL_K q2uy
          end
          6'd11: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd81, 9'd84, 9'd91};   // ADD_T Sb01CB
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd196, 9'd197, 9'd198};   // ADD_N nux
            w.m[0] = {1'b1, 3'd1, 9'd189, 9'd66, 9'd200};   // MUL_K q1vx
            w.m[1] = {1'b1, 3'd1, 9'd185, 9'd70, 9'd201};   // MUL_K q2vx
            w.m[2] = {1'b1, 3'd1, 9'd168, 9'd70, 9'd204};   // MUL_K q1uy
            w.m[3] = {1'b1, 3'd1, 9'd187, 9'd70, 9'd208};   // MUL_K q1vy
          end
          6'd12: begin
            w.m[1] = {1'b1, 3'd0, 9'd11, 9'd59, 9'd85};   // MUL_T tcCB1
            w.m[2] = {1'b1, 3'd0, 9'd13, 9'd52, 9'd99};   // MUL_T taCG0
            w.m[3] = {1'b1, 3'd0, 9'd13, 9'd53, 9'd100};   // MUL_T tbCG0
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd200, 9'd201, 9'd202};   // ADD_N nvx
            w.a[1] = {1'b1, 3'd3, 1'b0, 9'd204, 9'd205, 9'd206};   // ADD_N nuy
            w.m[0] = {1'b1, 3'd1, 9'd189, 9'd68, 9'd209};   // MUL_K q2vy
          end
          6'd13: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd82, 9'd85, 9'd93};   // ADD_T Sc01CB
            w.m[1] = {1'b1, 3'd0, 9'd13, 9'd54, 9'd101};   // MUL_T tcCG0
            w.m[2] = {1'b1, 3'd0, 9'd14, 9'd57, 9'd102};   // MUL_T taCG1
            w.m[3] = {1'b1, 3'd0, 9'd14, 9'd58, 9'd103};   // MUL_T tbCG1
            w.m[0] = {1'b1, 3'd2, 9'd198, 9'd195, 9'd199};   // MUL_Q nqux
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd208, 9'd209, 9'd210};   // ADD_N nvy
          end
          6'd14: begin
            w.m[2] = {1'b1, 3'd0, 9'd14, 9'd59, 9'd104};   // MUL_T tcCG1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd99, 9'd102, 9'd108};   // ADD_T Sa01CG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd100, 9'd103, 9'd110};   // ADD_T Sb01CG
            w.m[3] = {1'b1, 3'd0, 9'd16, 9'd52, 9'd118};   // MUL_T taCR0
            w.m[0] = {1'b1, 3'd2, 9'd202, 9'd195, 9'd203};   // MUL_Q nqvx
            w.m[1] = {1'b1, 3'd2, 9'd206, 9'd195, 9'd207};   // MUL_Q nquy
          end
          6'd15: begin
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd101, 9'd104, 9'd112};   // ADD_T Sc01CG
            w.m[1] = {1'b1, 3'd0, 9'd16, 9'd53, 9'd119};   // MUL_T tbCR0
            w.m[2] = {1'b1, 3'd0, 9'd16, 9'd54, 9'd120};   // MUL_T tcCR0
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd57, 9'd121};   // MUL_T taCR1
            w.m[0] = {1'b1, 3'd2, 9'd210, 9'd195, 9'd211};   // MUL_Q nqvy
            w.a[0] = {1'b1, 3'd4, 1'b0, 9'd199, 9'd203, 9'd212};   // ADD_LX lhix
            w.a[1] = {1'b1, 3'd5, 1'b0, 9'd199, 9'd203, 9'd213};   // ADD_LN llox
          end
          6'd16: begin
            w.m[0] = {1'b1, 3'd0, 9'd17, 9'd58, 9'd122};   // MUL_T tbCR1
            w.m[1] = {1'b1, 3'd0, 9'd17, 9'd59, 9'd123};   // MUL_T tcCR1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd118, 9'd121, 9'd127};   // ADD_T Sa01CR
            w.m[2] = {1'b1, 3'd0, 9'd19, 9'd52, 9'd137};   // MUL_T taCA0
            w.m[3] = {1'b1, 3'd0, 9'd19, 9'd53, 9'd138};   // MUL_T tbCA0
            w.a[0] = {1'b1, 3'd4, 1'b0, 9'd207, 9'd211, 9'd217};   // ADD_LX lhiy
            w.a[1] = {1'b1, 3'd5, 1'b0, 9'd207, 9'd211, 9'd218};   // ADD_LN lloy
          end
          6'd17: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd119, 9'd122, 9'd129};   // ADD_T Sb01CR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd120, 9'd123, 9'd131};   // ADD_T Sc01CR
            w.m[0] = {1'b1, 3'd0, 9'd19, 9'd54, 9'd139};   // MUL_T tcCA0
            w.m[1] = {1'b1, 3'd0, 9'd20, 9'd57, 9'd140};   // MUL_T taCA1
            w.m[2] = {1'b1, 3'd0, 9'd20, 9'd58, 9'd141};   // MUL_T tbCA1
            w.m[3] = {1'b1, 3'd0, 9'd20, 9'd59, 9'd142};   // MUL_T tcCA1
            w.a[0] = {1'b1, 3'd7, 1'b0, 9'd212, 9'd213, 9'd214};   // ADD_P lsumx
          end
          6'd18: begin
            w.m[2] = {1'b1, 3'd0, 9'd12, 9'd62, 9'd86};   // MUL_T taCB2
            w.m[3] = {1'b1, 3'd0, 9'd12, 9'd63, 9'd87};   // MUL_T tbCB2
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd137, 9'd140, 9'd146};   // ADD_T Sa01CA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd138, 9'd141, 9'd148};   // ADD_T Sb01CA
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd139, 9'd142, 9'd150};   // ADD_T Sc01CA
            w.m[0] = {1'b1, 3'd5, 9'd213, 9'd28, 9'd215};   // MUL_P llessx
            w.a[0] = {1'b1, 3'd7, 1'b0, 9'd217, 9'd218, 9'd219};   // ADD_P lsumy
            w.m[1] = {1'b1, 3'd5, 9'd218, 9'd28, 9'd220};   // MUL_P llessy
          end
          6'd19: begin
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd64, 9'd88};   // MUL_T tcCB2
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd89, 9'd86, 9'd90};   // ADD_T SaCB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd91, 9'd87, 9'd92};   // ADD_T SbCB
            w.m[1] = {1'b1, 3'd0, 9'd15, 9'd62, 9'd105};   // MUL_T taCG2
            w.m[2] = {1'b1, 3'd0, 9'd15, 9'd63, 9'd106};   // MUL_T tbCG2
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd64, 9'd107};   // MUL_T tcCG2
            w.a[0] = {1'b1, 3'd7, 1'b1, 9'd214, 9'd215, 9'd216};   // ADD_P lenx
          end
          6'd20: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd93, 9'd88, 9'd94};   // ADD_T ScCB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd108, 9'd105, 9'd109};   // ADD_T SaCG
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd110, 9'd106, 9'd111};   // ADD_T SbCG
            w.m[0] = {1'b1, 3'd0, 9'd18, 9'd62, 9'd124};   // MUL_T taCR2
            w.m[1] = {1'b1, 3'd0, 9'd18, 9'd63, 9'd125};   // MUL_T tbCR2
            w.m[2] = {1'b1, 3'd0, 9'd18, 9'd64, 9'd126};   // MUL_T tcCR2
            w.m[3] = {1'b1, 3'd0, 9'd21, 9'd62, 9'd143};   // MUL_T taCA2
            w.a[0] = {1'b1, 3'd7, 1'b1, 9'd219, 9'd220, 9'd221};   // ADD_P leny
          end
          6'd21: begin
            w.m[2] = {1'b1, 3'd0, 9'd75, 9'd9, 9'd76};   // MUL_T mean
            w.m[3] = {1'b1, 3'd0, 9'd66, 9'd73, 9'd77};   // MUL_T A0W
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd112, 9'd107, 9'd113};   // ADD_T ScCG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd127, 9'd124, 9'd128};   // ADD_T SaCR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd129, 9'd125, 9'd130};   // ADD_T SbCR
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd131, 9'd126, 9'd132};   // ADD_T ScCR
            w.m[0] = {1'b1, 3'd0, 9'd21, 9'd63, 9'd144};   // MUL_T tbCA2
            w.m[1] = {1'b1, 3'd0, 9'd21, 9'd64, 9'd145};   // MUL_T tcCA2
          end
          6'd22: begin
            w.m[0] = {1'b1, 3'd0, 9'd68, 9'd73, 9'd78};   // MUL_T B0W
            w.m[1] = {1'b1, 3'd0, 9'd70, 9'd73, 9'd79};   // MUL_T C0W
            w.m[2] = {1'b1, 3'd0, 9'd24, 9'd76, 9'd171};   // MUL_T CfU
            w.m[3] = {1'b1, 3'd0, 9'd166, 9'd73, 9'd172};   // MUL_T A0U
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd146, 9'd143, 9'd147};   // ADD_T SaCA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd148, 9'd144, 9'd149};   // ADD_T SbCA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd150, 9'd145, 9'd151};   // ADD_T ScCA
            w.a[3] = {1'b1, 3'd6, 1'b0, 9'd216, 9'd221, 9'd222};   // ADD_BS best0
          end
          6'd23: begin
            w.w = {1'b1, 2'd0, 4'd0, 9'd76, 9'd79, 9'd78, 9'd77};   // W_PL wW
            w.m[0] = {1'b1, 3'd0, 9'd168, 9'd73, 9'd173};   // MUL_T B0U
            w.m[1] = {1'b1, 3'd0, 9'd170, 9'd73, 9'd174};   // MUL_T C0U
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd76, 9'd190};   // MUL_T CfV
            w.m[3] = {1'b1, 3'd0, 9'd185, 9'd73, 9'd191};   // MUL_T A0V
          end
          6'd24: begin
            w.w = {1'b1, 2'd0, 4'd1, 9'd171, 9'd174, 9'd173, 9'd172};   // W_PL wU
            w.m[0] = {1'b1, 3'd0, 9'd187, 9'd73, 9'd192};   // MUL_T B0V
            w.m[1] = {1'b1, 3'd0, 9'd189, 9'd73, 9'd193};   // MUL_T C0V
            w.m[2] = {1'b1, 3'd0, 9'd12, 9'd76, 9'd95};   // MUL_T CfCB
            w.m[3] = {1'b1, 3'd0, 9'd90, 9'd73, 9'd96};   // MUL_T A0CB
          end
          6'd25: begin
            w.w = {1'b1, 2'd0, 4'd2, 9'd190, 9'd193, 9'd192, 9'd191};   // W_PL wV
            w.m[0] = {1'b1, 3'd0, 9'd92, 9'd73, 9'd97};   // MUL_T B0CB
            w.m[1] = {1'b1, 3'd0, 9'd94, 9'd73, 9'd98};   // MUL_T C0CB
            w.m[2] = {1'b1, 3'd0, 9'd15, 9'd76, 9'd114};   // MUL_T CfCG
            w.m[3] = {1'b1, 3'd0, 9'd109, 9'd73, 9'd115};   // MUL_T A0CG
          end
          6'd26: begin
            w.w = {1'b1, 2'd0, 4'd3, 9'd95, 9'd98, 9'd97, 9'd96};   // W_PL wCB
            w.m[0] = {1'b1, 3'd0, 9'd111, 9'd73, 9'd116};   // MUL_T B0CG
            w.m[1] = {1'b1, 3'd0, 9'd113, 9'd73, 9'd117};   // MUL_T C0CG
            w.m[2] = {1'b1, 3'd0, 9'd18, 9'd76, 9'd133};   // MUL_T CfCR
            w.m[3] = {1'b1, 3'd0, 9'd128, 9'd73, 9'd134};   // MUL_T A0CR
          end
          6'd27: begin
            w.w = {1'b1, 2'd0, 4'd4, 9'd114, 9'd117, 9'd116, 9'd115};   // W_PL wCG
            w.m[0] = {1'b1, 3'd0, 9'd130, 9'd73, 9'd135};   // MUL_T B0CR
            w.m[1] = {1'b1, 3'd0, 9'd132, 9'd73, 9'd136};   // MUL_T C0CR
            w.m[2] = {1'b1, 3'd0, 9'd21, 9'd76, 9'd152};   // MUL_T CfCA
            w.m[3] = {1'b1, 3'd0, 9'd147, 9'd73, 9'd153};   // MUL_T A0CA
          end
          6'd28: begin
            w.w = {1'b1, 2'd0, 4'd5, 9'd133, 9'd136, 9'd135, 9'd134};   // W_PL wCR
            w.m[0] = {1'b1, 3'd0, 9'd149, 9'd73, 9'd154};   // MUL_T B0CA
            w.m[1] = {1'b1, 3'd0, 9'd151, 9'd73, 9'd155};   // MUL_T C0CA
            w.m[2] = {1'b1, 3'd4, 9'd222, 9'd195, 9'd223};   // MUL_B best
          end
          6'd29: begin
            w.w = {1'b1, 2'd0, 4'd6, 9'd152, 9'd155, 9'd154, 9'd153};   // W_PL wCA
          end
          6'd30: begin
            w.w = {1'b1, 2'd2, 4'd0, 9'd0, 9'd0, 9'd0, 9'd223};   // W_K wK
          end
          default: ;
        endcase
      end
      4'd3: begin   // TEX_M1
        case (pc)
          6'd0: begin
            w.m[0] = {1'b1, 3'd0, 9'd6, 9'd4, 9'd41};   // MUL_T pxy21
            w.m[1] = {1'b1, 3'd0, 9'd3, 9'd7, 9'd42};   // MUL_T pxy12
            w.m[2] = {1'b1, 3'd0, 9'd0, 9'd7, 9'd44};   // MUL_T pxy02
            w.m[3] = {1'b1, 3'd0, 9'd6, 9'd1, 9'd45};   // MUL_T pxy20
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd4, 9'd7, 9'd50};   // ADD_T dy0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd6, 9'd3, 9'd51};   // ADD_T dx0
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd7, 9'd1, 9'd55};   // ADD_T dy1
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd0, 9'd6, 9'd56};   // ADD_T dx1
          end
          6'd1: begin
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd42, 9'd41, 9'd43};   // ADD_T e0
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd45, 9'd44, 9'd46};   // ADD_T e1
            w.m[0] = {1'b1, 3'd0, 9'd3, 9'd1, 9'd47};   // MUL_T pxy10
            w.m[1] = {1'b1, 3'd0, 9'd0, 9'd4, 9'd48};   // MUL_T pxy01
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd1, 9'd4, 9'd60};   // ADD_T dy2
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd3, 9'd0, 9'd61};   // ADD_T dx2
          end
          6'd2: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd48, 9'd47, 9'd49};   // ADD_T e2
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd50, 9'd52};   // MUL_T wa0
            w.m[1] = {1'b1, 3'd0, 9'd2, 9'd51, 9'd53};   // MUL_T wb0
            w.m[2] = {1'b1, 3'd0, 9'd5, 9'd55, 9'd57};   // MUL_T wa1
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd56, 9'd58};   // MUL_T wb1
            w.a[1] = {1'b1, 3'd1, 1'b0, 9'd2, 9'd5, 9'd74};   // ADD_W m01
          end
          6'd3: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd52, 9'd57, 9'd65};   // ADD_T SaW01
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd53, 9'd58, 9'd67};   // ADD_T SbW01
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd43, 9'd46, 9'd71};   // ADD_T Sdet01
            w.m[0] = {1'b1, 3'd0, 9'd22, 9'd52, 9'd156};   // MUL_T taU0
            w.m[1] = {1'b1, 3'd0, 9'd22, 9'd53, 9'd157};   // MUL_T tbU0
            w.m[2] = {1'b1, 3'd0, 9'd23, 9'd57, 9'd159};   // MUL_T taU1
            w.m[3] = {1'b1, 3'd0, 9'd23, 9'd58, 9'd160};   // MUL_T tbU1
          end
          6'd4: begin
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd74, 9'd8, 9'd75};   // ADD_T msum
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd156, 9'd159, 9'd165};   // ADD_T Sa01U
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd157, 9'd160, 9'd167};   // ADD_T Sb01U
            w.m[0] = {1'b1, 3'd0, 9'd25, 9'd52, 9'd175};   // MUL_T taV0
            w.m[1] = {1'b1, 3'd0, 9'd25, 9'd53, 9'd176};   // MUL_T tbV0
            w.m[2] = {1'b1, 3'd0, 9'd26, 9'd57, 9'd178};   // MUL_T taV1
            w.m[3] = {1'b1, 3'd0, 9'd26, 9'd58, 9'd179};   // MUL_T tbV1
          end
          6'd5: begin
            w.m[2] = {1'b1, 3'd0, 9'd2, 9'd43, 9'd54};   // MUL_T wc0
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd46, 9'd59};   // MUL_T wc1
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd60, 9'd62};   // MUL_T wa2
            w.m[1] = {1'b1, 3'd0, 9'd8, 9'd61, 9'd63};   // MUL_T wb2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd71, 9'd49, 9'd72};   // ADD_T Sdet
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd175, 9'd178, 9'd184};   // ADD_T Sa01V
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd176, 9'd179, 9'd186};   // ADD_T Sb01V
          end
          6'd6: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd65, 9'd62, 9'd66};   // ADD_T SaW
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd67, 9'd63, 9'd68};   // ADD_T SbW
            w.m[0] = {1'b1, 3'd0, 9'd24, 9'd62, 9'd162};   // MUL_T taU2
            w.m[1] = {1'b1, 3'd0, 9'd24, 9'd63, 9'd163};   // MUL_T tbU2
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd62, 9'd181};   // MUL_T taV2
            w.m[3] = {1'b1, 3'd0, 9'd27, 9'd63, 9'd182};   // MUL_T tbV2
          end
          6'd7: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd49, 9'd64};   // MUL_T wc2
            w.m[1] = {1'b1, 3'd0, 9'd22, 9'd54, 9'd158};   // MUL_T tcU0
            w.m[2] = {1'b1, 3'd0, 9'd23, 9'd59, 9'd161};   // MUL_T tcU1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd165, 9'd162, 9'd166};   // ADD_T SaU
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd167, 9'd163, 9'd168};   // ADD_T SbU
            w.m[3] = {1'b1, 3'd0, 9'd25, 9'd54, 9'd177};   // MUL_T tcV0
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd184, 9'd181, 9'd185};   // ADD_T SaV
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd186, 9'd182, 9'd187};   // ADD_T SbV
            w.r = {1'b1, 1'b1, 9'd72, 9'd194};   // RCP_M minv
          end
          6'd8: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd54, 9'd64, 9'd69};   // ADD_T ScW02
            w.r = {1'b1, 1'b0, 9'd72, 9'd73};   // RCP_T inv
            w.m[1] = {1'b1, 3'd0, 9'd24, 9'd64, 9'd164};   // MUL_T tcU2
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd158, 9'd161, 9'd169};   // ADD_T Sc01U
            w.m[0] = {1'b1, 3'd0, 9'd26, 9'd59, 9'd180};   // MUL_T tcV1
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd64, 9'd183};   // MUL_T tcV2
            w.m[3] = {1'b1, 3'd0, 9'd66, 9'd0, 9'd232};   // MUL_T d1aW
          end
          6'd9: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd177, 9'd180, 9'd188};   // ADD_T Sc01V
            w.m[0] = {1'b1, 3'd0, 9'd166, 9'd0, 9'd224};   // MUL_T d1aU
            w.m[1] = {1'b1, 3'd0, 9'd168, 9'd1, 9'd225};   // MUL_T d1bU
            w.m[2] = {1'b1, 3'd0, 9'd185, 9'd0, 9'd228};   // MUL_T d1aV
            w.m[3] = {1'b1, 3'd0, 9'd187, 9'd1, 9'd229};   // MUL_T d1bV
          end
          6'd10: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd69, 9'd59, 9'd70};   // ADD_T ScW
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd169, 9'd164, 9'd170};   // ADD_T ScU
            w.m[2] = {1'b1, 3'd0, 9'd10, 9'd52, 9'd80};   // MUL_T taCB0
            w.m[3] = {1'b1, 3'd0, 9'd10, 9'd53, 9'd81};   // MUL_T tbCB0
            w.m[1] = {1'b1, 3'd3, 9'd194, 9'd194, 9'd195};   // MUL_I2 inv2
            w.a[2] = {1'b1, 3'd2, 1'b0, 9'd224, 9'd225, 9'd226};   // ADD_R d1abU
            w.a[3] = {1'b1, 3'd2, 1'b0, 9'd228, 9'd229, 9'd230};   // ADD_R d1abV
            w.m[0] = {1'b1, 3'd0, 9'd68, 9'd1, 9'd233};   // MUL_T d1bW
          end
          6'd11: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd188, 9'd183, 9'd189};   // ADD_T ScV
            w.m[0] = {1'b1, 3'd0, 9'd10, 9'd54, 9'd82};   // MUL_T tcCB0
            w.m[1] = {1'b1, 3'd0, 9'd11, 9'd57, 9'd83};   // MUL_T taCB1
            w.m[2] = {1'b1, 3'd0, 9'd11, 9'd58, 9'd84};   // MUL_T tbCB1
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd59, 9'd85};   // MUL_T tcCB1
            w.a[1] = {1'b1, 3'd2, 1'b0, 9'd232, 9'd233, 9'd234};   // ADD_R d1abW
          end
          6'd12: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd80, 9'd83, 9'd89};   // ADD_T Sa01CB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd81, 9'd84, 9'd91};   // ADD_T Sb01CB
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd82, 9'd85, 9'd93};   // ADD_T Sc01CB
            w.m[0] = {1'b1, 3'd0, 9'd13, 9'd52, 9'd99};   // MUL_T taCG0
            w.m[1] = {1'b1, 3'd0, 9'd13, 9'd53, 9'd100};   // MUL_T tbCG0
            w.m[2] = {1'b1, 3'd0, 9'd13, 9'd54, 9'd101};   // MUL_T tcCG0
            w.m[3] = {1'b1, 3'd0, 9'd14, 9'd57, 9'd102};   // MUL_T taCG1
            w.a[0] = {1'b1, 3'd2, 1'b0, 9'd226, 9'd170, 9'd227};   // ADD_R d1U
          end
          6'd13: begin
            w.m[0] = {1'b1, 3'd0, 9'd14, 9'd58, 9'd103};   // MUL_T tbCG1
            w.m[1] = {1'b1, 3'd0, 9'd14, 9'd59, 9'd104};   // MUL_T tcCG1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd99, 9'd102, 9'd108};   // ADD_T Sa01CG
            w.m[2] = {1'b1, 3'd0, 9'd16, 9'd52, 9'd118};   // MUL_T taCR0
            w.m[3] = {1'b1, 3'd0, 9'd16, 9'd53, 9'd119};   // MUL_T tbCR0
            w.a[0] = {1'b1, 3'd2, 1'b0, 9'd230, 9'd189, 9'd231};   // ADD_R d1V
            w.a[1] = {1'b1, 3'd2, 1'b0, 9'd234, 9'd70, 9'd235};   // ADD_R d1W
          end
          6'd14: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd100, 9'd103, 9'd110};   // ADD_T Sb01CG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd101, 9'd104, 9'd112};   // ADD_T Sc01CG
            w.m[2] = {1'b1, 3'd0, 9'd16, 9'd54, 9'd120};   // MUL_T tcCR0
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd57, 9'd121};   // MUL_T taCR1
            w.m[0] = {1'b1, 3'd1, 9'd227, 9'd66, 9'd196};   // MUL_K q1ux
            w.m[1] = {1'b1, 3'd1, 9'd227, 9'd68, 9'd205};   // MUL_K q2uy
          end
          6'd15: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd118, 9'd121, 9'd127};   // ADD_T Sa01CR
            w.m[0] = {1'b1, 3'd1, 9'd166, 9'd235, 9'd197};   // MUL_K q2ux
            w.m[1] = {1'b1, 3'd1, 9'd231, 9'd66, 9'd200};   // MUL_K q1vx
            w.m[2] = {1'b1, 3'd1, 9'd185, 9'd235, 9'd201};   // MUL_K q2vx
            w.m[3] = {1'b1, 3'd1, 9'd168, 9'd235, 9'd204};   // MUL_K q1uy
          end
          6'd16: begin
            w.m[2] = {1'b1, 3'd0, 9'd17, 9'd58, 9'd122};   // MUL_T tbCR1
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd59, 9'd123};   // MUL_T tcCR1
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd196, 9'd197, 9'd198};   // ADD_N nux
            w.a[1] = {1'b1, 3'd3, 1'b0, 9'd200, 9'd201, 9'd202};   // ADD_N nvx
            w.a[2] = {1'b1, 3'd3, 1'b0, 9'd204, 9'd205, 9'd206};   // ADD_N nuy
            w.m[0] = {1'b1, 3'd1, 9'd187, 9'd235, 9'd208};   // MUL_K q1vy
            w.m[1] = {1'b1, 3'd1, 9'd231, 9'd68, 9'd209};   // MUL_K q2vy
          end
          6'd17: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd119, 9'd122, 9'd129};   // ADD_T Sb01CR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd120, 9'd123, 9'd131};   // ADD_T Sc01CR
            w.m[0] = {1'b1, 3'd0, 9'd19, 9'd52, 9'd137};   // MUL_T taCA0
            w.m[1] = {1'b1, 3'd0, 9'd19, 9'd53, 9'd138};   // MUL_T tbCA0
            w.m[2] = {1'b1, 3'd0, 9'd19, 9'd54, 9'd139};   // MUL_T tcCA0
            w.m[3] = {1'b1, 3'd0, 9'd20, 9'd57, 9'd140};   // MUL_T taCA1
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd208, 9'd209, 9'd210};   // ADD_N nvy
          end
          6'd18: begin
            w.m[3] = {1'b1, 3'd0, 9'd20, 9'd58, 9'd141};   // MUL_T tbCA1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd137, 9'd140, 9'd146};   // ADD_T Sa01CA
            w.m[0] = {1'b1, 3'd2, 9'd198, 9'd195, 9'd199};   // MUL_Q nqux
            w.m[1] = {1'b1, 3'd2, 9'd202, 9'd195, 9'd203};   // MUL_Q nqvx
            w.m[2] = {1'b1, 3'd2, 9'd206, 9'd195, 9'd207};   // MUL_Q nquy
          end
          6'd19: begin
            w.m[2] = {1'b1, 3'd0, 9'd12, 9'd62, 9'd86};   // MUL_T taCB2
            w.m[3] = {1'b1, 3'd0, 9'd12, 9'd63, 9'd87};   // MUL_T tbCB2
            w.m[1] = {1'b1, 3'd0, 9'd20, 9'd59, 9'd142};   // MUL_T tcCA1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd138, 9'd141, 9'd148};   // ADD_T Sb01CA
            w.m[0] = {1'b1, 3'd2, 9'd210, 9'd195, 9'd211};   // MUL_Q nqvy
            w.a[0] = {1'b1, 3'd4, 1'b0, 9'd199, 9'd203, 9'd212};   // ADD_LX lhix
            w.a[1] = {1'b1, 3'd5, 1'b0, 9'd199, 9'd203, 9'd213};   // ADD_LN llox
          end
          6'd20: begin
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd64, 9'd88};   // MUL_T tcCB2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd89, 9'd86, 9'd90};   // ADD_T SaCB
            w.m[1] = {1'b1, 3'd0, 9'd15, 9'd62, 9'd105};   // MUL_T taCG2
            w.m[2] = {1'b1, 3'd0, 9'd15, 9'd63, 9'd106};   // MUL_T tbCG2
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd64, 9'd107};   // MUL_T tcCG2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd139, 9'd142, 9'd150};   // ADD_T Sc01CA
            w.a[0] = {1'b1, 3'd4, 1'b0, 9'd207, 9'd211, 9'd217};   // ADD_LX lhiy
            w.a[1] = {1'b1, 3'd5, 1'b0, 9'd207, 9'd211, 9'd218};   // ADD_LN lloy
          end
          6'd21: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd91, 9'd87, 9'd92};   // ADD_T SbCB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd93, 9'd88, 9'd94};   // ADD_T ScCB
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd108, 9'd105, 9'd109};   // ADD_T SaCG
            w.m[1] = {1'b1, 3'd0, 9'd18, 9'd62, 9'd124};   // MUL_T taCR2
            w.m[2] = {1'b1, 3'd0, 9'd18, 9'd63, 9'd125};   // MUL_T tbCR2
            w.m[3] = {1'b1, 3'd0, 9'd18, 9'd64, 9'd126};   // MUL_T tcCR2
            w.a[0] = {1'b1, 3'd7, 1'b0, 9'd212, 9'd213, 9'd214};   // ADD_P lsumx
            w.m[0] = {1'b1, 3'd5, 9'd213, 9'd28, 9'd215};   // MUL_P llessx
          end
          6'd22: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd110, 9'd106, 9'd111};   // ADD_T SbCG
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd112, 9'd107, 9'd113};   // ADD_T ScCG
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd127, 9'd124, 9'd128};   // ADD_T SaCR
            w.m[1] = {1'b1, 3'd0, 9'd21, 9'd62, 9'd143};   // MUL_T taCA2
            w.m[2] = {1'b1, 3'd0, 9'd21, 9'd63, 9'd144};   // MUL_T tbCA2
            w.m[3] = {1'b1, 3'd0, 9'd21, 9'd64, 9'd145};   // MUL_T tcCA2
            w.a[0] = {1'b1, 3'd7, 1'b0, 9'd217, 9'd218, 9'd219};   // ADD_P lsumy
            w.m[0] = {1'b1, 3'd5, 9'd218, 9'd28, 9'd220};   // MUL_P llessy
          end
          6'd23: begin
            w.m[0] = {1'b1, 3'd0, 9'd75, 9'd9, 9'd76};   // MUL_T mean
            w.m[1] = {1'b1, 3'd0, 9'd66, 9'd73, 9'd77};   // MUL_T A0W
            w.m[2] = {1'b1, 3'd0, 9'd68, 9'd73, 9'd78};   // MUL_T B0W
            w.m[3] = {1'b1, 3'd0, 9'd70, 9'd73, 9'd79};   // MUL_T C0W
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd129, 9'd125, 9'd130};   // ADD_T SbCR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd131, 9'd126, 9'd132};   // ADD_T ScCR
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd146, 9'd143, 9'd147};   // ADD_T SaCA
            w.a[0] = {1'b1, 3'd7, 1'b1, 9'd214, 9'd215, 9'd216};   // ADD_P lenx
          end
          6'd24: begin
            w.w = {1'b1, 2'd0, 4'd0, 9'd76, 9'd79, 9'd78, 9'd77};   // W_PL wW
            w.m[0] = {1'b1, 3'd0, 9'd24, 9'd76, 9'd171};   // MUL_T CfU
            w.m[1] = {1'b1, 3'd0, 9'd166, 9'd73, 9'd172};   // MUL_T A0U
            w.m[2] = {1'b1, 3'd0, 9'd168, 9'd73, 9'd173};   // MUL_T B0U
            w.m[3] = {1'b1, 3'd0, 9'd170, 9'd73, 9'd174};   // MUL_T C0U
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd148, 9'd144, 9'd149};   // ADD_T SbCA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd150, 9'd145, 9'd151};   // ADD_T ScCA
            w.a[0] = {1'b1, 3'd7, 1'b1, 9'd219, 9'd220, 9'd221};   // ADD_P leny
          end
          6'd25: begin
            w.w = {1'b1, 2'd0, 4'd1, 9'd171, 9'd174, 9'd173, 9'd172};   // W_PL wU
            w.m[0] = {1'b1, 3'd0, 9'd27, 9'd76, 9'd190};   // MUL_T CfV
            w.m[1] = {1'b1, 3'd0, 9'd185, 9'd73, 9'd191};   // MUL_T A0V
            w.m[2] = {1'b1, 3'd0, 9'd187, 9'd73, 9'd192};   // MUL_T B0V
            w.m[3] = {1'b1, 3'd0, 9'd189, 9'd73, 9'd193};   // MUL_T C0V
          end
          6'd26: begin
            w.w = {1'b1, 2'd0, 4'd2, 9'd190, 9'd193, 9'd192, 9'd191};   // W_PL wV
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd76, 9'd95};   // MUL_T CfCB
            w.m[1] = {1'b1, 3'd0, 9'd90, 9'd73, 9'd96};   // MUL_T A0CB
            w.m[2] = {1'b1, 3'd0, 9'd92, 9'd73, 9'd97};   // MUL_T B0CB
            w.m[3] = {1'b1, 3'd0, 9'd94, 9'd73, 9'd98};   // MUL_T C0CB
            w.a[0] = {1'b1, 3'd6, 1'b0, 9'd216, 9'd221, 9'd222};   // ADD_BS best0
          end
          6'd27: begin
            w.w = {1'b1, 2'd0, 4'd3, 9'd95, 9'd98, 9'd97, 9'd96};   // W_PL wCB
            w.m[0] = {1'b1, 3'd0, 9'd15, 9'd76, 9'd114};   // MUL_T CfCG
            w.m[1] = {1'b1, 3'd0, 9'd109, 9'd73, 9'd115};   // MUL_T A0CG
            w.m[2] = {1'b1, 3'd0, 9'd111, 9'd73, 9'd116};   // MUL_T B0CG
            w.m[3] = {1'b1, 3'd0, 9'd113, 9'd73, 9'd117};   // MUL_T C0CG
          end
          6'd28: begin
            w.w = {1'b1, 2'd0, 4'd4, 9'd114, 9'd117, 9'd116, 9'd115};   // W_PL wCG
            w.m[0] = {1'b1, 3'd0, 9'd18, 9'd76, 9'd133};   // MUL_T CfCR
            w.m[1] = {1'b1, 3'd0, 9'd128, 9'd73, 9'd134};   // MUL_T A0CR
            w.m[2] = {1'b1, 3'd0, 9'd130, 9'd73, 9'd135};   // MUL_T B0CR
            w.m[3] = {1'b1, 3'd0, 9'd132, 9'd73, 9'd136};   // MUL_T C0CR
          end
          6'd29: begin
            w.w = {1'b1, 2'd0, 4'd5, 9'd133, 9'd136, 9'd135, 9'd134};   // W_PL wCR
            w.m[0] = {1'b1, 3'd0, 9'd21, 9'd76, 9'd152};   // MUL_T CfCA
            w.m[1] = {1'b1, 3'd0, 9'd147, 9'd73, 9'd153};   // MUL_T A0CA
            w.m[2] = {1'b1, 3'd0, 9'd149, 9'd73, 9'd154};   // MUL_T B0CA
            w.m[3] = {1'b1, 3'd0, 9'd151, 9'd73, 9'd155};   // MUL_T C0CA
          end
          6'd30: begin
            w.w = {1'b1, 2'd0, 4'd6, 9'd152, 9'd155, 9'd154, 9'd153};   // W_PL wCA
            w.m[0] = {1'b1, 3'd4, 9'd222, 9'd195, 9'd223};   // MUL_B best
          end
          6'd31: begin
            w.w = {1'b1, 2'd2, 4'd0, 9'd0, 9'd0, 9'd0, 9'd223};   // W_K wK
          end
          default: ;
        endcase
      end
      4'd4: begin   // TEX_O
        case (pc)
          6'd0: begin
            w.m[0] = {1'b1, 3'd0, 9'd6, 9'd4, 9'd41};   // MUL_T pxy21
            w.m[1] = {1'b1, 3'd0, 9'd3, 9'd7, 9'd42};   // MUL_T pxy12
            w.m[2] = {1'b1, 3'd0, 9'd0, 9'd7, 9'd44};   // MUL_T pxy02
            w.m[3] = {1'b1, 3'd0, 9'd6, 9'd1, 9'd45};   // MUL_T pxy20
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd4, 9'd7, 9'd50};   // ADD_T dy0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd6, 9'd3, 9'd51};   // ADD_T dx0
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd7, 9'd1, 9'd55};   // ADD_T dy1
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd0, 9'd6, 9'd56};   // ADD_T dx1
          end
          6'd1: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd42, 9'd41, 9'd43};   // ADD_T e0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd45, 9'd44, 9'd46};   // ADD_T e1
            w.m[0] = {1'b1, 3'd0, 9'd3, 9'd1, 9'd47};   // MUL_T pxy10
            w.m[1] = {1'b1, 3'd0, 9'd0, 9'd4, 9'd48};   // MUL_T pxy01
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd1, 9'd4, 9'd60};   // ADD_T dy2
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd3, 9'd0, 9'd61};   // ADD_T dx2
          end
          6'd2: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd48, 9'd47, 9'd49};   // ADD_T e2
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd50, 9'd52};   // MUL_T wa0
            w.m[1] = {1'b1, 3'd0, 9'd2, 9'd51, 9'd53};   // MUL_T wb0
            w.m[2] = {1'b1, 3'd0, 9'd5, 9'd55, 9'd57};   // MUL_T wa1
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd56, 9'd58};   // MUL_T wb1
            w.a[1] = {1'b1, 3'd1, 1'b0, 9'd2, 9'd5, 9'd74};   // ADD_W m01
          end
          6'd3: begin
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd43, 9'd54};   // MUL_T wc0
            w.m[1] = {1'b1, 3'd0, 9'd5, 9'd46, 9'd59};   // MUL_T wc1
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd52, 9'd57, 9'd65};   // ADD_T SaW01
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd53, 9'd58, 9'd67};   // ADD_T SbW01
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd43, 9'd46, 9'd71};   // ADD_T Sdet01
            w.m[2] = {1'b1, 3'd0, 9'd22, 9'd52, 9'd156};   // MUL_T taU0
            w.m[3] = {1'b1, 3'd0, 9'd22, 9'd53, 9'd157};   // MUL_T tbU0
          end
          6'd4: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd49, 9'd64};   // MUL_T wc2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd74, 9'd8, 9'd75};   // ADD_T msum
            w.m[1] = {1'b1, 3'd0, 9'd22, 9'd54, 9'd158};   // MUL_T tcU0
            w.m[2] = {1'b1, 3'd0, 9'd23, 9'd57, 9'd159};   // MUL_T taU1
            w.m[3] = {1'b1, 3'd0, 9'd23, 9'd58, 9'd160};   // MUL_T tbU1
          end
          6'd5: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd54, 9'd64, 9'd69};   // ADD_T ScW02
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd71, 9'd49, 9'd72};   // ADD_T Sdet
            w.m[0] = {1'b1, 3'd0, 9'd23, 9'd59, 9'd161};   // MUL_T tcU1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd156, 9'd159, 9'd165};   // ADD_T Sa01U
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd157, 9'd160, 9'd167};   // ADD_T Sb01U
            w.m[1] = {1'b1, 3'd0, 9'd25, 9'd52, 9'd175};   // MUL_T taV0
            w.m[2] = {1'b1, 3'd0, 9'd25, 9'd53, 9'd176};   // MUL_T tbV0
            w.m[3] = {1'b1, 3'd0, 9'd25, 9'd54, 9'd177};   // MUL_T tcV0
          end
          6'd6: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd158, 9'd161, 9'd169};   // ADD_T Sc01U
            w.m[0] = {1'b1, 3'd0, 9'd26, 9'd57, 9'd178};   // MUL_T taV1
            w.m[1] = {1'b1, 3'd0, 9'd26, 9'd58, 9'd179};   // MUL_T tbV1
            w.m[2] = {1'b1, 3'd0, 9'd26, 9'd59, 9'd180};   // MUL_T tcV1
            w.m[3] = {1'b1, 3'd0, 9'd10, 9'd52, 9'd80};   // MUL_T taCB0
          end
          6'd7: begin
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd69, 9'd59, 9'd70};   // ADD_T ScW
            w.r = {1'b1, 1'b0, 9'd72, 9'd73};   // RCP_T inv
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd175, 9'd178, 9'd184};   // ADD_T Sa01V
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd176, 9'd179, 9'd186};   // ADD_T Sb01V
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd177, 9'd180, 9'd188};   // ADD_T Sc01V
            w.m[0] = {1'b1, 3'd0, 9'd10, 9'd53, 9'd81};   // MUL_T tbCB0
            w.m[1] = {1'b1, 3'd0, 9'd10, 9'd54, 9'd82};   // MUL_T tcCB0
            w.m[2] = {1'b1, 3'd0, 9'd11, 9'd57, 9'd83};   // MUL_T taCB1
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd58, 9'd84};   // MUL_T tbCB1
          end
          6'd8: begin
            w.m[0] = {1'b1, 3'd0, 9'd11, 9'd59, 9'd85};   // MUL_T tcCB1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd80, 9'd83, 9'd89};   // ADD_T Sa01CB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd81, 9'd84, 9'd91};   // ADD_T Sb01CB
            w.m[1] = {1'b1, 3'd0, 9'd13, 9'd52, 9'd99};   // MUL_T taCG0
            w.m[2] = {1'b1, 3'd0, 9'd13, 9'd53, 9'd100};   // MUL_T tbCG0
            w.m[3] = {1'b1, 3'd0, 9'd13, 9'd54, 9'd101};   // MUL_T tcCG0
          end
          6'd9: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd82, 9'd85, 9'd93};   // ADD_T Sc01CB
            w.m[0] = {1'b1, 3'd0, 9'd14, 9'd57, 9'd102};   // MUL_T taCG1
            w.m[1] = {1'b1, 3'd0, 9'd14, 9'd58, 9'd103};   // MUL_T tbCG1
            w.m[2] = {1'b1, 3'd0, 9'd14, 9'd59, 9'd104};   // MUL_T tcCG1
            w.m[3] = {1'b1, 3'd0, 9'd16, 9'd52, 9'd118};   // MUL_T taCR0
          end
          6'd10: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd99, 9'd102, 9'd108};   // ADD_T Sa01CG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd100, 9'd103, 9'd110};   // ADD_T Sb01CG
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd101, 9'd104, 9'd112};   // ADD_T Sc01CG
            w.m[0] = {1'b1, 3'd0, 9'd16, 9'd53, 9'd119};   // MUL_T tbCR0
            w.m[1] = {1'b1, 3'd0, 9'd16, 9'd54, 9'd120};   // MUL_T tcCR0
            w.m[2] = {1'b1, 3'd0, 9'd17, 9'd57, 9'd121};   // MUL_T taCR1
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd58, 9'd122};   // MUL_T tbCR1
          end
          6'd11: begin
            w.m[0] = {1'b1, 3'd0, 9'd17, 9'd59, 9'd123};   // MUL_T tcCR1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd118, 9'd121, 9'd127};   // ADD_T Sa01CR
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd119, 9'd122, 9'd129};   // ADD_T Sb01CR
            w.m[1] = {1'b1, 3'd0, 9'd19, 9'd52, 9'd137};   // MUL_T taCA0
            w.m[2] = {1'b1, 3'd0, 9'd19, 9'd53, 9'd138};   // MUL_T tbCA0
            w.m[3] = {1'b1, 3'd0, 9'd19, 9'd54, 9'd139};   // MUL_T tcCA0
          end
          6'd12: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd120, 9'd123, 9'd131};   // ADD_T Sc01CR
            w.m[0] = {1'b1, 3'd0, 9'd20, 9'd57, 9'd140};   // MUL_T taCA1
            w.m[1] = {1'b1, 3'd0, 9'd20, 9'd58, 9'd141};   // MUL_T tbCA1
            w.m[2] = {1'b1, 3'd0, 9'd20, 9'd59, 9'd142};   // MUL_T tcCA1
            w.m[3] = {1'b1, 3'd0, 9'd29, 9'd52, 9'd236};   // MUL_T taOB0
          end
          6'd13: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd137, 9'd140, 9'd146};   // ADD_T Sa01CA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd138, 9'd141, 9'd148};   // ADD_T Sb01CA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd139, 9'd142, 9'd150};   // ADD_T Sc01CA
            w.m[0] = {1'b1, 3'd0, 9'd29, 9'd53, 9'd237};   // MUL_T tbOB0
            w.m[1] = {1'b1, 3'd0, 9'd29, 9'd54, 9'd238};   // MUL_T tcOB0
            w.m[2] = {1'b1, 3'd0, 9'd30, 9'd57, 9'd239};   // MUL_T taOB1
            w.m[3] = {1'b1, 3'd0, 9'd30, 9'd58, 9'd240};   // MUL_T tbOB1
          end
          6'd14: begin
            w.m[0] = {1'b1, 3'd0, 9'd30, 9'd59, 9'd241};   // MUL_T tcOB1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd236, 9'd239, 9'd245};   // ADD_T Sa01OB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd237, 9'd240, 9'd247};   // ADD_T Sb01OB
            w.m[1] = {1'b1, 3'd0, 9'd32, 9'd52, 9'd255};   // MUL_T taOG0
            w.m[2] = {1'b1, 3'd0, 9'd32, 9'd53, 9'd256};   // MUL_T tbOG0
            w.m[3] = {1'b1, 3'd0, 9'd32, 9'd54, 9'd257};   // MUL_T tcOG0
          end
          6'd15: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd238, 9'd241, 9'd249};   // ADD_T Sc01OB
            w.m[0] = {1'b1, 3'd0, 9'd33, 9'd57, 9'd258};   // MUL_T taOG1
            w.m[1] = {1'b1, 3'd0, 9'd33, 9'd58, 9'd259};   // MUL_T tbOG1
            w.m[2] = {1'b1, 3'd0, 9'd33, 9'd59, 9'd260};   // MUL_T tcOG1
            w.m[3] = {1'b1, 3'd0, 9'd35, 9'd52, 9'd274};   // MUL_T taOR0
          end
          6'd16: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd255, 9'd258, 9'd264};   // ADD_T Sa01OG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd256, 9'd259, 9'd266};   // ADD_T Sb01OG
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd257, 9'd260, 9'd268};   // ADD_T Sc01OG
            w.m[0] = {1'b1, 3'd0, 9'd35, 9'd53, 9'd275};   // MUL_T tbOR0
            w.m[1] = {1'b1, 3'd0, 9'd35, 9'd54, 9'd276};   // MUL_T tcOR0
            w.m[2] = {1'b1, 3'd0, 9'd36, 9'd57, 9'd277};   // MUL_T taOR1
            w.m[3] = {1'b1, 3'd0, 9'd36, 9'd58, 9'd278};   // MUL_T tbOR1
          end
          6'd17: begin
            w.m[0] = {1'b1, 3'd0, 9'd36, 9'd59, 9'd279};   // MUL_T tcOR1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd274, 9'd277, 9'd283};   // ADD_T Sa01OR
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd275, 9'd278, 9'd285};   // ADD_T Sb01OR
            w.m[1] = {1'b1, 3'd0, 9'd38, 9'd52, 9'd293};   // MUL_T taOA0
            w.m[2] = {1'b1, 3'd0, 9'd38, 9'd53, 9'd294};   // MUL_T tbOA0
            w.m[3] = {1'b1, 3'd0, 9'd38, 9'd54, 9'd295};   // MUL_T tcOA0
          end
          6'd18: begin
            w.m[3] = {1'b1, 3'd0, 9'd8, 9'd60, 9'd62};   // MUL_T wa2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd276, 9'd279, 9'd287};   // ADD_T Sc01OR
            w.m[0] = {1'b1, 3'd0, 9'd39, 9'd57, 9'd296};   // MUL_T taOA1
            w.m[1] = {1'b1, 3'd0, 9'd39, 9'd58, 9'd297};   // MUL_T tbOA1
            w.m[2] = {1'b1, 3'd0, 9'd39, 9'd59, 9'd298};   // MUL_T tcOA1
          end
          6'd19: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd61, 9'd63};   // MUL_T wb2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd65, 9'd62, 9'd66};   // ADD_T SaW
            w.m[1] = {1'b1, 3'd0, 9'd24, 9'd62, 9'd162};   // MUL_T taU2
            w.m[2] = {1'b1, 3'd0, 9'd24, 9'd64, 9'd164};   // MUL_T tcU2
            w.m[3] = {1'b1, 3'd0, 9'd27, 9'd62, 9'd181};   // MUL_T taV2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd293, 9'd296, 9'd302};   // ADD_T Sa01OA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd294, 9'd297, 9'd304};   // ADD_T Sb01OA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd295, 9'd298, 9'd306};   // ADD_T Sc01OA
          end
          6'd20: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd67, 9'd63, 9'd68};   // ADD_T SbW
            w.m[0] = {1'b1, 3'd0, 9'd24, 9'd63, 9'd163};   // MUL_T tbU2
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd165, 9'd162, 9'd166};   // ADD_T SaU
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd169, 9'd164, 9'd170};   // ADD_T ScU
            w.m[1] = {1'b1, 3'd0, 9'd27, 9'd63, 9'd182};   // MUL_T tbV2
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd64, 9'd183};   // MUL_T tcV2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd184, 9'd181, 9'd185};   // ADD_T SaV
            w.m[3] = {1'b1, 3'd0, 9'd12, 9'd62, 9'd86};   // MUL_T taCB2
          end
          6'd21: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd167, 9'd163, 9'd168};   // ADD_T SbU
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd186, 9'd182, 9'd187};   // ADD_T SbV
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd188, 9'd183, 9'd189};   // ADD_T ScV
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd63, 9'd87};   // MUL_T tbCB2
            w.m[1] = {1'b1, 3'd0, 9'd12, 9'd64, 9'd88};   // MUL_T tcCB2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd89, 9'd86, 9'd90};   // ADD_T SaCB
            w.m[2] = {1'b1, 3'd0, 9'd15, 9'd62, 9'd105};   // MUL_T taCG2
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd63, 9'd106};   // MUL_T tbCG2
          end
          6'd22: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd91, 9'd87, 9'd92};   // ADD_T SbCB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd93, 9'd88, 9'd94};   // ADD_T ScCB
            w.m[0] = {1'b1, 3'd0, 9'd15, 9'd64, 9'd107};   // MUL_T tcCG2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd108, 9'd105, 9'd109};   // ADD_T SaCG
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd110, 9'd106, 9'd111};   // ADD_T SbCG
            w.m[1] = {1'b1, 3'd0, 9'd18, 9'd62, 9'd124};   // MUL_T taCR2
            w.m[2] = {1'b1, 3'd0, 9'd18, 9'd63, 9'd125};   // MUL_T tbCR2
            w.m[3] = {1'b1, 3'd0, 9'd18, 9'd64, 9'd126};   // MUL_T tcCR2
          end
          6'd23: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd112, 9'd107, 9'd113};   // ADD_T ScCG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd127, 9'd124, 9'd128};   // ADD_T SaCR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd129, 9'd125, 9'd130};   // ADD_T SbCR
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd131, 9'd126, 9'd132};   // ADD_T ScCR
            w.m[0] = {1'b1, 3'd0, 9'd21, 9'd62, 9'd143};   // MUL_T taCA2
            w.m[1] = {1'b1, 3'd0, 9'd21, 9'd63, 9'd144};   // MUL_T tbCA2
            w.m[2] = {1'b1, 3'd0, 9'd21, 9'd64, 9'd145};   // MUL_T tcCA2
            w.m[3] = {1'b1, 3'd0, 9'd31, 9'd62, 9'd242};   // MUL_T taOB2
          end
          6'd24: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd146, 9'd143, 9'd147};   // ADD_T SaCA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd148, 9'd144, 9'd149};   // ADD_T SbCA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd150, 9'd145, 9'd151};   // ADD_T ScCA
            w.m[0] = {1'b1, 3'd0, 9'd31, 9'd63, 9'd243};   // MUL_T tbOB2
            w.m[1] = {1'b1, 3'd0, 9'd31, 9'd64, 9'd244};   // MUL_T tcOB2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd245, 9'd242, 9'd246};   // ADD_T SaOB
            w.m[2] = {1'b1, 3'd0, 9'd34, 9'd62, 9'd261};   // MUL_T taOG2
            w.m[3] = {1'b1, 3'd0, 9'd34, 9'd63, 9'd262};   // MUL_T tbOG2
          end
          6'd25: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd247, 9'd243, 9'd248};   // ADD_T SbOB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd249, 9'd244, 9'd250};   // ADD_T ScOB
            w.m[0] = {1'b1, 3'd0, 9'd34, 9'd64, 9'd263};   // MUL_T tcOG2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd264, 9'd261, 9'd265};   // ADD_T SaOG
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd266, 9'd262, 9'd267};   // ADD_T SbOG
            w.m[1] = {1'b1, 3'd0, 9'd37, 9'd62, 9'd280};   // MUL_T taOR2
            w.m[2] = {1'b1, 3'd0, 9'd37, 9'd63, 9'd281};   // MUL_T tbOR2
            w.m[3] = {1'b1, 3'd0, 9'd37, 9'd64, 9'd282};   // MUL_T tcOR2
          end
          6'd26: begin
            w.m[3] = {1'b1, 3'd0, 9'd75, 9'd9, 9'd76};   // MUL_T mean
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd268, 9'd263, 9'd269};   // ADD_T ScOG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd283, 9'd280, 9'd284};   // ADD_T SaOR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd285, 9'd281, 9'd286};   // ADD_T SbOR
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd287, 9'd282, 9'd288};   // ADD_T ScOR
            w.m[0] = {1'b1, 3'd0, 9'd40, 9'd62, 9'd299};   // MUL_T taOA2
            w.m[1] = {1'b1, 3'd0, 9'd40, 9'd63, 9'd300};   // MUL_T tbOA2
            w.m[2] = {1'b1, 3'd0, 9'd40, 9'd64, 9'd301};   // MUL_T tcOA2
          end
          6'd27: begin
            w.m[0] = {1'b1, 3'd0, 9'd66, 9'd73, 9'd77};   // MUL_T A0W
            w.m[1] = {1'b1, 3'd0, 9'd68, 9'd73, 9'd78};   // MUL_T B0W
            w.m[2] = {1'b1, 3'd0, 9'd70, 9'd73, 9'd79};   // MUL_T C0W
            w.m[3] = {1'b1, 3'd0, 9'd24, 9'd76, 9'd171};   // MUL_T CfU
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd302, 9'd299, 9'd303};   // ADD_T SaOA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd304, 9'd300, 9'd305};   // ADD_T SbOA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd306, 9'd301, 9'd307};   // ADD_T ScOA
          end
          6'd28: begin
            w.w = {1'b1, 2'd0, 4'd0, 9'd76, 9'd79, 9'd78, 9'd77};   // W_PL wW
            w.m[0] = {1'b1, 3'd0, 9'd166, 9'd73, 9'd172};   // MUL_T A0U
            w.m[1] = {1'b1, 3'd0, 9'd168, 9'd73, 9'd173};   // MUL_T B0U
            w.m[2] = {1'b1, 3'd0, 9'd170, 9'd73, 9'd174};   // MUL_T C0U
            w.m[3] = {1'b1, 3'd0, 9'd27, 9'd76, 9'd190};   // MUL_T CfV
          end
          6'd29: begin
            w.w = {1'b1, 2'd0, 4'd1, 9'd171, 9'd174, 9'd173, 9'd172};   // W_PL wU
            w.m[0] = {1'b1, 3'd0, 9'd185, 9'd73, 9'd191};   // MUL_T A0V
            w.m[1] = {1'b1, 3'd0, 9'd187, 9'd73, 9'd192};   // MUL_T B0V
            w.m[2] = {1'b1, 3'd0, 9'd189, 9'd73, 9'd193};   // MUL_T C0V
            w.m[3] = {1'b1, 3'd0, 9'd12, 9'd76, 9'd95};   // MUL_T CfCB
          end
          6'd30: begin
            w.w = {1'b1, 2'd0, 4'd2, 9'd190, 9'd193, 9'd192, 9'd191};   // W_PL wV
            w.m[0] = {1'b1, 3'd0, 9'd90, 9'd73, 9'd96};   // MUL_T A0CB
            w.m[1] = {1'b1, 3'd0, 9'd92, 9'd73, 9'd97};   // MUL_T B0CB
            w.m[2] = {1'b1, 3'd0, 9'd94, 9'd73, 9'd98};   // MUL_T C0CB
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd76, 9'd114};   // MUL_T CfCG
          end
          6'd31: begin
            w.w = {1'b1, 2'd0, 4'd3, 9'd95, 9'd98, 9'd97, 9'd96};   // W_PL wCB
            w.m[0] = {1'b1, 3'd0, 9'd109, 9'd73, 9'd115};   // MUL_T A0CG
            w.m[1] = {1'b1, 3'd0, 9'd111, 9'd73, 9'd116};   // MUL_T B0CG
            w.m[2] = {1'b1, 3'd0, 9'd113, 9'd73, 9'd117};   // MUL_T C0CG
            w.m[3] = {1'b1, 3'd0, 9'd18, 9'd76, 9'd133};   // MUL_T CfCR
          end
          6'd32: begin
            w.w = {1'b1, 2'd0, 4'd4, 9'd114, 9'd117, 9'd116, 9'd115};   // W_PL wCG
            w.m[0] = {1'b1, 3'd0, 9'd128, 9'd73, 9'd134};   // MUL_T A0CR
            w.m[1] = {1'b1, 3'd0, 9'd130, 9'd73, 9'd135};   // MUL_T B0CR
            w.m[2] = {1'b1, 3'd0, 9'd132, 9'd73, 9'd136};   // MUL_T C0CR
            w.m[3] = {1'b1, 3'd0, 9'd21, 9'd76, 9'd152};   // MUL_T CfCA
          end
          6'd33: begin
            w.w = {1'b1, 2'd0, 4'd5, 9'd133, 9'd136, 9'd135, 9'd134};   // W_PL wCR
            w.m[0] = {1'b1, 3'd0, 9'd147, 9'd73, 9'd153};   // MUL_T A0CA
            w.m[1] = {1'b1, 3'd0, 9'd149, 9'd73, 9'd154};   // MUL_T B0CA
            w.m[2] = {1'b1, 3'd0, 9'd151, 9'd73, 9'd155};   // MUL_T C0CA
            w.m[3] = {1'b1, 3'd0, 9'd31, 9'd76, 9'd251};   // MUL_T CfOB
          end
          6'd34: begin
            w.w = {1'b1, 2'd0, 4'd6, 9'd152, 9'd155, 9'd154, 9'd153};   // W_PL wCA
            w.m[0] = {1'b1, 3'd0, 9'd246, 9'd73, 9'd252};   // MUL_T A0OB
            w.m[1] = {1'b1, 3'd0, 9'd248, 9'd73, 9'd253};   // MUL_T B0OB
            w.m[2] = {1'b1, 3'd0, 9'd250, 9'd73, 9'd254};   // MUL_T C0OB
            w.m[3] = {1'b1, 3'd0, 9'd34, 9'd76, 9'd270};   // MUL_T CfOG
          end
          6'd35: begin
            w.w = {1'b1, 2'd0, 4'd7, 9'd251, 9'd254, 9'd253, 9'd252};   // W_PL wOB
            w.m[0] = {1'b1, 3'd0, 9'd265, 9'd73, 9'd271};   // MUL_T A0OG
            w.m[1] = {1'b1, 3'd0, 9'd267, 9'd73, 9'd272};   // MUL_T B0OG
            w.m[2] = {1'b1, 3'd0, 9'd269, 9'd73, 9'd273};   // MUL_T C0OG
            w.m[3] = {1'b1, 3'd0, 9'd37, 9'd76, 9'd289};   // MUL_T CfOR
          end
          6'd36: begin
            w.w = {1'b1, 2'd0, 4'd8, 9'd270, 9'd273, 9'd272, 9'd271};   // W_PL wOG
            w.m[0] = {1'b1, 3'd0, 9'd284, 9'd73, 9'd290};   // MUL_T A0OR
            w.m[1] = {1'b1, 3'd0, 9'd286, 9'd73, 9'd291};   // MUL_T B0OR
            w.m[2] = {1'b1, 3'd0, 9'd288, 9'd73, 9'd292};   // MUL_T C0OR
            w.m[3] = {1'b1, 3'd0, 9'd40, 9'd76, 9'd308};   // MUL_T CfOA
          end
          6'd37: begin
            w.w = {1'b1, 2'd0, 4'd9, 9'd289, 9'd292, 9'd291, 9'd290};   // W_PL wOR
            w.m[0] = {1'b1, 3'd0, 9'd303, 9'd73, 9'd309};   // MUL_T A0OA
            w.m[1] = {1'b1, 3'd0, 9'd305, 9'd73, 9'd310};   // MUL_T B0OA
            w.m[2] = {1'b1, 3'd0, 9'd307, 9'd73, 9'd311};   // MUL_T C0OA
          end
          6'd38: begin
            w.w = {1'b1, 2'd0, 4'd10, 9'd308, 9'd311, 9'd310, 9'd309};   // W_PL wOA
          end
          default: ;
        endcase
      end
      4'd5: begin   // TEX_O_M0
        case (pc)
          6'd0: begin
            w.m[0] = {1'b1, 3'd0, 9'd6, 9'd4, 9'd41};   // MUL_T pxy21
            w.m[1] = {1'b1, 3'd0, 9'd3, 9'd7, 9'd42};   // MUL_T pxy12
            w.m[2] = {1'b1, 3'd0, 9'd0, 9'd7, 9'd44};   // MUL_T pxy02
            w.m[3] = {1'b1, 3'd0, 9'd6, 9'd1, 9'd45};   // MUL_T pxy20
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd4, 9'd7, 9'd50};   // ADD_T dy0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd6, 9'd3, 9'd51};   // ADD_T dx0
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd7, 9'd1, 9'd55};   // ADD_T dy1
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd0, 9'd6, 9'd56};   // ADD_T dx1
          end
          6'd1: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd42, 9'd41, 9'd43};   // ADD_T e0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd45, 9'd44, 9'd46};   // ADD_T e1
            w.m[0] = {1'b1, 3'd0, 9'd3, 9'd1, 9'd47};   // MUL_T pxy10
            w.m[1] = {1'b1, 3'd0, 9'd0, 9'd4, 9'd48};   // MUL_T pxy01
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd1, 9'd4, 9'd60};   // ADD_T dy2
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd3, 9'd0, 9'd61};   // ADD_T dx2
          end
          6'd2: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd48, 9'd47, 9'd49};   // ADD_T e2
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd50, 9'd52};   // MUL_T wa0
            w.m[1] = {1'b1, 3'd0, 9'd2, 9'd51, 9'd53};   // MUL_T wb0
            w.m[2] = {1'b1, 3'd0, 9'd5, 9'd55, 9'd57};   // MUL_T wa1
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd56, 9'd58};   // MUL_T wb1
            w.a[1] = {1'b1, 3'd1, 1'b0, 9'd2, 9'd5, 9'd74};   // ADD_W m01
          end
          6'd3: begin
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd43, 9'd54};   // MUL_T wc0
            w.m[1] = {1'b1, 3'd0, 9'd5, 9'd46, 9'd59};   // MUL_T wc1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd52, 9'd57, 9'd65};   // ADD_T SaW01
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd53, 9'd58, 9'd67};   // ADD_T SbW01
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd43, 9'd46, 9'd71};   // ADD_T Sdet01
            w.m[2] = {1'b1, 3'd0, 9'd22, 9'd52, 9'd156};   // MUL_T taU0
            w.m[3] = {1'b1, 3'd0, 9'd22, 9'd53, 9'd157};   // MUL_T tbU0
          end
          6'd4: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd49, 9'd64};   // MUL_T wc2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd74, 9'd8, 9'd75};   // ADD_T msum
            w.m[1] = {1'b1, 3'd0, 9'd22, 9'd54, 9'd158};   // MUL_T tcU0
            w.m[2] = {1'b1, 3'd0, 9'd23, 9'd57, 9'd159};   // MUL_T taU1
            w.m[3] = {1'b1, 3'd0, 9'd23, 9'd58, 9'd160};   // MUL_T tbU1
          end
          6'd5: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd54, 9'd64, 9'd69};   // ADD_T ScW02
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd71, 9'd49, 9'd72};   // ADD_T Sdet
            w.m[0] = {1'b1, 3'd0, 9'd23, 9'd59, 9'd161};   // MUL_T tcU1
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd156, 9'd159, 9'd165};   // ADD_T Sa01U
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd157, 9'd160, 9'd167};   // ADD_T Sb01U
            w.m[1] = {1'b1, 3'd0, 9'd25, 9'd52, 9'd175};   // MUL_T taV0
            w.m[2] = {1'b1, 3'd0, 9'd25, 9'd53, 9'd176};   // MUL_T tbV0
            w.m[3] = {1'b1, 3'd0, 9'd25, 9'd54, 9'd177};   // MUL_T tcV0
          end
          6'd6: begin
            w.m[3] = {1'b1, 3'd0, 9'd8, 9'd60, 9'd62};   // MUL_T wa2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd158, 9'd161, 9'd169};   // ADD_T Sc01U
            w.m[0] = {1'b1, 3'd0, 9'd26, 9'd57, 9'd178};   // MUL_T taV1
            w.m[1] = {1'b1, 3'd0, 9'd26, 9'd58, 9'd179};   // MUL_T tbV1
            w.m[2] = {1'b1, 3'd0, 9'd26, 9'd59, 9'd180};   // MUL_T tcV1
          end
          6'd7: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd61, 9'd63};   // MUL_T wb2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd65, 9'd62, 9'd66};   // ADD_T SaW
            w.m[1] = {1'b1, 3'd0, 9'd24, 9'd62, 9'd162};   // MUL_T taU2
            w.m[2] = {1'b1, 3'd0, 9'd24, 9'd64, 9'd164};   // MUL_T tcU2
            w.m[3] = {1'b1, 3'd0, 9'd27, 9'd62, 9'd181};   // MUL_T taV2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd175, 9'd178, 9'd184};   // ADD_T Sa01V
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd176, 9'd179, 9'd186};   // ADD_T Sb01V
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd177, 9'd180, 9'd188};   // ADD_T Sc01V
            w.r = {1'b1, 1'b1, 9'd72, 9'd194};   // RCP_M minv
          end
          6'd8: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd67, 9'd63, 9'd68};   // ADD_T SbW
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd69, 9'd59, 9'd70};   // ADD_T ScW
            w.r = {1'b1, 1'b0, 9'd72, 9'd73};   // RCP_T inv
            w.m[0] = {1'b1, 3'd0, 9'd24, 9'd63, 9'd163};   // MUL_T tbU2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd165, 9'd162, 9'd166};   // ADD_T SaU
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd169, 9'd164, 9'd170};   // ADD_T ScU
            w.m[1] = {1'b1, 3'd0, 9'd27, 9'd63, 9'd182};   // MUL_T tbV2
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd64, 9'd183};   // MUL_T tcV2
            w.m[3] = {1'b1, 3'd0, 9'd10, 9'd52, 9'd80};   // MUL_T taCB0
          end
          6'd9: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd167, 9'd163, 9'd168};   // ADD_T SbU
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd184, 9'd181, 9'd185};   // ADD_T SaV
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd186, 9'd182, 9'd187};   // ADD_T SbV
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd188, 9'd183, 9'd189};   // ADD_T ScV
            w.m[1] = {1'b1, 3'd0, 9'd10, 9'd53, 9'd81};   // MUL_T tbCB0
            w.m[2] = {1'b1, 3'd0, 9'd10, 9'd54, 9'd82};   // MUL_T tcCB0
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd57, 9'd83};   // MUL_T taCB1
            w.m[0] = {1'b1, 3'd3, 9'd194, 9'd194, 9'd195};   // MUL_I2 inv2
          end
          6'd10: begin
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd58, 9'd84};   // MUL_T tbCB1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd80, 9'd83, 9'd89};   // ADD_T Sa01CB
            w.m[0] = {1'b1, 3'd1, 9'd170, 9'd66, 9'd196};   // MUL_K q1ux
            w.m[1] = {1'b1, 3'd1, 9'd166, 9'd70, 9'd197};   // MUL_K q2ux
            w.m[2] = {1'b1, 3'd1, 9'd170, 9'd68, 9'd205};   // MUL_K q2uy
          end
          6'd11: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd81, 9'd84, 9'd91};   // ADD_T Sb01CB
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd196, 9'd197, 9'd198};   // ADD_N nux
            w.m[0] = {1'b1, 3'd1, 9'd189, 9'd66, 9'd200};   // MUL_K q1vx
            w.m[1] = {1'b1, 3'd1, 9'd185, 9'd70, 9'd201};   // MUL_K q2vx
            w.m[2] = {1'b1, 3'd1, 9'd168, 9'd70, 9'd204};   // MUL_K q1uy
            w.m[3] = {1'b1, 3'd1, 9'd187, 9'd70, 9'd208};   // MUL_K q1vy
          end
          6'd12: begin
            w.m[1] = {1'b1, 3'd0, 9'd11, 9'd59, 9'd85};   // MUL_T tcCB1
            w.m[2] = {1'b1, 3'd0, 9'd13, 9'd52, 9'd99};   // MUL_T taCG0
            w.m[3] = {1'b1, 3'd0, 9'd13, 9'd53, 9'd100};   // MUL_T tbCG0
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd200, 9'd201, 9'd202};   // ADD_N nvx
            w.a[1] = {1'b1, 3'd3, 1'b0, 9'd204, 9'd205, 9'd206};   // ADD_N nuy
            w.m[0] = {1'b1, 3'd1, 9'd189, 9'd68, 9'd209};   // MUL_K q2vy
          end
          6'd13: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd82, 9'd85, 9'd93};   // ADD_T Sc01CB
            w.m[1] = {1'b1, 3'd0, 9'd13, 9'd54, 9'd101};   // MUL_T tcCG0
            w.m[2] = {1'b1, 3'd0, 9'd14, 9'd57, 9'd102};   // MUL_T taCG1
            w.m[3] = {1'b1, 3'd0, 9'd14, 9'd58, 9'd103};   // MUL_T tbCG1
            w.m[0] = {1'b1, 3'd2, 9'd198, 9'd195, 9'd199};   // MUL_Q nqux
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd208, 9'd209, 9'd210};   // ADD_N nvy
          end
          6'd14: begin
            w.m[2] = {1'b1, 3'd0, 9'd14, 9'd59, 9'd104};   // MUL_T tcCG1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd99, 9'd102, 9'd108};   // ADD_T Sa01CG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd100, 9'd103, 9'd110};   // ADD_T Sb01CG
            w.m[3] = {1'b1, 3'd0, 9'd16, 9'd52, 9'd118};   // MUL_T taCR0
            w.m[0] = {1'b1, 3'd2, 9'd202, 9'd195, 9'd203};   // MUL_Q nqvx
            w.m[1] = {1'b1, 3'd2, 9'd206, 9'd195, 9'd207};   // MUL_Q nquy
          end
          6'd15: begin
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd101, 9'd104, 9'd112};   // ADD_T Sc01CG
            w.m[1] = {1'b1, 3'd0, 9'd16, 9'd53, 9'd119};   // MUL_T tbCR0
            w.m[2] = {1'b1, 3'd0, 9'd16, 9'd54, 9'd120};   // MUL_T tcCR0
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd57, 9'd121};   // MUL_T taCR1
            w.m[0] = {1'b1, 3'd2, 9'd210, 9'd195, 9'd211};   // MUL_Q nqvy
            w.a[0] = {1'b1, 3'd4, 1'b0, 9'd199, 9'd203, 9'd212};   // ADD_LX lhix
            w.a[1] = {1'b1, 3'd5, 1'b0, 9'd199, 9'd203, 9'd213};   // ADD_LN llox
          end
          6'd16: begin
            w.m[0] = {1'b1, 3'd0, 9'd17, 9'd58, 9'd122};   // MUL_T tbCR1
            w.m[1] = {1'b1, 3'd0, 9'd17, 9'd59, 9'd123};   // MUL_T tcCR1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd118, 9'd121, 9'd127};   // ADD_T Sa01CR
            w.m[2] = {1'b1, 3'd0, 9'd19, 9'd52, 9'd137};   // MUL_T taCA0
            w.m[3] = {1'b1, 3'd0, 9'd19, 9'd53, 9'd138};   // MUL_T tbCA0
            w.a[0] = {1'b1, 3'd4, 1'b0, 9'd207, 9'd211, 9'd217};   // ADD_LX lhiy
            w.a[1] = {1'b1, 3'd5, 1'b0, 9'd207, 9'd211, 9'd218};   // ADD_LN lloy
          end
          6'd17: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd119, 9'd122, 9'd129};   // ADD_T Sb01CR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd120, 9'd123, 9'd131};   // ADD_T Sc01CR
            w.m[0] = {1'b1, 3'd0, 9'd19, 9'd54, 9'd139};   // MUL_T tcCA0
            w.m[1] = {1'b1, 3'd0, 9'd20, 9'd57, 9'd140};   // MUL_T taCA1
            w.m[2] = {1'b1, 3'd0, 9'd20, 9'd58, 9'd141};   // MUL_T tbCA1
            w.m[3] = {1'b1, 3'd0, 9'd20, 9'd59, 9'd142};   // MUL_T tcCA1
            w.a[0] = {1'b1, 3'd7, 1'b0, 9'd212, 9'd213, 9'd214};   // ADD_P lsumx
          end
          6'd18: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd137, 9'd140, 9'd146};   // ADD_T Sa01CA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd138, 9'd141, 9'd148};   // ADD_T Sb01CA
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd139, 9'd142, 9'd150};   // ADD_T Sc01CA
            w.m[0] = {1'b1, 3'd0, 9'd29, 9'd52, 9'd236};   // MUL_T taOB0
            w.m[1] = {1'b1, 3'd0, 9'd29, 9'd53, 9'd237};   // MUL_T tbOB0
            w.m[2] = {1'b1, 3'd0, 9'd29, 9'd54, 9'd238};   // MUL_T tcOB0
            w.m[3] = {1'b1, 3'd0, 9'd30, 9'd57, 9'd239};   // MUL_T taOB1
            w.a[0] = {1'b1, 3'd7, 1'b0, 9'd217, 9'd218, 9'd219};   // ADD_P lsumy
          end
          6'd19: begin
            w.m[0] = {1'b1, 3'd0, 9'd30, 9'd58, 9'd240};   // MUL_T tbOB1
            w.m[1] = {1'b1, 3'd0, 9'd30, 9'd59, 9'd241};   // MUL_T tcOB1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd236, 9'd239, 9'd245};   // ADD_T Sa01OB
            w.m[2] = {1'b1, 3'd0, 9'd32, 9'd52, 9'd255};   // MUL_T taOG0
            w.m[3] = {1'b1, 3'd0, 9'd32, 9'd53, 9'd256};   // MUL_T tbOG0
          end
          6'd20: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd237, 9'd240, 9'd247};   // ADD_T Sb01OB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd238, 9'd241, 9'd249};   // ADD_T Sc01OB
            w.m[0] = {1'b1, 3'd0, 9'd32, 9'd54, 9'd257};   // MUL_T tcOG0
            w.m[1] = {1'b1, 3'd0, 9'd33, 9'd57, 9'd258};   // MUL_T taOG1
            w.m[2] = {1'b1, 3'd0, 9'd33, 9'd58, 9'd259};   // MUL_T tbOG1
            w.m[3] = {1'b1, 3'd0, 9'd33, 9'd59, 9'd260};   // MUL_T tcOG1
          end
          6'd21: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd255, 9'd258, 9'd264};   // ADD_T Sa01OG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd256, 9'd259, 9'd266};   // ADD_T Sb01OG
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd257, 9'd260, 9'd268};   // ADD_T Sc01OG
            w.m[0] = {1'b1, 3'd0, 9'd35, 9'd52, 9'd274};   // MUL_T taOR0
            w.m[1] = {1'b1, 3'd0, 9'd35, 9'd53, 9'd275};   // MUL_T tbOR0
            w.m[2] = {1'b1, 3'd0, 9'd35, 9'd54, 9'd276};   // MUL_T tcOR0
            w.m[3] = {1'b1, 3'd0, 9'd36, 9'd57, 9'd277};   // MUL_T taOR1
          end
          6'd22: begin
            w.m[0] = {1'b1, 3'd0, 9'd36, 9'd58, 9'd278};   // MUL_T tbOR1
            w.m[1] = {1'b1, 3'd0, 9'd36, 9'd59, 9'd279};   // MUL_T tcOR1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd274, 9'd277, 9'd283};   // ADD_T Sa01OR
            w.m[2] = {1'b1, 3'd0, 9'd38, 9'd52, 9'd293};   // MUL_T taOA0
            w.m[3] = {1'b1, 3'd0, 9'd38, 9'd53, 9'd294};   // MUL_T tbOA0
          end
          6'd23: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd275, 9'd278, 9'd285};   // ADD_T Sb01OR
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd276, 9'd279, 9'd287};   // ADD_T Sc01OR
            w.m[0] = {1'b1, 3'd0, 9'd38, 9'd54, 9'd295};   // MUL_T tcOA0
            w.m[1] = {1'b1, 3'd0, 9'd39, 9'd57, 9'd296};   // MUL_T taOA1
            w.m[2] = {1'b1, 3'd0, 9'd39, 9'd58, 9'd297};   // MUL_T tbOA1
            w.m[3] = {1'b1, 3'd0, 9'd39, 9'd59, 9'd298};   // MUL_T tcOA1
          end
          6'd24: begin
            w.m[2] = {1'b1, 3'd0, 9'd12, 9'd62, 9'd86};   // MUL_T taCB2
            w.m[3] = {1'b1, 3'd0, 9'd12, 9'd63, 9'd87};   // MUL_T tbCB2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd293, 9'd296, 9'd302};   // ADD_T Sa01OA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd294, 9'd297, 9'd304};   // ADD_T Sb01OA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd295, 9'd298, 9'd306};   // ADD_T Sc01OA
            w.m[0] = {1'b1, 3'd5, 9'd213, 9'd28, 9'd215};   // MUL_P llessx
            w.m[1] = {1'b1, 3'd5, 9'd218, 9'd28, 9'd220};   // MUL_P llessy
          end
          6'd25: begin
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd64, 9'd88};   // MUL_T tcCB2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd89, 9'd86, 9'd90};   // ADD_T SaCB
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd91, 9'd87, 9'd92};   // ADD_T SbCB
            w.m[1] = {1'b1, 3'd0, 9'd15, 9'd62, 9'd105};   // MUL_T taCG2
            w.m[2] = {1'b1, 3'd0, 9'd15, 9'd63, 9'd106};   // MUL_T tbCG2
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd64, 9'd107};   // MUL_T tcCG2
            w.a[0] = {1'b1, 3'd7, 1'b1, 9'd214, 9'd215, 9'd216};   // ADD_P lenx
            w.a[1] = {1'b1, 3'd7, 1'b1, 9'd219, 9'd220, 9'd221};   // ADD_P leny
          end
          6'd26: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd93, 9'd88, 9'd94};   // ADD_T ScCB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd108, 9'd105, 9'd109};   // ADD_T SaCG
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd110, 9'd106, 9'd111};   // ADD_T SbCG
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd112, 9'd107, 9'd113};   // ADD_T ScCG
            w.m[0] = {1'b1, 3'd0, 9'd18, 9'd62, 9'd124};   // MUL_T taCR2
            w.m[1] = {1'b1, 3'd0, 9'd18, 9'd63, 9'd125};   // MUL_T tbCR2
            w.m[2] = {1'b1, 3'd0, 9'd18, 9'd64, 9'd126};   // MUL_T tcCR2
            w.m[3] = {1'b1, 3'd0, 9'd21, 9'd62, 9'd143};   // MUL_T taCA2
          end
          6'd27: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd127, 9'd124, 9'd128};   // ADD_T SaCR
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd129, 9'd125, 9'd130};   // ADD_T SbCR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd131, 9'd126, 9'd132};   // ADD_T ScCR
            w.m[0] = {1'b1, 3'd0, 9'd21, 9'd63, 9'd144};   // MUL_T tbCA2
            w.m[1] = {1'b1, 3'd0, 9'd21, 9'd64, 9'd145};   // MUL_T tcCA2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd146, 9'd143, 9'd147};   // ADD_T SaCA
            w.m[2] = {1'b1, 3'd0, 9'd31, 9'd62, 9'd242};   // MUL_T taOB2
            w.m[3] = {1'b1, 3'd0, 9'd31, 9'd63, 9'd243};   // MUL_T tbOB2
          end
          6'd28: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd148, 9'd144, 9'd149};   // ADD_T SbCA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd150, 9'd145, 9'd151};   // ADD_T ScCA
            w.m[0] = {1'b1, 3'd0, 9'd31, 9'd64, 9'd244};   // MUL_T tcOB2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd245, 9'd242, 9'd246};   // ADD_T SaOB
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd247, 9'd243, 9'd248};   // ADD_T SbOB
            w.m[1] = {1'b1, 3'd0, 9'd34, 9'd62, 9'd261};   // MUL_T taOG2
            w.m[2] = {1'b1, 3'd0, 9'd34, 9'd63, 9'd262};   // MUL_T tbOG2
            w.m[3] = {1'b1, 3'd0, 9'd34, 9'd64, 9'd263};   // MUL_T tcOG2
          end
          6'd29: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd249, 9'd244, 9'd250};   // ADD_T ScOB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd264, 9'd261, 9'd265};   // ADD_T SaOG
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd266, 9'd262, 9'd267};   // ADD_T SbOG
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd268, 9'd263, 9'd269};   // ADD_T ScOG
            w.m[0] = {1'b1, 3'd0, 9'd37, 9'd62, 9'd280};   // MUL_T taOR2
            w.m[1] = {1'b1, 3'd0, 9'd37, 9'd63, 9'd281};   // MUL_T tbOR2
            w.m[2] = {1'b1, 3'd0, 9'd37, 9'd64, 9'd282};   // MUL_T tcOR2
            w.m[3] = {1'b1, 3'd0, 9'd40, 9'd62, 9'd299};   // MUL_T taOA2
          end
          6'd30: begin
            w.m[2] = {1'b1, 3'd0, 9'd75, 9'd9, 9'd76};   // MUL_T mean
            w.m[3] = {1'b1, 3'd0, 9'd66, 9'd73, 9'd77};   // MUL_T A0W
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd283, 9'd280, 9'd284};   // ADD_T SaOR
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd285, 9'd281, 9'd286};   // ADD_T SbOR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd287, 9'd282, 9'd288};   // ADD_T ScOR
            w.m[0] = {1'b1, 3'd0, 9'd40, 9'd63, 9'd300};   // MUL_T tbOA2
            w.m[1] = {1'b1, 3'd0, 9'd40, 9'd64, 9'd301};   // MUL_T tcOA2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd302, 9'd299, 9'd303};   // ADD_T SaOA
          end
          6'd31: begin
            w.m[0] = {1'b1, 3'd0, 9'd68, 9'd73, 9'd78};   // MUL_T B0W
            w.m[1] = {1'b1, 3'd0, 9'd70, 9'd73, 9'd79};   // MUL_T C0W
            w.m[2] = {1'b1, 3'd0, 9'd24, 9'd76, 9'd171};   // MUL_T CfU
            w.m[3] = {1'b1, 3'd0, 9'd166, 9'd73, 9'd172};   // MUL_T A0U
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd304, 9'd300, 9'd305};   // ADD_T SbOA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd306, 9'd301, 9'd307};   // ADD_T ScOA
            w.a[2] = {1'b1, 3'd6, 1'b0, 9'd216, 9'd221, 9'd222};   // ADD_BS best0
          end
          6'd32: begin
            w.w = {1'b1, 2'd0, 4'd0, 9'd76, 9'd79, 9'd78, 9'd77};   // W_PL wW
            w.m[0] = {1'b1, 3'd0, 9'd168, 9'd73, 9'd173};   // MUL_T B0U
            w.m[1] = {1'b1, 3'd0, 9'd170, 9'd73, 9'd174};   // MUL_T C0U
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd76, 9'd190};   // MUL_T CfV
            w.m[3] = {1'b1, 3'd0, 9'd185, 9'd73, 9'd191};   // MUL_T A0V
          end
          6'd33: begin
            w.w = {1'b1, 2'd0, 4'd1, 9'd171, 9'd174, 9'd173, 9'd172};   // W_PL wU
            w.m[0] = {1'b1, 3'd0, 9'd187, 9'd73, 9'd192};   // MUL_T B0V
            w.m[1] = {1'b1, 3'd0, 9'd189, 9'd73, 9'd193};   // MUL_T C0V
            w.m[2] = {1'b1, 3'd0, 9'd12, 9'd76, 9'd95};   // MUL_T CfCB
            w.m[3] = {1'b1, 3'd0, 9'd90, 9'd73, 9'd96};   // MUL_T A0CB
          end
          6'd34: begin
            w.w = {1'b1, 2'd0, 4'd2, 9'd190, 9'd193, 9'd192, 9'd191};   // W_PL wV
            w.m[0] = {1'b1, 3'd0, 9'd92, 9'd73, 9'd97};   // MUL_T B0CB
            w.m[1] = {1'b1, 3'd0, 9'd94, 9'd73, 9'd98};   // MUL_T C0CB
            w.m[2] = {1'b1, 3'd0, 9'd15, 9'd76, 9'd114};   // MUL_T CfCG
            w.m[3] = {1'b1, 3'd0, 9'd109, 9'd73, 9'd115};   // MUL_T A0CG
          end
          6'd35: begin
            w.w = {1'b1, 2'd0, 4'd3, 9'd95, 9'd98, 9'd97, 9'd96};   // W_PL wCB
            w.m[0] = {1'b1, 3'd0, 9'd111, 9'd73, 9'd116};   // MUL_T B0CG
            w.m[1] = {1'b1, 3'd0, 9'd113, 9'd73, 9'd117};   // MUL_T C0CG
            w.m[2] = {1'b1, 3'd0, 9'd18, 9'd76, 9'd133};   // MUL_T CfCR
            w.m[3] = {1'b1, 3'd0, 9'd128, 9'd73, 9'd134};   // MUL_T A0CR
          end
          6'd36: begin
            w.w = {1'b1, 2'd0, 4'd4, 9'd114, 9'd117, 9'd116, 9'd115};   // W_PL wCG
            w.m[0] = {1'b1, 3'd0, 9'd130, 9'd73, 9'd135};   // MUL_T B0CR
            w.m[1] = {1'b1, 3'd0, 9'd132, 9'd73, 9'd136};   // MUL_T C0CR
            w.m[2] = {1'b1, 3'd0, 9'd21, 9'd76, 9'd152};   // MUL_T CfCA
            w.m[3] = {1'b1, 3'd0, 9'd147, 9'd73, 9'd153};   // MUL_T A0CA
          end
          6'd37: begin
            w.w = {1'b1, 2'd0, 4'd5, 9'd133, 9'd136, 9'd135, 9'd134};   // W_PL wCR
            w.m[0] = {1'b1, 3'd0, 9'd149, 9'd73, 9'd154};   // MUL_T B0CA
            w.m[1] = {1'b1, 3'd0, 9'd151, 9'd73, 9'd155};   // MUL_T C0CA
            w.m[2] = {1'b1, 3'd0, 9'd31, 9'd76, 9'd251};   // MUL_T CfOB
            w.m[3] = {1'b1, 3'd0, 9'd246, 9'd73, 9'd252};   // MUL_T A0OB
          end
          6'd38: begin
            w.w = {1'b1, 2'd0, 4'd6, 9'd152, 9'd155, 9'd154, 9'd153};   // W_PL wCA
            w.m[0] = {1'b1, 3'd0, 9'd248, 9'd73, 9'd253};   // MUL_T B0OB
            w.m[1] = {1'b1, 3'd0, 9'd250, 9'd73, 9'd254};   // MUL_T C0OB
            w.m[2] = {1'b1, 3'd0, 9'd34, 9'd76, 9'd270};   // MUL_T CfOG
            w.m[3] = {1'b1, 3'd0, 9'd265, 9'd73, 9'd271};   // MUL_T A0OG
          end
          6'd39: begin
            w.w = {1'b1, 2'd0, 4'd7, 9'd251, 9'd254, 9'd253, 9'd252};   // W_PL wOB
            w.m[0] = {1'b1, 3'd0, 9'd267, 9'd73, 9'd272};   // MUL_T B0OG
            w.m[1] = {1'b1, 3'd0, 9'd269, 9'd73, 9'd273};   // MUL_T C0OG
            w.m[2] = {1'b1, 3'd0, 9'd37, 9'd76, 9'd289};   // MUL_T CfOR
            w.m[3] = {1'b1, 3'd0, 9'd284, 9'd73, 9'd290};   // MUL_T A0OR
          end
          6'd40: begin
            w.w = {1'b1, 2'd0, 4'd8, 9'd270, 9'd273, 9'd272, 9'd271};   // W_PL wOG
            w.m[0] = {1'b1, 3'd0, 9'd286, 9'd73, 9'd291};   // MUL_T B0OR
            w.m[1] = {1'b1, 3'd0, 9'd288, 9'd73, 9'd292};   // MUL_T C0OR
            w.m[2] = {1'b1, 3'd0, 9'd40, 9'd76, 9'd308};   // MUL_T CfOA
            w.m[3] = {1'b1, 3'd0, 9'd303, 9'd73, 9'd309};   // MUL_T A0OA
          end
          6'd41: begin
            w.w = {1'b1, 2'd0, 4'd9, 9'd289, 9'd292, 9'd291, 9'd290};   // W_PL wOR
            w.m[0] = {1'b1, 3'd0, 9'd305, 9'd73, 9'd310};   // MUL_T B0OA
            w.m[1] = {1'b1, 3'd0, 9'd307, 9'd73, 9'd311};   // MUL_T C0OA
            w.m[2] = {1'b1, 3'd4, 9'd222, 9'd195, 9'd223};   // MUL_B best
          end
          6'd42: begin
            w.w = {1'b1, 2'd0, 4'd10, 9'd308, 9'd311, 9'd310, 9'd309};   // W_PL wOA
          end
          6'd43: begin
            w.w = {1'b1, 2'd2, 4'd0, 9'd0, 9'd0, 9'd0, 9'd223};   // W_K wK
          end
          default: ;
        endcase
      end
      4'd6: begin   // TEX_O_M1
        case (pc)
          6'd0: begin
            w.m[0] = {1'b1, 3'd0, 9'd6, 9'd4, 9'd41};   // MUL_T pxy21
            w.m[1] = {1'b1, 3'd0, 9'd3, 9'd7, 9'd42};   // MUL_T pxy12
            w.m[2] = {1'b1, 3'd0, 9'd0, 9'd7, 9'd44};   // MUL_T pxy02
            w.m[3] = {1'b1, 3'd0, 9'd6, 9'd1, 9'd45};   // MUL_T pxy20
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd4, 9'd7, 9'd50};   // ADD_T dy0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd6, 9'd3, 9'd51};   // ADD_T dx0
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd7, 9'd1, 9'd55};   // ADD_T dy1
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd0, 9'd6, 9'd56};   // ADD_T dx1
          end
          6'd1: begin
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd42, 9'd41, 9'd43};   // ADD_T e0
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd45, 9'd44, 9'd46};   // ADD_T e1
            w.m[0] = {1'b1, 3'd0, 9'd3, 9'd1, 9'd47};   // MUL_T pxy10
            w.m[1] = {1'b1, 3'd0, 9'd0, 9'd4, 9'd48};   // MUL_T pxy01
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd1, 9'd4, 9'd60};   // ADD_T dy2
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd3, 9'd0, 9'd61};   // ADD_T dx2
          end
          6'd2: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd48, 9'd47, 9'd49};   // ADD_T e2
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd50, 9'd52};   // MUL_T wa0
            w.m[1] = {1'b1, 3'd0, 9'd2, 9'd51, 9'd53};   // MUL_T wb0
            w.m[2] = {1'b1, 3'd0, 9'd5, 9'd55, 9'd57};   // MUL_T wa1
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd56, 9'd58};   // MUL_T wb1
            w.a[1] = {1'b1, 3'd1, 1'b0, 9'd2, 9'd5, 9'd74};   // ADD_W m01
          end
          6'd3: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd52, 9'd57, 9'd65};   // ADD_T SaW01
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd53, 9'd58, 9'd67};   // ADD_T SbW01
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd43, 9'd46, 9'd71};   // ADD_T Sdet01
            w.m[0] = {1'b1, 3'd0, 9'd22, 9'd52, 9'd156};   // MUL_T taU0
            w.m[1] = {1'b1, 3'd0, 9'd22, 9'd53, 9'd157};   // MUL_T tbU0
            w.m[2] = {1'b1, 3'd0, 9'd23, 9'd57, 9'd159};   // MUL_T taU1
            w.m[3] = {1'b1, 3'd0, 9'd23, 9'd58, 9'd160};   // MUL_T tbU1
          end
          6'd4: begin
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd74, 9'd8, 9'd75};   // ADD_T msum
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd156, 9'd159, 9'd165};   // ADD_T Sa01U
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd157, 9'd160, 9'd167};   // ADD_T Sb01U
            w.m[0] = {1'b1, 3'd0, 9'd25, 9'd52, 9'd175};   // MUL_T taV0
            w.m[1] = {1'b1, 3'd0, 9'd25, 9'd53, 9'd176};   // MUL_T tbV0
            w.m[2] = {1'b1, 3'd0, 9'd26, 9'd57, 9'd178};   // MUL_T taV1
            w.m[3] = {1'b1, 3'd0, 9'd26, 9'd58, 9'd179};   // MUL_T tbV1
          end
          6'd5: begin
            w.m[2] = {1'b1, 3'd0, 9'd2, 9'd43, 9'd54};   // MUL_T wc0
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd46, 9'd59};   // MUL_T wc1
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd60, 9'd62};   // MUL_T wa2
            w.m[1] = {1'b1, 3'd0, 9'd8, 9'd61, 9'd63};   // MUL_T wb2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd71, 9'd49, 9'd72};   // ADD_T Sdet
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd175, 9'd178, 9'd184};   // ADD_T Sa01V
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd176, 9'd179, 9'd186};   // ADD_T Sb01V
          end
          6'd6: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd65, 9'd62, 9'd66};   // ADD_T SaW
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd67, 9'd63, 9'd68};   // ADD_T SbW
            w.m[0] = {1'b1, 3'd0, 9'd24, 9'd62, 9'd162};   // MUL_T taU2
            w.m[1] = {1'b1, 3'd0, 9'd24, 9'd63, 9'd163};   // MUL_T tbU2
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd62, 9'd181};   // MUL_T taV2
            w.m[3] = {1'b1, 3'd0, 9'd27, 9'd63, 9'd182};   // MUL_T tbV2
          end
          6'd7: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd49, 9'd64};   // MUL_T wc2
            w.m[1] = {1'b1, 3'd0, 9'd22, 9'd54, 9'd158};   // MUL_T tcU0
            w.m[2] = {1'b1, 3'd0, 9'd23, 9'd59, 9'd161};   // MUL_T tcU1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd165, 9'd162, 9'd166};   // ADD_T SaU
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd167, 9'd163, 9'd168};   // ADD_T SbU
            w.m[3] = {1'b1, 3'd0, 9'd25, 9'd54, 9'd177};   // MUL_T tcV0
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd184, 9'd181, 9'd185};   // ADD_T SaV
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd186, 9'd182, 9'd187};   // ADD_T SbV
            w.r = {1'b1, 1'b1, 9'd72, 9'd194};   // RCP_M minv
          end
          6'd8: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd54, 9'd64, 9'd69};   // ADD_T ScW02
            w.r = {1'b1, 1'b0, 9'd72, 9'd73};   // RCP_T inv
            w.m[1] = {1'b1, 3'd0, 9'd24, 9'd64, 9'd164};   // MUL_T tcU2
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd158, 9'd161, 9'd169};   // ADD_T Sc01U
            w.m[0] = {1'b1, 3'd0, 9'd26, 9'd59, 9'd180};   // MUL_T tcV1
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd64, 9'd183};   // MUL_T tcV2
            w.m[3] = {1'b1, 3'd0, 9'd66, 9'd0, 9'd232};   // MUL_T d1aW
          end
          6'd9: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd177, 9'd180, 9'd188};   // ADD_T Sc01V
            w.m[0] = {1'b1, 3'd0, 9'd166, 9'd0, 9'd224};   // MUL_T d1aU
            w.m[1] = {1'b1, 3'd0, 9'd168, 9'd1, 9'd225};   // MUL_T d1bU
            w.m[2] = {1'b1, 3'd0, 9'd185, 9'd0, 9'd228};   // MUL_T d1aV
            w.m[3] = {1'b1, 3'd0, 9'd187, 9'd1, 9'd229};   // MUL_T d1bV
          end
          6'd10: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd69, 9'd59, 9'd70};   // ADD_T ScW
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd169, 9'd164, 9'd170};   // ADD_T ScU
            w.m[2] = {1'b1, 3'd0, 9'd10, 9'd52, 9'd80};   // MUL_T taCB0
            w.m[3] = {1'b1, 3'd0, 9'd10, 9'd53, 9'd81};   // MUL_T tbCB0
            w.m[1] = {1'b1, 3'd3, 9'd194, 9'd194, 9'd195};   // MUL_I2 inv2
            w.a[2] = {1'b1, 3'd2, 1'b0, 9'd224, 9'd225, 9'd226};   // ADD_R d1abU
            w.a[3] = {1'b1, 3'd2, 1'b0, 9'd228, 9'd229, 9'd230};   // ADD_R d1abV
            w.m[0] = {1'b1, 3'd0, 9'd68, 9'd1, 9'd233};   // MUL_T d1bW
          end
          6'd11: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd188, 9'd183, 9'd189};   // ADD_T ScV
            w.m[0] = {1'b1, 3'd0, 9'd10, 9'd54, 9'd82};   // MUL_T tcCB0
            w.m[1] = {1'b1, 3'd0, 9'd11, 9'd57, 9'd83};   // MUL_T taCB1
            w.m[2] = {1'b1, 3'd0, 9'd11, 9'd58, 9'd84};   // MUL_T tbCB1
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd59, 9'd85};   // MUL_T tcCB1
            w.a[1] = {1'b1, 3'd2, 1'b0, 9'd232, 9'd233, 9'd234};   // ADD_R d1abW
          end
          6'd12: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd80, 9'd83, 9'd89};   // ADD_T Sa01CB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd81, 9'd84, 9'd91};   // ADD_T Sb01CB
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd82, 9'd85, 9'd93};   // ADD_T Sc01CB
            w.m[0] = {1'b1, 3'd0, 9'd13, 9'd52, 9'd99};   // MUL_T taCG0
            w.m[1] = {1'b1, 3'd0, 9'd13, 9'd53, 9'd100};   // MUL_T tbCG0
            w.m[2] = {1'b1, 3'd0, 9'd13, 9'd54, 9'd101};   // MUL_T tcCG0
            w.m[3] = {1'b1, 3'd0, 9'd14, 9'd57, 9'd102};   // MUL_T taCG1
            w.a[0] = {1'b1, 3'd2, 1'b0, 9'd226, 9'd170, 9'd227};   // ADD_R d1U
          end
          6'd13: begin
            w.m[0] = {1'b1, 3'd0, 9'd14, 9'd58, 9'd103};   // MUL_T tbCG1
            w.m[1] = {1'b1, 3'd0, 9'd14, 9'd59, 9'd104};   // MUL_T tcCG1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd99, 9'd102, 9'd108};   // ADD_T Sa01CG
            w.m[2] = {1'b1, 3'd0, 9'd16, 9'd52, 9'd118};   // MUL_T taCR0
            w.m[3] = {1'b1, 3'd0, 9'd16, 9'd53, 9'd119};   // MUL_T tbCR0
            w.a[0] = {1'b1, 3'd2, 1'b0, 9'd230, 9'd189, 9'd231};   // ADD_R d1V
            w.a[1] = {1'b1, 3'd2, 1'b0, 9'd234, 9'd70, 9'd235};   // ADD_R d1W
          end
          6'd14: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd100, 9'd103, 9'd110};   // ADD_T Sb01CG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd101, 9'd104, 9'd112};   // ADD_T Sc01CG
            w.m[2] = {1'b1, 3'd0, 9'd16, 9'd54, 9'd120};   // MUL_T tcCR0
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd57, 9'd121};   // MUL_T taCR1
            w.m[0] = {1'b1, 3'd1, 9'd227, 9'd66, 9'd196};   // MUL_K q1ux
            w.m[1] = {1'b1, 3'd1, 9'd227, 9'd68, 9'd205};   // MUL_K q2uy
          end
          6'd15: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd118, 9'd121, 9'd127};   // ADD_T Sa01CR
            w.m[0] = {1'b1, 3'd1, 9'd166, 9'd235, 9'd197};   // MUL_K q2ux
            w.m[1] = {1'b1, 3'd1, 9'd231, 9'd66, 9'd200};   // MUL_K q1vx
            w.m[2] = {1'b1, 3'd1, 9'd185, 9'd235, 9'd201};   // MUL_K q2vx
            w.m[3] = {1'b1, 3'd1, 9'd168, 9'd235, 9'd204};   // MUL_K q1uy
          end
          6'd16: begin
            w.m[2] = {1'b1, 3'd0, 9'd17, 9'd58, 9'd122};   // MUL_T tbCR1
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd59, 9'd123};   // MUL_T tcCR1
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd196, 9'd197, 9'd198};   // ADD_N nux
            w.a[1] = {1'b1, 3'd3, 1'b0, 9'd200, 9'd201, 9'd202};   // ADD_N nvx
            w.a[2] = {1'b1, 3'd3, 1'b0, 9'd204, 9'd205, 9'd206};   // ADD_N nuy
            w.m[0] = {1'b1, 3'd1, 9'd187, 9'd235, 9'd208};   // MUL_K q1vy
            w.m[1] = {1'b1, 3'd1, 9'd231, 9'd68, 9'd209};   // MUL_K q2vy
          end
          6'd17: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd119, 9'd122, 9'd129};   // ADD_T Sb01CR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd120, 9'd123, 9'd131};   // ADD_T Sc01CR
            w.m[0] = {1'b1, 3'd0, 9'd19, 9'd52, 9'd137};   // MUL_T taCA0
            w.m[1] = {1'b1, 3'd0, 9'd19, 9'd53, 9'd138};   // MUL_T tbCA0
            w.m[2] = {1'b1, 3'd0, 9'd19, 9'd54, 9'd139};   // MUL_T tcCA0
            w.m[3] = {1'b1, 3'd0, 9'd20, 9'd57, 9'd140};   // MUL_T taCA1
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd208, 9'd209, 9'd210};   // ADD_N nvy
          end
          6'd18: begin
            w.m[3] = {1'b1, 3'd0, 9'd20, 9'd58, 9'd141};   // MUL_T tbCA1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd137, 9'd140, 9'd146};   // ADD_T Sa01CA
            w.m[0] = {1'b1, 3'd2, 9'd198, 9'd195, 9'd199};   // MUL_Q nqux
            w.m[1] = {1'b1, 3'd2, 9'd202, 9'd195, 9'd203};   // MUL_Q nqvx
            w.m[2] = {1'b1, 3'd2, 9'd206, 9'd195, 9'd207};   // MUL_Q nquy
          end
          6'd19: begin
            w.m[1] = {1'b1, 3'd0, 9'd20, 9'd59, 9'd142};   // MUL_T tcCA1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd138, 9'd141, 9'd148};   // ADD_T Sb01CA
            w.m[2] = {1'b1, 3'd0, 9'd29, 9'd52, 9'd236};   // MUL_T taOB0
            w.m[3] = {1'b1, 3'd0, 9'd29, 9'd53, 9'd237};   // MUL_T tbOB0
            w.m[0] = {1'b1, 3'd2, 9'd210, 9'd195, 9'd211};   // MUL_Q nqvy
            w.a[0] = {1'b1, 3'd4, 1'b0, 9'd199, 9'd203, 9'd212};   // ADD_LX lhix
            w.a[1] = {1'b1, 3'd5, 1'b0, 9'd199, 9'd203, 9'd213};   // ADD_LN llox
          end
          6'd20: begin
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd139, 9'd142, 9'd150};   // ADD_T Sc01CA
            w.m[0] = {1'b1, 3'd0, 9'd29, 9'd54, 9'd238};   // MUL_T tcOB0
            w.m[1] = {1'b1, 3'd0, 9'd30, 9'd57, 9'd239};   // MUL_T taOB1
            w.m[2] = {1'b1, 3'd0, 9'd30, 9'd58, 9'd240};   // MUL_T tbOB1
            w.m[3] = {1'b1, 3'd0, 9'd30, 9'd59, 9'd241};   // MUL_T tcOB1
            w.a[0] = {1'b1, 3'd4, 1'b0, 9'd207, 9'd211, 9'd217};   // ADD_LX lhiy
            w.a[1] = {1'b1, 3'd5, 1'b0, 9'd207, 9'd211, 9'd218};   // ADD_LN lloy
          end
          6'd21: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd236, 9'd239, 9'd245};   // ADD_T Sa01OB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd237, 9'd240, 9'd247};   // ADD_T Sb01OB
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd238, 9'd241, 9'd249};   // ADD_T Sc01OB
            w.m[0] = {1'b1, 3'd0, 9'd32, 9'd52, 9'd255};   // MUL_T taOG0
            w.m[1] = {1'b1, 3'd0, 9'd32, 9'd53, 9'd256};   // MUL_T tbOG0
            w.m[2] = {1'b1, 3'd0, 9'd32, 9'd54, 9'd257};   // MUL_T tcOG0
            w.m[3] = {1'b1, 3'd0, 9'd33, 9'd57, 9'd258};   // MUL_T taOG1
            w.a[0] = {1'b1, 3'd7, 1'b0, 9'd212, 9'd213, 9'd214};   // ADD_P lsumx
          end
          6'd22: begin
            w.m[0] = {1'b1, 3'd0, 9'd33, 9'd58, 9'd259};   // MUL_T tbOG1
            w.m[1] = {1'b1, 3'd0, 9'd33, 9'd59, 9'd260};   // MUL_T tcOG1
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd255, 9'd258, 9'd264};   // ADD_T Sa01OG
            w.m[2] = {1'b1, 3'd0, 9'd35, 9'd52, 9'd274};   // MUL_T taOR0
            w.m[3] = {1'b1, 3'd0, 9'd35, 9'd53, 9'd275};   // MUL_T tbOR0
            w.a[0] = {1'b1, 3'd7, 1'b0, 9'd217, 9'd218, 9'd219};   // ADD_P lsumy
          end
          6'd23: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd256, 9'd259, 9'd266};   // ADD_T Sb01OG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd257, 9'd260, 9'd268};   // ADD_T Sc01OG
            w.m[0] = {1'b1, 3'd0, 9'd35, 9'd54, 9'd276};   // MUL_T tcOR0
            w.m[1] = {1'b1, 3'd0, 9'd36, 9'd57, 9'd277};   // MUL_T taOR1
            w.m[2] = {1'b1, 3'd0, 9'd36, 9'd58, 9'd278};   // MUL_T tbOR1
            w.m[3] = {1'b1, 3'd0, 9'd36, 9'd59, 9'd279};   // MUL_T tcOR1
          end
          6'd24: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd274, 9'd277, 9'd283};   // ADD_T Sa01OR
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd275, 9'd278, 9'd285};   // ADD_T Sb01OR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd276, 9'd279, 9'd287};   // ADD_T Sc01OR
            w.m[0] = {1'b1, 3'd0, 9'd38, 9'd52, 9'd293};   // MUL_T taOA0
            w.m[1] = {1'b1, 3'd0, 9'd38, 9'd53, 9'd294};   // MUL_T tbOA0
            w.m[2] = {1'b1, 3'd0, 9'd38, 9'd54, 9'd295};   // MUL_T tcOA0
            w.m[3] = {1'b1, 3'd0, 9'd39, 9'd57, 9'd296};   // MUL_T taOA1
          end
          6'd25: begin
            w.m[0] = {1'b1, 3'd0, 9'd39, 9'd58, 9'd297};   // MUL_T tbOA1
            w.m[1] = {1'b1, 3'd0, 9'd39, 9'd59, 9'd298};   // MUL_T tcOA1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd293, 9'd296, 9'd302};   // ADD_T Sa01OA
            w.m[2] = {1'b1, 3'd5, 9'd213, 9'd28, 9'd215};   // MUL_P llessx
            w.m[3] = {1'b1, 3'd5, 9'd218, 9'd28, 9'd220};   // MUL_P llessy
          end
          6'd26: begin
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd62, 9'd86};   // MUL_T taCB2
            w.m[1] = {1'b1, 3'd0, 9'd12, 9'd63, 9'd87};   // MUL_T tbCB2
            w.m[2] = {1'b1, 3'd0, 9'd12, 9'd64, 9'd88};   // MUL_T tcCB2
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd62, 9'd105};   // MUL_T taCG2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd294, 9'd297, 9'd304};   // ADD_T Sb01OA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd295, 9'd298, 9'd306};   // ADD_T Sc01OA
            w.a[2] = {1'b1, 3'd7, 1'b1, 9'd214, 9'd215, 9'd216};   // ADD_P lenx
            w.a[3] = {1'b1, 3'd7, 1'b1, 9'd219, 9'd220, 9'd221};   // ADD_P leny
          end
          6'd27: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd89, 9'd86, 9'd90};   // ADD_T SaCB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd91, 9'd87, 9'd92};   // ADD_T SbCB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd93, 9'd88, 9'd94};   // ADD_T ScCB
            w.m[0] = {1'b1, 3'd0, 9'd15, 9'd63, 9'd106};   // MUL_T tbCG2
            w.m[1] = {1'b1, 3'd0, 9'd15, 9'd64, 9'd107};   // MUL_T tcCG2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd108, 9'd105, 9'd109};   // ADD_T SaCG
            w.m[2] = {1'b1, 3'd0, 9'd18, 9'd62, 9'd124};   // MUL_T taCR2
            w.m[3] = {1'b1, 3'd0, 9'd18, 9'd63, 9'd125};   // MUL_T tbCR2
          end
          6'd28: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd110, 9'd106, 9'd111};   // ADD_T SbCG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd112, 9'd107, 9'd113};   // ADD_T ScCG
            w.m[0] = {1'b1, 3'd0, 9'd18, 9'd64, 9'd126};   // MUL_T tcCR2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd127, 9'd124, 9'd128};   // ADD_T SaCR
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd129, 9'd125, 9'd130};   // ADD_T SbCR
            w.m[1] = {1'b1, 3'd0, 9'd21, 9'd62, 9'd143};   // MUL_T taCA2
            w.m[2] = {1'b1, 3'd0, 9'd21, 9'd63, 9'd144};   // MUL_T tbCA2
            w.m[3] = {1'b1, 3'd0, 9'd21, 9'd64, 9'd145};   // MUL_T tcCA2
          end
          6'd29: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd131, 9'd126, 9'd132};   // ADD_T ScCR
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd146, 9'd143, 9'd147};   // ADD_T SaCA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd148, 9'd144, 9'd149};   // ADD_T SbCA
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd150, 9'd145, 9'd151};   // ADD_T ScCA
            w.m[0] = {1'b1, 3'd0, 9'd31, 9'd62, 9'd242};   // MUL_T taOB2
            w.m[1] = {1'b1, 3'd0, 9'd31, 9'd63, 9'd243};   // MUL_T tbOB2
            w.m[2] = {1'b1, 3'd0, 9'd31, 9'd64, 9'd244};   // MUL_T tcOB2
            w.m[3] = {1'b1, 3'd0, 9'd34, 9'd62, 9'd261};   // MUL_T taOG2
          end
          6'd30: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd245, 9'd242, 9'd246};   // ADD_T SaOB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd247, 9'd243, 9'd248};   // ADD_T SbOB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd249, 9'd244, 9'd250};   // ADD_T ScOB
            w.m[0] = {1'b1, 3'd0, 9'd34, 9'd63, 9'd262};   // MUL_T tbOG2
            w.m[1] = {1'b1, 3'd0, 9'd34, 9'd64, 9'd263};   // MUL_T tcOG2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd264, 9'd261, 9'd265};   // ADD_T SaOG
            w.m[2] = {1'b1, 3'd0, 9'd37, 9'd62, 9'd280};   // MUL_T taOR2
            w.m[3] = {1'b1, 3'd0, 9'd37, 9'd63, 9'd281};   // MUL_T tbOR2
          end
          6'd31: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd266, 9'd262, 9'd267};   // ADD_T SbOG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd268, 9'd263, 9'd269};   // ADD_T ScOG
            w.m[0] = {1'b1, 3'd0, 9'd37, 9'd64, 9'd282};   // MUL_T tcOR2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd283, 9'd280, 9'd284};   // ADD_T SaOR
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd285, 9'd281, 9'd286};   // ADD_T SbOR
            w.m[1] = {1'b1, 3'd0, 9'd40, 9'd62, 9'd299};   // MUL_T taOA2
            w.m[2] = {1'b1, 3'd0, 9'd40, 9'd63, 9'd300};   // MUL_T tbOA2
            w.m[3] = {1'b1, 3'd0, 9'd40, 9'd64, 9'd301};   // MUL_T tcOA2
          end
          6'd32: begin
            w.m[0] = {1'b1, 3'd0, 9'd75, 9'd9, 9'd76};   // MUL_T mean
            w.m[1] = {1'b1, 3'd0, 9'd66, 9'd73, 9'd77};   // MUL_T A0W
            w.m[2] = {1'b1, 3'd0, 9'd68, 9'd73, 9'd78};   // MUL_T B0W
            w.m[3] = {1'b1, 3'd0, 9'd70, 9'd73, 9'd79};   // MUL_T C0W
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd287, 9'd282, 9'd288};   // ADD_T ScOR
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd302, 9'd299, 9'd303};   // ADD_T SaOA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd304, 9'd300, 9'd305};   // ADD_T SbOA
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd306, 9'd301, 9'd307};   // ADD_T ScOA
          end
          6'd33: begin
            w.w = {1'b1, 2'd0, 4'd0, 9'd76, 9'd79, 9'd78, 9'd77};   // W_PL wW
            w.m[0] = {1'b1, 3'd0, 9'd24, 9'd76, 9'd171};   // MUL_T CfU
            w.m[1] = {1'b1, 3'd0, 9'd166, 9'd73, 9'd172};   // MUL_T A0U
            w.m[2] = {1'b1, 3'd0, 9'd168, 9'd73, 9'd173};   // MUL_T B0U
            w.m[3] = {1'b1, 3'd0, 9'd170, 9'd73, 9'd174};   // MUL_T C0U
            w.a[0] = {1'b1, 3'd6, 1'b0, 9'd216, 9'd221, 9'd222};   // ADD_BS best0
          end
          6'd34: begin
            w.w = {1'b1, 2'd0, 4'd1, 9'd171, 9'd174, 9'd173, 9'd172};   // W_PL wU
            w.m[0] = {1'b1, 3'd0, 9'd27, 9'd76, 9'd190};   // MUL_T CfV
            w.m[1] = {1'b1, 3'd0, 9'd185, 9'd73, 9'd191};   // MUL_T A0V
            w.m[2] = {1'b1, 3'd0, 9'd187, 9'd73, 9'd192};   // MUL_T B0V
            w.m[3] = {1'b1, 3'd0, 9'd189, 9'd73, 9'd193};   // MUL_T C0V
          end
          6'd35: begin
            w.w = {1'b1, 2'd0, 4'd2, 9'd190, 9'd193, 9'd192, 9'd191};   // W_PL wV
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd76, 9'd95};   // MUL_T CfCB
            w.m[1] = {1'b1, 3'd0, 9'd90, 9'd73, 9'd96};   // MUL_T A0CB
            w.m[2] = {1'b1, 3'd0, 9'd92, 9'd73, 9'd97};   // MUL_T B0CB
            w.m[3] = {1'b1, 3'd0, 9'd94, 9'd73, 9'd98};   // MUL_T C0CB
          end
          6'd36: begin
            w.w = {1'b1, 2'd0, 4'd3, 9'd95, 9'd98, 9'd97, 9'd96};   // W_PL wCB
            w.m[0] = {1'b1, 3'd0, 9'd15, 9'd76, 9'd114};   // MUL_T CfCG
            w.m[1] = {1'b1, 3'd0, 9'd109, 9'd73, 9'd115};   // MUL_T A0CG
            w.m[2] = {1'b1, 3'd0, 9'd111, 9'd73, 9'd116};   // MUL_T B0CG
            w.m[3] = {1'b1, 3'd0, 9'd113, 9'd73, 9'd117};   // MUL_T C0CG
          end
          6'd37: begin
            w.w = {1'b1, 2'd0, 4'd4, 9'd114, 9'd117, 9'd116, 9'd115};   // W_PL wCG
            w.m[0] = {1'b1, 3'd0, 9'd18, 9'd76, 9'd133};   // MUL_T CfCR
            w.m[1] = {1'b1, 3'd0, 9'd128, 9'd73, 9'd134};   // MUL_T A0CR
            w.m[2] = {1'b1, 3'd0, 9'd130, 9'd73, 9'd135};   // MUL_T B0CR
            w.m[3] = {1'b1, 3'd0, 9'd132, 9'd73, 9'd136};   // MUL_T C0CR
          end
          6'd38: begin
            w.w = {1'b1, 2'd0, 4'd5, 9'd133, 9'd136, 9'd135, 9'd134};   // W_PL wCR
            w.m[0] = {1'b1, 3'd0, 9'd21, 9'd76, 9'd152};   // MUL_T CfCA
            w.m[1] = {1'b1, 3'd0, 9'd147, 9'd73, 9'd153};   // MUL_T A0CA
            w.m[2] = {1'b1, 3'd0, 9'd149, 9'd73, 9'd154};   // MUL_T B0CA
            w.m[3] = {1'b1, 3'd0, 9'd151, 9'd73, 9'd155};   // MUL_T C0CA
          end
          6'd39: begin
            w.w = {1'b1, 2'd0, 4'd6, 9'd152, 9'd155, 9'd154, 9'd153};   // W_PL wCA
            w.m[0] = {1'b1, 3'd0, 9'd31, 9'd76, 9'd251};   // MUL_T CfOB
            w.m[1] = {1'b1, 3'd0, 9'd246, 9'd73, 9'd252};   // MUL_T A0OB
            w.m[2] = {1'b1, 3'd0, 9'd248, 9'd73, 9'd253};   // MUL_T B0OB
            w.m[3] = {1'b1, 3'd0, 9'd250, 9'd73, 9'd254};   // MUL_T C0OB
          end
          6'd40: begin
            w.w = {1'b1, 2'd0, 4'd7, 9'd251, 9'd254, 9'd253, 9'd252};   // W_PL wOB
            w.m[0] = {1'b1, 3'd0, 9'd34, 9'd76, 9'd270};   // MUL_T CfOG
            w.m[1] = {1'b1, 3'd0, 9'd265, 9'd73, 9'd271};   // MUL_T A0OG
            w.m[2] = {1'b1, 3'd0, 9'd267, 9'd73, 9'd272};   // MUL_T B0OG
            w.m[3] = {1'b1, 3'd0, 9'd269, 9'd73, 9'd273};   // MUL_T C0OG
          end
          6'd41: begin
            w.w = {1'b1, 2'd0, 4'd8, 9'd270, 9'd273, 9'd272, 9'd271};   // W_PL wOG
            w.m[0] = {1'b1, 3'd0, 9'd37, 9'd76, 9'd289};   // MUL_T CfOR
            w.m[1] = {1'b1, 3'd0, 9'd284, 9'd73, 9'd290};   // MUL_T A0OR
            w.m[2] = {1'b1, 3'd0, 9'd286, 9'd73, 9'd291};   // MUL_T B0OR
            w.m[3] = {1'b1, 3'd0, 9'd288, 9'd73, 9'd292};   // MUL_T C0OR
          end
          6'd42: begin
            w.w = {1'b1, 2'd0, 4'd9, 9'd289, 9'd292, 9'd291, 9'd290};   // W_PL wOR
            w.m[0] = {1'b1, 3'd0, 9'd40, 9'd76, 9'd308};   // MUL_T CfOA
            w.m[1] = {1'b1, 3'd0, 9'd303, 9'd73, 9'd309};   // MUL_T A0OA
            w.m[2] = {1'b1, 3'd0, 9'd305, 9'd73, 9'd310};   // MUL_T B0OA
            w.m[3] = {1'b1, 3'd0, 9'd307, 9'd73, 9'd311};   // MUL_T C0OA
          end
          6'd43: begin
            w.w = {1'b1, 2'd0, 4'd10, 9'd308, 9'd311, 9'd310, 9'd309};   // W_PL wOA
            w.m[0] = {1'b1, 3'd4, 9'd222, 9'd195, 9'd223};   // MUL_B best
          end
          6'd44: begin
            w.w = {1'b1, 2'd2, 4'd0, 9'd0, 9'd0, 9'd0, 9'd223};   // W_K wK
          end
          default: ;
        endcase
      end
      4'd7: begin   // TEX_D
        case (pc)
          6'd0: begin
            w.m[0] = {1'b1, 3'd0, 9'd6, 9'd4, 9'd41};   // MUL_T pxy21
            w.m[1] = {1'b1, 3'd0, 9'd3, 9'd7, 9'd42};   // MUL_T pxy12
            w.m[2] = {1'b1, 3'd0, 9'd0, 9'd7, 9'd44};   // MUL_T pxy02
            w.m[3] = {1'b1, 3'd0, 9'd6, 9'd1, 9'd45};   // MUL_T pxy20
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd4, 9'd7, 9'd50};   // ADD_T dy0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd6, 9'd3, 9'd51};   // ADD_T dx0
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd7, 9'd1, 9'd55};   // ADD_T dy1
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd0, 9'd6, 9'd56};   // ADD_T dx1
          end
          6'd1: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd42, 9'd41, 9'd43};   // ADD_T e0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd45, 9'd44, 9'd46};   // ADD_T e1
            w.m[0] = {1'b1, 3'd0, 9'd3, 9'd1, 9'd47};   // MUL_T pxy10
            w.m[1] = {1'b1, 3'd0, 9'd0, 9'd4, 9'd48};   // MUL_T pxy01
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd1, 9'd4, 9'd60};   // ADD_T dy2
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd3, 9'd0, 9'd61};   // ADD_T dx2
          end
          6'd2: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd48, 9'd47, 9'd49};   // ADD_T e2
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd50, 9'd52};   // MUL_T wa0
            w.m[1] = {1'b1, 3'd0, 9'd2, 9'd51, 9'd53};   // MUL_T wb0
            w.m[2] = {1'b1, 3'd0, 9'd5, 9'd55, 9'd57};   // MUL_T wa1
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd56, 9'd58};   // MUL_T wb1
            w.a[1] = {1'b1, 3'd1, 1'b0, 9'd2, 9'd5, 9'd74};   // ADD_W m01
          end
          6'd3: begin
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd43, 9'd54};   // MUL_T wc0
            w.m[1] = {1'b1, 3'd0, 9'd5, 9'd46, 9'd59};   // MUL_T wc1
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd52, 9'd57, 9'd65};   // ADD_T SaW01
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd53, 9'd58, 9'd67};   // ADD_T SbW01
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd43, 9'd46, 9'd71};   // ADD_T Sdet01
            w.m[2] = {1'b1, 3'd0, 9'd22, 9'd52, 9'd156};   // MUL_T taU0
            w.m[3] = {1'b1, 3'd0, 9'd22, 9'd53, 9'd157};   // MUL_T tbU0
          end
          6'd4: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd49, 9'd64};   // MUL_T wc2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd74, 9'd8, 9'd75};   // ADD_T msum
            w.m[1] = {1'b1, 3'd0, 9'd22, 9'd54, 9'd158};   // MUL_T tcU0
            w.m[2] = {1'b1, 3'd0, 9'd23, 9'd57, 9'd159};   // MUL_T taU1
            w.m[3] = {1'b1, 3'd0, 9'd23, 9'd58, 9'd160};   // MUL_T tbU1
          end
          6'd5: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd54, 9'd64, 9'd69};   // ADD_T ScW02
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd71, 9'd49, 9'd72};   // ADD_T Sdet
            w.m[0] = {1'b1, 3'd0, 9'd23, 9'd59, 9'd161};   // MUL_T tcU1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd156, 9'd159, 9'd165};   // ADD_T Sa01U
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd157, 9'd160, 9'd167};   // ADD_T Sb01U
            w.m[1] = {1'b1, 3'd0, 9'd25, 9'd52, 9'd175};   // MUL_T taV0
            w.m[2] = {1'b1, 3'd0, 9'd25, 9'd53, 9'd176};   // MUL_T tbV0
            w.m[3] = {1'b1, 3'd0, 9'd25, 9'd54, 9'd177};   // MUL_T tcV0
          end
          6'd6: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd158, 9'd161, 9'd169};   // ADD_T Sc01U
            w.m[0] = {1'b1, 3'd0, 9'd26, 9'd57, 9'd178};   // MUL_T taV1
            w.m[1] = {1'b1, 3'd0, 9'd26, 9'd58, 9'd179};   // MUL_T tbV1
            w.m[2] = {1'b1, 3'd0, 9'd26, 9'd59, 9'd180};   // MUL_T tcV1
            w.m[3] = {1'b1, 3'd0, 9'd10, 9'd52, 9'd80};   // MUL_T taCB0
          end
          6'd7: begin
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd69, 9'd59, 9'd70};   // ADD_T ScW
            w.r = {1'b1, 1'b0, 9'd72, 9'd73};   // RCP_T inv
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd175, 9'd178, 9'd184};   // ADD_T Sa01V
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd176, 9'd179, 9'd186};   // ADD_T Sb01V
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd177, 9'd180, 9'd188};   // ADD_T Sc01V
            w.m[0] = {1'b1, 3'd0, 9'd10, 9'd53, 9'd81};   // MUL_T tbCB0
            w.m[1] = {1'b1, 3'd0, 9'd10, 9'd54, 9'd82};   // MUL_T tcCB0
            w.m[2] = {1'b1, 3'd0, 9'd11, 9'd57, 9'd83};   // MUL_T taCB1
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd58, 9'd84};   // MUL_T tbCB1
          end
          6'd8: begin
            w.m[0] = {1'b1, 3'd0, 9'd11, 9'd59, 9'd85};   // MUL_T tcCB1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd80, 9'd83, 9'd89};   // ADD_T Sa01CB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd81, 9'd84, 9'd91};   // ADD_T Sb01CB
            w.m[1] = {1'b1, 3'd0, 9'd13, 9'd52, 9'd99};   // MUL_T taCG0
            w.m[2] = {1'b1, 3'd0, 9'd13, 9'd53, 9'd100};   // MUL_T tbCG0
            w.m[3] = {1'b1, 3'd0, 9'd13, 9'd54, 9'd101};   // MUL_T tcCG0
          end
          6'd9: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd82, 9'd85, 9'd93};   // ADD_T Sc01CB
            w.m[0] = {1'b1, 3'd0, 9'd14, 9'd57, 9'd102};   // MUL_T taCG1
            w.m[1] = {1'b1, 3'd0, 9'd14, 9'd58, 9'd103};   // MUL_T tbCG1
            w.m[2] = {1'b1, 3'd0, 9'd14, 9'd59, 9'd104};   // MUL_T tcCG1
            w.m[3] = {1'b1, 3'd0, 9'd16, 9'd52, 9'd118};   // MUL_T taCR0
          end
          6'd10: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd99, 9'd102, 9'd108};   // ADD_T Sa01CG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd100, 9'd103, 9'd110};   // ADD_T Sb01CG
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd101, 9'd104, 9'd112};   // ADD_T Sc01CG
            w.m[0] = {1'b1, 3'd0, 9'd16, 9'd53, 9'd119};   // MUL_T tbCR0
            w.m[1] = {1'b1, 3'd0, 9'd16, 9'd54, 9'd120};   // MUL_T tcCR0
            w.m[2] = {1'b1, 3'd0, 9'd17, 9'd57, 9'd121};   // MUL_T taCR1
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd58, 9'd122};   // MUL_T tbCR1
          end
          6'd11: begin
            w.m[0] = {1'b1, 3'd0, 9'd17, 9'd59, 9'd123};   // MUL_T tcCR1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd118, 9'd121, 9'd127};   // ADD_T Sa01CR
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd119, 9'd122, 9'd129};   // ADD_T Sb01CR
            w.m[1] = {1'b1, 3'd0, 9'd19, 9'd52, 9'd137};   // MUL_T taCA0
            w.m[2] = {1'b1, 3'd0, 9'd19, 9'd53, 9'd138};   // MUL_T tbCA0
            w.m[3] = {1'b1, 3'd0, 9'd19, 9'd54, 9'd139};   // MUL_T tcCA0
          end
          6'd12: begin
            w.m[3] = {1'b1, 3'd0, 9'd8, 9'd60, 9'd62};   // MUL_T wa2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd120, 9'd123, 9'd131};   // ADD_T Sc01CR
            w.m[0] = {1'b1, 3'd0, 9'd20, 9'd57, 9'd140};   // MUL_T taCA1
            w.m[1] = {1'b1, 3'd0, 9'd20, 9'd58, 9'd141};   // MUL_T tbCA1
            w.m[2] = {1'b1, 3'd0, 9'd20, 9'd59, 9'd142};   // MUL_T tcCA1
          end
          6'd13: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd61, 9'd63};   // MUL_T wb2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd65, 9'd62, 9'd66};   // ADD_T SaW
            w.m[1] = {1'b1, 3'd0, 9'd24, 9'd62, 9'd162};   // MUL_T taU2
            w.m[2] = {1'b1, 3'd0, 9'd24, 9'd64, 9'd164};   // MUL_T tcU2
            w.m[3] = {1'b1, 3'd0, 9'd27, 9'd62, 9'd181};   // MUL_T taV2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd137, 9'd140, 9'd146};   // ADD_T Sa01CA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd138, 9'd141, 9'd148};   // ADD_T Sb01CA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd139, 9'd142, 9'd150};   // ADD_T Sc01CA
          end
          6'd14: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd67, 9'd63, 9'd68};   // ADD_T SbW
            w.m[0] = {1'b1, 3'd0, 9'd24, 9'd63, 9'd163};   // MUL_T tbU2
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd165, 9'd162, 9'd166};   // ADD_T SaU
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd169, 9'd164, 9'd170};   // ADD_T ScU
            w.m[1] = {1'b1, 3'd0, 9'd27, 9'd63, 9'd182};   // MUL_T tbV2
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd64, 9'd183};   // MUL_T tcV2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd184, 9'd181, 9'd185};   // ADD_T SaV
            w.m[3] = {1'b1, 3'd0, 9'd12, 9'd62, 9'd86};   // MUL_T taCB2
          end
          6'd15: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd167, 9'd163, 9'd168};   // ADD_T SbU
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd186, 9'd182, 9'd187};   // ADD_T SbV
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd188, 9'd183, 9'd189};   // ADD_T ScV
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd63, 9'd87};   // MUL_T tbCB2
            w.m[1] = {1'b1, 3'd0, 9'd12, 9'd64, 9'd88};   // MUL_T tcCB2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd89, 9'd86, 9'd90};   // ADD_T SaCB
            w.m[2] = {1'b1, 3'd0, 9'd15, 9'd62, 9'd105};   // MUL_T taCG2
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd63, 9'd106};   // MUL_T tbCG2
          end
          6'd16: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd91, 9'd87, 9'd92};   // ADD_T SbCB
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd93, 9'd88, 9'd94};   // ADD_T ScCB
            w.m[0] = {1'b1, 3'd0, 9'd15, 9'd64, 9'd107};   // MUL_T tcCG2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd108, 9'd105, 9'd109};   // ADD_T SaCG
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd110, 9'd106, 9'd111};   // ADD_T SbCG
            w.m[1] = {1'b1, 3'd0, 9'd18, 9'd62, 9'd124};   // MUL_T taCR2
            w.m[2] = {1'b1, 3'd0, 9'd18, 9'd63, 9'd125};   // MUL_T tbCR2
            w.m[3] = {1'b1, 3'd0, 9'd18, 9'd64, 9'd126};   // MUL_T tcCR2
          end
          6'd17: begin
            w.m[3] = {1'b1, 3'd0, 9'd75, 9'd9, 9'd76};   // MUL_T mean
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd112, 9'd107, 9'd113};   // ADD_T ScCG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd127, 9'd124, 9'd128};   // ADD_T SaCR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd129, 9'd125, 9'd130};   // ADD_T SbCR
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd131, 9'd126, 9'd132};   // ADD_T ScCR
            w.m[0] = {1'b1, 3'd0, 9'd21, 9'd62, 9'd143};   // MUL_T taCA2
            w.m[1] = {1'b1, 3'd0, 9'd21, 9'd63, 9'd144};   // MUL_T tbCA2
            w.m[2] = {1'b1, 3'd0, 9'd21, 9'd64, 9'd145};   // MUL_T tcCA2
          end
          6'd18: begin
            w.m[0] = {1'b1, 3'd0, 9'd66, 9'd73, 9'd77};   // MUL_T A0W
            w.m[1] = {1'b1, 3'd0, 9'd68, 9'd73, 9'd78};   // MUL_T B0W
            w.m[2] = {1'b1, 3'd0, 9'd70, 9'd73, 9'd79};   // MUL_T C0W
            w.m[3] = {1'b1, 3'd0, 9'd24, 9'd76, 9'd171};   // MUL_T CfU
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd146, 9'd143, 9'd147};   // ADD_T SaCA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd148, 9'd144, 9'd149};   // ADD_T SbCA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd150, 9'd145, 9'd151};   // ADD_T ScCA
            w.w = {1'b1, 2'd1, 4'd7, 9'd0, 9'd0, 9'd0, 9'd0};   // W_DR wOB
          end
          6'd19: begin
            w.w = {1'b1, 2'd0, 4'd0, 9'd76, 9'd79, 9'd78, 9'd77};   // W_PL wW
            w.m[0] = {1'b1, 3'd0, 9'd166, 9'd73, 9'd172};   // MUL_T A0U
            w.m[1] = {1'b1, 3'd0, 9'd168, 9'd73, 9'd173};   // MUL_T B0U
            w.m[2] = {1'b1, 3'd0, 9'd170, 9'd73, 9'd174};   // MUL_T C0U
            w.m[3] = {1'b1, 3'd0, 9'd27, 9'd76, 9'd190};   // MUL_T CfV
          end
          6'd20: begin
            w.w = {1'b1, 2'd0, 4'd1, 9'd171, 9'd174, 9'd173, 9'd172};   // W_PL wU
            w.m[0] = {1'b1, 3'd0, 9'd185, 9'd73, 9'd191};   // MUL_T A0V
            w.m[1] = {1'b1, 3'd0, 9'd187, 9'd73, 9'd192};   // MUL_T B0V
            w.m[2] = {1'b1, 3'd0, 9'd189, 9'd73, 9'd193};   // MUL_T C0V
            w.m[3] = {1'b1, 3'd0, 9'd12, 9'd76, 9'd95};   // MUL_T CfCB
          end
          6'd21: begin
            w.w = {1'b1, 2'd0, 4'd2, 9'd190, 9'd193, 9'd192, 9'd191};   // W_PL wV
            w.m[0] = {1'b1, 3'd0, 9'd90, 9'd73, 9'd96};   // MUL_T A0CB
            w.m[1] = {1'b1, 3'd0, 9'd92, 9'd73, 9'd97};   // MUL_T B0CB
            w.m[2] = {1'b1, 3'd0, 9'd94, 9'd73, 9'd98};   // MUL_T C0CB
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd76, 9'd114};   // MUL_T CfCG
          end
          6'd22: begin
            w.w = {1'b1, 2'd0, 4'd3, 9'd95, 9'd98, 9'd97, 9'd96};   // W_PL wCB
            w.m[0] = {1'b1, 3'd0, 9'd109, 9'd73, 9'd115};   // MUL_T A0CG
            w.m[1] = {1'b1, 3'd0, 9'd111, 9'd73, 9'd116};   // MUL_T B0CG
            w.m[2] = {1'b1, 3'd0, 9'd113, 9'd73, 9'd117};   // MUL_T C0CG
            w.m[3] = {1'b1, 3'd0, 9'd18, 9'd76, 9'd133};   // MUL_T CfCR
          end
          6'd23: begin
            w.w = {1'b1, 2'd0, 4'd4, 9'd114, 9'd117, 9'd116, 9'd115};   // W_PL wCG
            w.m[0] = {1'b1, 3'd0, 9'd128, 9'd73, 9'd134};   // MUL_T A0CR
            w.m[1] = {1'b1, 3'd0, 9'd130, 9'd73, 9'd135};   // MUL_T B0CR
            w.m[2] = {1'b1, 3'd0, 9'd132, 9'd73, 9'd136};   // MUL_T C0CR
            w.m[3] = {1'b1, 3'd0, 9'd21, 9'd76, 9'd152};   // MUL_T CfCA
          end
          6'd24: begin
            w.w = {1'b1, 2'd0, 4'd5, 9'd133, 9'd136, 9'd135, 9'd134};   // W_PL wCR
            w.m[0] = {1'b1, 3'd0, 9'd147, 9'd73, 9'd153};   // MUL_T A0CA
            w.m[1] = {1'b1, 3'd0, 9'd149, 9'd73, 9'd154};   // MUL_T B0CA
            w.m[2] = {1'b1, 3'd0, 9'd151, 9'd73, 9'd155};   // MUL_T C0CA
          end
          6'd25: begin
            w.w = {1'b1, 2'd0, 4'd6, 9'd152, 9'd155, 9'd154, 9'd153};   // W_PL wCA
          end
          6'd26: begin
            w.w = {1'b1, 2'd1, 4'd8, 9'd0, 9'd0, 9'd0, 9'd0};   // W_DR wOG
          end
          6'd27: begin
            w.w = {1'b1, 2'd1, 4'd9, 9'd0, 9'd0, 9'd0, 9'd0};   // W_DR wOR
          end
          6'd28: begin
            w.w = {1'b1, 2'd1, 4'd10, 9'd0, 9'd0, 9'd0, 9'd0};   // W_DR wOA
          end
          default: ;
        endcase
      end
      4'd8: begin   // TEX_D_M0
        case (pc)
          6'd0: begin
            w.m[0] = {1'b1, 3'd0, 9'd6, 9'd4, 9'd41};   // MUL_T pxy21
            w.m[1] = {1'b1, 3'd0, 9'd3, 9'd7, 9'd42};   // MUL_T pxy12
            w.m[2] = {1'b1, 3'd0, 9'd0, 9'd7, 9'd44};   // MUL_T pxy02
            w.m[3] = {1'b1, 3'd0, 9'd6, 9'd1, 9'd45};   // MUL_T pxy20
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd4, 9'd7, 9'd50};   // ADD_T dy0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd6, 9'd3, 9'd51};   // ADD_T dx0
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd7, 9'd1, 9'd55};   // ADD_T dy1
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd0, 9'd6, 9'd56};   // ADD_T dx1
          end
          6'd1: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd42, 9'd41, 9'd43};   // ADD_T e0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd45, 9'd44, 9'd46};   // ADD_T e1
            w.m[0] = {1'b1, 3'd0, 9'd3, 9'd1, 9'd47};   // MUL_T pxy10
            w.m[1] = {1'b1, 3'd0, 9'd0, 9'd4, 9'd48};   // MUL_T pxy01
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd1, 9'd4, 9'd60};   // ADD_T dy2
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd3, 9'd0, 9'd61};   // ADD_T dx2
          end
          6'd2: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd48, 9'd47, 9'd49};   // ADD_T e2
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd50, 9'd52};   // MUL_T wa0
            w.m[1] = {1'b1, 3'd0, 9'd2, 9'd51, 9'd53};   // MUL_T wb0
            w.m[2] = {1'b1, 3'd0, 9'd5, 9'd55, 9'd57};   // MUL_T wa1
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd56, 9'd58};   // MUL_T wb1
            w.a[1] = {1'b1, 3'd1, 1'b0, 9'd2, 9'd5, 9'd74};   // ADD_W m01
          end
          6'd3: begin
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd43, 9'd54};   // MUL_T wc0
            w.m[1] = {1'b1, 3'd0, 9'd5, 9'd46, 9'd59};   // MUL_T wc1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd52, 9'd57, 9'd65};   // ADD_T SaW01
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd53, 9'd58, 9'd67};   // ADD_T SbW01
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd43, 9'd46, 9'd71};   // ADD_T Sdet01
            w.m[2] = {1'b1, 3'd0, 9'd22, 9'd52, 9'd156};   // MUL_T taU0
            w.m[3] = {1'b1, 3'd0, 9'd22, 9'd53, 9'd157};   // MUL_T tbU0
          end
          6'd4: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd49, 9'd64};   // MUL_T wc2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd74, 9'd8, 9'd75};   // ADD_T msum
            w.m[1] = {1'b1, 3'd0, 9'd22, 9'd54, 9'd158};   // MUL_T tcU0
            w.m[2] = {1'b1, 3'd0, 9'd23, 9'd57, 9'd159};   // MUL_T taU1
            w.m[3] = {1'b1, 3'd0, 9'd23, 9'd58, 9'd160};   // MUL_T tbU1
          end
          6'd5: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd54, 9'd64, 9'd69};   // ADD_T ScW02
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd71, 9'd49, 9'd72};   // ADD_T Sdet
            w.m[0] = {1'b1, 3'd0, 9'd23, 9'd59, 9'd161};   // MUL_T tcU1
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd156, 9'd159, 9'd165};   // ADD_T Sa01U
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd157, 9'd160, 9'd167};   // ADD_T Sb01U
            w.m[1] = {1'b1, 3'd0, 9'd25, 9'd52, 9'd175};   // MUL_T taV0
            w.m[2] = {1'b1, 3'd0, 9'd25, 9'd53, 9'd176};   // MUL_T tbV0
            w.m[3] = {1'b1, 3'd0, 9'd25, 9'd54, 9'd177};   // MUL_T tcV0
          end
          6'd6: begin
            w.m[3] = {1'b1, 3'd0, 9'd8, 9'd60, 9'd62};   // MUL_T wa2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd158, 9'd161, 9'd169};   // ADD_T Sc01U
            w.m[0] = {1'b1, 3'd0, 9'd26, 9'd57, 9'd178};   // MUL_T taV1
            w.m[1] = {1'b1, 3'd0, 9'd26, 9'd58, 9'd179};   // MUL_T tbV1
            w.m[2] = {1'b1, 3'd0, 9'd26, 9'd59, 9'd180};   // MUL_T tcV1
          end
          6'd7: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd61, 9'd63};   // MUL_T wb2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd65, 9'd62, 9'd66};   // ADD_T SaW
            w.m[1] = {1'b1, 3'd0, 9'd24, 9'd62, 9'd162};   // MUL_T taU2
            w.m[2] = {1'b1, 3'd0, 9'd24, 9'd64, 9'd164};   // MUL_T tcU2
            w.m[3] = {1'b1, 3'd0, 9'd27, 9'd62, 9'd181};   // MUL_T taV2
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd175, 9'd178, 9'd184};   // ADD_T Sa01V
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd176, 9'd179, 9'd186};   // ADD_T Sb01V
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd177, 9'd180, 9'd188};   // ADD_T Sc01V
            w.r = {1'b1, 1'b1, 9'd72, 9'd194};   // RCP_M minv
          end
          6'd8: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd67, 9'd63, 9'd68};   // ADD_T SbW
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd69, 9'd59, 9'd70};   // ADD_T ScW
            w.r = {1'b1, 1'b0, 9'd72, 9'd73};   // RCP_T inv
            w.m[0] = {1'b1, 3'd0, 9'd24, 9'd63, 9'd163};   // MUL_T tbU2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd165, 9'd162, 9'd166};   // ADD_T SaU
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd169, 9'd164, 9'd170};   // ADD_T ScU
            w.m[1] = {1'b1, 3'd0, 9'd27, 9'd63, 9'd182};   // MUL_T tbV2
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd64, 9'd183};   // MUL_T tcV2
            w.m[3] = {1'b1, 3'd0, 9'd10, 9'd52, 9'd80};   // MUL_T taCB0
          end
          6'd9: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd167, 9'd163, 9'd168};   // ADD_T SbU
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd184, 9'd181, 9'd185};   // ADD_T SaV
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd186, 9'd182, 9'd187};   // ADD_T SbV
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd188, 9'd183, 9'd189};   // ADD_T ScV
            w.m[1] = {1'b1, 3'd0, 9'd10, 9'd53, 9'd81};   // MUL_T tbCB0
            w.m[2] = {1'b1, 3'd0, 9'd10, 9'd54, 9'd82};   // MUL_T tcCB0
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd57, 9'd83};   // MUL_T taCB1
            w.m[0] = {1'b1, 3'd3, 9'd194, 9'd194, 9'd195};   // MUL_I2 inv2
          end
          6'd10: begin
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd58, 9'd84};   // MUL_T tbCB1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd80, 9'd83, 9'd89};   // ADD_T Sa01CB
            w.m[0] = {1'b1, 3'd1, 9'd170, 9'd66, 9'd196};   // MUL_K q1ux
            w.m[1] = {1'b1, 3'd1, 9'd166, 9'd70, 9'd197};   // MUL_K q2ux
            w.m[2] = {1'b1, 3'd1, 9'd170, 9'd68, 9'd205};   // MUL_K q2uy
          end
          6'd11: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd81, 9'd84, 9'd91};   // ADD_T Sb01CB
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd196, 9'd197, 9'd198};   // ADD_N nux
            w.m[0] = {1'b1, 3'd1, 9'd189, 9'd66, 9'd200};   // MUL_K q1vx
            w.m[1] = {1'b1, 3'd1, 9'd185, 9'd70, 9'd201};   // MUL_K q2vx
            w.m[2] = {1'b1, 3'd1, 9'd168, 9'd70, 9'd204};   // MUL_K q1uy
            w.m[3] = {1'b1, 3'd1, 9'd187, 9'd70, 9'd208};   // MUL_K q1vy
          end
          6'd12: begin
            w.m[1] = {1'b1, 3'd0, 9'd11, 9'd59, 9'd85};   // MUL_T tcCB1
            w.m[2] = {1'b1, 3'd0, 9'd13, 9'd52, 9'd99};   // MUL_T taCG0
            w.m[3] = {1'b1, 3'd0, 9'd13, 9'd53, 9'd100};   // MUL_T tbCG0
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd200, 9'd201, 9'd202};   // ADD_N nvx
            w.a[1] = {1'b1, 3'd3, 1'b0, 9'd204, 9'd205, 9'd206};   // ADD_N nuy
            w.m[0] = {1'b1, 3'd1, 9'd189, 9'd68, 9'd209};   // MUL_K q2vy
          end
          6'd13: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd82, 9'd85, 9'd93};   // ADD_T Sc01CB
            w.m[1] = {1'b1, 3'd0, 9'd13, 9'd54, 9'd101};   // MUL_T tcCG0
            w.m[2] = {1'b1, 3'd0, 9'd14, 9'd57, 9'd102};   // MUL_T taCG1
            w.m[3] = {1'b1, 3'd0, 9'd14, 9'd58, 9'd103};   // MUL_T tbCG1
            w.m[0] = {1'b1, 3'd2, 9'd198, 9'd195, 9'd199};   // MUL_Q nqux
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd208, 9'd209, 9'd210};   // ADD_N nvy
          end
          6'd14: begin
            w.m[2] = {1'b1, 3'd0, 9'd14, 9'd59, 9'd104};   // MUL_T tcCG1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd99, 9'd102, 9'd108};   // ADD_T Sa01CG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd100, 9'd103, 9'd110};   // ADD_T Sb01CG
            w.m[3] = {1'b1, 3'd0, 9'd16, 9'd52, 9'd118};   // MUL_T taCR0
            w.m[0] = {1'b1, 3'd2, 9'd202, 9'd195, 9'd203};   // MUL_Q nqvx
            w.m[1] = {1'b1, 3'd2, 9'd206, 9'd195, 9'd207};   // MUL_Q nquy
          end
          6'd15: begin
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd101, 9'd104, 9'd112};   // ADD_T Sc01CG
            w.m[1] = {1'b1, 3'd0, 9'd16, 9'd53, 9'd119};   // MUL_T tbCR0
            w.m[2] = {1'b1, 3'd0, 9'd16, 9'd54, 9'd120};   // MUL_T tcCR0
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd57, 9'd121};   // MUL_T taCR1
            w.m[0] = {1'b1, 3'd2, 9'd210, 9'd195, 9'd211};   // MUL_Q nqvy
            w.a[0] = {1'b1, 3'd4, 1'b0, 9'd199, 9'd203, 9'd212};   // ADD_LX lhix
            w.a[1] = {1'b1, 3'd5, 1'b0, 9'd199, 9'd203, 9'd213};   // ADD_LN llox
          end
          6'd16: begin
            w.m[0] = {1'b1, 3'd0, 9'd17, 9'd58, 9'd122};   // MUL_T tbCR1
            w.m[1] = {1'b1, 3'd0, 9'd17, 9'd59, 9'd123};   // MUL_T tcCR1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd118, 9'd121, 9'd127};   // ADD_T Sa01CR
            w.m[2] = {1'b1, 3'd0, 9'd19, 9'd52, 9'd137};   // MUL_T taCA0
            w.m[3] = {1'b1, 3'd0, 9'd19, 9'd53, 9'd138};   // MUL_T tbCA0
            w.a[0] = {1'b1, 3'd4, 1'b0, 9'd207, 9'd211, 9'd217};   // ADD_LX lhiy
            w.a[1] = {1'b1, 3'd5, 1'b0, 9'd207, 9'd211, 9'd218};   // ADD_LN lloy
          end
          6'd17: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd119, 9'd122, 9'd129};   // ADD_T Sb01CR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd120, 9'd123, 9'd131};   // ADD_T Sc01CR
            w.m[0] = {1'b1, 3'd0, 9'd19, 9'd54, 9'd139};   // MUL_T tcCA0
            w.m[1] = {1'b1, 3'd0, 9'd20, 9'd57, 9'd140};   // MUL_T taCA1
            w.m[2] = {1'b1, 3'd0, 9'd20, 9'd58, 9'd141};   // MUL_T tbCA1
            w.m[3] = {1'b1, 3'd0, 9'd20, 9'd59, 9'd142};   // MUL_T tcCA1
            w.a[0] = {1'b1, 3'd7, 1'b0, 9'd212, 9'd213, 9'd214};   // ADD_P lsumx
          end
          6'd18: begin
            w.m[2] = {1'b1, 3'd0, 9'd12, 9'd62, 9'd86};   // MUL_T taCB2
            w.m[3] = {1'b1, 3'd0, 9'd12, 9'd63, 9'd87};   // MUL_T tbCB2
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd137, 9'd140, 9'd146};   // ADD_T Sa01CA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd138, 9'd141, 9'd148};   // ADD_T Sb01CA
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd139, 9'd142, 9'd150};   // ADD_T Sc01CA
            w.m[0] = {1'b1, 3'd5, 9'd213, 9'd28, 9'd215};   // MUL_P llessx
            w.a[0] = {1'b1, 3'd7, 1'b0, 9'd217, 9'd218, 9'd219};   // ADD_P lsumy
            w.m[1] = {1'b1, 3'd5, 9'd218, 9'd28, 9'd220};   // MUL_P llessy
          end
          6'd19: begin
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd64, 9'd88};   // MUL_T tcCB2
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd89, 9'd86, 9'd90};   // ADD_T SaCB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd91, 9'd87, 9'd92};   // ADD_T SbCB
            w.m[1] = {1'b1, 3'd0, 9'd15, 9'd62, 9'd105};   // MUL_T taCG2
            w.m[2] = {1'b1, 3'd0, 9'd15, 9'd63, 9'd106};   // MUL_T tbCG2
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd64, 9'd107};   // MUL_T tcCG2
            w.a[0] = {1'b1, 3'd7, 1'b1, 9'd214, 9'd215, 9'd216};   // ADD_P lenx
          end
          6'd20: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd93, 9'd88, 9'd94};   // ADD_T ScCB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd108, 9'd105, 9'd109};   // ADD_T SaCG
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd110, 9'd106, 9'd111};   // ADD_T SbCG
            w.m[0] = {1'b1, 3'd0, 9'd18, 9'd62, 9'd124};   // MUL_T taCR2
            w.m[1] = {1'b1, 3'd0, 9'd18, 9'd63, 9'd125};   // MUL_T tbCR2
            w.m[2] = {1'b1, 3'd0, 9'd18, 9'd64, 9'd126};   // MUL_T tcCR2
            w.m[3] = {1'b1, 3'd0, 9'd21, 9'd62, 9'd143};   // MUL_T taCA2
            w.a[0] = {1'b1, 3'd7, 1'b1, 9'd219, 9'd220, 9'd221};   // ADD_P leny
          end
          6'd21: begin
            w.m[2] = {1'b1, 3'd0, 9'd75, 9'd9, 9'd76};   // MUL_T mean
            w.m[3] = {1'b1, 3'd0, 9'd66, 9'd73, 9'd77};   // MUL_T A0W
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd112, 9'd107, 9'd113};   // ADD_T ScCG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd127, 9'd124, 9'd128};   // ADD_T SaCR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd129, 9'd125, 9'd130};   // ADD_T SbCR
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd131, 9'd126, 9'd132};   // ADD_T ScCR
            w.m[0] = {1'b1, 3'd0, 9'd21, 9'd63, 9'd144};   // MUL_T tbCA2
            w.m[1] = {1'b1, 3'd0, 9'd21, 9'd64, 9'd145};   // MUL_T tcCA2
          end
          6'd22: begin
            w.m[0] = {1'b1, 3'd0, 9'd68, 9'd73, 9'd78};   // MUL_T B0W
            w.m[1] = {1'b1, 3'd0, 9'd70, 9'd73, 9'd79};   // MUL_T C0W
            w.m[2] = {1'b1, 3'd0, 9'd24, 9'd76, 9'd171};   // MUL_T CfU
            w.m[3] = {1'b1, 3'd0, 9'd166, 9'd73, 9'd172};   // MUL_T A0U
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd146, 9'd143, 9'd147};   // ADD_T SaCA
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd148, 9'd144, 9'd149};   // ADD_T SbCA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd150, 9'd145, 9'd151};   // ADD_T ScCA
            w.w = {1'b1, 2'd1, 4'd7, 9'd0, 9'd0, 9'd0, 9'd0};   // W_DR wOB
            w.a[3] = {1'b1, 3'd6, 1'b0, 9'd216, 9'd221, 9'd222};   // ADD_BS best0
          end
          6'd23: begin
            w.w = {1'b1, 2'd0, 4'd0, 9'd76, 9'd79, 9'd78, 9'd77};   // W_PL wW
            w.m[0] = {1'b1, 3'd0, 9'd168, 9'd73, 9'd173};   // MUL_T B0U
            w.m[1] = {1'b1, 3'd0, 9'd170, 9'd73, 9'd174};   // MUL_T C0U
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd76, 9'd190};   // MUL_T CfV
            w.m[3] = {1'b1, 3'd0, 9'd185, 9'd73, 9'd191};   // MUL_T A0V
          end
          6'd24: begin
            w.w = {1'b1, 2'd0, 4'd1, 9'd171, 9'd174, 9'd173, 9'd172};   // W_PL wU
            w.m[0] = {1'b1, 3'd0, 9'd187, 9'd73, 9'd192};   // MUL_T B0V
            w.m[1] = {1'b1, 3'd0, 9'd189, 9'd73, 9'd193};   // MUL_T C0V
            w.m[2] = {1'b1, 3'd0, 9'd12, 9'd76, 9'd95};   // MUL_T CfCB
            w.m[3] = {1'b1, 3'd0, 9'd90, 9'd73, 9'd96};   // MUL_T A0CB
          end
          6'd25: begin
            w.w = {1'b1, 2'd0, 4'd2, 9'd190, 9'd193, 9'd192, 9'd191};   // W_PL wV
            w.m[0] = {1'b1, 3'd0, 9'd92, 9'd73, 9'd97};   // MUL_T B0CB
            w.m[1] = {1'b1, 3'd0, 9'd94, 9'd73, 9'd98};   // MUL_T C0CB
            w.m[2] = {1'b1, 3'd0, 9'd15, 9'd76, 9'd114};   // MUL_T CfCG
            w.m[3] = {1'b1, 3'd0, 9'd109, 9'd73, 9'd115};   // MUL_T A0CG
          end
          6'd26: begin
            w.w = {1'b1, 2'd0, 4'd3, 9'd95, 9'd98, 9'd97, 9'd96};   // W_PL wCB
            w.m[0] = {1'b1, 3'd0, 9'd111, 9'd73, 9'd116};   // MUL_T B0CG
            w.m[1] = {1'b1, 3'd0, 9'd113, 9'd73, 9'd117};   // MUL_T C0CG
            w.m[2] = {1'b1, 3'd0, 9'd18, 9'd76, 9'd133};   // MUL_T CfCR
            w.m[3] = {1'b1, 3'd0, 9'd128, 9'd73, 9'd134};   // MUL_T A0CR
          end
          6'd27: begin
            w.w = {1'b1, 2'd0, 4'd4, 9'd114, 9'd117, 9'd116, 9'd115};   // W_PL wCG
            w.m[0] = {1'b1, 3'd0, 9'd130, 9'd73, 9'd135};   // MUL_T B0CR
            w.m[1] = {1'b1, 3'd0, 9'd132, 9'd73, 9'd136};   // MUL_T C0CR
            w.m[2] = {1'b1, 3'd0, 9'd21, 9'd76, 9'd152};   // MUL_T CfCA
            w.m[3] = {1'b1, 3'd0, 9'd147, 9'd73, 9'd153};   // MUL_T A0CA
          end
          6'd28: begin
            w.w = {1'b1, 2'd0, 4'd5, 9'd133, 9'd136, 9'd135, 9'd134};   // W_PL wCR
            w.m[0] = {1'b1, 3'd0, 9'd149, 9'd73, 9'd154};   // MUL_T B0CA
            w.m[1] = {1'b1, 3'd0, 9'd151, 9'd73, 9'd155};   // MUL_T C0CA
            w.m[2] = {1'b1, 3'd4, 9'd222, 9'd195, 9'd223};   // MUL_B best
          end
          6'd29: begin
            w.w = {1'b1, 2'd0, 4'd6, 9'd152, 9'd155, 9'd154, 9'd153};   // W_PL wCA
          end
          6'd30: begin
            w.w = {1'b1, 2'd1, 4'd8, 9'd0, 9'd0, 9'd0, 9'd0};   // W_DR wOG
          end
          6'd31: begin
            w.w = {1'b1, 2'd1, 4'd9, 9'd0, 9'd0, 9'd0, 9'd0};   // W_DR wOR
          end
          6'd32: begin
            w.w = {1'b1, 2'd1, 4'd10, 9'd0, 9'd0, 9'd0, 9'd0};   // W_DR wOA
          end
          6'd33: begin
            w.w = {1'b1, 2'd2, 4'd0, 9'd0, 9'd0, 9'd0, 9'd223};   // W_K wK
          end
          default: ;
        endcase
      end
      4'd9: begin   // TEX_D_M1
        case (pc)
          6'd0: begin
            w.m[0] = {1'b1, 3'd0, 9'd6, 9'd4, 9'd41};   // MUL_T pxy21
            w.m[1] = {1'b1, 3'd0, 9'd3, 9'd7, 9'd42};   // MUL_T pxy12
            w.m[2] = {1'b1, 3'd0, 9'd0, 9'd7, 9'd44};   // MUL_T pxy02
            w.m[3] = {1'b1, 3'd0, 9'd6, 9'd1, 9'd45};   // MUL_T pxy20
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd4, 9'd7, 9'd50};   // ADD_T dy0
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd6, 9'd3, 9'd51};   // ADD_T dx0
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd7, 9'd1, 9'd55};   // ADD_T dy1
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd0, 9'd6, 9'd56};   // ADD_T dx1
          end
          6'd1: begin
            w.a[2] = {1'b1, 3'd0, 1'b1, 9'd42, 9'd41, 9'd43};   // ADD_T e0
            w.a[3] = {1'b1, 3'd0, 1'b1, 9'd45, 9'd44, 9'd46};   // ADD_T e1
            w.m[0] = {1'b1, 3'd0, 9'd3, 9'd1, 9'd47};   // MUL_T pxy10
            w.m[1] = {1'b1, 3'd0, 9'd0, 9'd4, 9'd48};   // MUL_T pxy01
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd1, 9'd4, 9'd60};   // ADD_T dy2
            w.a[1] = {1'b1, 3'd0, 1'b1, 9'd3, 9'd0, 9'd61};   // ADD_T dx2
          end
          6'd2: begin
            w.a[0] = {1'b1, 3'd0, 1'b1, 9'd48, 9'd47, 9'd49};   // ADD_T e2
            w.m[0] = {1'b1, 3'd0, 9'd2, 9'd50, 9'd52};   // MUL_T wa0
            w.m[1] = {1'b1, 3'd0, 9'd2, 9'd51, 9'd53};   // MUL_T wb0
            w.m[2] = {1'b1, 3'd0, 9'd5, 9'd55, 9'd57};   // MUL_T wa1
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd56, 9'd58};   // MUL_T wb1
            w.a[1] = {1'b1, 3'd1, 1'b0, 9'd2, 9'd5, 9'd74};   // ADD_W m01
          end
          6'd3: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd52, 9'd57, 9'd65};   // ADD_T SaW01
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd53, 9'd58, 9'd67};   // ADD_T SbW01
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd43, 9'd46, 9'd71};   // ADD_T Sdet01
            w.m[0] = {1'b1, 3'd0, 9'd22, 9'd52, 9'd156};   // MUL_T taU0
            w.m[1] = {1'b1, 3'd0, 9'd22, 9'd53, 9'd157};   // MUL_T tbU0
            w.m[2] = {1'b1, 3'd0, 9'd23, 9'd57, 9'd159};   // MUL_T taU1
            w.m[3] = {1'b1, 3'd0, 9'd23, 9'd58, 9'd160};   // MUL_T tbU1
          end
          6'd4: begin
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd74, 9'd8, 9'd75};   // ADD_T msum
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd156, 9'd159, 9'd165};   // ADD_T Sa01U
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd157, 9'd160, 9'd167};   // ADD_T Sb01U
            w.m[0] = {1'b1, 3'd0, 9'd25, 9'd52, 9'd175};   // MUL_T taV0
            w.m[1] = {1'b1, 3'd0, 9'd25, 9'd53, 9'd176};   // MUL_T tbV0
            w.m[2] = {1'b1, 3'd0, 9'd26, 9'd57, 9'd178};   // MUL_T taV1
            w.m[3] = {1'b1, 3'd0, 9'd26, 9'd58, 9'd179};   // MUL_T tbV1
          end
          6'd5: begin
            w.m[2] = {1'b1, 3'd0, 9'd2, 9'd43, 9'd54};   // MUL_T wc0
            w.m[3] = {1'b1, 3'd0, 9'd5, 9'd46, 9'd59};   // MUL_T wc1
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd60, 9'd62};   // MUL_T wa2
            w.m[1] = {1'b1, 3'd0, 9'd8, 9'd61, 9'd63};   // MUL_T wb2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd71, 9'd49, 9'd72};   // ADD_T Sdet
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd175, 9'd178, 9'd184};   // ADD_T Sa01V
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd176, 9'd179, 9'd186};   // ADD_T Sb01V
          end
          6'd6: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd65, 9'd62, 9'd66};   // ADD_T SaW
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd67, 9'd63, 9'd68};   // ADD_T SbW
            w.m[0] = {1'b1, 3'd0, 9'd24, 9'd62, 9'd162};   // MUL_T taU2
            w.m[1] = {1'b1, 3'd0, 9'd24, 9'd63, 9'd163};   // MUL_T tbU2
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd62, 9'd181};   // MUL_T taV2
            w.m[3] = {1'b1, 3'd0, 9'd27, 9'd63, 9'd182};   // MUL_T tbV2
          end
          6'd7: begin
            w.m[0] = {1'b1, 3'd0, 9'd8, 9'd49, 9'd64};   // MUL_T wc2
            w.m[1] = {1'b1, 3'd0, 9'd22, 9'd54, 9'd158};   // MUL_T tcU0
            w.m[2] = {1'b1, 3'd0, 9'd23, 9'd59, 9'd161};   // MUL_T tcU1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd165, 9'd162, 9'd166};   // ADD_T SaU
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd167, 9'd163, 9'd168};   // ADD_T SbU
            w.m[3] = {1'b1, 3'd0, 9'd25, 9'd54, 9'd177};   // MUL_T tcV0
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd184, 9'd181, 9'd185};   // ADD_T SaV
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd186, 9'd182, 9'd187};   // ADD_T SbV
            w.r = {1'b1, 1'b1, 9'd72, 9'd194};   // RCP_M minv
          end
          6'd8: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd54, 9'd64, 9'd69};   // ADD_T ScW02
            w.r = {1'b1, 1'b0, 9'd72, 9'd73};   // RCP_T inv
            w.m[1] = {1'b1, 3'd0, 9'd24, 9'd64, 9'd164};   // MUL_T tcU2
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd158, 9'd161, 9'd169};   // ADD_T Sc01U
            w.m[0] = {1'b1, 3'd0, 9'd26, 9'd59, 9'd180};   // MUL_T tcV1
            w.m[2] = {1'b1, 3'd0, 9'd27, 9'd64, 9'd183};   // MUL_T tcV2
            w.m[3] = {1'b1, 3'd0, 9'd66, 9'd0, 9'd232};   // MUL_T d1aW
          end
          6'd9: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd177, 9'd180, 9'd188};   // ADD_T Sc01V
            w.m[0] = {1'b1, 3'd0, 9'd166, 9'd0, 9'd224};   // MUL_T d1aU
            w.m[1] = {1'b1, 3'd0, 9'd168, 9'd1, 9'd225};   // MUL_T d1bU
            w.m[2] = {1'b1, 3'd0, 9'd185, 9'd0, 9'd228};   // MUL_T d1aV
            w.m[3] = {1'b1, 3'd0, 9'd187, 9'd1, 9'd229};   // MUL_T d1bV
          end
          6'd10: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd69, 9'd59, 9'd70};   // ADD_T ScW
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd169, 9'd164, 9'd170};   // ADD_T ScU
            w.m[2] = {1'b1, 3'd0, 9'd10, 9'd52, 9'd80};   // MUL_T taCB0
            w.m[3] = {1'b1, 3'd0, 9'd10, 9'd53, 9'd81};   // MUL_T tbCB0
            w.m[1] = {1'b1, 3'd3, 9'd194, 9'd194, 9'd195};   // MUL_I2 inv2
            w.a[2] = {1'b1, 3'd2, 1'b0, 9'd224, 9'd225, 9'd226};   // ADD_R d1abU
            w.a[3] = {1'b1, 3'd2, 1'b0, 9'd228, 9'd229, 9'd230};   // ADD_R d1abV
            w.m[0] = {1'b1, 3'd0, 9'd68, 9'd1, 9'd233};   // MUL_T d1bW
          end
          6'd11: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd188, 9'd183, 9'd189};   // ADD_T ScV
            w.m[0] = {1'b1, 3'd0, 9'd10, 9'd54, 9'd82};   // MUL_T tcCB0
            w.m[1] = {1'b1, 3'd0, 9'd11, 9'd57, 9'd83};   // MUL_T taCB1
            w.m[2] = {1'b1, 3'd0, 9'd11, 9'd58, 9'd84};   // MUL_T tbCB1
            w.m[3] = {1'b1, 3'd0, 9'd11, 9'd59, 9'd85};   // MUL_T tcCB1
            w.a[1] = {1'b1, 3'd2, 1'b0, 9'd232, 9'd233, 9'd234};   // ADD_R d1abW
          end
          6'd12: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd80, 9'd83, 9'd89};   // ADD_T Sa01CB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd81, 9'd84, 9'd91};   // ADD_T Sb01CB
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd82, 9'd85, 9'd93};   // ADD_T Sc01CB
            w.m[0] = {1'b1, 3'd0, 9'd13, 9'd52, 9'd99};   // MUL_T taCG0
            w.m[1] = {1'b1, 3'd0, 9'd13, 9'd53, 9'd100};   // MUL_T tbCG0
            w.m[2] = {1'b1, 3'd0, 9'd13, 9'd54, 9'd101};   // MUL_T tcCG0
            w.m[3] = {1'b1, 3'd0, 9'd14, 9'd57, 9'd102};   // MUL_T taCG1
            w.a[0] = {1'b1, 3'd2, 1'b0, 9'd226, 9'd170, 9'd227};   // ADD_R d1U
          end
          6'd13: begin
            w.m[0] = {1'b1, 3'd0, 9'd14, 9'd58, 9'd103};   // MUL_T tbCG1
            w.m[1] = {1'b1, 3'd0, 9'd14, 9'd59, 9'd104};   // MUL_T tcCG1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd99, 9'd102, 9'd108};   // ADD_T Sa01CG
            w.m[2] = {1'b1, 3'd0, 9'd16, 9'd52, 9'd118};   // MUL_T taCR0
            w.m[3] = {1'b1, 3'd0, 9'd16, 9'd53, 9'd119};   // MUL_T tbCR0
            w.a[0] = {1'b1, 3'd2, 1'b0, 9'd230, 9'd189, 9'd231};   // ADD_R d1V
            w.a[1] = {1'b1, 3'd2, 1'b0, 9'd234, 9'd70, 9'd235};   // ADD_R d1W
          end
          6'd14: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd100, 9'd103, 9'd110};   // ADD_T Sb01CG
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd101, 9'd104, 9'd112};   // ADD_T Sc01CG
            w.m[2] = {1'b1, 3'd0, 9'd16, 9'd54, 9'd120};   // MUL_T tcCR0
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd57, 9'd121};   // MUL_T taCR1
            w.m[0] = {1'b1, 3'd1, 9'd227, 9'd66, 9'd196};   // MUL_K q1ux
            w.m[1] = {1'b1, 3'd1, 9'd227, 9'd68, 9'd205};   // MUL_K q2uy
          end
          6'd15: begin
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd118, 9'd121, 9'd127};   // ADD_T Sa01CR
            w.m[0] = {1'b1, 3'd1, 9'd166, 9'd235, 9'd197};   // MUL_K q2ux
            w.m[1] = {1'b1, 3'd1, 9'd231, 9'd66, 9'd200};   // MUL_K q1vx
            w.m[2] = {1'b1, 3'd1, 9'd185, 9'd235, 9'd201};   // MUL_K q2vx
            w.m[3] = {1'b1, 3'd1, 9'd168, 9'd235, 9'd204};   // MUL_K q1uy
          end
          6'd16: begin
            w.m[2] = {1'b1, 3'd0, 9'd17, 9'd58, 9'd122};   // MUL_T tbCR1
            w.m[3] = {1'b1, 3'd0, 9'd17, 9'd59, 9'd123};   // MUL_T tcCR1
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd196, 9'd197, 9'd198};   // ADD_N nux
            w.a[1] = {1'b1, 3'd3, 1'b0, 9'd200, 9'd201, 9'd202};   // ADD_N nvx
            w.a[2] = {1'b1, 3'd3, 1'b0, 9'd204, 9'd205, 9'd206};   // ADD_N nuy
            w.m[0] = {1'b1, 3'd1, 9'd187, 9'd235, 9'd208};   // MUL_K q1vy
            w.m[1] = {1'b1, 3'd1, 9'd231, 9'd68, 9'd209};   // MUL_K q2vy
          end
          6'd17: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd119, 9'd122, 9'd129};   // ADD_T Sb01CR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd120, 9'd123, 9'd131};   // ADD_T Sc01CR
            w.m[0] = {1'b1, 3'd0, 9'd19, 9'd52, 9'd137};   // MUL_T taCA0
            w.m[1] = {1'b1, 3'd0, 9'd19, 9'd53, 9'd138};   // MUL_T tbCA0
            w.m[2] = {1'b1, 3'd0, 9'd19, 9'd54, 9'd139};   // MUL_T tcCA0
            w.m[3] = {1'b1, 3'd0, 9'd20, 9'd57, 9'd140};   // MUL_T taCA1
            w.a[0] = {1'b1, 3'd3, 1'b0, 9'd208, 9'd209, 9'd210};   // ADD_N nvy
          end
          6'd18: begin
            w.m[3] = {1'b1, 3'd0, 9'd20, 9'd58, 9'd141};   // MUL_T tbCA1
            w.a[0] = {1'b1, 3'd0, 1'b0, 9'd137, 9'd140, 9'd146};   // ADD_T Sa01CA
            w.m[0] = {1'b1, 3'd2, 9'd198, 9'd195, 9'd199};   // MUL_Q nqux
            w.m[1] = {1'b1, 3'd2, 9'd202, 9'd195, 9'd203};   // MUL_Q nqvx
            w.m[2] = {1'b1, 3'd2, 9'd206, 9'd195, 9'd207};   // MUL_Q nquy
          end
          6'd19: begin
            w.m[2] = {1'b1, 3'd0, 9'd12, 9'd62, 9'd86};   // MUL_T taCB2
            w.m[3] = {1'b1, 3'd0, 9'd12, 9'd63, 9'd87};   // MUL_T tbCB2
            w.m[1] = {1'b1, 3'd0, 9'd20, 9'd59, 9'd142};   // MUL_T tcCA1
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd138, 9'd141, 9'd148};   // ADD_T Sb01CA
            w.m[0] = {1'b1, 3'd2, 9'd210, 9'd195, 9'd211};   // MUL_Q nqvy
            w.a[0] = {1'b1, 3'd4, 1'b0, 9'd199, 9'd203, 9'd212};   // ADD_LX lhix
            w.a[1] = {1'b1, 3'd5, 1'b0, 9'd199, 9'd203, 9'd213};   // ADD_LN llox
          end
          6'd20: begin
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd64, 9'd88};   // MUL_T tcCB2
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd89, 9'd86, 9'd90};   // ADD_T SaCB
            w.m[1] = {1'b1, 3'd0, 9'd15, 9'd62, 9'd105};   // MUL_T taCG2
            w.m[2] = {1'b1, 3'd0, 9'd15, 9'd63, 9'd106};   // MUL_T tbCG2
            w.m[3] = {1'b1, 3'd0, 9'd15, 9'd64, 9'd107};   // MUL_T tcCG2
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd139, 9'd142, 9'd150};   // ADD_T Sc01CA
            w.a[0] = {1'b1, 3'd4, 1'b0, 9'd207, 9'd211, 9'd217};   // ADD_LX lhiy
            w.a[1] = {1'b1, 3'd5, 1'b0, 9'd207, 9'd211, 9'd218};   // ADD_LN lloy
          end
          6'd21: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd91, 9'd87, 9'd92};   // ADD_T SbCB
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd93, 9'd88, 9'd94};   // ADD_T ScCB
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd108, 9'd105, 9'd109};   // ADD_T SaCG
            w.m[1] = {1'b1, 3'd0, 9'd18, 9'd62, 9'd124};   // MUL_T taCR2
            w.m[2] = {1'b1, 3'd0, 9'd18, 9'd63, 9'd125};   // MUL_T tbCR2
            w.m[3] = {1'b1, 3'd0, 9'd18, 9'd64, 9'd126};   // MUL_T tcCR2
            w.a[0] = {1'b1, 3'd7, 1'b0, 9'd212, 9'd213, 9'd214};   // ADD_P lsumx
            w.m[0] = {1'b1, 3'd5, 9'd213, 9'd28, 9'd215};   // MUL_P llessx
          end
          6'd22: begin
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd110, 9'd106, 9'd111};   // ADD_T SbCG
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd112, 9'd107, 9'd113};   // ADD_T ScCG
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd127, 9'd124, 9'd128};   // ADD_T SaCR
            w.m[1] = {1'b1, 3'd0, 9'd21, 9'd62, 9'd143};   // MUL_T taCA2
            w.m[2] = {1'b1, 3'd0, 9'd21, 9'd63, 9'd144};   // MUL_T tbCA2
            w.m[3] = {1'b1, 3'd0, 9'd21, 9'd64, 9'd145};   // MUL_T tcCA2
            w.a[0] = {1'b1, 3'd7, 1'b0, 9'd217, 9'd218, 9'd219};   // ADD_P lsumy
            w.m[0] = {1'b1, 3'd5, 9'd218, 9'd28, 9'd220};   // MUL_P llessy
          end
          6'd23: begin
            w.m[0] = {1'b1, 3'd0, 9'd75, 9'd9, 9'd76};   // MUL_T mean
            w.m[1] = {1'b1, 3'd0, 9'd66, 9'd73, 9'd77};   // MUL_T A0W
            w.m[2] = {1'b1, 3'd0, 9'd68, 9'd73, 9'd78};   // MUL_T B0W
            w.m[3] = {1'b1, 3'd0, 9'd70, 9'd73, 9'd79};   // MUL_T C0W
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd129, 9'd125, 9'd130};   // ADD_T SbCR
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd131, 9'd126, 9'd132};   // ADD_T ScCR
            w.a[3] = {1'b1, 3'd0, 1'b0, 9'd146, 9'd143, 9'd147};   // ADD_T SaCA
            w.a[0] = {1'b1, 3'd7, 1'b1, 9'd214, 9'd215, 9'd216};   // ADD_P lenx
          end
          6'd24: begin
            w.w = {1'b1, 2'd0, 4'd0, 9'd76, 9'd79, 9'd78, 9'd77};   // W_PL wW
            w.m[0] = {1'b1, 3'd0, 9'd24, 9'd76, 9'd171};   // MUL_T CfU
            w.m[1] = {1'b1, 3'd0, 9'd166, 9'd73, 9'd172};   // MUL_T A0U
            w.m[2] = {1'b1, 3'd0, 9'd168, 9'd73, 9'd173};   // MUL_T B0U
            w.m[3] = {1'b1, 3'd0, 9'd170, 9'd73, 9'd174};   // MUL_T C0U
            w.a[1] = {1'b1, 3'd0, 1'b0, 9'd148, 9'd144, 9'd149};   // ADD_T SbCA
            w.a[2] = {1'b1, 3'd0, 1'b0, 9'd150, 9'd145, 9'd151};   // ADD_T ScCA
            w.a[0] = {1'b1, 3'd7, 1'b1, 9'd219, 9'd220, 9'd221};   // ADD_P leny
          end
          6'd25: begin
            w.w = {1'b1, 2'd0, 4'd1, 9'd171, 9'd174, 9'd173, 9'd172};   // W_PL wU
            w.m[0] = {1'b1, 3'd0, 9'd27, 9'd76, 9'd190};   // MUL_T CfV
            w.m[1] = {1'b1, 3'd0, 9'd185, 9'd73, 9'd191};   // MUL_T A0V
            w.m[2] = {1'b1, 3'd0, 9'd187, 9'd73, 9'd192};   // MUL_T B0V
            w.m[3] = {1'b1, 3'd0, 9'd189, 9'd73, 9'd193};   // MUL_T C0V
          end
          6'd26: begin
            w.w = {1'b1, 2'd0, 4'd2, 9'd190, 9'd193, 9'd192, 9'd191};   // W_PL wV
            w.m[0] = {1'b1, 3'd0, 9'd12, 9'd76, 9'd95};   // MUL_T CfCB
            w.m[1] = {1'b1, 3'd0, 9'd90, 9'd73, 9'd96};   // MUL_T A0CB
            w.m[2] = {1'b1, 3'd0, 9'd92, 9'd73, 9'd97};   // MUL_T B0CB
            w.m[3] = {1'b1, 3'd0, 9'd94, 9'd73, 9'd98};   // MUL_T C0CB
            w.a[0] = {1'b1, 3'd6, 1'b0, 9'd216, 9'd221, 9'd222};   // ADD_BS best0
          end
          6'd27: begin
            w.w = {1'b1, 2'd0, 4'd3, 9'd95, 9'd98, 9'd97, 9'd96};   // W_PL wCB
            w.m[0] = {1'b1, 3'd0, 9'd15, 9'd76, 9'd114};   // MUL_T CfCG
            w.m[1] = {1'b1, 3'd0, 9'd109, 9'd73, 9'd115};   // MUL_T A0CG
            w.m[2] = {1'b1, 3'd0, 9'd111, 9'd73, 9'd116};   // MUL_T B0CG
            w.m[3] = {1'b1, 3'd0, 9'd113, 9'd73, 9'd117};   // MUL_T C0CG
          end
          6'd28: begin
            w.w = {1'b1, 2'd0, 4'd4, 9'd114, 9'd117, 9'd116, 9'd115};   // W_PL wCG
            w.m[0] = {1'b1, 3'd0, 9'd18, 9'd76, 9'd133};   // MUL_T CfCR
            w.m[1] = {1'b1, 3'd0, 9'd128, 9'd73, 9'd134};   // MUL_T A0CR
            w.m[2] = {1'b1, 3'd0, 9'd130, 9'd73, 9'd135};   // MUL_T B0CR
            w.m[3] = {1'b1, 3'd0, 9'd132, 9'd73, 9'd136};   // MUL_T C0CR
          end
          6'd29: begin
            w.w = {1'b1, 2'd0, 4'd5, 9'd133, 9'd136, 9'd135, 9'd134};   // W_PL wCR
            w.m[0] = {1'b1, 3'd0, 9'd21, 9'd76, 9'd152};   // MUL_T CfCA
            w.m[1] = {1'b1, 3'd0, 9'd147, 9'd73, 9'd153};   // MUL_T A0CA
            w.m[2] = {1'b1, 3'd0, 9'd149, 9'd73, 9'd154};   // MUL_T B0CA
            w.m[3] = {1'b1, 3'd0, 9'd151, 9'd73, 9'd155};   // MUL_T C0CA
          end
          6'd30: begin
            w.w = {1'b1, 2'd0, 4'd6, 9'd152, 9'd155, 9'd154, 9'd153};   // W_PL wCA
            w.m[0] = {1'b1, 3'd4, 9'd222, 9'd195, 9'd223};   // MUL_B best
          end
          6'd31: begin
            w.w = {1'b1, 2'd1, 4'd7, 9'd0, 9'd0, 9'd0, 9'd0};   // W_DR wOB
          end
          6'd32: begin
            w.w = {1'b1, 2'd1, 4'd8, 9'd0, 9'd0, 9'd0, 9'd0};   // W_DR wOG
          end
          6'd33: begin
            w.w = {1'b1, 2'd1, 4'd9, 9'd0, 9'd0, 9'd0, 9'd0};   // W_DR wOR
          end
          6'd34: begin
            w.w = {1'b1, 2'd1, 4'd10, 9'd0, 9'd0, 9'd0, 9'd0};   // W_DR wOA
          end
          6'd35: begin
            w.w = {1'b1, 2'd2, 4'd0, 9'd0, 9'd0, 9'd0, 9'd223};   // W_K wK
          end
          default: ;
        endcase
      end
      default: ;
    endcase
    return w;
  endfunction

endpackage

// p2_fp_cut_tb_top: make fp-cut (tb/fp/fp_cut_tb.cpp). H2 at the HW widths (num H2, 5.5): 24-bit inputs cut to 8, 16,
// 19, 20, 24 bits; the wide adds' 62-bit values to 24 and 16; 64-bit values to 62 (the wide adds' second truncation)
// and 24. Every instance takes the low bits of i_mant. Outputs registered (latency 1, tb/fp/fp_tb.h).
module p2_fp_cut_tb_top
  import p2_fp_pkg::*;
(
  input  logic                       clk,
  input  logic                       in_v,
  input  logic                       i_neg,
  input  logic                       i_bad,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [63:0]                i_mant,
  output logic                       out_v,
  output logic                       c24_8_neg,  c24_8_bad,  c24_16_neg, c24_16_bad, c24_19_neg, c24_19_bad,
  output logic                       c24_20_neg, c24_20_bad, c24_24_neg, c24_24_bad, c62_24_neg, c62_24_bad,
  output logic                       c62_16_neg, c62_16_bad, c64_62_neg, c64_62_bad, c64_24_neg, c64_24_bad,
  output logic signed [P2_FP_EW-1:0] c24_8_exp,  c24_16_exp, c24_19_exp, c24_20_exp, c24_24_exp,
  output logic signed [P2_FP_EW-1:0] c62_24_exp, c62_16_exp, c64_62_exp, c64_24_exp,
  output logic [7:0]                 c24_8_mant,
  output logic [15:0]                c24_16_mant,
  output logic [18:0]                c24_19_mant,
  output logic [19:0]                c24_20_mant,
  output logic [23:0]                c24_24_mant,
  output logic [23:0]                c62_24_mant,
  output logic [15:0]                c62_16_mant,
  output logic [61:0]                c64_62_mant,
  output logic [23:0]                c64_24_mant
);
  p2_hw_check u_hw_check ();

  // one instance: its tuple, combinational
  `define P2_CUT_TB(NAME, IWV, NV) \
    logic NAME``_n, NAME``_b; \
    logic signed [P2_FP_EW-1:0] NAME``_e; \
    logic [NV-1:0] NAME``_m; \
    p2_fp_cut #(.IW(IWV), .N(NV)) u_``NAME ( \
      .i_neg(i_neg), .i_bad(i_bad), .i_exp(i_exp), .i_mant(i_mant[IWV-1:0]), \
      .o_neg(NAME``_n), .o_bad(NAME``_b), .o_exp(NAME``_e), .o_mant(NAME``_m)); \
    always_ff @(posedge clk) begin \
      NAME``_neg <= NAME``_n; NAME``_bad <= NAME``_b; NAME``_exp <= NAME``_e; NAME``_mant <= NAME``_m; \
    end

  `P2_CUT_TB(c24_8, 24, 8)
  `P2_CUT_TB(c24_16, 24, 16)
  `P2_CUT_TB(c24_19, 24, 19)
  `P2_CUT_TB(c24_20, 24, 20)
  `P2_CUT_TB(c24_24, 24, 24)
  `P2_CUT_TB(c62_24, 62, 24)
  `P2_CUT_TB(c62_16, 62, 16)
  `P2_CUT_TB(c64_62, 64, 62)
  `P2_CUT_TB(c64_24, 64, 24)
  `undef P2_CUT_TB

  always_ff @(posedge clk) out_v <= in_v;
endmodule

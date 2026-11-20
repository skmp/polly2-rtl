// p2_fp_mul_tb_top: make fp-mul (tb/fp/fp_mul_tb.cpp). H5 at every instance shape of num H5 / 5.5 and one small one
// for the exhaustive structure check: 24x24->24 (setup), 24x24->48 (exact: mip numerator class), 10x10->10, 8x8->8 and
// 24x5->8 (mip), 16x13->29 (exact: TSP run start), 8x16->24 (exact: fog). Each instance takes the low bits of a_mant
// and b_mant. Outputs registered (latency 1, tb/fp/fp_tb.h).
module p2_fp_mul_tb_top
  import p2_fp_pkg::*;
(
  input  logic                       clk,
  input  logic                       in_v,
  input  logic                       a_neg,
  input  logic                       a_bad,
  input  logic signed [P2_FP_EW-1:0] a_exp,
  input  logic [23:0]                a_mant,
  input  logic                       b_neg,
  input  logic                       b_bad,
  input  logic signed [P2_FP_EW-1:0] b_exp,
  input  logic [23:0]                b_mant,
  output logic                       out_v,
  output logic                       m24_neg, m24_bad, m48_neg, m48_bad, m10_neg, m10_bad, m8_neg, m8_bad,
  output logic                       m24x5_neg, m24x5_bad, m16x13_neg, m16x13_bad, m8x16_neg, m8x16_bad,
  output logic signed [P2_FP_EW-1:0] m24_exp, m48_exp, m10_exp, m8_exp, m24x5_exp, m16x13_exp, m8x16_exp,
  output logic [23:0]                m24_mant,
  output logic [47:0]                m48_mant,
  output logic [9:0]                 m10_mant,
  output logic [7:0]                 m8_mant,
  output logic [7:0]                 m24x5_mant,
  output logic [28:0]                m16x13_mant,
  output logic [23:0]                m8x16_mant
);
  p2_hw_check u_hw_check ();

  `define P2_MUL_TB(NAME, AWV, BWV, NV) \
    logic NAME``_n, NAME``_b; \
    logic signed [P2_FP_EW-1:0] NAME``_e; \
    logic [NV-1:0] NAME``_m; \
    p2_fp_mul #(.AW(AWV), .BW(BWV), .N(NV)) u_``NAME ( \
      .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant[AWV-1:0]), \
      .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant[BWV-1:0]), \
      .o_neg(NAME``_n), .o_bad(NAME``_b), .o_exp(NAME``_e), .o_mant(NAME``_m)); \
    always_ff @(posedge clk) begin \
      NAME``_neg <= NAME``_n; NAME``_bad <= NAME``_b; NAME``_exp <= NAME``_e; NAME``_mant <= NAME``_m; \
    end

  `P2_MUL_TB(m24, 24, 24, 24)
  `P2_MUL_TB(m48, 24, 24, 48)
  `P2_MUL_TB(m10, 10, 10, 10)
  `P2_MUL_TB(m8, 8, 8, 8)
  `P2_MUL_TB(m24x5, 24, 5, 8)
  `P2_MUL_TB(m16x13, 16, 13, 29)
  `P2_MUL_TB(m8x16, 8, 16, 24)
  `undef P2_MUL_TB

  always_ff @(posedge clk) out_v <= in_v;
endmodule

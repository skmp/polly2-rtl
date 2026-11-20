// p2_fp_add_tb_top: make fp-add (tb/fp/fp_add_tb.cpp). H6 at the HW shapes, 24/25 (every setup adder) and 24/53
// (MipSelect's DCalcCtrl-1 sums, GAP G1), and at 8 bits with reaches 9, 12 and 53 for the exhaustive structure check
// (num 7.3: the reference is generic, so the parameterized RTL is proven at small widths and sampled at full width).
// The 8-bit instances take the low bits of the mantissas. Outputs registered (latency 1, tb/fp/fp_tb.h).
module p2_fp_add_tb_top
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
  output logic                       a25_neg, a25_bad, a53_neg, a53_bad, s9_neg, s9_bad, s12_neg, s12_bad,
  output logic                       s53_neg, s53_bad,
  output logic signed [P2_FP_EW-1:0] a25_exp, a53_exp, s9_exp, s12_exp, s53_exp,
  output logic [23:0]                a25_mant,
  output logic [23:0]                a53_mant,
  output logic [7:0]                 s9_mant,
  output logic [7:0]                 s12_mant,
  output logic [7:0]                 s53_mant
);
  p2_hw_check u_hw_check ();

  `define P2_ADD_TB(NAME, WV, RV) \
    logic NAME``_n, NAME``_b; \
    logic signed [P2_FP_EW-1:0] NAME``_e; \
    logic [WV-1:0] NAME``_m; \
    p2_fp_add #(.W(WV), .R(RV)) u_``NAME ( \
      .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant[WV-1:0]), \
      .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant[WV-1:0]), \
      .o_neg(NAME``_n), .o_bad(NAME``_b), .o_exp(NAME``_e), .o_mant(NAME``_m)); \
    always_ff @(posedge clk) begin \
      NAME``_neg <= NAME``_n; NAME``_bad <= NAME``_b; NAME``_exp <= NAME``_e; NAME``_mant <= NAME``_m; \
    end

  `P2_ADD_TB(a25, 24, 25)
  `P2_ADD_TB(a53, 24, 53)
  `P2_ADD_TB(s9, 8, 9)
  `P2_ADD_TB(s12, 8, 12)
  `P2_ADD_TB(s53, 8, 53)
  `undef P2_ADD_TB

  always_ff @(posedge clk) out_v <= in_v;
endmodule

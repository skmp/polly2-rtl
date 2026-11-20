// p2_fp_cutbelow_tb_top: make fp-cutbelow (tb/fp/fp_cutbelow_tb.cpp). H3 at 24 bits (the edge steps, the depth start
// and steps before their 20-bit cut) and 20 bits (after it), num H3, 5.5. The 20-bit instance takes the low bits of
// i_mant. Outputs registered (latency 1, tb/fp/fp_tb.h).
module p2_fp_cutbelow_tb_top
  import p2_fp_pkg::*;
(
  input  logic                       clk,
  input  logic                       in_v,
  input  logic                       i_neg,
  input  logic                       i_bad,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [23:0]                i_mant,
  input  logic signed [P2_FP_EW-1:0] e,
  output logic                       out_v,
  output logic                       b24_neg,
  output logic                       b24_bad,
  output logic signed [P2_FP_EW-1:0] b24_exp,
  output logic [23:0]                b24_mant,
  output logic                       b20_neg,
  output logic                       b20_bad,
  output logic signed [P2_FP_EW-1:0] b20_exp,
  output logic [19:0]                b20_mant
);
  p2_hw_check u_hw_check ();

  logic                       n24, f24, n20, f20;
  logic signed [P2_FP_EW-1:0] e24, e20;
  logic [23:0]                m24;
  logic [19:0]                m20;

  p2_fp_cut_below #(.MW(24)) u24 (
    .i_neg(i_neg), .i_bad(i_bad), .i_exp(i_exp), .i_mant(i_mant), .e(e),
    .o_neg(n24), .o_bad(f24), .o_exp(e24), .o_mant(m24));
  p2_fp_cut_below #(.MW(20)) u20 (
    .i_neg(i_neg), .i_bad(i_bad), .i_exp(i_exp), .i_mant(i_mant[19:0]), .e(e),
    .o_neg(n20), .o_bad(f20), .o_exp(e20), .o_mant(m20));

  always_ff @(posedge clk) begin
    out_v    <= in_v;
    b24_neg  <= n24;
    b24_bad  <= f24;
    b24_exp  <= e24;
    b24_mant <= m24;
    b20_neg  <= n20;
    b20_bad  <= f20;
    b20_exp  <= e20;
    b20_mant <= m20;
  end
endmodule

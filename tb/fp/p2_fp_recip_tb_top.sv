// p2_fp_recip_tb_top: make fp-recip (tb/fp/fp_recip_tb.cpp). H8 p2_fp_recip24 (num H8, 2.9). Output registered
// (latency 1, tb/fp/fp_tb.h).
module p2_fp_recip_tb_top
  import p2_fp_pkg::*;
(
  input  logic                       clk,
  input  logic                       in_v,
  input  logic                       i_neg,
  input  logic                       i_bad,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [23:0]                i_mant,
  output logic                       out_v,
  output logic                       r_neg,
  output logic                       r_bad,
  output logic signed [P2_FP_EW-1:0] r_exp,
  output logic [23:0]                r_mant
);
  p2_hw_check u_hw_check ();

  logic                       n, b;
  logic signed [P2_FP_EW-1:0] e;
  logic [23:0]                m;

  p2_fp_recip24 u_recip (
    .i_neg(i_neg), .i_bad(i_bad), .i_exp(i_exp), .i_mant(i_mant), .o_neg(n), .o_bad(b), .o_exp(e), .o_mant(m));

  always_ff @(posedge clk) begin
    out_v  <= in_v;
    r_neg  <= n;
    r_bad  <= b;
    r_exp  <= e;
    r_mant <= m;
  end
endmodule

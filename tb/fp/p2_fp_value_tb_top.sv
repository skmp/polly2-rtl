// p2_fp_value_tb_top: make fp-value (tb/fp/fp_value_tb.cpp). H12a p2_fp_value_norm at the TSP's widths (a 27-bit k).
// Outputs registered (latency 1, tb/fp/fp_tb.h).
module p2_fp_value_tb_top
  import p2_fp_pkg::*;
(
  input  logic                       clk,
  input  logic                       in_v,
  input  logic signed [26:0]         k,
  input  logic signed [P2_FP_EW-1:0] unit,
  output logic                       out_v,
  output logic                       v_neg,
  output logic                       v_bad,
  output logic signed [P2_FP_EW-1:0] v_exp,
  output logic [16:0]                v_mant
);
  p2_hw_check u_hw_check ();

  logic                       n;
  logic signed [P2_FP_EW-1:0] e;
  logic [16:0]                m;

  p2_fp_value_norm #(.KW(27)) u_dut (.k(k), .unit(unit), .o_neg(n), .o_exp(e), .o_mant(m));

  always_ff @(posedge clk) begin
    out_v  <= in_v;
    v_neg  <= n;
    v_bad  <= 1'b0;          // the plane value is never flagged (PlaneT::Value)
    v_exp  <= e;
    v_mant <= m;
  end
endmodule

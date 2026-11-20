// p2_fp_halfline_tb_top: make fp-halfline (tb/fp/fp_halfline_tb.cpp). H7b p2_fp_half_line at the TSP's widths (16-bit
// coefficients, a 27-bit k): c and b are the evaluator's seen(C), seen(B). Outputs registered (latency 1, tb/fp/fp_tb.h).
module p2_fp_halfline_tb_top
  import p2_fp_pkg::*;
(
  input  logic                       clk,
  input  logic                       in_v,
  input  logic                       c_neg,
  input  logic                       c_bad,
  input  logic signed [P2_FP_EW-1:0] c_exp,
  input  logic [15:0]                c_mant,
  input  logic                       b_neg,
  input  logic                       b_bad,
  input  logic signed [P2_FP_EW-1:0] b_exp,
  input  logic [15:0]                b_mant,
  input  logic signed [P2_FP_EW-1:0] unit,
  output logic                       out_v,
  output logic signed [26:0]         dk
);
  p2_hw_check u_hw_check ();

  logic signed [26:0] d;

  // seen() never gives a bad value (c_bad, b_bad are the tuples' flags, always 0 here)
  p2_fp_half_line #(.MW(16), .KW(27)) u_dut (
    .c_neg(c_neg), .c_exp(c_exp), .c_mant(c_mant), .b_neg(b_neg), .b_exp(b_exp), .b_mant(b_mant), .unit(unit),
    .dk(d));

  always_ff @(posedge clk) begin
    out_v <= in_v;
    dk    <= d;
  end
endmodule

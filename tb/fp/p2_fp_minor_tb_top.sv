// p2_fp_minor_tb_top: make fp-minor (tb/fp/fp_minor_tb.cpp). H7c p2_fp_mip_minor at 24 bits (MipSelect's widths) and
// at 8 bits (the exhaustive structure check; it takes the low 8 bits of the mantissas). Outputs registered (latency 1,
// tb/fp/fp_tb.h).
module p2_fp_minor_tb_top
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
  output logic                       n24_neg,
  output logic                       n24_bad,
  output logic signed [P2_FP_EW-1:0] n24_exp,
  output logic [23:0]                n24_mant,
  output logic                       n8_neg,
  output logic                       n8_bad,
  output logic signed [P2_FP_EW-1:0] n8_exp,
  output logic [7:0]                 n8_mant
);
  p2_hw_check u_hw_check ();

  logic                       n24, f24, n8, f8;
  logic signed [P2_FP_EW-1:0] e24, e8;
  logic [23:0]                m24;
  logic [7:0]                 m8;

  p2_fp_mip_minor #(.W(24)) u24 (
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant),
    .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant),
    .o_neg(n24), .o_bad(f24), .o_exp(e24), .o_mant(m24));
  p2_fp_mip_minor #(.W(8)) u8 (
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant[7:0]),
    .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant[7:0]),
    .o_neg(n8), .o_bad(f8), .o_exp(e8), .o_mant(m8));

  always_ff @(posedge clk) begin
    out_v    <= in_v;
    n24_neg  <= n24;
    n24_bad  <= f24;
    n24_exp  <= e24;
    n24_mant <= m24;
    n8_neg   <= n8;
    n8_bad   <= f8;
    n8_exp   <= e8;
    n8_mant  <= m8;
  end
endmodule

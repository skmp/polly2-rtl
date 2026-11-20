// p2_fp_cmp_tb_top: make fp-cmp (tb/fp/fp_cmp_tb.cpp). H9 (num H9, 2.6, 2.11, 2.12): |a| <= |b|, a <= b,
// |a| >= 2^e, Perpendicular(a) against FPU_PERP_VAL = reg, CulledBySize(a) against FPU_CULL_VAL = reg and
// CulledByFacing(mode, a). Outputs registered (latency 1, tb/fp/fp_tb.h).
module p2_fp_cmp_tb_top
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
  input  logic signed [P2_FP_EW-1:0] e,
  input  logic [31:0]                reg_v,
  input  logic [1:0]                 mode,
  output logic                       out_v,
  output logic                       abs_le,
  output logic                       le,
  output logic                       ge,
  output logic                       perp,
  output logic                       by_size,
  output logic                       by_facing
);
  p2_hw_check u_hw_check ();

  logic d_abs_le, d_le, d_ge, d_perp, d_size, d_facing;

  p2_fp_abs_le #(.MW(24)) u_abs_le (
    .a_exp(a_exp), .a_mant(a_mant), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant), .le(d_abs_le));
  p2_fp_le #(.MW(24)) u_le (
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant),
    .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant), .le(d_le));
  p2_fp_at_least_pow2 #(.MW(24)) u_ge (.i_exp(a_exp), .i_mant(a_mant), .e(e), .ge(d_ge));
  p2_fp_perp u_perp (.det_bad(a_bad), .det_exp(a_exp), .det_mant(a_mant), .fpu_perp_val(reg_v), .perp(d_perp));
  p2_fp_cull u_cull (
    .det_neg(a_neg), .det_bad(a_bad), .det_exp(a_exp), .det_mant(a_mant), .fpu_cull_val(reg_v), .cull_mode(mode),
    .by_size(d_size), .by_facing(d_facing));

  always_ff @(posedge clk) begin
    out_v     <= in_v;
    abs_le    <= d_abs_le;
    le        <= d_le;
    ge        <= d_ge;
    perp      <= d_perp;
    by_size   <= d_size;
    by_facing <= d_facing;
  end
endmodule

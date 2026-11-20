// p2_fp_range_tb_top: make fp-range (tb/fp/fp_range_tb.cpp). H10, the range wrappers of every flavour (num H10, 4):
// p2_fp_rng_lim (lim_mode), p2_fp_rng_mul (mul_ranged), p2_fp_rng_add at 24/25 (add_mode: edge, depth, TSP, TSP third)
// and at 24/53 (MipSelect's radd: TSP), p2_fp_rng_add_inf (the depth mean), p2_fp_rng_kind (mip), p2_fp_rng_recip
// (recip_mip: TSP, mip), p2_fp_rng_with_zero (the TSP flat mean). Every vector drives all of them. Outputs registered
// (latency 1, tb/fp/fp_tb.h).
module p2_fp_range_tb_top
  import p2_fp_pkg::*;
(
  input  logic                       clk,
  input  logic                       in_v,
  input  logic                       a_neg,
  input  logic                       a_bad,
  input  logic signed [P2_FP_EW-1:0] a_exp,
  input  logic [23:0]                a_mant,
  input  logic [22:0]                a_frac,
  input  logic                       b_neg,
  input  logic                       b_bad,
  input  logic signed [P2_FP_EW-1:0] b_exp,
  input  logic [23:0]                b_mant,
  input  logic [22:0]                b_frac,
  input  logic [31:0]                zbits,
  input  logic [1:0]                 lim_mode,
  input  logic                       mul_ranged,
  input  logic [1:0]                 add_mode,
  input  logic                       recip_mip,
  output logic                       out_v,
  output logic                       lim_neg, lim_bad, mul_neg, mul_bad, add_neg, add_bad, a53_neg, a53_bad,
  output logic                       ainf_neg, ainf_bad, kp_neg, kp_bad, rcp_neg, rcp_bad, wz_neg, wz_bad,
  output logic signed [P2_FP_EW-1:0] lim_exp, mul_exp, add_exp, a53_exp, ainf_exp, kp_exp, rcp_exp, wz_exp,
  output logic [23:0]                lim_mant, mul_mant, add_mant, a53_mant, ainf_mant, kp_mant, rcp_mant, wz_mant,
  output logic [1:0]                 kind
);
  p2_hw_check u_hw_check ();

  // the combinational results, then the register
  `define P2_RNG_TB_DECL(NAME) \
    logic NAME``_n, NAME``_b; \
    logic signed [P2_FP_EW-1:0] NAME``_e; \
    logic [23:0] NAME``_m; \
    always_ff @(posedge clk) begin \
      NAME``_neg <= NAME``_n; NAME``_bad <= NAME``_b; NAME``_exp <= NAME``_e; NAME``_mant <= NAME``_m; \
    end

  `P2_RNG_TB_DECL(lim)
  `P2_RNG_TB_DECL(mul)
  `P2_RNG_TB_DECL(add)
  `P2_RNG_TB_DECL(a53)
  `P2_RNG_TB_DECL(ainf)
  `P2_RNG_TB_DECL(kp)
  `P2_RNG_TB_DECL(rcp)
  `P2_RNG_TB_DECL(wz)
  `undef P2_RNG_TB_DECL

  logic [1:0] d_kind;

  p2_fp_rng_lim #(.MW(24)) u_lim (
    .mode(lim_mode), .i_neg(a_neg), .i_bad(a_bad), .i_exp(a_exp), .i_mant(a_mant),
    .o_neg(lim_n), .o_bad(lim_b), .o_exp(lim_e), .o_mant(lim_m));
  p2_fp_rng_mul #(.W(24)) u_mul (
    .ranged(mul_ranged),
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant),
    .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant),
    .o_neg(mul_n), .o_bad(mul_b), .o_exp(mul_e), .o_mant(mul_m));
  p2_fp_rng_add #(.W(24), .R(25)) u_add (
    .mode(add_mode),
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant),
    .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant),
    .o_neg(add_n), .o_bad(add_b), .o_exp(add_e), .o_mant(add_m));
  p2_fp_rng_add #(.W(24), .R(53)) u_add53 (
    .mode(add_mode),
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant),
    .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant),
    .o_neg(a53_n), .o_bad(a53_b), .o_exp(a53_e), .o_mant(a53_m));
  p2_fp_rng_add_inf #(.W(24), .R(25)) u_ainf (
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant), .a_frac(a_frac),
    .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant), .b_frac(b_frac),
    .o_neg(ainf_n), .o_bad(ainf_b), .o_exp(ainf_e), .o_mant(ainf_m));
  p2_fp_rng_kind #(.W(24)) u_kind (
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant),
    .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant),
    .kind(d_kind), .o_neg(kp_n), .o_bad(kp_b), .o_exp(kp_e), .o_mant(kp_m));
  p2_fp_rng_recip u_rcp (
    .mip(recip_mip), .i_neg(a_neg), .i_bad(a_bad), .i_exp(a_exp), .i_mant(a_mant),
    .o_neg(rcp_n), .o_bad(rcp_b), .o_exp(rcp_e), .o_mant(rcp_m));
  p2_fp_rng_with_zero u_wz (
    .i_neg(a_neg), .i_bad(a_bad), .i_exp(a_exp), .i_mant(a_mant), .zbits(zbits),
    .o_neg(wz_n), .o_bad(wz_b), .o_exp(wz_e), .o_mant(wz_m));

  always_ff @(posedge clk) begin
    out_v <= in_v;
    kind  <= d_kind;
  end
endmodule

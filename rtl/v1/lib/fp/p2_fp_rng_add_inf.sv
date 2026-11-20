// p2_fp_rng_add_inf: H10, the depth setup's addition of the determinant-zero mean, `addBad` (docs/spec/numerics.md
// H10, 4.2 addInf; refcore pvr_isp_depth.h DepthTileT::Setup L571-575 at 708fb8cd).
//
//   a, b both bad, of opposite signs, with different raw fractions:  the infinity of the larger fraction's sign
//   otherwise:                                                        the depth `add` (p2_fp_rng_add, DEPTH)
//
// a_frac / b_frac: the corner's raw fraction u[22:0] when its exponent field is 255, else 0 (a sum: 0). A corner of
// field 255 adds as an infinity of its sign, two of opposite signs as their fractions say, equal ones +0
// (depthgaps_dzinf 48 of 48 regions; with the fraction not counting 29). Combinational.
module p2_fp_rng_add_inf
  import p2_fp_pkg::*;
#(
  parameter int W = 24,
  parameter int R = 25
) (
  input  logic                       a_neg,
  input  logic                       a_bad,
  input  logic signed [P2_FP_EW-1:0] a_exp,
  input  logic [W-1:0]               a_mant,
  input  logic [22:0]                a_frac,
  input  logic                       b_neg,
  input  logic                       b_bad,
  input  logic signed [P2_FP_EW-1:0] b_exp,
  input  logic [W-1:0]               b_mant,
  input  logic [22:0]                b_frac,
  output logic                       o_neg,
  output logic                       o_bad,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [W-1:0]               o_mant
);
  logic                       s_neg, s_bad, fracs;
  logic signed [P2_FP_EW-1:0] s_exp;
  logic [W-1:0]               s_mant;

  p2_fp_rng_add #(.W(W), .R(R)) u_add (
    .mode(P2_RNG_ADD_DEPTH),
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant),
    .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant),
    .o_neg(s_neg), .o_bad(s_bad), .o_exp(s_exp), .o_mant(s_mant));

  assign fracs = a_bad && b_bad && (a_neg != b_neg) && (a_frac != b_frac);

  assign o_neg  = fracs ? ((a_frac > b_frac) ? a_neg : b_neg) : s_neg;
  assign o_bad  = fracs ? 1'b1 : s_bad;
  assign o_exp  = fracs ? '0 : s_exp;
  assign o_mant = fracs ? '0 : s_mant;
endmodule

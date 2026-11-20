// p2_fp_cut_below: H3, drop the mantissa bits under the grid 2^e, toward zero (docs/spec/numerics.md H3, 2.4; refcore
// pvr_softfp.h Fp::cutBelow).
//
//   mant != 0 and exp < e:  s = e - exp;  mant = s >= 64 ? 0 : mant >> s;  exp = e
//
// The sign is kept: a negative value cut to nothing is -0 (num 1.2). Sites: the edge steps onto `unit` and the walk's
// `fine` (pvr_isp_edge.h EdgeTile::Setup L237-238, L273-274), the depth start and steps onto `pair - 21` and `unit`, the
// REG steps onto 2^102 (pvr_isp_depth.h L436, L618, L624). Inputs are at most 24 bits (MW <= 64, so the reference's
// `s >= 64` and an MW-bit shift agree). Combinational.
module p2_fp_cut_below
  import p2_fp_pkg::*;
#(
  parameter int MW = 24
) (
  input  logic                       i_neg,
  input  logic                       i_bad,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [MW-1:0]              i_mant,
  input  logic signed [P2_FP_EW-1:0] e,          // the grid: everything below 2^e goes
  output logic                       o_neg,
  output logic                       o_bad,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [MW-1:0]              o_mant
);
  logic signed [P2_FP_XW-1:0] s;     // e - exp: the bits under the grid
  logic                       act;   // a nonzero mantissa with bits under the grid

  assign s      = p2_fp_xw(e) - p2_fp_xw(i_exp);
  assign act    = (i_mant != '0) && (i_exp < e);
  assign o_neg  = i_neg;
  assign o_bad  = i_bad;
  assign o_exp  = act ? e : i_exp;
  assign o_mant = !act ? i_mant : (s >= P2_FP_XW'(MW)) ? '0 : i_mant >> s;
endmodule

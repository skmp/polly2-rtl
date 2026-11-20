// p2_fp_div: H13 tsp_div, one whole TSP division num / den (docs/spec/numerics.md H13 `divide`; docs/spec/tsp.md 6;
// refcore pvr_tsp_plane.h Divide; dreamcast-tests pvr-tests/uvmeas recipscan, reciprow, reciprown, wneg, wzero2;
// texfar_m1, texfar_m1q; hugepos c): p2_fp_div_den (the reciprocal of den) and p2_fp_div_quot (num times it). The pixel
// pipe shares one p2_fp_div_den among its quotients (ARCHITECTURE 3.7.7 P2); this is the one-quotient form, for a
// site with one, and the form the lockstep testbench compares with Divide. Operands are plane values (p2_pval_t:
// neg, a mantissa of up to 17 bits, exp; never flagged). Combinational.
module p2_fp_div
  import p2_pkg::*;
  import p2_fp_pkg::*;
#(
  parameter int MW = 17
) (
  input  logic                         n_neg,
  input  logic signed [P2_FP_EW-1:0]   n_exp,
  input  logic [MW-1:0]                n_mant,
  input  logic                         d_neg,
  input  logic signed [P2_FP_EW-1:0]   d_exp,
  input  logic [MW-1:0]                d_mant,
  output logic                         o_neg,
  output logic signed [P2_FP_EW-1:0]   o_exp,
  output logic [P2_QUOT_MANT_BITS-1:0] o_mant
);
  logic [15:0]                r;
  logic signed [P2_FP_XW-1:0] ed;

  p2_fp_div_den #(.MW(MW)) u_den (.d_neg(d_neg), .d_exp(d_exp), .d_mant(d_mant), .r(r), .ed(ed));
  p2_fp_div_quot #(.MW(MW)) u_quot (
    .n_neg(n_neg), .n_exp(n_exp), .n_mant(n_mant), .r(r), .ed(ed), .o_neg(o_neg), .o_exp(o_exp), .o_mant(o_mant));
endmodule

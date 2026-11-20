// p2_isp_fsw: the edge unit's swamp (SAT 0) or saturation (SAT 1) at 2^overflowExp on a p2_fp24_t (num H7a; refcore
// pvr_isp_edge.h the `swamp` lambdas of EdgeWinding and EdgeTile::Setup, and the saturations of dx, dy and the start).
// A p2_fp_swamp with packed ports. Combinational.
module p2_isp_fsw
  import p2_pkg::*;
#(
  parameter bit SAT = 1'b0
) (
  input  p2_fp24_t i,
  output p2_fp24_t o
);
  p2_fp_swamp #(.MW(P2_FP24_MANT_BITS), .SAT(SAT)) u_sw (
    .i_neg(i.neg), .i_bad(i.bad), .i_exp(i.exp), .i_mant(i.mant),
    .o_neg(o.neg), .o_bad(o.bad), .o_exp(o.exp), .o_mant(o.mant));
endmodule

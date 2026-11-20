// p2_isp_fmul: the edge unit's product, Mul(a, b, EdgeHW::productBits) on p2_fp24_t tuples (num H5; refcore
// pvr_softfp.h Mul). A p2_fp_mul 24 x 24 -> 24 with packed ports, for the edge setup's datapath (PLAN M2). Combinational.
module p2_isp_fmul
  import p2_hw_pkg::*;
  import p2_pkg::*;
(
  input  p2_fp24_t a,
  input  p2_fp24_t b,
  output p2_fp24_t o
);
  p2_fp_mul #(.AW(P2_FP24_MANT_BITS), .BW(P2_FP24_MANT_BITS), .N(P2_ISP_EDGE_PRODUCT_BITS)) u_mul (
    .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
    .b_neg(b.neg), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
    .o_neg(o.neg), .o_bad(o.bad), .o_exp(o.exp), .o_mant(o.mant));
endmodule

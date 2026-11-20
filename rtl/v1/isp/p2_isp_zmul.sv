// p2_isp_zmul: the depth setup's product (refcore pvr_isp_depth.h DepthTileT::Setup `mul` L362-368 at refsw3 4f3efe15;
// num H10 depth flavour, ARCHITECTURE 3.4.4 step 6) on p2_fp24_t tuples: a p2_fp_rng_mul 24 x 24 -> 24 with packed
// ports. RANGED = 1: `mul` (an infinity times a zero is a zero, else an infinity, the product's sign either way;
// Mul(p, q, DepthHW::productBits), then 2^128 or more an infinity and below 2^-126 a zero of its sign: zovf_ps,
// depthgaps_nanprod, zspec). RANGED = 0: the plain Mul(p, q, DepthHW::coefBits) of the slopes A = a inv, B = b inv and
// the register steps (depth.h L513, L659-660; isp 6.3 "Unranged"). Combinational.
module p2_isp_zmul
  import p2_hw_pkg::*;
  import p2_pkg::*;
#(
  parameter bit RANGED = 1'b1
) (
  input  p2_fp24_t a,
  input  p2_fp24_t b,
  output p2_fp24_t o
);
  p2_fp_rng_mul #(.W(P2_ISP_DEPTH_PRODUCT_BITS)) u_mul (
    .ranged(RANGED),
    .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
    .b_neg(b.neg), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
    .o_neg(o.neg), .o_bad(o.bad), .o_exp(o.exp), .o_mant(o.mant));
endmodule

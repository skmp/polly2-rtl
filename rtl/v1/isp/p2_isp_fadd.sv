// p2_isp_fadd: the edge unit's sum, Add(a, b, EdgeHW::sumBits, EdgeHW::reach) with guard -1, or Sub(a, b) = Add(a, -b)
// when sub (num H6; refcore pvr_softfp.h Add, Sub). No range and no zero rule: the edge unit's adds are plain at refsw3
// 4f3efe15 (isp 6.2; the zero rule of 0de9776b is the depth setup's own). A p2_fp_add 24/25 with packed ports.
// Combinational.
module p2_isp_fadd
  import p2_hw_pkg::*;
  import p2_pkg::*;
(
  input  p2_fp24_t a,
  input  p2_fp24_t b,
  input  logic     sub,
  output p2_fp24_t o
);
  p2_fp_add #(.W(P2_ISP_EDGE_SUM_BITS), .R(P2_ISP_EDGE_REACH)) u_add (
    .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
    .b_neg(b.neg ^ sub), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
    .o_neg(o.neg), .o_bad(o.bad), .o_exp(o.exp), .o_mant(o.mant));
endmodule

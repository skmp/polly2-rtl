// p2_isp_edge_cross: sw(Sub(sw(Mul(a1, b1)), sw(Mul(a2, b2)))), the swamped cross term of the edge unit: EdgeWinding's
// e(j, k) = x_j y_k - x_k y_j (a1 = x_j, b1 = y_k, a2 = x_k, b2 = y_j) and EdgeTile::Setup's c = xb ya - xa yb
// (refcore pvr_isp_edge.h L117-118, L184-185 at 4f3efe15; isp 7.1, 8.3). Every product and the difference that reach
// 2^128 swamp the rest (H7a): dreamcast-tests pvr-tests/faredge_cmax (4,800 of 4,800 tiles: the product that counts,
// two of one sign cancelling), faredge_m131 and faredge_cull (the determinant). SW = 0 is plain Winding's cross term
// (no swamp; edge.h L86-92), whose only use is the bad flag (not built: p2_isp_edge_det). Combinational.
module p2_isp_edge_cross
  import p2_pkg::*;
#(
  parameter bit SW = 1'b1
) (
  input  p2_fp24_t a1,
  input  p2_fp24_t b1,
  input  p2_fp24_t a2,
  input  p2_fp24_t b2,
  output p2_fp24_t o
);
  p2_fp24_t p1, p2, q1, q2, d;
  p2_isp_fmul u_m1 (.a(a1), .b(b1), .o(p1));
  p2_isp_fmul u_m2 (.a(a2), .b(b2), .o(p2));
  p2_fp24_t r1, r2, od;
  p2_isp_fsw #(.SAT(1'b0)) u_s1 (.i(p1), .o(r1));
  p2_isp_fsw #(.SAT(1'b0)) u_s2 (.i(p2), .o(r2));
  assign q1 = SW ? r1 : p1;
  assign q2 = SW ? r2 : p2;
  p2_isp_fadd u_sub (.a(q1), .b(q2), .sub(1'b1), .o(d));
  p2_isp_fsw #(.SAT(1'b0)) u_sd (.i(d), .o(od));
  assign o = SW ? od : d;
endmodule

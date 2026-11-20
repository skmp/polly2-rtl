// p2_isp_edge_det: per primitive, the bad corners, the swamped determinant, the winding and the culls (isp 7.1, 7.2;
// ARCHITECTURE 3.4.4 steps 1-3; refcore refsw_tile.cpp RasterizeTriangle L775-792 and TriangleCulled, pvr_isp_edge.h
// Winding and EdgeWinding, refsw_tile.cpp CulledBySize / CulledByFacing, at refsw3 4f3efe15).
//
//   bad    any x or y of corners 1-3, or of corner 4 of a quad, is an infinity or a NaN (FromBits `bad`). refsw3 reads it
//          from the plain Winding's determinant, whose flag is the OR of every operand's (each corner enters it; Mul and
//          Add OR the flags), and from FX[3], FY[3]: nothing is drawn and nothing is culled (dreamcast-tests
//          pvr-tests/huge). The plain determinant itself is used for nothing else, so it is not built.
//   det    EdgeWinding: e(j,k) = sw(Sub(sw(x_j y_k), sw(x_k y_j))), e1 = e(1,2), e2 = e(2,0), e3 = e(0,1) (corners
//          0-based), det = sw(Add(sw(Add(e1, e2)), e3)); 24-bit products and sums, reach 25, no zero rule (isp 6.2)
//          [faredge_m131, faredge_ecap, faredge_walk, faredge_far32: the plain determinant 296 / 1,007 / 647 / 408
//          tiles wrong, the swamped 0; covmeas rules 2, 9: the order (e1 + e2) + e3, zero counts as positive]
//   flip   the winding sgn = +1 iff det < 0 and det != 0, else -1; flip = (sgn < 0): EdgeTile::Setup turns s20, sx, sy
//   culled CullMode != 0, no bad corner, and CulledBySize(det) || CulledByFacing(CullMode, det) on the swamped
//          determinant (num H9, p2_fp_cull) [faredge_cull: 484 of 1,200 regions wrong with the plain one; cullval;
//          raster page 4: equal is culled]
// Combinational.
module p2_isp_edge_det
  import p2_pkg::*;
(
  input  p2_fp24_t [3:0] x,              // FromBits of corners 1-4 (rasterizer order)
  input  p2_fp24_t [3:0] y,
  input  logic           quad,
  input  logic [1:0]     cull_mode,      // ISP_TSP CullMode
  input  logic [31:0]    fpu_cull_val,   // FPU_CULL_VAL
  output logic           bad,
  output p2_fp24_t       det,
  output logic           flip,
  output logic           culled
);
  p2_fp24_t [2:0] e;
  p2_fp24_t       s12, w12, s123;

  // e1 = e(1, 2), e2 = e(2, 0), e3 = e(0, 1): e(j, k) with j = (g + 1) % 3, k = (g + 2) % 3
  genvar g;
  generate
    for (g = 0; g < 3; g = g + 1) begin : g_e
      localparam int J = (g + 1) % 3;
      localparam int K = (g + 2) % 3;
      p2_isp_edge_cross u_e (.a1(x[J]), .b1(y[K]), .a2(x[K]), .b2(y[J]), .o(e[g]));
    end
  endgenerate

  p2_isp_fadd u_a12 (.a(e[0]), .b(e[1]), .sub(1'b0), .o(s12));
  p2_isp_fsw #(.SAT(1'b0)) u_s12 (.i(s12), .o(w12));
  p2_isp_fadd u_a3 (.a(w12), .b(e[2]), .sub(1'b0), .o(s123));
  p2_isp_fsw #(.SAT(1'b0)) u_sd (.i(s123), .o(det));

  assign bad  = x[0].bad | x[1].bad | x[2].bad | y[0].bad | y[1].bad | y[2].bad | (quad & (x[3].bad | y[3].bad));
  // EdgeWinding: (det.neg && !det.zero()) ? 1 : -1; a zero counts as positive (covmeas rule 9)
  assign flip = !(det.neg && det.mant != '0);

  logic by_size, by_facing;
  p2_fp_cull u_cull (
    .det_neg(det.neg), .det_bad(det.bad), .det_exp(det.exp), .det_mant(det.mant),
    .fpu_cull_val(fpu_cull_val), .cull_mode(cull_mode), .by_size(by_size), .by_facing(by_facing));
  assign culled = (cull_mode != 2'd0) && !bad && (by_size || by_facing);
endmodule

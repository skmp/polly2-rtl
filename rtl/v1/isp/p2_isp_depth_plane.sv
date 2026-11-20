// p2_isp_depth_plane: the depth plane of one primitive, per primitive (not per tile), in the depth setup's ranged
// arithmetic (refcore pvr_isp_depth.h DepthTileT::Setup L415-426 and the determinant-zero mean L645-655 at refsw3
// 4f3efe15; isp 9.2, 9.4b; ARCHITECTURE 3.4.4 step 6). Corners 1, 2, 3 in rasterizer order (refsw3 0, 1, 2; a quad's
// depth is its first three corners': refsw_tile.cpp L811-813), FromSingle(., 1) inputs (num H4: field 255 an infinity
// with its sign, field 0 a zero), every operation the depth flavour of H10 (p2_isp_zmul, p2_isp_zadd):
//
//   e1  = addE(mul(x2, y3), -mul(x3, y2));  e2 = addE(mul(x3, y1), -mul(x1, y3));  e3 = addE(mul(x1, y2), -mul(x2, y1))
//   a   = (mul(z1, subC(y2, y3)) + mul(z2, subC(y3, y1))) + mul(z3, subC(y1, y2))           (t1 + t2) + t3
//   b   = (mul(z1, subC(x3, x2)) + mul(z2, subC(x1, x3))) + mul(z3, subC(x2, x1))
//   c   = (mul(z1, e1) + mul(z3, e3)) + mul(z2, e2)                                          (t1 + t3) + t2
//   det = addE(addE(e1, e2), e3);  Perpendicular(det) (FPU_PERP_VAL, num H9): det = +0
// [zmeas item 1: the sum orders, one of 384 combinations fits; zovf_sum: the constant's order; depth2_zcoord, depth2_zedge:
// the zero rule in subC and addE (DepthHW::zeroRuleCoords, zeroRuleEdges); perpval, perpeq, detinf: FPU_PERP_VAL.]
// The edges and the determinant are the depth unit's own, not the edge unit's swamped EdgeWinding (isp 6.2, 9.2).
//
// The determinant-zero mean (isp 9.4b): (z1 + z2) + z3 in the setup's adder, a corner of exponent field 255 adding as
// an infinity of its sign and two such of opposite signs as their 23-bit fractions say (the larger fraction's
// infinity; equal ones +0 by `add`; a sum's fraction is 0), times OneThird (0xAAAAAB 2^-25, ranged), stored flat
// (p2_zword_pkg::flat) [perpmean_word 16,384 of 16,384; perpmean_neg; perpmean_bg; perpmean_strip; perpmean_tiny;
// depthgaps_detneg; depthgaps_dzinf 48 of 48]. The key is used only when the tile's regime is the mean's
// (p2_isp_depth_setup). Combinational.
module p2_isp_depth_plane
  import p2_hw_pkg::*;
  import p2_pkg::*;
  import p2_fp_pkg::*;
(
  input  logic [2:0][31:0] x_bits,
  input  logic [2:0][31:0] y_bits,
  input  logic [2:0][31:0] z_bits,
  input  logic [31:0]      fpu_perp_val,
  output p2_fp24_t         a,
  output p2_fp24_t         b,
  output p2_fp24_t         c,
  output p2_fp24_t         det,         // after Perpendicular
  output p2_zkey_t         mean_key     // flat(mean): the key of a determinant-zero (or perpendicular) primitive
);
  // the zero rule's switches (DepthHW; p2_hw_check: the RTL implements 1)
  localparam bit RULE_COORDS = P2_ISP_DEPTH_ZERO_RULE_COORDS != 0;
  localparam bit RULE_EDGES  = P2_ISP_DEPTH_ZERO_RULE_EDGES != 0;

  p2_fp24_t [2:0] X, Y, Z;
  genvar g;
  generate
    for (g = 0; g < 3; g = g + 1) begin : g_in
      p2_fp_in_single u_x (.u(x_bits[g]), .ranged(1'b1), .o_neg(X[g].neg), .o_bad(X[g].bad), .o_exp(X[g].exp),
        .o_mant(X[g].mant));
      p2_fp_in_single u_y (.u(y_bits[g]), .ranged(1'b1), .o_neg(Y[g].neg), .o_bad(Y[g].bad), .o_exp(Y[g].exp),
        .o_mant(Y[g].mant));
      p2_fp_in_single u_z (.u(z_bits[g]), .ranged(1'b1), .o_neg(Z[g].neg), .o_bad(Z[g].bad), .o_exp(Z[g].exp),
        .o_mant(Z[g].mant));
    end
  endgenerate

  // ---- the edges x_j y_k - x_k y_j: e[0] = edge(1, 2), e[1] = edge(2, 0), e[2] = edge(0, 1) in refsw3's numbering
  p2_fp24_t [2:0] pjk, pkj, e;
  generate
    for (g = 0; g < 3; g = g + 1) begin : g_edge
      localparam int J = (g + 1) % 3;
      localparam int K = (g + 2) % 3;
      p2_isp_zmul #(.RANGED(1'b1)) u_jk (.a(X[J]), .b(Y[K]), .o(pjk[g]));
      p2_isp_zmul #(.RANGED(1'b1)) u_kj (.a(X[K]), .b(Y[J]), .o(pkj[g]));
      p2_isp_zadd #(.RULE(RULE_EDGES)) u_e (.a(pjk[g]), .b(pkj[g]), .sub(1'b1), .o(e[g]));
    end
  endgenerate

  // ---- the coordinate differences: dy[k] = subC(y_{k+1}, y_{k+2}), dx[k] = subC(x_{k+2}, x_{k+1}) (refsw3 a, b)
  p2_fp24_t [2:0] dy, dx, ta, tb, tc;
  generate
    for (g = 0; g < 3; g = g + 1) begin : g_diff
      localparam int J = (g + 1) % 3;
      localparam int K = (g + 2) % 3;
      p2_isp_zadd #(.RULE(RULE_COORDS)) u_dy (.a(Y[J]), .b(Y[K]), .sub(1'b1), .o(dy[g]));
      p2_isp_zadd #(.RULE(RULE_COORDS)) u_dx (.a(X[K]), .b(X[J]), .sub(1'b1), .o(dx[g]));
      p2_isp_zmul #(.RANGED(1'b1)) u_ta (.a(Z[g]), .b(dy[g]), .o(ta[g]));
      p2_isp_zmul #(.RANGED(1'b1)) u_tb (.a(Z[g]), .b(dx[g]), .o(tb[g]));
      p2_isp_zmul #(.RANGED(1'b1)) u_tc (.a(Z[g]), .b(e[g]), .o(tc[g]));
    end
  endgenerate

  // ---- a, b: (t1 + t2) + t3; c: (t1 + t3) + t2
  p2_fp24_t a12, b12, c13, det12, det0;
  p2_isp_zadd #(.RULE(1'b1)) u_a12 (.a(ta[0]), .b(ta[1]), .sub(1'b0), .o(a12));
  p2_isp_zadd #(.RULE(1'b1)) u_a   (.a(a12), .b(ta[2]), .sub(1'b0), .o(a));
  p2_isp_zadd #(.RULE(1'b1)) u_b12 (.a(tb[0]), .b(tb[1]), .sub(1'b0), .o(b12));
  p2_isp_zadd #(.RULE(1'b1)) u_b   (.a(b12), .b(tb[2]), .sub(1'b0), .o(b));
  p2_isp_zadd #(.RULE(1'b1)) u_c13 (.a(tc[0]), .b(tc[2]), .sub(1'b0), .o(c13));
  p2_isp_zadd #(.RULE(1'b1)) u_c   (.a(c13), .b(tc[1]), .sub(1'b0), .o(c));
  // ---- det = (e1 + e2) + e3, then FPU_PERP_VAL
  p2_isp_zadd #(.RULE(RULE_EDGES)) u_d12 (.a(e[0]), .b(e[1]), .sub(1'b0), .o(det12));
  p2_isp_zadd #(.RULE(RULE_EDGES)) u_d   (.a(det12), .b(e[2]), .sub(1'b0), .o(det0));

  logic perp;
  p2_fp_perp u_perp (.det_bad(det0.bad), .det_exp(det0.exp), .det_mant(det0.mant), .fpu_perp_val(fpu_perp_val),
    .perp(perp));
  always_comb begin
    det = det0;
    if (perp)
      det = '0;                           // FPU_PERP_VAL: as a determinant of +0 (pvr_softfp.h Perpendicular)
  end

  // ---- the mean: addBad(addBad(z1, f1, z2, f2), 0, z3, f3) x OneThird
  logic [2:0][22:0] fr;                   // a corner's 23-bit fraction when its exponent field is 255, else 0
  generate
    for (g = 0; g < 3; g = g + 1) begin : g_frac
      assign fr[g] = (z_bits[g][30:23] == 8'hFF) ? z_bits[g][22:0] : 23'd0;
    end
  endgenerate

  p2_fp24_t s12a, s12, s3a, sum, third, mean;
  p2_isp_zadd #(.RULE(1'b1)) u_s12 (.a(Z[0]), .b(Z[1]), .sub(1'b0), .o(s12a));
  // two infinities of opposite signs and different fractions: the larger fraction's infinity
  always_comb begin
    s12 = s12a;
    if (Z[0].bad && Z[1].bad && Z[0].neg != Z[1].neg && fr[0] != fr[1]) begin
      s12      = '0;
      s12.bad  = 1'b1;
      s12.neg  = (fr[0] > fr[1]) ? Z[0].neg : Z[1].neg;
    end
  end
  p2_isp_zadd #(.RULE(1'b1)) u_s3 (.a(s12), .b(Z[2]), .sub(1'b0), .o(s3a));
  // the sum's fraction is 0: against the third corner's
  always_comb begin
    sum = s3a;
    if (s12.bad && Z[2].bad && s12.neg != Z[2].neg && fr[2] != 23'd0) begin
      sum     = '0;
      sum.bad = 1'b1;
      sum.neg = Z[2].neg;
    end
  end
  // OneThird: 1/3 rounded up to 24 bits, 0xAAAAAB 2^-25 (pvr_softfp.h OneThird; perpmean_word: 0xAAAAAA misses 1,618)
  always_comb begin
    third      = '0;
    third.mant = 24'hAAAAAB;
    third.exp  = -10'sd25;
  end
  p2_isp_zmul #(.RANGED(1'b1)) u_mean (.a(sum), .b(third), .o(mean));
  assign mean_key = p2_zword_pkg::flat(mean);
endmodule

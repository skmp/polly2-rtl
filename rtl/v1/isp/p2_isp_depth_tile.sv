// p2_isp_depth_tile: the depth plane in one tile, from the primitive's plane (p2_isp_depth_plane): the regime and the
// fields of p2_ztile_t (refcore pvr_isp_depth.h DepthTileT::Setup L427-735 at refsw3 4f3efe15; isp 9.3-9.5;
// ARCHITECTURE 2.4, 3.4.4 step 7). In refsw3's order:
//   1.  det infinite:                          CONST, key 0                        [trsort_recip page 10, trsort_auto]
//   1b. det of 2^126 or more (top(det) - 1 >= 126, exactly 2^126 included: the reciprocal is zero): CONST, key 0
//       [4f3efe15: trsort_recip 160 / 160, trsort_recipovf 80 / 80, trsort_auto 240 / 240]
//   2.  det nonzero: inv0 = Recip(det, 24); first0 = mul(add(add(mul(a, x0), mul(b, y0)), c), inv0) at the tile's first
//       sample point (x0, y0) = (left, top) + HALF_OFFSET[0] / 2 (0de9776b: depth2_halfc, depth2_halfo 16 / 16)
//       a. a or b infinite: REG (isp 9.5)              [zovf_creg, zovf_wrap, nantr_pos, depthgaps_rstart, depthgaps_rcut,
//                                                       depth2_cneg, depth2_halfc]
//       b. first0 or c infinite: a == b == 0: CONST saturated(first0) / from_fp(cut19(first0)) [bgbig]; else BLOCK from
//          the forced start +-2^127 (first0 infinite) or first0     [depthgaps_infstart, depthgaps_edges, zovf]
//       c. else BLOCK from first0
//   3.  det zero (or perpendicular): CONST, the mean's key (p2_isp_depth_plane)       [perpmean_*, depthgaps_dzinf]
// BLOCK (isp 9.4a, in the G form): A = Mul(a, inv0, 24), B likewise (unranged), below 2^-126 cleared (`under`);
// pair = max(top A, top B); a zero start with no slopes is CONST 0 [zspec pages 3-6]; start = cut20(first), onto the
// slopes' grid 2^(pair - 21) toward zero (startOnSlopes 1: zstart 49,152 / 49,152); gexp = max(e, pair + 5) - 26 with
// e = top(first), or pair + 5 for a start that is or was cut to zero [zmeas "mix reach", depthgaps_flt];
//   S  = 2 trunc(start / G)            the start in half units of G = 2^gexp, |S| < 2^27
//   DX = trunc(cut20(A) / G), DY       the steps in units of G (the cut to the pair's grid and to the tile's grid
//                                      2^(e - 26) is one cut onto G: isp 9.4a), |DX| < 2^21
//   E  = clamp(gexp + 26, -122, 128)   [depthgaps_neggrid, depthgaps_tinymean (-122); depthgaps_bigslope, _bigpair (128)]
//   nsh = E - 15 - gexp; fbw = the start is zero and nsh < 0 (NegWord's fallback word, num A5)
// [zmeas 89,801 brackets; zblock, ztile, zstart, precision; depthgaps_*.] refsw3's float form (a slope 2^50 times the
// start, `pair - 21 + 24 - unit > 100`) is unreachable with startOnSlopes 1 (isp 9.4a): there is none here, and the
// testbench asserts refsw3 never takes it.
// REG (isp 9.5): sa, sb = an infinite slope's step +-1 (its sign against det's), 0 for a finite one; fa, fb = the
// finite slope Mul(a, inv0, 24) cut to 20 bits, then toward zero onto 2^102, mod 2^30 with its sign [zovf_creg 50 / 50,
// zovf_wrap W2, depth2_cneg 12 / 12]; r0 = +-2^25 for an infinite first0 (one step; a NaN's payload does not count:
// nantr_pos 2,700 / 2,700), else cut20(first0) toward zero onto 2^102 [depthgaps_rstart, depthgaps_rcut].
// The products and sums of 2. are this module's; the rest is p2_isp_depth_fin (shared with M4's p2_isp_setup).
// Combinational.
module p2_isp_depth_tile
  import p2_hw_pkg::*;
  import p2_pkg::*;
  import p2_fp_pkg::*;
(
  input  p2_fp24_t                a,
  input  p2_fp24_t                b,
  input  p2_fp24_t                c,
  input  p2_fp24_t                det,          // after Perpendicular
  input  p2_zkey_t                mean_key,
  input  logic [5:0]              tile_x,
  input  logic [5:0]              tile_y,
  input  logic                    half,         // HALF_OFFSET[0] (fpu_pixel_half_offset): the sample point
  output p2_ztile_t               z,
  // the values the testbench compares on the way (debug taps of the setup's results; not a hardware interface)
  output p2_fp24_t                first0_o,
  output p2_fp24_t                sa_o,         // A, B after `under`
  output p2_fp24_t                sb_o
);
  // the products and sums of the tile (the rules after them: p2_isp_depth_fin)
  p2_fp24_t inv0;
  p2_fp_recip24 u_recip (.i_neg(det.neg), .i_bad(det.bad), .i_exp(det.exp), .i_mant(det.mant),
    .o_neg(inv0.neg), .o_bad(inv0.bad), .o_exp(inv0.exp), .o_mant(inv0.mant));

  // ---------------------------------------------------------------------------------------------- first0
  // the first sample point x00, y00 (made below, beside the regime: the start and the lanes' S are one rule)
  p2_fp24_t x00, y00, ax, by, s_ab, s_abc, first0;
  p2_isp_zmul #(.RANGED(1'b1)) u_ax (.a(a), .b(x00), .o(ax));
  p2_isp_zmul #(.RANGED(1'b1)) u_by (.a(b), .b(y00), .o(by));
  p2_isp_zadd #(.RULE(1'b1)) u_ab (.a(ax), .b(by), .sub(1'b0), .o(s_ab));
  p2_isp_zadd #(.RULE(1'b1)) u_abc (.a(s_ab), .b(c), .sub(1'b0), .o(s_abc));
  p2_isp_zmul #(.RANGED(1'b1)) u_first (.a(s_abc), .b(inv0), .o(first0));
  assign first0_o = first0;

  // ---------------------------------------------------------------------------------------------- the slopes
  // A = Mul(a, inv, coefBits), B likewise: unranged (they step as numbers up to 2^254: depthgaps_edges); the same
  // products give REG's steps (refsw3's invS is inv0)
  p2_fp24_t a_raw, b_raw;
  p2_isp_zmul #(.RANGED(1'b0)) u_sa (.a(a), .b(inv0), .o(a_raw));
  p2_isp_zmul #(.RANGED(1'b0)) u_sb (.a(b), .b(inv0), .o(b_raw));

  // the tile's first sample point in half pixels, 2 left + HALF_OFFSET[0] (FromHalves; refsw_tile.cpp L809-813): the
  // corner with HALF_OFFSET[0] clear, and every pixel whole steps from the start there, S included (0de9776b)
  always_comb begin
    x00      = '0;
    x00.exp  = -10'sd1;
    x00.mant = 24'({tile_x, 5'd0, half});
    y00      = '0;
    y00.exp  = -10'sd1;
    y00.mant = 24'({tile_y, 5'd0, half});
  end

  // the regime and the fields (p2_isp_depth_fin, shared with M4's p2_isp_setup)
  p2_isp_depth_fin u_fin (.a(a), .b(b), .c(c), .det(det), .mean_key(mean_key), .first0(first0), .a_raw(a_raw),
    .b_raw(b_raw), .half(half), .z(z), .sa_o(sa_o), .sb_o(sb_o));
endmodule

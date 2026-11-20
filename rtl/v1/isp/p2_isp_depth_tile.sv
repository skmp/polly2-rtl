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
  localparam int XW          = P2_FP_XW;
  localparam int TILE_BITS   = P2_ISP_DEPTH_TILE_BITS;      // 26
  localparam int PAIR_BITS   = P2_ISP_DEPTH_PAIR_BITS;      // 21
  localparam int START_BITS  = P2_ISP_DEPTH_START_BITS;     // 20
  localparam int SLOPE_BITS  = P2_ISP_DEPTH_SLOPE_BITS;     // 20
  localparam int REG_GRID    = 102;                         // the register's unit 2^102 (2^25 of them: 2^127, a step)
  localparam int REG_STEP    = 25;
  localparam int E_MIN       = -122;
  localparam int E_MAX       = 128;
  localparam int DET_HIGH    = P2_FP_RECIP_DET_HIGH;        // 126: the reciprocal's range (4f3efe15)

  // top(v) = exp + BL(mant): v in [2^(top - 1), 2^top)
  function automatic logic signed [XW-1:0] ftop(input logic signed [P2_FP_EW-1:0] e, input logic [23:0] m);
    logic [5:0] n;
    n = '0;
    for (int k = 0; k < 24; k++)
      if (m[k]) n = 6'(k + 1);
    return p2_fp_xw(e) + XW'(n);
  endfunction

  // ---------------------------------------------------------------------------------------------- the determinant
  logic det_zero, det_big;
  assign det_zero = !det.bad && det.mant == '0;
  assign det_big  = !det.bad && det.mant != '0 && (ftop(det.exp, det.mant) - XW'(1) >= XW'(DET_HIGH));

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
  p2_fp24_t a_raw, b_raw, sa_u, sb_u;
  p2_isp_zmul #(.RANGED(1'b0)) u_sa (.a(a), .b(inv0), .o(a_raw));
  p2_isp_zmul #(.RANGED(1'b0)) u_sb (.a(b), .b(inv0), .o(b_raw));
  // under(): below 2^-126 the mantissa cleared (zspec pages 3-6)
  always_comb begin
    sa_u = a_raw;
    sb_u = b_raw;
    if (a_raw.mant != '0 && ftop(a_raw.exp, a_raw.mant) - XW'(1) < XW'(-126)) sa_u.mant = '0;
    if (b_raw.mant != '0 && ftop(b_raw.exp, b_raw.mant) - XW'(1) < XW'(-126)) sb_u.mant = '0;
  end
  assign sa_o = sa_u;
  assign sb_o = sb_u;

  // ---------------------------------------------------------------------------------------------- REG (isp 9.5)
  logic cap_a, cap_b;
  assign cap_a = a.bad;
  assign cap_b = b.bad;

  // the finite slope's step: cut20, toward zero onto 2^102, mod 2^30, signed (refsw3 rstep)
  p2_fp20_t qa20, qb20, qa, qb;
  p2_fp_cut #(.IW(24), .N(SLOPE_BITS)) u_qa20 (.i_neg(a_raw.neg), .i_bad(a_raw.bad), .i_exp(a_raw.exp),
    .i_mant(a_raw.mant), .o_neg(qa20.neg), .o_bad(qa20.bad), .o_exp(qa20.exp), .o_mant(qa20.mant));
  p2_fp_cut #(.IW(24), .N(SLOPE_BITS)) u_qb20 (.i_neg(b_raw.neg), .i_bad(b_raw.bad), .i_exp(b_raw.exp),
    .i_mant(b_raw.mant), .o_neg(qb20.neg), .o_bad(qb20.bad), .o_exp(qb20.exp), .o_mant(qb20.mant));
  p2_fp_cut_below #(.MW(SLOPE_BITS)) u_qa (.i_neg(qa20.neg), .i_bad(qa20.bad), .i_exp(qa20.exp), .i_mant(qa20.mant),
    .e(P2_FP_EW'(REG_GRID)), .o_neg(qa.neg), .o_bad(qa.bad), .o_exp(qa.exp), .o_mant(qa.mant));
  p2_fp_cut_below #(.MW(SLOPE_BITS)) u_qb (.i_neg(qb20.neg), .i_bad(qb20.bad), .i_exp(qb20.exp), .i_mant(qb20.mant),
    .e(P2_FP_EW'(REG_GRID)), .o_neg(qb.neg), .o_bad(qb.bad), .o_exp(qb.exp), .o_mant(qb.mant));

  function automatic logic signed [30:0] rstep(input logic cap, input logic v_zero, input p2_fp20_t q);
    logic signed [XW-1:0] sh;
    logic [29:0]          m;
    if (cap || v_zero || q.mant == '0)
      return '0;
    sh = p2_fp_xw(q.exp) - XW'(REG_GRID);         // >= 0 after the cut onto 2^102
    if (sh >= XW'(30) || sh < 0)
      return '0;                                  // (q.mant << sh) & (2^30 - 1) is 0 from sh = 30 (GAP: 2^128 and up)
    m = 30'(q.mant) << sh[4:0];                   // the bits from 2^30 up dropped: mod 2^30
    return q.neg ? 31'sd0 - $signed({1'b0, m}) : $signed({1'b0, m});
  endfunction

  logic signed [30:0] fa, fb;
  assign fa = rstep(cap_a, a.mant == '0, qa);
  assign fb = rstep(cap_b, b.mant == '0, qb);

  // the register's start: one step with first0's sign when it is infinite, else cut20(first0) toward zero onto 2^102
  p2_fp20_t f0_20;
  p2_fp_cut #(.IW(24), .N(START_BITS)) u_f020 (.i_neg(first0.neg), .i_bad(first0.bad), .i_exp(first0.exp),
    .i_mant(first0.mant), .o_neg(f0_20.neg), .o_bad(f0_20.bad), .o_exp(f0_20.exp), .o_mant(f0_20.mant));
  logic signed [P2_ZT_REG_BITS-1:0] r0;
  always_comb begin
    logic signed [XW-1:0] sh;
    logic [63:0]          m;
    p2_fp24_t             rs;                     // the start's 20 bits (depthgaps_rcut)
    rs      = '0;
    rs.exp  = f0_20.exp;
    rs.mant = 24'(f0_20.mant);
    m  = '0;
    sh = p2_fp_xw(rs.exp) - XW'(REG_GRID);
    if (first0.bad) begin
      m = 64'd1 << REG_STEP;
    end else if (rs.mant != '0) begin
      if (sh >= 0)
        m = (sh < XW'(40)) ? 64'(rs.mant) << sh[5:0] : 64'd0;
      else
        m = (sh > XW'(-64)) ? 64'(rs.mant) >> 6'(XW'(0) - sh) : 64'd0;
    end
    // toward zero, either sign (depthgaps_rstart)
    r0 = first0.neg ? P2_ZT_REG_BITS'(64'd0 - m) : P2_ZT_REG_BITS'(m);
  end

  // ---------------------------------------------------------------------------------------------- BLOCK (isp 9.4a)
  // the constant or the start overflowed: a flat plane is CONST; otherwise the start forced to +-2^127 (first0
  // infinite) or first0 itself (refsw3 `forced`)
  logic     fbad, forced_flat;
  p2_fp24_t first;
  assign fbad        = first0.bad || c.bad;
  assign forced_flat = fbad && a.mant == '0 && b.mant == '0;
  always_comb begin
    first = first0;
    if (first0.bad) begin
      first      = '0;
      first.neg  = first0.neg;
      first.exp  = 10'sd104;               // FromSingle(0x7f000000): 2^127
      first.mant = 24'h800000;
    end
    // under(first): first0 is ranged already (a no-op kept for refsw3's order)
    if (first.mant != '0 && ftop(first.exp, first.mant) - XW'(1) < XW'(-126)) first.mant = '0;
  end

  logic                 first_zero, pair_v;
  logic signed [XW-1:0] top_a, top_b, top_f, pair;
  assign first_zero = first.mant == '0;
  assign top_a      = ftop(sa_u.exp, sa_u.mant);
  assign top_b      = ftop(sb_u.exp, sb_u.mant);
  assign top_f      = ftop(first.exp, first.mant);
  assign pair_v     = sa_u.mant != '0 || sb_u.mant != '0;
  always_comb begin
    if (sa_u.mant == '0)      pair = top_b;
    else if (sb_u.mant == '0) pair = top_a;
    else                      pair = (top_a > top_b) ? top_a : top_b;
  end

  // the start: cut20, then onto the slopes' grid 2^(pair - 21) toward zero, either sign
  p2_fp20_t f20, st;
  p2_fp_cut #(.IW(24), .N(START_BITS)) u_f20 (.i_neg(first.neg), .i_bad(first.bad), .i_exp(first.exp),
    .i_mant(first.mant), .o_neg(f20.neg), .o_bad(f20.bad), .o_exp(f20.exp), .o_mant(f20.mant));
  p2_fp20_t st_c;
  p2_fp_cut_below #(.MW(START_BITS)) u_st (.i_neg(f20.neg), .i_bad(f20.bad), .i_exp(f20.exp), .i_mant(f20.mant),
    .e(P2_FP_EW'(pair - XW'(PAIR_BITS))), .o_neg(st_c.neg), .o_bad(st_c.bad), .o_exp(st_c.exp), .o_mant(st_c.mant));
  assign st = pair_v ? st_c : f20;

  logic                 start_zero;
  logic signed [XW-1:0] e_blk, gx, gexp, E, nsh;
  assign start_zero = st.mant == '0;
  assign e_blk      = (first_zero || start_zero) ? pair + XW'(TILE_BITS - PAIR_BITS) : top_f;
  assign gx         = (pair_v && pair + XW'(TILE_BITS - PAIR_BITS) > e_blk) ? pair + XW'(TILE_BITS - PAIR_BITS) : e_blk;
  assign gexp       = gx - XW'(TILE_BITS);
  assign E          = (gx < XW'(E_MIN)) ? XW'(E_MIN) : (gx > XW'(E_MAX)) ? XW'(E_MAX) : gx;
  assign nsh        = E - XW'(15) - gexp;

  // S = 2 start / G: the start's bits are on G or above it (isp 9.4a), a left shift of 1 .. 27
  logic signed [P2_ZT_S_BITS-1:0] S;
  always_comb begin
    logic signed [XW-1:0] sh;
    logic [P2_ZT_S_BITS-1:0] m;
    sh = p2_fp_xw(st.exp) - gexp + XW'(1);
    m  = (st.mant == '0 || sh < 0 || sh >= XW'(P2_ZT_S_BITS)) ? '0 : P2_ZT_S_BITS'(st.mant) << sh[4:0];
    S  = st.neg ? P2_ZT_S_BITS'(0) - $signed(m) : $signed(m);
  end

  // DX, DY = cut20(A), cut20(B) toward zero onto G
  p2_fp20_t a20, b20, ag, bg;
  p2_fp_cut #(.IW(24), .N(SLOPE_BITS)) u_a20 (.i_neg(sa_u.neg), .i_bad(sa_u.bad), .i_exp(sa_u.exp), .i_mant(sa_u.mant),
    .o_neg(a20.neg), .o_bad(a20.bad), .o_exp(a20.exp), .o_mant(a20.mant));
  p2_fp_cut #(.IW(24), .N(SLOPE_BITS)) u_b20 (.i_neg(sb_u.neg), .i_bad(sb_u.bad), .i_exp(sb_u.exp), .i_mant(sb_u.mant),
    .o_neg(b20.neg), .o_bad(b20.bad), .o_exp(b20.exp), .o_mant(b20.mant));
  p2_fp_cut_below #(.MW(SLOPE_BITS)) u_ag (.i_neg(a20.neg), .i_bad(a20.bad), .i_exp(a20.exp), .i_mant(a20.mant),
    .e(P2_FP_EW'(gexp)), .o_neg(ag.neg), .o_bad(ag.bad), .o_exp(ag.exp), .o_mant(ag.mant));
  p2_fp_cut_below #(.MW(SLOPE_BITS)) u_bg (.i_neg(b20.neg), .i_bad(b20.bad), .i_exp(b20.exp), .i_mant(b20.mant),
    .e(P2_FP_EW'(gexp)), .o_neg(bg.neg), .o_bad(bg.bad), .o_exp(bg.exp), .o_mant(bg.mant));

  function automatic logic signed [P2_ZT_STEP_BITS-1:0] gstep(input p2_fp20_t v, input logic signed [XW-1:0] g);
    logic signed [XW-1:0]        sh;
    logic [P2_ZT_STEP_BITS-1:0] m;
    sh = p2_fp_xw(v.exp) - g;
    m  = (v.mant == '0 || sh < 0 || sh >= XW'(P2_ZT_STEP_BITS)) ? '0 : P2_ZT_STEP_BITS'(v.mant) << sh[4:0];
    return v.neg ? P2_ZT_STEP_BITS'(0) - $signed(m) : $signed(m);
  endfunction

  // cut19(first0) = cut19(cut20(first0)): one more bit off when the 20-bit cut has 20
  p2_fp20_t c19;
  always_comb begin
    c19 = f0_20;
    if (f0_20.mant[19]) begin
      c19.mant = f0_20.mant >> 1;
      c19.exp  = f0_20.exp + 10'sd1;
    end
  end

  // ---------------------------------------------------------------------------------------------- the regime
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
  always_comb begin
    z        = '0;
    z.regime = P2_Z_CONST;
    z.key    = '0;
    z.r0     = r0;
    z.sa     = cap_a ? ((a.neg != det.neg) ? -2'sd1 : 2'sd1) : 2'sd0;
    z.sb     = cap_b ? ((b.neg != det.neg) ? -2'sd1 : 2'sd1) : 2'sd0;
    z.fa     = fa;
    z.fb     = fb;
    z.S      = S;
    z.DX     = gstep(ag, gexp);
    z.DY     = gstep(bg, gexp);
    z.gexp   = 10'(gexp);
    z.E      = 9'(E);
    z.nsh    = (nsh < XW'(-16)) ? -5'sd16 : (nsh > XW'(15)) ? 5'sd15 : P2_ZT_NSH_BITS'(nsh);
    z.fbw    = start_zero && nsh < 0;
    if (det.bad || det_big) begin
      z.regime = P2_Z_CONST;                    // the reciprocal is zero: 0 at every pixel
      z.key    = '0;
    end else if (det_zero) begin
      z.regime = P2_Z_CONST;                    // the mean of the corners
      z.key    = mean_key;
    end else if (cap_a || cap_b) begin
      z.regime = P2_Z_REG;
    end else if (forced_flat) begin
      z.regime = P2_Z_CONST;
      if (first0.bad) begin
        z.key = p2_zword_pkg::saturated(first0.neg);
      end else begin
        z.key = p2_zword_pkg::from_fp(c19);
      end
    end else if (first_zero && !pair_v) begin
      z.regime = P2_Z_CONST;                    // no start and no slopes: 0
      z.key    = '0;
    end else begin
      z.regime = P2_Z_BLOCK;
    end
  end
endmodule

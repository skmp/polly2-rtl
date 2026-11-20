// p2_isp_edge_fin: the blocking of one edge in one tile into p2_edge_t, from the tile's start and the edge's steps (refcore
// pvr_isp_edge.h EdgeTile::Setup L203-293 at refsw3 4f3efe15; isp 8.3, 8.5; ARCHITECTURE 2.4, 3.4.4 step 4; num 5.1). The
// fixed logic after the arithmetic: p2_isp_edge_block (M2's fixed-latency unit) feeds it the start it computes, and
// p2_isp_setup (M4) the start its microprogram computed on p2_isp_alu; the rules are one copy here.
//
//   s20     = cut20(start); s20, sx, sy turned when flip (sgn < 0)          [covmeas rule 3; EdgeHW::startBits]
//   E       = max(ep + blockAdd, es + startAdd) (es only for a start that is not zero), at most blockMax: an edge whose
//             E is cut is BIG (cut <=> ep >= 124: es + 1 <= 129 always, isp 8.3) [faredge_m131, faredge_ecap: 129;
//             130 has 1,424 tiles wrong]
//   unit    = big ? E - cutUnitBits (2^102) : ep - pairBits   [edge2_walk pages 3-5: 900 of 900 tiles; 2^(E - 26) 240
//             wrong, 708fb8cd's two grids 339]
//   d       = E - unit
//   CONSTANT (const_v): a bad coordinate (nothing inside; unreachable behind the bad corner); a point edge, both ep and
//             es absent (inside: covmeas degen40, 234 of 234); no step (the start's sign); d >= 30 (the start's sign:
//             |t0| >= 2^d while 62 steps add less than 2^28, isp 8.5; refsw3 evaluates those tiles, cap E - unit > 56,
//             with this result: the testbench checks it on every such tile)
//   t0      = 2 floor(s20 / 2^unit) + (any bit of s20 below 2^unit), or for a big edge 2 trunc(s20 / 2^102), no half
//             unit [edge2_walk pages 3-5: 5 tiles wrong floored]
//   tx, ty  = 2 trunc(sx / 2^unit), 2 trunc(sy / 2^unit) (cutBelow toward zero, then exact)
//   zsh     = d - zeroShift + 1: zero2 = 2 << (E - zeroShift - unit) = 2^zsh
//   far32   = tx > 0: (32 tx) mod 2^30 = (tx mod 2^25) << 5; tx < 0 with tx mod 2^25 == 0 (sx a multiple of 2^126):
//             2^30 (= 2^131); else 0 (edge.h Walk L404) [edge2_walk pages 0-2, edge2_end pages 0-4, edge2_mult]
// The values fit p2_edge_t's widths wherever the edge is not constant (isp 8.5). Combinational.
module p2_isp_edge_fin
  import p2_hw_pkg::*;
  import p2_pkg::*;
  import p2_fp_pkg::*;
(
  input  p2_fp24_t                     start,   // sat(Add(first, c)): the tile's start, saturated to +-2^127
  input  p2_fp20_t                     sx,      // cut20(-sat(dy)), not turned
  input  p2_fp20_t                     sy,      // cut20(sat(dx)), not turned
  input  logic signed [P2_FP_XW-1:0]   ep,
  input  logic                         ep_v,
  input  logic                         bad,
  input  logic                         flip,    // sgn < 0: turn the start and the steps
  output p2_edge_t                     e
);
  // EdgeHW's numbers (p2_hw_pkg)
  localparam int BLOCK_ADD     = P2_ISP_EDGE_BLOCK_ADD;
  localparam int START_ADD     = P2_ISP_EDGE_START_ADD;
  localparam int BLOCK_MAX     = P2_ISP_EDGE_BLOCK_MAX;
  localparam int CUT_UNIT_BITS = P2_ISP_EDGE_CUT_UNIT_BITS;
  localparam int PAIR_BITS     = P2_ISP_EDGE_PAIR_BITS;
  localparam int ZERO_SHIFT    = P2_ISP_EDGE_ZERO_SHIFT;

  // es = top(start) (L203)
  localparam int NW = $clog2(P2_FP24_MANT_BITS + 1);
  logic [NW-1:0]              ns;
  logic signed [P2_FP_XW-1:0] es;
  logic                       es_v;
  p2_fp_lzc #(.W(P2_FP24_MANT_BITS), .NW(NW)) u_bs (.v(start.mant), .n(ns));
  assign es   = p2_fp_xw(start.exp) + $signed({{(P2_FP_XW - NW){1'b0}}, ns});
  assign es_v = start.mant != '0;

  // s20 = start.cut(startBits) (L211), turned with sx, sy (L212-214)
  p2_fp20_t s20c, s20;
  p2_fp_cut #(.IW(P2_FP24_MANT_BITS), .N(P2_ISP_EDGE_START_BITS)) u_s20 (
    .i_neg(start.neg), .i_bad(start.bad), .i_exp(start.exp), .i_mant(start.mant),
    .o_neg(s20c.neg), .o_bad(s20c.bad), .o_exp(s20c.exp), .o_mant(s20c.mant));
  always_comb begin
    s20     = s20c;
    s20.neg = s20c.neg ^ flip;
  end

  // E, the cut, unit, d (L219-243)
  logic signed [P2_FP_XW-1:0] e0, ee, unit, d;
  logic                       cut;
  always_comb begin
    e0 = ep + P2_FP_XW'(BLOCK_ADD);
    if (es_v && es + P2_FP_XW'(START_ADD) > e0)
      e0 = es + P2_FP_XW'(START_ADD);
    cut  = e0 > P2_FP_XW'(BLOCK_MAX);
    ee   = cut ? P2_FP_XW'(BLOCK_MAX) : e0;
    unit = cut ? ee - P2_FP_XW'(CUT_UNIT_BITS) : ep - P2_FP_XW'(PAIR_BITS);
    d    = ee - unit;
  end

  // t0: floor(s20 / 2^unit) with its fraction bit; for a big edge the magnitude cut toward zero (L271-277)
  localparam int TW = P2_EDGE_T0_BITS;
  localparam int SW = P2_EDGE_STEP_BITS;
  logic signed [TW-1:0] fl, t0;
  logic                 frac;
  p2_fp_floor #(.MW(P2_FP20_MANT_BITS), .OW(TW), .ZNEG(1'b0), .CLAMP(0)) u_t0 (
    .i_neg(s20.neg & !cut), .i_exp(s20.exp), .i_mant(s20.mant), .u(unit[P2_FP_EW-1:0]), .o_int(fl), .o_frac(frac));
  always_comb begin
    if (!cut)
      t0 = (fl <<< 1) + $signed({{(TW - 1){1'b0}}, frac});
    else if (s20.neg)
      t0 = TW'(0) - (fl <<< 1);
    else
      t0 = fl <<< 1;
  end

  // tx, ty: sx, sy cut below the unit toward zero, in half units (L249-250, L278-279)
  logic signed [SW-2:0] qx, qy;
  p2_fp_floor #(.MW(P2_FP20_MANT_BITS), .OW(SW - 1), .ZNEG(1'b0), .CLAMP(0)) u_tx (
    .i_neg(1'b0), .i_exp(sx.exp), .i_mant(sx.mant), .u(unit[P2_FP_EW-1:0]), .o_int(qx), .o_frac());
  p2_fp_floor #(.MW(P2_FP20_MANT_BITS), .OW(SW - 1), .ZNEG(1'b0), .CLAMP(0)) u_ty (
    .i_neg(1'b0), .i_exp(sy.exp), .i_mant(sy.mant), .u(unit[P2_FP_EW-1:0]), .o_int(qy), .o_frac());
  logic signed [SW-1:0] tx, ty, mx, my;
  assign mx = {qx, 1'b0};
  assign my = {qy, 1'b0};
  assign tx = (sx.neg ^ flip) ? SW'(0) - mx : mx;
  assign ty = (sy.neg ^ flip) ? SW'(0) - my : my;

  // the constant tiles (L171-172, L204-216, L244-248; isp 8.5's d >= 30)
  localparam int D_CONST = 30;
  logic const_v, const_in;
  always_comb begin
    const_v  = 1'b1;
    const_in = 1'b0;
    if (bad)
      const_in = 1'b0;                          // an infinity or a NaN: nothing inside
    else if (!ep_v && !es_v)
      const_in = 1'b1;                          // a point edge: zero everywhere counts as inside
    else if (!ep_v || d >= P2_FP_XW'(D_CONST))
      const_in = !s20.neg;                      // no step, or the start 2^30 times the steps: its sign
    else
      const_v  = 1'b0;
  end

  // far32 (edge.h Walk L404), in half units of the big edge's unit 2^(blockMax - cutUnitBits) = 2^102:
  // H = 2^WB = 2^30 (= 2^walkExp = 2^131), and 32 tx mod 2^WB = (tx mod 2^(WB - log2 32)) << log2 32
  localparam int WB = P2_ISP_EDGE_WALK_EXP - (P2_ISP_EDGE_BLOCK_MAX - P2_ISP_EDGE_CUT_UNIT_BITS) + 1;
  localparam int FM = WB - P2_TILE_LOG2;        // 25: the bits of tx that survive 32 tx mod 2^WB
  logic [P2_EDGE_FAR_BITS-1:0] far32;
  always_comb begin
    if (tx > 0)
      far32 = P2_EDGE_FAR_BITS'({tx[FM-1:0], {P2_TILE_LOG2{1'b0}}});
    else if (tx < 0 && tx[FM-1:0] == '0)
      far32 = P2_EDGE_FAR_BITS'(1) << WB;
    else
      far32 = '0;
  end

  logic signed [P2_FP_XW-1:0] zsh;
  assign zsh = d - P2_FP_XW'(ZERO_SHIFT - 1);

  always_comb begin
    e          = '0;
    e.const_v  = const_v;
    e.const_in = const_in;
    e.t0       = t0;
    e.tx       = tx;
    e.ty       = ty;
    e.zsh      = zsh[P2_EDGE_ZSH_BITS-1:0];
    e.big      = cut;
    e.far32    = far32;
  end
endmodule

// p2_isp_edge_row: one edge's row stage and its 32 lanes: the inside mask of tile row j (ARCHITECTURE 3.4.5 "edge lanes",
// "the big-edge walk"; isp 8.4a, 8.4b, 8.5; refcore pvr_isp_edge.h InsideOrdinary L306, RowMask L322, Walk L397,
// Inside L440 at refsw3 4f3efe15). Every value is on the edge's one grid, in half units of 2^unit (2^102 for a big
// edge): the lanes take a base and decide with the step tx and the threshold z = zero2 = 2^zsh.
//
// Row stage, r = t0 + j ty (the raster's accumulator):
//   constant edge:  the edge's answer for every pixel
//   ordinary edge:  |r| <= zero2: the whole row by (|tx| <= tie2 ? ty > 0 : tx > 0) (the row-zero rule, covmeas rule 6);
//                   else lanes(r)
//   big edge (the walk, H = 2^30 = 2^131, Z = zero2 = 2^7 = 2^108):
//     rw = r wrapped into [-H, H): r's low 31 bits read as two's complement (R wraps by 2^132 [hugepos_rules pages 0-3;
//          faredge_m131 page 11; faredge_walk pages 8-11])
//     above = rw + far32 > Z: the far value above ZERO, not 0 [edge2_walk pages 3-5: 12 tiles]; far32 from p2_edge_t
//          [edge2_walk pages 0-2, edge2_end, edge2_mult]
//     dead (an earlier row ended the edge): no pixel; else
//     |rw| <= Z:                     rw == r ? the ordinary row-zero rule : (tx > 0 ? all : tx == 0 ? ty > 0 : none)
//     tx == 0 or rw, tx of one sign: rw == r ? lanes(r) : (rw > 0 ? all : none) [faredge K 127]
//     else mid = rw + 16 tx; mid outside [-H, H): lanes(rw + sign(rw) 2H) (the push [faredge_k132 group K; faredge_m131
//          pages 0-5: -2^131 exactly not pushed, +2^131 pushed]); else lanes(rw)
//     ends: not the walk's first row, the row before above and this one not: every later row outside [faredge_m131
//          pages 6-15; hugepos_rules page 11; faredge_walk pages 4-7; from the polygon's first row: faredge_walk 1,351]
// Lane i (0 .. 31), v_i = base + i tx: v > z inside; v < -z outside; in the zone, column 31 by tx > 0 (lastColumnByStep),
// else inside when the next pixel's value v + tx >= -z (covmeas rules 7, 8).
// The widths: every value below 2^33 in size (isp 8.5; the testbench asserts it on refsw3's values). Combinational.
module p2_isp_edge_row
  import p2_hw_pkg::*;
  import p2_pkg::*;
(
  input  p2_edge_t                             e,
  input  logic signed [P2_EDGE_LANE_BITS-1:0]  r,          // t0 + j ty
  input  logic                                 first,      // j is the walk's first row (jf)
  input  logic                                 was_above,  // the walk's state from the rows before
  input  logic                                 dead,
  output logic [P2_TILE-1:0]                   mask,
  output logic                                 above,
  output logic                                 ends
);
  localparam int AW = P2_EDGE_LANE_BITS;
  // H = 2 << (walkExp - unit) half units of the big edge's unit 2^(blockMax - cutUnitBits) = 2^102: 2^30 (= 2^131)
  localparam int WB = P2_ISP_EDGE_WALK_EXP - (P2_ISP_EDGE_BLOCK_MAX - P2_ISP_EDGE_CUT_UNIT_BITS) + 1;
  typedef logic signed [AW-1:0] v_t;

  v_t z, tie, txw, tyw, hh, rw, farv, mid, base;
  logic force_v, force_in;

  assign z   = v_t'(1) <<< e.zsh;
  assign tie = v_t'(1) <<< (e.zsh + P2_EDGE_ZSH_BITS'(P2_ISP_EDGE_ZERO_SHIFT - P2_ISP_EDGE_TIE_SHIFT));
  assign txw = v_t'(e.tx);
  assign tyw = v_t'(e.ty);
  assign hh  = v_t'(1) <<< WB;
  // wrap(r): the low WB + 1 bits of r, sign-extended
  assign rw   = v_t'($signed(r[WB:0]));
  assign farv = rw + $signed({{(AW - P2_EDGE_FAR_BITS){1'b0}}, e.far32});
  assign mid  = rw + (txw <<< 4);
  assign above = farv > z;
  assign ends  = !first && was_above && !above;

  logic r_zero, rw_zero, wrapped, same, push, ord_zero;
  assign r_zero   = (r >= -z) && (r <= z);
  assign rw_zero  = (rw >= -z) && (rw <= z);
  assign wrapped  = rw != r;
  assign same     = (txw == 0) || ((rw > 0) == (txw > 0));
  assign push     = (mid >= hh) || (mid < -hh);
  // the ordinary row-zero rule (InsideOrdinary L309-310): a row that starts at zero takes the column step's sign, or the
  // row step's when the column step is within the tie threshold
  assign ord_zero = ((txw >= -tie) && (txw <= tie)) ? (tyw > 0) : (txw > 0);

  always_comb begin
    force_v  = 1'b1;
    force_in = 1'b0;
    base     = r;
    if (e.const_v)
      force_in = e.const_in;
    else if (!e.big) begin
      if (r_zero)
        force_in = ord_zero;
      else
        force_v = 1'b0;
    end else if (dead)
      force_in = 1'b0;
    else if (rw_zero)
      force_in = !wrapped ? ord_zero : (txw > 0) ? 1'b1 : (txw == 0) ? (tyw > 0) : 1'b0;
    else if (same) begin
      if (!wrapped)
        force_v = 1'b0;
      else
        force_in = rw > 0;
    end else begin
      force_v = 1'b0;
      if (push) begin
        if (rw > 0)
          base = rw + (hh <<< 1);
        else
          base = rw - (hh <<< 1);
      end else
        base = rw;
    end
  end

  // the 32 lanes: v_i = base + i tx (lane i reads v_i and v_(i+1); lane 31 has no next pixel)
  v_t v [P2_TILE];
  logic [P2_TILE-1:0] lanes;
  genvar i;
  generate
    for (i = 0; i < P2_TILE; i = i + 1) begin : g_v
      assign v[i] = base + v_t'(i) * txw;
    end
    for (i = 0; i < P2_TILE; i = i + 1) begin : g_lane
      if (i == P2_TILE - 1) begin : g_last
        assign lanes[i] = (v[i] > z) ? 1'b1 : (v[i] < -z) ? 1'b0 : (txw > 0);
      end else begin : g_mid
        assign lanes[i] = (v[i] > z) ? 1'b1 : (v[i] < -z) ? 1'b0 : (v[i + 1] >= -z);
      end
    end
  endgenerate

  assign mask = force_v ? {P2_TILE{force_in}} : lanes;
endmodule

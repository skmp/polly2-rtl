// p2_isp_edge_steps: an edge's steps from its coordinate differences, the part of EdgeTile::Setup between dx, dy and the
// tile (refcore pvr_isp_edge.h L193-194, L201-202 at refsw3 4f3efe15; isp 8.3; num 5.1). Shared by p2_isp_edge_line
// (M2's fixed-latency unit) and M4's p2_isp_setup, which reads dx and dy from its microprogram's registers.
//
//   steps    = sat(dx), sat(dy): a difference of 2^128 or more steps by +-2^127 [hugepos_v4, _v5, _v6, hugepos_cov,
//              hugepos_sw2, hugepos_rules page 8]
//   sy = cut20(sat(dx)), sx = cut20(-sat(dy))         the row and column steps, before the winding turns them
//                                                     [covmeas rule 4; EdgeHW::slopeBits]
//   ep = max(top(sat dx), top(sat dy)); ep_v = 0 when both are zero (refsw3's NoExp)
// Combinational.
module p2_isp_edge_steps
  import p2_hw_pkg::*;
  import p2_pkg::*;
  import p2_fp_pkg::*;
(
  input  p2_fp24_t                     dx,      // Sub(xa, xb), Sub(ya, yb): not saturated
  input  p2_fp24_t                     dy,
  output p2_fp20_t                     sx,
  output p2_fp20_t                     sy,
  output logic signed [P2_FP_XW-1:0]   ep,
  output logic                         ep_v
);
  p2_fp24_t dxs, dys;
  p2_isp_fsw #(.SAT(1'b1)) u_dxs (.i(dx), .o(dxs));
  p2_isp_fsw #(.SAT(1'b1)) u_dys (.i(dy), .o(dys));

  // sy = dx.cut(slopeBits), sx = (-dy).cut(slopeBits) (L201)
  p2_fp_cut #(.IW(P2_FP24_MANT_BITS), .N(P2_ISP_EDGE_SLOPE_BITS)) u_sy (
    .i_neg(dxs.neg), .i_bad(dxs.bad), .i_exp(dxs.exp), .i_mant(dxs.mant),
    .o_neg(sy.neg), .o_bad(sy.bad), .o_exp(sy.exp), .o_mant(sy.mant));
  p2_fp_cut #(.IW(P2_FP24_MANT_BITS), .N(P2_ISP_EDGE_SLOPE_BITS)) u_sx (
    .i_neg(!dys.neg), .i_bad(dys.bad), .i_exp(dys.exp), .i_mant(dys.mant),
    .o_neg(sx.neg), .o_bad(sx.bad), .o_exp(sx.exp), .o_mant(sx.mant));

  // ep = max(top dx, top dy) (L202), on the saturated steps
  localparam int NW = $clog2(P2_FP24_MANT_BITS + 1);
  logic [NW-1:0]              nx, ny;
  logic signed [P2_FP_XW-1:0] tx, ty;
  p2_fp_lzc #(.W(P2_FP24_MANT_BITS), .NW(NW)) u_bx (.v(dxs.mant), .n(nx));
  p2_fp_lzc #(.W(P2_FP24_MANT_BITS), .NW(NW)) u_by (.v(dys.mant), .n(ny));
  assign tx = p2_fp_xw(dxs.exp) + $signed({{(P2_FP_XW - NW){1'b0}}, nx});
  assign ty = p2_fp_xw(dys.exp) + $signed({{(P2_FP_XW - NW){1'b0}}, ny});

  always_comb begin
    ep_v = (dxs.mant != '0) || (dys.mant != '0);
    if (dxs.mant == '0)
      ep = ty;
    else if (dys.mant == '0)
      ep = tx;
    else
      ep = (tx > ty) ? tx : ty;
  end

endmodule

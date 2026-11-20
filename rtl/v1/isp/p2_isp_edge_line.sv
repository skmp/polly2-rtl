// p2_isp_edge_line: the part of EdgeTile::Setup that does not depend on the tile, per edge a -> b (refcore
// pvr_isp_edge.h L183-203 at refsw3 4f3efe15; isp 8.3; num 5.1: "c, dx and dy do not depend on the tile").
//
//   c        = sw(Sub(sw(xb ya), sw(xa yb)))          the constant from absolute coordinates [covmeas rule 1]
//   dx, dy   = Sub(xa, xb), Sub(ya, yb)
//   dxP, dyP = sw(dx), sw(dy)                         for the start's products (p2_isp_edge_block)
//   steps    = sat(dx), sat(dy): a difference of 2^128 or more steps by +-2^127 [hugepos_v4, _v5, _v6, hugepos_cov,
//              hugepos_sw2, hugepos_rules page 8]
//   sy = cut20(sat(dx)), sx = cut20(-sat(dy))         the row and column steps, before the winding turns them
//                                                     [covmeas rule 4; EdgeHW::slopeBits]
//   ep = max(top(sat dx), top(sat dy)); ep_v = 0 when both are zero (refsw3's NoExp)
//   bad      any of the four coordinates is bad (Setup's first test; unreachable behind p2_isp_edge_det's bad corner)
// Combinational.
module p2_isp_edge_line
  import p2_hw_pkg::*;
  import p2_pkg::*;
  import p2_fp_pkg::*;
(
  input  p2_fp24_t                     xa,
  input  p2_fp24_t                     ya,
  input  p2_fp24_t                     xb,
  input  p2_fp24_t                     yb,
  output p2_fp24_t                     c,
  output p2_fp24_t                     dxp,
  output p2_fp24_t                     dyp,
  output p2_fp20_t                     sx,
  output p2_fp20_t                     sy,
  output logic signed [P2_FP_XW-1:0]   ep,
  output logic                         ep_v,
  output logic                         bad
);
  p2_fp24_t dx, dy;

  // c = sw(Sub(sw(Mul(xb, ya)), sw(Mul(xa, yb)))) (L184-185)
  p2_isp_edge_cross u_c (.a1(xb), .b1(ya), .a2(xa), .b2(yb), .o(c));
  // dx = Sub(xa, xb), dy = Sub(ya, yb) (L191)
  p2_isp_fadd u_dx (.a(xa), .b(xb), .sub(1'b1), .o(dx));
  p2_isp_fadd u_dy (.a(ya), .b(yb), .sub(1'b1), .o(dy));
  // dxP, dyP (L192); the steps saturated (L193-194)
  p2_isp_fsw #(.SAT(1'b0)) u_dxp (.i(dx), .o(dxp));
  p2_isp_fsw #(.SAT(1'b0)) u_dyp (.i(dy), .o(dyp));
  // the steps (p2_isp_edge_steps, shared with M4's p2_isp_setup)
  p2_isp_edge_steps u_steps (.dx(dx), .dy(dy), .sx(sx), .sy(sy), .ep(ep), .ep_v(ep_v));

  assign bad = xa.bad | ya.bad | xb.bad | yb.bad;
endmodule

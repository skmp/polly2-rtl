// p2_isp_edge_block: the per-tile part of EdgeTile::Setup for one edge, into p2_edge_t (refcore pvr_isp_edge.h L195-293
// at refsw3 4f3efe15; isp 8.3, 8.5; ARCHITECTURE 2.4, 3.4.4 step 4; num 5.1).
//
//   x0, y0  = FromHalves(x0h), FromHalves(y0h): the tile's first sample point (2 left + HALF_OFFSET[0])
//   first   = sw(Add(sw(dxP y0), -sw(dyP x0)))   [covmeas rule 3: the dropped operand; faredge_cmax]
//   start   = sat(Add(first, c))                 saturated to +-2^127 at 2^128 [faredge_cmax 4,800 of 4,800; hugepos a]
//   then the blocking, p2_isp_edge_fin (s20 and the turn, E, the grid, t0, tx, ty, zsh, far32, the constant tiles): one copy
//   shared with M4's microprogrammed p2_isp_setup
// The values fit p2_edge_t's widths wherever the edge is not constant (isp 8.5). Combinational.
module p2_isp_edge_block
  import p2_hw_pkg::*;
  import p2_pkg::*;
  import p2_fp_pkg::*;
(
  input  p2_fp24_t                     c,
  input  p2_fp24_t                     dxp,
  input  p2_fp24_t                     dyp,
  input  p2_fp20_t                     sx,      // cut20(-sat(dy)), not turned
  input  p2_fp20_t                     sy,      // cut20(sat(dx)), not turned
  input  logic signed [P2_FP_XW-1:0]   ep,
  input  logic                         ep_v,
  input  logic                         bad,
  input  logic                         flip,    // sgn < 0: turn the start and the steps
  input  logic [11:0]                  x0h,     // the tile's first sample point in half pixels
  input  logic [11:0]                  y0h,
  output p2_edge_t                     e
);
  // the tile's first sample point: FromHalves(k) = {k < 0, |k|, -1}
  p2_fp24_t x0, y0;
  always_comb begin
    x0      = '0;
    x0.exp  = P2_FP_EW'(0) - P2_FP_EW'(1);
    x0.mant = P2_FP24_MANT_BITS'(x0h);
    y0      = '0;
    y0.exp  = P2_FP_EW'(0) - P2_FP_EW'(1);
    y0.mant = P2_FP24_MANT_BITS'(y0h);
  end

  // first = sw(Add(sw(Mul(dxP, y0)), -sw(Mul(dyP, x0)))) (L197); start = Add(first, c) saturated (L198-200)
  p2_fp24_t p0, p1, q0, q1, f, first, st, start;
  p2_isp_fmul u_m0 (.a(dxp), .b(y0), .o(p0));
  p2_isp_fmul u_m1 (.a(dyp), .b(x0), .o(p1));
  p2_isp_fsw #(.SAT(1'b0)) u_s0 (.i(p0), .o(q0));
  p2_isp_fsw #(.SAT(1'b0)) u_s1 (.i(p1), .o(q1));
  p2_isp_fadd u_f (.a(q0), .b(q1), .sub(1'b1), .o(f));
  p2_isp_fsw #(.SAT(1'b0)) u_sf (.i(f), .o(first));
  p2_isp_fadd u_st (.a(first), .b(c), .sub(1'b0), .o(st));
  p2_isp_fsw #(.SAT(1'b1)) u_ss (.i(st), .o(start));

  // the blocking (p2_isp_edge_fin, shared with M4's p2_isp_setup)
  p2_isp_edge_fin u_fin (.start(start), .sx(sx), .sy(sy), .ep(ep), .ep_v(ep_v), .bad(bad), .flip(flip), .e(e));
endmodule

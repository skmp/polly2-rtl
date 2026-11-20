// p2_isp_edge_setup: the ISP edge setup datapath as a fixed-latency unit (PLAN M2; ARCHITECTURE 3.4.4 steps 1-5, 2.4
// p2_edge_t; isp 7.1, 7.2, 8.1-8.3, 8.6 at refsw3 4f3efe15). One (primitive, tile) pair a clock in, its result LAT = 2
// clocks later; no back-pressure. M4's microprogrammed p2_isp_setup replaces the datapath's sequencing (the scheduler
// shares the products); the functions are these.
//
//   stage A (combinational on the inputs, registered into s1): the corners as FromBits (num H4: a denormal kept, an
//     infinity or a NaN bad and unsigned); p2_isp_edge_det (bad corners, the swamped determinant, the winding, the
//     culls); per edge p2_isp_edge_line (c, dx, dy and the steps: they do not depend on the tile); p2_isp_rowrange
//   stage B (registered into the outputs): per edge p2_isp_edge_block (the tile's start, E, the grid, the blocking into
//     p2_edge_t); the row range in the tile (the row-31 shift, jf, jl, rows_v)
//
// Edges (isp 8.1; refsw_tile.cpp L800-804): E12 = 1 -> 2, E23 = 2 -> 3, E31 = 3 -> 1 for a triangle or 3 -> 4 for a quad,
// E41 = 4 -> 1 (quads only; a triangle's edge 3 is a constant inside). Every edge is turned with the winding of corners
// 1-3 [covmeas sprite14, sprite15]. The edge fields of a bad or culled primitive are computed all the same (the caller
// decides: ARCHITECTURE 3.4.4 step 8).
module p2_isp_edge_setup
  import p2_pkg::*;
  import p2_fp_pkg::*;
(
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         in_v,
  input  logic [3:0][31:0]             x_bits,        // the corners' x, y as IEEE singles, rasterizer order; corner 4
  input  logic [3:0][31:0]             y_bits,        // read for a quad only
  input  logic                         quad,
  input  logic                         modvol,        // RM_MODIFIER: no row range, no row-31 shift
  input  logic [1:0]                   cull_mode,     // ISP_TSP CullMode
  input  logic [31:0]                  fpu_cull_val,  // FPU_CULL_VAL
  input  logic                         half,          // HALF_OFFSET[0] (fpu_pixel_half_offset): sample at pixel centres
  input  logic [5:0]                   tile_x,
  input  logic [5:0]                   tile_y,
  output logic                         out_v,
  output logic                         bad,           // a corner is an infinity or a NaN: nothing drawn, nothing culled
  output logic                         culled,
  output logic                         flip,          // the winding: sgn < 0 (the determinant >= 0)
  output p2_fp24_t                     det,           // EdgeWinding's swamped determinant
  output p2_edge_t [3:0]               edges,
  output logic [P2_TILE_LOG2-1:0]      jf,
  output logic [P2_TILE_LOG2-1:0]      jl,
  output logic                         rows_v
);
  localparam int RW = 42;

  // ---------------------------------------------------------------------------------------------------------- stage A
  p2_fp24_t [3:0] fx, fy;
  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_in
      p2_fp_in_single u_x (.u(x_bits[g]), .ranged(1'b0), .o_neg(fx[g].neg), .o_bad(fx[g].bad), .o_exp(fx[g].exp),
        .o_mant(fx[g].mant));
      p2_fp_in_single u_y (.u(y_bits[g]), .ranged(1'b0), .o_neg(fy[g].neg), .o_bad(fy[g].bad), .o_exp(fy[g].exp),
        .o_mant(fy[g].mant));
    end
  endgenerate

  logic     a_bad, a_flip, a_culled;
  p2_fp24_t a_det;
  p2_isp_edge_det u_det (.x(fx), .y(fy), .quad(quad), .cull_mode(cull_mode), .fpu_cull_val(fpu_cull_val),
    .bad(a_bad), .det(a_det), .flip(a_flip), .culled(a_culled));

  // the edges' corners: a = k, b = k + 1; the third edge ends at corner 4 of a quad, corner 1 of a triangle
  p2_fp24_t [3:0] a_c, a_dxp, a_dyp;
  p2_fp20_t [3:0] a_sx, a_sy;
  logic signed [3:0][P2_FP_XW-1:0] a_ep;
  logic [3:0] a_ep_v, a_ebad;
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_line
      p2_fp24_t xb, yb;
      if (g == 2) begin : g_third
        assign xb = quad ? fx[3] : fx[0];
        assign yb = quad ? fy[3] : fy[0];
      end else begin : g_other
        assign xb = fx[(g + 1) % 4];
        assign yb = fy[(g + 1) % 4];
      end
      p2_isp_edge_line u_line (.xa(fx[g]), .ya(fy[g]), .xb(xb), .yb(yb), .c(a_c[g]), .dxp(a_dxp[g]), .dyp(a_dyp[g]),
        .sx(a_sx[g]), .sy(a_sy[g]), .ep(a_ep[g]), .ep_v(a_ep_v[g]), .bad(a_ebad[g]));
    end
  endgenerate

  logic signed [RW-1:0] a_rf, a_rl;
  p2_isp_rowrange #(.RW(RW)) u_rows (.y(fy), .quad(quad), .row_first(a_rf), .row_last(a_rl));

  // ------------------------------------------------------------------------------------------------------------ s1
  logic                            s1_v, s1_bad, s1_flip, s1_culled, s1_quad, s1_modvol, s1_half;
  p2_fp24_t                        s1_det;
  p2_fp24_t [3:0]                  s1_c, s1_dxp, s1_dyp;
  p2_fp20_t [3:0]                  s1_sx, s1_sy;
  logic signed [3:0][P2_FP_XW-1:0] s1_ep;
  logic [3:0]                      s1_ep_v, s1_ebad;
  logic signed [RW-1:0]            s1_rf, s1_rl;
  logic [5:0]                      s1_tx, s1_ty;

  always_ff @(posedge clk) begin
    if (rst)
      s1_v <= 1'b0;
    else
      s1_v <= in_v;
    s1_bad    <= a_bad;
    s1_flip   <= a_flip;
    s1_culled <= a_culled;
    s1_det    <= a_det;
    s1_quad   <= quad;
    s1_modvol <= modvol;
    s1_half   <= half;
    s1_c      <= a_c;
    s1_dxp    <= a_dxp;
    s1_dyp    <= a_dyp;
    s1_sx     <= a_sx;
    s1_sy     <= a_sy;
    s1_ep     <= a_ep;
    s1_ep_v   <= a_ep_v;
    s1_ebad   <= a_ebad;
    s1_rf     <= a_rf;
    s1_rl     <= a_rl;
    s1_tx     <= tile_x;
    s1_ty     <= tile_y;
  end

  // ---------------------------------------------------------------------------------------------------------- stage B
  // the tile's first sample point in half pixels: 2 left + HALF_OFFSET[0] (refsw_tile.cpp L797-798)
  logic [11:0] x0h, y0h;
  assign x0h = {s1_tx, 5'b0, s1_half};
  assign y0h = {s1_ty, 5'b0, s1_half};

  p2_edge_t [3:0] b_e;
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_block
      p2_edge_t eb;
      p2_isp_edge_block u_block (.c(s1_c[g]), .dxp(s1_dxp[g]), .dyp(s1_dyp[g]), .sx(s1_sx[g]), .sy(s1_sy[g]),
        .ep(s1_ep[g]), .ep_v(s1_ep_v[g]), .bad(s1_ebad[g]), .flip(s1_flip), .x0h(x0h), .y0h(y0h), .e(eb));
      if (g == 3) begin : g_fourth
        // a triangle has no fourth edge: inside everywhere
        p2_edge_t e4;
        always_comb begin
          e4 = eb;
          if (!s1_quad) begin
            e4.const_v  = 1'b1;
            e4.const_in = 1'b1;
          end
        end
        assign b_e[g] = e4;
      end else begin : g_edge
        assign b_e[g] = eb;
      end
    end
  endgenerate

  // the row range in the tile, with the row-31 shift (p2_isp_rowclip, shared with M4's p2_isp_setup)
  logic [P2_TILE_LOG2-1:0] b_jf, b_jl;
  logic                    b_rows_v;
  logic b_big_any;
  assign b_big_any = $signed(s1_ep[0]) >= 124 || $signed(s1_ep[1]) >= 124 || $signed(s1_ep[2]) >= 124 ||
                     (s1_quad && $signed(s1_ep[3]) >= 124);
  p2_isp_rowclip #(.RW(RW)) u_clip (.row_first(s1_rf), .row_last(s1_rl), .tile_y(s1_ty), .modvol(s1_modvol),
    .big_any(b_big_any), .jf(b_jf), .jl(b_jl), .rows_v(b_rows_v));

  always_ff @(posedge clk) begin
    if (rst)
      out_v <= 1'b0;
    else
      out_v <= s1_v;
    bad    <= s1_bad;
    culled <= s1_culled;
    flip   <= s1_flip;
    det    <= s1_det;
    edges  <= b_e;
    jf     <= b_jf;
    jl     <= b_jl;
    rows_v <= b_rows_v;
  end
endmodule

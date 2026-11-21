// p2_isp_raster: the row stepper, 32 lanes, one tile row a clock (PLAN M4; ARCHITECTURE 3.4.5; isp 8.4-8.6, 9.4a, 9.5,
// 9.6; refcore refsw_tile.cpp RasterizeTriangle's row loop L849-860, pvr_isp_edge.h EdgeTile::Inside / Walk /
// SetFirstRow, pvr_isp_depth.h DepthTileT::At at refsw3 4f3efe15). It joins M2's edge raster and M3's depth raster under
// one descriptor (p2_rdesc_t, from p2_isp_setup's hand-off) and one row counter; the per-edge row stage and walk
// (p2_isp_edge_row) and the depth lanes (p2_isp_depth_lane) are theirs.
//
// A descriptor is taken when rd_v && rd_rdy; one with rows_v = 0 has no row and is dropped. Its rows jf .. jl (all 32 for
// a MODIFIER triangle and a kill descriptor: p2_isp_setup sets them) go out in order, one a clock, as row_v / row_j /
// in_mask / zk with row_last on the last and the descriptor's tag, rm, depth_mode, zwdis, sum_op beside them; out_rdy = 0
// holds the row (nothing changes). rd_rdy is high when idle or with the last row going out, so that descriptors follow
// each other without a gap: a triangle costs max(its setup program, its rows) behind the 1-deep hand-off
// [M tim 3.2: "+1 a line per triangle past 16 lines"; quad 32 x 32: 64].
//   edges   per edge r = t0 + j ty, a 34-bit accumulator set at the take to t0 + jf ty and stepped by ty a row; the walk's
//           state (above in the row before, dead) starts at jf, the polygon's first row in the tile (SetFirstRow; 0 for
//           MODIFIER): the rows before it are never stepped, so the state depends only on the rows stepped
//   mask    the AND of the four edges' masks (a triangle's fourth is a constant inside), 0 with kill (3.4.4 step 8)
//   depth   BLOCK and REG are a row base plus lane offsets on one 30-bit accumulator: v_i = base_j + i sx,
//           base_j = base_0 + j sy, BLOCK base_0 = S, sx = 2 DX, sy = 2 DY (half units of G); REG base_0 = r0,
//           sx = sa 2^25 + fa, sy = sb 2^25 + fb (mod 2^30); set at the take to base_0 + jf sy; CONST the key
module p2_isp_raster
  import p2_pkg::*;
  import p2_regs_pkg::*;
(
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         rd_v,
  output logic                         rd_rdy,
  input  p2_rdesc_t                    rd,
  output logic                         row_v,
  input  logic                         out_rdy,
  output logic [P2_TILE_LOG2-1:0]      row_j,
  output logic [P2_TILE-1:0]           in_mask,
  output p2_zkey_t [P2_TILE-1:0]       zk,
  output logic                         row_last,
  // the descriptor's fields for p2_isp_pix
  output p2_tag_t                      row_tag,
  output p2_rm_t                       row_rm,
  output logic [2:0]                   row_depth_mode,
  output logic                         row_zwdis,
  output p2_sum_op_t                   row_sum_op,
  // no descriptor being stepped and no row in the output register (p2_isp_ctl's walk end, M6)
  output logic                         idle
);
  localparam int AW = P2_EDGE_LANE_BITS;
  localparam int TW = P2_ZT_T_BITS;
  typedef logic signed [AW-1:0] e_t;
  typedef logic signed [TW-1:0] z_t;

  // ---------------------------------------------------------------------------------------------- the row counter
  logic                    act;
  logic [P2_TILE_LOG2-1:0] j, jl;
  logic                    adv, last, take;
  assign adv    = act && (!row_v || out_rdy);
  assign last   = j == jl;
  assign rd_rdy = !act || (adv && last);
  assign take   = rd_v && rd_rdy && rd.rows_v;
  assign idle   = !act && !row_v;

  // the descriptor's fields that ride with the rows
  logic        kill;
  p2_tag_t     d_tag;
  p2_rm_t      d_rm;
  logic [2:0]  d_dm;
  logic        d_zw;
  p2_sum_op_t  d_sum;

  // ---------------------------------------------------------------------------------------------- the edges
  p2_edge_t [3:0] ed;
  e_t         r [4];
  logic [3:0] was_above, dead;
  logic       wfirst;          // this row is the walk's first (jf: the polygon's first row in the tile)

  logic [3:0][P2_TILE-1:0] m;
  logic [3:0]              ab, en;
  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_edge
      p2_isp_edge_row u_row (.e(ed[g]), .r(r[g]), .first(wfirst), .was_above(was_above[g]), .dead(dead[g]),
        .mask(m[g]), .above(ab[g]), .ends(en[g]));
    end
  endgenerate

  // t0 + jf ty at the take
  e_t r0 [4];
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_r0
      assign r0[g] = e_t'(rd.edges[g].t0) + e_t'(rd.edges[g].ty) * e_t'({1'b0, rd.jf});
    end
  endgenerate

  // ---------------------------------------------------------------------------------------------- the depth
  p2_zregime_t                      zd_regime;
  p2_zkey_t                         zd_key;
  logic signed [9:0]                zd_gexp;
  logic signed [8:0]                zd_e;
  logic signed [P2_ZT_NSH_BITS-1:0] zd_nsh;
  logic                             zd_fbw;
  z_t                               base, sx, sy;

  z_t in_base, in_sx, in_sy, in_base_jf;
  always_comb begin
    if (rd.z.regime == P2_Z_REG) begin
      in_base = z_t'(rd.z.r0);
      in_sx   = z_t'(rd.z.sa) * z_t'(32'sd33554432) + z_t'(rd.z.fa);
      in_sy   = z_t'(rd.z.sb) * z_t'(32'sd33554432) + z_t'(rd.z.fb);
    end else begin
      in_base = z_t'(rd.z.S);
      in_sx   = z_t'(rd.z.DX) * z_t'(2);
      in_sy   = z_t'(rd.z.DY) * z_t'(2);
    end
    in_base_jf = in_base + in_sy * z_t'({1'b0, rd.jf});
  end

  p2_zkey_t [P2_TILE-1:0] k;
  generate
    for (g = 0; g < P2_TILE; g = g + 1) begin : g_lane
      z_t vi;
      assign vi = base + sx * z_t'(g);
      p2_isp_depth_lane u_lane (.regime(zd_regime), .v(vi), .gexp(zd_gexp), .e(zd_e), .nsh(zd_nsh), .fbw(zd_fbw),
        .key_c(zd_key), .key(k[g]));
    end
  endgenerate

  // ---------------------------------------------------------------------------------------------- the stepper
  always_ff @(posedge clk) begin
    if (rst) begin
      act   <= 1'b0;
      row_v <= 1'b0;
    end else begin
      if (adv) begin
        row_v          <= 1'b1;
        row_j          <= j;
        in_mask        <= kill ? '0 : (m[0] & m[1] & m[2] & m[3]);
        zk             <= k;
        row_last       <= last;
        row_tag        <= d_tag;
        row_rm         <= d_rm;
        row_depth_mode <= d_dm;
        row_zwdis      <= d_zw;
        row_sum_op     <= d_sum;
        j              <= j + 1'b1;
        wfirst         <= 1'b0;
        base           <= base + sy;
        for (int q = 0; q < 4; q++) begin
          r[q] <= r[q] + e_t'(ed[q].ty);
          if (!dead[q]) begin
            was_above[q] <= ab[q];
            if (en[q])
              dead[q] <= 1'b1;
          end
        end
        if (last)
          act <= 1'b0;
      end else if (out_rdy)
        row_v <= 1'b0;
      if (take) begin
        act       <= 1'b1;
        // the rows from jf: the polygon's first row in the tile (0 for MODIFIER and kill)
        j         <= rd.jf;
        jl        <= rd.jl;
        kill      <= rd.kill;
        d_tag     <= rd.tag;
        d_rm      <= rd.rm;
        d_dm      <= rd.depth_mode;
        d_zw      <= rd.zwdis;
        d_sum     <= rd.sum_op;
        ed        <= rd.edges;
        was_above <= '0;
        wfirst    <= 1'b1;
        dead      <= '0;
        for (int q = 0; q < 4; q++)
          r[q] <= r0[q];
        zd_regime <= rd.z.regime;
        zd_key    <= rd.z.key;
        zd_gexp   <= rd.z.gexp;
        zd_e      <= rd.z.E;
        zd_nsh    <= rd.z.nsh;
        zd_fbw    <= rd.z.fbw;
        base      <= in_base_jf;
        sx        <= in_sx;
        sy        <= in_sy;
      end
    end
  end
endmodule

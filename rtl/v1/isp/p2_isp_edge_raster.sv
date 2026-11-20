// p2_isp_edge_raster: the edge half of p2_isp_raster, the row stepper: one tile row a clock, the inside mask of the
// primitive (ARCHITECTURE 3.4.5; isp 8.4, 8.6; refcore refsw_tile.cpp RasterizeTriangle's row loop L849-860,
// pvr_isp_edge.h EdgeTile::Inside, Walk, SetFirstRow at refsw3 4f3efe15). The depth lanes join it in M3.
//
// A descriptor (the edges of one primitive in one tile, its rows jf .. jl, kill) is taken when in_v && in_rdy; one with
// rows_v = 0 has no row and is dropped. Its rows go out in order, one a clock, each as row_v / row_j / in_mask with
// row_last on the last; out_rdy = 0 holds the row (nothing changes). in_rdy is high when idle or with the last row
// going out, so that descriptors follow each other without a gap.
//   per edge: r = t0 + j ty, a 34-bit accumulator set at the take to t0 + jf ty and stepped by ty a row; the walk's
//             state (above in the row before, dead) starts at jf, the polygon's first row in the tile (SetFirstRow;
//             0 for MODIFIER): the rows before it are never stepped, so the state depends only on the rows stepped
//   in_mask = AND of the four edges' masks (a triangle's fourth is a constant inside), 0 with kill
//             (ARCHITECTURE 3.4.4 step 8)
// The mask equals refsw3's Inside(i, j) of all edges on every row of the range [covmeas 115 sets; faredge*, hugepos*,
// edge2_* pages' own triangles; tb/isp_edge].
module p2_isp_edge_raster
  import p2_pkg::*;
(
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         in_v,
  output logic                         in_rdy,
  input  p2_edge_t [3:0]               in_edges,
  input  logic [P2_TILE_LOG2-1:0]      in_jf,
  input  logic [P2_TILE_LOG2-1:0]      in_jl,
  input  logic                         in_rows_v,
  input  logic                         in_kill,
  output logic                         row_v,
  input  logic                         out_rdy,
  output logic [P2_TILE_LOG2-1:0]      row_j,
  output logic [P2_TILE-1:0]           in_mask,
  output logic                         row_last
);
  localparam int AW = P2_EDGE_LANE_BITS;
  typedef logic signed [AW-1:0] v_t;

  logic                    act, kill;
  logic [P2_TILE_LOG2-1:0] j, jl;
  p2_edge_t [3:0]          ed;
  v_t                      r [4];
  logic [3:0]              was_above, dead;
  logic                    wfirst;          // this row is the walk's first (jf: the polygon's first row in the tile)

  logic adv, last, take;
  assign adv    = act && (!row_v || out_rdy);
  assign last   = j == jl;
  assign in_rdy = !act || (adv && last);
  assign take   = in_v && in_rdy && in_rows_v;

  // the row stage and the lanes of each edge
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
  v_t r0 [4];
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_r0
      assign r0[g] = v_t'(in_edges[g].t0) + v_t'(in_edges[g].ty) * v_t'({1'b0, in_jf});
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      act   <= 1'b0;
      row_v <= 1'b0;
    end else begin
      if (adv) begin
        row_v    <= 1'b1;
        row_j    <= j;
        in_mask  <= kill ? '0 : (m[0] & m[1] & m[2] & m[3]);
        row_last <= last;
        j        <= j + 1'b1;
        wfirst   <= 1'b0;
        for (int k = 0; k < 4; k++) begin
          r[k] <= r[k] + v_t'(ed[k].ty);
          if (!dead[k]) begin
            was_above[k] <= ab[k];
            if (en[k])
              dead[k] <= 1'b1;
          end
        end
        if (last)
          act <= 1'b0;
      end else if (out_rdy)
        row_v <= 1'b0;
      if (take) begin
        act       <= 1'b1;
        kill      <= in_kill;
        j         <= in_jf;
        jl        <= in_jl;
        ed        <= in_edges;
        was_above <= '0;
        wfirst    <= 1'b1;
        dead      <= '0;
        for (int k = 0; k < 4; k++)
          r[k] <= r0[k];
      end
    end
  end
endmodule

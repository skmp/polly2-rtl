// p2_isp_rowclip: the rows of one tile a polygon is stepped on (refcore refsw_tile.cpp RasterizeTriangle L819-847,
// pvr_isp_edge.h EdgeTile::SetFirstRow L297 at refsw3 4f3efe15; isp 8.6; ARCHITECTURE 2.4 jf / jl / rows_v, 3.4.4 step 5),
// from the polygon's row range (p2_isp_rowrange). Shared by M2's p2_isp_edge_setup and M4's p2_isp_setup. Combinational.
//
// the row range in the tile, with the row-31 shift (refsw_tile.cpp RasterizeTriangle L819-847, pvr_isp_edge.h
// EdgeTile::SetFirstRow L297; isp 8.6; ARCHITECTURE 2.4 jf / jl / rows_v, 3.4.4 step 5)
//   not MODIFIER: a polygon whose first row is the tile's row 31 starts at row 30 in that tile, every polygon
//                 [faredge_walk pages 0-3: 366 of 3,537 tiles wrong without; faredge_far32 390 against 0; edge2_walk
//                 page 6: 43 tiles wrong with the shift for big edges only (6784ea3d), 0 for every polygon;
//                 edge2_row31 300 of 300: the user tile clip has no part]; then rows_v = some row of the tile is in
//                 first .. last, jf / jl the range clipped to 0 .. 31. jf is also where a big edge's walk starts
//                 (SetFirstRow: the first row clamped to 0 .. 31).
//   MODIFIER:     no range and no shift: rows 0 .. 31, the walk from row 0 [covmeas sliver36].
module p2_isp_rowclip
  import p2_pkg::*;
#(
  parameter int RW = 42
) (
  input  logic signed [RW-1:0]     row_first,   // RowRange's first and last row (screen rows)
  input  logic signed [RW-1:0]     row_last,
  input  logic [5:0]               tile_y,
  input  logic                     modvol,      // RM_MODIFIER: no range, no shift
  // some edge of the polygon has a step of 2^124 or more (ep >= 124): read by no rule since 4f3efe15 (the shift is for
  // every polygon); the hook of 6784ea3d's rule, tb/isp_edge/mutants.txt row31-big-only
  input  logic                     big_any,
  output logic [P2_TILE_LOG2-1:0]  jf,
  output logic [P2_TILE_LOG2-1:0]  jl,
  output logic                     rows_v
);
  logic signed [RW-1:0]    b_top, b_rf, b_rl;
  logic [P2_TILE_LOG2-1:0] b_jf, b_jl;
  logic                    b_rows_v;
  assign b_top = $signed({{(RW - 6 - P2_TILE_LOG2){1'b0}}, tile_y, {P2_TILE_LOG2{1'b0}}});
  always_comb begin
    b_rf = row_first - b_top;
    b_rl = row_last - b_top;
    if (b_rf == RW'(P2_TILE) - RW'(1))
      b_rf = b_rf - RW'(1);
    if (modvol) begin
      b_jf     = '0;
      b_jl     = '1;
      b_rows_v = 1'b1;
    end else begin
      b_rows_v = (b_rf <= RW'(P2_TILE) - RW'(1)) && (b_rl >= RW'(0));
      b_jf     = (b_rf < 0) ? '0 : (b_rf > RW'(P2_TILE) - RW'(1)) ? '1 : b_rf[P2_TILE_LOG2-1:0];
      b_jl     = (b_rl < 0) ? '0 : (b_rl > RW'(P2_TILE) - RW'(1)) ? '1 : b_rl[P2_TILE_LOG2-1:0];
    end
  end

  assign jf     = b_jf;
  assign jl     = b_jl;
  assign rows_v = b_rows_v;
endmodule

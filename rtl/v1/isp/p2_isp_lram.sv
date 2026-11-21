// p2_isp_lram: one wide per-pixel field of p2_isp_buf (PLAN M7; ARCHITECTURE 3.4.7 "Storage and physical ports"):
// 32 rows x 32 lanes of W bits, one RAM per lane (conventions.md 4.2: one array per write lane), read and written a row
// at a time at one address.
//
//   write   we, w_row, w_lane (a lane enable each), w_data: at the clock's edge
//   read    re, r_row: the row's words the clock after (a registered read: a write and a read of one row in one clock
//           read the old words)
//   debug   sim only: dbg_row's words combinationally (the tile testbench's compare)
module p2_isp_lram
  import p2_pkg::*;
#(
  parameter int W = 64
) (
  input  logic                              clk,
  input  logic                              we,
  input  logic [P2_TILE_LOG2-1:0]           w_row,
  input  logic [P2_TILE-1:0]                w_lane,
  input  logic [P2_TILE-1:0][W-1:0]         w_data,
  input  logic                              re,
  input  logic [P2_TILE_LOG2-1:0]           r_row,
  output logic [P2_TILE-1:0][W-1:0]         q,
  input  logic [P2_TILE_LOG2-1:0]           dbg_row,
  output logic [P2_TILE-1:0][W-1:0]         dbg_q
);
  genvar g;
  generate
    for (g = 0; g < P2_TILE; g = g + 1) begin : g_lane
      logic [W-1:0] m [P2_TILE];
      always_ff @(posedge clk) begin
        if (we && w_lane[g])
          m[w_row] <= w_data[g];
        if (re)
          q[g] <= m[r_row];
      end
`ifndef SYNTHESIS
      assign dbg_q[g] = m[dbg_row];
`else
      assign dbg_q[g] = '0;
`endif
    end
  endgenerate
endmodule

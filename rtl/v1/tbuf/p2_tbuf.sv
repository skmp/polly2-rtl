// p2_tbuf: the two tile buffers (PLAN M11: the RAMs and the secondary port; M12 adds the controller: the actions on eoe,
// the write-out start, the DstSelect interlock, p2_tbuf_hs. ARCHITECTURE 3.9; tsp 17.1; refsw_tile.cpp colorBufferStore,
// colorBuffer1 / colorBuffer2, NextTileAccumulationBuffers, GetColorOutputBuffer at refsw3 4f3efe15).
//
//   two RAMs of 1024 x 32 bits (B, G, R, A; pixel y * 32 + x), never cleared [accbuf: keep-Z tiles show the tiles two,
//   four and six before]; `sel` says which is buffer 1 (the one being shaded); `swap` exchanges them
//   (NextTileAccumulationBuffers; driven by the testbench in M11, by the controller from M12)
//   each RAM has one read port and one write port (a simple dual-port macro):
//     buffer 1's read port: P10's (p2_pp_blend: buffer1[idx], the dst without DstSelect)
//     buffer 2's read port, the SECONDARY port, shared [I tim 3.10]: P10's address when P10 reads buffer 2 (SrcSelect for
//       src, DstSelect for dst), else the write-out's (wo_*); both take the data (a SrcSelect pixel during a write-out
//       damages the write-out's picture: accbuf page 7, blendpos)
//     writes: P10's, to either buffer
//   reads are registered: the data the clock after the address, in the reader's own register (P10's hold it while
//   its point is held; the write-out's)
// The debug port (dbg_*) is the testbench's: it loads the state a capture starts from (the reference's buffers) and
// reads every word back, by logical buffer (1 or 2), combinationally; it is not used while the pipe runs. It is
// simulation only (M12: `ifndef SYNTHESIS`; in synthesis its inputs are unused and its outputs 0), so that each RAM keeps
// its one write port and one read port.
// The swap is p2_tbuf_ctl's (M12), the controller of the actions on eoe.
// [Die: region 4, four macros of two sub-arrays each, the densest RAM; two buffers of 1024 x 32 here (8 KB in all), the
// sub-array split is not modelled (ARCHITECTURE 3.12).]
module p2_tbuf
  import p2_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     swap,
  output logic                     sel,        // 0: RAM 0 is buffer 1
  // P10 (p2_pp_blend)
  input  logic                     rd_en,
  input  logic [P2_PIX_BITS-1:0]   rd_idx,
  input  logic                     rd_b2,
  output logic [31:0]              rd_b1_data,
  output logic [31:0]              rd_b2_data,
  input  logic                     wr_en,
  input  logic                     wr_b2,
  input  logic [P2_PIX_BITS-1:0]   wr_idx,
  input  logic [31:0]              wr_data,
  // the write-out's read of buffer 2 (p2_wout, M12)
  input  logic                     wo_re,
  input  logic [P2_PIX_BITS-1:0]   wo_idx,
  output logic                     wo_gnt,
  output logic [31:0]              wo_data,
  // the testbench's debug port
  input  logic                     dbg_we,
  input  logic                     dbg_b2,
  input  logic [P2_PIX_BITS-1:0]   dbg_idx,
  input  logic [31:0]              dbg_wdata,
  output logic [31:0]              dbg_b1,
  output logic [31:0]              dbg_b2_data
);
  logic [31:0] ram0 [1024];
  logic [31:0] ram1 [1024];

  // the two read ports: RAM sel is buffer 1, RAM !sel buffer 2. One address a RAM a clock; the word goes to the register
  // of the reader that asked (P10's, held while its point is; the write-out's), so that a write-out read under a held P10
  // point does not take its word
  logic                   p2rd, wo0, wo1;
  logic [P2_PIX_BITS-1:0] ra0, ra1;
  logic [31:0]            qp0, qp1, qw;
  logic                   rp0, rp1;
  assign p2rd   = rd_en && rd_b2;
  assign wo_gnt = wo_re && !p2rd;
  assign rp0    = !sel ? rd_en : p2rd;            // P10 reads RAM 0
  assign rp1    = sel ? rd_en : p2rd;
  assign wo0    = sel && wo_gnt;                  // the write-out reads RAM 0 (buffer 2)
  assign wo1    = !sel && wo_gnt;
  assign ra0    = rp0 ? rd_idx : wo_idx;
  assign ra1    = rp1 ? rd_idx : wo_idx;
  always_ff @(posedge clk) begin
    if (rp0) qp0 <= ram0[ra0];
    if (rp1) qp1 <= ram1[ra1];
    if (wo0) qw <= ram0[ra0];
    if (wo1) qw <= ram1[ra1];
    if (wr_en && (wr_b2 ^ sel) == 1'b0) ram0[wr_idx] <= wr_data;
    if (wr_en && (wr_b2 ^ sel) == 1'b1) ram1[wr_idx] <= wr_data;
`ifndef SYNTHESIS
    if (dbg_we && (dbg_b2 ^ sel) == 1'b0) ram0[dbg_idx] <= dbg_wdata;
    if (dbg_we && (dbg_b2 ^ sel) == 1'b1) ram1[dbg_idx] <= dbg_wdata;
`endif
  end
  assign rd_b1_data = sel ? qp1 : qp0;
  assign rd_b2_data = sel ? qp0 : qp1;
  assign wo_data    = qw;

  always_ff @(posedge clk)
    if (rst) sel <= 1'b0;
    else if (swap) sel <= !sel;

`ifndef SYNTHESIS
  assign dbg_b1      = sel ? ram1[dbg_idx] : ram0[dbg_idx];
  assign dbg_b2_data = sel ? ram0[dbg_idx] : ram1[dbg_idx];
`else
  assign dbg_b1      = '0;
  assign dbg_b2_data = '0;
`endif
endmodule

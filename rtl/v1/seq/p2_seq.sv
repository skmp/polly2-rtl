// p2_seq: the tile sequencer (PLAN M12; ARCHITECTURE 3.3, 2.3 "Entry"): the region array, entry by entry, to p2_isp_ctl.
// Owns isp 3.1 and the walk part of isp 1 (refcore refsw_lists.cpp ReadRegionArrayEntry and RenderCORE's do-while at
// refsw3 4f3efe15).
//
//   `start` (STARTRENDER): the next entry is at REGION_BASE; entries are read in memory order, up to and including the
//   one with last_region (a do-while: the first entry is always read)
//   an entry is 6 words with FPU_PARAM_CFG[21] (region_header_type), else 5: control, OP, OP_MOD, TR, TR_MOD (, PT)
//   (ReadRegionArrayEntry). For 5-word entries the PT list is 0x80000000 (empty, pointer 0) and pre_sort is
//   ISP_FEED_CFG[0]; for 6-word entries pre_sort is the control word's bit 29
//   each list pointer: empty = bit 31, ptr = bits 23:2 (ListPointer)
// Structure: one 32-bit read a word through C0 (32-bit view, pvr_map32: vri); an entry's reads are issued back to back
// once there is room for it in the entry FIFO (SEQ_AHEAD entries [G: 2], ARCHITECTURE 6), its words collected in
// order, the entry pushed. [M tim 3.1: a tile with nothing to do costs 335 clk plus its write-out; this unit's share is
// the entry fetch latency, the split GAP T1.]
module p2_seq
  import p2_pkg::*;
#(
  parameter int SEQ_AHEAD = 2
) (
  input  logic          clk,
  input  logic          rst,
  input  logic          start,
  input  logic [31:0]   region_base,     // REGION_BASE
  input  logic [31:0]   fpu_param_cfg,   // FPU_PARAM_CFG (bit 21: 6-word entries)
  input  logic [31:0]   isp_feed_cfg,    // ISP_FEED_CFG (bit 0: pre_sort of 5-word entries)
  // entries to p2_isp_ctl
  output logic          ent_v,
  input  logic          ent_rdy,
  output p2_entry_t     ent,
  output logic          busy,            // a render's region array is being read
  // C0
  output logic          m_v,
  input  logic          m_rdy,
  output logic [23:0]   m_addr,
  input  logic          m_rv,
  output logic          m_rrdy,
  input  logic [31:0]   m_rdata
);
  localparam int QB = $clog2(SEQ_AHEAD + 1);

  // ---------------------------------------------------------------------------------------------- the entry FIFO
  p2_entry_t       q [SEQ_AHEAD];
  logic [QB-1:0]   qn;
  logic [$clog2(SEQ_AHEAD > 1 ? SEQ_AHEAD : 2)-1:0] qw, qr;
  logic            push, pop;
  p2_entry_t       nent;
  assign ent_v = qn != '0;
  assign ent   = q[qr];
  assign pop   = ent_v && ent_rdy;

  // ---------------------------------------------------------------------------------------------- the reads
  logic        run, fetching, six;
  logic [23:0] addr;                  // the next word's address
  logic [2:0]  issued, got, nw;
  logic [31:0] w [6];
  logic [15:0] idx;
  assign six    = fpu_param_cfg[21];
  assign nw     = six ? 3'd6 : 3'd5;
  // an entry's reads start when the FIFO has room for it (counting the one being fetched)
  assign m_v    = fetching && issued != nw;
  assign m_addr = addr;
  assign m_rrdy = 1'b1;
  assign busy   = run;

  always_comb begin
    p2_entry_t e;
    e             = '0;
    e.tilex       = w[0][7:2];
    e.tiley       = w[0][13:8];
    e.no_writeout = w[0][28];
    e.pre_sort    = six ? w[0][29] : isp_feed_cfg[0];
    e.z_keep      = w[0][30];
    e.last        = w[0][31];
    for (int l = 0; l < P2_LISTS - 1; l++) begin
      e.ptr[l]   = w[l + 1][23:2];
      e.empty[l] = w[l + 1][31];
    end
    e.ptr[P2_LIST_PT]   = six ? w[5][23:2] : 22'd0;
    e.empty[P2_LIST_PT] = six ? w[5][31] : 1'b1;
    e.idx         = idx;
    nent          = e;
  end
  assign push = fetching && got == nw;

  always_ff @(posedge clk) begin
    if (rst) begin
      run      <= 1'b0;
      fetching <= 1'b0;
      qn       <= '0;
      qw       <= '0;
      qr       <= '0;
    end else begin
      if (start) begin
        run      <= 1'b1;
        fetching <= 1'b0;
        addr     <= region_base[23:0];
        idx      <= '0;
      end else if (run && !fetching && qn < QB'(SEQ_AHEAD)) begin
        fetching <= 1'b1;
        issued   <= '0;
        got      <= '0;
      end
      if (m_v && m_rdy) begin
        issued <= issued + 3'd1;
        addr   <= addr + 24'd4;
      end
      if (fetching && m_rv) begin
        w[got] <= m_rdata;
        got    <= got + 3'd1;
      end
      if (push) begin
        q[qw]    <= nent;
        qw       <= qw == $bits(qw)'(SEQ_AHEAD - 1) ? '0 : qw + 1'b1;
        fetching <= 1'b0;
        idx      <= idx + 16'd1;
        if (nent.last)
          run <= 1'b0;
      end
      if (pop)
        qr <= qr == $bits(qr)'(SEQ_AHEAD - 1) ? '0 : qr + 1'b1;
      qn <= QB'(qn + QB'(push) - QB'(pop));
    end
  end
endmodule

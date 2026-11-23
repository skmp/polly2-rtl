// p2_sort: the span sorter (PLAN M8; ARCHITECTURE 3.6): the order in which the TSP shades a pass's runs. Owns tsp 3.2 and
// isp 12.2: refsw3's SpanSort (refcore refsw_tile.cpp; dreamcast-tests timemeas order runs 38-41, spansortcfg).
//
// refsw3 SpanSort, per pass: a window of 96 spans filled in raster order; the oldest span's primitive is drained, all its
// spans in the window oldest first, also those that come in while it lasts (each one shaded makes room for the next);
// then the next oldest span's primitive. The primitive is the tag & ~7 with SPAN_SORT_CFG bit 8 (offset sort: a strip's
// triangles are one primitive), the whole tag without; SPAN_SORT_CFG bit 0 = 0: no sorter, raster order.
//
// Here the passes come back to back, with no barrier between them (ARCHITECTURE 3.6):
// - The window: WIN = 96 places in age order (place 0 the oldest), COMPACTING: a place freed is closed up at once and
//   the run queue's next item goes behind the youngest [M timemeas order: out-of-order runs by window size 95: 129/246,
//   96: 6/20, 97: 150/276; a circular FIFO with holes 485-631]. One fill and one emit a clock [G T5].
// - The key {epoch, tag & mask}: the epoch (p2_isp_cut's pass count, 7 bits) keeps the passes apart. Every item of
//   pass e is older than every item of pass e + 1 and a drain takes window[0]'s key, so pass e's items leave before any
//   of pass e + 1's. The window holds at most 96 passes, so 7 bits never alias.
// - The drain: prim = the key of window[0] at its start; each step emits the OLDEST item with key == prim (a 96-way
//   match on the key, an age priority encoder); it ends when none matches (a clock with no emit) or when the epoch's
//   last item left. The first step of a drain emits window[0] itself in the clock the drain starts.
// - The emit condition [G T5]: a step (an emit, or the end of a drain) is taken only while the window is full or the
//   oldest pass is closed (its eop item has come in). The window then holds what SpanSort's holds for that pass, the
//   next min(96, remaining) runs, so the order is SpanSort's whatever the cutter's pace. Whether the console waits so is
//   GAP T5 (the early drains, timing.md 3.6).
// - The flags: the runs leave in another order than they came in, so eop / eoe move to the last item of the pass to
//   leave: the one emitted while the pass is closed and no other item of its epoch is in the window (a second 96-way
//   match, on the epoch alone). An eop item that leaves before that leaves its flags in sv_closed / sv_eoe.
// - A null item (flags only: an entry's end decided after its last run, p2_isp_cut) is in no pass: it matches no key
//   and leaves alone when it reaches window[0] (every item older than it has left by then), its eoe with it.
// - SPAN_SORT_CFG[0] = 0 (bypass): window[0] leaves each clock, raster order, the flags where they came in (refsw3; the
//   console's near-raster order with early runs is GAP T5). The 0x100 and 0x10001 hangs are not modelled (D6).
//
// Out: the item, and new_drain (this item starts a drain: the TSP's setup look-ahead, ARCHITECTURE 3.7.1).
module p2_sort
  import p2_pkg::*;
#(
  parameter int WIN = 96
) (
  input  logic   clk,
  input  logic   rst,
  input  logic   cfg_on,         // SPAN_SORT_CFG[0]: the sorter (0: raster order)
  input  logic   cfg_offs,       // SPAN_SORT_CFG[8]: offset sort (the key's tag & ~7)
  input  logic   in_v,
  output logic   in_rdy,
  input  p2_rs_t in_d,
  output logic   out_v,
  input  logic   out_rdy,
  output p2_rs_t out_d,
  output logic   out_new_drain,
  // statistics (the testbench's clocks report)
  output logic   t_full,         // the window is full
  output logic   t_wait,         // a step held by the emit condition
  output logic   t_end           // a drain ended with no emit
);
  localparam int IB = $clog2(WIN);
  localparam int CB = $clog2(WIN + 1);

  p2_rs_t        w  [WIN];        // the window, oldest first
  logic [WIN-1:0] hl;             // a hole (a place freed but not closed up; never set while the window compacts)
  logic [CB-1:0] cnt;             // places taken
  logic          dr_v;            // a drain is in progress
  logic [P2_EPOCH_BITS-1:0] dr_ep;
  logic [31:0]   dr_tag;
  logic          sv_closed;       // the oldest pass's eop item has already left (not as its last item)
  logic          sv_eoe;          // ... with eoe

  logic [31:0] kmask;
  assign kmask = cfg_offs ? ~32'h7 : ~32'h0;    // refsw3 SpanSort: (cfg & 0x100) ? ~7 : ~0

  // ---------------------------------------------------------------------------------------------- the matches
  logic [WIN-1:0] live, m, ep_m, eops;
  logic [P2_EPOCH_BITS-1:0] p_ep;
  logic [31:0] p_tag;
  always_comb begin
    p_ep  = dr_v ? dr_ep : w[0].epoch;
    p_tag = dr_v ? dr_tag : (w[0].tag & kmask);
    for (int i = 0; i < WIN; i++) begin
      live[i] = CB'(i) < cnt && !hl[i];
      // the key: 96 comparators against prim
      m[i]    = live[i] && !w[i].null_ && w[i].epoch == p_ep && (w[i].tag & kmask) == p_tag;
      // the epoch alone: is another item of the pass in the window
      ep_m[i] = live[i] && !w[i].null_ && w[i].epoch == p_ep;
      eops[i] = live[i] && !w[i].null_ && w[i].eop;
    end
    if (!cfg_on)
      m = {{(WIN - 1){1'b0}}, live[0] && !w[0].null_};
  end

  // the oldest match: an age priority encoder
  logic [IB-1:0] sel;
  logic          found;
  always_comb begin
    sel   = '0;
    found = 1'b0;
    for (int i = WIN - 1; i >= 0; i--)
      if (m[i]) begin
        sel   = IB'(i);
        found = 1'b1;
      end
  end

  // the oldest pass is closed when its eop item is in the window or has left: every eop item in the window is the
  // oldest pass's or a later one's, and a later pass's eop came in after the oldest pass's
  logic closed, others, full, ok, hnull, last;
  logic [WIN-1:0] sel_oh;
  assign sel_oh = WIN'(1) << sel;
  assign closed = sv_closed || eops != '0;
  assign others = (ep_m & ~sel_oh) != '0;
  assign full   = cnt == CB'(WIN);
  assign ok     = !cfg_on || full || closed;     // the emit condition (bypass: none)
  assign hnull  = !dr_v && live[0] && w[0].null_;
  assign last   = closed && !others;             // the pass's last item to leave

  // ---------------------------------------------------------------------------------------------- the step
  logic emit, dr_end, take;
  always_comb begin
    emit   = hnull || (found && ok);
    dr_end = cfg_on && dr_v && !found && ok;
    out_v  = emit;
    out_d  = w[hnull ? '0 : sel];
    out_new_drain = emit && !hnull && !dr_v;
    if (!hnull) begin
      out_d.eop = last;
      out_d.eoe = last && (sv_eoe || w[sel].eoe);
    end
  end
  assign take = emit && out_rdy;

  // the place the step frees: compaction closes the gap at once (rm: the places above it move down one; kill: it is
  // left as a hole, which a circular FIFO would do, never here)
  logic kill_v, rm_v;
  logic [IB-1:0] rm_i;
  assign kill_v = 1'b0;
  assign rm_v   = take;
  assign rm_i   = hnull ? '0 : sel;

  // the fill: the run queue's head goes behind the youngest, in the clock a place is freed too
  logic fill;
  logic [CB-1:0] apos;
  assign in_rdy = cnt < CB'(WIN) || rm_v;
  assign fill   = in_v && in_rdy;
  assign apos   = cnt - CB'(rm_v);

  // the next window: the fill's place, the places above a freed one moved down one
  p2_rs_t         w_n [WIN];
  logic [WIN-1:0] hl_n;
  always_comb begin
    for (int j = 0; j < WIN; j++) begin
      w_n[j]  = w[j];
      hl_n[j] = hl[j];
      if (fill && CB'(j) == apos) begin
        w_n[j]  = in_d;
        hl_n[j] = 1'b0;
      end else if (rm_v && IB'(j) >= rm_i && j < WIN - 1) begin
        w_n[j]  = w[j + 1];
        hl_n[j] = hl[j + 1];
      end else if (kill_v && IB'(j) == sel)
        hl_n[j] = 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    w  <= w_n;
    hl <= hl_n;
    if (rst) begin
      cnt       <= '0;
      hl        <= '0;
      dr_v      <= 1'b0;
      sv_closed <= 1'b0;
      sv_eoe    <= 1'b0;
    end else begin
      cnt <= cnt - CB'(rm_v) + CB'(fill);
      if (take && !hnull) begin
        if (last) begin
          // the pass's last item: the drain and the pass end
          dr_v      <= 1'b0;
          sv_closed <= 1'b0;
          sv_eoe    <= 1'b0;
        end else begin
          if (cfg_on && !dr_v) begin
            dr_v   <= 1'b1;
            dr_ep  <= p_ep;
            dr_tag <= p_tag;
          end
          if (w[sel].eop) begin
            sv_closed <= 1'b1;
            sv_eoe    <= w[sel].eoe;
          end
        end
      end
      if (dr_end)
        dr_v <= 1'b0;
    end
  end

  assign t_full = full;
  assign t_wait = cfg_on && !hnull && (found || dr_v) && !ok;
  assign t_end  = dr_end;
endmodule

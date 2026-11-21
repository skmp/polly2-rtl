// p2_isp_ptc: the punch-through chunk counter and the hand-off gate (PLAN M7; ARCHITECTURE 3.4.10; isp 11.4 "Chunks";
// refcore refsw_lists.cpp PtChunkTake, RenderTriangle's ptChunkCulled at refsw3 4f3efe15; dreamcast-tests
// pvr-tests/ptchunk, ptchunkq, ptchunkm, ptchunkcost, ptchunklag).
//
// It sits between p2_isp_setup's hand-off and the raster (it needs setup's cull verdict). Per primitive at its
// program's end (setup's pc strobe, in list order), while a punch-through walk runs (en):
//
//   S = ISP_FEED_CFG[13:4] (0 .. 1023); T = S - 2 as a SIGNED value (-2 .. 1021)
//   culled (CullMode: facing or size)  -> culled = 3 (counted in the next check only); no room in the chunk
//   else nv = quad ? 4 : 3
//        if fill > 0 && (fill - prevQuad) + culled + nv > T: chunkAt++, fill = 0        (the quad lag, the culled lag)
//        fill += nv; prevQuad = quad; culled = 0
//
// The compare is signed: for S = 0 or 1 every primitive is its own chunk, as refsw3's int compare gives (an unsigned
// S - 2 would put the whole list in one chunk). A bad corner (nothing drawn, not culled) counts as stored (isp 15 #19);
// its program has no descriptor (pc_desc = 0), but it moves the counter all the same.
//
// The descriptor a primitive puts into the 1-deep hand-off carries its chunk (chunkAt after its own check). The gate:
//   - its chunk is the one being peeled (cur): it goes to the raster (a member);
//   - a later chunk: the walk is at the chunk's end. It is HELD in the hand-off (hold), as the next chunk's first member,
//     and the walk behind it waits by back-pressure (ARCHITECTURE 3.4.1: the RTL counts once, continuing the walk at
//     the primitive that did not fit; refsw3 re-counts the whole list every pass: the same members, because the count
//     depends only on the list and the cull verdicts);
//   - in full-walk mode (fw: the chunk overflowed p2_isp_pcache, ARCHITECTURE 3.4.11 "A chunk larger than PCACHE_N
//     descriptors replays as walks"): every walk starts at the list's start with the counter reset (restart), and a
//     descriptor of another chunk is dropped, not held.
// more_chunks: chunkAt > cur, another chunk follows (refsw3's ptChunks = chunkAt + 1).
// Outside the punch-through phase (pt = 0) the gate passes everything; inside it a descriptor passes only during a walk
// (en; during a replay p2_isp_pcache has the raster's input and the held descriptor stays). The counter counts through
// the whole punch-through phase.
module p2_isp_ptc
  import p2_pkg::*;
(
  input  logic                         clk,
  input  logic                         rst,
  input  logic [9:0]                   chunk_size,     // ISP_FEED_CFG[13:4]
  // ctl
  input  logic                         pt,             // the punch-through phase: count every strobe (a culled or
                                                       // bad primitive behind a held descriptor still finishes its
                                                       // program and moves the counter while the passes replay)
  input  logic                         en,             // a punch-through walk (pass 0 of a chunk, or any pass in fw)
  input  logic                         restart,        // a walk from the list's start: the counter from zero
  input  logic                         set_cur,        // the chunk being peeled is cur_in
  input  logic [15:0]                  cur_in,
  input  logic                         fw_set,         // p2_isp_pcache overflowed in this chunk's fill
  input  logic                         fw_clr,         // a punch-through phase starts
  output logic                         fw,
  output logic                         hold,
  output logic                         more_chunks,
  output logic [15:0]                  chunk_at,       // the counter (the chunks so far - 1)
  // setup's strobe, one per primitive in list order
  input  logic                         pc_v,
  input  logic                         pc_culled,
  input  logic                         pc_quad,
  input  logic                         pc_desc,        // the primitive put a descriptor into the hand-off now
  // the hand-off (p2_isp_setup) to the raster side
  input  logic                         rd_v,
  output logic                         rd_rdy,
  output logic                         o_v,
  input  logic                         o_rdy
);
  logic signed [12:0] fill;
  logic               prev_quad;
  logic [1:0]         culled;          // 0 or 3
  logic [15:0]        at, cur, hc;     // hc: the hand-off's descriptor's chunk

  // the check (PtChunkTake)
  logic signed [12:0] nv, lhs, thr;
  logic               brk;
  logic [15:0]        at_n;
  always_comb begin
    nv   = pc_quad ? 13'sd4 : 13'sd3;
    lhs  = (fill - (prev_quad ? 13'sd1 : 13'sd0)) + $signed({11'd0, culled}) + nv;
    thr  = $signed({3'd0, chunk_size}) - 13'sd2;
    brk  = fill > 13'sd0 && lhs > thr;
    at_n = brk ? at + 16'd1 : at;
  end

  logic member, later;
  assign member      = hc == cur;
  assign later       = !member;
  // in the punch-through phase nothing passes between its walks (the passes' SHADEs, the replays, the sweeps)
  assign hold        = pt && rd_v && later && !fw;
  assign o_v         = rd_v && (!pt || (en && member));
  assign rd_rdy      = !pt ? o_rdy : (en && (member ? o_rdy : fw));     // fw: dropped
  assign more_chunks = at != cur;
  assign chunk_at    = at;

  always_ff @(posedge clk) begin
    if (rst) begin
      fill      <= '0;
      prev_quad <= 1'b0;
      culled    <= '0;
      at        <= '0;
      cur       <= '0;
      fw        <= 1'b0;
    end else begin
      if (pt && pc_v) begin
        if (pc_culled)
          culled <= 2'd3;
        else begin
          fill      <= (brk ? 13'sd0 : fill) + nv;
          prev_quad <= pc_quad;
          culled    <= '0;
          at        <= at_n;
        end
      end
      if (pc_v && pc_desc)
        hc <= at_n;
      if (restart) begin
        fill      <= '0;
        prev_quad <= 1'b0;
        culled    <= '0;
        at        <= '0;
      end
      if (set_cur)
        cur <= cur_in;
      if (fw_set)
        fw <= 1'b1;
      if (fw_clr)
        fw <= 1'b0;
    end
  end
endmodule

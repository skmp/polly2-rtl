//
// spanner_v2 - the DECOUPLED span-generate + TSP-setup stage of the v2 TSP pipeline.
//
// Replaces the monolithic peel_core `spn` FSM's resolve+setup+write with two engines
// that run CONCURRENTLY, joined by a small setup FIFO, so the per-triangle setup cost
// (~54cyc/tri) is hidden behind the shade stage (1px/clk, downstream, not in here):
//
//   FSM 1  SPANGEN  - walks the tile's tag buffer 4 ALIGNED pixels/clk, coalesces the
//                     leading same-tag run within each aligned group into a SPAN, and
//                     writes {id, repeat, invW[0:3]} to the OUT span buffer at the
//                     run-start pixel index. A NEW (not-yet-seen) tag BUMP-ALLOCATES a
//                     ring setup id (id = top_tag++) and pushes {id,tag} to the setup FIFO.
//                     NEVER stalls on setup (that is downstream).
//   FSM 2  SETUP    - drains the setup FIFO: tag -> record_fetcher (GetFpuEntry) ->
//                     tsp_setup (10 planes) -> WRITE triangle_setups[id]. Runs in
//                     parallel with SPANGEN and the (external) shade stage.
//
// DEDUP / ID: a direct-mapped M10K dedup map (indexed by pc_slot(tag)) holds {gen,tag,id};
// the setup id is BUMP-ALLOCATED (top_tag), so triangle_setups ids are DENSE (0..distinct-1
// per tile) not hash-scattered. triangle_setups is a RING shared with TSP (no ping-pong):
// tsp_go signals a tile's setups done, tsp_rd_done frees that tile's ring range (tail).
// A single 32x32 tile has <=1024 distinct tags, so ring_size=NSLOT never intra-tile
// overflows; cross-tile overlap can overflow -> SPANGEN stalls for tsp_rd_done. The dedup
// map's `gen` (bumped per start) invalidates prior-tile buckets for free ("don't reuse when
// x/y change"); on gen wrap a clear-walk writes gen=0.
//
// The triangle_setups RING + span buffer are EXTERNAL (module write ports); the ring
// tail/reclaim handshake (tsp_go/tsp_rd_done) lets peel_core share ONE buffer with TSP.
//
// IN (tag buffer): a 4-wide ALIGNED read port. The module presents a group base
// (rd_group = x & ~3) and receives the 4 lanes' {valid,tag,invW,pt} the NEXT cycle
// (1-cyc registered read, same timing as taginvw_tile_buffer's single-pixel port; glue
// widens that buffer to serve 4 aligned lanes). Lane l is pixel (group|l).
//
module spanner_v2 import tsp_pkg::*; #(
    parameter integer NSLOT = 1024,          // dedup-map depth (== tile pixels)
    parameter integer SLOTW = 10,            // clog2(NSLOT) (tile pixel index width)
    // CROSS-PASS PLANE REUSE via a SLIDING WINDOW: plane ids are the low bits of
    // a free-running alloc SEQUENCE; the dedup generation is kept across passes
    // of the same tile, so a later pass's hit reuses the earlier pass's setup id
    // (no re-fetch, no re-setup) - but only ids within the last WINDOW allocs
    // are referencable (older hits realloc). Every span carries its alloc-seq
    // watermark; the READER feeds back the watermark of the last span it fully
    // consumed (cons_seq), and a plane is free once cons_seq passes its seq by
    // WINDOW (no unconsumed span can reference it: any such span's watermark
    // would be <= seq+WINDOW <= cons_seq, i.e. already consumed). Ring capacity
    // check is pure pointer arithmetic: alloc may run at most RING_N - WINDOW
    // ahead of cons_seq. The reader consumes STREAMED (it does not wait for the
    // pass to finish spanning), so an alloc stall always resolves.
    parameter integer RING_N = 1024,         // plane ring depth (pow2)
    parameter integer IDW    = 10,           // clog2(RING_N) (setup-id width)
    parameter integer WINDOW = 512,          // max lookback for cross-pass reuse
    parameter integer SEQ_W  = 13,           // alloc-sequence width (wrap-safe)
    // span RING (shared with TSP) is sized larger than the plane ring: 2048 = two
    // worst-case tiles, so a full 1024-span pass fits with room for a SECOND pass to be
    // written and in flight while the first drains. SPAN_W = clog2(SPAN_NSLOT) = 11.
    parameter integer SPAN_NSLOT = 2048,
    parameter integer SPAN_W     = 11
) (
    input                       clk,
    input                       reset,

    // ---- control ----
    input                       start,       // 1-cyc: begin resolving one tile pass
    input                       ctx_inval,   // render start: params may change at the
                                             // same pointers -> drop the retained ctx
    output reg                  busy,         // start .. SPANGEN done && setup drained
    input                       shade_mode,  // 1=OP (shade all px); 0=PEEL (gate on valid)
    input      [31:0]           xbase, ybase,// this tile's origin (for tsp_setup_min)
    input      [26:0]           param_base,
    input                       intensity_shadow, // regs.fpu_shad_scale.intensity_shadow

    // ---- shared-ring handshake with the TSP consumer ----
    // triangle_setups is a RING shared with TSP (no ping-pong): ids are bump-allocated
    // (top_tag), TSP reads them, and a whole tile's ring range frees when TSP finishes it.
    output reg                  tsp_go,      // 1-cyc: this tile's setups are all done -> TSP may read
    input                       tsp_rd_done, // 1-cyc: TSP finished the oldest handed tile -> free its range
    // ---- STREAMING handshake: the reader consumes spans while this pass is
    // still being spanned. span_head_live exposes the write head (available =
    // head - reader ptr); sp_wm (stored with each span) is the alloc-seq
    // watermark the reader must (a) wait for setup_seq to reach before shading
    // the span (its planes are then written) and (b) report back via cons_seq
    // once the span's last pixel has taken its planes (plane-free authority).
    output     [SPAN_W:0]       span_head_live,
    output     [SEQ_W-1:0]      sp_wm,       // alloc watermark of the span at sp_we
    output     [SEQ_W-1:0]      setup_seq,   // setups written so far (alloc order)
    input      [SEQ_W-1:0]      cons_seq,    // reader: watermark fully consumed

    // ---- IN: 4-wide ALIGNED tag-buffer read (present addr -> data NEXT cycle) ----
    output reg                  rd_valid,    // present a group read this cycle
    output reg [SLOTW-1:0]      rd_group,    // group base pixel index (x & ~3)
    input      [3:0]            ti_valid,    // per-lane staged-this-pass bit
    input      [31:0]           ti_tag  [0:3],
    input      [30:0]           ti_invw [0:3],
    input      [3:0]            ti_pt,       // per-lane PT alpha-test bit

    // ---- OUT: triangle_setups WRITE (SETUP engine) ----
    output reg                  ts_we,
    output reg [IDW-1:0]        ts_id,
    output reg [31:0]           ts_isp, ts_tsp, ts_tcw,
    output reg [319:0]          ts_ddx, ts_ddy, ts_c,   // 10 x 32, lane j at [32*j+:32]

    // ---- OUT: span buffer WRITE (SPANGEN engine) into the shared RING ----
    // DENSELY PACKED and SHADED-ONLY: SPANGEN emits a span ONLY for a maximal run of
    // contiguous SHADED (valid, or OP) same-tag pixels within the aligned group. Invalid
    // pixels emit NO span (they just advance the walk). Each shaded span is written at the
    // ring head slot (sp_slot = span_head, wrapping). The reader walks this pass's ring range
    // [sp_range_base .. +sp_range_cnt) and expands each span's rep pixels unconditionally (all
    // shaded) - no per-pixel dense walk, no shade mask. sp_start = run-start pixel index (y:x).
    output reg                  sp_we,
    output reg [SPAN_W-1:0]     sp_slot,     // ring slot = span_head (wraps at SPAN_NSLOT)
    // span RING RANGE of this pass, valid when busy deasserts: base = ring position of this
    // pass's first span (== span_head at start), cnt = # spans emitted (0 => empty). Both
    // carry the extra wrap-MSB so (head - base) is correct across a ring wrap. The reader
    // walks cnt slots from base[SPAN_W-1:0] with natural wrap.
    output reg [SPAN_W:0]       sp_range_base,
    output reg [SPAN_W:0]       sp_range_cnt,
    output reg [SLOTW-1:0]      sp_start,    // run-start pixel index (y:x, 0..1023) [data]
    output reg [IDW-1:0]        sp_id,       // setup id (== triangle_setups slot)
    output reg [2:0]            sp_rep,      // run length 1..4 (all covered pixels shaded)
    output reg [30:0]           sp_invw [0:3], // per-covered-pixel invW (lanes 0..rep-1)
    output reg                  sp_at,       // PT alpha-test enable (run-start lane)
    input                       sp_ready,    // span consumer (expander) can accept this cycle

    // ---- DDR client for the internal record_fetcher ----
    output ddr_rd_req_t         dreq,
    input  ddr_rd_resp_t        dresp
);
    // ============================ dedup map + setup-id ring ============================
    // id = BUMP-ALLOCATED (top_tag), not the hash. The dedup MAP is a direct-mapped M10K
    // (indexed by pc_slot(tag)) that remembers, per hash bucket, {gen, tag, id} = which
    // ring id a tag was assigned. triangle_setups[id] is a RING (top_tag..tail) shared
    // with TSP; ids are dense (0..distinct-1 per tile) instead of scattered by the hash,
    // so the ring can be far smaller than 1024 and shared with TSP without ping-pong.
    //   lookup:  h = pc_slot(tag); if map[h].gen==cur_gen && map[h].tag==tag -> HIT, id=map[h].id
    //            else MISS -> id = top_tag++, map[h] = {cur_gen, tag, id}, push a setup.
    // pc_slot spreads tags across the 1024 map buckets (10-bit hash). tag =
    // {skip[26:24], param_offs[23:3], tag_offset[2:0]}; strip triangles share param_offs.
    function automatic [SLOTW-1:0] pc_slot(input [31:0] tag);
        pc_slot = tag[12:3] ^ tag[22:13] ^ { {(SLOTW-3){1'b0}}, tag[2:0] };
    endfunction

    // dedup MAP: ONE M10K holding {gen, tag, id} per bucket, so tag+validity+id all live
    // in block RAM (no flop valid-vector, no bulk clear). A bucket is VALID this pass iff
    // gen==cur_gen; `start` bumps cur_gen so prior-pass buckets go stale for free ("don't
    // reuse when x/y change"). cur_gen never 0; on wrap a clear-walk writes gen=0 to all.
    // REGISTERED read (1-cyc); the dedup test is PIPELINED COAL(read)->EMIT(compare+write).
    // COHERENCY: EMIT can WRITE a bucket the same cycle COAL presents the next read (M10K
    // returns stale on same-addr r+w) -> the two most-recent allocations are FORWARDED.
    localparam integer GEN_W = 8;
    localparam integer DD_W  = GEN_W + 32 + SEQ_W;   // {gen, tag, alloc-seq}
    localparam [GEN_W-1:0] GEN_MAX = {GEN_W{1'b1}};
    (* ramstyle = "M10K, no_rw_check" *) reg [DD_W-1:0] dedup_ram [0:NSLOT-1];
    reg [DD_W-1:0]     dd_rd_q;                   // registered read {gen,tag,seq} of coal bucket
    reg [GEN_W-1:0]    cur_gen;                   // current ERA generation (never 0)
    reg                dd_clearing;               // clear-walk in progress (gen wrap)
    reg [SLOTW-1:0]    dd_clr_addr;
    wire [GEN_W-1:0]   dd_rd_gen  = dd_rd_q[DD_W-1 -: GEN_W];
    wire [31:0]        slot_tag_q = dd_rd_q[SEQ_W +: 32];
    wire [SEQ_W-1:0]   slot_seq_q = dd_rd_q[0 +: SEQ_W];
    wire               slot_valid_q = (dd_rd_gen == cur_gen);

    // ---- setup-id allocator: free-running SEQUENCE, sliding-window liveness ----
    // slot = alloc_seq[IDW-1:0]; a plane's slot may be re-allocated once
    // alloc_seq - its_seq >= RING_N, which the capacity stall below defers until
    // cons_seq (reader progress) has passed its_seq + WINDOW - and the window
    // check makes any FURTHER reference realloc instead. So a slot is never
    // overwritten while a not-yet-consumed span references it.
    reg  [SEQ_W-1:0]   alloc_seq;                 // next plane's sequence number
    reg  [SEQ_W-1:0]   ts_seq;                    // setups written so far (in order)
    assign setup_seq = ts_seq;
    // alloc may run RING_N - WINDOW ahead of the reader's consumed watermark
    wire [SEQ_W-1:0]   ring_ahead = alloc_seq - cons_seq;
    wire ring_full  = (ring_ahead >= SEQ_W'(RING_N - WINDOW));
    localparam integer GF_AW = 3;                 // up to 8 passes handed-but-not-done (matches
                                                  // peel_core MD_N=8).
    reg [GF_AW:0]      gf_wp, gf_rp;              // handed-pass FIFO ptrs (span ends)
    wire gf_empty = (gf_wp == gf_rp);
    // retention context: same tile origin since the last start, not render-invalidated
    reg [31:0]         prev_xb, prev_yb;
    reg                ctx_val;
    reg                retain_en;              // +noretain: force every pass fresh
`ifndef SYNTHESIS
    initial retain_en = !$test$plusargs("noretain");
`else
    initial retain_en = 1'b1;
`endif
    wire               ctx_ok    = ctx_val && (prev_xb == xbase) && (prev_yb == ybase);
    wire               retain_ok = retain_en && ctx_ok;

    // ---- span RING (dense_span_buffer slots), shared with TSP (mirrors the plane ring) ----
    // span_head = next slot to write; span_tail = oldest slot still owned by TSP. Sized
    // SPAN_NSLOT=2048 so a single worst-case tile (<=1024 spans) always fits (deadlock-free,
    // same argument as the plane ring) with room for a second pass in flight. Every SHADED
    // span consumes a slot (NOT just allocs) -> the ring-full stall gates on run_shaded.
    // span_pass_base snapshots span_head at each pass start (the pass's range base). A
    // parallel end-pointer FIFO sgf_mem records each handed pass's span end (span_head).
    // ROLLING READ: the pointers FREE-RUN and wrap by width - there is no
    // snap-to-zero when the ring goes idle. The old normalize existed only to
    // keep ids dense from 0 on a sequential pass, but it needed an awkward
    // "no handed-but-unfreed pass outstanding" guard (a normalize under an
    // outstanding gf entry loads a STALE tail on its later tsp_rd_done), and a
    // streaming reader that paces off the LIVE head cannot tolerate the head
    // moving backwards under it. Slots are just RAM addresses; they may start
    // anywhere, so the discontinuity bought nothing.
    reg [SPAN_W:0]     span_head, span_tail;      // ring head / tail (SPAN_W+1 bits)
    assign span_head_live = span_head;            // streaming reader's availability limit
    wire span_ring_empty = (span_head == span_tail);
    wire span_ring_full  = (span_head[SPAN_W] != span_tail[SPAN_W]) &&
                           (span_head[SPAN_W-1:0] == span_tail[SPAN_W-1:0]);
    reg [SPAN_W:0]     span_pass_base;            // span_head at this pass's start
    reg [SPAN_W:0]     sgf_mem [0:(1<<GF_AW)-1];  // span END pointers handed to TSP

    // ============================ setup FIFO (SPANGEN -> SETUP) ============================
    // {id, tag} pushed when a span allocates a NEW slot; drained by the SETUP engine.
    localparam integer SF_AW = 3;                 // 8-deep
    localparam integer SF_N  = (1 << SF_AW);
    localparam integer SF_W  = IDW + 32;          // {id, tag}
    reg  [SF_W-1:0] sf_mem [0:SF_N-1];
    reg  [SF_AW:0]  sf_wp, sf_rp;                 // extra MSB for full/empty disambig
    wire            sf_empty = (sf_wp == sf_rp);
    wire            sf_full  = (sf_wp[SF_AW] != sf_rp[SF_AW]) &&
                               (sf_wp[SF_AW-1:0] == sf_rp[SF_AW-1:0]);
    reg             sf_push;  reg [SF_W-1:0] sf_pdata;
    wire [SF_W-1:0] sf_head  = sf_mem[sf_rp[SF_AW-1:0]];

    // ============================ FSM 1: SPANGEN (pipelined, 1 span/cycle) ============================
    // A continuously-advancing 2-stage pipeline (M10K-friendly: slot read is registered):
    //   COAL (this cycle): a group's 4 lanes are held in g_*; coalesce the leading same-tag
    //        run at the current intra-group position sg_x -> a span descriptor run_*.
    //        PRESENT the registered slot_tag read of run_id. Advance sg_x by run_rep. If the
    //        group is exhausted, the group PREFETCH (ahead) supplies the next group's lanes
    //        so COAL keeps producing one descriptor EVERY cycle with no reissue bubble.
    //   EMIT (next cycle): the descriptor produced by COAL last cycle is in t_*; its slot
    //        read has resolved (slot_*_q, forwarded) -> dedup compare, WRITE the span,
    //        allocate on a miss. Retires one span/cycle.
    // Uniform tile (one tag, 4px runs) -> 256 groups x 1 span x 1 cyc + fill/drain ~= 258.
    // Multi-span group (A B C D) -> COAL produces 4 descriptors on 4 consecutive cycles
    // (sg_x steps within the held group, no reissue) -> 4 cyc, still 1 span/cyc.
    //
    // GROUP PREFETCH: the tag buffer read has 1-cyc latency, so we must present the NEXT
    // group's read the cycle BEFORE COAL needs it. gp_* holds the prefetched group; when
    // COAL exhausts the current group it swaps gp_* -> g_* and the prefetch reads group+1.
    reg              sg_active;     // SPANGEN still walking (COAL may produce)
    reg [SLOTW-1:0]  sg_x;          // next pixel to coalesce a span at (0..NSLOT-1)
    reg              g_ready;       // ti_* holds sg_x's group this cycle (read landed)
    // The tag buffer is a registered-read RAM: its output ti_* reflects the address
    // presented LAST cycle, and updates EVERY cycle. So we present rd_group = the group of
    // the pixel COAL coalesces NEXT cycle, continuously; then ti_* is ALWAYS the correct
    // group source for the current sg_x -> COAL coalesces directly off ti_* (no held-group
    // register, no source mux). g_ready gates the 1-cycle fill latency after start/stall.
    reg [SLOTW-1:0]  rd_next_x;     // combinational: pixel whose group we address

    // ---- span descriptor latched at COAL, consumed (emitted) at EMIT ----
    reg              t_valid;       // EMIT stage occupied
    reg [SLOTW-1:0]  t_x;           // run-start pixel index
    reg [SLOTW-1:0]  t_h;           // pc_slot(run_tag) = dedup map bucket
    reg [31:0]       t_tag;
    reg [2:0]        t_rep;
    reg              t_ok;          // this run is SHADED (emit a span); else invalid (skip)
    reg [30:0]       t_invw [0:3];
    reg              t_at;

    wire [1:0] sg_lane = sg_x[1:0];              // intra-group position of sg_x

    // ---- leading-run coalesce (combinational off ti_*, the current group source) ----
    // shade_ok(l) = shade_mode | ti_valid[l] : is lane l shaded this pass. run_ok0 = start
    // lane shaded? Two run kinds, both advancing sg_x by run_rep, but only SHADED runs emit
    // a span:
    //   * SHADED start (run_ok0=1): extend while contiguous, shaded, and SAME tag. -> a real
    //                  span (rep 1..4, all covered lanes shaded, same triangle).
    //   * INVALID start(run_ok0=0): extend while contiguous invalid, IGNORING tag. -> emits
    //                  NO span; just skips the invalid pixels (advance the walk).
    // A shade transition (valid<->invalid) or a tag change breaks the run. No shade mask:
    // every emitted span is uniformly shaded.
    reg  [2:0] run_rep;                          // 1..4 (run length; advances sg_x)
    reg  [31:0] run_tag;
    reg        run_ok0;                          // start lane shaded? (span emitted iff 1)
    integer rl;
    always @(*) begin
        run_tag    = ti_tag[sg_lane];
        run_rep    = 3'd1;
        run_ok0    = shade_mode | ti_valid[sg_lane];
        for (rl = 0; rl < 4; rl = rl + 1) begin
            // extend if in-group, contiguous, same shade-eligibility, and (if shaded) same tag.
            if (rl > sg_lane && rl == sg_lane + run_rep
                && ((shade_mode | ti_valid[rl]) == run_ok0)
                && (run_ok0 ? (ti_tag[rl] == run_tag) : 1'b1)) begin
                run_rep = run_rep + 3'd1;
            end
        end
    end

    wire [SLOTW-1:0] run_id = pc_slot(run_tag);

    // dedup test in EMIT, using the REGISTERED slot read (slot_tag_q/slot_valid_q) of
    // t_id, WITH forwarding. In the 1-span/cycle pipeline, EMIT retires a span every cycle
    // and may write the slot store the SAME cycle COAL presents the next span's read (M10K
    // read-during-write returns stale data). So we forward the LAST TWO emitted allocations:
    //   fwd0 = the allocation done LAST cycle (its write is in flight, read returns stale)
    //   fwd1 = the allocation done TWO cycles ago (covers the M10K's write-settle window)
    // Both are checked against t_id; the most recent wins. Uniform tile (same tag every
    // group -> same id) is covered: after the first alloc, every later EMIT sees fwd and
    // dedups (no re-push, no re-setup).
    // forwarding is keyed by the map BUCKET (t_h = pc_slot) and carries {tag, id} of the
    // two most-recent allocations, so a back-to-back reuse of a just-allocated bucket sees
    // the fresh {tag,id} despite the M10K read-during-write staleness.
    reg             fwd0_valid, fwd1_valid;
    reg [SLOTW-1:0] fwd0_h,     fwd1_h;
    reg [31:0]      fwd0_tag,   fwd1_tag;
    reg [SEQ_W-1:0] fwd0_seq,   fwd1_seq;
    wire            fwd0_hit = fwd0_valid && (fwd0_h == t_h);
    wire            fwd1_hit = fwd1_valid && (fwd1_h == t_h);
    wire            eff_valid = fwd0_hit | fwd1_hit | slot_valid_q;
    wire [31:0]     eff_tag   = fwd0_hit ? fwd0_tag : (fwd1_hit ? fwd1_tag : slot_tag_q);
    wire [SEQ_W-1:0] eff_seq  = fwd0_hit ? fwd0_seq : (fwd1_hit ? fwd1_seq : slot_seq_q);
    // Only SHADED runs (t_ok) emit a span AND allocate/dedup/setup. An invalid run (t_ok=0)
    // is retired at EMIT without emitting a span, allocating an id, or pushing a setup - it
    // only advanced the walk past its invalid pixels.
    wire run_shaded   = t_valid && t_ok;
    // WINDOW check: a hit is only usable while the plane's seq is within the
    // last WINDOW allocs (older planes may free under a later span; realloc).
    // Forwarded entries are <= 2 allocs old - always in window.
    wire            eff_inwin = (alloc_seq - eff_seq) <= SEQ_W'(WINDOW);
    wire is_dedup_hit = run_shaded && eff_valid && (eff_tag == t_tag) && eff_inwin;
    wire needs_alloc  = run_shaded && !is_dedup_hit;
    // ring id (triangle_setups slot) = low bits of the plane's alloc seq
    wire [IDW-1:0] emit_id = is_dedup_hit ? eff_seq[IDW-1:0]
                             : (run_shaded ? alloc_seq[IDW-1:0] : {IDW{1'b0}});
    // the span's watermark: alloc count AFTER this span (incl. its own alloc)
    wire [SEQ_W-1:0] emit_wm = alloc_seq + (needs_alloc ? SEQ_W'(1) : SEQ_W'(0));
    assign sp_wm = emit_wm;            // stored with the span (valid at sp_we)

    // emit can commit when: an ALLOCATING emit needs setup-FIFO room AND a free ring slot.
    // A same-tag reuse needs neither. When blocked, the WHOLE pipeline freezes (COAL+EMIT).
    wire emit_stall_fifo = needs_alloc && sf_full;
    wire emit_stall_ring = needs_alloc && ring_full;   // no free plane id -> wait for TSP
    // also freeze if the span consumer (expander) can't accept the span this emit produces
    wire emit_stall_span = run_shaded && !sp_ready;   // only stall when actually emitting
    // span RING full: EVERY shaded span consumes a slot (unlike plane alloc, miss-only), so
    // this gates on run_shaded, not needs_alloc. No free span slot -> wait for TSP to drain.
    wire emit_stall_span_ring = run_shaded && span_ring_full;
    wire pipe_stall      = emit_stall_fifo | emit_stall_ring | emit_stall_span
                         | emit_stall_span_ring;

    // ---- COAL advance: sg_x steps by run_rep; group exhausted when it crosses the group ----
    wire [SLOTW-1:0] sg_x_next   = sg_x + { {(SLOTW-3){1'b0}}, run_rep };

    // ---- GROUP-ONLY advance, for the taginvw read address ------------------------
    // rd_group below uses ONLY sg_x_next[SLOTW-1:2], so the low two bits of that add
    // - and the carry chain that produces the top eight - are dead weight on the
    // worst path in the design: taginvw RAM -> tag compare -> run_rep -> this adder
    // -> raddr -> the same RAM, closed in one cycle (9,011 endpoints, -4.976).
    //
    // The group part is exactly  sg_grp + carry,  carry = (sg_lane + run_rep) >= 4,
    // because run_rep is 1..4 and sg_lane is 0..3, so the sum never exceeds 7. And
    // carry needs no adder either: the run starts at sg_lane and can only end at
    // lane 3 at the latest (the extend loop is confined to the group), so it crosses
    // the group boundary iff it extended through EVERY lane above sg_lane.
    //
    // "Extended through lane l" is tested here as adjacency, ti_tag[l]==ti_tag[l-1],
    // rather than against run_tag=ti_tag[sg_lane]. Equality is transitive and the
    // shade-eligibility bits chain the same way, so a full adjacent chain from
    // sg_lane+1 to 3 is the same predicate - but it drops the 4:1 run_tag mux out of
    // the address path as well as the adder. sg_grp/sg_grp_p1 come straight off the
    // sg_x REGISTER, so the increment is on a register-to-register path with a whole
    // cycle to itself; the RAM only has to drive the mux SELECT.
    wire [3:0] sg_ok;                             // per-lane shade eligibility
    genvar gl;
    generate for (gl = 0; gl < 4; gl = gl + 1) begin : sgok
        assign sg_ok[gl] = shade_mode | ti_valid[gl];
    end endgenerate
    wire [3:1] sg_ext;                            // lane l joins lane l-1
    generate for (gl = 1; gl < 4; gl = gl + 1) begin : sgext
        assign sg_ext[gl] = (sg_ok[gl] == sg_ok[gl-1])
                         && (sg_ok[gl] ? (ti_tag[gl] == ti_tag[gl-1]) : 1'b1);
    end endgenerate
    reg sg_carry;                                 // the run leaves this group
    always @(*) begin
        case (sg_lane)
            2'd0:    sg_carry = sg_ext[1] & sg_ext[2] & sg_ext[3];
            2'd1:    sg_carry = sg_ext[2] & sg_ext[3];
            2'd2:    sg_carry = sg_ext[3];
            default: sg_carry = 1'b1;             // already at lane 3: any run leaves
        endcase
    end
    wire [SLOTW-3:0] sg_grp    = sg_x[SLOTW-1:2];
    wire [SLOTW-3:0] sg_grp_p1 = sg_grp + 1'b1;   // off the register, not off the RAM
    wire walk_last              = (sg_x_next == '0);          // wrapped past pixel 1023
    // COAL produces a descriptor this cycle iff walking, the group read has landed
    // (g_ready), and the pipeline isn't frozen.
    wire coal_fires = sg_active && g_ready && !pipe_stall;

    // ---- SINGLE dedup_ram write port (M10K-inferable) ----
    // dedup_ram has exactly TWO logical writers - the gen-wrap clear-walk and the EMIT
    // allocation - which are MUTUALLY EXCLUSIVE (during dd_clearing, sg_active=0 so
    // coal_fires=0 and t_valid stays 0 -> no EMIT write; clearing ends the cycle it sets
    // sg_active, and no EMIT can race that cycle). Two inline `dedup_ram[..]<=` statements
    // defeat Quartus RAM inference (Warning 10999) and fall back to 1024x50 = 51200 FLOPS.
    // Collapsing them into one muxed write port (one addr, one data, one enable) infers a
    // single M10K with IDENTICAL behavior and timing - the EMIT write keeps its !pipe_stall
    // and (t_valid && needs_alloc) guard, the clear write keeps its every-cycle-while-clearing
    // guard - so there is NO performance change, only the RAM<->flop mapping.
    wire            dd_emit_we = !pipe_stall && t_valid && needs_alloc;
    wire            dd_we    = dd_clearing || dd_emit_we;
    wire [SLOTW-1:0] dd_waddr = dd_clearing ? dd_clr_addr : t_h;
    wire [DD_W-1:0]  dd_wdata = dd_clearing ? {DD_W{1'b0}}
                                            : {cur_gen, t_tag, alloc_seq};
    // Read port: present run_id's bucket exactly when COAL produces a descriptor (coal_fires),
    // so dd_rd_q resolves next cycle in EMIT. A clean read ENABLE (dd_re) + read ADDRESS
    // (dd_raddr) in a DEDICATED always block below is the textbook synchronous-read M10K
    // template; keeping the read inline under the control FSM made Quartus see the read as
    // asynchronous (Info 276007) and fall back to 1024x50 flops.
    wire            dd_re    = coal_fires;
    wire [SLOTW-1:0] dd_raddr = run_id;

    // ---- dedup_ram: DEDICATED simple-dual-port M10K block (textbook template) ----
    // ONE write port (dd_we/dd_waddr/dd_wdata), ONE registered read port (dd_re/dd_raddr ->
    // dd_rd_q). Isolated from the control FSM so Quartus infers a clean synchronous-read RAM
    // (no async-read fallback). `no_rw_check`: a same-cycle read+write to the same address
    // returns OLD data; the fwd0/fwd1 forwarding downstream already covers that R/W collision,
    // so the read semantics are unchanged from the original inline `dd_rd_q <= dedup_ram[..]`.
    // Timing is identical: dd_re == coal_fires (read presented exactly when a descriptor is
    // produced), dd_we gated exactly as the original two inline writes were.
    always @(posedge clk) begin
        if (dd_we) dedup_ram[dd_waddr] <= dd_wdata;
        if (dd_re) dd_rd_q <= dedup_ram[dd_raddr];
    end

    // ============================ SETUP path (streaming, no serial FSM) ============================
    // Three independent stages, each fed continuously, so the record fetch of triangle
    // N+1 OVERLAPS the plane setup of triangle N (they were serial before: ~144 fetch +
    // ~257 setup = ~400 cyc/triangle back-to-back):
    //   FETCH  : pop the setup FIFO into record_fetcher whenever it is free.
    //   pend_* : 1-deep skid holding the decoded record until tsp_setup_min is free
    //            (frees the fetcher to start the next fetch).
    //   SETUP  : latch pend_* into cur_*/fv_* (held stable for the whole run) + start
    //            tsp_setup_min; on tsp_done pulse ts_pend -> ts_we write.
    reg              fetch_busy;    // a fetch is in flight (fx_start..fx_done)
    reg [IDW-1:0]    fx_id;         // the in-flight fetch's setup id
    reg              pend_v;        // pend_* holds a decoded record awaiting setup
    reg [IDW-1:0]    pend_id;
    reg [31:0]       pend_isp, pend_tsp, pend_tcw;
    reg [31:0]       pend_x[0:2], pend_y[0:2], pend_z[0:2];
    reg [31:0]       pend_u[0:2], pend_v3[0:2], pend_col[0:2], pend_ofs[0:2];
    reg              su_run;        // tsp_setup_min busy (tsp_start..tsp_done)
    reg              ts_pend;       // write triangle_setups this cycle (cycle after tsp_done)
    reg [IDW-1:0]    su_id;         // the active setup's id (write target)
`ifndef SYNTHESIS
    integer          su_dbg_cyc;   // +sutrace cycle counter
`endif

    // record_fetcher (demand only; FIFOs front & back hide its latency, no prefetch)
    reg              fx_start;
    reg  [31:0]      fx_tag;
    wire             fx_busy, fx_done;
    wire [31:0]      fx_isp, fx_tsp, fx_tcw;
    wire [31:0]      fx_x[0:2], fx_y[0:2], fx_z[0:2];
    wire [31:0]      fx_u[0:2], fx_v[0:2], fx_col[0:2], fx_ofs[0:2];
    record_fetcher u_fetch (
        .clk(clk), .reset(reset),
        .start(fx_start), .tag(fx_tag), .param_base(param_base),
        .intensity_shadow(intensity_shadow),
        .busy(fx_busy), .done(fx_done),
        .o_isp(fx_isp), .o_tsp(fx_tsp), .o_tcw(fx_tcw),
        .o_x(fx_x), .o_y(fx_y), .o_z(fx_z),
        .o_u(fx_u), .o_v(fx_v), .o_col(fx_col), .o_ofs(fx_ofs),
        .dreq(dreq), .dresp(dresp)
    );

    // latched decoded record of the tri being set up (feed tsp_setup_min)
    // fv_*/cur_isp: the verts + isp flags feeding tsp_setup_stream for the CURRENT setup
    // (su_id). public_flat_rd so the TB can snapshot them at ts_we and run an INDEPENDENT
    // refsw2 PlaneStepper3 golden (+planecheck).
    reg [31:0] cur_isp /*verilator public_flat_rd*/;
    reg [31:0] cur_tsp, cur_tcw;
    reg [31:0] fv_x[0:2] /*verilator public_flat_rd*/, fv_y[0:2] /*verilator public_flat_rd*/, fv_z[0:2] /*verilator public_flat_rd*/;
    reg [31:0] fv_u[0:2] /*verilator public_flat_rd*/, fv_v[0:2] /*verilator public_flat_rd*/, fv_col[0:2] /*verilator public_flat_rd*/, fv_ofs[0:2] /*verilator public_flat_rd*/;
    wire f_texture = cur_isp[ISP_TEXTURE_BIT];
    wire f_offset  = cur_isp[ISP_OFFSET_BIT];
    wire f_gouraud = cur_isp[ISP_GOURAUD_BIT];

    // tsp_setup_min: 10-plane producer
    reg              tsp_start;
    wire             tsp_done, tsp_pvalid;
    wire [3:0]       tsp_pidx;
    wire [31:0]      tsp_pddx, tsp_pddy, tsp_pc;
`ifndef SYNTHESIS
    // +uvvtx : the PER-VERTEX u/v (and x/y) handed to TSP setup, i.e. the values the
    // interpolated UV planes are built from. Raw hex - decode offline. This separates
    // "the submitted UVs are odd" from "the interpolation lost precision".
    always @(posedge clk) if (!reset && $test$plusargs("uvvtx") && start)
        $display("[UVVTX] xy1=%08x,%08x uv1=%08x,%08x | xy2=%08x,%08x uv2=%08x,%08x | xy3=%08x,%08x uv3=%08x,%08x",
                 fv_x[0], fv_y[0], fv_u[0], fv_v[0],
                 fv_x[1], fv_y[1], fv_u[1], fv_v[1],
                 fv_x[2], fv_y[2], fv_u[2], fv_v[2]);
`endif

    tsp_setup_stream u_tsp (
        // .rdy: back-to-back handshake unused here - spanner_v2 waits for done
        // (done implies rdy), so the legacy start-after-done flow still works.
        .clk(clk), .reset(reset), .start(tsp_start), .rdy(), .done(tsp_done),
        .gouraud(f_gouraud), .texture(f_texture), .offset(f_offset),
        .x1(fv_x[0]),.y1(fv_y[0]),.z1(fv_z[0]),
        .x2(fv_x[1]),.y2(fv_y[1]),.z2(fv_z[1]),
        .x3(fv_x[2]),.y3(fv_y[2]),.z3(fv_z[2]),
        .xbase(xbase), .ybase(ybase),
        .u1(fv_u[0]),.v1(fv_v[0]),.u2(fv_u[1]),.v2(fv_v[1]),.u3(fv_u[2]),.v3(fv_v[2]),
        .col1(fv_col[0]),.col2(fv_col[1]),.col3(fv_col[2]),
        .ofs1(fv_ofs[0]),.ofs2(fv_ofs[1]),.ofs3(fv_ofs[2]),
        .plane_valid(tsp_pvalid), .plane_idx(tsp_pidx),
        .o_ddx(tsp_pddx), .o_ddy(tsp_pddy), .o_c(tsp_pc)
    );

    // plane accumulators (written by tsp_setup_min's streamed plane_valid/plane_idx)
    reg [319:0] acc_ddx, acc_ddy, acc_c;

    // ============================ combinational OUT + FIFO drive ============================
    integer k;
    always @(*) begin
        // ----- EMIT: span write + FIFO push. The descriptor produced by COAL last cycle
        // is in t_* (t_valid); its slot read has resolved -> dedup here and write. Held
        // (no write, no advance) when the pipeline is frozen. -----
        // emit a span ONLY for a shaded run (t_ok); invalid runs retire silently.
        sp_we      = run_shaded && !pipe_stall;
        sp_slot    = span_head[SPAN_W-1:0]; // ring write slot = span_head (wraps)
        sp_start   = t_x;                  // run-start pixel index (y:x) [data for the reader]
        sp_id      = emit_id;              // bump-allocated (or reused) ring id
        sp_rep     = t_rep;
        sp_at      = t_at;
        for (k = 0; k < 4; k = k + 1) sp_invw[k] = t_invw[k];
        // span RING range of this pass (valid at busy->0). base = span_head at pass start,
        // cnt = span_head - base (wrap-safe via the extra MSB). cnt==0 => empty pass.
        sp_range_base = span_pass_base;
        sp_range_cnt  = span_head - span_pass_base;

        sf_push  = sp_we && needs_alloc;   // allocate -> push a setup
        sf_pdata = { emit_id, t_tag };

        // COAL group read address. A registered-read tag buffer updates its output EVERY
        // cycle from the presented address, so we drive rd_group to the group of the pixel
        // COAL will coalesce NEXT cycle, CONTINUOUSLY (don't rely on the read output
        // persisting across cycles). Next-coalesced pixel = sg_x_next if COAL fires this
        // cycle (advancing), else sg_x (idle/fill/held).
        rd_next_x = coal_fires ? sg_x_next : sg_x;
        // rd_valid MUST stay asserted through a pipe_stall: when it drops, the taginvw
        // read address collapses to group 0 (taginvw raddr defaults to 0 with rd4_valid=0),
        // so the NEXT cycle ti_* holds group 0's {tag,invW} instead of sg_x's group. If COAL
        // then fires (stall just cleared), it coalesces sg_x off group 0's STALE data
        // (observed on menu2: group 0 = px0-3,py0's invW leaking into an interior group after
        // a 1-cycle bubble). rd_next_x already = sg_x while stalled (coal_fires=0), so keeping
        // rd_valid high just re-presents sg_x's group -> ti_* is always correct when COAL resumes.
        rd_valid  = sg_active;
        // == { rd_next_x[SLOTW-1:2], 2'b00 }, without the adder (see sg_carry above).
        rd_group  = { (coal_fires && sg_carry) ? sg_grp_p1 : sg_grp, 2'b00 };

        // ----- SETUP -> triangle_setups write -----
        ts_we  = ts_pend;
        ts_id  = su_id;
        ts_isp = cur_isp;
        ts_tsp = cur_tsp;
        ts_tcw = cur_tcw;
        ts_ddx = acc_ddx;
        ts_ddy = acc_ddy;
        ts_c   = acc_c;
    end

`ifndef SYNTHESIS
    // EQUIVALENCE CHECK for the adder-free rd_group (see sg_carry). The whole
    // correctness argument for that transformation is an algebraic identity, so it is
    // CHECKED every cycle against the arithmetic it replaced rather than reasoned
    // about once. It must never fire; if it does, the fast path is wrong and every
    // span after it reads the wrong tile group.
    always @(posedge clk)
        if (!reset && sg_active && !$isunknown(rd_next_x) && !$isunknown(rd_group)
            && rd_group != { rd_next_x[SLOTW-1:2], 2'b00 }) begin
            $display("[spanner_v2] RD_GROUP MISMATCH @t=%0t: fast=%0d arith=%0d  (sg_x=%0d lane=%0d run_rep=%0d carry=%b coal=%b ext=%b ok=%b)",
                     $time, rd_group, { rd_next_x[SLOTW-1:2], 2'b00 },
                     sg_x, sg_lane, run_rep, sg_carry, coal_fires, sg_ext, sg_ok);
            $fatal(1);
        end
`endif

    // ============================ sequential ============================
    // pass done: SPANGEN drained + the whole setup path drained
    wire pass_done_w = busy && !start && !dd_clearing && !sg_active && !t_valid
                     && sf_empty && !fetch_busy && !pend_v && !su_run && !ts_pend;
`ifndef SYNTHESIS
    integer s_ret = 0, s_fresh = 0, s_setups = 0;
    final $display("=== SPANNER %m: passes retained=%0d fresh=%0d, setups fetched+computed=%0d ===",
                   s_ret, s_fresh, s_setups);
`endif
    integer q;
    always @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0; tsp_go <= 1'b0;
            sg_active <= 1'b0; sg_x <= '0; t_valid <= 1'b0;
            g_ready <= 1'b0;
            cur_gen <= GEN_MAX;           // force a clear-walk on the FIRST start (HW-safe
                                          // regardless of M10K power-up state)
            dd_clearing <= 1'b0;
            fwd0_valid <= 1'b0; fwd1_valid <= 1'b0;
            sf_wp <= '0; sf_rp <= '0;
            alloc_seq <= '0; ts_seq <= '0; gf_wp <= '0; gf_rp <= '0;
            ctx_val <= 1'b0; prev_xb <= '0; prev_yb <= '0;
            span_head <= '0; span_tail <= '0; span_pass_base <= '0;
            fetch_busy <= 1'b0; pend_v <= 1'b0; su_run <= 1'b0; ts_pend <= 1'b0;
            fx_start <= 1'b0; tsp_start <= 1'b0;
        end else begin
            fx_start  <= 1'b0;
            tsp_start <= 1'b0;
            tsp_go    <= 1'b0;            // 1-cyc pulse

            // ---------------- TSP drained a pass -> free its SPAN range ----------------
            // (plane liveness is the sliding window off cons_seq - no per-pass
            // plane frees; see the module-header window argument)
            if (tsp_rd_done && !gf_empty) begin
                span_tail <= sgf_mem[gf_rp[GF_AW-1:0]];
                gf_rp     <= gf_rp + 1'b1;
            end

            // ---------------- start a tile pass ----------------
            // RETAINED pass (same tile ctx): KEEP the generation - dedup entries
            // written by earlier passes of this era stay valid, so their planes
            // are REUSED (a hit emits the old id: no fetch, no setup). Otherwise
            // bump the generation so all prior buckets go stale for free (clear-
            // walk first on wrap).
            //
            // NO RING NORMALIZE (either ring). Both heads/tails free-run and wrap
            // by width; ids and slots are just RAM addresses and may start
            // anywhere. This deletes the old "idle -> snap to 0" special case and
            // its gf_empty guard (a normalize under a handed-but-unfreed pass
            // loaded a STALE tail on that pass's later tsp_rd_done -> spurious
            // full/empty -> SPANGEN deadlock). It is also REQUIRED by streaming:
            // the reader paces off the live span head, which must never move
            // backwards under it.
            if (start) begin
                busy  <= 1'b1;
                fwd0_valid <= 1'b0; fwd1_valid <= 1'b0;
                sf_wp <= '0; sf_rp <= '0;
                prev_xb <= xbase; prev_yb <= ybase; ctx_val <= 1'b1;
                span_pass_base <= span_head;   // this pass starts at the live head
                if (retain_ok) begin
                    sg_x <= '0; sg_active <= 1'b1;      // keep gen: cross-pass reuse
                    t_valid <= 1'b0; g_ready <= 1'b0;
`ifndef SYNTHESIS
                    s_ret <= s_ret + 1;
`endif
                end else if (cur_gen == GEN_MAX) begin
                    dd_clearing <= 1'b1; dd_clr_addr <= '0;   // SPANGEN idle until clear done
`ifndef SYNTHESIS
                    s_fresh <= s_fresh + 1;
`endif
                end else begin
                    cur_gen <= cur_gen + 1'b1;
                    sg_x <= '0; sg_active <= 1'b1; t_valid <= 1'b0; g_ready <= 1'b0;
`ifndef SYNTHESIS
                    s_fresh <= s_fresh + 1;
`endif
                end
            end
            if (ctx_inval) ctx_val <= 1'b0;   // render start: retained ctx is void

            // dedup_ram writes/reads are handled by the DEDICATED M10K block above
            // (dd_we/dd_waddr/dd_wdata write, dd_re/dd_raddr->dd_rd_q read).

            // ---------------- dedup clear-walk (gen wrap) ----------------
            if (dd_clearing) begin
                if (dd_clr_addr == NSLOT-1) begin
                    dd_clearing <= 1'b0; cur_gen <= {{(GEN_W-1){1'b0}}, 1'b1};   // gen=1
                    sg_x <= '0; sg_active <= 1'b1; t_valid <= 1'b0; g_ready <= 1'b0;
                end else dd_clr_addr <= dd_clr_addr + 1'b1;
            end

            // =================== FSM 1: SPANGEN pipeline (COAL + EMIT) ===================
            // Whole pipeline freezes on pipe_stall (setup FIFO full on an allocating emit).
            if (!pipe_stall) begin
                // ---------- EMIT: retire the descriptor produced last cycle ----------
                // On a MISS, allocate the next SEQUENCE number (slot = its low IDW
                // bits) and write the map bucket {cur_gen, tag, seq}. span write +
                // setup push are combinational (sp_*).
                if (t_valid && needs_alloc) begin
                    // dedup_ram[t_h] write is done by the single muxed port above (dd_emit_we).
                    alloc_seq <= alloc_seq + 1'b1;
                end
                // dense pack: only an EMITTED (shaded) span advances the ring head. Guarded
                // by !pipe_stall (this block), so a span-ring-full stall holds the head.
                if (run_shaded) span_head <= span_head + 1'b1;
                // forwarding shift: fwd0 = alloc this cycle (bucket t_h -> {tag,seq}).
                fwd1_valid <= fwd0_valid; fwd1_h <= fwd0_h; fwd1_seq <= fwd0_seq; fwd1_tag <= fwd0_tag;
                fwd0_valid <= t_valid && needs_alloc;
                fwd0_h     <= t_h;
                fwd0_seq   <= alloc_seq;
                fwd0_tag   <= t_tag;

                // ---------- COAL: coalesce one span off ti_* (the current group) ----------
                if (coal_fires) begin
`ifndef SYNTHESIS
                    // +ttspan: what the spanner READS for the first pixels of rows 0/1
                    if ($test$plusargs("ttspan") && (sg_x < 4 || (sg_x >= 32 && sg_x < 36)))
                        $display("[TTS] xb=%08x yb=%08x mode=%b sg_x=%0d val=%b tags=%08x %08x %08x %08x invw=%08x %08x rep=%0d ok0=%b",
                                 xbase, ybase, shade_mode, sg_x, ti_valid,
                                 ti_tag[0], ti_tag[1], ti_tag[2], ti_tag[3],
                                 {1'b0,ti_invw[0]}, {1'b0,ti_invw[1]}, run_rep, run_ok0);
                    if ($test$plusargs("coaltrace"))
                        $display("[COAL] sg_x=%0d rdgrp=%0d rdv=%b ti_tag=%08x %08x %08x %08x val=%b",
                                 sg_x, rd_group, rd_valid, ti_tag[0], ti_tag[1], ti_tag[2], ti_tag[3], ti_valid);
                    // +peelzero: in PEEL mode (shade_mode=0), catch a span emitted for a
                    // lane whose ti_invw==0 — the exact bad case (peel shading a pixel with
                    // valid=1 but zeroed invW). Shows the lane's valid/tag/invw.
                    if ($test$plusargs("peelzero") && !shade_mode && run_ok0
                        && ti_invw[sg_lane] == 31'd0)
                        $display("[PEELZERO] sg_x=%0d lane=%0d val=%b tag=%08x invw=%08x rep=%0d",
                                 sg_x, sg_lane, ti_valid, ti_tag[sg_lane], ti_invw[sg_lane], run_rep);
                    // catch a COAL emit where the START lane is shaded (span will be written)
                    // AND its captured invw would be 0 in PEEL mode — the reader-fed bad px.
                    if ($test$plusargs("peelzero") && !shade_mode && run_ok0 && sg_x < 8)
                        $display("[COALDBG] sg_x=%0d lane=%0d val=%b tag=%08x ti_invw[l]=%08x rep=%0d run_id=%0d",
                                 sg_x, sg_lane, ti_valid, ti_tag[sg_lane], ti_invw[sg_lane], run_rep, run_id);
`endif
                    t_valid  <= 1'b1;
                    t_x      <= sg_x;
                    t_h      <= run_id;            // dedup map bucket = pc_slot(run_tag)
                    t_tag    <= run_tag;
                    t_rep    <= run_rep;
                    t_ok     <= run_ok0;           // shaded run -> emit a span; else skip
                    t_at     <= ti_pt[sg_lane];
                    for (q = 0; q < 4; q = q + 1)
                        t_invw[q] <= (q < run_rep) ? ti_invw[sg_lane + q[1:0]] : 31'd0;
                    // the dedup read for THIS descriptor is presented by the dedicated M10K
                    // block above (dd_re == coal_fires, dd_raddr == run_id); dd_rd_q resolves
                    // next cycle in EMIT. run_id/coal_fires are stable this cycle.

                    // advance. The read for sg_x_next's group is presented THIS cycle
                    // (rd_group tracks rd_next_x continuously) -> ti_* is correct next cycle.
                    sg_x <= sg_x_next;
                    if (walk_last) sg_active <= 1'b0;
                    // g_ready stays 1 (a valid read was presented this cycle).
                end else begin
                    // fill bubble (post start/stall): no descriptor; the read of sg_x's
                    // group was presented this cycle -> ready next cycle.
                    t_valid <= 1'b0;
                end

                // g_ready: a valid read was presented this cycle (sg_active && !pipe_stall
                // is implied by being in this block); it lands next cycle. Cleared only at
                // start (below) so the first COAL waits one fill cycle.
                if (sg_active) g_ready <= 1'b1;
            end

            // =================== FIFO push ===================
            if (sf_push && !sf_full) begin
                sf_mem[sf_wp[SF_AW-1:0]] <= sf_pdata;
                sf_wp <= sf_wp + 1'b1;
`ifndef SYNTHESIS
                s_setups <= s_setups + 1;
`endif
            end

            // =================== SETUP path (streaming stages) ===================
`ifndef SYNTHESIS
            su_dbg_cyc <= start ? 0 : su_dbg_cyc + 1;
            if ($test$plusargs("sutrace")) begin
                if (!fetch_busy && !pend_v && !sf_empty)
                    $display("[SU c%0d] FETCH issue tag=%08x id=%0d", su_dbg_cyc, sf_head[31:0], sf_head[SF_W-1:32]);
                if (fetch_busy && fx_done)      $display("[SU c%0d] FETCH done id=%0d", su_dbg_cyc, fx_id);
                if (!su_run && !ts_pend && (pend_v || fx_done))
                                                $display("[SU c%0d] SETUP start id=%0d", su_dbg_cyc, fx_done ? fx_id : pend_id);
                if (su_run && tsp_done)         $display("[SU c%0d] SETUP done id=%0d", su_dbg_cyc, su_id);
                if (ts_pend)                    $display("[SU c%0d] WRITE id=%0d", su_dbg_cyc, su_id);
            end
`endif
            // ---- FETCH issue: pop the FIFO into the fetcher whenever it is free and the
            // pend skid is empty (the skid frees when setup accepts, so fetch N+1 runs
            // DURING setup N). fetch_busy covers the fx_start..fx_busy visibility gap.
            if (!fetch_busy && !pend_v && !sf_empty) begin
                fx_tag     <= sf_head[31:0];
                fx_id      <= sf_head[SF_W-1:32];
                fx_start   <= 1'b1;
                sf_rp      <= sf_rp + 1'b1;    // pop
                fetch_busy <= 1'b1;
            end

            // ---- FETCH complete -> pend skid (or straight into setup if it is idle) ----
            if (fetch_busy && fx_done) begin
                fetch_busy <= 1'b0;
                pend_v     <= 1'b1;
                pend_id    <= fx_id;
                pend_isp <= fx_isp; pend_tsp <= fx_tsp; pend_tcw <= fx_tcw;
                for (q = 0; q < 3; q = q + 1) begin
                    pend_x[q]<=fx_x[q]; pend_y[q]<=fx_y[q]; pend_z[q]<=fx_z[q];
                    pend_u[q]<=fx_u[q]; pend_v3[q]<=fx_v[q];
                    pend_col[q]<=fx_col[q]; pend_ofs[q]<=fx_ofs[q];
                end
            end

            // ---- SETUP accept: whenever tsp_setup_min is idle (and the previous write
            // retired), latch the pending record into cur_*/fv_* (held stable for the whole
            // run) and start. Bypass: accept straight off fx_done the same cycle. ----
            if (!su_run && !ts_pend && (pend_v || fx_done)) begin
                if (pend_v) begin
                    cur_isp <= pend_isp; cur_tsp <= pend_tsp; cur_tcw <= pend_tcw;
                    for (q = 0; q < 3; q = q + 1) begin
                        fv_x[q]<=pend_x[q]; fv_y[q]<=pend_y[q]; fv_z[q]<=pend_z[q];
                        fv_u[q]<=pend_u[q]; fv_v[q]<=pend_v3[q];
                        fv_col[q]<=pend_col[q]; fv_ofs[q]<=pend_ofs[q];
                    end
                    su_id  <= pend_id;
                    pend_v <= 1'b0;
                end else begin  // fx_done bypass (skid empty, setup idle)
                    cur_isp <= fx_isp; cur_tsp <= fx_tsp; cur_tcw <= fx_tcw;
                    for (q = 0; q < 3; q = q + 1) begin
                        fv_x[q]<=fx_x[q]; fv_y[q]<=fx_y[q]; fv_z[q]<=fx_z[q];
                        fv_u[q]<=fx_u[q]; fv_v[q]<=fx_v[q];
                        fv_col[q]<=fx_col[q]; fv_ofs[q]<=fx_ofs[q];
                    end
                    su_id  <= fx_id;
                    pend_v <= 1'b0;   // consumed in flight, skid stays empty
                end
                acc_ddx <= '0; acc_ddy <= '0; acc_c <= '0;
                tsp_start <= 1'b1;
                su_run <= 1'b1;
            end

            // ---- SETUP run: collect streamed planes; done -> 1-cycle write pulse ----
            if (tsp_pvalid) begin
                acc_ddx[32*tsp_pidx +: 32] <= tsp_pddx;
                acc_ddy[32*tsp_pidx +: 32] <= tsp_pddy;
                acc_c  [32*tsp_pidx +: 32] <= tsp_pc;
            end
            if (su_run && tsp_done) begin
                su_run  <= 1'b0;
                ts_pend <= 1'b1;      // ts_we fires (combinational) next cycle
            end else if (ts_pend) begin
                ts_pend <= 1'b0;
                ts_seq  <= ts_seq + 1'b1;   // one setup landed (alloc order)
            end

            // =================== busy / done -> tsp_go ===================
            // done when SPANGEN drained (not walking, EMIT stage empty) AND the whole setup
            // path is drained (FIFO, fetch, skid, setup run, write pulse). At that moment the
            // tile's setups are ALL in triangle_setups -> pulse tsp_go and record the span
            // END pointer so tsp_rd_done can free this pass's span range. Plane frees are
            // window-based off cons_seq, so there is no plane end pointer to record.
            if (pass_done_w) begin
                busy   <= 1'b0;
                tsp_go <= 1'b1;
                sgf_mem[gf_wp[GF_AW-1:0]] <= span_head;
                gf_wp <= gf_wp + 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    // one span write per cycle; ts write mutually exclusive per its FSM. Sanity: never
    // push a full FIFO, never pop an empty one.
    always @(posedge clk) if (!reset) begin
        if (sf_push && sf_full)
            $error("spanner_v2: setup FIFO overflow (push while full)");
        // a ring-free pulse with no outstanding handed pass would be silently dropped,
        // leaking ring space forever (permanent ring_full stall) - protocol violation.
        if (tsp_rd_done && gf_empty)
            $error("spanner_v2: tsp_rd_done with empty go-FIFO (free dropped)");
        // sliding-window sanity: alloc never runs past its capacity bound.
        if ((alloc_seq - cons_seq) > SEQ_W'(RING_N - WINDOW))
            $error("spanner_v2: alloc_seq ran past capacity (ahead=%0d)", alloc_seq - cons_seq);
    end
    // plane-lifetime scoreboard: ref_wm[slot] = watermark of the LAST span that
    // references the slot; an ALLOC (overwrite) of the slot while the reader has
    // not consumed past that watermark is a use-after-free.
    reg [SEQ_W-1:0] sb_ref_wm [0:RING_N-1];
    reg             sb_ref_v  [0:RING_N-1];
    always @(posedge clk) begin
        if (reset) begin : sbrst
            integer sbi;
            for (sbi = 0; sbi < RING_N; sbi = sbi + 1) sb_ref_v[sbi] = 1'b0;
        end else begin
            if (sp_we) begin
                sb_ref_wm[sp_id] <= emit_wm;
                sb_ref_v [sp_id] <= 1'b1;
            end
            if (dd_emit_we && sb_ref_v[alloc_seq[IDW-1:0]] && !(sp_we && sp_id == alloc_seq[IDW-1:0])
                && ((cons_seq - sb_ref_wm[alloc_seq[IDW-1:0]]) >> (SEQ_W-1)))
                $error("spanner_v2: plane slot %0d OVERWRITTEN while referenced (ref_wm=%0d cons=%0d alloc=%0d)",
                       alloc_seq[IDW-1:0], sb_ref_wm[alloc_seq[IDW-1:0]], cons_seq, alloc_seq);
        end
    end
    always @(posedge clk) if (!reset) begin
        if ((alloc_seq - ts_seq) > SEQ_W'(64))
            $error("spanner_v2: setup engine impossibly far behind (%0d)", alloc_seq - ts_seq);
    end
`endif
endmodule

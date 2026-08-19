//
// isp_primitive_iterator_pf - PREFETCHING variant of isp_primitive_iterator.
//
// Same function (walk STRIP/ARRAY entries, emit per-triangle XYZ core tags from
// the parameter buffer) and same refsw semantics, but the record burst READER and
// the triangle EMIT FSM are fully decoupled through a PING-PONG of two record
// buffers, and entries are pulled from a STREAMING input. This lets the reader
// fetch the NEXT record's data (paying DDR latency) WHILE the emit FSM is still
// draining the CURRENT record's triangles - so the per-record fetch is hidden
// behind the downstream setup, instead of serializing in front of it.
//
// Streaming entry interface (replaces start/entry/busy):
//   entry_valid : an entry is available on entry/entry_type (LEVEL)
//   entry_ack   : iterator consumed the entry this cycle (1-cycle pulse) ->
//                 the producer (isp_core) advances to the next entry
//   flush       : (LEVEL) no more entries will arrive for this list; once the
//                 iterator has drained everything it pulses `drained`.
//   drained     : (1-cycle) all pulled entries fully emitted AND flush seen ->
//                 the list is complete (barrier for isp_core).
//
// Triangle output (trio/ack) and refsw record/vertex layout are IDENTICAL to
// isp_primitive_iterator (see that file's header for the record math).
//
module isp_primitive_iterator_pf import tsp_pkg::*; (
    input                  clk,
    input                  reset,
    input      [26:0]      param_base,       // PARAM_BASE & 0xF00000 (byte addr)
    input                  intensity_shadow, // FPU_SHAD_SCALE.intensity_shadow

    // streaming entry input
    input                  entry_valid,      // an entry is available
    input      entry_type_e    entry_type,   // ENT_STRIP / ENT_TRI / ENT_QUAD
    input      objlist_entry_t entry,        // mask (STRIP) / count (ARRAY)
    input                  entry_pt,         // list-kind: this entry is from the PT list
                                             // (carried through to trio.is_pt per-triangle)
    input                  entry_early,      // this entry belongs to an EARLY-kicked
                                             // NEXT-pass walk consumed during the current
                                             // pass's drain: its records fetch/probe/claim
                                             // normally but WITHOUT the sort-cache filter
                                             // (verdicts are invalid until the pass's
                                             // demotes settle), and its triangles carry
                                             // trio.early so the caller can fence them
    input                  early_open,       // 1-cyc (pass decision): every in-flight
                                             // EARLY flag becomes CURRENT-pass - a
                                             // stale flag surviving into the next
                                             // pass's window would fence live work
                                             // as next-pass and deadlock the barrier
    output reg             entry_ack,        // 1-cycle: consumed the entry
    output                 busy,             // LEVEL: iterator has work in flight
                                             // (records read/being read/emitting).
                                             // isp_core's barrier gates on !busy &&
                                             // eq_empty (no flush/drained needed).
    output                 busy_live,        // LEVEL: busy with NON-early work only -
                                             // what the PASS BARRIER waits on (early
                                             // records belong to the NEXT pass and must
                                             // not hold the current pass open)

    // triangle output
    output triangle_out_t  trio,
    input  triangle_ack_t  ack,

    // ---- PRE-FETCH sort-cache check (peel pass >= 2) ----
    // Before committing a record's DDR burst, every triangle tag of that record
    // (constructible from the OL entry fields alone) is run through the sort
    // cache. A record whose every triangle is already "fully rendered" is
    // SKIPPED WITHOUT FETCHING (the old fq-head check paid the fetch first and
    // only saved setup+raster); a partially-done strip fetches once but emits
    // only the not-done triangles. The check tag is built with cache_bypass=0
    // (that bit lives in the not-yet-fetched ISP word): a cb=1 triangle simply
    // mismatches -> "not done" -> fetched and rendered normally (conservative).
    input                  skip_en,          // LEVEL: peeling && pass>=2 && sc_ready
    output reg             chk_valid,        // 1-cyc: check chk_tag
    output core_tag_t      chk_tag,
    input                  chk_valid_q,      // verdict strobe (1 cyc after chk_valid)
    input                  chk_done,         // 1 = fully rendered -> skippable
    // the check port is SHARED with the caller's pq-pop deferred check (the sort
    // filter for early-fetched triangles). chk_hold defers this walk's issues for
    // a cycle so the two can never collide; chk_src_q routes the strobes: this
    // walk's verdicts carry src=0, the caller's carry src=1 and are ignored here.
    input                  chk_hold,
    input                  chk_src_q,
    output reg             skp_pulse,        // 1-cyc: skipped skp_cnt triangles pre-fetch
    output reg [2:0]       skp_cnt,

    // ---- PRE-FETCH setup-cache probe (isp_setup_cache; TR/PT phases only) ----
    // Rides the SAME per-triangle walk as the sort-cache check above (chk_tag is
    // shared; a triangle's two verdicts land on the same cycle). A record whose
    // every SURVIVING triangle (enabled, not sort-skipped) hits is emitted as
    // lightweight CACHED triangles - its DDR burst is skipped entirely and the
    // fq consumer bypasses setup with the cached plane records. tc_pin pins a
    // surviving hit's index the cycle its verdict lands (chk_tag still presents
    // that triangle), so the entry cannot be evicted before it is consumed.
    input                  tc_en,            // LEVEL: cache active (peeling || pt_phase)
    output reg             tc_chk,           // 1-cyc: probe chk_tag
    input                  tc_vq,            // verdict strobe (1 cyc after tc_chk)
    input                  tc_hit,           // probe hit
    output reg             tc_pin,           // 1-cyc: pin chk_tag's index

    // direct DDR3 read port (64-bit beats, via shared arbiter)
    output ddr_rd_req_t    dreq,
    input  ddr_rd_resp_t   dresp
);
    // ================= per-buffer record state (NBUF-deep ring) =================
    // Each buffer holds one record's fetched data + the emit-relevant geometry.
    // NBUF was 2 (a ping-pong). It is now 4 so the reader can keep OUTS DDR bursts
    // in flight at once - see the READ DESCRIPTOR QUEUE below.
    localparam integer NBUF = 4;
    localparam integer BW   = $clog2(NBUF);
    localparam integer OUTS = 4;                 // max record bursts in flight
    xyz_t      vslot [0:NBUF-1][0:7];  // [buf][vertex] XYZ
    reg [31:0] b_isp   [0:NBUF-1];     // isp word
    reg        b_cached[0:NBUF-1];     // CACHED record: no burst, no verts - the fq
                                       // consumer reads the setup cache by tag
    reg [5:0]  b_hitm  [0:NBUF-1];     // per-triangle setup-cache HIT (strip order,
                                       // bit [5-i]; arrays use bit 5) -> trio.pinned
    reg        b_early [0:NBUF-1];     // record came from an early-pulled entry
                                       // -> trio.early, excluded from busy_live
    reg        b_pt    [0:NBUF-1];     // list-kind (PT) of this record, -> trio.is_pt
    reg [5:0]  b_mask  [0:NBUF-1];     // strip mask
    reg [2:0]  b_skip  [0:NBUF-1];
    reg        b_shadow[0:NBUF-1];
    reg [20:0] b_po    [0:NBUF-1];     // param_offs_in_words of this record
    reg        b_array [0:NBUF-1];     // 1 = array record (tag_offset 0), 0 = strip
    reg        b_quad  [0:NBUF-1];     // 1 = QUAD array record (4 verts, -> trio.quad)
    reg [3:0]  b_nfill [0:NBUF-1];     // vertices captured (Z landed)
    reg        b_ready [0:NBUF-1];     // buffer holds a complete/streaming record
    reg        b_done  [0:NBUF-1];     // buffer's burst fully read (all verts in)
    reg        b_infl  [0:NBUF-1];     // burst ISSUED into this buffer, beats not in yet

    // ================= READ DESCRIPTOR QUEUE (pipelined DDR reads) =================
    // The reader used to be strictly one-burst-at-a-time: R_REQ issued, R_STREAM
    // consumed every beat, only then could the next record issue. The DDR bus went
    // IDLE for the whole round trip between records - measured at 37% of the window on
    // sa_slow2, where the record fetcher owns the bus 86% of the time and the entire
    // ISP front-end starves behind it (EQ full 66%, FQ/PQ empty >90%, raster idle 26%).
    //
    // Now ISSUE and RECEIVE are decoupled. The arbiter returns this client's beats in
    // ISSUE ORDER, so the receiver only ever parses ONE burst at a time and simply
    // needs to know which record the beats at the head belong to - that is this queue.
    // Only the PARSE-relevant fields ride it; everything else (mask/skip/shadow/pt/po/
    // array/quad) is published into b_* at ISSUE time, which is safe because emit does
    // not look at a buffer until b_ready[buf] goes up at burst completion.
    reg [BW-1:0] dq_buf    [0:OUTS-1];
    reg [8:0]    dq_span   [0:OUTS-1];
    reg [4:0]    dq_hdr    [0:OUTS-1];
    reg [4:0]    dq_stride [0:OUTS-1];
    reg [$clog2(OUTS)-1:0] dq_head, dq_tail;
    reg [$clog2(OUTS):0]   dq_cnt;
    wire dq_empty = (dq_cnt == 0);
    wire dq_full  = (dq_cnt == OUTS[$clog2(OUTS):0]);
    // last beat of the burst currently landing
    // (declared with the queue; used by both the issue and receive sides)
    // the burst currently landing = queue head
    wire [BW-1:0] cur_buf    = dq_buf   [dq_head];
    wire [8:0]    cur_span   = dq_span  [dq_head];
    wire [4:0]    cur_hdr    = dq_hdr   [dq_head];
    wire [4:0]    cur_stride = dq_stride[dq_head];
    wire          rx_last    = !dq_empty && dresp.dready && (beat == cur_span - 9'd1);

    // ================= entry expansion (array -> multiple records) =================
    // The reader owns record advancement. For an array entry we expand `count`
    // records; for a strip, one record. This state tracks the entry currently
    // being expanded by the READER (independent of what emit is draining).
    reg        ex_active;              // an entry is being expanded by the reader
    reg        ex_array;
    reg        ex_quad;                // array entry is a QUAD array (4 verts/record)
    reg [2:0]  ex_skip;   reg ex_shadow;   reg [5:0] ex_mask;
    reg        ex_ispt;                // list-kind of the entry being expanded
    reg [20:0] ex_po;                  // running param_offs of the next record
    reg [26:0] ex_base;                // running byte base of the next record
    reg [4:0]  ex_count;               // records remaining (array); 1 for strip
    wire       ex_two_vol   = ex_shadow & ~intensity_shadow;
    wire [4:0] ex_stride_w  = 5'd3 + ex_skip * (ex_two_vol ? 5'd2 : 5'd1);
    wire [4:0] ex_hdr_words = ex_two_vol ? 5'd5 : 5'd3;
    // (rec_bytes/rec_words are now computed in the staged exg_* pipeline below)
    // For a STRIP, read only up to the LAST vertex any enabled triangle needs, not
    // all 8. Triangle i (mask[5-i]) uses verts i,i+1,i+2; the highest enabled i =
    // 5 - (lowest set bit of mask), so verts needed = (5-lsb)+3 = 8-lsb. (Array
    // records always read exactly 3.)
    function automatic [2:0] lsb6(input [5:0] m);
        casez (m)
            6'b?????1: lsb6 = 3'd0;
            6'b????10: lsb6 = 3'd1;
            6'b???100: lsb6 = 3'd2;
            6'b??1000: lsb6 = 3'd3;
            6'b?10000: lsb6 = 3'd4;
            6'b100000: lsb6 = 3'd5;
            default:   lsb6 = 3'd5;   // mask==0 (no tris): read minimal (3 verts)
        endcase
    endfunction
    wire [3:0] ex_strip_nv = 4'd8 - {1'b0, lsb6(ex_mask)};   // 3..8
    wire [3:0] ex_nverts   = ex_array ? (ex_quad ? 4'd4 : 4'd3) : ex_strip_nv;

    // ---- per-ENTRY geometry pre-computation (2 shallow stages) ----
    // The record geometry (stride/hdr/span/rec_bytes/rec_words) is CONSTANT for the
    // whole entry (shadow/skip/mask/array never change between an array entry's
    // records), but computing it combinationally at the record-start latch put the
    // whole ex_shadow -> stride-mux -> (nverts-1)*stride multiply cone (plus the
    // parallel 3*stride rec_bytes multiply) into that one cycle - the ~15ns
    // ex_shadow -> rd_span_r Fmax violator. Split it per ENTRY instead:
    //   E+1 (exg_s1_v): register the shallow terms (stride, hdr, nverts-1) off ex_*.
    //   E+2 (exg_v)   : register the products (span, rec_bytes, rec_words) off the
    //                   STAGE-1 REGISTERS - each multiply gets its own clean cycle.
    // Record start then copies plain registers (no logic). Costs +2 cycles per
    // entry, amortized over all its records.
    reg        exg_s1_v, exg_v;
    reg [4:0]  exg_stride_r, exg_hdr_r;
    reg [3:0]  exg_nm1_r;                       // nverts - 1
    reg [8:0]  exg_span_r;
    reg [26:0] exg_recb_r;
    reg [20:0] exg_recw_r;
    // stage-2 combinational (from stage-1 registers; same expressions/widths as the
    // old ex_span_vw / ex_rec_bytes / ex_rec_words, only the sources changed).
    // rec_bytes = (hdr + nverts*stride)*4 with nverts*stride = nm1*stride + stride,
    // sharing the one nm1*stride product with the span (was a hard-coded 3*stride,
    // wrong for QUAD arrays which carry 4 vertices per record).
    wire [8:0]  exg_nvs_c  = {5'b0, exg_nm1_r} * {4'b0, exg_stride_r};   // (nverts-1)*stride
    wire [8:0]  exg_span_c = {4'b0, exg_hdr_r} + exg_nvs_c + 9'd3;
    wire [26:0] exg_recb_c = {22'b0, exg_hdr_r, 2'b00}
                           + {16'b0, exg_nvs_c, 2'b00}
                           + {20'b0, exg_stride_r, 2'b00};
    wire [20:0] exg_recw_c = exg_recb_c[22:2];

    // outstanding-record bookkeeping: reader has fetched (or is fetching) records
    // that emit has not yet finished. flush + none-outstanding + reader idle -> done.
    reg [3:0]  outstanding;            // records fetched-but-not-emitted

    // ================= pre-fetch sort$ check state =================
    // Runs CONCURRENTLY with the exg_* geometry pipeline off the live ex_* cursor
    // (ex_po is always the NEXT record to fetch), one verdict per triangle:
    //   array record : one tag {ex_po, toff=0}            -> pc_skip
    //   strip record : one tag per enabled mask bit       -> pc_fmask (survivors)
    // pc_v gates the record start; re-armed (cleared) per record.
    reg        pe_en;                  // skip_en latched at entry pull (stable per entry)
    reg        tcl;                    // tc_en latched at entry pull (stable per entry)
    reg        exl_early;              // entry_early latched at entry pull
    reg        pc_v;                   // verdicts complete for the next record
    reg        pc_skip;                // array: record fully rendered -> skip fetch
    reg [5:0]  pc_fmask;               // strip: enabled AND not-done (same bit order
                                       //        as ex_mask: triangle i at bit [5-i])
    reg        tc_hit1;                // array: surviving triangle hit the setup cache
    reg [5:0]  tc_hitm;                // strip: surviving triangles that hit
    reg [2:0]  pc_i;                   // strip triangle index (toff) being checked
    reg        tcc_pulse;              // BLOCKING temp: a cached record was claimed
                                       // this cycle (read by os_update below)
    localparam PC_IDLE=2'd0, PC_ISSUE=2'd1, PC_WAIT=2'd2;
    reg [1:0]  pcs;
    // NOTE: pass the per-slot fields IN (read the arrays at the call site) rather
    // than indexing them inside the function - Quartus 17.0's Verific frontend
    // crashes ("read to RAM wasn't mapped") on an array read via a function-arg
    // index inside an assignment-pattern.
    function automatic core_tag_t mk_tag(input isp_cbp, input shdw,
                                         input [2:0] skp, input [20:0] po,
                                         input [2:0] toff);
        mk_tag = '{ invalid:1'b0, pad:2'b00,
                    cache_bypass:isp_cbp, shadow:shdw, skip:skp,
                    param_offs_in_words:po, tag_offset:toff };
    endfunction
    // check tag: cache_bypass unknown pre-fetch -> 0 (see port comment)
    assign chk_tag = mk_tag(1'b0, ex_shadow, ex_skip, ex_po,
                            ex_array ? 3'd0 : pc_i);
    // the record about to start is entirely skippable
    wire pc_rec_skip = ex_array ? pc_skip : (pc_fmask == 6'd0);
    // ...or entirely resident in the setup cache: every SURVIVING triangle hit.
    // (When the sort filter is off, every enabled triangle is a survivor.)
    wire [5:0] surv_mask  = (pe_en && !ex_array) ? pc_fmask : ex_mask;
    wire       tc_rec_hit = tcl && pc_v
                          && (ex_array ? tc_hit1
                                       : (surv_mask != 6'd0)
                                         && ((surv_mask & ~tc_hitm) == 6'd0));
    function automatic [2:0] cnt6(input [5:0] m);
        cnt6 = {2'd0,m[0]} + {2'd0,m[1]} + {2'd0,m[2]}
             + {2'd0,m[3]} + {2'd0,m[4]} + {2'd0,m[5]};
    endfunction

    // LEVEL busy: any record buffered, being read, being expanded, being emitted,
    // or any outstanding. This is the AUTHORITATIVE producer-idle signal for the
    // isp_core barrier (a pulse-cleared reg was racy).

    // ================= burst reader (fills rd_buf) =================
    reg [BW-1:0] rd_buf;               // buffer the reader is filling (issue cursor)
    // geometry of the record currently being READ (latched when reader starts it)
    reg [26:0] rd_base;   reg [2:0] rd_skip;  reg rd_shadow; reg [5:0] rd_mask;
    reg [20:0] rd_po;     reg rd_array;      reg rd_quad;
    reg [5:0]  rd_hitm;   // per-triangle setup-cache hits of the record being read
    reg        rd_early;  // record comes from an early-pulled entry
    // Record geometry (span/header/stride) is CONSTANT for the whole record and
    // depends only on the latched shadow/skip/mask/array. Computing the span
    // combinationally (it has a multiply) used to feed the per-beat
    // `beat==span-1` end-of-record comparator straight from rd_shadow -> the 100 MHz
    // critical path. Instead we precompute the geometry from the ex_* sources at the
    // R_IDLE latch and REGISTER it here, so the per-beat comparator and the
    // need_off_r stepping read plain registers, not a rd_shadow->multiply chain.
    reg  [8:0] rd_span_r;              // record span in vwords, registered at start
    reg  [4:0] rd_hdr_r, rd_stride_r;  // header words / per-vertex stride, registered
    // ex_rec_bytes/ex_rec_words are ALSO constant for the whole entry (skip/shadow
    // never change between records of an array entry) but were combinational (a
    // by-3 multiply) gated into the ex_base/ex_po register write by the same
    // end-of-record comparator. Register them at record start too, so that write is
    // a plain add of a registered increment, not shadow->multiply->gated-write.
    reg  [26:0] rd_rec_bytes_r;
    reg  [20:0] rd_rec_words_r;

    wire [24:0] rd_base_vw  = rd_base[26:2];
    wire [20:0] rd_view     = rd_base_vw[20:0];   // 32-bit view word (bank = bit 20)

    reg  [5:0]  ni;                    // needed-item index
    wire        ni_isp = (ni == 6'd0);
    reg  [3:0]  ni_vx;                 // vertex index (tracked, no divider)
    reg  [1:0]  ni_cmp;                // component (0=x,1=y,2=z)
    // need_off used to be combinational: hdr + ni_vx*stride + ni_cmp. That per-beat
    // MULTIPLY, fed by rd_shadow (via rd_stride_w/rd_hdr_words) and compared against
    // `beat`, then gating the vslot write, was the 100 MHz critical path. Instead we
    // ACCUMULATE it in a register: same value, no multiply and no rd_shadow->compare
    // combinational chain (rd_shadow now only feeds the small +1 / +stride-2 step).
    //   +1        stepping a component within a vertex (c: 0->1, 1->2)
    //   +stride-2 crossing z of vertex v to x of vertex v+1
    // Seeded at the ISP word (need_off_r=0); on the ISP->first-vertex transition it
    // jumps to rd_hdr_words. Max value ~ 5 + 7*9 + 2 = 70, fits in 9 bits.
    reg  [8:0]  need_off_r;
    wire [8:0]  need_off = need_off_r;

    localparam R_IDLE=2'd0, R_REQ=2'd1, R_STREAM=2'd2;
    reg [1:0]  rst;
    reg [8:0]  beat;
    wire [31:0] beat_half = dresp.dout32;   // the arbiter selected the half

    reg        dreq_rd_r; reg [28:0] dreq_addr_r; reg [7:0] dreq_burst_r;
    assign dreq.rd    = dreq_rd_r;
    assign dreq.addr  = dreq_addr_r;
    assign dreq.burst = dreq_burst_r;
    assign dreq.w32   = 1'b1;   // 32-bit view: the arbiter shuffles + drops the half

    // ================= emit FSM (drains em_buf) =================
    reg [BW-1:0] em_buf;               // buffer emit is draining
    reg        tri_ready_r;
    xyz_t      v0_r, v1_r, v2_r;
    core_tag_t tag_r;
    reg        pin_r;     // this triangle hit the setup cache -> its pop unpins
    assign trio.triangle_ready = tri_ready_r;
    assign trio.isp            = b_isp[em_buf];
    assign trio.is_pt          = b_pt[em_buf];
    assign trio.v0 = v0_r; assign trio.v1 = v1_r; assign trio.v2 = v2_r;
    // QUAD 4th vertex: read straight off the presented buffer (stable while
    // b_ready, like b_isp; only meaningful when trio.quad). Its Z is never used.
    assign trio.quad = b_quad[em_buf];
    assign trio.v3x  = vslot[em_buf][3].x;
    assign trio.v3y  = vslot[em_buf][3].y;
    assign trio.tag            = tag_r;
    assign trio.cached         = b_cached[em_buf];   // setup-cache resident (no verts)
    assign trio.pinned         = pin_r;              // its fq pop must unpin
    assign trio.early          = b_early[em_buf];    // next-pass triangle (pq fence)
    assign trio.prim_done      = 1'b0;   // not used by isp_core-pf path (drained instead)

    function automatic [3:0] va(input [2:0] i); va = {1'b0,i} + (i[0] ? 4'd1 : 4'd0); endfunction
    function automatic [3:0] vb(input [2:0] i); vb = {1'b0,i} + (i[0] ? 4'd0 : 4'd1); endfunction

    // (mk_tag moved up beside the pre-fetch check state, which also uses it.)

    integer    rbi;                    // reset loop index over the NBUF buffers
    localparam E_IDLE=2'd0, E_SEEK=2'd1, E_PRESENT=2'd2, E_REL=2'd3;
    reg [1:0]  est;
    reg [2:0]  s_i;

    // authoritative LEVEL busy: anything in flight anywhere in the iterator.
    // any buffer ready-or-in-flight, or a descriptor still queued, counts as busy.
    wire b_any_live = b_ready[0] || b_ready[1] || b_ready[2] || b_ready[3]
                    || b_infl [0] || b_infl [1] || b_infl [2] || b_infl [3];
    assign busy = ex_active || (rst != R_IDLE) || (est != E_IDLE)
                || (outstanding != 4'd0) || b_any_live || !dq_empty;
    // busy with NON-early work only: everything the current pass's barrier must
    // wait for. In-order processing means early work is always the TAIL, so per-
    // buffer/expansion flags classify it exactly. (dq beats are covered by b_infl;
    // outstanding/emit are covered by b_ready + the est term.)
    wire bl_buf = ((b_ready[0] || b_infl[0]) && !b_early[0])
               || ((b_ready[1] || b_infl[1]) && !b_early[1])
               || ((b_ready[2] || b_infl[2]) && !b_early[2])
               || ((b_ready[3] || b_infl[3]) && !b_early[3]);
    assign busy_live = (ex_active && !exl_early)
                    || (rst != R_IDLE && !rd_early)
                    || bl_buf
                    || ((est != E_IDLE) && !b_early[em_buf]);

    always @(posedge clk) begin
        if (reset) begin
            rst<=R_IDLE; est<=E_IDLE; dreq_rd_r<=0; entry_ack<=0;
            rd_buf<=0; em_buf<=0; ex_active<=0; outstanding<=0;
            exg_s1_v<=0; exg_v<=0;
            dq_head<=0; dq_tail<=0; dq_cnt<=0; beat<=0;
            for (rbi=0; rbi<NBUF; rbi=rbi+1) begin
                b_ready[rbi]<=1'b0; b_done[rbi]<=1'b0; b_infl[rbi]<=1'b0;
            end
            tri_ready_r<=0;
            pe_en<=0; pc_v<=0; pcs<=PC_IDLE; chk_valid<=0; skp_pulse<=0;
            tcl<=0; tc_chk<=0; tc_pin<=0; exl_early<=0; rd_early<=0;
            for (rbi=0; rbi<NBUF; rbi=rbi+1) b_early[rbi]<=1'b0;
        end else begin
            entry_ack <= 1'b0;
            dreq_rd_r <= 1'b0;
            chk_valid <= 1'b0;
            tc_chk    <= 1'b0;
            tc_pin    <= 1'b0;
            skp_pulse <= 1'b0;
            tcc_pulse  = 1'b0;   // blocking: set by the cached-record claim below

            // ====== PRE-FETCH SORT$ CHECK + SETUP$ PROBE (concurrent with exg_*) ======
            // Collect verdicts for the NEXT record (ex_po cursor). ONE walk serves
            // both caches: each triangle's tag is presented once, chk_valid probes
            // the sort cache (only when the skip filter is armed), tc_chk probes the
            // setup cache (only in TR/PT phases), and both verdicts land on the same
            // cycle. 1-in-flight (issue, wait strobe, next) - a strip's <=6 checks
            // cost ~2 cycles each vs the ~30+-cycle fetch they can save.
            case (pcs)
            PC_IDLE: if (ex_active && (pe_en || tcl) && !pc_v && !chk_hold) begin
                if (ex_array) begin
                    chk_valid <= pe_en;                   // single tag, toff=0
                    tc_chk    <= tcl;
                    tc_hit1   <= 1'b0;
                    pcs <= PC_WAIT;
                end else begin
                    pc_fmask <= 6'd0;
                    tc_hitm  <= 6'd0;
                    pc_i     <= 3'd0;
                    pcs <= PC_ISSUE;
                end
            end
            PC_ISSUE: begin   // strip: check triangle pc_i if enabled, else advance
                if (ex_mask[3'd5 - pc_i]) begin
                    if (!chk_hold) begin                  // yield the shared port
                        chk_valid <= pe_en;
                        tc_chk    <= tcl;
                        pcs <= PC_WAIT;
                    end
                end else if (pc_i == 3'd5) begin
                    pc_v <= 1'b1; pcs <= PC_IDLE;
                end else pc_i <= pc_i + 3'd1;
            end
            // wait for OUR strobe: sort verdicts routed by src (src=1 belongs to the
            // caller's pq-pop checker); the private tc port needs no routing.
            PC_WAIT: if (pe_en ? (chk_valid_q && !chk_src_q) : tc_vq) begin : pc_verdict
                // a SURVIVOR renders this pass (enabled, not sort-skipped). Its
                // setup-cache hit is claimed NOW: tc_pin pins the index while
                // chk_tag still presents this triangle, so the entry cannot be
                // evicted before the fq consumer reads it (partial-hit records'
                // pinned triangles flow through setup and unpin at that pop).
                reg surv, hit;
                surv = !(pe_en && chk_done);
                hit  = tcl && tc_hit && surv;
                tc_pin <= hit;
                if (ex_array) begin
                    pc_skip <= pe_en && chk_done;
                    tc_hit1 <= hit;
                    pc_v <= 1'b1; pcs <= PC_IDLE;
                end else begin
                    if (surv) pc_fmask[3'd5 - pc_i] <= 1'b1;   // survivor
                    if (hit)  tc_hitm [3'd5 - pc_i] <= 1'b1;
                    if (pc_i == 3'd5) begin pc_v <= 1'b1; pcs <= PC_IDLE; end
                    else begin pc_i <= pc_i + 3'd1; pcs <= PC_ISSUE; end
                end
            end
            default: pcs <= PC_IDLE;
            endcase

            // ==================== READER ====================
            // Continuously: if not expanding an entry, pull the next entry; else
            // fetch the next record of the current entry into the FREE buffer.
            // dq_cnt decrement on a completing burst when no issue happens this cycle
            // (the issue path folds the -1 into its own += 1 above).
            if (rx_last && !(rst == R_REQ && !dresp.busy && !dq_full))
                dq_cnt <= dq_cnt - 1'b1;

            case (rst)
            R_IDLE: begin
                if (!ex_active) begin
                    // pull a new entry to expand (if the target buffer is free)
                    if (entry_valid && !b_ready[rd_buf] && !b_infl[rd_buf]) begin
                        ex_active <= 1'b1;
                        ex_array  <= (entry_type != ENT_STRIP);
                        ex_quad   <= (entry_type == ENT_QUAD);
                        ex_skip   <= entry.skip;
                        ex_shadow <= entry.shadow;
                        ex_ispt   <= entry_pt;      // list-kind, held for all this entry's records
                        ex_mask   <= entry.mask;
                        ex_po     <= entry.param_offs_in_words;
                        ex_base   <= param_base + {entry.param_offs_in_words, 2'b00};
                        ex_count  <= (entry_type != ENT_STRIP) ? entry.count : 5'd1;
                        exg_s1_v  <= 1'b0;     // geometry pipeline restarts for this entry
                        exg_v     <= 1'b0;
                        // NO sort filter for early entries: their verdicts would read
                        // demotes that have not settled (the current pass is still
                        // rastering) - a false "done" would drop live geometry. They
                        // fetch unfiltered; the setup-cache probe (tcl) is
                        // pass-invariant and stays on, so most re-walked records are
                        // cache hits and never touch DDR anyway.
                        pe_en     <= skip_en && !entry_early;
                        tcl       <= tc_en;    // setup-cache probing, stable per entry
                        exl_early <= entry_early;
                        pc_v      <= 1'b0;     // re-arm the pre-check for record 0
                        pcs       <= PC_IDLE;
                        entry_ack <= 1'b1;     // consume it; producer advances
                    end
                end else if (!exg_s1_v) begin
                    // entry geometry, stage 1: the shallow terms off the ex_* latches
                    exg_stride_r <= ex_stride_w;
                    exg_hdr_r    <= ex_hdr_words;
                    exg_nm1_r    <= ex_nverts - 4'd1;
                    exg_s1_v     <= 1'b1;
                end else if (!exg_v) begin
                    // entry geometry, stage 2: the products, off the stage-1 REGISTERS
                    exg_span_r <= exg_span_c;
                    exg_recb_r <= exg_recb_c;
                    exg_recw_r <= exg_recw_c;
                    exg_v      <= 1'b1;
                end else if ((pe_en || tcl) && !pc_v) begin
                    // wait for the pre-fetch sort$/setup$ verdicts of this record
                end else if (pe_en && pc_rec_skip) begin
                    // every triangle of this record is already fully rendered:
                    // SKIP ITS FETCH - advance the expansion cursor directly.
                    skp_pulse <= 1'b1;
                    skp_cnt   <= ex_array ? 3'd1 : cnt6(ex_mask);
                    pc_v      <= 1'b0;                 // re-check the next record
                    if (ex_array && ex_count != 5'd1) begin
                        ex_count <= ex_count - 5'd1;
                        ex_base  <= ex_base + exg_recb_r;
                        ex_po    <= ex_po   + exg_recw_r;
                    end else ex_active <= 1'b0;        // entry done expanding
                end else if (tc_rec_hit && !b_ready[rd_buf] && !b_infl[rd_buf]) begin
                    // CACHED record: every surviving triangle's setup parameters
                    // are resident (and pinned) in the setup cache - NO DDR burst,
                    // no vertex data. Publish the buffer directly as ready with
                    // the cached flag; emit presents each surviving triangle as a
                    // lightweight CACHED trio (tag only) and the fq consumer
                    // bypasses setup with the cached plane records. Expansion
                    // advances exactly as R_REQ does.
                    b_mask [rd_buf] <= surv_mask;
                    b_skip [rd_buf] <= ex_skip;
                    b_shadow[rd_buf]<= ex_shadow;
                    b_pt   [rd_buf] <= ex_ispt;
                    b_po   [rd_buf] <= ex_po;
                    b_array[rd_buf] <= ex_array;
                    b_quad [rd_buf] <= ex_quad;
                    b_cached[rd_buf]<= 1'b1;
                    b_hitm [rd_buf] <= ex_array ? {tc_hit1, 5'b0} : tc_hitm;
                    b_early[rd_buf] <= exl_early;
                    b_isp  [rd_buf] <= 32'd0;   // cb=0, matching the cb=0 probe tag
                                                // that hit (a cb=1 fill is refused, so
                                                // a hit PROVES the record's cb was 0);
                                                // the real ISP word rides the cached
                                                // plane record into pq
                    b_nfill[rd_buf] <= 4'd8;    // no vertex waits in emit
                    b_done [rd_buf] <= 1'b1;
                    b_ready[rd_buf] <= 1'b1;
                    rd_buf  <= rd_buf + 1'b1;
                    tcc_pulse = 1'b1;           // outstanding++ (see os_update)
                    pc_v    <= 1'b0;            // re-check the next record
                    if (ex_array && ex_count != 5'd1) begin
                        ex_count <= ex_count - 5'd1;
                        ex_base  <= ex_base + exg_recb_r;
                        ex_po    <= ex_po   + exg_recw_r;
                    end else ex_active <= 1'b0;        // entry done expanding
                end else if (!b_ready[rd_buf] && !b_infl[rd_buf] && !dq_full) begin
                    // start the next record of the current entry into rd_buf.
                    // Strips carry the FILTERED mask (pre-checked done triangles
                    // dropped) so emit never presents an already-rendered one.
                    if (pe_en && !ex_array && cnt6(pc_fmask) != cnt6(ex_mask)) begin
                        skp_pulse <= 1'b1;             // partial-strip skip stat
                        skp_cnt   <= cnt6(ex_mask) - cnt6(pc_fmask);
                    end
                    rd_base   <= ex_base;
                    rd_skip   <= ex_skip;
                    rd_shadow <= ex_shadow;
                    rd_mask   <= (pe_en && !ex_array) ? pc_fmask : ex_mask;
                    rd_po     <= ex_po;
                    rd_array  <= ex_array;
                    rd_quad   <= ex_quad;
                    // a PARTIALLY-hit record fetches, but its hit triangles are
                    // still PINNED (claimed at their verdicts) - carry the hit
                    // mask so each one's fq pop unpins (trio.pinned).
                    rd_hitm   <= tcl ? (ex_array ? {tc_hit1, 5'b0} : tc_hitm) : 6'd0;
                    rd_early  <= exl_early;
                    // record geometry: plain register-to-register copies of the
                    // per-entry pre-computed values (no logic in this latch - the
                    // ex_shadow -> multiply cone was the Fmax violator here).
                    rd_span_r      <= exg_span_r;
                    rd_hdr_r       <= exg_hdr_r;
                    rd_stride_r    <= exg_stride_r;
                    rd_rec_bytes_r <= exg_recb_r;
                    rd_rec_words_r <= exg_recw_r;
                    rst       <= R_REQ;
                end
            end
            // ISSUE ONLY. Fires the burst and goes straight back to R_IDLE so the next
            // record can be prepared and issued while this one's beats are still in
            // flight. The RECEIVER below lands the beats. Everything the emit side will
            // need is published into b_* HERE (safe: emit gates on b_ready, which only
            // goes up at completion), so the descriptor queue carries just the four
            // parse fields.
            R_REQ: if (!dresp.busy && !dq_full) begin
                dreq_rd_r    <= 1'b1;
                dreq_addr_r  <= {8'd0, rd_view}; // 32-bit view word; arbiter shuffles
                dreq_burst_r <= rd_span_r[7:0];
                b_nfill[rd_buf] <= 4'd0;
                b_done [rd_buf] <= 1'b0;
                b_infl [rd_buf] <= 1'b1;
                // publish the emit-facing geometry now, while rd_*/ex_* still describe
                // THIS record - by the time its beats land, expansion has moved on.
                b_mask [rd_buf] <= rd_mask;
                b_skip [rd_buf] <= rd_skip;
                b_shadow[rd_buf]<= rd_shadow;
                b_pt   [rd_buf] <= ex_ispt;
                b_po   [rd_buf] <= rd_po;
                b_array[rd_buf] <= rd_array;
                b_quad [rd_buf] <= rd_quad;
                b_cached[rd_buf]<= 1'b0;   // a fetched record is never CACHED
                b_hitm [rd_buf] <= rd_hitm;
                b_early[rd_buf] <= rd_early;
                // enqueue the parse descriptor
                dq_buf   [dq_tail] <= rd_buf;
                dq_span  [dq_tail] <= rd_span_r;
                dq_hdr   [dq_tail] <= rd_hdr_r;
                dq_stride[dq_tail] <= rd_stride_r;
                dq_tail <= dq_tail + 1'b1;
                dq_cnt  <= dq_cnt + 1'b1 - (rx_last ? 1'b1 : 1'b0);
                rd_buf  <= rd_buf + 1'b1;
                // advance the entry expansion HERE (it used to happen at burst end).
                if (ex_array && ex_count != 5'd1) begin
                    ex_count <= ex_count - 5'd1;
                    ex_base  <= ex_base + rd_rec_bytes_r;
                    ex_po    <= ex_po   + rd_rec_words_r;
                    pc_v     <= 1'b0;      // re-arm the pre-check for the next record
                end else begin
                    ex_active <= 1'b0;     // entry done expanding
                end
                rst <= R_IDLE;
            end
            default: rst <= R_IDLE;
            endcase

            // ==================== BURST RECEIVER ====================
            // Independent of the issue FSM above. This client's beats come back in
            // ISSUE ORDER, so exactly one burst is landing at a time: the descriptor at
            // the queue head. Parsing is unchanged from the old R_STREAM - same
            // need_off_r accumulation, same vslot/b_isp writes - it just reads its
            // record geometry from cur_* instead of rd_*, and targets cur_buf.
            if (!dq_empty && dresp.dready) begin
                if (beat == need_off) begin
                    if (ni_isp) b_isp[cur_buf] <= beat_half;
                    else begin
                        case (ni_cmp)
                            2'd0:    vslot[cur_buf][ni_vx].x <= beat_half;
                            2'd1:    vslot[cur_buf][ni_vx].y <= beat_half;
                            default: vslot[cur_buf][ni_vx].z <= beat_half;
                        endcase
                        if (ni_cmp == 2'd2) b_nfill[cur_buf] <= b_nfill[cur_buf] + 4'd1;
                    end
                    ni <= ni + 6'd1;
                    if (ni_isp)              need_off_r <= {4'b0, cur_hdr};
                    else if (ni_cmp == 2'd2) need_off_r <= need_off_r + {4'b0, cur_stride} - 9'd2;
                    else                     need_off_r <= need_off_r + 9'd1;
                    if (!ni_isp) begin
                        if (ni_cmp == 2'd2) begin ni_cmp<=2'd0; ni_vx<=ni_vx+4'd1; end
                        else                       ni_cmp<=ni_cmp+2'd1;
                    end
                end
                if (rx_last) begin
                    // record fully read: hand the buffer to emit and start the next
                    // queued burst's parse state from scratch.
                    b_done [cur_buf] <= 1'b1;
                    b_ready[cur_buf] <= 1'b1;
                    b_infl [cur_buf] <= 1'b0;
                    dq_head <= dq_head + 1'b1;
                    beat <= 9'd0; ni <= 6'd0; ni_vx <= 4'd0; ni_cmp <= 2'd0;
                    need_off_r <= 9'd0;
                end else beat <= beat + 9'd1;
            end

            // ==================== EMIT ====================
            case (est)
            E_IDLE: if (b_ready[em_buf]) begin
                s_i <= 3'd0;
                est <= b_array[em_buf] ? E_PRESENT : E_SEEK;
            end
            E_SEEK: begin
                // strip: seek s_i to the next set mask bit. A DISABLED triangle is
                // skipped immediately (its verts may not have been read - the burst
                // is trimmed to the last ENABLED triangle's verts). An ENABLED
                // triangle waits for its 3 verts (nfill > s_i+2) before emitting.
                if (!b_mask[em_buf][3'd5 - s_i]) begin
                    if (s_i == 3'd5) est <= E_REL;      // no more triangles
                    else s_i <= s_i + 3'd1;             // skip disabled, no vert wait
                end else if (b_nfill[em_buf] > {1'b0,s_i} + 4'd2) begin
                    v0_r <= vslot[em_buf][va(s_i)];
                    v1_r <= vslot[em_buf][vb(s_i)];
                    v2_r <= vslot[em_buf][{1'b0,s_i}+4'd2];
                    tag_r <= mk_tag(b_isp[em_buf][ISP_CACHEBYPASS_BIT], b_shadow[em_buf],
                                    b_skip[em_buf], b_po[em_buf], s_i);
                    pin_r <= b_hitm[em_buf][3'd5 - s_i];
                    tri_ready_r <= 1'b1;
                    est <= E_PRESENT;
                end
            end
            E_PRESENT: begin
                if (b_array[em_buf] && !tri_ready_r) begin
                    // quad records carry 4 vertices - wait for all of them (trio.v3x/y
                    // are read live off vslot[3], which must have landed)
                    if (b_nfill[em_buf] >= (b_quad[em_buf] ? 4'd4 : 4'd3)) begin
                        v0_r<=vslot[em_buf][0]; v1_r<=vslot[em_buf][1]; v2_r<=vslot[em_buf][2];
                        tag_r<=mk_tag(b_isp[em_buf][ISP_CACHEBYPASS_BIT], b_shadow[em_buf],
                                      b_skip[em_buf], b_po[em_buf], 3'd0);
                        pin_r <= b_hitm[em_buf][5];
                        tri_ready_r <= 1'b1;
                    end
                end else begin
                    tri_ready_r <= 1'b1;
                    if (ack.triangle_done) begin
                        tri_ready_r <= 1'b0;
                        if (b_array[em_buf]) est <= E_REL;
                        else if (s_i == 3'd5) est <= E_REL;
                        else begin s_i <= s_i + 3'd1; est <= E_SEEK; end
                    end
                end
            end
            E_REL: begin
                // release the buffer; one record retired.
                b_ready[em_buf] <= 1'b0;
                // RING INCREMENT, not a toggle. This was `~em_buf` back when there were
                // exactly 2 buffers and it was a ping-pong; with NBUF=4 the complement
                // maps 0<->3 and 1<->2, so emit would only ever drain buffers 0 and 3
                // while the reader filled 0,1,2,3 in order - the reader then wedges on
                // !b_ready[rd_buf] and the whole iterator deadlocks.
                em_buf          <= em_buf + 1'b1;
                est             <= E_IDLE;
            end
            endcase

            // outstanding = records fetched-but-not-emitted. Single update point so
            // a same-cycle fetch-complete (+1), CACHED-record claim (+1) and
            // buffer-release (-1) reconcile. (rx_last and a claim CAN coincide -
            // a burst landing while the reader claims a cached record.)
            begin : os_update
                reg push, pop;
                push = rx_last;   // a record's burst fully landed (was: R_STREAM end)
                pop  = (est==E_REL);
                outstanding <= outstanding + (push ? 4'd1 : 4'd0)
                                           + (tcc_pulse ? 4'd1 : 4'd0)
                                           - (pop ? 4'd1 : 4'd0);
            end
            // (list-done is observed by isp_core via !busy && eq_empty; no
            //  flush/drained handshake needed.)

            // ---- EARLY-FLAG OPEN (last, so it wins any same-edge write): the pass
            // decision promotes every in-flight early record/entry to CURRENT-pass.
            if (early_open) begin
                exl_early <= 1'b0;
                rd_early  <= 1'b0;
                for (rbi = 0; rbi < NBUF; rbi = rbi + 1) b_early[rbi] <= 1'b0;
            end
        end
    end
endmodule

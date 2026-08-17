//
// tex_cache_4p_1c - 4-READ-PORT texture cache, PIPELINED 2-CYCLE-reply variant.
// 1024 lines x 32 BYTES (256-bit = 4x 64-bit words), direct-mapped, over the DDR3 raw
// 64-bit read port. Backs the 4 bilinear corner fetchers. Plus a 5th, always-available
// PREFILL PROBE port (tag-only residency test; see PREFILL PROBE below).
//
// HISTORY: this was the 1-CYCLE reply variant (accept N -> ack N+1, hit test
// combinational off the registered RAM read). That single cycle carried RAM Tco + a
// 17-bit tag compare x4 + the group priority + the ack fanout - ~12ns of logic, which
// is what broke 120MHz once the prefetch walker piled its own compare tree on top.
// Now the lookup is a 2-stage PIPELINE at the same throughput:
//
//   LOOK  (cycle N)  : request accepted; line index drives the block-RAM read ports;
//                      request fields register into the b-stage (b_*).
//   TEST  (cycle N+1): the RAM read lands; tag compare + word select are computed and
//                      REGISTERED into the t-stage (t_hit/t_word + request fields).
//   REPLY (cycle N+2): group decision (priority over 4 REGISTERED hit bits) + ack.
//
// One request per cycle streams through (TWO groups in flight: b + t); a hit group
// still acks every cycle, just one cycle later than before. ready/ack are now shallow
// logic off registers - the M10K read never reaches a register enable in one cycle.
//
// On a REPLY miss the cache HOLDS: ready drops (all ports), the t-stage group is
// served by fills + retests, and the b-stage group (accepted while the miss was in
// flight through the pipe) is REPLAYED from LOOK afterwards - its TEST result was
// computed against pre-fill meta and may be stale in either direction, so it must
// re-run. The client never sees a "not-ok" - only a late accept (ready low until the
// group is resident). Order is preserved: t acks before b replays.
//
// ======================= MULTI-OUTSTANDING DEMAND FILLS (MLP) =======================
// A miss episode fills ALL of the t-group's distinct missing lines CONCURRENTLY: S_MISS
// issues one burst per cycle-pair (as fast as the channel accepts) into an in-order
// fill queue, and the beats of every issued burst stream back in issue order, each
// line committing on its own 4th beat. Only when the queue has drained does the retest
// run. A group needing n distinct lines therefore costs ONE round trip + n*4 beats
// instead of n serialized round trips.
//   * The DDR arbiter is already pipelined (peel_core DDR_OUT order FIFO); what gates
//     this is the per-client busy, which used to span request->last beat. The tc client
//     now reports busy only while its request is ungranted or it is at TC_OUT_MAX
//     outstanding bursts, so it can hold several.
//   * t_iss[k] marks a port whose line has been issued. Issue-time DEDUP sets it for
//     EVERY port sharing that line, so the four corners of one bilinear sample that
//     land in the same line still cost one burst (the common case - see the fills-per-
//     group histogram: 86% of missing groups want exactly one line).
//   * Aliasing is still safe: a later commit in the same batch may evict an earlier
//     one, but the LAST line committed cannot be evicted by anyone, so its port always
//     hits at retest and every batch retires >= 1 port. A new batch clears t_iss and
//     re-issues whatever the retest still finds missing - the old at-most-4-fills
//     bound becomes at-most-4-BATCHES.
//   * The hitchhike (a missing line already in flight on the PREFETCH client) is
//     unchanged in spirit but no longer blocks the other lines: the ridden port is
//     marked issued, ride_w remembers that a foreign transfer must land before the
//     retest, and the rest of the batch issues meanwhile.
//
// ============================ M10K STORAGE (2 copies, not 4) ============================
// The four demand read ports are served by TWO true-dual-port arrays, not four
// single-read copies: an M10K in BIDIR_DUAL_PORT mode has two independent ports, so
// data_a serves ports 0 and 1 and data_b serves ports 2 and 3, each out of ONE copy of
// the storage. At 1024 deep the fitter's per-block config is 1024x10 in true-dual-port
// mode exactly as in simple-dual-port mode (the x40 width that TDP cannot do needs a
// 256-deep array), so the second read port costs NOTHING - this halves the block count
// of the line store. See bram_tdp.sv for the width rule before reusing the trick.
//
// Port A of each array is the one that also WRITES (fills + the invalidate sweep); its
// address is muxed write/read. That is safe because reads and writes NEVER coincide
// here: reads are presented only in S_RUN/S_RT0/S_RB0, and every write happens in
// S_RST/S_FILL-commit/prefetch-commit slots (rd_en low).
//
// ============================ WHY THERE IS NO ALIAS LIVELOCK ============================
// Group-atomic serving (the 4 ports are the 4 corners of ONE bilinear sample) with
// direct-mapped aliasing used to be able to ping-pong evictions forever. The fix (kept
// from the 1-cycle version, simplified): a port that HITS at any decision point has its
// 64-bit word ALREADY REGISTERED in t_word and is marked t_done; from then on it is
// served from that register and does not care if its line is evicted. Fills broadcast
// unconditionally to both arrays, and every fill retires at least one port (the port
// whose line was just written re-tests immediately and hits). A group of 4 completes in
// at most 4 fills regardless of how the corners alias. (The separate t_hold register of
// the 1-cycle version is gone - t_word IS the hold register now.)
//
// ================================= PREFILL PROBE =================================
// pf_* is a probe port that answers "is this line resident?", used by the prefetch
// walker to find the next miss in the queued request stream while the cache is
// FROZEN filling - which is exactly when the four demand ports are idle. It reads
// the DEMAND tag copies (meta_a/meta_b) through their spare true-dual-port ports:
// 4 tags/cycle, at zero extra M10K.
//   Probe is TAG ONLY - it reports residency, not data.
//   PIPELINED, 2-cycle: present + pf_gnt at cycle K, meta read lands K+1, the
//   compare is REGISTERED and pf_ack/pf_hit fire at K+2. The walker streams one
//   probe per cycle and matches acks to grants by order (pf_gnt tells it which
//   presented probes actually launched; a probe presented on a commit cycle is
//   simply not granted). Registering the compare keeps the walker's fill-select
//   tree off the M10K read path - the exact -9ns cone this rework removes.
//   Answers are CONSERVATIVE: a probe issued during the invalidate sweep reports
//   "not resident", which is what will be true once the sweep lands.
//
// PROTOCOL per port i:
//   creq[i].req    : client wants to issue creq[i].waddr this cycle
//   cresp[i].ready : cache can accept it this cycle (LOW during a fill / reset sweep)
//   ACCEPTED       : creq[i].req && cresp[i].ready
//   cresp[i].ack   : a result is valid this cycle (2 cycles after accept on a full-hit
//                    stream; later across a miss episode) - IN ISSUE ORDER
//   cresp[i].rdata : the requested 64-bit word (registered)
// Line addr = waddr[28:2]; word-in-line = waddr[1:0]. index=line[9:0], tag=line[26:10].
//
module tex_cache_4p_1c import tsp_pkg::*; (
    input                clk,
    input                reset,
    input                flush,   // 1-cyc: re-run the valid-clear sweep (render start). The
                                  // cache is address-tagged and has NO cross-render coherency;
                                  // VRAM textures/VQ codebooks re-streamed to a reused address
                                  // would hit stale lines. The Dreamcast re-reads textures from
                                  // VRAM every render, so we invalidate here on every render.
    input  cache_req_t   creq  [0:3],
    output cache_resp_t  cresp [0:3],

    // ---- prefill probe: 5th read port, tag-only, never backpressured ----
    input                pf_req,        // probe these 4 lines this cycle
    input      [4*29-1:0] pf_waddr,     // 4 x 64-bit-word address (creq[].waddr form)
    output               pf_gnt,        // probe LAUNCHED this cycle (rd ports were free)
    output               pf_ack,        // 2 cycles after a grant: pf_hit[] is valid
    output       [3:0]   pf_hit,        // per-probe: line resident (registered)
    output               pf_busy,       // 1 = frozen filling (probing is possible)

    output ddr_rd_req_t  dreq,
    input  ddr_rd_resp_t dresp,
    // ---- PREFETCH fill port: its own DDR client, single outstanding ----
    input                pf_fill,       // level: prefetch this line (hold until !pf_fbusy)
    input        [28:0]  pf_faddr,      // 64-bit-word address of the line
    output               pf_fbusy,      // prefetch receiver occupied
    output ddr_rd_req_t  pfreq,
    input  ddr_rd_resp_t pfresp
);
    localparam integer NLINE = 1024;
    localparam integer IXW   = 10;
    localparam integer LAW   = 27;
    localparam integer TAGW  = LAW - IXW;           // 17
    localparam integer MW    = TAGW + 1;            // meta word = {vld, tag}
    // in-flight demand fills. A bilinear group wants at most 4 distinct lines, so 4 is
    // enough for ONE batch; the channel caps concurrency anyway (peel_core TC_OUT_MAX),
    // making fq_full a belt-and-braces stall rather than the normal limiter.
    localparam integer FQD   = 4;

    integer i, k;

    // S_RUN   : streaming (accept -> b -> t -> ack, one group/cycle)
    // S_MISS  : issue a DDR burst per distinct missing line of the t-group (one per
    //           accepted cycle, all outstanding together); beats land here too
    // S_FILL  : everything issued - drain the remaining beats / hitchhiked prefetch
    // S_RT0/1 : re-present the t-group's reads / re-register hit+word (post-fill)
    // S_RT2   : re-decide the t-group (ack, or next batch of fills)
    // S_RB0/1 : replay the frozen b-group through LOOK/TEST, shift into t
    localparam S_RST=0, S_RUN=1, S_MISS=2, S_FILL=3,
               S_RT0=4, S_RT1=5, S_RT2=6, S_RB0=7, S_RB1=8;
    reg [3:0] st;
    reg [IXW:0] rst_i;

    // ============ REPLY-stage group (t): decision is shallow, all off registers ============
    reg            t_v   [0:3];
    reg [LAW-1:0]  t_line[0:3];
    reg [1:0]      t_wsel[0:3];
    reg            t_hit [0:3];         // registered TEST result
    reg [63:0]     t_word[0:3];         // registered selected word (doubles as hold reg)
    reg            t_done[0:3];         // captured in an earlier round; word is final
    reg [3:0]      t_iss;               // this port's line is issued (or ridden) in the
                                        // CURRENT batch - cleared when a batch starts

    wire t_ok [0:3];
    genvar gi;
    generate
      for (gi=0; gi<4; gi=gi+1) begin : tok
        assign t_ok[gi] = t_done[gi] || t_hit[gi];
      end
    endgenerate
    // lowest REPLY-stage port still MISSING (not resident, not captured). fm[2]=1 => none.
    wire [2:0] fm = (t_v[0] && !t_ok[0]) ? 3'd0 :
                    (t_v[1] && !t_ok[1]) ? 3'd1 :
                    (t_v[2] && !t_ok[2]) ? 3'd2 :
                    (t_v[3] && !t_ok[3]) ? 3'd3 : 3'b100;
    wire t_miss = !fm[2];

    wire accept_ok = (st == S_RUN) && !t_miss;
    wire [3:0] acc;
    generate
      for (gi=0; gi<4; gi=gi+1) begin : ac
        assign acc[gi]           = accept_ok && creq[gi].req;
        assign cresp[gi].ready   = accept_ok;          // backpressure (same all ports)
      end
    endgenerate

    // group-atomic ack: all valid ports ack TOGETHER, in S_RUN (streaming) or S_RT2
    // (the retested group completing). rdata is the registered word - never RAM-direct.
    wire decide    = (st == S_RUN) || (st == S_RT2);
    wire group_ack = decide && !t_miss;
    generate
      for (gi=0; gi<4; gi=gi+1) begin : od
        assign cresp[gi].ack   = group_ack && t_v[gi];
        assign cresp[gi].rdata = t_word[gi];
      end
    endgenerate

    // ============ TEST-stage group (b): accepted last cycle, RAM read landing ============
    reg            b_v   [0:3];
    reg [LAW-1:0]  b_line[0:3];
    reg [1:0]      b_wsel[0:3];
    wire b_any = b_v[0] || b_v[1] || b_v[2] || b_v[3];

    // ---- decode the incoming (accepted) request per port ----
    wire [LAW-1:0]  in_line[0:3];
    wire [IXW-1:0]  in_ix  [0:3];
    wire [1:0]      in_wsel[0:3];
    generate
      for (gi=0; gi<4; gi=gi+1) begin : ind
        assign in_line[gi] = creq[gi].waddr[28:2];
        assign in_ix[gi]   = in_line[gi][IXW-1:0];
        assign in_wsel[gi] = creq[gi].waddr[1:0];
      end
    endgenerate

    // ============ READ address: new request, or a retest/replay re-present ============
    reg  [IXW-1:0] rd_ix [0:3];
    always @(*) begin
        for (int p=0; p<4; p=p+1)
            rd_ix[p] = (st == S_RT0) ? t_line[p][IXW-1:0] :
                       (st == S_RB0) ? b_line[p][IXW-1:0] : in_ix[p];
    end
    // reads are PRESENTED only in these states (data lands the cycle after)
    wire rd_en = (st == S_RUN) || (st == S_RT0) || (st == S_RB0);

    // ============ IN-FLIGHT DEMAND FILL QUEUE (in issue order) ============
    // One entry per issued burst. Beats come back in issue order, so only the HEAD is
    // accumulating: m_acc/m_beat belong to fq_line[fq_h], which commits on its 4th beat
    // and pops. lf_line/lf_v remember the LAST line committed (for pf_dup).
    reg  [LAW-1:0] fq_line [0:FQD-1];
    reg  [FQD-1:0] fq_v;                        // per-slot occupancy (for the pf_dup CAM)
    reg  [2:0]     fq_wp, fq_rp;                // wrap bit + 2-bit index
    wire           fq_empty = (fq_wp == fq_rp);
    wire           fq_full  = (fq_wp[2] != fq_rp[2]) && (fq_wp[1:0] == fq_rp[1:0]);
    wire [1:0]     fq_h     = fq_rp[1:0];
    reg  [1:0]     m_beat; reg [255:0] m_acc;
    reg  [LAW-1:0] lf_line;             // last line committed by the demand path
    reg            lf_v;                // lf_line valid (for pf_dup)
    reg            ride_w;              // a missing line of this batch is in flight on
                                        // the PREFETCH client: it must land before the
                                        // retest
    reg [LAW-1:0]  ride_line;           // ...that line. If a batch rides TWO lines (both
                                        // being prefetched) this holds the later one; the
                                        // earlier may still be in flight when the ride
                                        // clears, in which case the retest misses and the
                                        // batch simply re-rides it - correct and bounded,
                                        // and it needs 4 comparators instead of 20.

    wire [LAW-1:0]  m_line = fq_line[fq_h];     // head: the line the beats belong to
    wire [IXW-1:0]  m_ix  = m_line[IXW-1:0];
    wire [TAGW-1:0] m_tag = m_line[LAW-1:IXW];

    // ============ WRITE side: fill commit + invalidate sweep + prefetch commit ============
    // Both arrays take the SAME write (broadcast); the write address is the sweep counter
    // during S_RST, the head in-flight line's index on a fill commit, the prefetched
    // line's on a prefetch commit.
    wire            sweep_we = (st == S_RST);
    // a beat is OURS only while we have a burst outstanding; the commit is the head
    // burst's 4th beat, which can land in S_MISS (still issuing) or S_FILL (draining).
    wire            d_beat   = dresp.dready && !fq_empty;
    wire            fill_we  = d_beat && (m_beat == 2'd3);
    wire            p_we;                       // prefetch commit (declared below)
    wire [IXW-1:0]  p_ix;
    wire [TAGW-1:0] p_tag;
    wire [255:0]    p_acc_w;
    wire            pf_pend_iss;                // iss_line is pending in the prefetcher
    wire            pf_pend_ride;               // ride_line still is (both declared below)
    wire            meta_we  = sweep_we || fill_we || p_we;
    wire            data_we  = fill_we || p_we;
    wire [IXW-1:0]  wa       = sweep_we ? rst_i[IXW-1:0] : (fill_we ? m_ix : p_ix);
    // ---- issue selection: lowest missing port whose line is not yet issued ----
    // im[2]=1 => nothing left to issue in this batch. This tree is the old `fm` with
    // t_iss added; it lives in S_MISS (the issue path), never on the decide path.
    wire [2:0] im = (t_v[0] && !t_ok[0] && !t_iss[0]) ? 3'd0 :
                    (t_v[1] && !t_ok[1] && !t_iss[1]) ? 3'd1 :
                    (t_v[2] && !t_ok[2] && !t_iss[2]) ? 3'd2 :
                    (t_v[3] && !t_ok[3] && !t_iss[3]) ? 3'd3 : 3'b100;
    wire            have_iss = !im[2];
    wire [LAW-1:0]  iss_line = t_line[im[1:0]];
    // the fill queue empties on THIS edge (last outstanding burst's 4th beat), so the
    // retest can start next cycle rather than a cycle after noticing fq_empty
    wire            fq_one   = ((fq_wp - fq_rp) == 3'd1);
    // DEDUP: every port wanting the line being issued is marked issued with it, so the
    // four corners of one sample that share a line cost ONE burst.
    wire [3:0]      iss_need;               // still missing and not yet issued
    wire [3:0]      iss_mask;               // ...of those, the ones on iss_line
    generate
      for (gi=0; gi<4; gi=gi+1) begin : ism
        assign iss_need[gi] = t_v[gi] && !t_ok[gi] && !t_iss[gi];
        assign iss_mask[gi] = iss_need[gi] && (t_line[gi] == iss_line);
      end
    endgenerate
    // another missing line after this one? If not, the issue phase ends on the SAME
    // cycle as this issue - waiting a cycle to discover !have_iss would tax every
    // batch, including the 85% that only ever want one line.
    wire            iss_more = |(iss_need & ~iss_mask);
    wire [28:0]     iss_base = {iss_line, 2'b00};
    // HITCHHIKE: this line is already in flight on the prefetch client - don't spend a
    // second burst on it, mark it issued and remember to wait for that commit (ride_w).
    wire            in_iss   = (st == S_MISS);
    wire            iss_ride = in_iss && have_iss && pf_pend_iss;
    // !rd_r is REQUIRED, not an optimisation: the arbiter's per-client pending slot holds
    // ONE address, and it registers our rd pulse on the edge that ends the cycle we
    // present it - so during that cycle its `busy` still reads low. Issuing again on it
    // would overwrite the address of a request that was never granted: one burst lost,
    // the fill queue waiting forever for beats that never come, and the entry it did get
    // filled from the wrong line. One presentation at a time; MANY bursts outstanding.
    wire            iss_go   = in_iss && have_iss && !iss_ride && !fq_full
                               && !rd_r && !dresp.busy;
    wire [MW-1:0]   wmeta    = sweep_we ? {1'b0, {TAGW{1'b0}}}
                             : fill_we  ? {1'b1, m_tag} : {1'b1, p_tag};
    wire [255:0]    wdata    = fill_we ? { dresp.dout, m_acc[191:0] } : p_acc_w;

    // ============ storage: 2 true-dual-port arrays serve the 4 demand ports ============
    // data_a/meta_a -> ports 0 (side A, also the write side) and 1 (side B)
    // data_b/meta_b -> ports 2 (side A, also the write side) and 3 (side B)
    wire [255:0] rdat0, rdat1, rdat2, rdat3;
    wire [MW-1:0] rmeta0, rmeta1, rmeta2, rmeta3;

    // PER-ARRAY `keep` COPIES OF THE WRITE ENABLE. data_we/meta_we each drive a
    // 256-bit-wide array's worth of M10K write-enable pins AND the address mux in front
    // of it; as one shared node `fill_we` reached fanout 292 and sat on the worst
    // texture-cache path (bridge -> d_beat -> fill_we -> wdata -> M10K, four long hops).
    // One copy per array lets the fitter put each next to the M10Ks it enables. Same
    // expression, same value - `keep` only stops synthesis re-merging them.
    (* keep = 1 *) wire data_we_a = data_we;
    (* keep = 1 *) wire data_we_b = data_we;
    bram_tdp #(.W(256), .D(NLINE)) u_data_a (
        .clk(clk),
        .a_en(rd_en), .a_we(data_we_a), .a_addr(data_we_a ? wa : rd_ix[0]),
        .a_din(wdata), .a_q(rdat0),
        .b_en(rd_en), .b_addr(rd_ix[1]), .b_q(rdat1));
    bram_tdp #(.W(256), .D(NLINE)) u_data_b (
        .clk(clk),
        .a_en(rd_en), .a_we(data_we_b), .a_addr(data_we_b ? wa : rd_ix[2]),
        .a_din(wdata), .a_q(rdat2),
        .b_en(rd_en), .b_addr(rd_ix[3]), .b_q(rdat3));
    // ---- PROBE: 4 tags/cycle off the IDLE demand meta ports ----
    // While the cache is frozen filling, the demand read ports are unused on most
    // cycles, so the prefetch walker borrows them: meta_a port A/B and meta_b port
    // A/B carry probes 0..3. Not granted while reads are presented (rd_en: S_RUN,
    // S_RT0, S_RB0 - hijacking those addresses would corrupt a demand lookup, the
    // livelock the old detector caught) nor on a write cycle (meta_we, port A busy).
    // The walker watches pf_gnt and simply re-presents on an ungranted cycle.
    wire [IXW-1:0] pf_ix [0:3];
    wire [TAGW-1:0] pf_tg [0:3];
    generate
      for (gi=0; gi<4; gi=gi+1) begin : pfd
        assign pf_ix[gi] = pf_waddr[29*gi+2 +: IXW];
        assign pf_tg[gi] = pf_waddr[29*gi+2+IXW +: TAGW];
      end
    endgenerate
    // pchk_go: the prefetch receiver's TAKE-TIME tag re-check borrows meta_a port A
    // for one read (declared here, driven in the receiver below). It outranks the
    // walker's probe (the walker is stalled on pf_fbusy whenever the receiver is
    // busy, so this never actually contends - the gate is belt).
    wire pchk_go;
    wire probe_go = pf_req && !rd_en && !meta_we && !pchk_go;
    assign pf_gnt = probe_go;
    wire [IXW-1:0] p_chk_ix;            // receiver's line index (driven below)
    wire [IXW-1:0] ma_a = meta_we ? wa : pchk_go ? p_chk_ix
                                       : probe_go ? pf_ix[0] : rd_ix[0];
    wire [IXW-1:0] ma_b =                 probe_go ? pf_ix[1] : rd_ix[1];
    wire [IXW-1:0] mb_a = meta_we ? wa : (probe_go ? pf_ix[2] : rd_ix[2]);
    wire [IXW-1:0] mb_b =                 probe_go ? pf_ix[3] : rd_ix[3];
    (* keep = 1 *) wire meta_we_a = meta_we;
    (* keep = 1 *) wire meta_we_b = meta_we;
    bram_tdp #(.W(MW), .D(NLINE)) u_meta_a (
        .clk(clk),
        .a_en(rd_en || probe_go || pchk_go), .a_we(meta_we_a), .a_addr(ma_a),
        .a_din(wmeta), .a_q(rmeta0),
        .b_en(rd_en || probe_go), .b_addr(ma_b), .b_q(rmeta1));
    bram_tdp #(.W(MW), .D(NLINE)) u_meta_b (
        .clk(clk),
        .a_en(rd_en || probe_go), .a_we(meta_we_b), .a_addr(mb_a),
        .a_din(wmeta), .a_q(rmeta2),
        .b_en(rd_en || probe_go), .b_addr(mb_b), .b_q(rmeta3));

    wire [255:0]  rdat [0:3];
    wire [MW-1:0] rmeta[0:3];
    assign rdat[0]=rdat0; assign rdat[1]=rdat1; assign rdat[2]=rdat2; assign rdat[3]=rdat3;
    assign rmeta[0]=rmeta0; assign rmeta[1]=rmeta1; assign rmeta[2]=rmeta2; assign rmeta[3]=rmeta3;

    // ============ TEST-stage compare (comb, the cycle the RAM read lands) ============
    // Source is the b-group (normal stream + S_RB1 replay) or the t-group (S_RT1
    // retest); the source request's tag/wsel select the compare and the word.
    // RAM Tco + one 17-bit compare + one 4:1 word mux -> register. Nothing deeper.
    wire            cmp_src_t = (st == S_RT1);
    wire [TAGW-1:0] cmp_tag [0:3];
    wire [1:0]      cmp_wsel[0:3];
    wire            cmp_srcv[0:3];
    wire            cmp_hit [0:3];
    wire [63:0]     cmp_word[0:3];
    generate
      for (gi=0; gi<4; gi=gi+1) begin : cmpg
        assign cmp_tag[gi]  = cmp_src_t ? t_line[gi][LAW-1:IXW] : b_line[gi][LAW-1:IXW];
        assign cmp_wsel[gi] = cmp_src_t ? t_wsel[gi] : b_wsel[gi];
        assign cmp_srcv[gi] = cmp_src_t ? t_v[gi]    : b_v[gi];
        assign cmp_hit[gi]  = cmp_srcv[gi] && rmeta[gi][TAGW]
                              && (rmeta[gi][TAGW-1:0] == cmp_tag[gi]);
        assign cmp_word[gi] = rdat[gi][64*cmp_wsel[gi] +: 64];
      end
    endgenerate

    // ============ demand DDR client ============
    reg        rd_r;   reg [28:0] addr_r; reg [7:0] burst_r;
    assign dreq.rd    = rd_r;
    assign dreq.addr  = addr_r;
    assign dreq.burst = burst_r;
    assign dreq.w32   = 1'b0;   // texels are read as raw 64-bit words

`ifndef SYNTHESIS
    integer stat_hit [0:4];
    integer stat_n;
    integer st_pfck_drop = 0;    // prefetches dropped by the take-time re-check
    integer st_dwait     = 0;    // demand lines ridden on an in-flight prefetch
    integer st_burst     = 0;    // demand bursts issued
    integer st_batch     = 0;    // fill batches (a batch = one round trip, n lines)
    integer st_mlp   [0:FQD];    // batches by number of bursts they issued
    integer st_bcur      = 0;    // bursts issued by the batch in progress
    integer st_pfburst   = 0;    // prefetch bursts issued
    integer st_pfhw      = 0;    // high-water of the prefetch ring occupancy
`endif

    always @(posedge clk) begin
        if (reset || flush) begin
            // reset, or render start: re-enter the valid-clear sweep (invalidate all
            // lines). Safe because the shade pipe is idle between renders (no fill in
            // flight). Stats (sim-only) are intentionally cumulative across renders.
            st <= S_RST; rd_r <= 0; rst_i <= 0; lf_v <= 1'b0;
            fq_wp <= 3'd0; fq_rp <= 3'd0; fq_v <= {FQD{1'b0}}; m_beat <= 2'd0;
            t_iss <= 4'd0; ride_w <= 1'b0;
            for (i=0;i<4;i=i+1) begin t_v[i]<=0; t_done[i]<=0; b_v[i]<=0; end
`ifndef SYNTHESIS
            if (reset) begin
                for (i=0;i<5;i=i+1) stat_hit[i] <= 0;
                for (i=0;i<=FQD;i=i+1) st_mlp[i] <= 0;
                stat_n <= 0;
            end
`endif
        end else begin
            rd_r <= 1'b0;

            // ---- BEAT RECEIVER (state-independent): beats belong to the HEAD in-flight
            // burst; its 4th beat commits the line (fill_we is driven combinationally
            // into both arrays from m_line/m_acc) and pops the queue. Beats can only
            // arrive in S_MISS/S_FILL - the batch does not leave for the retest until
            // the queue is empty - so this never collides with a presented read.
            if (d_beat) begin
                m_acc[64*m_beat +: 64] <= dresp.dout;
                if (m_beat == 2'd3) begin
                    m_beat    <= 2'd0;
                    fq_rp     <= fq_rp + 3'd1;
                    fq_v[fq_h] <= 1'b0;
                    lf_line   <= m_line;
                    lf_v      <= 1'b1;
                end else m_beat <= m_beat + 2'd1;
            end
            // A ride ends when its line stops being pending in the prefetcher: it either
            // committed, or the take-time re-check dropped it because it was ALREADY
            // resident. Either way the line is there and the retest may run. Tracking the
            // LINE (not "the receiver is idle") is what makes this correct with several
            // speculative lines in flight - the receiver is almost never idle now.
            if (ride_w && !pf_pend_ride) ride_w <= 1'b0;

            case (st)
            // clear valid bits one entry/cycle after reset. The write itself is driven
            // combinationally off sweep_we/wa/wmeta into both tag copies.
            S_RST: begin
                for (i=0;i<4;i=i+1) begin t_v[i] <= 1'b0; t_done[i] <= 1'b0; b_v[i] <= 1'b0; end
                if (rst_i == NLINE-1) st <= S_RUN;
                else rst_i <= rst_i + 1'b1;
            end

            // steady state, one group/cycle: DECIDE the t-group (registered hits),
            // SHIFT b->t with the compare landing this cycle, ACCEPT a new group into
            // b (its RAM read is presented combinationally this cycle). On the first
            // miss, freeze BOTH groups and go fill; b is replayed after t completes.
            S_RUN: begin
`ifndef SYNTHESIS
                if (t_v[0] || t_v[1] || t_v[2] || t_v[3]) begin
                    stat_hit[(t_ok[0]?1:0)+(t_ok[1]?1:0)
                            +(t_ok[2]?1:0)+(t_ok[3]?1:0)]
                        <= stat_hit[(t_ok[0]?1:0)+(t_ok[1]?1:0)
                                   +(t_ok[2]?1:0)+(t_ok[3]?1:0)] + 1;
                    stat_n <= stat_n + 1;
                end
`endif
                if (t_miss) begin
                    // A miss in the t-group: start a fill BATCH - every distinct missing
                    // line is issued from S_MISS, all outstanding together. Ports that
                    // HIT right now already have their word REGISTERED in t_word - just
                    // mark them done; the fills are then free to evict their lines (what
                    // makes the unconditional broadcast safe). The b-group freezes
                    // untouched; ready was low this cycle so nothing new was accepted
                    // behind it.
                    for (k=0;k<4;k=k+1)
                        if (t_v[k] && !t_done[k] && t_hit[k]) t_done[k] <= 1'b1;
                    t_iss <= 4'd0;
                    st <= S_MISS;
`ifndef SYNTHESIS
                    st_batch <= st_batch + 1; st_bcur <= 0;
`endif
                end else begin
                    // t acked this cycle (if valid). Pipe advances.
                    for (k=0;k<4;k=k+1) begin
                        t_v[k]    <= b_v[k];
                        t_done[k] <= 1'b0;
                        t_line[k] <= b_line[k];
                        t_wsel[k] <= b_wsel[k];
                        t_hit[k]  <= cmp_hit[k];
                        t_word[k] <= cmp_word[k];
                        b_v[k]    <= acc[k];
                        b_line[k] <= in_line[k];
                        b_wsel[k] <= in_wsel[k];
                    end
                end
            end

            // ISSUE one 4-word burst per distinct missing line, one per accepted cycle,
            // all outstanding on the channel together. A line the prefetch receiver
            // already has in flight is RIDDEN instead of fetched twice (issuing our own
            // burst would fetch it twice); the rest of the batch keeps issuing while we
            // wait for that foreign commit. If the receiver instead DROPS its line
            // (take-time re-check hit) the line is resident and the retest will hit -
            // no deadlock either way. Beats land here too (see the receiver above).
            S_MISS: begin
                if (iss_ride) begin
                    t_iss     <= t_iss | iss_mask;
                    ride_w    <= 1'b1;
                    ride_line <= iss_line;
                    if (!iss_more) st <= S_FILL;
`ifndef SYNTHESIS
                    st_dwait <= st_dwait + 1;
                    if (!iss_more) st_mlp[st_bcur] <= st_mlp[st_bcur] + 1;
`endif
                end else if (iss_go) begin
                    rd_r    <= 1'b1;
                    addr_r  <= iss_base;              // raw; the arbiter decorates
                    burst_r <= 8'd4;
                    fq_line[fq_wp[1:0]] <= iss_line;
                    fq_v[fq_wp[1:0]]    <= 1'b1;
                    fq_wp   <= fq_wp + 3'd1;
                    t_iss   <= t_iss | iss_mask;
                    if (!iss_more) st <= S_FILL;
`ifndef SYNTHESIS
                    st_burst <= st_burst + 1;
                    st_bcur  <= st_bcur + 1;
                    if (!iss_more) st_mlp[st_bcur + 1] <= st_mlp[st_bcur + 1] + 1;
`endif
                end else if (!have_iss) begin
                    st <= S_FILL;
`ifndef SYNTHESIS
                    st_mlp[st_bcur] <= st_mlp[st_bcur] + 1;
`endif
                end
            end
            // everything issued: drain the outstanding beats (and any ridden prefetch)
            // before retesting, so the retest sees every line of the batch. The exit
            // ANTICIPATES the last beat (fill_we && fq_one empties the queue on this very
            // edge) - discovering fq_empty a cycle later would cost every batch a cycle.
            S_FILL: if ((fq_empty || (fill_we && fq_one)) && (!ride_w || !pf_pend_ride))
                        st <= S_RT0;

            // post-batch retest of the t-group: re-present its reads (S_RT0), re-register
            // hit+word for the not-yet-done ports (S_RT1), re-decide (S_RT2). Every port
            // whose line the batch filled now hits, EXCEPT one that a later commit in the
            // same batch aliased out - that one misses again and gets a fresh batch. The
            // last line committed cannot have been evicted, so every batch retires at
            // least one port and a group completes in at most 4 batches.
            S_RT0: st <= S_RT1;
            S_RT1: begin
                for (k=0;k<4;k=k+1)
                    if (t_v[k] && !t_done[k]) begin
                        t_hit[k]  <= cmp_hit[k];
                        t_word[k] <= cmp_word[k];
                    end
                st <= S_RT2;
            end
            S_RT2: begin
`ifndef SYNTHESIS
                if (t_v[0] || t_v[1] || t_v[2] || t_v[3]) begin
                    stat_hit[(t_ok[0]?1:0)+(t_ok[1]?1:0)
                            +(t_ok[2]?1:0)+(t_ok[3]?1:0)]
                        <= stat_hit[(t_ok[0]?1:0)+(t_ok[1]?1:0)
                                   +(t_ok[2]?1:0)+(t_ok[3]?1:0)] + 1;
                    stat_n <= stat_n + 1;
                end
`endif
                if (t_miss) begin
                    for (k=0;k<4;k=k+1)
                        if (t_v[k] && !t_done[k] && t_hit[k]) t_done[k] <= 1'b1;
                    t_iss <= 4'd0;              // fresh batch
                    st <= S_MISS;
`ifndef SYNTHESIS
                    st_batch <= st_batch + 1; st_bcur <= 0;
`endif
                end else begin
                    // t acked this cycle; clear it and replay the frozen b-group (its
                    // TEST ran against pre-fill meta - it must re-run from LOOK).
                    for (k=0;k<4;k=k+1) begin t_v[k] <= 1'b0; t_done[k] <= 1'b0; end
                    st <= b_any ? S_RB0 : S_RUN;
                end
            end

            // replay the b-group: re-present its reads (S_RB0), shift b->t with the
            // fresh compare (S_RB1), then S_RUN decides it (and resumes accepting).
            S_RB0: st <= S_RB1;
            S_RB1: begin
                for (k=0;k<4;k=k+1) begin
                    t_v[k]    <= b_v[k];
                    t_done[k] <= 1'b0;
                    t_line[k] <= b_line[k];
                    t_wsel[k] <= b_wsel[k];
                    t_hit[k]  <= cmp_hit[k];
                    t_word[k] <= cmp_word[k];
                    b_v[k]    <= 1'b0;
                end
                st <= S_RUN;
            end
            default: st <= S_RUN;
            endcase
        end
    end

    // ==================== PREFILL PROBE reply pipeline ====================
    // grant @K (probe_go) -> meta read lands @K+1 -> compare REGISTERED, pf_ack/pf_hit
    // @K+2. pf_v_r marks "rmeta holds probe data this cycle" (the demand pipe never
    // consumes rmeta on such a cycle: compare cycles S_RUN/S_RT1/S_RB1 follow read
    // presents S_RUN/S_RT0/S_RB0, and probe_go is blocked on all of those by rd_en).
    reg        pf_v_r, pf_sweep_r, pf_ack_r;
    reg [3:0]  pf_hit_r;
    reg [TAGW-1:0] pf_tg_r [0:3];
    always @(posedge clk) begin
        if (reset) begin pf_v_r <= 1'b0; pf_sweep_r <= 1'b0; pf_ack_r <= 1'b0; pf_hit_r <= 4'd0; end
        else begin
            pf_v_r     <= probe_go;
            pf_sweep_r <= sweep_we;
            for (i=0;i<4;i=i+1) pf_tg_r[i] <= pf_tg[i];
            pf_ack_r   <= pf_v_r;
            pf_hit_r[0] <= pf_v_r && !pf_sweep_r && rmeta0[TAGW] && (rmeta0[TAGW-1:0] == pf_tg_r[0]);
            pf_hit_r[1] <= pf_v_r && !pf_sweep_r && rmeta1[TAGW] && (rmeta1[TAGW-1:0] == pf_tg_r[1]);
            pf_hit_r[2] <= pf_v_r && !pf_sweep_r && rmeta2[TAGW] && (rmeta2[TAGW-1:0] == pf_tg_r[2]);
            pf_hit_r[3] <= pf_v_r && !pf_sweep_r && rmeta3[TAGW] && (rmeta3[TAGW-1:0] == pf_tg_r[3]);
        end
    end
    assign pf_ack  = pf_ack_r;
    assign pf_hit  = pf_hit_r;
    assign pf_busy = (st != S_RUN);

    // ==================== PREFETCH RECEIVER (PIPELINED, PFQD LINES DEEP) ====================
    // Was ONE line end to end (take -> re-check -> burst -> commit, ~23 cycles), which
    // capped the whole prefetcher at one line per 23 cycles: the walker holds pf_fill
    // until !pf_fbusy, so it could never run ahead, and a demand miss whose line WAS
    // being prefetched still stalled ~10 cycles waiting for it (57% of miss batches, 292k
    // cycles on sc_ingame2). Now the FRONT stage (take -> residency re-check -> issue) is
    // the only serial part - it releases the walker as soon as a line's burst is issued -
    // and a RING of PFQD lines carries the fetch + commit tail:
    //
    //   pq_wp : next slot to allocate (a burst was issued for it)
    //   pq_fp : slot currently receiving beats (bursts return in issue order)
    //   pq_rp : head slot, complete and waiting for a write slot to commit
    //   invariant rp <= fp <= wp in ring order; occupancy (wp-rp) <= PFQD
    //
    // Data lives per slot because a commit can wait arbitrarily long (it needs !rd_en,
    // and a pure hit streak presents reads EVERY cycle) while the next burst's beats are
    // already arriving. A drop can only happen in the FRONT stage, so the ring never
    // holds holes and every stage stays strictly in order.
    //
    // It shares the arrays' write path, which the demand fill owns:
    //   * the commit waits for a cycle with the demand write idle (!fill_we,
    //     !sweep_we) AND no demand reads presented (!rd_en). Port A of each array
    //     is the write port, and bram_tdp gives writes priority - committing on a
    //     read-present cycle would silently swallow ports 0 and 2's reads.
    //     !rd_en holds through S_MISS/S_FILL/S_RT1/S_RT2/S_RB1, so slots abound.
    //   * pf_dup: never prefetch the line the demand path filled LAST (lf_line), nor one
    //     it has in flight, nor one THIS receiver already has in flight - with several
    //     lines pending, its own ring is a duplicate source too. Plain 27-bit compares
    //     off registers; the old combinational miss_now term is gone (a walker fill
    //     request can only follow a probe granted during a fill episode, so the state
    //     check was provably redundant - and it was half of the -9ns launch cone).
    //   * pf_fill is a LEVEL: the walker holds it (and pf_faddr) until it sees
    //     !pf_fbusy - on that cycle the receiver either takes the line or drops a
    //     duplicate; either way the walker moves on.
    //   * TAKE-TIME RE-CHECK (P_CK0/P_CK1): the walker's probe answer is STALE by
    //     the time its fill request gets here (probe pipe + candidate stage + skid),
    //     and pf_dup only remembers the LAST demand fill - so before spending a DDR
    //     burst the receiver re-reads the line's tag through meta_a port A (free
    //     whenever the demand pipe isn't presenting reads; the walker is stalled on
    //     pf_fbusy so it never contends) and DROPS a line that became resident.
    //     Between a passed check and the commit nobody else can fill this line (the
    //     demand path WAITS on it instead - see S_MISS), so a duplicate prefetch
    //     commit is now impossible, not just bounded (sim-asserted at p_we).
    localparam integer PFQD = 4;                    // speculative lines in flight
    localparam integer PPW  = $clog2(PFQD);         // ring index width
    localparam P_IDLE=0, P_CK0=1, P_CK1=2, P_REQ=3;
    reg [1:0]      pst;
    reg [LAW-1:0]  p_cand;                          // line in the front stage
    // ---- the ring ----
    reg [LAW-1:0]  pq_line [0:PFQD-1];
    reg [255:0]    pq_acc  [0:PFQD-1];
    reg [PFQD-1:0] pq_v;                            // per-slot occupancy (for the CAMs)
    reg [PPW:0]    pq_wp, pq_fp, pq_rp;             // wrap bit + index
    reg [1:0]      p_beat;                          // beat counter for slot pq_fp
    wire [PPW-1:0] pq_h  = pq_rp[PPW-1:0];          // head (commit) slot
    wire [PPW-1:0] pq_f  = pq_fp[PPW-1:0];          // filling slot
    // occupancy as an explicit (PPW+1)-bit wire. Do NOT inline `pq_wp - pq_rp` inside a
    // wider cast or an integer context: the subtraction is then evaluated at the WIDER
    // width and the ring wrap stops working (a 3-bit 1-6=3 reads as 11 in 4 bits).
    // PFQ_MAX is a TYPED UNSIGNED localparam on purpose: `(PPW+1)'(PFQD)` casts a signed
    // integer, which makes any `>`/`<` against it a SIGNED comparison (3'b100 reads as -4),
    // so the overflow assertion below could never fire.
    localparam [PPW:0] PFQ_MAX = (PPW+1)'(PFQD);
    wire [PPW:0]   pq_occ    = pq_wp - pq_rp;
    wire           pq_full   = (pq_occ == PFQ_MAX);
    wire           pq_rxing = (pq_wp != pq_fp);     // a burst is still returning beats
    wire           pq_rdy   = (pq_fp != pq_rp);     // head slot is complete
    assign p_ix     = pq_line[pq_h][IXW-1:0];       // commit target
    assign p_tag    = pq_line[pq_h][LAW-1:IXW];
    assign p_acc_w  = pq_acc [pq_h];
    assign p_chk_ix = p_cand[IXW-1:0];              // front-stage re-check
    wire [TAGW-1:0] p_ctag = p_cand[LAW-1:IXW];
    wire [LAW-1:0] pf_fline = pf_faddr[28:2];
    // pf_dup: never prefetch the line the demand path filled LAST (lf_line) nor any line
    // it currently has IN FLIGHT. The in-flight arm is what keeps "a duplicate prefetch
    // commit is impossible" true now that the demand path can hold several bursts: the
    // ride check below only stops the demand path from duplicating a PREFETCH, not the
    // prefetcher from duplicating a demand fill.
    wire [FQD-1:0] fq_match;
    generate
      for (gi=0; gi<FQD; gi=gi+1) begin : fqm
        assign fq_match[gi] = fq_v[gi] && (fq_line[gi] == pf_fline);
      end
    endgenerate
    // ---- "is this line pending in the PREFETCHER?" - front stage + ring ----
    // Three callers, three lines: pf_fline (don't take a line we already hold),
    // iss_line (the demand path RIDES a pending line instead of fetching it again) and
    // ride_line (a ride ends when its line stops being pending - by then it is resident,
    // whether it committed or was dropped as already-resident).
    wire [PFQD-1:0] pq_m_pf, pq_m_iss, pq_m_ride;
    generate
      for (gi=0; gi<PFQD; gi=gi+1) begin : pqm
        assign pq_m_pf  [gi] = pq_v[gi] && (pq_line[gi] == pf_fline);
        assign pq_m_iss [gi] = pq_v[gi] && (pq_line[gi] == iss_line);
        assign pq_m_ride[gi] = pq_v[gi] && (pq_line[gi] == ride_line);
      end
    endgenerate
    wire p_front_v  = (pst != P_IDLE);
    wire pf_pend_pf   = (p_front_v && (p_cand == pf_fline)) || |pq_m_pf;
    assign pf_pend_iss  = (p_front_v && (p_cand == iss_line)) || |pq_m_iss;
    assign pf_pend_ride = (p_front_v && (p_cand == ride_line)) || |pq_m_ride;
    wire pf_dup   = (lf_v && (pf_fline == lf_line)) || |fq_match || pf_pend_pf;
    // ...and never TAKE on a cycle the demand path is pushing a line: fq_v is set on
    // that same edge, so pf_dup cannot see it yet. Without this the two can claim the
    // SAME line on one edge (demand pushes L, receiver takes L), the receiver's
    // take-time re-check then passes because L is not resident YET, and both fetch it -
    // the duplicate commit the $error below catches. One cycle of deferral is exactly
    // enough: pf_fill is a level, and by the next cycle fq_v covers the line.
    wire pf_take  = pf_fill && (pst == P_IDLE) && !pf_dup && !iss_go;
    // the walker is released as soon as the front stage clears - NOT after the round trip
    assign pf_fbusy = p_front_v;
    assign pchk_go  = (pst == P_CK0) && !rd_en && !meta_we;
    // the re-read landed this cycle: resident?
    wire pchk_hit   = rmeta0[TAGW] && (rmeta0[TAGW-1:0] == p_ctag);
    reg        p_rd; reg [28:0] p_addr;
    assign pfreq.rd    = p_rd;
    assign pfreq.addr  = p_addr;
    assign pfreq.burst = 8'd4;
    assign pfreq.w32   = 1'b0;  // same raw 64-bit form as the demand path
    // !p_rd for the same reason as the demand path's iss_go: the arbiter's pending slot
    // is ONE address and registers our pulse on the edge ending the cycle we present it.
    wire p_iss_go = (pst == P_REQ) && !pq_full && !p_rd && !pfresp.busy;
    // commit slot: head complete, demand write idle AND no demand reads presented
    assign p_we = pq_rdy && !fill_we && !sweep_we && !rd_en;
    // a beat is ours only while a burst is still returning
    wire   p_beat_v = pfresp.dready && pq_rxing;
    always @(posedge clk) begin
        if (reset || flush) begin
            pst <= P_IDLE; p_rd <= 1'b0; p_beat <= 2'd0;
            pq_wp <= '0; pq_fp <= '0; pq_rp <= '0; pq_v <= {PFQD{1'b0}};
        end else begin
            p_rd <= 1'b0;

            // ---- FRONT STAGE: take -> residency re-check -> issue+allocate ----
            case (pst)
            P_IDLE: if (pf_take) begin p_cand <= pf_fline; pst <= P_CK0; end
            P_CK0:  if (pchk_go) pst <= P_CK1;      // tag re-read presented
            P_CK1:  begin
`ifndef SYNTHESIS
                        if (pchk_hit) st_pfck_drop <= st_pfck_drop + 1;
`endif
                        pst <= pchk_hit ? P_IDLE : P_REQ;   // resident -> drop
                    end
            P_REQ:  if (p_iss_go) begin
                        p_rd   <= 1'b1;
                        p_addr <= {p_cand, 2'b00};        // raw; identical form to demand
                        pq_line[pq_wp[PPW-1:0]] <= p_cand;
                        pq_v   [pq_wp[PPW-1:0]] <= 1'b1;
                        pq_wp  <= pq_wp + 1'b1;
                        pst    <= P_IDLE;           // walker released HERE, not at commit
`ifndef SYNTHESIS
                        st_pfburst <= st_pfburst + 1;
`endif
                    end
            default: pst <= P_IDLE;
            endcase

            // ---- BEATS: fill the slot at pq_fp; bursts return in issue order ----
            if (p_beat_v) begin
                pq_acc[pq_f][64*p_beat +: 64] <= pfresp.dout;
                if (p_beat == 2'd3) begin p_beat <= 2'd0; pq_fp <= pq_fp + 1'b1; end
                else p_beat <= p_beat + 2'd1;
            end

            // ---- COMMIT: head slot into both arrays (driven combinationally by p_we) ----
            if (p_we) begin
                pq_v[pq_h] <= 1'b0;
                pq_rp      <= pq_rp + 1'b1;
`ifndef SYNTHESIS
                // between the passed re-check and this commit nobody else can have filled
                // this line (the demand path RIDES it instead), so a duplicate commit
                // means the dedup protocol broke.
                if (u_meta_a.mem[p_ix] == {1'b1, p_tag})
                    $error("tex_cache_4p_1c %m: DUPLICATE prefetch commit of resident line %07x",
                           pq_line[pq_h]);
`endif
            end
        end
    end

`ifndef SYNTHESIS
    // ==================== +occlog EVENT observation (sim only) ====================
    // Three INTERVAL events, each exposed as {level, start-pulse, line address} for
    // peel_core's occlog to sample hierarchically (same pattern as the u_shade /
    // u_spanner refs). Durations are measured by the sampler from the level, so the
    // cache only has to say WHAT is happening and TO WHICH LINE:
    //
    //   ev_miss  - a demand miss episode: from the S_RUN/S_RT2 decision that latched
    //              a missing line until the group finally acks. Covers the whole
    //              freeze (issue + burst + retest + any further fills of the same
    //              group), which is exactly the shade-pipe stall the trace is for.
    //   ev_pf    - the prefetch receiver holds AT LEAST ONE speculative line (front
    //              stage or ring). Not a stall - shown to see whether prefetches
    //              actually overlap the demand misses next to them. With the ring it is
    //              a level over up to PFQD lines, so its episodes no longer map 1:1 to
    //              lines; st_pfburst / st_pfhw in the final print are the per-line counts.
    //   ev_pfw   - the hitchhike wait: a line of the current batch is in flight on the
    //              prefetch client and NOTHING of ours is (fq_empty), so the batch is
    //              purely waiting on a foreign transfer. This is a SUBSET of ev_miss
    //              (a miss episode that cost nothing extra in DDR traffic but still
    //              stalled) and, by the fq_empty term, still DISJOINT from ev_fetch
    //              now that a batch can ride one line while fetching another.
    //   ev_fetch - our own demand burst(s) in flight: from an accepted issue until the
    //              queue drains. Also a SUBSET of ev_miss, and disjoint from ev_pfw -
    //              together they split a miss episode into "time actually moving data"
    //              vs "time waiting on someone else's transfer", with the remainder
    //              being arbiter wait (dresp.busy) plus the retest walk. One event per
    //              ISSUE (the sampler closes on a go pulse), so a batch that issues n
    //              lines yields n records, each addressed with the line it issued -
    //              but they now OVERLAP in time rather than running back to back, so
    //              summed FETCH cycles no longer add up to the serial total.
    //
    // ev_*_a is the LINE address (LAW bits), valid from the start pulse onward.
    reg            ev_miss, ev_pfw;
    reg [LAW-1:0]  ev_miss_a;
    wire           ev_miss_go = (st == S_RUN || st == S_RT2) && t_miss;
    wire           ev_miss_end = group_ack && (t_v[0]||t_v[1]||t_v[2]||t_v[3]);
    wire           ev_pf     = p_front_v || (pq_occ != '0);
    wire [LAW-1:0] ev_pf_a   = pf_fline;
    wire           ev_pf_go  = pf_take;
    wire           ev_pfw_lv = ride_w && fq_empty;
    wire           ev_pfw_go = ev_pfw_lv && !ev_pfw;
    // the exact burst-issue condition (the S_MISS arm above) and "any of ours in flight"
    wire           ev_fetch_go = iss_go;
    wire           ev_fetch    = !fq_empty;
    wire [LAW-1:0] ev_fetch_a  = iss_line;
    always @(posedge clk) begin
        if (reset || flush) begin
            ev_miss <= 1'b0; ev_pfw <= 1'b0;
        end else begin
            // miss episode: opens on the latch of a missing line, closes on the ack
            // that retires the group (the same edge a new episode can open on, so
            // the open wins - back-to-back groups each get their own event).
            if (ev_miss_go)       begin ev_miss <= 1'b1; ev_miss_a <= t_line[fm[1:0]]; end
            else if (ev_miss_end) ev_miss <= 1'b0;
            // both sides 32-bit SIGNED, left zero-extended so it can never read negative
            if (st_pfhw < int'({29'd0, pq_occ})) st_pfhw <= int'({29'd0, pq_occ});
            // hitchhike wait: ev_pfw is the DELAYED copy, used only to edge-detect
            // the start (ev_pfw_lv is the live level the sampler tracks)
            ev_pfw <= ev_pfw_lv;
        end
    end

    // ---- LIVELOCK detector (kept as a regression net, should never fire) ----
    // The t_done/t_word capture means every fill strictly shrinks the missing set -
    // dozens of back-to-back fills without a group ack means the invariant broke
    // (e.g. a probe hijacking a demand/retest read address, the exact bug class the
    // rd_en gate on probe_go exists for).
    integer tc_fills; reg tc_reported;
    always @(posedge clk) begin
        if (reset) begin tc_fills <= 0; tc_reported <= 1'b0; end
        else begin
            // count only GENUINE burst issues (the exact S_MISS issue condition).
            // Counting bare `S_MISS && !dresp.busy` false-fired once the hitchhike
            // path existed: demand SITS in S_MISS with its own client idle while it
            // waits for the in-flight prefetch of its line to commit, and a prefetch
            // burst under arbiter contention takes >64 cycles - 65 phantom "fills".
            if (group_ack && (t_v[0]||t_v[1]||t_v[2]||t_v[3])) tc_fills <= 0;
            else if (iss_go) tc_fills <= tc_fills + 1;
            if (tc_fills > 64 && !tc_reported) begin
                tc_reported <= 1'b1;
                $display("\n$$$$$$ TEX$ LIVELOCK %m (%0d fills, no group ack) $$$$$$", tc_fills);
                $display("  filling line=%08x (index=%0d tag=%0d) via port %0d", m_line, m_ix, m_tag, fm[1:0]);
                for (k=0;k<4;k=k+1)
                    $display("  port%0d: v=%0d done=%0d line=%08x  index=%0d tag=%0d  hit=%0d",
                             k, t_v[k], t_done[k], t_line[k], t_line[k][IXW-1:0],
                             t_line[k][LAW-1:IXW], t_hit[k]);
                $display("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$\n");
            end
        end
    end

    // ---- INVARIANTS the MLP fill queue rests on ----
    always @(posedge clk) if (!reset) begin
        // a returned beat must never land on a cycle that presents a read (the write
        // would silently swallow ports 0/2's reads - the bug class bram_tdp warns about)
        if (d_beat && rd_en)
            $error("tex_cache_4p_1c %m: demand beat on a read-present cycle (st=%0d)", st);
        // the retest must only run with the whole batch landed
        if ((st == S_RT0 || st == S_RT1) && !fq_empty)
            $error("tex_cache_4p_1c %m: retest entered with %0d fills still in flight",
                   fq_wp - fq_rp);
        // a beat with nothing outstanding means our issue/receive order desynced from
        // the arbiter's
        if (dresp.dready && fq_empty)
            $error("tex_cache_4p_1c %m: demand beat with an empty fill queue");
        // ---- prefetch ring: rp <= fp <= wp in ring order, never over-full ----
        if (pfresp.dready && !pq_rxing)
            $error("tex_cache_4p_1c %m: prefetch beat with no burst returning");
        if (pq_occ > PFQ_MAX)
            $error("tex_cache_4p_1c %m: prefetch ring overflow (%0d)", pq_occ);
        if ((pq_fp - pq_rp) > pq_occ)
            $error("tex_cache_4p_1c %m: prefetch fill pointer passed the issue pointer");
        // a commit writes port A of both arrays: never on a read-present cycle
        if (p_we && rd_en)
            $error("tex_cache_4p_1c %m: prefetch commit on a read-present cycle");
        // demand and prefetch must never write on the same edge (one port A each)
        if (p_we && fill_we)
            $error("tex_cache_4p_1c %m: demand and prefetch commit collided");
    end

    final begin
        $display("=== TEX$1c %m: %0d lookup-cycles: HIT4=%0d HIT3=%0d HIT2=%0d HIT1=%0d HIT0=%0d pfck_drop=%0d dwait=%0d ===",
                 stat_n, stat_hit[4], stat_hit[3], stat_hit[2], stat_hit[1], stat_hit[0],
                 st_pfck_drop, st_dwait);
        $display("=== TEX$1c %m MLP: %0d batches, %0d bursts (%.2f/batch); batches by bursts: 0=%0d 1=%0d 2=%0d 3=%0d 4=%0d ===",
                 st_batch, st_burst, st_batch ? real'(st_burst)/real'(st_batch) : 0.0,
                 st_mlp[0], st_mlp[1], st_mlp[2], st_mlp[3], st_mlp[4]);
        $display("=== TEX$1c %m PF: %0d bursts issued, ring depth %0d, high-water %0d ===",
                 st_pfburst, PFQD, st_pfhw);
    end
`endif
endmodule

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
// ======================= MISS BATCHES (multi-outstanding fills) =======================
// A miss episode hands the engine ALL of the t-group's distinct missing lines, which it
// fetches CONCURRENTLY; only when every one has come back does the retest run. A group
// needing n distinct lines therefore costs ONE round trip + n*4 beats instead of n
// serialized round trips.
//   * t_iss[k] marks a port whose line has been handed over. REQUEST-TIME DEDUP sets it
//     for EVERY port sharing that line, so the four corners of one bilinear sample that
//     land in the same line still cost one request (the common case - see the
//     lines-per-group histogram: 86% of missing groups want exactly one line).
//   * Aliasing is still safe: a later fill in the same batch may evict an earlier one,
//     but the LAST line written cannot be evicted by anyone, so its port always hits at
//     retest and every batch retires >= 1 port. A new batch clears t_iss and re-requests
//     whatever the retest still finds missing - the bound is at-most-4-BATCHES.
//   * Duplicate suppression against IN-FLIGHT lines (a line the engine is already
//     fetching, whether for us or speculatively) lives in the ENGINE now, not here: it
//     folds our request onto the existing entry and still owes us its demand_done. The
//     old hitchhike/ride_w bookkeeping is gone with it.
//
// ================================ THE FILL STEAL ================================
// A finished line is written by STEALING one lookup cycle instead of waiting for a cycle
// that happens to present no read. bram_tdp port A is the write port and takes priority
// over its read, so a write landing on a read-present cycle would silently swallow ports
// 0 and 2's reads; we make the cycle safe rather than deferring the write:
//   fill_req (level) -> ready drops, rd_en drops, S_RT0/S_RB0 HOLD, write goes through.
// Nothing in flight is corrupted: a group's read is presented one cycle BEFORE its
// compare, and the RAM outputs are registered, so the b-group landing this cycle is
// unaffected. S_RUN needs no special case - accept_ok already includes !fill_req, so the
// pipe simply takes a one-cycle bubble. S_RT0/S_RB0 must hold because their compare
// reads data presented THAT cycle.
// This is what removes per-line data buffering from the fill path: the engine keeps one
// accumulator, not one buffer per outstanding line, which is what makes a 16-deep
// speculative scan affordable.
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
// address is muxed write/read. Reads and writes NEVER coincide: reads are presented only
// in S_RUN/S_RT0/S_RB0, the sweep owns S_RST outright, and a fill write forces rd_en low
// for its cycle (THE FILL STEAL above).
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
    output               pf_busy,       // 1 = not streaming (probing is possible)

    // ================= FILL INTERFACE to the shared tex_fill_engine =================
    // This cache owns NO DDR client. It asks for lines and is handed finished lines;
    // one engine multiplexes every texel-path request onto a single arbiter port.
    //   miss_v/miss_line/miss_ack : one line at a time out of the current batch. The
    //     engine either enqueues it or folds it onto an already-queued entry; either
    //     way it acks, and it owes us exactly one demand_done for it.
    //   fill_req/fill_line/fill_data/fill_gnt : a completed line, written by STEALING
    //     one lookup cycle (see THE FILL STEAL below). Granted the same cycle.
    //   demand_done : pulse, one per completed line WE asked for. The batch retests
    //     when its outstanding count reaches zero.
    output               miss_v,
    output     [26:0]    miss_line,
    input                miss_ack,
    input                fill_req,
    input      [26:0]    fill_line,
    input      [255:0]   fill_data,
    output               fill_gnt,
    input                demand_done
);
    localparam integer NLINE = 1024;
    localparam integer IXW   = 10;
    localparam integer LAW   = 27;
    localparam integer TAGW  = LAW - IXW;           // 17
    localparam integer MW    = TAGW + 1;            // meta word = {vld, tag}

    integer i, k;

    // S_RUN   : streaming (accept -> b -> t -> ack, one group/cycle)
    // S_REQ   : hand the engine every distinct missing line of the t-group (one per
    //           ack), with corner dedup
    // S_WAIT  : all handed over - wait for the engine's demand_done for each
    // S_RT0/1 : re-present the t-group's reads / re-register hit+word (post-fill)
    // S_RT2   : re-decide the t-group (ack, or next batch of requests)
    // S_RB0/1 : replay the frozen b-group through LOOK/TEST, shift into t
    localparam S_RST=0, S_RUN=1, S_REQ=2, S_WAIT=3,
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

    // !fill_we is ESSENTIAL: on a stolen cycle rd_en is low, so a group accepted here
    // would have no RAM read presented for it and its TEST would compare against the
    // PREVIOUS group's registered read - a hit on the wrong line, silently returning
    // another line's data. Dropping ready for that cycle is the whole cost of the steal.
    wire accept_ok = (st == S_RUN) && !t_miss && !fill_we;
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
    // reads are PRESENTED only in these states, and NOT on a stolen fill cycle
    // (data lands the cycle after)
    wire rd_en = ((st == S_RUN) || (st == S_RT0) || (st == S_RB0)) && !fill_we;

    // ============ WRITE side: fill + invalidate sweep ============
    // Both arrays take the SAME write (broadcast); the write address is the sweep counter
    // during S_RST, otherwise the filled line's index. The write is unconditional except
    // during the sweep, which owns port A outright - the engine discards everything in
    // flight on flush, so in practice a fill never collides with a sweep (asserted).
    wire            sweep_we = (st == S_RST);
    wire            fill_we  = fill_req && !sweep_we;
    assign          fill_gnt = fill_we;
    wire [IXW-1:0]  f_ix     = fill_line[IXW-1:0];
    wire [TAGW-1:0] f_tag    = fill_line[LAW-1:IXW];
    wire            meta_we  = sweep_we || fill_we;
    wire            data_we  = fill_we;
    wire [IXW-1:0]  wa       = sweep_we ? rst_i[IXW-1:0] : f_ix;
    // ---- request selection: lowest missing port whose line is not yet handed over ----
    // im[2]=1 => nothing left to request in this batch. This tree is the old `fm` with
    // t_iss added; it lives in S_REQ (the request path), never on the decide path.
    wire [2:0] im = (t_v[0] && !t_ok[0] && !t_iss[0]) ? 3'd0 :
                    (t_v[1] && !t_ok[1] && !t_iss[1]) ? 3'd1 :
                    (t_v[2] && !t_ok[2] && !t_iss[2]) ? 3'd2 :
                    (t_v[3] && !t_ok[3] && !t_iss[3]) ? 3'd3 : 3'b100;
    wire            have_iss = !im[2];
    wire [LAW-1:0]  iss_line = t_line[im[1:0]];
    assign          miss_v    = (st == S_REQ) && have_iss;
    assign          miss_line = iss_line;
    wire            iss_go    = miss_v && miss_ack;
    // outstanding demand requests of the current batch (<= 4)
    reg  [2:0]      d_out;
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
    // another missing line after this one? If not, the request phase ends on the SAME
    // cycle as this ack - waiting a cycle to discover !have_iss would tax every batch,
    // including the 85% that only ever want one line.
    wire            iss_more = |(iss_need & ~iss_mask);
    wire [MW-1:0]   wmeta    = sweep_we ? {1'b0, {TAGW{1'b0}}} : {1'b1, f_tag};
    wire [255:0]    wdata    = fill_data;

    // ============ storage: 2 true-dual-port arrays serve the 4 demand ports ============
    // data_a/meta_a -> ports 0 (side A, also the write side) and 1 (side B)
    // data_b/meta_b -> ports 2 (side A, also the write side) and 3 (side B)
    wire [255:0] rdat0, rdat1, rdat2, rdat3;
    wire [MW-1:0] rmeta0, rmeta1, rmeta2, rmeta3;

    bram_tdp #(.W(256), .D(NLINE)) u_data_a (
        .clk(clk),
        .a_en(rd_en), .a_we(data_we), .a_addr(data_we ? wa : rd_ix[0]),
        .a_din(wdata), .a_q(rdat0),
        .b_en(rd_en), .b_addr(rd_ix[1]), .b_q(rdat1));
    bram_tdp #(.W(256), .D(NLINE)) u_data_b (
        .clk(clk),
        .a_en(rd_en), .a_we(data_we), .a_addr(data_we ? wa : rd_ix[2]),
        .a_din(wdata), .a_q(rdat2),
        .b_en(rd_en), .b_addr(rd_ix[3]), .b_q(rdat3));
    // ---- PROBE: 4 tags/cycle off the IDLE demand meta ports ----
    // Whenever the cache is not presenting a lookup, the demand read ports are unused,
    // so the scanner borrows them: meta_a port A/B and meta_b port A/B carry probes
    // 0..3. Not granted while reads are presented (rd_en: S_RUN, S_RT0, S_RB0 -
    // hijacking those addresses would corrupt a lookup, the livelock the old detector
    // caught) nor on a write cycle (meta_we, port A busy). The scanner watches pf_gnt
    // and simply re-presents on an ungranted cycle. The window is exactly the
    // demand-miss stall, which is when scanning ahead is worth the most.
    wire [IXW-1:0] pf_ix [0:3];
    wire [TAGW-1:0] pf_tg [0:3];
    generate
      for (gi=0; gi<4; gi=gi+1) begin : pfd
        assign pf_ix[gi] = pf_waddr[29*gi+2 +: IXW];
        assign pf_tg[gi] = pf_waddr[29*gi+2+IXW +: TAGW];
      end
    endgenerate
    wire probe_go = pf_req && !rd_en && !meta_we;
    assign pf_gnt = probe_go;
    wire [IXW-1:0] ma_a = meta_we ? wa : (probe_go ? pf_ix[0] : rd_ix[0]);
    wire [IXW-1:0] ma_b =                 probe_go ? pf_ix[1] : rd_ix[1];
    wire [IXW-1:0] mb_a = meta_we ? wa : (probe_go ? pf_ix[2] : rd_ix[2]);
    wire [IXW-1:0] mb_b =                 probe_go ? pf_ix[3] : rd_ix[3];
    bram_tdp #(.W(MW), .D(NLINE)) u_meta_a (
        .clk(clk),
        .a_en(rd_en || probe_go), .a_we(meta_we), .a_addr(ma_a),
        .a_din(wmeta), .a_q(rmeta0),
        .b_en(rd_en || probe_go), .b_addr(ma_b), .b_q(rmeta1));
    bram_tdp #(.W(MW), .D(NLINE)) u_meta_b (
        .clk(clk),
        .a_en(rd_en || probe_go), .a_we(meta_we), .a_addr(mb_a),
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

`ifndef SYNTHESIS
    integer stat_hit [0:4];
    integer stat_n;
    integer st_batch     = 0;    // fill batches (a batch = one round trip, n lines)
    integer st_req       = 0;    // lines requested from the engine
    integer st_mlp   [0:4];      // batches by number of lines they requested
    integer st_bcur      = 0;    // lines requested by the batch in progress
    integer st_steal     = 0;    // lookup cycles stolen by fills
`endif

    always @(posedge clk) begin
        if (reset || flush) begin
            // reset, or render start: re-enter the valid-clear sweep (invalidate all
            // lines). Safe because the shade pipe is idle between renders, and the engine
            // discards everything in flight on flush. Stats (sim-only) are intentionally
            // cumulative across renders.
            st <= S_RST; rst_i <= 0;
            t_iss <= 4'd0; d_out <= 3'd0;
            for (i=0;i<4;i=i+1) begin t_v[i]<=0; t_done[i]<=0; b_v[i]<=0; end
`ifndef SYNTHESIS
            if (reset) begin
                for (i=0;i<5;i=i+1) begin stat_hit[i] <= 0; st_mlp[i] <= 0; end
                stat_n <= 0;
            end
`endif
        end else begin
            // ---- outstanding demand requests of the batch ----
            d_out <= d_out + (iss_go ? 3'd1 : 3'd0) - (demand_done ? 3'd1 : 3'd0);
`ifndef SYNTHESIS
            if (fill_we && ((st == S_RUN) || (st == S_RT0) || (st == S_RB0)))
                st_steal <= st_steal + 1;
`endif

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
                    // A miss in the t-group: start a BATCH - every distinct missing line
                    // is handed to the engine from S_REQ and fetched concurrently. Ports
                    // that HIT right now already have their word REGISTERED in t_word -
                    // just mark them done; the fills are then free to evict their lines
                    // (what makes the unconditional broadcast safe). The b-group freezes
                    // untouched; ready was low this cycle so nothing new was accepted
                    // behind it.
                    for (k=0;k<4;k=k+1)
                        if (t_v[k] && !t_done[k] && t_hit[k]) t_done[k] <= 1'b1;
                    t_iss <= 4'd0;
                    st <= S_REQ;
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

            // REQUEST one line per ack until every distinct missing line of the batch is
            // handed over; the engine fetches them concurrently. Corner dedup (iss_mask)
            // means the four corners of one sample sharing a line cost ONE request. The
            // engine folds a request onto a line it is already fetching and still owes us
            // its demand_done, so there is no ride/hitchhike bookkeeping here any more.
            S_REQ: begin
                if (iss_go) begin
                    t_iss <= t_iss | iss_mask;
                    if (!iss_more) st <= S_WAIT;
`ifndef SYNTHESIS
                    st_req  <= st_req + 1;
                    st_bcur <= st_bcur + 1;
                    if (!iss_more) st_mlp[st_bcur + 1] <= st_mlp[st_bcur + 1] + 1;
`endif
                end else if (!have_iss) begin
                    st <= S_WAIT;
`ifndef SYNTHESIS
                    st_mlp[st_bcur] <= st_mlp[st_bcur] + 1;
`endif
                end
            end
            // everything requested: wait for a demand_done per request, so the retest
            // sees every line of the batch. The exit ANTICIPATES the last one (d_out
            // reaches 0 on this very edge) - noticing it a cycle later would cost every
            // batch a cycle. iss_go cannot fire here, so d_out only counts down.
            S_WAIT: if ((d_out == 3'd0) || (demand_done && (d_out == 3'd1)))
                        st <= S_RT0;

            // post-batch retest of the t-group: re-present its reads (S_RT0), re-register
            // hit+word for the not-yet-done ports (S_RT1), re-decide (S_RT2). Every port
            // whose line the batch filled now hits, EXCEPT one that a later commit in the
            // same batch aliased out - that one misses again and gets a fresh batch. The
            // last line committed cannot have been evicted, so every batch retires at
            // least one port and a group completes in at most 4 batches.
            // S_RT0/S_RB0 PRESENT reads whose compare lands the next cycle, so a stolen
            // fill cycle (rd_en forced low) must not advance them - hold instead.
            S_RT0: if (!fill_we) st <= S_RT1;
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
                    st <= S_REQ;
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
            S_RB0: if (!fill_we) st <= S_RB1;
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

`ifndef SYNTHESIS
    // ==================== +occlog EVENT observation (sim only) ====================
    // INTERVAL events exposed as {level, start-pulse, line address} for peel_core's
    // occlog to sample hierarchically. Durations are measured by the sampler from the
    // level, so the cache only says WHAT is happening and TO WHICH LINE:
    //
    //   ev_miss  - a miss episode: from the S_RUN/S_RT2 decision that latched a missing
    //              line until the group finally acks. Covers the whole stall (request +
    //              fetch + retest + any further batches of the same group), which is
    //              exactly the shade-pipe stall the trace is for.
    //   ev_fetch - this cache has demand lines outstanding at the engine (d_out != 0).
    //              A SUBSET of ev_miss; one record per REQUEST (the sampler closes on a
    //              go pulse), each addressed with the line requested. The engine owns
    //              the DDR port now, so its own event tracks cover the speculative side.
    //
    // ev_*_a is the LINE address (LAW bits), valid from the start pulse onward.
    reg            ev_miss;
    reg [LAW-1:0]  ev_miss_a;
    wire           ev_miss_go  = (st == S_RUN || st == S_RT2) && t_miss;
    wire           ev_miss_end = group_ack && (t_v[0]||t_v[1]||t_v[2]||t_v[3]);
    wire           ev_fetch_go = iss_go;
    wire           ev_fetch    = (d_out != 3'd0);
    wire [LAW-1:0] ev_fetch_a  = iss_line;
    always @(posedge clk) begin
        if (reset || flush) ev_miss <= 1'b0;
        else begin
            // opens on the latch of a missing line, closes on the ack that retires the
            // group (the same edge a new episode can open on, so the open wins -
            // back-to-back groups each get their own event).
            if (ev_miss_go)       begin ev_miss <= 1'b1; ev_miss_a <= t_line[fm[1:0]]; end
            else if (ev_miss_end) ev_miss <= 1'b0;
        end
    end

    // ---- LIVELOCK detector (kept as a regression net, should never fire) ----
    // The t_done/t_word capture means every batch strictly shrinks the missing set -
    // dozens of requests without a group ack means the invariant broke (e.g. a probe
    // hijacking a lookup/retest read address, the exact bug class the rd_en gate on
    // probe_go exists for).
    integer tc_fills; reg tc_reported;
    always @(posedge clk) begin
        if (reset) begin tc_fills <= 0; tc_reported <= 1'b0; end
        else begin
            if (group_ack && (t_v[0]||t_v[1]||t_v[2]||t_v[3])) tc_fills <= 0;
            else if (iss_go) tc_fills <= tc_fills + 1;
            if (tc_fills > 64 && !tc_reported) begin
                tc_reported <= 1'b1;
                $display("\n$$$$$$ TEX$ LIVELOCK %m (%0d requests, no group ack) $$$$$$", tc_fills);
                $display("  requesting line=%08x via port %0d", iss_line, fm[1:0]);
                for (k=0;k<4;k=k+1)
                    $display("  port%0d: v=%0d done=%0d iss=%0d line=%08x  index=%0d tag=%0d  hit=%0d",
                             k, t_v[k], t_done[k], t_iss[k], t_line[k], t_line[k][IXW-1:0],
                             t_line[k][LAW-1:IXW], t_hit[k]);
                $display("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$\n");
            end
        end
    end

    // ---- INVARIANTS the fill steal and the batch protocol rest on ----
    always @(posedge clk) if (!reset) begin
        // a fill write must never land on a cycle that presents a read (the write would
        // silently swallow ports 0/2's reads - the bug class bram_tdp warns about).
        // Trivially true via rd_en's !fill_we term; kept so removing that term fires.
        if (fill_we && rd_en)
            $error("tex_cache_4p_1c %m: fill write on a read-present cycle (st=%0d)", st);
        // the retest must only run with every line of the batch landed
        if ((st == S_RT0 || st == S_RT1) && (d_out != 3'd0))
            $error("tex_cache_4p_1c %m: retest entered with %0d requests outstanding", d_out);
        // demand_done must always be owed
        if (demand_done && (d_out == 3'd0) && !iss_go)
            $error("tex_cache_4p_1c %m: demand_done with nothing outstanding");
        // one batch can want at most the 4 corners' distinct lines
        if (d_out > 3'd4)
            $error("tex_cache_4p_1c %m: %0d requests outstanding (max 4)", d_out);
        // the engine must not present a fill during the invalidate sweep - it discards
        // everything in flight on flush, so this cannot happen
        if (fill_req && sweep_we)
            $error("tex_cache_4p_1c %m: fill presented during the invalidate sweep");
    end

    final begin
        $display("=== TEX$1c %m: %0d lookup-cycles: HIT4=%0d HIT3=%0d HIT2=%0d HIT1=%0d HIT0=%0d ===",
                 stat_n, stat_hit[4], stat_hit[3], stat_hit[2], stat_hit[1], stat_hit[0]);
        $display("=== TEX$1c %m BATCH: %0d batches, %0d lines requested (%.2f/batch); by lines: 0=%0d 1=%0d 2=%0d 3=%0d 4=%0d; %0d lookup cycles stolen by fills ===",
                 st_batch, st_req, st_batch ? real'(st_req)/real'(st_batch) : 0.0,
                 st_mlp[0], st_mlp[1], st_mlp[2], st_mlp[3], st_mlp[4], st_steal);
    end
`endif
endmodule

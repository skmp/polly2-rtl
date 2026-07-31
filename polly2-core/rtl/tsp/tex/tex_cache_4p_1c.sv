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

    integer i, k;

    // S_RUN   : streaming (accept -> b -> t -> ack, one group/cycle)
    // S_MISS  : issue the DDR burst for the t-group's first missing line
    // S_FILL  : receive 4 beats; last beat commits (fill_we)
    // S_RT0/1 : re-present the t-group's reads / re-register hit+word (post-fill)
    // S_RT2   : re-decide the t-group (ack, or next fill)
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

    // ============ WRITE side: fill commit + invalidate sweep + prefetch commit ============
    // Both arrays take the SAME write (broadcast); the write address is the sweep counter
    // during S_RST, the missing line's index on a fill commit, the prefetched line's on a
    // prefetch commit.
    reg  [LAW-1:0] m_line;              // line being demand-filled (last one filled)
    reg            m_v;                 // m_line has ever been latched (for pf_dup)
    reg [1:0]      m_beat; reg [255:0] m_acc;
    wire [IXW-1:0]  m_ix  = m_line[IXW-1:0];
    wire [TAGW-1:0] m_tag = m_line[LAW-1:IXW];
    wire [28:0]     m_base = {m_line, 2'b00};

    wire            sweep_we = (st == S_RST);
    wire            fill_we  = (st == S_FILL) && dresp.dready && (m_beat == 2'd3);
    wire            p_we;                       // prefetch commit (declared below)
    wire [IXW-1:0]  p_ix;
    wire [TAGW-1:0] p_tag;
    wire [255:0]    p_acc_w;
    wire            m_pf_ride;                  // demand's missing line is in flight on the
                                                // prefetch client (declared below): ride it
    wire            meta_we  = sweep_we || fill_we || p_we;
    wire            data_we  = fill_we || p_we;
    wire [IXW-1:0]  wa       = sweep_we ? rst_i[IXW-1:0] : (fill_we ? m_ix : p_ix);
    wire [MW-1:0]   wmeta    = sweep_we ? {1'b0, {TAGW{1'b0}}}
                             : fill_we  ? {1'b1, m_tag} : {1'b1, p_tag};
    wire [255:0]    wdata    = fill_we ? { dresp.dout, m_acc[191:0] } : p_acc_w;

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
    bram_tdp #(.W(MW), .D(NLINE)) u_meta_a (
        .clk(clk),
        .a_en(rd_en || probe_go || pchk_go), .a_we(meta_we), .a_addr(ma_a),
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

    // ============ demand DDR client ============
    reg        rd_r;   reg [28:0] addr_r; reg [7:0] burst_r;
    assign dreq.rd    = rd_r;
    assign dreq.addr  = addr_r;
    assign dreq.burst = burst_r;

`ifndef SYNTHESIS
    integer stat_hit [0:4];
    integer stat_n;
    integer st_pfck_drop = 0;    // prefetches dropped by the take-time re-check
    integer st_dwait     = 0;    // demand misses served by an in-flight prefetch
    reg     dwait_r      = 1'b0;
`endif

    always @(posedge clk) begin
        if (reset || flush) begin
            // reset, or render start: re-enter the valid-clear sweep (invalidate all
            // lines). Safe because the shade pipe is idle between renders (no fill in
            // flight). Stats (sim-only) are intentionally cumulative across renders.
            st <= S_RST; rd_r <= 0; rst_i <= 0; m_v <= 1'b0;
            for (i=0;i<4;i=i+1) begin t_v[i]<=0; t_done[i]<=0; b_v[i]<=0; end
`ifndef SYNTHESIS
            if (reset) begin
                for (i=0;i<5;i=i+1) stat_hit[i] <= 0;
                stat_n <= 0;
            end
`endif
        end else begin
            rd_r <= 1'b0;

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
                    // A miss in the t-group: latch the lowest missing line and go fill.
                    // Ports that HIT right now already have their word REGISTERED in
                    // t_word - just mark them done; the fill is then free to evict
                    // their lines (what makes the unconditional broadcast safe). The
                    // b-group freezes untouched; ready was low this cycle so nothing
                    // new was accepted behind it.
                    m_line <= t_line[fm[1:0]];
                    m_v    <= 1'b1;
                    m_beat <= 2'd0;
                    for (k=0;k<4;k=k+1)
                        if (t_v[k] && !t_done[k] && t_hit[k]) t_done[k] <= 1'b1;
                    st <= S_MISS;
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

            // burst-read the 4 words of the missing line - UNLESS the prefetch
            // receiver already has this exact line in flight: then issuing our own
            // burst would just fetch it twice. Wait for its commit (p_we fires
            // freely here: rd_en and fill_we are both low in S_MISS) and go
            // straight to the retest. If the receiver instead DROPS its line
            // (take-time re-check hit), pst returns to P_IDLE and we fall through
            // to a normal issue - no deadlock either way.
            S_MISS: begin
                if (m_pf_ride) begin
`ifndef SYNTHESIS
                    if (!dwait_r) begin st_dwait <= st_dwait + 1; dwait_r <= 1'b1; end
`endif
                    if (p_we) begin
                        st <= S_RT0;
`ifndef SYNTHESIS
                        dwait_r <= 1'b0;
`endif
                    end
                end else if (!dresp.busy) begin
                    rd_r    <= 1'b1;
                    addr_r  <= {4'b0011, m_base[24:0]};
                    burst_r <= 8'd4;
                    st      <= S_FILL;
`ifndef SYNTHESIS
                    dwait_r <= 1'b0;
`endif
                end
            end
            S_FILL: if (dresp.dready) begin
                m_acc[64*m_beat +: 64] <= dresp.dout;
                if (m_beat == 2'd3) st <= S_RT0;   // fill_we commits this same edge
                else m_beat <= m_beat + 2'd1;
            end

            // post-fill retest of the t-group: re-present its reads (S_RT0), re-register
            // hit+word for the not-yet-done ports (S_RT1), re-decide (S_RT2). The port
            // whose line was just filled now hits; a port to a different still-missing
            // line misses again -> another fill. Every fill retires at least one port,
            // so a group completes in at most 4 fills.
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
                    m_line <= t_line[fm[1:0]];
                    m_v    <= 1'b1;
                    m_beat <= 2'd0;
                    for (k=0;k<4;k=k+1)
                        if (t_v[k] && !t_done[k] && t_hit[k]) t_done[k] <= 1'b1;
                    st <= S_MISS;
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

    // ==================== PREFETCH RECEIVER ====================
    // An independent single-outstanding fill on its own DDR client, so a
    // speculative line pipelines BEHIND demand fills instead of serialising on the
    // demand port. It shares the arrays' write path, which the demand fill owns:
    //   * the commit waits for a cycle with the demand write idle (!fill_we,
    //     !sweep_we) AND no demand reads presented (!rd_en). Port A of each array
    //     is the write port, and bram_tdp gives writes priority - committing on a
    //     read-present cycle would silently swallow ports 0 and 2's reads.
    //     !rd_en holds through S_MISS/S_FILL/S_RT1/S_RT2/S_RB1, so slots abound.
    //   * pf_dup: never prefetch the line the demand path filled LAST (m_line) -
    //     with the walker's fill request registered, the request can arrive a few
    //     cycles after the demand fill that made it redundant. This is a plain
    //     27-bit compare off registers; the old combinational miss_now term is
    //     gone (a walker fill request can only follow a probe granted during a
    //     fill episode, so the state check was provably redundant - and it was
    //     half of the -9ns launch cone).
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
    localparam P_IDLE=0, P_CK0=1, P_CK1=2, P_REQ=3, P_FILL=4, P_WAIT=5;
    reg [2:0]      pst;
    reg [LAW-1:0]  p_line;
    reg [1:0]      p_beat;
    reg [255:0]    p_acc;
    assign p_ix     = p_line[IXW-1:0];
    assign p_tag    = p_line[LAW-1:IXW];
    assign p_chk_ix = p_ix;
    assign p_acc_w  = p_acc;
    wire [LAW-1:0] pf_fline = pf_faddr[28:2];
    wire pf_dup   = m_v && (pf_fline == m_line);
    wire pf_take  = pf_fill && (pst == P_IDLE) && !pf_dup;
    wire p_active = (pst != P_IDLE);
    assign pf_fbusy = p_active;
    assign m_pf_ride = p_active && (p_line == m_line);
    assign pchk_go  = (pst == P_CK0) && !rd_en && !meta_we;
    // the re-read landed this cycle: resident?
    wire pchk_hit   = rmeta0[TAGW] && (rmeta0[TAGW-1:0] == p_tag);
    reg        p_rd; reg [28:0] p_addr;
    assign pfreq.rd    = p_rd;
    assign pfreq.addr  = p_addr;
    assign pfreq.burst = 8'd4;
    // commit slot: demand write idle AND no demand reads presented
    assign p_we = (pst == P_WAIT) && !fill_we && !sweep_we && !rd_en;
    always @(posedge clk) begin
        if (reset || flush) begin
            pst <= P_IDLE; p_rd <= 1'b0; p_beat <= 2'd0;
        end else begin
            p_rd <= 1'b0;
            case (pst)
            P_IDLE: if (pf_take) begin p_line <= pf_fline; p_beat <= 2'd0; pst <= P_CK0; end
            P_CK0:  if (pchk_go) pst <= P_CK1;      // tag re-read presented
            P_CK1:  begin
`ifndef SYNTHESIS
                        if (pchk_hit) st_pfck_drop <= st_pfck_drop + 1;
`endif
                        pst <= pchk_hit ? P_IDLE : P_REQ;   // resident -> drop
                    end
            P_REQ:  if (!pfresp.busy) begin
                        p_rd <= 1'b1;
                        p_addr <= {4'b0011, {p_line, 2'b00} & 29'h1FFFFFF};
                        pst <= P_FILL;
                    end
            P_FILL: if (pfresp.dready) begin
                        p_acc[64*p_beat +: 64] <= pfresp.dout;
                        if (p_beat == 2'd3) pst <= P_WAIT;
                        else p_beat <= p_beat + 2'd1;
                    end
            P_WAIT: if (p_we) begin
                        pst <= P_IDLE;
`ifndef SYNTHESIS
                        // between the passed re-check and this commit nobody else can
                        // have filled this line (the demand path waits on it instead),
                        // so a duplicate commit means the dedup protocol broke.
                        if (u_meta_a.mem[p_ix] == {1'b1, p_tag})
                            $error("tex_cache_4p_1c %m: DUPLICATE prefetch commit of resident line %07x",
                                   p_line);
`endif
                    end
            default: pst <= P_IDLE;
            endcase
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
    //   ev_pf    - the prefetch receiver is occupied with one speculative line
    //              (P_CK0 take .. commit/drop). Not a stall - shown to see whether
    //              prefetches actually overlap the demand misses next to them.
    //   ev_pfw   - the hitchhike wait: a demand miss whose line is already in flight
    //              on the prefetch client, sitting in S_MISS for that commit. This
    //              is a SUBSET of ev_miss (a miss episode that cost nothing extra in
    //              DDR traffic but still stalled), so the viewer can separate
    //              "missed and fetched" from "missed and waited on a prefetch".
    //   ev_fetch - the demand DDR burst itself: S_FILL, from the accepted issue to
    //              the 4th beat. Also a SUBSET of ev_miss, and the complement of
    //              ev_pfw in the interesting sense - together they split a miss
    //              episode into "time actually moving data" vs "time waiting on
    //              someone else's transfer", with the remainder being arbiter wait
    //              in S_MISS (dresp.busy) plus the retest walk. ONE burst per
    //              event: a group that misses on several lines re-enters S_MISS
    //              and gets a separate ev_fetch per line, each with its own addr.
    //
    // ev_*_a is the LINE address (LAW bits), valid from the start pulse onward.
    reg            ev_miss, ev_pfw;
    reg [LAW-1:0]  ev_miss_a;
    wire           ev_miss_go = (st == S_RUN || st == S_RT2) && t_miss;
    wire           ev_miss_end = group_ack && (t_v[0]||t_v[1]||t_v[2]||t_v[3]);
    wire           ev_pf     = p_active;
    wire [LAW-1:0] ev_pf_a   = p_line;
    wire           ev_pf_go  = pf_take;
    wire           ev_pfw_lv = (st == S_MISS) && m_pf_ride;
    wire           ev_pfw_go = ev_pfw_lv && !ev_pfw;
    // the exact burst-issue condition (mirrors the S_MISS arm above): not riding a
    // prefetch, and the DDR client accepted the request this cycle
    wire           ev_fetch_go = (st == S_MISS) && !m_pf_ride && !dresp.busy;
    wire           ev_fetch    = (st == S_FILL);
    always @(posedge clk) begin
        if (reset || flush) begin
            ev_miss <= 1'b0; ev_pfw <= 1'b0;
        end else begin
            // miss episode: opens on the latch of a missing line, closes on the ack
            // that retires the group (the same edge a new episode can open on, so
            // the open wins - back-to-back groups each get their own event).
            if (ev_miss_go)       begin ev_miss <= 1'b1; ev_miss_a <= t_line[fm[1:0]]; end
            else if (ev_miss_end) ev_miss <= 1'b0;
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
            else if (st==S_MISS && !m_pf_ride && !dresp.busy) tc_fills <= tc_fills + 1;
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

    final begin
        $display("=== TEX$1c %m: %0d lookup-cycles: HIT4=%0d HIT3=%0d HIT2=%0d HIT1=%0d HIT0=%0d pfck_drop=%0d dwait=%0d ===",
                 stat_n, stat_hit[4], stat_hit[3], stat_hit[2], stat_hit[1], stat_hit[0],
                 st_pfck_drop, st_dwait);
    end
`endif
endmodule

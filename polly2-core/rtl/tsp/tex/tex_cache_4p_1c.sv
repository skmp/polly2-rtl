//
// tex_cache_4p_1c - 4-READ-PORT texture cache, 1-CYCLE reply variant of tex_cache_4p.
// 1024 lines x 32 BYTES (256-bit = 4x 64-bit words), direct-mapped, over the DDR3 raw
// 64-bit read port. Backs the 4 bilinear corner fetchers.
//
// DIFFERENCE vs tex_cache_4p (the 2-cycle LOOK->TEST version): here a request presented
// while cresp[i].ready is high is ACCEPTED at cycle N and its result is returned at
// cycle N+1 - ONE cycle of latency. On a miss the cache HOLDS: it deasserts ready (all
// ports) and fills from DDR, then serves the held request. The client therefore never
// sees a "not-ok" - only a late accept (ready low until the line is resident).
//
// PIPELINE, per port i:
//   ACCEPT (cycle N):  creq[i].req && cresp[i].ready. The accepted line index drives
//                      copy i's M10K read port (combinational addr -> registered rdata),
//                      and the request fields {line,tag,wsel,valid} are registered into
//                      treg[i]. ready is HIGH only when the cache is running and not
//                      filling.
//   REPLY  (cycle N+1): the registered rdat/rmeta + treg decide HIT combinationally, and
//                      cresp[i].ack + cresp[i].rdata are driven THIS cycle (combinational
//                      off the registered read). A MISS here freezes + fills; the held
//                      treg re-tests after the fill and then acks. So a hit is 1 cycle;
//                      a miss extends by the fill time but the SAME request is served.
//
// FILL LOOKAHEAD (this revision): the fill path is split into
//   * a FILL RECEIVER (fr_*): ONE outstanding DDR request end-to-end; consumes the
//     arbiter-qualified beats WHENEVER they arrive (independent of the FSM state) and
//     writes the line under a LIVE alias-skip mask (evaluated at the write beat, so a
//     prefetched fill can never evict a line the CURRENTLY-frozen group needs).
//   * a REQUEST SCHEDULER: the frozen group's missing lines are issued BACK-TO-BACK
//     (the next request pulses on the same cycle the previous burst's last beat lands
//     - the per-client pend latch in the DDR arbiter captures a pulse at any time),
//     with ONE retest at the end instead of one per fill.
//   * a PROBE port: while the cache is frozen filling, the idle meta read port tag-
//     checks the fetch queue's NEXT pending row (probe_*); its first missing line is
//     DDR-requested as soon as the group's own fills are done, so the next burst is
//     already PENDING at the arbiter when the current one ends (removes the ack ->
//     accept -> miss-discovery gap AND the channel is not lost to other clients in
//     that window). When the probed row is later accepted and misses, ports whose
//     line matches the in-flight fill are marked already-requested (no double fetch).
//
// M10K: line DATA is held in FOUR full copies (data0..data3), one registered-read block
// RAM per port, so 4 parallel reads map to M10K on Cyclone V. A fill BROADCASTS the
// line into every copy it safely can. The ONE copy a fill must skip: a port frozen on
// a DIFFERENT line at the SAME index (alias) - overwriting it is the eviction ping-pong
// that livelocked the group-atomic protocol. The skip mask is computed LIVE at the
// write beat (fr_wm below), so it is always correct w.r.t. the group frozen right now.
//
// PROTOCOL per port i (UNCHANGED by the lookahead revision):
//   creq[i].req    : client wants to issue creq[i].waddr this cycle
//   cresp[i].ready : cache can accept it this cycle (LOW during a fill / reset sweep)
//   ACCEPTED       : creq[i].req && cresp[i].ready
//   cresp[i].ack   : group-atomic result strobe (all valid ports together, in order)
//   cresp[i].rdata : the requested 64-bit word
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

    // ---- PROBE (fill lookahead): the client's NEXT pending lookup group, presented
    //      while the cache is frozen. Tag-checked on the idle read port; the first
    //      missing line is prefetched. Tie probe_valid low when unused. ----
    input                probe_valid,
    input  [3:0]         probe_mask,
    input  [28:0]        probe_waddr [0:3],

    output ddr_rd_req_t  dreq,
    input  ddr_rd_resp_t dresp
);
    localparam integer NLINE = 1024;
    localparam integer IXW   = 10;
    localparam integer LAW   = 27;
    localparam integer TAGW  = LAW - IXW;           // 17

    (* ramstyle = "M10K, no_rw_check" *) reg [255:0] data0 [0:NLINE-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [255:0] data1 [0:NLINE-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [255:0] data2 [0:NLINE-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [255:0] data3 [0:NLINE-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [TAGW:0] meta0 [0:NLINE-1]; // {vld, tag}
    (* ramstyle = "M10K, no_rw_check" *) reg [TAGW:0] meta1 [0:NLINE-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [TAGW:0] meta2 [0:NLINE-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [TAGW:0] meta3 [0:NLINE-1];

    integer i, k;

    localparam S_RST=0, S_RUN=1, S_WAITFILL=2, S_RETEST=3;
    reg [1:0] st;
    reg [IXW:0] rst_i;

    // A REPLY-stage miss this cycle (combinational off the registered read). While a miss
    // is being serviced (or during reset) the cache cannot accept, so ready is low.
    wire miss_now;                                 // = !fm[2]
    wire accept = (st == S_RUN) && !miss_now;
    wire [3:0] acc;
    genvar gi;
    generate
      for (gi=0; gi<4; gi=gi+1) begin : ac
        assign acc[gi]           = accept && creq[gi].req;
        assign cresp[gi].ready   = accept;             // backpressure (same all ports)
      end
    endgenerate

    // ---- decode the incoming (accepted) request per port ----
    wire [LAW-1:0]  in_line[0:3];
    wire [IXW-1:0]  in_ix  [0:3];
    wire [TAGW-1:0] in_tag [0:3];
    wire [1:0]      in_wsel[0:3];
    generate
      for (gi=0; gi<4; gi=gi+1) begin : ind
        assign in_line[gi] = creq[gi].waddr[28:2];
        assign in_ix[gi]   = in_line[gi][IXW-1:0];
        assign in_tag[gi]  = in_line[gi][LAW-1:IXW];
        assign in_wsel[gi] = creq[gi].waddr[1:0];
      end
    endgenerate

    // probe decode
    wire [LAW-1:0]  pr_line[0:3];
    wire [IXW-1:0]  pr_ix  [0:3];
    generate
      for (gi=0; gi<4; gi=gi+1) begin : prd
        assign pr_line[gi] = probe_waddr[gi][28:2];
        assign pr_ix[gi]   = pr_line[gi][IXW-1:0];
      end
    endgenerate

    // ============ READ address: retest > probe (while frozen) > accepted request ============
    // The rdat/rmeta registers are CLOBBERED by probe reads while frozen - safe, because
    // every return to S_RUN goes through S_RETEST which reloads them for the group.
    reg  [IXW-1:0] rd_ix [0:3];
    reg  [IXW-1:0] retest_ix [0:3];
    reg            retesting;
    reg            pr_evd;                  // probe evaluated for this fill episode
    reg            pf_have;                 // prefetch candidate latched
    wire pr_want = (st == S_WAITFILL) && !retesting && probe_valid && !pr_evd && !pf_have;
    reg  pr_rdp;                            // a probe read lands this cycle
    always @(*) begin
        for (int p=0; p<4; p=p+1)
            rd_ix[p] = retesting ? retest_ix[p] : pr_want ? pr_ix[p] : in_ix[p];
    end

    // registered M10K reads, one per port.
    reg [255:0]  rdat [0:3];
    reg [TAGW:0] rmeta[0:3];
    wire         rd_en = (st == S_RUN) || retesting || pr_want;
    always @(posedge clk) if (rd_en) begin
        rdat[0]  <= data0[rd_ix[0]];  rmeta[0] <= meta0[rd_ix[0]];
        rdat[1]  <= data1[rd_ix[1]];  rmeta[1] <= meta1[rd_ix[1]];
        rdat[2]  <= data2[rd_ix[2]];  rmeta[2] <= meta2[rd_ix[2]];
        rdat[3]  <= data3[rd_ix[3]];  rmeta[3] <= meta3[rd_ix[3]];
    end

    // ============ REPLY register: the request whose data is arriving this cycle ============
    reg            t_v   [0:3];
    reg [LAW-1:0]  t_line[0:3];
    reg [TAGW-1:0] t_tag [0:3];
    reg [1:0]      t_wsel[0:3];
    wire        t_hit [0:3];
    wire [63:0] t_word[0:3];
    generate
      for (gi=0; gi<4; gi=gi+1) begin : th
        assign t_hit[gi]  = t_v[gi] && rmeta[gi][TAGW] && (rmeta[gi][TAGW-1:0]==t_tag[gi]);
        assign t_word[gi] = rdat[gi][64*t_wsel[gi] +: 64];
      end
    endgenerate

    // lowest-index REPLY-stage port that MISSED. fm[2]=1 => none.
    wire [2:0] fm = (t_v[0] && !t_hit[0]) ? 3'd0 :
                    (t_v[1] && !t_hit[1]) ? 3'd1 :
                    (t_v[2] && !t_hit[2]) ? 3'd2 :
                    (t_v[3] && !t_hit[3]) ? 3'd3 : 3'b100;
    assign miss_now = !fm[2];

    wire group_ready = (st == S_RUN) && !miss_now;          // ALL valid ports resident

    // ---- 1-CYCLE OUTPUTS, GROUP-ATOMIC (unchanged) ----
    generate
      for (gi=0; gi<4; gi=gi+1) begin : od
        assign cresp[gi].ack   = group_ready && t_v[gi];
        assign cresp[gi].rdata = t_word[gi];
      end
    endgenerate

    // ============ FILL RECEIVER: one outstanding request, beats consumed anywhere ============
    reg            fr_busy;
    reg [LAW-1:0]  fr_line;
    reg [1:0]      fr_beat;
    reg [191:0]    fr_acc;
    wire [IXW-1:0] fr_ix      = fr_line[IXW-1:0];
    wire           fr_beat_now= fr_busy && dresp.dready;
    wire           fr_last    = fr_beat_now && (fr_beat == 2'd3);
    // LIVE alias-skip write mask: skip copy k only when port k is currently held on a
    // DIFFERENT line at the SAME index (evaluated at the write beat, so it is correct
    // for prefetched fills landing under a newer frozen group too).
    wire [3:0] fr_wm;
    generate
      for (gi=0; gi<4; gi=gi+1) begin : fwm
        assign fr_wm[gi] = !t_v[gi]
                        || (t_line[gi] == fr_line)
                        || (t_line[gi][IXW-1:0] != fr_ix);
      end
    endgenerate

    // ============ frozen-group fill bookkeeping ============
    reg [3:0] g_miss;                       // frozen ports still awaiting their line
    reg [3:0] g_req;                        // ... whose line is requested / in flight
    wire [2:0] nq = (g_miss[0] && !g_req[0]) ? 3'd0 :
                    (g_miss[1] && !g_req[1]) ? 3'd1 :
                    (g_miss[2] && !g_req[2]) ? 3'd2 :
                    (g_miss[3] && !g_req[3]) ? 3'd3 : 3'b100;

    // ============ prefetch candidate ============
    reg [LAW-1:0] pf_line;

    // DDR request pulse
    reg        rd_r;   reg [28:0] addr_r;
    assign dreq.rd    = rd_r;
    assign dreq.addr  = addr_r;
    assign dreq.burst = 8'd4;

    // scheduler can issue when the receiver is free THIS cycle or freeing (last beat):
    // the sequential block below lets the issue's fr_* assignments win over the
    // receiver's clear, giving back-to-back bursts with zero idle request cycles.
    wire fr_can_issue = (!fr_busy || fr_last) && !rd_r;

`ifndef SYNTHESIS
    integer stat_hit [0:4];
    integer stat_n;
    integer st_pf_iss, st_fills;
`endif

    always @(posedge clk) begin
        if (reset || flush) begin
            st <= S_RST; rd_r <= 0; rst_i <= 0; retesting <= 0;
            fr_busy <= 1'b0; g_miss <= 4'd0; g_req <= 4'd0;
            pf_have <= 1'b0; pr_evd <= 1'b0; pr_rdp <= 1'b0;
            for (i=0;i<4;i=i+1) t_v[i]<=0;
`ifndef SYNTHESIS
            if (reset) begin
                for (i=0;i<5;i=i+1) stat_hit[i] <= 0;
                stat_n <= 0; st_pf_iss <= 0; st_fills <= 0;
            end
            if (flush && !reset && fr_busy)
                $error("tex_cache_4p_1c %m: flush with a fill in flight");
`endif
        end else begin
            rd_r <= 1'b0;
            retesting <= 1'b0;
            pr_rdp <= pr_want;

            // -------- fill receiver: consume qualified beats in ANY state --------
            if (fr_beat_now) begin
                fr_beat <= fr_beat + 2'd1;
                if (fr_beat != 2'd3) fr_acc[64*fr_beat +: 64] <= dresp.dout;
                else begin
                    if (fr_wm[0]) begin data0[fr_ix] <= { dresp.dout, fr_acc }; meta0[fr_ix] <= {1'b1, fr_line[LAW-1:IXW]}; end
                    if (fr_wm[1]) begin data1[fr_ix] <= { dresp.dout, fr_acc }; meta1[fr_ix] <= {1'b1, fr_line[LAW-1:IXW]}; end
                    if (fr_wm[2]) begin data2[fr_ix] <= { dresp.dout, fr_acc }; meta2[fr_ix] <= {1'b1, fr_line[LAW-1:IXW]}; end
                    if (fr_wm[3]) begin data3[fr_ix] <= { dresp.dout, fr_acc }; meta3[fr_ix] <= {1'b1, fr_line[LAW-1:IXW]}; end
                    fr_busy <= 1'b0;
                    // satisfied frozen ports (line now resident)
                    for (k=0;k<4;k=k+1) if (t_line[k] == fr_line) g_miss[k] <= 1'b0;
                    pr_evd <= 1'b0;          // tags changed: allow a fresh probe pass
`ifndef SYNTHESIS
                    st_fills <= st_fills + 1;
`endif
                end
            end

            // -------- probe evaluation (read issued last cycle lands now) --------
            if (pr_rdp && !pf_have) begin : prev
                reg        found;
                reg [LAW-1:0] cand;
                found = 1'b0; cand = '0;
                for (k=0;k<4;k=k+1)
                    if (!found && probe_mask[k]
                        && !(rmeta[k][TAGW] && rmeta[k][TAGW-1:0] == pr_line[k][LAW-1:IXW])) begin
                        found = 1'b1; cand = pr_line[k];
                    end
                // don't prefetch a line the group will fill anyway / already in flight
                if (found) begin
                    if (fr_busy && fr_line == cand) found = 1'b0;
                    for (k=0;k<4;k=k+1)
                        if (g_miss[k] && t_line[k] == cand) found = 1'b0;
                end
                if (found) begin pf_have <= 1'b1; pf_line <= cand; end
                pr_evd <= 1'b1;              // one evaluation per fill episode
            end

            // -------- request scheduler: group lines first, then the prefetch --------
            if (fr_can_issue) begin
                if ((st == S_WAITFILL) && !nq[2]) begin
                    rd_r    <= 1'b1;
                    addr_r  <= {4'b0011, t_line[nq[1:0]][22:0], 2'b00};
                    fr_busy <= 1'b1; fr_line <= t_line[nq[1:0]]; fr_beat <= 2'd0;
                    for (k=0;k<4;k=k+1)
                        if (t_line[k] == t_line[nq[1:0]]) g_req[k] <= 1'b1;
                end else if (pf_have) begin
                    rd_r    <= 1'b1;
                    addr_r  <= {4'b0011, pf_line[22:0], 2'b00};
                    fr_busy <= 1'b1; fr_line <= pf_line; fr_beat <= 2'd0;
                    pf_have <= 1'b0;
`ifndef SYNTHESIS
                    st_pf_iss <= st_pf_iss + 1;
`endif
                end
            end

            // -------- FSM --------
            case (st)
            S_RST: begin
                meta0[rst_i[IXW-1:0]][TAGW] <= 1'b0;
                meta1[rst_i[IXW-1:0]][TAGW] <= 1'b0;
                meta2[rst_i[IXW-1:0]][TAGW] <= 1'b0;
                meta3[rst_i[IXW-1:0]][TAGW] <= 1'b0;
                for (i=0;i<4;i=i+1) t_v[i] <= 1'b0;
                if (rst_i == NLINE-1) st <= S_RUN;
                else rst_i <= rst_i + 1'b1;
            end

            S_RUN: begin
`ifndef SYNTHESIS
                if (t_v[0] || t_v[1] || t_v[2] || t_v[3]) begin
                    stat_hit[(t_hit[0]?1:0)+(t_hit[1]?1:0)
                            +(t_hit[2]?1:0)+(t_hit[3]?1:0)]
                        <= stat_hit[(t_hit[0]?1:0)+(t_hit[1]?1:0)
                                   +(t_hit[2]?1:0)+(t_hit[3]?1:0)] + 1;
                    stat_n <= stat_n + 1;
                end
`endif
                if (!fm[2]) begin
                    // freeze the WHOLE group (hitting ports stay valid so all ack
                    // together after the fills). A port whose line matches the fill
                    // completing THIS cycle is already resident; one matching an
                    // in-flight fill is marked requested (no double fetch).
                    for (k=0;k<4;k=k+1) begin
                        retest_ix[k] <= t_line[k][IXW-1:0];
                        g_miss[k] <= t_v[k] && !t_hit[k]
                                     && !(fr_last && t_line[k] == fr_line);
                        g_req[k]  <= fr_busy && !fr_last && (t_line[k] == fr_line);
                    end
                    pr_evd <= 1'b0;
                    st <= S_WAITFILL;
                end else begin
                    for (k=0;k<4;k=k+1) begin
                        t_v[k]    <= acc[k];
                        t_line[k] <= in_line[k];
                        t_tag[k]  <= in_tag[k];
                        t_wsel[k] <= in_wsel[k];
                    end
                end
            end

            // frozen: the scheduler/receiver above do the work; leave when the whole
            // group is resident - INCLUDING the fill landing this very cycle (else a
            // cycle is lost per burst). A prefetch may still be streaming; the
            // receiver handles it in S_RETEST/S_RUN autonomously.
            S_WAITFILL: begin : wf
                reg [3:0] g_miss_now;
                for (k=0;k<4;k=k+1)
                    g_miss_now[k] = g_miss[k] && !(fr_last && t_line[k] == fr_line);
                if (g_miss_now == 4'd0) begin
                    retesting <= 1'b1;
                    st <= S_RETEST;
                end
            end

            // one cycle for the re-presented reads to land, then S_RUN re-tests treg.
            S_RETEST: st <= S_RUN;
            default:  st <= S_RUN;
            endcase
        end
    end

`ifndef SYNTHESIS
    // ---- LIVELOCK detector: fills that never resolve the group ----
    integer tc_fills; reg tc_reported;
    always @(posedge clk) begin
        if (reset) begin tc_fills <= 0; tc_reported <= 1'b0; end
        else begin
            if (group_ready)  tc_fills <= 0;
            else if (fr_last) tc_fills <= tc_fills + 1;
            if (tc_fills > 64 && !tc_reported) begin
                tc_reported <= 1'b1;
                $display("\n$$$$$$ TEX$ LIVELOCK %m (%0d fills, no group_ready) $$$$$$", tc_fills);
                $display("  filling line=%08x  g_miss=%b g_req=%b st=%0d", fr_line, g_miss, g_req, st);
                for (k=0;k<4;k=k+1)
                    $display("  port%0d: v=%0d line=%08x  index=%0d tag=%0d  hit=%0d",
                             k, t_v[k], t_line[k], t_line[k][IXW-1:0], t_line[k][LAW-1:IXW], t_hit[k]);
                $display("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$\n");
            end
        end
    end

    final begin
        $display("=== TEX$1c %m: %0d lookup-cycles: HIT4=%0d HIT3=%0d HIT2=%0d HIT1=%0d HIT0=%0d fills=%0d (prefetched=%0d) ===",
                 stat_n, stat_hit[4], stat_hit[3], stat_hit[2], stat_hit[1], stat_hit[0],
                 st_fills, st_pf_iss);
    end
`endif
endmodule

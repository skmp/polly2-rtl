//
// tex_cache_4p_1c - 4-READ-PORT texture cache, 1-CYCLE reply variant of tex_cache_4p.
// 1024 lines x 32 BYTES (256-bit = 4x 64-bit words), direct-mapped, over the DDR3 raw
// 64-bit read port. Backs the 4 bilinear corner fetchers. Plus a 5th, always-available
// PREFILL PROBE port (tag-only residency test; see PREFILL PROBE below).
//
// DIFFERENCE vs tex_cache_4p (the 2-cycle LOOK->TEST version): here a request presented
// while cresp[i].ready is high is ACCEPTED at cycle N and its result is returned at
// cycle N+1 - ONE cycle of latency. On a miss the cache HOLDS: it deasserts ready (all
// ports) and fills from DDR, then serves the held request. The client therefore never
// sees a "not-ok" - only a late accept (ready low until the line is resident). This
// matches the fixed-latency, no-FIFO tex_fetch_pp pipeline (T0 issue -> T1 data).
//
// PIPELINE, per port i:
//   ACCEPT (cycle N):  creq[i].req && cresp[i].ready. The accepted line index drives
//                      port i's block-RAM read port (combinational addr -> registered
//                      rdata), and the request fields {line,tag,wsel,valid} are
//                      registered into treg[i]. ready is HIGH only when the cache is
//                      running and not filling.
//   REPLY  (cycle N+1): the registered rdat/rmeta + treg decide HIT combinationally, and
//                      cresp[i].ack + cresp[i].rdata are driven THIS cycle (combinational
//                      off the registered read). A MISS here freezes + fills; the held
//                      treg re-tests after the fill and then acks. So a hit is 1 cycle;
//                      a miss extends by the fill time but the SAME request is served.
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
// here: rd_en is low outside S_RUN/retest, and every write happens in S_FILL/S_RST.
//
// ============================ WHY THERE IS NO ALIAS LIVELOCK ============================
// Sharing storage between sibling ports removed the per-copy trick the old 4-copy
// version relied on. Previously a fill skipped the copy of a port frozen on a DIFFERENT
// line at the SAME index, because overwriting it was the direct-mapped eviction
// ping-pong that livelocked the group-atomic protocol. With ports 0/1 sharing one array
// that no longer works in either direction: honouring the sibling's veto suppresses the
// write the missing port needs (it re-misses forever), and ignoring it reinstates the
// ping-pong, because siblings can no longer hold two aliasing lines at once.
//
// The fix is to stop needing the line to stay resident. A port that HITS while the group
// is still waiting has its 64-bit word captured into t_hold[i] and is marked t_done[i];
// from then on it is served from the hold register and does not care if its line is
// evicted. So fills now BROADCAST unconditionally to both arrays, and every fill retires
// at least one port (the port whose line was just written re-tests immediately, before
// any other fill, and hits). A group of 4 therefore completes in at most 4 fills
// regardless of how the corners alias. m_wport is gone.
//
// ================================= PREFILL PROBE =================================
// pf_* is a FIFTH read port that answers "is this line resident?" and is ALWAYS
// available - it is never gated by the demand ports' backpressure, and it keeps
// answering during fills and during the invalidate sweep, i.e. exactly when the four
// demand ports are frozen. It reads a PRIVATE tag copy (meta_pf, a simple-dual-port
// array with a dedicated read port), which is why it cannot be starved; that copy costs
// ~2 M10Ks and takes the same writes as the demand tag copies.
//   Probe is TAG ONLY - it reports residency, not data. That is all a prefill check
//   needs, and it is what keeps the port cheap: a probe port that returned line DATA
//   would need a third 256-bit array (~26 M10Ks) and would give back most of what the
//   2-copy conversion just saved.
//   pf_req at cycle N -> pf_ack at cycle N+1 with pf_hit. Answers are CONSERVATIVE: a
//   probe issued during the invalidate sweep reports "not resident" (which is what will
//   be true once the sweep lands) and a probe colliding with the in-flight fill write is
//   forwarded from that write rather than reading undefined read-during-write data.
//   pf_busy is informational: the fill machinery is occupied, so acting on a miss now
//   will queue behind the demand path.
//
// PROTOCOL per port i:
//   creq[i].req    : client wants to issue creq[i].waddr this cycle
//   cresp[i].ready : cache can accept it this cycle (LOW during a fill / reset sweep)
//   ACCEPTED       : creq[i].req && cresp[i].ready
//   cresp[i].ack   : a result is valid this cycle (combinational; the accepted request
//                    from last cycle, now hitting) - IN ISSUE ORDER
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

    // ---- prefill probe: 5th read port, tag-only, never backpressured ----
    input                pf_req,    // probe this cycle
    input        [28:0]  pf_waddr,  // 64-bit-word address (same form as creq[].waddr)
    output               pf_ack,    // 1 cycle later: pf_hit is valid
    output               pf_hit,    // line is resident (conservative: 0 while sweeping)
    output               pf_busy,   // informational: fill machinery occupied

    output ddr_rd_req_t  dreq,
    input  ddr_rd_resp_t dresp
);
    localparam integer NLINE = 1024;
    localparam integer IXW   = 10;
    localparam integer LAW   = 27;
    localparam integer TAGW  = LAW - IXW;           // 17
    localparam integer MW    = TAGW + 1;            // meta word = {vld, tag}

    integer i, k;

    localparam S_RST=0, S_RUN=1, S_MISS=2, S_FILL=3, S_RETEST=4;
    reg [2:0] st;
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

    // ============ READ address: accepted request, or the frozen index on a re-test ============
    reg  [IXW-1:0] rd_ix [0:3];
    reg  [IXW-1:0] retest_ix [0:3];
    reg            retesting;
    always @(*) begin
        for (int p=0; p<4; p=p+1)
            rd_ix[p] = retesting ? retest_ix[p] : in_ix[p];
    end
    wire rd_en = (st == S_RUN) || retesting;       // reads frozen while filling/sweeping

    // ============ WRITE side: fill commit + invalidate sweep ============
    // Both arrays take the SAME write (broadcast); the write address is the sweep counter
    // during S_RST and the missing line's index during a fill commit.
    reg [LAW-1:0]  m_line; reg [IXW-1:0] m_ix; reg [TAGW-1:0] m_tag;
    reg [1:0]      m_beat; reg [255:0] m_acc;
    wire [28:0] m_base = {m_line, 2'b00};

    wire            sweep_we = (st == S_RST);
    wire            fill_we  = (st == S_FILL) && dresp.dready && (m_beat == 2'd3);
    wire            meta_we  = sweep_we || fill_we;
    wire [IXW-1:0]  wa       = sweep_we ? rst_i[IXW-1:0] : m_ix;
    wire [MW-1:0]   wmeta    = sweep_we ? {1'b0, {TAGW{1'b0}}} : {1'b1, m_tag};
    wire [255:0]    wdata    = { dresp.dout, m_acc[191:0] };

    // ============ storage: 2 true-dual-port arrays serve the 4 demand ports ============
    // data_a/meta_a -> ports 0 (side A, also the write side) and 1 (side B)
    // data_b/meta_b -> ports 2 (side A, also the write side) and 3 (side B)
    wire [255:0] rdat0, rdat1, rdat2, rdat3;
    wire [MW-1:0] rmeta0, rmeta1, rmeta2, rmeta3;

    bram_tdp #(.W(256), .D(NLINE)) u_data_a (
        .clk(clk),
        .a_en(rd_en), .a_we(fill_we), .a_addr(fill_we ? wa : rd_ix[0]),
        .a_din(wdata), .a_q(rdat0),
        .b_en(rd_en), .b_addr(rd_ix[1]), .b_q(rdat1));
    bram_tdp #(.W(256), .D(NLINE)) u_data_b (
        .clk(clk),
        .a_en(rd_en), .a_we(fill_we), .a_addr(fill_we ? wa : rd_ix[2]),
        .a_din(wdata), .a_q(rdat2),
        .b_en(rd_en), .b_addr(rd_ix[3]), .b_q(rdat3));
    bram_tdp #(.W(MW), .D(NLINE)) u_meta_a (
        .clk(clk),
        .a_en(rd_en), .a_we(meta_we), .a_addr(meta_we ? wa : rd_ix[0]),
        .a_din(wmeta), .a_q(rmeta0),
        .b_en(rd_en), .b_addr(rd_ix[1]), .b_q(rmeta1));
    bram_tdp #(.W(MW), .D(NLINE)) u_meta_b (
        .clk(clk),
        .a_en(rd_en), .a_we(meta_we), .a_addr(meta_we ? wa : rd_ix[2]),
        .a_din(wmeta), .a_q(rmeta2),
        .b_en(rd_en), .b_addr(rd_ix[3]), .b_q(rmeta3));

    wire [255:0]  rdat [0:3];
    wire [MW-1:0] rmeta[0:3];
    assign rdat[0]=rdat0; assign rdat[1]=rdat1; assign rdat[2]=rdat2; assign rdat[3]=rdat3;
    assign rmeta[0]=rmeta0; assign rmeta[1]=rmeta1; assign rmeta[2]=rmeta2; assign rmeta[3]=rmeta3;

    // ============ REPLY register: the request whose data is arriving this cycle ============
    // treg[i] mirrors the request accepted (or re-presented) one cycle ago. The hit test
    // and ack happen THIS cycle, combinationally, aligned with the registered read.
    // t_done[i]/t_hold[i]: this port already got its word during an earlier round of the
    // group's fills and is now served from the hold register (see the livelock note).
    reg            t_v   [0:3];
    reg [LAW-1:0]  t_line[0:3];
    reg [TAGW-1:0] t_tag [0:3];
    reg [1:0]      t_wsel[0:3];
    reg            t_done[0:3];
    reg [63:0]     t_hold[0:3];
    wire        t_hit [0:3];
    wire        t_ok  [0:3];            // resident-or-already-captured
    wire [63:0] t_word[0:3];
    generate
      for (gi=0; gi<4; gi=gi+1) begin : th
        assign t_hit[gi]  = t_v[gi] && rmeta[gi][TAGW] && (rmeta[gi][TAGW-1:0]==t_tag[gi]);
        assign t_ok[gi]   = t_done[gi] || t_hit[gi];
        assign t_word[gi] = rdat[gi][64*t_wsel[gi] +: 64];
      end
    endgenerate

    // fm (declared below) selects the lowest missing port; fm[2]=1 == NO valid port missing.
    // (miss_now is forward-declared at the top of the module.)
    wire group_ready = (st == S_RUN) && !miss_now;          // ALL valid ports resident

    // ---- 1-CYCLE OUTPUTS, GROUP-ATOMIC: the 4 ports are the 4 corners of ONE bilinear
    //      sample, so they are served as a GROUP - a hitting port does NOT ack while any
    //      sibling is still missing/filling. Only when the WHOLE group is resident
    //      (group_ready) do all valid ports ack together, keeping the 4 corner fetchers in
    //      perfect lockstep downstream. ack + rdata are combinational off the registered
    //      read (1-cycle latency for an all-hit group); a port retired in an earlier round
    //      replays its captured word instead. ----
    generate
      for (gi=0; gi<4; gi=gi+1) begin : od
        assign cresp[gi].ack   = group_ready && t_v[gi];
        assign cresp[gi].rdata = t_done[gi] ? t_hold[gi] : t_word[gi];
      end
    endgenerate

    reg        rd_r;   reg [28:0] addr_r; reg [7:0] burst_r;
    assign dreq.rd    = rd_r;
    assign dreq.addr  = addr_r;
    assign dreq.burst = burst_r;

    // lowest-index REPLY-stage port that is still MISSING (not resident, not captured).
    // fm[2]=1 => none.
    wire [2:0] fm = (t_v[0] && !t_ok[0]) ? 3'd0 :
                    (t_v[1] && !t_ok[1]) ? 3'd1 :
                    (t_v[2] && !t_ok[2]) ? 3'd2 :
                    (t_v[3] && !t_ok[3]) ? 3'd3 : 3'b100;
    assign miss_now = !fm[2];

`ifndef SYNTHESIS
    integer stat_hit [0:4];
    integer stat_n;
`endif

    always @(posedge clk) begin
        if (reset) begin
            st <= S_RST; rd_r <= 0; rst_i <= 0; retesting <= 0;
            for (i=0;i<4;i=i+1) begin t_v[i]<=0; t_done[i]<=0; end
`ifndef SYNTHESIS
            for (i=0;i<5;i=i+1) stat_hit[i] <= 0;
            stat_n <= 0;
`endif
        end else if (flush) begin
            // render start: re-enter the valid-clear sweep (invalidate all lines). Safe
            // because the shade pipe is idle between renders (no fill in flight). Stats
            // (sim-only) are intentionally left cumulative across renders.
            st <= S_RST; rd_r <= 0; rst_i <= 0; retesting <= 0;
            for (i=0;i<4;i=i+1) begin t_v[i]<=0; t_done[i]<=0; end
        end else begin
            rd_r <= 1'b0;
            retesting <= 1'b0;

            case (st)
            // clear valid bits one entry/cycle after reset. The write itself is driven
            // combinationally off sweep_we/wa/wmeta into all three tag copies.
            S_RST: begin
                for (i=0;i<4;i=i+1) begin t_v[i] <= 1'b0; t_done[i] <= 1'b0; end
                if (rst_i == NLINE-1) st <= S_RUN;
                else rst_i <= rst_i + 1'b1;
            end

            // steady state: REPLY-test the request whose data is arriving this cycle (treg,
            // registered from the request accepted/re-presented last cycle). Hits ack
            // combinationally (above). Simultaneously accept a NEW request per port into
            // treg for next cycle's REPLY. On the first miss, freeze and go fill.
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
                if (!fm[2]) begin
                    // A miss in the group: latch the lowest missing line and go fill. FREEZE
                    // the WHOLE group's treg - including ports that HIT - because with
                    // group-atomic ack a hitting port has NOT been served yet; it must stay
                    // valid so all 4 ack TOGETHER once the last missing line is filled.
                    // CAPTURE every port that is resident right now into its hold register
                    // and retire it: once captured, the fill is free to evict its line, and
                    // that is exactly what makes an unconditional broadcast (and hence
                    // sibling ports sharing one array) safe. New requests are NOT accepted
                    // (ready=0 while !S_RUN). ----
                    m_line <= t_line[fm[1:0]];
                    m_ix   <= t_line[fm[1:0]][IXW-1:0];
                    m_tag  <= t_line[fm[1:0]][LAW-1:IXW];
                    m_beat <= 2'd0;
                    for (k=0;k<4;k=k+1) begin
                        retest_ix[k] <= t_line[k][IXW-1:0];    // keep ALL t_v (group waits)
                        if (t_v[k] && !t_done[k] && t_hit[k]) begin
                            t_hold[k] <= t_word[k];
                            t_done[k] <= 1'b1;
                        end
                    end
                    st <= S_MISS;
                end else begin
                    // no miss: the whole group acked this cycle. Accept a new request per
                    // port for next cycle's REPLY and clear the hold bookkeeping.
                    for (k=0;k<4;k=k+1) begin
                        t_v[k]    <= acc[k];
                        t_done[k] <= 1'b0;
                        t_line[k] <= in_line[k];
                        t_tag[k]  <= in_tag[k];
                        t_wsel[k] <= in_wsel[k];
                    end
                end
            end

            // burst-read the 4 words of the missing line.
            S_MISS: if (!dresp.busy) begin
                rd_r    <= 1'b1;
                addr_r  <= {4'b0011, m_base[24:0]};
                burst_r <= 8'd4;
                st      <= S_FILL;
            end
            S_FILL: if (dresp.dready) begin
                m_acc[64*m_beat +: 64] <= dresp.dout;
                if (m_beat == 2'd3) begin
                    // fill_we commits { dresp.dout, m_acc[191:0] } into BOTH arrays this
                    // same edge (broadcast; no per-copy veto - see the livelock note), then
                    // reload the frozen reads from the updated store and re-test next cyc.
                    retesting <= 1'b1;
                    st <= S_RETEST;
                end else m_beat <= m_beat + 2'd1;
            end
            // one cycle for the re-presented reads to land, then S_RUN re-tests treg. The
            // port whose line was just filled now hits (and is captured/acked); a port to a
            // different still-missing line misses again -> another fill. Every fill retires
            // at least that one port, so a group completes in at most 4 fills.
            S_RETEST: st <= S_RUN;
            default: st <= S_RUN;
            endcase
        end
    end

    // ==================== PREFILL PROBE: private tag copy + 1-cycle answer ====================
    // meta_pf takes the same writes as the demand tag copies but has its OWN read port, so
    // a probe is never blocked by the demand ports and stays live during fills and sweeps.
    wire [LAW-1:0]  pf_line = pf_waddr[28:2];
    wire [IXW-1:0]  pf_ix   = pf_line[IXW-1:0];
    wire [TAGW-1:0] pf_tag  = pf_line[LAW-1:IXW];
    wire [MW-1:0]   pf_q;

    bram_sdp #(.W(MW), .D(NLINE)) u_meta_pf (
        .clk(clk), .we(meta_we), .waddr(wa), .din(wmeta),
        .re(pf_req), .raddr(pf_ix), .q(pf_q));

    reg             pf_v_r, pf_sweep_r;
    reg [IXW-1:0]   pf_ix_r;
    reg [TAGW-1:0]  pf_tag_r;
    reg             pf_w_v;                 // a write landed on the same edge as the read
    reg [IXW-1:0]   pf_w_ix;
    reg [MW-1:0]    pf_w_meta;
    always @(posedge clk) begin
        if (reset) begin
            pf_v_r <= 1'b0; pf_w_v <= 1'b0; pf_sweep_r <= 1'b0;
        end else begin
            pf_v_r     <= pf_req;
            pf_ix_r    <= pf_ix;
            pf_tag_r   <= pf_tag;
            pf_sweep_r <= sweep_we;          // probe issued mid-sweep -> answer "not resident"
            pf_w_v     <= meta_we;
            pf_w_ix    <= wa;
            pf_w_meta  <= wmeta;
        end
    end
    // forward the colliding write: bram_sdp has no read-during-write bypass, so a probe of
    // the address being written returns undefined data. We know exactly what was written.
    wire            pf_fwd  = pf_w_v && (pf_w_ix == pf_ix_r);
    wire [MW-1:0]   pf_meta = pf_fwd ? pf_w_meta : pf_q;
    assign pf_ack  = pf_v_r;
    assign pf_hit  = pf_v_r && !pf_sweep_r && pf_meta[TAGW]
                            && (pf_meta[TAGW-1:0] == pf_tag_r);
    assign pf_busy = (st != S_RUN);

`ifndef SYNTHESIS
    // ---- LIVELOCK detector (kept as a regression net, should never fire) ----
    // The old 4-copy design could livelock: a group of 4 bilinear corners is served
    // ATOMICALLY, each fill resolved only the LOWEST missing port's line, and two frozen
    // ports wanting DIFFERENT lines that ALIAS to the same index evicted each other
    // forever. The t_done/t_hold capture removed the cause - a retired port no longer
    // needs its line resident, so every fill strictly shrinks the missing set. This
    // detector stays because the property is worth failing loudly on: count consecutive
    // fills WITHOUT a group_ready (a healthy fill is followed by group_ready within a
    // couple of retests; dozens back-to-back means the invariant broke).
    integer tc_fills; reg tc_reported;
    always @(posedge clk) begin
        if (reset) begin tc_fills <= 0; tc_reported <= 1'b0; end
        else begin
            if (group_ready)             tc_fills <= 0;             // group made progress
            else if (st==S_MISS && !dresp.busy) tc_fills <= tc_fills + 1;  // one more fill kicked
            if (tc_fills > 64 && !tc_reported) begin
                tc_reported <= 1'b1;
                $display("\n$$$$$$ TEX$ LIVELOCK %m (%0d fills, no group_ready) $$$$$$", tc_fills);
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
        $display("=== TEX$1c %m: %0d lookup-cycles: HIT4=%0d HIT3=%0d HIT2=%0d HIT1=%0d HIT0=%0d ===",
                 stat_n, stat_hit[4], stat_hit[3], stat_hit[2], stat_hit[1], stat_hit[0]);
    end
`endif
endmodule

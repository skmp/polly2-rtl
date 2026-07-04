//
// tex_cache_4p - 4-READ-PORT texture cache, 1024 lines x 32 BYTES (256-bit, =4x
// 64-bit words), direct-mapped, over the DDR3 raw 64-bit read port. Backs the 4
// bilinear corner fetchers.
//
// STREAMING (pipelined, multi-outstanding) VERSION: each port accepts a NEW request
// EVERY CYCLE on a hit stream (valid/ready handshake) and returns results IN ISSUE
// ORDER at a FIXED 2-cycle hit latency. The pipe only stalls (deasserts ready on all
// ports) while a MISS is being filled from DDR. This sustains 1 bilinear texel (4
// corners) / clock on cache hits.
//
// M10K-COMPATIBLE (registered read) WHILE KEEPING 4 PARALLEL READ PORTS: the line
// DATA is held in FOUR FULL COPIES (data0..data3), one per port, each a
// REGISTERED-read block RAM so Quartus maps it to M10K on Cyclone V. Fills write ALL
// FOUR copies + the shared tag/valid so the copies stay identical.
//
// PIPELINE (registered read), per port i:
//   LOOK  (cycle N):   the request ACCEPTED this cycle (creq[i].req && cready[i])
//                      drives its line index into copy i's read port (combinational
//                      addr -> registered rdata). The request fields are latched into
//                      the TEST register treg[i].
//   TEST  (cycle N+1): registered rdat/rmeta + treg decide HIT (-> cresp[i].ack +
//                      the requested 64-bit word) or MISS (-> freeze + fill).
// Because a new request may be accepted every cycle, results emerge one per cycle, two
// cycles after issue, IN ORDER. The client presents req only when cready is high.
//
// PROTOCOL per port i:
//   creq[i].req    : client wants to issue creq[i].waddr this cycle
//   cready[i]      : cache can accept it this cycle (LOW during a fill)
//   ACCEPTED       : creq[i].req && cready[i]
//   cresp[i].ack   : a result (in issue order) is valid this cycle
//   cresp[i].rdata : the 64-bit word
// Line addr = waddr[28:2]; word-in-line = waddr[1:0]. index=line[9:0], tag=line[26:10].
//
// MISS handling (in-order, no reorder buffer): on a TEST miss the cache freezes ALL
// ports (cready=0), fills the whole 32-byte line as ONE 4-beat DDR burst, then RE-TESTS
// the frozen TEST-stage request(s) against the now-resident line. Every frozen port
// whose line matches the just-filled line is served (dedup); a frozen port to a
// different line re-presents its read and re-tests next cycle. The 4 corner fetchers
// issue in lockstep, so freezing all 4 is the natural behaviour.
//
module tex_cache_4p import tsp_pkg::*; (
    input                clk,
    input                reset,
    input  cache_req_t   creq  [0:3],
    output cache_resp_t  cresp [0:3],      // .ready = per-port accept (backpressure)
    output ddr_rd_req_t  dreq,
    input  ddr_rd_resp_t dresp
);
    localparam integer NLINE = 1024;
    localparam integer IXW   = 10;                 // line index bits
    localparam integer LAW   = 27;                 // line-address width (waddr[28:2])
    localparam integer TAGW  = LAW - IXW;           // 17

    // FOUR full copies of the 256-bit (4-word) line store, one registered-read M10K
    // per read port. tag/valid are duplicated per port too so each port's hit test
    // is a local registered read (no shared async fan-out).
    (* ramstyle = "M10K, no_rw_check" *) reg [255:0] data0 [0:NLINE-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [255:0] data1 [0:NLINE-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [255:0] data2 [0:NLINE-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [255:0] data3 [0:NLINE-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [TAGW:0] meta0 [0:NLINE-1]; // {vld, tag}
    (* ramstyle = "M10K, no_rw_check" *) reg [TAGW:0] meta1 [0:NLINE-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [TAGW:0] meta2 [0:NLINE-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [TAGW:0] meta3 [0:NLINE-1];

    integer i, k;

    localparam S_RST=0, S_RUN=1, S_MISS=2, S_FILL=3, S_RETEST=4;
    reg [2:0] st;
    reg [IXW:0] rst_i;                        // reset sweep counter (clears meta[])

    // "cache can accept new requests this cycle" = running normally (S_RUN) AND the
    // TEST stage this cycle is NOT a miss. On a miss cycle we branch to fill and do
    // NOT latch the incoming request, so cready MUST be low that cycle or the client's
    // request (which it believes accepted) would be silently dropped. `miss_now` is
    // combinational from the registered reads (see fm below, declared later); forward-
    // declared here as a wire.
    wire miss_now;                                 // = !fm[2] (a TEST-stage miss)
    wire accept = (st == S_RUN) && !miss_now;
    // per-port accept: the client's req AND the cache accepting.
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

    // ============ LOOK: present each port's read address ============
    // The request ACCEPTED this cycle drives copy i's read port; its data lands next
    // cycle for the TEST stage. During a re-test after a fill we instead re-present the
    // frozen TEST-stage index (retest_ix) so the just-filled line is read back.
    reg  [IXW-1:0] rd_ix [0:3];
    reg  [IXW-1:0] retest_ix [0:3];
    reg            retesting;                 // 1 for the cycle after a fill commits
    always @(*) begin
        for (int p=0; p<4; p=p+1)
            rd_ix[p] = retesting ? retest_ix[p] : in_ix[p];
    end

    // registered reads (M10K), one per port. Frozen while filling so the read that was
    // presented before the miss survives the fill (re-presented via retest_ix instead).
    reg [255:0]  rdat [0:3];
    reg [TAGW:0] rmeta[0:3];
    wire         rd_en = (st == S_RUN) || retesting;
    always @(posedge clk) if (rd_en) begin
        rdat[0]  <= data0[rd_ix[0]];  rmeta[0] <= meta0[rd_ix[0]];
        rdat[1]  <= data1[rd_ix[1]];  rmeta[1] <= meta1[rd_ix[1]];
        rdat[2]  <= data2[rd_ix[2]];  rmeta[2] <= meta2[rd_ix[2]];
        rdat[3]  <= data3[rd_ix[3]];  rmeta[3] <= meta3[rd_ix[3]];
    end

    // ============ TEST register: the request whose data is arriving this cycle ============
    // treg[i] mirrors the request that was accepted (or re-presented) one cycle ago.
    reg            t_v   [0:3];
    reg [LAW-1:0]  t_line[0:3];
    reg [TAGW-1:0] t_tag [0:3];
    reg [1:0]      t_wsel[0:3];
    // per-port hit against the registered rmeta = {vld, tag}
    wire        t_hit [0:3];
    wire [63:0] t_word[0:3];
    generate
      for (gi=0; gi<4; gi=gi+1) begin : th
        assign t_hit[gi]  = t_v[gi] && rmeta[gi][TAGW] && (rmeta[gi][TAGW-1:0]==t_tag[gi]);
        assign t_word[gi] = rdat[gi][64*t_wsel[gi] +: 64];
      end
    endgenerate

    reg        ack_r  [0:3]; reg [63:0] rdata_r [0:3];
    reg        rd_r;   reg [28:0] addr_r; reg [7:0] burst_r;
    generate
      for (gi=0; gi<4; gi=gi+1) begin : od
        assign cresp[gi].ack   = ack_r[gi];
        assign cresp[gi].rdata = rdata_r[gi];
      end
    endgenerate
    assign dreq.rd    = rd_r;
    assign dreq.addr  = addr_r;
    assign dreq.burst = burst_r;

    // fill bookkeeping
    reg [LAW-1:0]  m_line; reg [IXW-1:0] m_ix; reg [TAGW-1:0] m_tag;
    reg [1:0]      m_beat; reg [255:0] m_acc;
    wire [28:0] m_base = {m_line, 2'b00};

    // lowest-index TEST-stage port that MISSED (needs a fill). fm[2]=1 => none
    wire [2:0] fm = (t_v[0] && !t_hit[0]) ? 3'd0 :
                    (t_v[1] && !t_hit[1]) ? 3'd1 :
                    (t_v[2] && !t_hit[2]) ? 3'd2 :
                    (t_v[3] && !t_hit[3]) ? 3'd3 : 3'b100;
    assign miss_now = !fm[2];                     // a TEST-stage miss this cycle

`ifndef SYNTHESIS
    // ---- TEX-stage hit-parallelism stats (see original module) ----
    integer stat_hit [0:4];
    integer stat_n;
`endif

    always @(posedge clk) begin
        if (reset) begin
            st <= S_RST; rd_r <= 0; rst_i <= 0; retesting <= 0;
            for (i=0;i<4;i=i+1) begin ack_r[i]<=0; t_v[i]<=0; end
`ifndef SYNTHESIS
            for (i=0;i<5;i=i+1) stat_hit[i] <= 0;
            stat_n <= 0;
`endif
        end else begin
            for (i=0;i<4;i=i+1) ack_r[i] <= 1'b0;
            rd_r <= 1'b0;
            retesting <= 1'b0;

            case (st)
            // clear valid bits one entry/cycle after reset (all 4 meta copies).
            S_RST: begin
                meta0[rst_i[IXW-1:0]][TAGW] <= 1'b0;
                meta1[rst_i[IXW-1:0]][TAGW] <= 1'b0;
                meta2[rst_i[IXW-1:0]][TAGW] <= 1'b0;
                meta3[rst_i[IXW-1:0]][TAGW] <= 1'b0;
                for (i=0;i<4;i=i+1) t_v[i] <= 1'b0;
                if (rst_i == NLINE-1) st <= S_RUN;
                else rst_i <= rst_i + 1'b1;
            end

            // steady state: TEST the request whose read is arriving this cycle (treg,
            // registered from the request accepted/re-presented last cycle), serve all
            // hits, and simultaneously accept a NEW request per port into treg for next
            // cycle's TEST. On the first miss, freeze and go fill.
            S_RUN: begin
                // TEST: serve every port that hit.
                for (i=0;i<4;i=i+1) if (t_hit[i]) begin
                    rdata_r[i] <= t_word[i]; ack_r[i] <= 1'b1;
                end
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
                    // A miss: latch the missed line and go fill. FREEZE: keep treg for
                    // ports that did NOT hit this cycle (so they re-test after the fill)
                    // but CLEAR t_v for ports that already hit + were acked above, so
                    // they are not served a second time on re-test. Do NOT accept new
                    // requests (cready=0 while !S_RUN).
                    m_line <= t_line[fm[1:0]];
                    m_ix   <= t_line[fm[1:0]][IXW-1:0];
                    m_tag  <= t_line[fm[1:0]][LAW-1:IXW];
                    m_beat <= 2'd0;
                    // remember each frozen port's index to re-present its read;
                    // drop ports that were already served (hit).
                    for (k=0;k<4;k=k+1) begin
                        retest_ix[k] <= t_line[k][IXW-1:0];
                        if (t_hit[k]) t_v[k] <= 1'b0;
                    end
                    st     <= S_MISS;
                end else begin
                    // no miss: accept a new request per port for next cycle's TEST.
                    // (rd_ix already presented these to the RAM this cycle.)
                    for (k=0;k<4;k=k+1) begin
                        t_v[k]    <= acc[k];
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
                    // commit the line into ALL FOUR copies + all four meta.
                    data0[m_ix] <= { dresp.dout, m_acc[191:0] };
                    data1[m_ix] <= { dresp.dout, m_acc[191:0] };
                    data2[m_ix] <= { dresp.dout, m_acc[191:0] };
                    data3[m_ix] <= { dresp.dout, m_acc[191:0] };
                    meta0[m_ix] <= {1'b1, m_tag};
                    meta1[m_ix] <= {1'b1, m_tag};
                    meta2[m_ix] <= {1'b1, m_tag};
                    meta3[m_ix] <= {1'b1, m_tag};
                    // Re-present the frozen TEST-stage reads (retest_ix) so the
                    // registered rdat/rmeta reload from the (now updated) line store,
                    // then RE-TEST them next cycle. retesting=1 drives rd_ix=retest_ix
                    // and keeps rd_en high for this reload.
                    retesting <= 1'b1;
                    st <= S_RETEST;
                end else m_beat <= m_beat + 2'd1;
            end
            // one cycle for the re-presented reads to land, then TEST them. Any frozen
            // port whose line == the just-filled line now hits; a port to a different
            // (still-missing) line will miss again and trigger another fill.
            S_RETEST: begin
                st <= S_RUN;    // next cycle runs TEST on the reloaded treg + reads
            end
            default: st <= S_RUN;
            endcase
        end
    end

`ifndef SYNTHESIS
    final begin
        $display("=== TEX$ %m: %0d lookup-cycles: HIT4=%0d HIT3=%0d HIT2=%0d HIT1=%0d HIT0=%0d ===",
                 stat_n, stat_hit[4], stat_hit[3], stat_hit[2], stat_hit[1], stat_hit[0]);
    end
`endif
endmodule

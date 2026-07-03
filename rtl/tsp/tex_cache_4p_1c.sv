//
// tex_cache_4p_1c - 4-READ-PORT texture cache, 1-CYCLE reply variant of tex_cache_4p.
// 1024 lines x 32 BYTES (256-bit = 4x 64-bit words), direct-mapped, over the DDR3 raw
// 64-bit read port. Backs the 4 bilinear corner fetchers.
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
// M10K: line DATA is held in FOUR full copies (data0..data3), one registered-read block
// RAM per port, so 4 parallel reads map to M10K on Cyclone V. Fills write all four copies
// + the shared-shape per-copy tag/valid so the copies stay identical.
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
    input  cache_req_t   creq  [0:3],
    output cache_resp_t  cresp [0:3],
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

    // registered M10K reads, one per port. Frozen while filling.
    reg [255:0]  rdat [0:3];
    reg [TAGW:0] rmeta[0:3];
    wire         rd_en = (st == S_RUN) || retesting;
    always @(posedge clk) if (rd_en) begin
        rdat[0]  <= data0[rd_ix[0]];  rmeta[0] <= meta0[rd_ix[0]];
        rdat[1]  <= data1[rd_ix[1]];  rmeta[1] <= meta1[rd_ix[1]];
        rdat[2]  <= data2[rd_ix[2]];  rmeta[2] <= meta2[rd_ix[2]];
        rdat[3]  <= data3[rd_ix[3]];  rmeta[3] <= meta3[rd_ix[3]];
    end

    // ============ REPLY register: the request whose data is arriving this cycle ============
    // treg[i] mirrors the request accepted (or re-presented) one cycle ago. The hit test
    // and ack happen THIS cycle, combinationally, aligned with the registered read.
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

    // fm (declared below) selects the lowest missing port; fm[2]=1 == NO valid port missing.
    // (miss_now is forward-declared at the top of the module.)
    wire group_ready = (st == S_RUN) && !miss_now;          // ALL valid ports resident

    // ---- 1-CYCLE OUTPUTS, GROUP-ATOMIC: the 4 ports are the 4 corners of ONE bilinear
    //      sample, so they are served as a GROUP - a hitting port does NOT ack while any
    //      sibling is still missing/filling. Only when the WHOLE group is resident
    //      (group_ready) do all valid ports ack together, keeping the 4 corner fetchers in
    //      perfect lockstep downstream. ack + rdata are combinational off the registered
    //      read (1-cycle latency for an all-hit group). ----
    generate
      for (gi=0; gi<4; gi=gi+1) begin : od
        assign cresp[gi].ack   = group_ready && t_v[gi];
        assign cresp[gi].rdata = t_word[gi];
      end
    endgenerate

    reg        rd_r;   reg [28:0] addr_r; reg [7:0] burst_r;
    assign dreq.rd    = rd_r;
    assign dreq.addr  = addr_r;
    assign dreq.burst = burst_r;

    // fill bookkeeping
    reg [LAW-1:0]  m_line; reg [IXW-1:0] m_ix; reg [TAGW-1:0] m_tag;
    reg [1:0]      m_beat; reg [255:0] m_acc;
    wire [28:0] m_base = {m_line, 2'b00};

    // lowest-index REPLY-stage port that MISSED. fm[2]=1 => none.
    wire [2:0] fm = (t_v[0] && !t_hit[0]) ? 3'd0 :
                    (t_v[1] && !t_hit[1]) ? 3'd1 :
                    (t_v[2] && !t_hit[2]) ? 3'd2 :
                    (t_v[3] && !t_hit[3]) ? 3'd3 : 3'b100;
    assign miss_now = !fm[2];

`ifndef SYNTHESIS
    integer stat_hit [0:4];
    integer stat_n;
`endif

    always @(posedge clk) begin
        if (reset) begin
            st <= S_RST; rd_r <= 0; rst_i <= 0; retesting <= 0;
            for (i=0;i<4;i=i+1) t_v[i]<=0;
`ifndef SYNTHESIS
            for (i=0;i<5;i=i+1) stat_hit[i] <= 0;
            stat_n <= 0;
`endif
        end else begin
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

            // steady state: REPLY-test the request whose read is arriving this cycle (treg,
            // registered from the request accepted/re-presented last cycle). Hits ack
            // combinationally (above). Simultaneously accept a NEW request per port into
            // treg for next cycle's REPLY. On the first miss, freeze and go fill.
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
                    // A miss in the group: latch the lowest missing line and go fill. FREEZE
                    // the WHOLE group's treg - including ports that HIT - because with
                    // group-atomic ack a hitting port has NOT been served yet; it must stay
                    // valid so all 4 ack TOGETHER once the last missing line is filled. Each
                    // frozen port re-presents its read (retest_ix) and re-tests after the
                    // fill; ports to still-missing lines trigger further fills. New requests
                    // are NOT accepted (ready=0 while !S_RUN). ----
                    m_line <= t_line[fm[1:0]];
                    m_ix   <= t_line[fm[1:0]][IXW-1:0];
                    m_tag  <= t_line[fm[1:0]][LAW-1:IXW];
                    m_beat <= 2'd0;
                    for (k=0;k<4;k=k+1)
                        retest_ix[k] <= t_line[k][IXW-1:0];    // keep ALL t_v (group waits)
                    st <= S_MISS;
                end else begin
                    // no miss: accept a new request per port for next cycle's REPLY.
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
                    data0[m_ix] <= { dresp.dout, m_acc[191:0] };
                    data1[m_ix] <= { dresp.dout, m_acc[191:0] };
                    data2[m_ix] <= { dresp.dout, m_acc[191:0] };
                    data3[m_ix] <= { dresp.dout, m_acc[191:0] };
                    meta0[m_ix] <= {1'b1, m_tag};
                    meta1[m_ix] <= {1'b1, m_tag};
                    meta2[m_ix] <= {1'b1, m_tag};
                    meta3[m_ix] <= {1'b1, m_tag};
                    // reload the frozen reads from the (now updated) store, re-test next cyc.
                    retesting <= 1'b1;
                    st <= S_RETEST;
                end else m_beat <= m_beat + 2'd1;
            end
            // one cycle for the re-presented reads to land, then S_RUN re-tests treg. A
            // frozen port whose line == the just-filled line now hits (and acks); a port to
            // a different still-missing line misses again -> another fill.
            S_RETEST: st <= S_RUN;
            default: st <= S_RUN;
            endcase
        end
    end

`ifndef SYNTHESIS
    final begin
        $display("=== TEX$1c %m: %0d lookup-cycles: HIT4=%0d HIT3=%0d HIT2=%0d HIT1=%0d HIT0=%0d ===",
                 stat_n, stat_hit[4], stat_hit[3], stat_hit[2], stat_hit[1], stat_hit[0]);
    end
`endif
endmodule

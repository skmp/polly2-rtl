//
// tex_cache_4p - 4-READ-PORT texture cache, 1024 lines x 32 BYTES (256-bit, =4x
// 64-bit words), direct-mapped, over the DDR3 raw 64-bit read port. Backs the 4
// bilinear corner fetchers, which can each present a lookup the SAME cycle and, on
// a hit, be served the SAME cycle -> sustains 1 bilinear texel (4 corners) / clock.
//
// M10K-COMPATIBLE (registered read) WHILE KEEPING 4 PARALLEL READ PORTS: the line
// DATA is held in FOUR FULL COPIES (data0..data3), one per port, each a
// REGISTERED-read block RAM so Quartus maps it to M10K on Cyclone V (M10K has no
// async read port; a simple-dual-port M10K gives 1 write + 1 read, so one copy per
// read port). Fills write ALL FOUR copies + the shared tag/valid so the copies
// stay identical.
//
// Lookups are pipelined by ONE cycle (registered read):
//   stage LOOK  (cycle N):   present each pending port's line index to its copy's
//                            read port (combinational addr -> registered rdata).
//   stage TEST  (cycle N+1): the registered rdata + the registered tag/valid decide
//                            per port: HIT -> ack + serve the requested 64-bit word;
//                            MISS -> queue the line for a burst fill.
// The 4 corner fetchers pulse req then POLL cresp.ack, so the extra pipeline cycle
// is transparent; parallel HITS still all ack in the same TEST cycle.
//
// A 32-byte line holds 4 consecutive 64-bit words. On a miss the whole line is
// fetched as ONE 4-beat DDR burst (paying DDR latency once and pulling in the 2x2
// bilinear neighbourhood), then the requested word is served.
//
// Client protocol per port i (unchanged): pulse creq[i].req with creq[i].waddr
// (64-bit-WORD addr) -> cresp[i].ack pulse + cresp[i].rdata (the 64-bit word).
// Line addr = waddr[28:2]; word-in-line = waddr[1:0]. index = line[9:0],
// tag = line[26:10].
//
// MISS handling (single DDR): parallel HITS serve together; MISSES are filled one
// distinct LINE at a time (one 4-beat burst each). Simultaneous misses to the SAME
// line DEDUPE - after a fill, every pending port whose line matches is acked from
// the just-filled line. The parent (tsp_shade_pp) stalls its pipe while any corner
// is busy.
//
module tex_cache_4p import tsp_pkg::*; (
    input                clk,
    input                reset,
    input  cache_req_t   creq  [0:3],
    output cache_resp_t  cresp [0:3],
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

    integer i;

    // ---- registered requests (one pending slot per port) ----
    reg            q_v   [0:3];
    reg [28:0]     q_addr[0:3];              // full 64-bit-word address
    wire [LAW-1:0]  q_line[0:3];             // 32-byte line address = waddr[28:2]
    wire [IXW-1:0]  q_ix  [0:3];
    wire [TAGW-1:0] q_tag [0:3];
    wire [1:0]      q_wsel[0:3];             // which 64-bit word within the line
    genvar gi;
    generate
      for (gi=0; gi<4; gi=gi+1) begin : qd
        assign q_line[gi] = q_addr[gi][28:2];
        assign q_ix[gi]   = q_line[gi][IXW-1:0];
        assign q_tag[gi]  = q_line[gi][LAW-1:IXW];
        assign q_wsel[gi] = q_addr[gi][1:0];
      end
    endgenerate

    // ============ LOOK stage: present each port's read address ============
    // rd_ix[i] is the line index port i reads THIS cycle (its registered rdata lands
    // next cycle). Default: the port's own pending line. The registered read fires
    // every cycle; the TEST stage (t_v gate) decides whether to consume it.
    reg  [IXW-1:0] rd_ix [0:3];
    always @(*) begin
        rd_ix[0] = q_ix[0];
        rd_ix[1] = q_ix[1];
        rd_ix[2] = q_ix[2];
        rd_ix[3] = q_ix[3];
    end

    // registered reads (M10K), one per port
    reg [255:0]  rdat [0:3];
    reg [TAGW:0] rmeta[0:3];
    always @(posedge clk) begin
        rdat[0]  <= data0[rd_ix[0]];  rmeta[0] <= meta0[rd_ix[0]];
        rdat[1]  <= data1[rd_ix[1]];  rmeta[1] <= meta1[rd_ix[1]];
        rdat[2]  <= data2[rd_ix[2]];  rmeta[2] <= meta2[rd_ix[2]];
        rdat[3]  <= data3[rd_ix[3]];  rmeta[3] <= meta3[rd_ix[3]];
    end

    // ============ TEST stage: latch what was presented at LOOK ============
    // t_* mirror the port slot fields registered one cycle ago so the registered
    // rdat/rmeta line up with the correct request. t_v[i] marks that port i had a
    // valid pending lookup in the previous (LOOK) cycle.
    reg            t_v   [0:3];
    reg [LAW-1:0]  t_line[0:3];
    reg [TAGW-1:0] t_tag [0:3];
    reg [1:0]      t_wsel[0:3];
    // per-port hit (registered rmeta = {vld, tag})
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

    localparam S_RST=0, S_RUN=1, S_MISS=2, S_FILL=3;
    reg [1:0] st;
    reg [IXW:0] rst_i;                        // reset sweep counter (clears meta[])

    // fill bookkeeping
    reg [LAW-1:0]  m_line; reg [IXW-1:0] m_ix; reg [TAGW-1:0] m_tag;
    reg [1:0]      m_beat; reg [255:0] m_acc;
    wire [28:0] m_base = {m_line, 2'b00};

    // lowest-index port that MISSED in the TEST stage (needs a fill). fm[2]=1 => none
    wire [2:0] fm = (t_v[0] && !t_hit[0]) ? 3'd0 :
                    (t_v[1] && !t_hit[1]) ? 3'd1 :
                    (t_v[2] && !t_hit[2]) ? 3'd2 :
                    (t_v[3] && !t_hit[3]) ? 3'd3 : 3'b100;

    integer k;

`ifndef SYNTHESIS
    // ---- TEX-stage hit-parallelism stats ----
    // Per TEST cycle that presents at least one active lookup, bin by how many of
    // the (up to 4) active ports hit the cache THAT cycle: hit4 = all four corners
    // resident, ... hit0 = every active port missed. Only counted while S_RUN is
    // actually consuming t_* (t_v gate below), so freeze/fill cycles don't inflate.
    integer stat_hit [0:4];               // stat_hit[n] = #cycles with n port-hits
    integer stat_n;                       // total binned (active-lookup) cycles
`endif

    always @(posedge clk) begin
        if (reset) begin
            st <= S_RST; rd_r <= 0; rst_i <= 0;
            for (i=0;i<4;i=i+1) begin ack_r[i]<=0; q_v[i]<=0; t_v[i]<=0; end
`ifndef SYNTHESIS
            for (i=0;i<5;i=i+1) stat_hit[i] <= 0;
            stat_n <= 0;
`endif
        end else begin
            for (i=0;i<4;i=i+1) ack_r[i] <= 1'b0;
            rd_r <= 1'b0;

            // accept new requests into any free port slot (safe during S_RST too)
            for (i=0;i<4;i=i+1)
                if (!q_v[i] && creq[i].req) begin q_v[i]<=1'b1; q_addr[i]<=creq[i].waddr; end

            case (st)
            // clear valid bits one entry/cycle after reset (all 4 meta copies).
            S_RST: begin
                meta0[rst_i[IXW-1:0]][TAGW] <= 1'b0;
                meta1[rst_i[IXW-1:0]][TAGW] <= 1'b0;
                meta2[rst_i[IXW-1:0]][TAGW] <= 1'b0;
                meta3[rst_i[IXW-1:0]][TAGW] <= 1'b0;
                if (rst_i == NLINE-1) st <= S_RUN;
                else rst_i <= rst_i + 1'b1;
            end

            // steady state: LOOK is presented combinationally every cycle from the
            // pending slots; here we run the TEST stage on the PREVIOUS cycle's
            // lookups (t_*), serving all hits in parallel and diverting to a fill on
            // the first miss. Then we re-arm t_* for the next TEST from the current
            // pending slots (that were presented to the RAM read THIS cycle).
            S_RUN: begin
                // TEST: serve every port that hit last cycle.
                for (i=0;i<4;i=i+1) if (t_hit[i]) begin
                    rdata_r[i] <= t_word[i]; ack_r[i] <= 1'b1; q_v[i] <= 1'b0;
                end
`ifndef SYNTHESIS
                // TEX stat: bin this TEST cycle by how many active ports hit. Only
                // count cycles that actually presented a lookup (>=1 t_v set).
                if (t_v[0] || t_v[1] || t_v[2] || t_v[3]) begin
                    stat_hit[(t_hit[0]?1:0)+(t_hit[1]?1:0)
                            +(t_hit[2]?1:0)+(t_hit[3]?1:0)]
                        <= stat_hit[(t_hit[0]?1:0)+(t_hit[1]?1:0)
                                   +(t_hit[2]?1:0)+(t_hit[3]?1:0)] + 1;
                    stat_n <= stat_n + 1;
                end
`endif
                if (!fm[2]) begin
                    // a miss: latch its line and go fill. Freeze the TEST pipeline
                    // (t_v cleared) so nothing re-tests against stale reads while the
                    // fill runs; lookups re-arm when we return to S_RUN.
                    m_line <= t_line[fm[1:0]];
                    m_ix   <= t_line[fm[1:0]][IXW-1:0];
                    m_tag  <= t_line[fm[1:0]][LAW-1:IXW];
                    m_beat <= 2'd0;
                    for (k=0;k<4;k=k+1) t_v[k] <= 1'b0;
                    st     <= S_MISS;
                end else begin
                    // no misses: advance the pipeline - the addresses presented this
                    // cycle (rd_ix = q_ix) become next cycle's TEST inputs.
                    for (k=0;k<4;k=k+1) begin
                        // a port that hit this cycle just cleared q_v -> won't re-test.
                        t_v[k]    <= q_v[k] && !t_hit[k];
                        t_line[k] <= q_line[k];
                        t_tag[k]  <= q_tag[k];
                        t_wsel[k] <= q_wsel[k];
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
                    // dedup-ack every pending port whose line matches the filled line.
                    for (i=0;i<4;i=i+1)
                        if (q_v[i] && q_line[i]==m_line) begin
                            rdata_r[i] <= (q_wsel[i]==2'd3) ? dresp.dout
                                        : m_acc[64*q_wsel[i] +: 64];
                            ack_r[i]   <= 1'b1; q_v[i] <= 1'b0;
                        end
                    st <= S_RUN;   // t_v all 0 -> re-arms cleanly next S_RUN cycle
                end else m_beat <= m_beat + 2'd1;
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

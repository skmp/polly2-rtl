//
// tex_fill_engine - the texel path's ONE memory port.
//
// Every texture read in the design goes through here: the data cache's demand misses,
// the scanner's speculative lines, and the VQ cache's codebook misses. Previously each
// of those was its own client of peel_core's arbiter (3 of its 7 ports, three
// request/response pairs running from the shader up to the top of the core). Collapsing
// them into one port keeps the texture memory logic LOCAL to the caches - the arbiter
// sees a single client, and the muxing that used to happen up there happens here, beside
// the arrays it serves.
//
// ============================ TWO QUEUES, ADDRESSES ONLY ============================
//   VQ  : VQ_Q  entries, VQ_OUT  outstanding - codebook lines, demand only
//   COL : COL_Q entries, COL_OUT outstanding - data lines, demand + speculative scan
// VQ_OUT + COL_OUT == the port's pipelined-request budget, so a VQ request can never be
// starved of a slot by speculative COL traffic. VQ also wins ISSUE arbitration: its fill
// is blocking a pixel in the shade pipe, while a scan line is by definition not needed
// yet.
//
// Depth is IN-FLIGHT TOTAL per queue: an entry is enqueued when a miss/scan finds it,
// marked issued when the port accepts its burst, and freed when its last beat lands.
// Three pointers per queue (wp enqueue / ip issue / rp complete) rather than a separate
// pending list, because enqueue order == issue order == completion order.
//
// ============================== NO PER-LINE BUFFERS ==============================
// The port returns the beats of every accepted burst strictly IN ISSUE ORDER, so bursts
// never interleave and only ONE line can complete on any cycle. That means a single
// 192-bit accumulator serves every outstanding line: the 4th beat presents
// {beat3, acc} straight at the owning cache, which writes it that same cycle by stealing
// a lookup cycle (see tex_cache_4p_1c: THE FILL STEAL). One owner FIFO bit per
// outstanding burst says which cache the beats belong to.
// This is the whole reason a 16-deep speculative scan is affordable: the previous design
// buffered a full 256-bit line per speculative slot, so 16 deep would have cost ~4096
// flops plus a 16:1 256-bit mux into the RAM write port.
//
// ================================== DEDUP ==================================
// A candidate line already in the COL queue is FOLDED onto that entry instead of fetching
// it twice. A demand fold sets the entry's dmd bit, so the cache still gets exactly one
// demand_done for its request - which is what lets the cache wait on a line the scanner
// had already started fetching, with no ride/hitchhike protocol. Only ONE candidate is
// compared per cycle (demand wins) so the CAM is 16 comparators, not 32.
//
// ================================== FLUSH ==================================
// On flush the caches invalidate everything, so lines in flight are worthless. The queues
// are cleared and the outstanding bursts are ORPHANED: their beats are counted and
// discarded with no write and no demand_done, and nothing new issues until they drain.
// That is what guarantees a fill never collides with the caches' invalidate sweep (which
// owns their write port outright), so fill_req needs no holding buffer.
//
module tex_fill_engine import tsp_pkg::*; #(
    parameter integer COL_Q   = 16,   // COL lines in flight (queued + outstanding)
    parameter integer COL_OUT = 12,   // ...of which at most this many bursts outstanding
    parameter integer COL_RSV = 4,    // COL entries the scanner may not take (kept for
                                      // demand, so a 4-line batch never waits on a slot)
    parameter integer VQ_Q    = 4,
    parameter integer VQ_OUT  = 4
) (
    input                clk,
    input                reset,
    input                flush,

    // ---- COL channel: demand from the data cache, plus the speculative scanner ----
    input                col_miss_v,
    input      [26:0]    col_miss_line,
    output               col_miss_ack,
    input                scan_v,
    input      [26:0]    scan_line,
    output               scan_ack,
    output               col_fill_req,
    output     [26:0]    col_fill_line,
    output     [255:0]   col_fill_data,
    input                col_fill_gnt,
    output               col_demand_done,

    // ---- VQ channel: demand only (codebook addresses depend on fetched data) ----
    input                vq_miss_v,
    input      [26:0]    vq_miss_line,
    output               vq_miss_ack,
    output               vq_fill_req,
    output     [26:0]    vq_fill_line,
    output     [255:0]   vq_fill_data,
    input                vq_fill_gnt,
    output               vq_demand_done,

    // ---- the ONE DDR read port for the whole texel path ----
    output ddr_rd_req_t  dreq,
    input  ddr_rd_resp_t dresp
);
    localparam integer LAW    = 27;
    localparam integer CQW    = $clog2(COL_Q);
    localparam integer VQW    = $clog2(VQ_Q);
    localparam integer OFD    = COL_OUT + VQ_OUT;      // max total outstanding
    localparam integer OFW    = $clog2(OFD);
    localparam         OWN_COL = 1'b0, OWN_VQ = 1'b1;

    integer ci, vi;

    // ================================ COL queue ================================
    reg [LAW-1:0]  cq_line [0:COL_Q-1];
    reg            cq_dmd  [0:COL_Q-1];
    reg [COL_Q-1:0] cq_v;                          // occupancy, for the dedup CAM
    reg [CQW:0]    cq_wp, cq_ip, cq_rp;
    wire [CQW:0]   cq_occ = cq_wp - cq_rp;         // queued + outstanding
    wire [CQW:0]   cq_out = cq_ip - cq_rp;         // bursts outstanding
    wire           cq_full = (cq_occ == (CQW+1)'(COL_Q));
    wire [CQW-1:0] cq_h    = cq_rp[CQW-1:0];       // completing entry
    wire [CQW-1:0] cq_i    = cq_ip[CQW-1:0];       // next to issue

    function automatic [CQW-1:0] cq_first_set(input [COL_Q-1:0] m);
        cq_first_set = '0;
        for (int q = COL_Q-1; q >= 0; q = q - 1) if (m[q]) cq_first_set = CQW'(q);
    endfunction

    // ================================ VQ queue ================================
    reg [LAW-1:0]  vq_line_q [0:VQ_Q-1];
    reg [VQW:0]    vq_wp, vq_ip, vq_rp;
    wire [VQW:0]   vq_occ = vq_wp - vq_rp;
    wire [VQW:0]   vq_out_n = vq_ip - vq_rp;
    wire           vq_full = (vq_occ == (VQW+1)'(VQ_Q));
    wire [VQW-1:0] vq_h    = vq_rp[VQW-1:0];
    wire [VQW-1:0] vq_i    = vq_ip[VQW-1:0];

    // ============================ orphan drain on flush ============================
    reg  orphaning;

    // ================================ enqueue (COL) ================================
    // Demand wins: it is blocking a pixel, and it is the only one that must never be
    // dropped. Exactly one candidate is compared against the queue per cycle.
    wire            cand_dmd  = col_miss_v;
    wire [LAW-1:0]  cand_line = col_miss_v ? col_miss_line : scan_line;
    wire            cand_v    = (col_miss_v || scan_v) && !orphaning;
    // dedup CAM: is this line already in the queue?
    wire [COL_Q-1:0] cq_match;
    genvar g;
    generate
      for (g=0; g<COL_Q; g=g+1) begin : cqm
        // EXCLUDE the entry completing on this very edge. Folding a demand onto it would
        // set its dmd bit at the same edge its col_demand_done is computed from the OLD
        // bit - the ack is given, the entry pops, and the done never comes: the cache
        // waits in S_WAIT forever. Excluded, the demand pushes its own entry instead
        // (one redundant refetch of a line being written right now, but correct).
        assign cq_match[g] = cq_v[g] && (cq_line[g] == cand_line)
                             && !(d_last && !own_vq && (CQW'(g) == cq_h));
      end
    endgenerate
    wire            cq_hit    = |cq_match;
    wire [CQW-1:0]  cq_hit_ix = cq_first_set(cq_match);
    // the scanner is held out of the last COL_RSV entries so a demand batch (<=4 lines)
    // never has to wait for a slot
    wire            cq_room   = cand_dmd ? !cq_full
                                         : (cq_occ <= (CQW+1)'(COL_Q - COL_RSV - 1));
    wire            cq_push   = cand_v && !cq_hit && cq_room;
    wire            cq_fold   = cand_v && cq_hit;
    assign col_miss_ack = col_miss_v && !orphaning && (cq_hit || cq_room);
    assign scan_ack     = scan_v && !col_miss_v && !orphaning && (cq_hit || cq_room);

    // ================================ enqueue (VQ) ================================
    // No scanner and no dedup: a codebook line's address comes from a just-fetched texel
    // word, so two corners of one quad wanting the same line is already deduped by the
    // VQ cache's own request-time iss_mask.
    wire vq_push = vq_miss_v && !vq_full && !orphaning;
    assign vq_miss_ack = vq_push;

    // ============================== owner FIFO ==============================
    // one bit per accepted burst: whose beats are these. Beats return in issue order, so
    // the head of this FIFO names the queue whose head is completing.
    reg            of_own [0:OFD-1];
    reg [OFW:0]    of_wp, of_rp;
    wire           of_empty = (of_wp == of_rp);
    wire [OFW:0]   of_occ   = of_wp - of_rp;
    wire           of_full  = (of_occ == (OFW+1)'(OFD));
    wire [OFW-1:0] of_h     = of_rp[OFW-1:0];
    wire           own_vq   = of_own[of_h];

    // ================================== issue ==================================
    // VQ first, always. !rd_r is REQUIRED: the arbiter's per-client pending slot holds
    // ONE address and registers our pulse on the edge ENDING the cycle we present it, so
    // during that cycle its busy still reads low - re-pulsing before the grant silently
    // overwrites an ungranted address and loses the burst.
    reg            rd_r; reg [28:0] addr_r;
    assign dreq.rd    = rd_r;
    assign dreq.addr  = addr_r;
    assign dreq.burst = 8'd4;
    wire vq_can  = (vq_ip != vq_wp) && (vq_out_n < (VQW+1)'(VQ_OUT));
    wire col_can = (cq_ip != cq_wp) && (cq_out   < (CQW+1)'(COL_OUT));
    wire iss_ok  = !orphaning && !rd_r && !dresp.busy && !of_full;
    wire iss_vq  = iss_ok && vq_can;
    wire iss_col = iss_ok && !vq_can && col_can;
    wire [LAW-1:0] iss_line = iss_vq ? vq_line_q[vq_i] : cq_line[cq_i];
    wire [28:0]    iss_base = {iss_line, 2'b00};

    // ============================== beat receiver ==============================
    reg [1:0]   beat;
    reg [191:0] acc;                                   // beats 0..2 of the current burst
    wire        d_beat = dresp.dready && !of_empty;
    wire        d_last = d_beat && (beat == 2'd3);
    wire [255:0] line_data = {dresp.dout, acc};        // completed line

    // present the completed line at its owner; the cache grants the same cycle by
    // stealing a lookup cycle. Suppressed while orphaning (data is worthless).
    wire done_col = d_last && !own_vq && !orphaning;
    wire done_vq  = d_last &&  own_vq && !orphaning;
    assign col_fill_req  = done_col;
    assign col_fill_line = cq_line[cq_h];
    assign col_fill_data = line_data;
    assign vq_fill_req   = done_vq;
    assign vq_fill_line  = vq_line_q[vq_h];
    assign vq_fill_data  = line_data;
    // one demand_done per completed line the cache asked for
    assign col_demand_done = done_col && cq_dmd[cq_h];
    assign vq_demand_done  = done_vq;                  // every VQ line is demand

    always @(posedge clk) begin
        if (reset) begin
            cq_wp <= '0; cq_ip <= '0; cq_rp <= '0; cq_v <= '0;
            vq_wp <= '0; vq_ip <= '0; vq_rp <= '0;
            of_wp <= '0; of_rp <= '0;
            beat  <= 2'd0; rd_r <= 1'b0; orphaning <= 1'b0;
        end else if (flush) begin
            // drop everything queued; let the accepted bursts drain as orphans so the
            // caches' invalidate sweep owns their write ports uncontested
            cq_wp <= '0; cq_ip <= '0; cq_rp <= '0; cq_v <= '0;
            vq_wp <= '0; vq_ip <= '0; vq_rp <= '0;
            rd_r  <= 1'b0;
            orphaning <= !of_empty;
        end else begin
            rd_r <= 1'b0;

            // ---- COL enqueue / fold ----
            if (cq_push) begin
                cq_line[cq_wp[CQW-1:0]] <= cand_line;
                cq_dmd [cq_wp[CQW-1:0]] <= cand_dmd;
                cq_v   [cq_wp[CQW-1:0]] <= 1'b1;
                cq_wp <= cq_wp + 1'b1;
            end else if (cq_fold && cand_dmd) begin
`ifndef SYNTHESIS
                // a second LIVE demand for one line would collapse two demand_done's into
                // one and hang the cache's batch. The cache's own iss_mask dedups its
                // corners, and a batch never outlives its demand_done, so this is
                // impossible - assert it rather than trust it.
                if (cq_dmd[cq_hit_ix])
                    $error("tex_fill_engine %m: second live demand fold on line %07x", cand_line);
`endif
                cq_dmd[cq_hit_ix] <= 1'b1;
            end

            // ---- VQ enqueue ----
            if (vq_push) begin
                vq_line_q[vq_wp[VQW-1:0]] <= vq_miss_line;
                vq_wp <= vq_wp + 1'b1;
            end

            // ---- issue one burst ----
            if (iss_vq || iss_col) begin
                rd_r   <= 1'b1;
                // {4'b0011, word[24:0]} - the DDR window prefix the geometry clients and
                // the old DEMAND path both use. NOTE the old PREFETCH client wrote
                // `{4'b0011, {line,2'b00} & 29'h1FFFFFF}`, which is 33 bits truncated into
                // a 29-bit reg: the prefix was silently DROPPED, so speculative bursts
                // addressed a different DDR region than demand bursts for the same line.
                // Invisible in sim (sim_ddr_fb only decodes addr[19:0]) and wrong on
                // hardware. Keep the widths adding to 29.
                addr_r <= {4'b0011, iss_base[24:0]};
                of_own[of_wp[OFW-1:0]] <= iss_vq ? OWN_VQ : OWN_COL;
                of_wp  <= of_wp + 1'b1;
                if (iss_vq) vq_ip <= vq_ip + 1'b1;
                else        cq_ip <= cq_ip + 1'b1;
            end

            // ---- beats ----
            if (d_beat) begin
                if (beat == 2'd3) begin
                    beat  <= 2'd0;
                    of_rp <= of_rp + 1'b1;
                    // An ORPHANED burst only drains the owner FIFO: flush already reset
                    // both queues, so advancing their pointers here would run rp past ip
                    // and underflow the outstanding count (cq_out reads 31, tripping the
                    // cap assertion and wedging issue).
                    if (!orphaning) begin
                        if (own_vq) vq_rp <= vq_rp + 1'b1;
                        else begin
                            cq_v[cq_h] <= 1'b0;
                            cq_rp      <= cq_rp + 1'b1;
                        end
                    end
                    if (orphaning && (of_occ == (OFW+1)'(1))) orphaning <= 1'b0;
                end else begin
                    acc[64*beat +: 64] <= dresp.dout;
                    beat <= beat + 2'd1;
                end
            end
`ifndef SYNTHESIS
            if (done_col && !col_fill_gnt)
                $error("tex_fill_engine %m: COL fill refused (line %07x lost)", cq_line[cq_h]);
            if (done_vq && !vq_fill_gnt)
                $error("tex_fill_engine %m: VQ fill refused (line %07x lost)", vq_line_q[vq_h]);
            if (dresp.dready && of_empty)
                $error("tex_fill_engine %m: beat with no burst outstanding");
            if (cq_out > (CQW+1)'(COL_OUT))
                $error("tex_fill_engine %m: COL outstanding %0d > %0d", cq_out, COL_OUT);
            if (vq_out_n > (VQW+1)'(VQ_OUT))
                $error("tex_fill_engine %m: VQ outstanding %0d > %0d", vq_out_n, VQ_OUT);
            if (cq_occ > (CQW+1)'(COL_Q))
                $error("tex_fill_engine %m: COL queue overflow");
`endif
        end
    end

`ifndef SYNTHESIS
    // ---- stats + occlog event hooks (peel_core samples these hierarchically) ----
    integer st_col = 0, st_col_dmd = 0, st_col_fold = 0, st_scan = 0, st_vq = 0;
    integer st_hw_col = 0, st_hw_vq = 0, st_hw_of = 0;
    always @(posedge clk) if (!reset) begin
        if (cq_push &&  cand_dmd) st_col_dmd  <= st_col_dmd + 1;
        if (cq_push && !cand_dmd) st_scan     <= st_scan + 1;
        if (cq_fold)              st_col_fold <= st_col_fold + 1;
        if (iss_col)              st_col      <= st_col + 1;
        if (iss_vq)               st_vq       <= st_vq + 1;
        if (st_hw_col < int'({{(32-CQW-1){1'b0}}, cq_occ}))   st_hw_col <= int'({{(32-CQW-1){1'b0}}, cq_occ});
        if (st_hw_vq  < int'({{(32-VQW-1){1'b0}}, vq_occ}))   st_hw_vq  <= int'({{(32-VQW-1){1'b0}}, vq_occ});
        if (st_hw_of  < int'({{(32-OFW-1){1'b0}}, of_occ}))   st_hw_of  <= int'({{(32-OFW-1){1'b0}}, of_occ});
    end
    // levels/pulses for the occlog interval tracks
    wire ev_col_busy = (cq_occ != '0);
    wire ev_vq_busy  = (vq_occ != '0);
    final begin
        $display("=== TEXFILL %m: bursts COL=%0d VQ=%0d | COL enq: demand=%0d scan=%0d folded=%0d ===",
                 st_col, st_vq, st_col_dmd, st_scan, st_col_fold);
        $display("=== TEXFILL %m: high-water COL=%0d/%0d VQ=%0d/%0d outstanding=%0d/%0d ===",
                 st_hw_col, COL_Q, st_hw_vq, VQ_Q, st_hw_of, OFD);
    end
`endif
endmodule

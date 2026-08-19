// sim_ddr_fb - shared SIM backend for the render cores (peel_core / isp_core).
//
// Bundles the behavioral 8 MB VRAM + faux single-channel DDR READ controller and
// the behavioral 640x480 framebuffer + faux framebuffer WRITE, exposing the
// injected core ports (ddr_req/ddr_resp, fbw_req/fbw_resp). A sim top instantiates
// ONE render core and ONE sim_ddr_fb and wires the two bundles together.
//
// The faux DDR controller is PIPELINED (multi-outstanding): it queues up to CQ
// accepted commands (busy = queue full), each command's RD_LAT dead-time counts
// down WHILE earlier bursts stream (as a real controller overlaps the next row
// activate with the current data), and beats return strictly in issue order,
// one/cycle from incrementing 64-bit-word addresses (addr[19:0]). The core's
// arbiter routes returned beats by its own issue-order FIFO. The framebuffer
// write is never busy: it accepts a pixel every cycle it is presented.
//
// The C++ TB reaches the memories at <top>__DOT__u_sim__DOT__{vram,fb}.
//
module sim_ddr_fb import tsp_pkg::*; #(
    parameter integer RD_LAT = 8
) (
    input                clk,
    input                reset,
    // injected into the render core:
    input  ddr_rd_req_t  ddr_req,     // core -> DDR read request
    output ddr_rd_resp_t ddr_resp,    // DDR read response -> core
    input  fb_wr_req_t   fbw_req,     // core -> framebuffer pixel write
    output fb_wr_resp_t  fbw_resp     // framebuffer backpressure -> core
);
    // -------------------- 8 MB behavioral VRAM (1M x 64-bit) --------------------
    (* verilator public_flat_rw *) reg [63:0] vram [0:1048575];
    // -------------------- 640x480 behavioral framebuffer --------------------
    (* verilator public_flat_rw *) reg [31:0] fb [0:640*480-1];

    // ==================== FAUX DDR READ CONTROLLER ====================
    // +ddrvary : inject ADDRESS-DEPENDENT variable read latency (deterministic - no RNG).
    // The real DDR3 controller's per-fill latency varies (row/bank/refresh/arbiter), which
    // this fixed-RD_LAT model never reproduces. With +ddrvary each read waits
    // RD_LAT + addr[3:0] dead cycles (8..23), so back-to-back reads - the 4 bilinear corners
    // and the interleaved data/VQ-codebook reads - resolve STAGGERED, exposing any payload/
    // texel alignment that silently relies on the constant sim latency (candidate cause of
    // the on-HW black-transparency: the at_en/TSP payload slipping vs the texel).
    reg ddrvary;
    initial ddrvary = $test$plusargs("ddrvary");
    // +ddrlat=N : override the BASE read latency at runtime (default RD_LAT).
    // The fixed RD_LAT=8 is far below the real DE10 f2h SDRAM path (~30-50
    // fabric cycles + arbitration) - measured on HW, features that win at
    // lat=8 can INVERT at real latency. Composes with +ddrvary.
    reg [7:0] rd_lat_r;
    initial begin
        int v;
        rd_lat_r = RD_LAT[7:0];
        if ($value$plusargs("ddrlat=%d", v)) rd_lat_r = v[7:0];
    end
    // +ddrserial : count latency down for the HEAD command only - the fully
    // SERIALIZED controller (no activate overlap). The default concurrent
    // countdown models perfect command pipelining, which real row/bank
    // conflicts do not deliver; the truth is between the two. Under serial,
    // BURSTY traffic (many small reads arriving together) pays latency per
    // command instead of once - the shape-sensitivity real HW shows.
    reg ddrserial;
    initial ddrserial = $test$plusargs("ddrserial");
    // +ddrgap=N : N dead cycles between BURSTS (row activate/precharge,
    // bus turnaround, write/scanout contention). This is the per-command
    // OVERHEAD term the latency knob cannot express: scattered small bursts
    // (texture fills, VQ codebooks, record reads) pay it once each, so
    // effective bandwidth collapses the way real f2h traffic does.
    reg [7:0] ddrgap;
    initial begin
        int g;
        ddrgap = 8'd0;
        if ($value$plusargs("ddrgap=%d", g)) ddrgap = g[7:0];
    end
    reg [7:0] gap_cnt = 8'd0;
    // command queue: up to CQ accepted bursts; per-slot latency counts down for ALL
    // queued commands each cycle (overlap), beats stream from the head in order.
    // CQ is the BACKEND's pending-read window - the thing that actually decides how much
    // memory-level parallelism the core can get, since ddr_resp.busy = q_full is what
    // gates acceptance. It was 4, which silently capped the whole channel below what the
    // arbiter and the texel cache's fill queues can now use (4 demand + 4 prefetch + one
    // per geometry client). On Avalon-MM this window is the SLAVE's
    // maximumPendingReadTransactions; the HPS f2h SDRAM port's real value lives in the
    // generated Qsys component. 16 here is "not the limiter" for the same reason DDR_OUT
    // is 16 in peel_core.
    localparam integer CQ  = 16;
    localparam integer CQW = $clog2(CQ);
    reg [19:0]  q_word [0:CQ-1];
    reg [7:0]   q_beats[0:CQ-1];
    reg [7:0]   q_lat  [0:CQ-1];
    reg [CQW:0] q_wp, q_rp;
    wire        q_empty = (q_wp == q_rp);
    wire        q_full  = (q_wp[CQW] != q_rp[CQW]) && (q_wp[CQW-1:0] == q_rp[CQW-1:0]);
    wire [CQW-1:0] q_h  = q_rp[CQW-1:0];
    reg [63:0] d_do; reg d_dv;
    integer qi;
    assign ddr_resp.busy   = q_full;
    assign ddr_resp.dout   = d_do;
    assign ddr_resp.dready = d_dv;
    // GUARD: mirror the DE10 read adapter's burst constraints (simplex_pvr_top
    // RD_MAX_BEATS = 128 = Avalon 8-bit-burstcount legal max; worst legal client
    // burst is the iterator record read, 3 hdr + 8 verts x 11 words = 91). This
    // model would happily accept burst 0/255 that wedge or violate the bus on
    // hardware (rez_ingame: a 71-beat burst vs the old 64-beat budget deadlocked
    // the DE10 while sim rendered fine). $fatal, not $error: this model ACCEPTS
    // the illegal burst and still renders correctly, so a continuing sim would
    // pass golden-check's md5 and hide the violation - kill the run so it shows
    // up as a RENDER FAIL instead.
    always @(posedge clk) if (!reset && ddr_req.rd && !q_full) begin
        if (ddr_req.burst == 8'd0 || ddr_req.burst > 8'd128)
            $fatal(1, "sim_ddr_fb: illegal burst %0d (addr=%07x) - HW adapter allows 1..128",
                   ddr_req.burst, ddr_req.addr);
    end

    always @(posedge clk) begin
        d_dv <= 1'b0;
        if (reset) begin q_wp <= '0; q_rp <= '0; end
        else begin
            if (ddr_req.rd && !q_full) begin
                q_word [q_wp[CQW-1:0]] <= ddr_req.addr[19:0];
                q_beats[q_wp[CQW-1:0]] <= ddr_req.burst;
                q_lat  [q_wp[CQW-1:0]] <= rd_lat_r + (ddrvary ? {4'd0, ddr_req.addr[3:0]} : 8'd0);
                q_wp <= q_wp + 1'b1;
            end
            for (qi = 0; qi < CQ; qi = qi + 1)
                if (q_lat[qi] != 8'd0
                    && !(ddrserial && qi != int'({{(32-CQW){1'b0}}, q_h}))
                    // gap is bus DEAD time: in serial mode it must delay the next
                    // access's start, not overlap its latency countdown (otherwise
                    // any gap <= lat is invisible and the calibration curve is flat)
                    && !(ddrserial && gap_cnt != 8'd0)
                    && !(ddr_req.rd && !q_full && qi == int'({{(32-CQW){1'b0}}, q_wp[CQW-1:0]})))
                    q_lat[qi] <= q_lat[qi] - 8'd1;
            if (gap_cnt != 8'd0) gap_cnt <= gap_cnt - 8'd1;
            else if (!q_empty && q_lat[q_h] == 8'd0) begin
                d_do <= vram[q_word[q_h]]; d_dv <= 1'b1;
                q_word[q_h]  <= q_word[q_h] + 20'd1;
                q_beats[q_h] <= q_beats[q_h] - 8'd1;
                if (q_beats[q_h] <= 8'd1) begin
                    q_rp <= q_rp + 1'b1;
                    gap_cnt <= ddrgap;   // inter-burst overhead
                end
            end
        end
    end

    // ==================== FAUX FRAMEBUFFER WRITE ====================
    // Behavioral fb[] is linear 640-wide (the shape the BMP writers expect);
    // rebuild the index from the screen coordinate.
    assign fbw_resp.busy = 1'b0;
    wire [19:0] fb_idx = {10'd0, fbw_req.py} * 20'd640 + {9'd0, fbw_req.px};
    always @(posedge clk) begin
        if (fbw_req.we) fb[fb_idx] <= fbw_req.argb;
    end
endmodule

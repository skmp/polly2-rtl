//
// mister_top - synthesizable MiSTer top for the layer-peeling render core.
//
// Wires peel_core to the real HPS DDR3 via the sysmem_lite f2sdram bridge
// (rtl/mister/), NOT through FPGA pins - DDR3 lives on the HPS. The bridge gives
// the 100 MHz core clock + reset and three Avalon RAM ports:
//   * ram1 : peel_core's DDR READS (region/objlist/param/texture) - one 64-bit
//            burst read in flight, driven by the injected ddr_req/ddr_resp.
//   * ram2 : peel_core's framebuffer WRITES (shaded pixels packed 2/word).
//   * vbuf : unused.
//
// The HPS ARM side is expected to preload VRAM into DDR and write the PVR
// registers (wr_en/wr_addr/wr_data), then pulse `go`; `done` marks completion.
// The framebuffer is written to DDR at FB_BASE (64-bit words, 2 ARGB px/word) for
// the HPS/scanout to read.
//
module peel_core_top import tsp_pkg::*; #(
    // DDR byte base of the 640x480 ARGB framebuffer (64-bit words, 2 px/word).
    parameter [28:0] FB_BASE_WORD = 29'h0080000   // 64-bit-word address
) (
    // ---- HPS reset control (no DDR3 pins: DDR3 is on the HPS) ----
    input             reset_req,    // async: request a core reset
    input             cold_req,     // HPS cold-reset button (tie 0 if unused)
    output            core_clk,     // 100 MHz core clock (from HPS bridge)
    output            core_reset,   // active-high synchronous core reset

    // ---- register/command load + run (driven by the HPS) ----
    input             wr_en,        // 1: write PVR reg wr_addr <= wr_data
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    input             go,           // 1-cycle: start rendering the region array
    output            done          // 1-cycle: region array fully processed
);
    // ------------------------------------------------------------------
    // HPS DDR3 bridge (sysmem_lite): core clock/reset + Avalon RAM ports.
    // ------------------------------------------------------------------
    wire clk_100m, reset_100m;
    assign core_clk   = clk_100m;
    assign core_reset = reset_100m;

    // ram1 : DDR read channel (Avalon)
    wire        r1_clk = clk_100m;
    wire [28:0] r1_addr;
    wire  [7:0] r1_burstcnt;
    wire        r1_waitrequest;
    wire [63:0] r1_readdata;
    wire        r1_readdatavalid;
    wire        r1_read;
    // ram2 : DDR framebuffer write channel (Avalon)
    wire        r2_clk = clk_100m;
    wire [28:0] r2_addr;
    wire  [7:0] r2_burstcnt;
    wire        r2_waitrequest;
    wire        r2_write;
    wire [63:0] r2_writedata;
    wire  [7:0] r2_byteenable;

    sysmem_lite u_sysmem (
        .reset_core_req    (reset_req),
        .reset_out         (reset_100m),
        .clock             (clk_100m),
        .reset_hps_cold_req(cold_req),
        .reset_hps_warm_req(1'b0),

        // ram1 : reads
        .ram1_clk          (r1_clk),
        .ram1_address      (r1_addr),
        .ram1_burstcount   (r1_burstcnt),
        .ram1_waitrequest  (r1_waitrequest),
        .ram1_readdata     (r1_readdata),
        .ram1_readdatavalid(r1_readdatavalid),
        .ram1_read         (r1_read),
        .ram1_writedata    (64'd0),
        .ram1_byteenable   (8'hFF),
        .ram1_write        (1'b0),

        // ram2 : framebuffer writes
        .ram2_clk          (r2_clk),
        .ram2_address      (r2_addr),
        .ram2_burstcount   (r2_burstcnt),
        .ram2_waitrequest  (r2_waitrequest),
        .ram2_readdata     (),
        .ram2_readdatavalid(),
        .ram2_read         (1'b0),
        .ram2_writedata    (r2_writedata),
        .ram2_byteenable   (r2_byteenable),
        .ram2_write        (r2_write),

        // vbuf : unused
        .vbuf_clk          (clk_100m),
        .vbuf_address      (28'd0),
        .vbuf_burstcount   (8'd0),
        .vbuf_waitrequest  (),
        .vbuf_readdata     (),
        .vbuf_readdatavalid(),
        .vbuf_read         (1'b0),
        .vbuf_writedata    (128'd0),
        .vbuf_byteenable   (16'd0),
        .vbuf_write        (1'b0)
    );

    // ------------------------------------------------------------------
    // peel_core with the DDR read + framebuffer write injected.
    // ------------------------------------------------------------------
    ddr_rd_req_t  ddr_req;  ddr_rd_resp_t ddr_resp;
    fb_wr_req_t   fbw_req;  fb_wr_resp_t  fbw_resp;

    peel_core u_core (
        .clk(clk_100m), .reset(reset_100m),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .go(go), .done(done),
        .ddr_req(ddr_req), .ddr_resp(ddr_resp),
        .fbw_req(fbw_req), .fbw_resp(fbw_resp),
        .regs_out()                              // exposed PVR regs (unused on HW)
    );

    // ==================================================================
    // DDR READ master: peel_core ddr_req/ddr_resp  <->  Avalon ram1.
    // peel_core issues one 64-bit-word-addressed burst read at a time and holds
    // ddr_req.rd until accepted. Avalon: assert read+address+burstcount until
    // !waitrequest (accepted), then `burst` readdatavalid beats stream back.
    // ==================================================================
    reg        rd_inflight;   // a read has been accepted, beats still returning
    reg [7:0]  rd_left;       // beats remaining to return
    // issue while the core requests and we have no read in flight
    wire       rd_issue = ddr_req.rd && !rd_inflight;
    assign r1_read     = rd_issue;
    assign r1_addr     = ddr_req.addr;
    assign r1_burstcnt = ddr_req.burst;

    // core-facing response: busy while a read is accepted-and-returning, or while
    // our issue is still waiting on the bridge (waitrequest). dready is GATED on
    // rd_inflight so a stray/late readdatavalid with no read outstanding can never
    // desync the core arbiter's beat count (hangs the exact-beat burst clients).
    assign ddr_resp.busy   = rd_inflight || (rd_issue && r1_waitrequest);
    assign ddr_resp.dout   = r1_readdata;
    assign ddr_resp.dready = r1_readdatavalid && rd_inflight;

    always @(posedge clk_100m) begin
        if (reset_100m) begin
            rd_inflight <= 1'b0; rd_left <= 8'd0;
        end else begin
            if (!rd_inflight) begin
                if (rd_issue && !r1_waitrequest) begin  // accepted this cycle
                    rd_inflight <= 1'b1;
                    rd_left     <= ddr_req.burst;
                end
            end else if (r1_readdatavalid) begin
                if (rd_left <= 8'd1) rd_inflight <= 1'b0;
                rd_left <= rd_left - 8'd1;
            end
        end
    end

    // ==================================================================
    // FRAMEBUFFER WRITE master: peel_core fbw_req (one 32-bit pixel/cycle at a
    // linear index)  ->  Avalon ram2 (64-bit words, 2 px/word).
    // We pair pixels: the first pixel of a word is latched (no DDR write yet), the
    // second pixel triggers a single-beat 64-bit write of {hi_px, lo_px}. Pixels
    // are streamed in linear order per tile row-major, and 640 is even, so pairing
    // even/odd linear indices lands two horizontally-adjacent pixels per word.
    //
    // NOTE: this assumes fbw_req delivers pixels for a word-pair back-to-back
    // (even index then odd index). peel_core streams col_buf in linear order, so
    // consecutive on-screen pixels differ by 1 in pix_idx - holding for the low
    // half then writing on the high half is correct for even row widths.
    // ==================================================================
    reg        have_lo;       // a low (even-index) pixel is latched, awaiting pair
    reg [31:0] lo_px;
    reg [19:0] lo_idx;
    reg        wr_pending;    // a 64-bit word is queued for ram2
    reg [63:0] wr_data64;
    reg [28:0] wr_addr64;

    // Backpressure: block the core while a queued word is still in flight (the
    // bridge hasn't accepted it), so accepting a new high-half pixel can never
    // clobber wr_data64. Latching a low-half pixel is always safe (no DDR write).
    assign fbw_resp.busy = wr_pending;

    assign r2_write      = wr_pending;
    assign r2_addr       = wr_addr64;
    assign r2_writedata  = wr_data64;
    assign r2_burstcnt   = 8'd1;
    assign r2_byteenable = 8'hFF;

    always @(posedge clk_100m) begin
        if (reset_100m) begin
            have_lo <= 1'b0; wr_pending <= 1'b0;
        end else begin
            // retire a queued word once the bridge accepts it
            if (wr_pending && !r2_waitrequest) wr_pending <= 1'b0;

            // accept a new pixel when the core presents one and we can take it
            if (fbw_req.we && !fbw_resp.busy) begin
                if (!have_lo) begin
                    // low half (even linear index): latch, wait for its pair
                    have_lo <= 1'b1;
                    lo_px   <= fbw_req.argb;
                    lo_idx  <= fbw_req.pix_idx;
                end else begin
                    // high half: form the 64-bit word {odd_px, even_px} and queue
                    have_lo    <= 1'b0;
                    wr_pending <= 1'b1;
                    wr_data64  <= {fbw_req.argb, lo_px};
                    wr_addr64  <= FB_BASE_WORD + {9'd0, lo_idx[19:1]};
                end
            end
        end
    end
endmodule

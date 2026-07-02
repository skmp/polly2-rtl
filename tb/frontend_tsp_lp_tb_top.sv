// frontend_tsp_lp_tb_top - SIM wrapper around peel_core.
//
// Provides the FAUX DDR controller (behavioral 8 MB vram[]) and the behavioral
// 640x480 framebuffer fb[], injected into peel_core via the ddr_req/ddr_resp and
// fbw_req/fbw_resp ports. The C++ TB loads the PVR reg dump through wr_* before
// `go`, preloads vram[], and reads fb[] after `done` to write the BMP.
//
// The faux DDR controller reproduces the original single-channel model exactly:
// a granted read waits RD_LAT dead cycles, then streams `burst` beats one/cycle
// from incrementing 64-bit-word addresses (addr[19:0]) - so cycle counts match
// the pre-refactor design.
//
module frontend_tsp_lp_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
    // register write path (C++ TB loads the PVR reg dump through this before go)
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    input             go,             // 1-cycle: start rendering the region array
    output reg        done            // 1-cycle: region array fully processed
);
    // -------------------- 8 MB behavioral VRAM (1M x 64-bit) --------------------
    (* verilator public_flat_rw *) reg [63:0] vram [0:1048575];
    // -------------------- 640x480 behavioral framebuffer --------------------
    (* verilator public_flat_rw *) reg [31:0] fb [0:640*480-1];

    // -------------------- injected core <-> backend bundles --------------------
    ddr_rd_req_t  ddr_req;  ddr_rd_resp_t ddr_resp;
    fb_wr_req_t   fbw_req;  fb_wr_resp_t  fbw_resp;

    // ==================== FAUX DDR READ CONTROLLER ====================
    // Single 64-bit channel, RD_LAT dead cycles then `burst` beats. Matches the
    // old in-core behavioral reader (one read in flight; the arbiter in peel_core
    // guarantees ddr_req.rd only pulses when the channel is free).
    localparam integer RD_LAT = 8;
    reg        d_busy;
    reg [19:0] d_word;
    reg [7:0]  d_beats, d_lat;
    reg [63:0] d_do; reg d_dv;
    assign ddr_resp.busy   = d_busy;
    assign ddr_resp.dout   = d_do;
    assign ddr_resp.dready = d_dv;
    always @(posedge clk) begin
        d_dv <= 1'b0;
        if (reset) d_busy <= 1'b0;
        else if (!d_busy) begin
            if (ddr_req.rd) begin
                d_busy  <= 1'b1;
                d_word  <= ddr_req.addr[19:0];
                d_beats <= ddr_req.burst;
                d_lat   <= RD_LAT[7:0];
            end
        end else if (d_lat != 0) d_lat <= d_lat - 8'd1;
        else begin
            d_do   <= vram[d_word]; d_dv <= 1'b1; d_word <= d_word + 20'd1;
            if (d_beats <= 8'd1) d_busy <= 1'b0;
            d_beats <= d_beats - 8'd1;
        end
    end

    // ==================== FAUX FRAMEBUFFER WRITE ====================
    // Never busy: accept a pixel every cycle it is presented, write it to fb[].
    assign fbw_resp.busy = 1'b0;
    always @(posedge clk) begin
        if (fbw_req.we) fb[fbw_req.pix_idx] <= fbw_req.argb;
    end

    // -------------------- the render core --------------------
    peel_core u_core (
        .clk(clk), .reset(reset),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .go(go), .done(done),
        .ddr_req(ddr_req), .ddr_resp(ddr_resp),
        .fbw_req(fbw_req), .fbw_resp(fbw_resp)
    );
endmodule

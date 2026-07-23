// sim_ddr_fb - shared SIM backend for the render cores (peel_core / isp_core).
//
// Bundles the behavioral 8 MB VRAM + faux single-channel DDR READ controller and
// the behavioral 640x480 framebuffer + faux framebuffer WRITE, exposing the
// injected core ports (ddr_req/ddr_resp, fbw_req/fbw_resp). A sim top instantiates
// ONE render core and ONE sim_ddr_fb and wires the two bundles together.
//
// The faux DDR controller reproduces the original single-channel model exactly: a
// granted read waits RD_LAT dead cycles, then streams `burst` beats one/cycle from
// incrementing 64-bit-word addresses (addr[19:0]). One read in flight (the core's
// arbiter only pulses ddr_req.rd when the channel is free). The framebuffer write
// is never busy: it accepts a pixel every cycle it is presented.
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
                d_lat   <= RD_LAT[7:0] + (ddrvary ? {4'd0, ddr_req.addr[3:0]} : 8'd0);
            end
        end else if (d_lat != 0) d_lat <= d_lat - 8'd1;
        else begin
            d_do   <= vram[d_word]; d_dv <= 1'b1; d_word <= d_word + 20'd1;
            if (d_beats <= 8'd1) d_busy <= 1'b0;
            d_beats <= d_beats - 8'd1;
        end
    end

    // ==================== FAUX FRAMEBUFFER WRITE ====================
    assign fbw_resp.busy = 1'b0;
    always @(posedge clk) begin
        if (fbw_req.we) fb[fbw_req.pix_idx] <= fbw_req.argb;
    end
endmodule

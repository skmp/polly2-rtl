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
    // command queue: up to CQ accepted bursts; per-slot latency counts down for ALL
    // queued commands each cycle (overlap), beats stream from the head in order.
    localparam integer CQ = 4;
    reg [19:0] q_word [0:CQ-1];
    reg [7:0]  q_beats[0:CQ-1];
    reg [7:0]  q_lat  [0:CQ-1];
    reg [2:0]  q_wp, q_rp;
    wire       q_empty = (q_wp == q_rp);
    wire       q_full  = (q_wp[2] != q_rp[2]) && (q_wp[1:0] == q_rp[1:0]);
    wire [1:0] q_h     = q_rp[1:0];
    reg [63:0] d_do; reg d_dv;
    integer qi;
    assign ddr_resp.busy   = q_full;
    assign ddr_resp.dout   = d_do;
    assign ddr_resp.dready = d_dv;
    always @(posedge clk) begin
        d_dv <= 1'b0;
        if (reset) begin q_wp <= 3'd0; q_rp <= 3'd0; end
        else begin
            if (ddr_req.rd && !q_full) begin
                q_word [q_wp[1:0]] <= ddr_req.addr[19:0];
                q_beats[q_wp[1:0]] <= ddr_req.burst;
                q_lat  [q_wp[1:0]] <= RD_LAT[7:0] + (ddrvary ? {4'd0, ddr_req.addr[3:0]} : 8'd0);
                q_wp <= q_wp + 3'd1;
            end
            for (qi = 0; qi < CQ; qi = qi + 1)
                if (q_lat[qi] != 8'd0 && !(ddr_req.rd && !q_full && qi == {30'd0,q_wp[1:0]}))
                    q_lat[qi] <= q_lat[qi] - 8'd1;
            if (!q_empty && q_lat[q_h] == 8'd0) begin
                d_do <= vram[q_word[q_h]]; d_dv <= 1'b1;
                q_word[q_h]  <= q_word[q_h] + 20'd1;
                q_beats[q_h] <= q_beats[q_h] - 8'd1;
                if (q_beats[q_h] <= 8'd1) q_rp <= q_rp + 3'd1;
            end
        end
    end

    // ==================== FAUX FRAMEBUFFER WRITE ====================
    assign fbw_resp.busy = 1'b0;
    always @(posedge clk) begin
        if (fbw_req.we) fb[fbw_req.pix_idx] <= fbw_req.argb;
    end
endmodule

//
// polly2_rtl_test - standalone synthesis / timing harness around the polly2 render core as the DE10 build integrates
// it: simplex_pvr_top (polly2-de10nano/rtl/simplex_pvr_top.sv) = peel_core (reg file, ISP/TSP, texture path, tile
// buffers) + its multi-outstanding DDR read master + the `vo` framebuffer write-out. peel_core takes its default
// RAS_LANES (8), as in the DE10 bitstream. A self-contained place-and-route + timing-close context, so the tool reports
// Fmax and area for the render core alone, decoupled from the board top -- the polly2 sibling of caique-rtl's
// testing harness (caique_rtl_test), with the same pattern:
//   * ALL external inputs are driven from registers the harness loads via wr_en / wr_addr / wr_data, so every input
//     bit has a real register source and the tool cannot fold the design away against constant inputs:
//       wr_addr[13] = 0 : a PVR register write (byte offset wr_addr[12:0]), registered once and then presented on the
//                         core's own wr_en / wr_addr / wr_data port, as pvr_mmio does on the DE10;
//       wr_addr[13] = 1 : in_reg[wr_addr[1:0]], the input register bank below;
//   * ALL external outputs are captured into RAW registers with NO logic in between (pure core timing), then XOR-folded
//     to a SINGLE `digest` pin one cycle LATER (the fold tree sits off the capture registers, never in a measured
//     path).
//
// External ports are simplex_pvr_top's: the register load + go / done, the two Avalon DDR channels (DDRAM_* reads,
// DDRAM2_* framebuffer writes; DDR3 sits behind the HPS on the DE10, so both stay outside) and the live display
// registers the board's scanout reads (FB_R_*, VO_CONTROL, SPG_CONTROL, FB_W_SOF*, TEST_SELECT). Capturing those
// keeps the same reg-file fields alive as the DE10 build. Left out with the board: sys_top, the HPS bridges
// (sysmem_lite, hps_lw_bridge, pvr_mmio), spg scanout, audio, the PLLs and the clk_sys mux.
//
// Build: vivado -mode batch -source create_project.tcl -tclargs build; Fmax in reports/fmax.txt.
//
module polly2_rtl_test (
    input             clk,
    input             reset,

    // ---- register load (driven by the HPS) ----
    input             wr_en,
    input      [13:0] wr_addr,      // [13] 0: PVR register byte offset [12:0], 1: in_reg[wr_addr[1:0]]
    input      [31:0] wr_data,

    // ---- single folded output pin (keeps every output bit alive) ----
    output reg        digest
);
    // ---- PVR register writes, registered once in front of the core ----
    reg        c_wr_en;
    reg [12:0] c_wr_addr;
    reg [31:0] c_wr_data;
    always @(posedge clk) begin
        if (reset) c_wr_en <= 1'b0;
        else       c_wr_en <= wr_en && !wr_addr[13];
        c_wr_addr <= wr_addr[12:0];
        c_wr_data <= wr_data;
    end

    // ---- input register bank ----
    //   0 : DDRAM_DOUT[31:0]
    //   1 : DDRAM_DOUT[63:32]
    //   2 : vram_cfg
    //   3 : control bits: 0 go, 1 tex_en, 2 DDRAM_BUSY, 3 DDRAM_DOUT_READY, 4 DDRAM2_BUSY
    localparam integer NREG = 4;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk) begin
        if (reset) begin
            for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        end else if (wr_en && wr_addr[13]) begin
            in_reg[wr_addr[1:0]] <= wr_data;
        end
    end

    wire [31:0] w_ctl = in_reg[3];

    // ---- DUT outputs ----
    wire        d_done;
    wire [31:0] d_fb_r_sof1, d_fb_r_sof2, d_fb_r_ctrl, d_vo_control, d_spg_control;
    wire [31:0] d_fb_w_sof1, d_fb_w_sof2, d_test_select;
    wire  [7:0] d_rd_burstcnt;
    wire [28:0] d_rd_addr;
    wire        d_rd;
    wire  [7:0] d_wr_burstcnt;
    wire [28:0] d_wr_addr;
    wire [63:0] d_wr_din;
    wire  [7:0] d_wr_be;
    wire        d_wr_we;

    // ---- DUT: the render core with its DDR masters ----
    simplex_pvr_top u_pvr (
        .clk(clk), .reset(reset),
        .wr_en(c_wr_en), .wr_addr(c_wr_addr), .wr_data(c_wr_data),
        .go(w_ctl[0]), .done(d_done),
        .tex_en(w_ctl[1]),
        .vram_cfg(in_reg[2]),
        .FB_R_SOF1(d_fb_r_sof1), .FB_R_SOF2(d_fb_r_sof2), .FB_R_CTRL(d_fb_r_ctrl),
        .VO_CONTROL(d_vo_control), .SPG_CONTROL(d_spg_control),
        .FB_W_SOF1(d_fb_w_sof1), .FB_W_SOF2(d_fb_w_sof2),
        .TEST_SELECT(d_test_select),
        .DDRAM_CLK(),
        .DDRAM_BUSY(w_ctl[2]),
        .DDRAM_BURSTCNT(d_rd_burstcnt),
        .DDRAM_ADDR(d_rd_addr),
        .DDRAM_DOUT({in_reg[1], in_reg[0]}),
        .DDRAM_DOUT_READY(w_ctl[3]),
        .DDRAM_RD(d_rd),
        .DDRAM2_CLK(),
        .DDRAM2_BUSY(w_ctl[4]),
        .DDRAM2_BURSTCNT(d_wr_burstcnt),
        .DDRAM2_ADDR(d_wr_addr),
        .DDRAM2_DIN(d_wr_din),
        .DDRAM2_BE(d_wr_be),
        .DDRAM2_WE(d_wr_we)
    );

    // ---- RAW capture (no logic before the flops -> pure core timing) ----
    reg [255:0] cap_regs;                 // the 8 display registers
    reg  [37:0] cap_rd;                   // DDRAM_RD, DDRAM_BURSTCNT, DDRAM_ADDR
    reg [109:0] cap_wr;                   // DDRAM2_WE, DDRAM2_BE, DDRAM2_BURSTCNT, DDRAM2_ADDR, DDRAM2_DIN
    reg         cap_done;
    always @(posedge clk) begin
        if (reset) begin cap_regs <= '0; cap_rd <= '0; cap_wr <= '0; cap_done <= 1'b0; end
        else begin
            cap_regs <= {d_fb_r_sof1, d_fb_r_sof2, d_fb_r_ctrl, d_vo_control, d_spg_control,
                         d_fb_w_sof1, d_fb_w_sof2, d_test_select};
            cap_rd   <= {d_rd, d_rd_burstcnt, d_rd_addr};
            cap_wr   <= {d_wr_we, d_wr_be, d_wr_burstcnt, d_wr_addr, d_wr_din};
            cap_done <= d_done;
        end
    end

    // ---- next cycle: XOR-fold to one pin (off cap_*, not the DUT) ----
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^{ cap_regs, cap_rd, cap_wr, cap_done };
    end
endmodule

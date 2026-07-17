//============================================================================
//
//  simplex PVR standalone top for the DE10-Nano / MiSTer hardware.
//
//  Written from scratch - NO MiSTer framework components. Contents:
//
//   - HPS plumbing: sysmem_lite (f2sdram atom wrapper: ram1/ram2/vbuf),
//     h2f gp registers (loader reset handshake), HDMI I2C pass-through
//     (minicast setup_hdmi programs the ADV7513), f2h vsync interrupt,
//     lightweight-bridge MMIO (hps_lw_bridge + pvr_mmio @ 0xFF200000).
//   - Core clock: rtl/pll (4 fixed outputs 75/90/100/112.5 MHz) through the
//     soft glitch-free mux (clk_mux_gf), selected by the MMIO CLK register;
//     reset window held around a switch.
//   - peel_core (simplex_pvr_top): registers/GO/RESET/VRAM base via MMIO,
//     render reads on ram1, framebuffer writes on ram2.
//   - Display: pll_hdmi (fixed 148.5 MHz) + SPG (1080p raster, 640x480
//     split-VRAM FB doubled to 1280x960, vbuf port) -> TX register stage ->
//     ADV7513. No OSD, no scaler, no analog output.
//   - Audio: pll_audio (24.576 MHz) + audio_i2s: 2048-entry sample FIFO
//     fed from the MMIO AUDIO_DATA register (blocking when full), drained
//     at 48 kHz onto the ADV7513's I2S input (16-bit, standard I2S).
//
//  The ARM (minicast) owns: bitstream load + reset release (gp[31:30],
//  01 -> 00 -> 10), ADV7513 init, VRAM loading via /dev/mem, and the PVR
//  MMIO map (see rtl/pvr_mmio.sv / minicast/pvr_mmio.h).
//
//============================================================================

module sys_top
(
	/////////// CLOCK //////////
	input         FPGA_CLK1_50,
	input         FPGA_CLK2_50,
	input         FPGA_CLK3_50,

	//////////// HDMI //////////
	output        HDMI_I2C_SCL,
	inout         HDMI_I2C_SDA,

	output        HDMI_MCLK,
	output        HDMI_SCLK,
	output        HDMI_LRCLK,
	output        HDMI_I2S,

	output        HDMI_TX_CLK,
	output        HDMI_TX_DE,
	output [23:0] HDMI_TX_D,
	output        HDMI_TX_HS,
	output        HDMI_TX_VS,

	input         HDMI_TX_INT,

	//////////// SDR ///////////
	output [12:0] SDRAM_A,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nWE,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nCS,
	output  [1:0] SDRAM_BA,
	output        SDRAM_CLK,
	output        SDRAM_CKE,

	//////////// VGA ///////////
	output  [5:0] VGA_R,
	output  [5:0] VGA_G,
	output  [5:0] VGA_B,
	inout         VGA_HS,   // secondary SD card detect when VGA_EN = 1
	output        VGA_VS,
	input         VGA_EN,

	/////////// AUDIO //////////
	output        AUDIO_L,
	output        AUDIO_R,
	output        AUDIO_SPDIF,

	//////////// SDIO ///////////
	inout   [3:0] SDIO_DAT,
	inout         SDIO_CMD,
	output        SDIO_CLK,

	//////////// I/O ///////////
	output        LED_USER,
	output        LED_HDD,
	output        LED_POWER,
	input         BTN_USER,
	input         BTN_OSD,
	input         BTN_RESET,

	////////// I/O ALT /////////
	output        SD_SPI_CS,
	input         SD_SPI_MISO,
	output        SD_SPI_CLK,
	output        SD_SPI_MOSI,

	inout         SDCD_SPDIF,
	output        IO_SCL,
	inout         IO_SDA,

	///////// USER IO ///////////
	inout   [6:0] USER_IO,

	////////// ADC //////////////
	output        ADC_SCK,
	input         ADC_SDO,
	output        ADC_SDI,
	output        ADC_CONVST,

	////////// MB KEY ///////////
	input   [1:0] KEY,

	////////// MB SWITCH ////////
	input   [3:0] SW,

	////////// MB LED ///////////
	output  [7:0] LED
);

//////////////////////////////////////////////////////////////////////////
// Unused board interfaces: parked safe/high-Z. The port list is kept
// complete so the QSF pin assignments still resolve.
//////////////////////////////////////////////////////////////////////////

assign SDRAM_A    = 13'd0;
assign SDRAM_BA   = 2'd0;
assign SDRAM_DQ   = 16'bZ;
assign SDRAM_DQML = 1'b1;
assign SDRAM_DQMH = 1'b1;
assign SDRAM_nWE  = 1'b1;
assign SDRAM_nCAS = 1'b1;
assign SDRAM_nRAS = 1'b1;
assign SDRAM_nCS  = 1'b1;
assign SDRAM_CLK  = 1'b0;
assign SDRAM_CKE  = 1'b0;

assign VGA_R  = 6'bZZZZZZ;
assign VGA_G  = 6'bZZZZZZ;
assign VGA_B  = 6'bZZZZZZ;
assign VGA_VS = 1'bZ;
assign VGA_HS = 1'bZ;       // must stay Z: readable as SD detect on IO boards

assign AUDIO_L     = 1'bZ;
assign AUDIO_R     = 1'bZ;
assign AUDIO_SPDIF = 1'bZ;
assign SDCD_SPDIF  = 1'bZ;

assign SDIO_DAT = 4'bZZZZ;
assign SDIO_CMD = 1'bZ;
assign SDIO_CLK = 1'bZ;

assign SD_SPI_CS   = 1'bZ;
assign SD_SPI_CLK  = 1'bZ;
assign SD_SPI_MOSI = 1'bZ;

assign IO_SCL  = 1'bZ;
assign IO_SDA  = 1'bZ;
assign USER_IO = 7'bZZZZZZZ;

assign ADC_SCK    = 1'b0;
assign ADC_SDI    = 1'b0;
assign ADC_CONVST = 1'b0;

assign LED_USER  = 1'bZ;
assign LED_HDD   = 1'bZ;
assign LED_POWER = 1'bZ;

// board LEDs: liveness + bring-up status
assign LED = {2'd0, pvr_mmio_rst, pvr_busy_led, ~pll_locked, spg_underrun, hb_hdmi, hb_sys};

//////////////////////////////////////////////////////////////////////////
// HPS general-purpose registers: only the loader's core-reset handshake.
// gp_out[31:30]: 01 = assert reset_req; 00 -> 10 transition = release.
//////////////////////////////////////////////////////////////////////////

wire [31:0] gp_out;

cyclonev_hps_interface_mpu_general_purpose h2f_gp
(
	.gp_in(32'd0),
	.gp_out(gp_out)
);

reg reset_req = 0;
always @(posedge FPGA_CLK2_50) begin
	reg [1:0] resetd, resetd2;
	reg       old_reset;

	old_reset <= reset;
	if(~old_reset & reset) reset_req <= 1;

	if(resetd==1) reset_req <= 1;
	if(resetd==2 && resetd2==0) reset_req <= 0;

	resetd  <= gp_out[31:30];
	resetd2 <= resetd;
end

//////////////////////////////////////////////////////////////////////////
// HPS DDR3 ports: ram1 = peel render reads, ram2 = peel FB writes,
// vbuf = SPG display reads (128-bit)
//////////////////////////////////////////////////////////////////////////

wire        reset;
wire        clk_100m;

wire [28:0] ram_address;
wire  [7:0] ram_burstcount;
wire        ram_waitrequest;
wire [63:0] ram_readdata;
wire        ram_readdatavalid;
wire        ram_read;

wire [28:0] ram2_address;
wire  [7:0] ram2_burstcount;
wire        ram2_waitrequest;
wire [63:0] ram2_writedata;
wire  [7:0] ram2_byteenable;
wire        ram2_write;

wire [27:0] vbuf_address;
wire  [7:0] vbuf_burstcount;
wire        vbuf_waitrequest;
wire [127:0] vbuf_readdata;
wire        vbuf_readdatavalid;
wire        vbuf_read;

sysmem_lite sysmem
(
	.reset_core_req(reset_req),
	.reset_out(reset),
	.clock(clk_100m),

	.reset_hps_cold_req(1'b0),

	// peel_core render/geometry reads (read-only)
	.ram1_clk(clk_sys),
	.ram1_address(ram_address),
	.ram1_burstcount(ram_burstcount),
	.ram1_waitrequest(ram_waitrequest),
	.ram1_readdata(ram_readdata),
	.ram1_readdatavalid(ram_readdatavalid),
	.ram1_read(ram_read),
	.ram1_writedata(64'd0),
	.ram1_byteenable(8'hFF),
	.ram1_write(1'b0),

	// peel_core framebuffer writes (write-only)
	.ram2_clk(clk_sys),
	.ram2_address(ram2_address),
	.ram2_burstcount(ram2_burstcount),
	.ram2_waitrequest(ram2_waitrequest),
	.ram2_readdata(),
	.ram2_readdatavalid(),
	.ram2_read(1'b0),
	.ram2_writedata(ram2_writedata),
	.ram2_byteenable(ram2_byteenable),
	.ram2_write(ram2_write),

	// SPG display reads (read-only, 128-bit)
	.vbuf_clk(clk_100m),
	.vbuf_address(vbuf_address),
	.vbuf_burstcount(vbuf_burstcount),
	.vbuf_waitrequest(vbuf_waitrequest),
	.vbuf_writedata(128'd0),
	.vbuf_byteenable(16'hFFFF),
	.vbuf_write(1'b0),
	.vbuf_readdata(vbuf_readdata),
	.vbuf_readdatavalid(vbuf_readdatavalid),
	.vbuf_read(vbuf_read)
);

//////////////////////////////////////////////////////////////////////////
// HDMI I2C pass-through: the HPS hard I2C owns the bus; minicast's
// setup_hdmi programs the ADV7513 through it.
//////////////////////////////////////////////////////////////////////////

wire hdmi_scl_en, hdmi_sda_en;
assign HDMI_I2C_SCL = hdmi_scl_en ? 1'b0 : 1'bZ;
assign HDMI_I2C_SDA = hdmi_sda_en ? 1'b0 : 1'bZ;

cyclonev_hps_interface_peripheral_i2c hdmi_i2c
(
	.out_clk(hdmi_scl_en),
	.scl(HDMI_I2C_SCL),
	.out_data(hdmi_sda_en),
	.sda(HDMI_I2C_SDA)
);

// vsync interrupt to the ARM (f2h IRQ0)
cyclonev_hps_interface_interrupts interrupts
(
	.irq({63'd0, HDMI_TX_VS})
);

//////////////////////////////////////////////////////////////////////////
// PVR MMIO @ 0xFF200000 (HPS lightweight bridge, hand-decoded Avalon-MM)
//////////////////////////////////////////////////////////////////////////

wire [20:0] pvr_avm_address;
wire        pvr_avm_read, pvr_avm_write;
wire [31:0] pvr_avm_writedata, pvr_avm_readdata;
wire  [3:0] pvr_avm_byteenable;
wire        pvr_avm_readdatavalid, pvr_avm_waitrequest;

hps_lw_bridge pvr_lw_bridge
(
	.clk              (clk_sys),
	.avm_address      (pvr_avm_address),
	.avm_read         (pvr_avm_read),
	.avm_write        (pvr_avm_write),
	.avm_writedata    (pvr_avm_writedata),
	.avm_byteenable   (pvr_avm_byteenable),
	.avm_readdata     (pvr_avm_readdata),
	.avm_readdatavalid(pvr_avm_readdatavalid),
	.avm_waitrequest  (pvr_avm_waitrequest)
);

wire        pvr_mmio_wr, pvr_mmio_go, pvr_mmio_rst, pvr_done;
wire [12:0] pvr_mmio_addr;
wire [31:0] pvr_mmio_wdata;
wire  [7:0] pvr_vram_top;
wire  [1:0] mmio_clk_sel;

wire        aud_fifo_wr, aud_fifo_full;
wire [31:0] aud_fifo_wdata;
wire [11:0] aud_fifo_level;

pvr_mmio pvr_mmio
(
	.clk              (clk_sys),

	.avs_address      (pvr_avm_address),
	.avs_read         (pvr_avm_read),
	.avs_write        (pvr_avm_write),
	.avs_writedata    (pvr_avm_writedata),
	.avs_byteenable   (pvr_avm_byteenable),
	.avs_readdata     (pvr_avm_readdata),
	.avs_readdatavalid(pvr_avm_readdatavalid),
	.avs_waitrequest  (pvr_avm_waitrequest),

	.pvr_wr           (pvr_mmio_wr),
	.pvr_addr         (pvr_mmio_addr),
	.pvr_wdata        (pvr_mmio_wdata),
	.pvr_go           (pvr_mmio_go),
	.pvr_rst          (pvr_mmio_rst),
	.vram_top         (pvr_vram_top),
	.clk_sel          (mmio_clk_sel),
	.pvr_done         (pvr_done),

	.aud_wr           (aud_fifo_wr),
	.aud_wdata        (aud_fifo_wdata),
	.aud_full         (aud_fifo_full),
	.aud_level        (aud_fifo_level)
);

//////////////////////////////////////////////////////////////////////////
// Core clock: 4 fixed PLL outputs (900 MHz VCO / 12,10,9,8) through the
// soft glitch-free mux. Selection from the MMIO CLK register; the core is
// held in reset for ~320ns on each side of the actual mux flip.
//////////////////////////////////////////////////////////////////////////

wire clk_sys;
wire clk_75, clk_90, clk_100, clk_112;
wire pll_locked;

pll pll
(
	.refclk(FPGA_CLK2_50),
	.rst(0),
	.outclk_0(clk_75),
	.outclk_1(clk_90),
	.outclk_2(clk_100),
	.outclk_3(clk_112),
	.reconfig_to_pll(64'd0),   // fixed outputs, no runtime reconfig
	.reconfig_from_pll(),
	.locked(pll_locked)
);

clk_mux_gf pixclk_mux
(
	.clks  ({clk_112, clk_100, clk_90, clk_75}),  // sel 0/1/2/3 = 75/90/100/112.5 MHz
	.sel   (clk_sel),
	.outclk(clk_sys)
);

reg  [1:0] clk_sel_meta   = 2'd0;
reg  [1:0] clk_sel_sync   = 2'd0;
reg  [1:0] clk_sel        = 2'd0;
reg  [4:0] clk_switch_cnt = 5'd0;

always @(posedge FPGA_CLK2_50) begin
	clk_sel_meta <= mmio_clk_sel;   // clk_sys domain -> 50 MHz, quasi-static
	clk_sel_sync <= clk_sel_meta;

	if (clk_switch_cnt != 5'd0) begin
		clk_switch_cnt <= clk_switch_cnt - 5'd1;
		if (clk_switch_cnt == 5'd16) clk_sel <= clk_sel_sync;
	end
	else if (clk_sel_sync != clk_sel) clk_switch_cnt <= 5'd31;
end

wire clk_switch_reset = !pll_locked | (clk_switch_cnt != 5'd0);

//////////////////////////////////////////////////////////////////////////
// peel_core (simplex_pvr_top). VRAM window: {vram_top, 24'd0} bytes in
// DDR3 (16MB aligned) = {vram_top, 21'd0} in 64-bit words.
//////////////////////////////////////////////////////////////////////////

wire [28:0] vram_word_base = {pvr_vram_top, 21'd0};

wire pvr_reset = reset_req | clk_switch_reset | pvr_mmio_rst;

wire [31:0] spvr_fb_r_sof1, spvr_fb_r_sof2, spvr_fb_w_sof1, spvr_fb_w_sof2;

// peel_core render DDR read channel (raw word offset; base added below)
wire [28:0] spvr_rd_addr;
wire  [7:0] spvr_rd_burstcnt;
wire        spvr_rd_rd;

// peel_core framebuffer write channel (raw word offset; base added below)
wire [28:0] spvr_fb_addr_raw;

simplex_pvr_top simplex_pvr
(
	.clk    ( clk_sys ),
	.reset  ( pvr_reset ),

	.wr_en  ( pvr_mmio_wr ),
	.wr_addr( pvr_mmio_addr ),
	.wr_data( pvr_mmio_wdata ),
	.go     ( pvr_mmio_go ),
	.done   ( pvr_done ),

	.tex_en ( 1'b1 ),                       // real texel fetches (not base-colour only)

	// FB write base is now internal to simplex_pvr_top (follows FB_W_SOF1);
	// SPG's display read base uses FB_R_SOF1 below.

	.FB_R_SOF1  ( spvr_fb_r_sof1 ),
	.FB_R_SOF2  ( spvr_fb_r_sof2 ),
	.FB_W_SOF1  ( spvr_fb_w_sof1 ),
	.FB_W_SOF2  ( spvr_fb_w_sof2 ),
	.TEST_SELECT( ),

	// render READ channel -> ram1
	.DDRAM_CLK       ( ),
	.DDRAM_BUSY      ( ram_waitrequest ),
	.DDRAM_BURSTCNT  ( spvr_rd_burstcnt ),
	.DDRAM_ADDR      ( spvr_rd_addr ),
	.DDRAM_DOUT      ( ram_readdata ),
	.DDRAM_DOUT_READY( ram_readdatavalid ),
	.DDRAM_RD        ( spvr_rd_rd ),

	// framebuffer WRITE channel -> ram2
	.DDRAM2_CLK      ( ),
	.DDRAM2_BUSY     ( ram2_waitrequest ),
	.DDRAM2_BURSTCNT ( ram2_burstcount ),
	.DDRAM2_ADDR     ( spvr_fb_addr_raw ),
	.DDRAM2_DIN      ( ram2_writedata ),
	.DDRAM2_BE       ( ram2_byteenable ),
	.DDRAM2_WE       ( ram2_write )
);

assign ram_address    = vram_word_base + spvr_rd_addr;
assign ram_burstcount = spvr_rd_burstcnt;
assign ram_read       = spvr_rd_rd;
assign ram2_address   = vram_word_base + spvr_fb_addr_raw;

// busy LED: set on GO, cleared on the render-done edge.
reg pvr_done_q   = 1'b0;
reg pvr_busy_led = 1'b0;
always @(posedge clk_sys) begin
	pvr_done_q <= pvr_done;
	if (pvr_done & ~pvr_done_q) pvr_busy_led <= 1'b0;
	if (pvr_mmio_go)            pvr_busy_led <= 1'b1;
end

//////////////////////////////////////////////////////////////////////////
// Display: pll_hdmi (fixed 148.5 MHz) + SPG -> TX register stage -> pins.
// FB is split-VRAM 16bpp RGB565: DC 32-bit-view word W at DDR byte W*8,
// half selected by SOF bit 22.
//////////////////////////////////////////////////////////////////////////

wire hdmi_clk_out;
pll_hdmi pll_hdmi
(
	.refclk(FPGA_CLK1_50),
	.rst(1'b0),
	.reconfig_to_pll(64'd0),   // fixed 148.5 MHz (1080p60), no runtime reconfig
	.reconfig_from_pll(),
	.outclk_0(hdmi_clk_out)
);

wire clk_hdmi = hdmi_clk_out;

// absolute DDR byte address of the displayed frame, straight from the core's
// FB_R_SOF1 display register (side layout: 8 bytes per DC 32-bit word; SOF
// bit 22 is the 64-bit-half select).
wire [31:0] fb_disp_base = {pvr_vram_top, 24'd0} + {9'd0, spvr_fb_r_sof1[21:2], 3'd0};

wire [23:0] hdmi_data;
wire        hdmi_hs, hdmi_vs, hdmi_de, hdmi_vbl, hdmi_brd;
wire        spg_underrun;

spg spg
(
	.clk         (clk_hdmi),
	.reset       (reset_req),

	.fb_base     (fb_disp_base),
	.fb_stride   (14'd1280),
	.fb_line_dbl (1'b0),
	.fb_split    (1'b1),
	.fb_disp_half(spvr_fb_r_sof1[22]),

	.avl_clk          (clk_100m),
	.avl_read         (vbuf_read),
	.avl_address      (vbuf_address),
	.avl_burstcount   (vbuf_burstcount),
	.avl_waitrequest  (vbuf_waitrequest),
	.avl_readdata     (vbuf_readdata),
	.avl_readdatavalid(vbuf_readdatavalid),

	.red   (hdmi_data[23:16]),
	.green (hdmi_data[15:8]),
	.blue  (hdmi_data[7:0]),
	.hsync (hdmi_hs),
	.vsync (hdmi_vs),
	.de    (hdmi_de),
	.vblank(hdmi_vbl),
	.border(hdmi_brd),

	.src_line  (),
	.vblank_in (),
	.vblank_out(),
	.underrun  (spg_underrun)
);

// 2-flop IO timing stage to the ADV7513
reg        hdmi_out_hs, hdmi_out_vs, hdmi_out_de;
reg [23:0] hdmi_out_d;

always @(posedge clk_hdmi) begin
	reg hs, vs, de;
	reg [23:0] d;

	hs <= hdmi_hs;
	vs <= hdmi_vs;
	de <= hdmi_de;
	d  <= hdmi_data;

	hdmi_out_hs <= hs;
	hdmi_out_vs <= vs;
	hdmi_out_de <= de;
	hdmi_out_d  <= d;
end

assign HDMI_TX_HS = hdmi_out_hs;
assign HDMI_TX_VS = hdmi_out_vs;
assign HDMI_TX_DE = hdmi_out_de;
assign HDMI_TX_D  = hdmi_out_d;

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
hdmiclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk_hdmi),
	.dataout(HDMI_TX_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

//////////////////////////////////////////////////////////////////////////
// Audio: MMIO AUDIO_DATA -> 2048-entry async FIFO -> I2S @ 48 kHz.
// setup_hdmi configures the ADV7513 for 48 kHz 16-bit standard I2S;
// audio_i2s generates the same clocking the old silent divider did
// (24.576 MHz MCLK, /8 = 3.072 MHz bclk (64fs), /512 = 48 kHz LR) and
// plays silence while the FIFO is empty.
//////////////////////////////////////////////////////////////////////////

wire clk_audio;
pll_audio pll_audio
(
	.refclk(FPGA_CLK3_50),
	.rst(0),
	.outclk_0(clk_audio)
);

wire aud_sclk, aud_lrclk, aud_sdata;

audio_i2s audio_i2s
(
	.wclk (clk_sys),
	.wr   (aud_fifo_wr),
	.wdata(aud_fifo_wdata),
	.full (aud_fifo_full),
	.level(aud_fifo_level),

	.aclk (clk_audio),
	.sclk (aud_sclk),
	.lrclk(aud_lrclk),
	.sdata(aud_sdata)
);

assign HDMI_MCLK  = clk_audio;
assign HDMI_SCLK  = aud_sclk;
assign HDMI_LRCLK = aud_lrclk;
assign HDMI_I2S   = aud_sdata;

//////////////////////////////////////////////////////////////////////////
// Heartbeats
//////////////////////////////////////////////////////////////////////////

reg [25:0] hb_sys_cnt = 26'd0;
always @(posedge clk_sys) hb_sys_cnt <= hb_sys_cnt + 26'd1;
wire hb_sys = hb_sys_cnt[25];            // ~0.6-0.9 Hz depending on clk_sys

reg [5:0] hb_vs_cnt = 6'd0;
reg       vs_q = 1'b0;
always @(posedge clk_hdmi) begin
	vs_q <= hdmi_vs;
	if (hdmi_vs & ~vs_q) hb_vs_cnt <= hb_vs_cnt + 6'd1;
end
wire hb_hdmi = hb_vs_cnt[5];             // ~0.94 Hz when the raster runs

endmodule

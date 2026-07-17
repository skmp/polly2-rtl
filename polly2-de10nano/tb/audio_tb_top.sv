// audio_tb_top.sv - pvr_mmio + audio_i2s wired exactly as in sys_top; the
// C++ tb drives the Avalon slave side the way hps_lw_bridge does (single
// transaction, write held until !waitrequest) and decodes the I2S output.

module audio_tb_top
(
	input  wire        clk_sys,
	input  wire        clk_audio,

	// Avalon-MM slave (what hps_lw_bridge would drive)
	input  wire [20:0] avs_address,
	input  wire        avs_read,
	input  wire        avs_write,
	input  wire [31:0] avs_writedata,
	input  wire  [3:0] avs_byteenable,
	output wire [31:0] avs_readdata,
	output wire        avs_readdatavalid,
	output wire        avs_waitrequest,

	// I2S out
	output wire        sclk,
	output wire        lrclk,
	output wire        sdata
);

wire        aud_wr, aud_full;
wire [31:0] aud_wdata;
wire [11:0] aud_level;

pvr_mmio mmio
(
	.clk              (clk_sys),

	.avs_address      (avs_address),
	.avs_read         (avs_read),
	.avs_write        (avs_write),
	.avs_writedata    (avs_writedata),
	.avs_byteenable   (avs_byteenable),
	.avs_readdata     (avs_readdata),
	.avs_readdatavalid(avs_readdatavalid),
	.avs_waitrequest  (avs_waitrequest),

	.pvr_wr           (),
	.pvr_addr         (),
	.pvr_wdata        (),
	.pvr_go           (),
	.pvr_rst          (),
	.vram_top         (),
	.clk_sel          (),
	.pvr_done         (1'b0),

	.aud_wr           (aud_wr),
	.aud_wdata        (aud_wdata),
	.aud_full         (aud_full),
	.aud_level        (aud_level)
);

audio_i2s audio_i2s
(
	.wclk (clk_sys),
	.wr   (aud_wr),
	.wdata(aud_wdata),
	.full (aud_full),
	.level(aud_level),

	.aclk (clk_audio),
	.sclk (sclk),
	.lrclk(lrclk),
	.sdata(sdata)
);

endmodule

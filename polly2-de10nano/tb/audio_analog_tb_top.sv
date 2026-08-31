// audio_analog_tb_top.sv - pvr_mmio + audio_pcm + DACs wired as in sys_top; the
// C++ tb drives the Avalon slave side the way hps_lw_bridge does (single
// transaction, write held until !waitrequest) and checks the PCM/PDM output.

module audio_analog_tb_top
(
	input  wire        clk_sys,
	input  wire        clk_audio,
	input  wire        reset,

	// Avalon-MM slave (what hps_lw_bridge would drive)
	input  wire [20:0] avs_address,
	input  wire        avs_read,
	input  wire        avs_write,
	input  wire [31:0] avs_writedata,
	input  wire  [3:0] avs_byteenable,
	output wire [31:0] avs_readdata,
	output wire        avs_readdatavalid,
	output wire        avs_waitrequest,

	output wire [15:0] left,
	output wire [15:0] right,
	output wire        sample_strobe,
	output wire        dac_l,
	output wire        dac_r
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
	.vram_cfg         (),
	.clk_sel          (),
	.pvr_done         (1'b0),

	.aud_wr           (aud_wr),
	.aud_wdata        (aud_wdata),
	.aud_full         (aud_full),
	.aud_level        (aud_level),

	.fb_top           (),
	.fb_bot           ()
);

audio_pcm audio_pcm
(
	.reset(reset),
	.wclk (clk_sys),
	.wr   (aud_wr),
	.wdata(aud_wdata),
	.full (aud_full),
	.level(aud_level),

	.aclk (clk_audio),
	.left (left),
	.right(right),
	.sample_strobe(sample_strobe)
);

sigma_delta_dac dl(.clk(clk_audio), .din(left ^ 16'h8000), .dout(dac_l));
sigma_delta_dac dr(.clk(clk_audio), .din(right ^ 16'h8000), .dout(dac_r));

endmodule

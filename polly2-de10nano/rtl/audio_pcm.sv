// audio_pcm.sv - MMIO-fed analog audio source: 2048-entry x 32-bit
// dual-clock sample FIFO (write side clk_sys, read side clk_audio).
//
// Sample format: [15:0] = LEFT, [31:16] = RIGHT, signed 16-bit PCM.
//
// A free-running /512 divider of the 24.576 MHz audio clock consumes one
// sample at 48 kHz.  The current signed PCM channels are exposed directly
// for the board-level sigma-delta DACs and serialized as standard 16-bit
// stereo I2S for the ADV7513.  Both outputs therefore consume the same FIFO
// sample at exactly the same frame boundary.
//
// One sample is popped per 48 kHz frame; an empty FIFO plays
// last-sample repeat. Reset flushes the FIFO and restores signed-zero silence.
//
// CDC: standard async FIFO, gray-coded pointers through 2FF synchronizers
// in each direction. The project SDC already cuts pll_audio against the
// core clocks (exclusive clock groups), and gray coding makes the
// pointer hops safe with any skew. full/level are write-side views
// (pessimistic while the read side catches up), empty is the read-side
// view - all conservative in the safe direction.

module audio_pcm
(
	input  wire        reset,

	// write side (clk_sys)
	input  wire        wclk,
	input  wire        wr,            // push wdata; ignored while full
	input  wire [31:0] wdata,         // [15:0] left, [31:16] right
	output wire        full,
	output wire [11:0] level,         // samples queued, 0..2048

	// read side / PCM out (clk_audio = 24.576 MHz)
	input  wire        aclk,
	output wire [15:0] left,
	output wire [15:0] right,
	output reg         sample_strobe = 1'b0,
	output wire        i2s_sclk,
	output wire        i2s_lrclk,
	output reg         i2s_sdata = 1'b0
);

function [11:0] bin2gray(input [11:0] b);
	bin2gray = b ^ (b >> 1);
endfunction

function [11:0] gray2bin(input [11:0] g);
	integer i;
	begin
		gray2bin[11] = g[11];
		for (i = 10; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i+1] ^ g[i];
	end
endfunction

reg [31:0] mem [0:2047];

//////////////////////////////////////////////////////////////////////////
// Write side (wclk)
//////////////////////////////////////////////////////////////////////////

reg [11:0] wbin     = 12'd0;
reg [11:0] wgray    = 12'd0;
reg [11:0] rgray_w1 = 12'd0;   // rgray -> wclk 2FF synchronizer
reg [11:0] rgray_w2 = 12'd0;

wire [11:0] wbin_next = wbin + 12'd1;

// full: write gray equals read gray with the two MSBs inverted
assign full  = (wgray == {~rgray_w2[11:10], rgray_w2[9:0]});
assign level = wbin - gray2bin(rgray_w2);

always @(posedge wclk) begin
	if (reset) begin
		wbin     <= 12'd0;
		wgray    <= 12'd0;
		rgray_w1 <= 12'd0;
		rgray_w2 <= 12'd0;
	end else begin
		rgray_w1 <= rgray;
		rgray_w2 <= rgray_w1;
		if (wr && !full) begin
			mem[wbin[10:0]] <= wdata;
			wbin  <= wbin_next;
			wgray <= bin2gray(wbin_next);
		end
	end
end

//////////////////////////////////////////////////////////////////////////
// Read side / 48 kHz sample clock (aclk)
//////////////////////////////////////////////////////////////////////////

reg [11:0] rbin     = 12'd0;
reg [11:0] rgray    = 12'd0;
reg [11:0] wgray_a1 = 12'd0;   // wgray -> aclk 2FF synchronizer
reg [11:0] wgray_a2 = 12'd0;

wire        empty     = (rgray == wgray_a2);
wire [11:0] rbin_next = rbin + 12'd1;

// free-running sample divider, wraps every 512 clocks
reg [8:0] adiv = 9'd0;
wire [8:0] adiv_next = adiv + 9'd1;

assign i2s_sclk  = adiv[2];
assign i2s_lrclk = adiv[8];

reg [31:0] rdata_q = 32'd0;   // popped RAM word
reg        got     = 1'b0;    // rdata_q valid for the upcoming frame
reg [31:0] sample  = 32'd0;
assign left  = sample[15:0];
assign right = sample[31:16];

// Standard I2S: LRCLK low is left, MSB first, and slot zero is the one-bit
// delay after each LRCLK edge.  Data changes on SCLK falling edges so the
// ADV7513 samples it on rising edges.
wire [4:0] i2s_slot = adiv_next[7:3];
wire       i2s_half = adiv_next[8];
wire [15:0] i2s_channel = i2s_half ? sample[31:16] : sample[15:0];
wire  [4:0] i2s_bit_index = 5'd16 - i2s_slot;

always @(posedge aclk) begin
	if (reset) begin
		rbin          <= 12'd0;
		rgray         <= 12'd0;
		wgray_a1      <= 12'd0;
		wgray_a2      <= 12'd0;
		adiv           <= 9'd0;
		rdata_q       <= 32'd0;
		got           <= 1'b0;
		sample        <= 32'd0;
		sample_strobe <= 1'b0;
		i2s_sdata     <= 1'b0;
	end else begin
		sample_strobe <= 1'b0;
		wgray_a1 <= wgray;
		wgray_a2 <= wgray_a1;

		adiv <= adiv_next;

		// pop mid right-half; settled long before the frame-boundary load
		if (adiv == 9'd384) begin
			got <= !empty;
			if (!empty) begin
				rdata_q <= mem[rbin[10:0]];
				rbin  <= rbin_next;
				rgray <= bin2gray(rbin_next);
			end
		end

		// Commit only a successfully popped sample.  Empty FIFO therefore
		// repeats the previous frame, and reset value zero is signed silence.
		if (adiv == 9'h1FF) begin
			if (got) sample <= rdata_q;
			got <= 1'b0;
			sample_strobe <= 1'b1;
		end

		if (adiv[2:0] == 3'b111)
			i2s_sdata <= (i2s_slot >= 5'd1 && i2s_slot <= 5'd16)
			             ? i2s_channel[i2s_bit_index[3:0]] : 1'b0;
	end
end

endmodule

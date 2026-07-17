// audio_i2s.sv - MMIO-fed HDMI audio: 2048-entry x 32-bit dual-clock sample
// FIFO (write side clk_sys, from pvr_mmio's AUDIO_DATA register) drained by
// an I2S serializer on clk_audio.
//
// Sample format: [15:0] = LEFT, [31:16] = RIGHT, signed 16-bit PCM.
//
// Serializer output matches what minicast's setup_hdmi programs into the
// ADV7513 (standard I2S, 16-bit word length, 48 kHz): 64fs frame, LRCLK
// low = left, MSB first, data delayed one SCLK after each LRCLK edge,
// transitions on SCLK falling edges. Clocks come from a free-running
// divider of clk_audio (24.576 MHz): SCLK = /8 = 3.072 MHz, LRCLK = /512
// = 48 kHz - the same division the silent placeholder used, so the
// ADV7513 clocking is unchanged.
//
// One sample is popped per 48 kHz frame; an empty FIFO plays silence
// (zeros, no last-sample repeat). There is no flush: after a core reset
// queued samples simply drain within ~43ms worst case.
//
// CDC: standard async FIFO, gray-coded pointers through 2FF synchronizers
// in each direction. The project SDC already cuts pll_audio against the
// core clocks (exclusive clock groups), and gray coding makes the
// pointer hops safe with any skew. full/level are write-side views
// (pessimistic while the read side catches up), empty is the read-side
// view - all conservative in the safe direction.

module audio_i2s
(
	// write side (clk_sys)
	input  wire        wclk,
	input  wire        wr,            // push wdata; ignored while full
	input  wire [31:0] wdata,         // [15:0] left, [31:16] right
	output wire        full,
	output wire [11:0] level,         // samples queued, 0..2048

	// read side / I2S out (clk_audio = 24.576 MHz)
	input  wire        aclk,
	output wire        sclk,          // 3.072 MHz bit clock (64fs)
	output wire        lrclk,         // 48 kHz word clock, low = left
	output reg         sdata = 1'b0
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
	rgray_w1 <= rgray;
	rgray_w2 <= rgray_w1;
	if (wr && !full) begin
		mem[wbin[10:0]] <= wdata;
		wbin  <= wbin_next;
		wgray <= bin2gray(wbin_next);
	end
end

//////////////////////////////////////////////////////////////////////////
// Read side + I2S serializer (aclk)
//////////////////////////////////////////////////////////////////////////

reg [11:0] rbin     = 12'd0;
reg [11:0] rgray    = 12'd0;
reg [11:0] wgray_a1 = 12'd0;   // wgray -> aclk 2FF synchronizer
reg [11:0] wgray_a2 = 12'd0;

wire        empty     = (rgray == wgray_a2);
wire [11:0] rbin_next = rbin + 12'd1;

// free-running frame divider: [2] = SCLK, [8] = LRCLK, wraps every 512
reg [8:0] adiv = 9'd0;
assign sclk  = adiv[2];
assign lrclk = adiv[8];

wire [8:0] adiv_next = adiv + 9'd1;

reg [31:0] rdata_q = 32'd0;   // popped RAM word
reg        got     = 1'b0;    // rdata_q valid for the upcoming frame
reg [31:0] sample  = 32'd0;   // the frame currently on the wire

// upcoming SCLK slot (0..31 in each half) and half, after this divider tick
wire [4:0] slot = adiv_next[7:3];
wire       half = adiv_next[8];

wire [15:0] ch    = half ? sample[31:16] : sample[15:0];
wire  [4:0] bidx5 = 5'd16 - slot;                // slots 1..16 -> bits 15..0

always @(posedge aclk) begin
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

	// next frame's sample lands exactly on the LRCLK falling edge; slot 0
	// carries no data (I2S one-bit delay), so the swap is never audible
	if (adiv == 9'h1FF) sample <= got ? rdata_q : 32'd0;

	// data transitions on every SCLK falling edge (adiv[2:0] wraps 7 -> 0)
	if (adiv[2:0] == 3'b111)
		sdata <= (slot >= 5'd1 && slot <= 5'd16) ? ch[bidx5[3:0]] : 1'b0;
end

endmodule

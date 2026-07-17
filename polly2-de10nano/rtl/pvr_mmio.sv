// pvr_mmio.sv - hand-decoded Avalon-MM slave behind the HPS lightweight
// bridge (hps_lw_bridge). ARM-visible map, base 0xFF200000, 32-bit accesses
// only (writes with byteenable != 4'b1111 are ignored):
//
//   0xFF200000 - 0xFF201FFF  PVR register file window (WRITE ONLY).
//                            word address = offset[12:2], forwarded to the
//                            peel_core reg file write port. Reads return 0.
//   0xFF202000  VRAM_BASE    RW. Bits [31:24] = top byte of the 16MB-aligned
//                            VRAM base in DDR3; low bits ignored, read back
//                            as 0. Power-up 0x32000000.
//   0xFF202004  STATUS       RO. [0] = WORKING (0 = IDLE), [1] = DONE
//                            (sticky; cleared by GO and RESET).
//   0xFF202008  GO           WO. Any write kicks the region-array parse
//                            (1-clk go pulse), clears DONE, starts the
//                            frame cycle counter.
//   0xFF20200C  RESET        WO. Any write runs a full reset cycle on the
//                            PVR: reset held high for RST_CYCLES clocks.
//   0xFF202010  FRAME_CYCLES RO. clk_sys cycles from GO until DONE; resets
//                            on GO, holds after DONE.
//   0xFF202014  CLK          RW. [1:0] core clock select: 0=75, 1=90, 2=100,
//                            3=112.5 MHz. Switching pauses clk_sys briefly
//                            and pulses the core reset window; avoid other
//                            MMIO traffic for ~2us after writing.
//   0xFF202018  AUDIO_DATA   W: push one stereo sample ([15:0] left,
//                            [31:16] right, signed 16-bit PCM) into the
//                            2048-entry audio FIFO (audio_i2s -> HDMI I2S).
//                            While the FIFO is full, waitrequest stalls the
//                            write (the HPS store blocks) until the I2S side
//                            frees a slot - up to ~21us at 48 kHz.
//                            R: [11:0] samples currently queued (0..2048).
//   0xFF20201C  reserved (read 0, writes ignored).
//
// Single clock domain (clk_sys). waitrequest is low except for AUDIO_DATA
// writes with the FIFO full - every other access completes immediately;
// reads return data the following cycle.

module pvr_mmio
#(
	parameter [7:0]  VRAM_TOP_INIT = 8'h32,   // 0x32000000
	parameter        RST_CYCLES    = 256      // max 511
)
(
	input  wire        clk,           // clk_sys

	// Avalon-MM slave (from hps_lw_bridge); [1:0] unused: 32-bit access only
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire [20:0] avs_address,
	/* verilator lint_on UNUSEDSIGNAL */
	input  wire        avs_read,
	input  wire        avs_write,
	input  wire [31:0] avs_writedata,
	input  wire  [3:0] avs_byteenable,
	output reg  [31:0] avs_readdata      = 32'd0,
	output reg         avs_readdatavalid = 1'b0,
	output wire        avs_waitrequest,

	// PVR side
	output reg         pvr_wr    = 1'b0,   // reg file write pulse
	output reg  [12:0] pvr_addr  = 13'd0,
	output reg  [31:0] pvr_wdata = 32'd0,
	output reg         pvr_go    = 1'b0,   // 1-clk render kick
	output reg         pvr_rst   = 1'b0,   // stretched reset
	output reg   [7:0] vram_top  = VRAM_TOP_INIT,
	output reg   [1:0] clk_sel   = 2'd0,     // core clock select (75 MHz default)
	input  wire        pvr_done,             // render done (level or pulse)

	// audio FIFO write port (audio_i2s)
	output reg         aud_wr    = 1'b0,     // 1-clk push pulse
	output reg  [31:0] aud_wdata = 32'd0,
	input  wire        aud_full,
	input  wire [11:0] aud_level
);

// no size casts (Quartus Standard 17.0)
/* verilator lint_off WIDTHTRUNC */
localparam [8:0] RSTC = RST_CYCLES;
/* verilator lint_on WIDTHTRUNC */

wire wr32     = avs_write && (avs_byteenable == 4'b1111);
wire sel_regs = (avs_address[20:13] == 8'd0);     // 0x0000-0x1FFF
wire sel_cfg  = (avs_address[20:13] == 8'd1);     // 0x2000-0x3FFF
wire [2:0] cfg_word = avs_address[4:2];           // 0x2000..0x201C

// AUDIO_DATA is the only stalling access: hold waitrequest while the FIFO
// is full - and for the one cycle a just-accepted push (aud_wr) needs to
// reach the FIFO write pointer, so a back-to-back write can't be accepted
// against the stale full flag and get dropped. hps_lw_bridge keeps
// avs_write asserted, so the push (and the HPS's blocked store) completes
// on the first cycle with a free slot.
wire wr_audio  = wr32 && sel_cfg && (cfg_word == 3'd6);
wire aud_stall = aud_full || aud_wr;
assign avs_waitrequest = wr_audio && aud_stall;

reg  [8:0] rst_cnt   = 9'd0;
reg        busy      = 1'b0;
reg        done_stk  = 1'b0;
reg        done_q    = 1'b0;
reg [31:0] cycles    = 32'd0;

always @(posedge clk) begin
	pvr_wr <= 1'b0;
	pvr_go <= 1'b0;
	aud_wr <= 1'b0;

	// ---- writes ----
	if (wr32) begin
		if (sel_regs) begin
			// wr_addr is a 13-bit PVR BYTE offset (reg_file does its own >>2);
			// pass the byte address straight through, low 2 bits 0.
			pvr_addr  <= avs_address[12:0];
			pvr_wdata <= avs_writedata;
			pvr_wr    <= 1'b1;
		end
		else if (sel_cfg) case (cfg_word)
			3'd0: vram_top <= avs_writedata[31:24];        // VRAM_BASE
			3'd2: begin                                    // GO
				pvr_go   <= 1'b1;
				done_stk <= 1'b0;
				busy     <= 1'b1;
				cycles   <= 32'd0;
			end
			3'd3: begin                                    // RESET
				rst_cnt  <= RSTC;
				busy     <= 1'b0;
				done_stk <= 1'b0;
			end
			3'd5: clk_sel <= avs_writedata[1:0];           // CLK
			3'd6: if (!aud_stall) begin                    // AUDIO_DATA
				// wr32 stays asserted while waitrequest stalls the
				// transaction; !aud_stall is the acceptance cycle
				// (must mirror avs_waitrequest exactly), so exactly
				// one push per HPS store.
				aud_wr    <= 1'b1;
				aud_wdata <= avs_writedata;
			end
			default: ;                                     // STATUS/CYCLES/rsvd: RO
		endcase
	end

	// ---- reset stretcher ----
	pvr_rst <= (rst_cnt != 9'd0);
	if (rst_cnt != 9'd0) rst_cnt <= rst_cnt - 9'd1;

	// ---- frame cycle counter / done tracking ----
	if (busy) cycles <= cycles + 32'd1;

	done_q <= pvr_done;
	if (pvr_done & ~done_q) begin
		done_stk <= 1'b1;
		busy     <= 1'b0;
	end

	// ---- reads (registered, 1-cycle readdatavalid) ----
	avs_readdatavalid <= avs_read;
	avs_readdata      <= 32'd0;
	if (avs_read && sel_cfg) begin
		case (cfg_word)
			3'd0: avs_readdata <= {vram_top, 24'd0};       // VRAM_BASE
			3'd1: avs_readdata <= {30'd0, done_stk, busy}; // STATUS
			3'd4: avs_readdata <= cycles;                  // FRAME_CYCLES
			3'd5: avs_readdata <= {30'd0, clk_sel};        // CLK
			3'd6: avs_readdata <= {20'd0, aud_level};      // AUDIO_DATA level
			default: ;
		endcase
	end
end

endmodule

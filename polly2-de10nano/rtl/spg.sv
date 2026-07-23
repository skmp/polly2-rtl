// spg.sv - fixed-mode display controller, loosely modelled on the Dreamcast
// (HOLLY) spg, but generating the FINAL 1080p raster directly at the HDMI
// pixel clock. Replaces ascal on the HDMI path:
//
//  - 1920x1080 CEA-861 timing (2200 x 1125 totals, both syncs positive).
//    At a 148.352 MHz pixel clock this is 1080p59.94 (the DC VGA field
//    rate); at 148.5 MHz it is exactly 60.000 Hz.
//  - The 640-wide framebuffer in DDR3 is displayed pixel- and line-doubled
//    (2x nearest) as a 1280x960 window centred in the frame (x 320..1599,
//    y 60..1019 - the same window the stripped ascal used). fb_line_dbl
//    displays a 640x240 source at 4x vertically instead (FB_R_CTRL
//    fb_line_double / the 240p menu option); fb_pix_dbl a 320-wide source
//    at 4x horizontally (VO_CONTROL pixel_double) - the two compose.
//  - All four FB_R_CTRL fb_depth read formats, with refsw2 Present()
//    semantics (fb_concat appended below the 5/6-bit channels):
//      0: 0555 RGB, 2 bytes/px     1: 565 RGB, 2 bytes/px
//      2: 888 RGB packed, 3 bytes/px (incl. the odd/even byte-address
//         fetch quirk refsw2 models)
//      3: 0888 RGB, 4 bytes/px
//    fb_enable=0 blanks the game window (borders/bands unaffected).
//  - FB_R_SOF is honoured PER LINE: fb_base/fb_disp_half are re-sampled
//    for every source-line fetch request ("render base"), while the
//    line-to-line advance is a separately accumulated "render offset"
//    (0 at source line 0, +fb_stride per line). A mid-frame base change
//    therefore takes effect from the next requested line, with the offset
//    accumulation undisturbed - refsw2's continuous addr walk. The base is
//    adopted through a 2-sample stability filter (it originates in another
//    clock domain); the sub-beat byte offset of each line's base is kept
//    per line buffer for the read side.
//  - fb_split replicates the Dreamcast 32-bit-view VRAM layout (minicast's
//    pvr_map32 rule): FB 32-bit word W lives at DDR byte W*8, in the LOW
//    (fb_disp_half=0, bank 0) or HIGH (fb_disp_half=1, bank 1) 32-bit half
//    of each 64-bit word - physical byte = W*8 + bank*4 (half re-sampled
//    per line with the base, it is SOF bit 22). A line is then fetched at 2x the FB-view byte count (2x
//    overfetch - still trivial bandwidth). fb_stride stays in FB-view
//    bytes in both modes; the DDR advance doubles internally.
//  - Two optional border bands: 640x30 RGB565 LINEAR framebuffers (stride
//    fixed at 1280 bytes) displayed 2x-doubled as 1280x60, exactly filling
//    the top (lines 0..59) and bottom (lines 1020..1079) borders,
//    x-centred like the game window. Bands are host OSD surfaces: always
//    565 with MSB-replicated expansion, independent of the game fb_depth.
//    fb_top_base / fb_bot_base are DDR BYTE addresses, 128-byte aligned,
//    sampled once per frame at the start of vertical blanking (line 1080);
//    0 disables a band (black border).
//  - DDR access is a 128-bit Avalon read master, intended for the vbuf
//    port on sysmem_lite that ascal used to own (16-byte word addresses).
//    Fetches are beat-aligned: the FB base's low 4 bits (split: bit 3
//    only) become a byte offset applied on the read side, and a misaligned
//    base just costs one extra beat. Bursts are serialized: a new command
//    is issued only after every beat of the previous one has arrived
//    (deliberately conservative w.r.t. the real-DDR3 read-beat desync
//    behaviour seen on hardware). A request landing mid-fetch (severe
//    starvation) is queued, not lost.
//  - Two line buffers ("current" / "next"): while one source line is
//    displayed (two output lines), the next is burst-read into the other.
//    Prefetch slack is two output lines (~29.7 us) per line; worst case
//    (split 0888, misaligned) is 321 beats - still no DMA engine and no
//    tight arbiter deadline. Storage is four 32-bit banks of 512: the
//    line's raw FB-view bytes, beat-aligned (split-mode half-selection is
//    the only write-side transformation), FB 32-bit word N -> bank N[1:0],
//    address {buffer, N[9:2]}.
//  - Read side: a source pixel at FB-view byte b reads the two adjacent
//    32-bit words containing bytes b..b+3 (per-bank addresses form a
//    sliding 4-word window), funnels the four bytes down and converts per
//    fb_depth. Addresses are pre-computed one pixel ahead so the RAM sees
//    only registered addresses.
//
// All video outputs are registered and mutually aligned (2 clk latency
// from the internal counters). Border pixels are black. Byte 0 of each
// 32-bit FB word is the lowest FB address (little-endian), matching the
// peel_core 16bpp tile writeback.

module spg
#(
	// CEA-861 1080p timing
	parameter H_ACTIVE = 1920,
	parameter H_FP     = 88,
	parameter H_SYNC   = 44,
	parameter H_BP     = 148,   // H total 2200
	parameter V_ACTIVE = 1080,
	parameter V_FP     = 4,
	parameter V_SYNC   = 5,
	parameter V_BP     = 36,    // V total 1125
	// source framebuffer (doubled to SRC_W*2 x SRC_H*2 on screen)
	parameter SRC_W    = 640,
	parameter SRC_H    = 480
)
(
	input  wire        clk,          // 1080p pixel clock (148.352 / 148.5 MHz)
	input  wire        reset,        // video-domain reset

	// Framebuffer location. fb_base/fb_disp_half are sampled once PER LINE
	// (at the line's fetch request, through a 2-sample stability filter);
	// everything else once per frame at the top of the raster. fb_base is
	// a byte address; bits [3:0] (split: bit [3], [2:0] must be 0) select
	// the starting byte within its 16-byte beat. fb_stride is in FB-view
	// bytes, a multiple of 16.
	input  wire [31:0] fb_base,      // BYTE address of the top-left pixel
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire [13:0] fb_stride,    // FB-view BYTEs per source line (SRC_W * bytes/px)
	/* verilator lint_on UNUSEDSIGNAL */
	input  wire        fb_line_dbl,  // 240p source: 4x vertical instead of 2x
	input  wire        fb_pix_dbl,   // VO_CONTROL.pixel_double: 320-wide source, 4x horizontal
	input  wire        fb_split,     // Dreamcast split-VRAM layout (see header)
	input  wire        fb_disp_half, // split: which 32-bit half of each 64-bit word
	input  wire [1:0]  fb_depth,     // FB_R_CTRL.fb_depth: 0=0555 1=565 2=888 3=0888
	input  wire [2:0]  fb_concat,    // FB_R_CTRL.fb_concat (low bits of 5/6-bit channels)
	input  wire        fb_enable,    // FB_R_CTRL.fb_enable: 0 = game window black

	// Border bands (see header). BYTE addresses, 128-byte aligned, 0 = off;
	// sampled once per frame at the start of vertical blanking.
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire [31:0] fb_top_base,  // 640x30 linear RGB565 above the window
	input  wire [31:0] fb_bot_base,  // 640x30 linear RGB565 below the window
	/* verilator lint_on UNUSEDSIGNAL */

	// 128-bit Avalon read master (sysmem vbuf port), avl_clk domain
	input  wire         avl_clk,
	output reg          avl_read,
	output reg  [27:0]  avl_address,    // 16-byte word address
	output reg  [7:0]   avl_burstcount,
	input  wire         avl_waitrequest,
	input  wire [127:0] avl_readdata,
	input  wire         avl_readdatavalid,

	// Video out (registered, aligned; syncs active high)
	output reg  [7:0]  red,
	output reg  [7:0]  green,
	output reg  [7:0]  blue,
	output reg         hsync,
	output reg         vsync,
	output reg         de,           // full 1920x1080 active area
	output reg         vblank,       // output-raster vertical blank (ascal o_vbl)
	output reg         border,       // active raster but outside the image window (ascal o_brd)

	// Raster status / frame pacing (video domain)
	output reg  [9:0]  src_line,     // source line currently displayed
	output reg         vblank_in,    // 1-clk pulse: image window finished
	output reg         vblank_out,   // 1-clk pulse: image window starts
	output reg         underrun      // sticky: a line was displayed before its fetch finished
);

// NOTE: no SystemVerilog size casts anywhere in this file - Quartus
// Standard 17.0 does not support N'(expr).
/* verilator lint_off WIDTHTRUNC */
localparam [11:0] H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;
localparam [10:0] V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;
localparam [11:0] HS_BEG   = H_ACTIVE + H_FP;
localparam [11:0] HS_END   = H_ACTIVE + H_FP + H_SYNC;
localparam [10:0] VS_BEG   = V_ACTIVE + V_FP;
localparam [10:0] VS_END   = V_ACTIVE + V_FP + V_SYNC;
localparam [11:0] H_ACT    = H_ACTIVE;
localparam [10:0] V_ACT    = V_ACTIVE;
localparam [11:0] X0       = (H_ACTIVE - SRC_W*2)/2;        // 320
localparam [11:0] X1       = (H_ACTIVE - SRC_W*2)/2 + SRC_W*2; // 1600
localparam [10:0] Y0       = (V_ACTIVE - SRC_H*2)/2;        // 60
localparam [10:0] Y1       = (V_ACTIVE - SRC_H*2)/2 + SRC_H*2; // 1020

localparam        BURST_LEN = 16;        // 128-bit beats per burst (256 bytes)
localparam [7:0]  BC_FULL   = BURST_LEN; // full burstcount
localparam [4:0]  BB_FULL   = BURST_LEN; // full per-burst beat count
localparam [8:0]  B9_FULL   = BURST_LEN;
localparam [27:0] ADDR_STEP = BURST_LEN; // address advance per full burst

// border bands: 640x30 linear, stride 1280 bytes = 80 16-byte words/beats
localparam [10:0] BAND_ADV   = 11'd80;
localparam [8:0]  BAND_BEATS = 9'd80;

// fetch/display region encoding ({region, src line} keys the request dedup)
localparam [1:0] RGN_GAME = 2'd0;
localparam [1:0] RGN_TOP  = 2'd1;
localparam [1:0] RGN_BOT  = 2'd2;
/* verilator lint_on WIDTHTRUNC */

//////////////////////////////////////////////////////////////////////////
// Output raster counters
//////////////////////////////////////////////////////////////////////////

reg [11:0] hcnt = 12'd0;
reg [10:0] vcnt = 11'd0;

always @(posedge clk or posedge reset) begin
	if (reset) begin
		hcnt <= 12'd0;
		vcnt <= 11'd0;
	end
	else begin
		if (hcnt == H_TOTAL - 12'd1) begin
			hcnt <= 12'd0;
			vcnt <= (vcnt == V_TOTAL - 11'd1) ? 11'd0 : vcnt + 11'd1;
		end
		else hcnt <= hcnt + 12'd1;
	end
end

wire img_v = (vcnt >= Y0) && (vcnt < Y1);

// Per-frame latch of the quasi-static config (stable for the Avalon domain:
// the first fetch request is issued Y0-2 lines later). The BASE is not here
// - it rides in each line's request payload.
reg [10:0] adv_lat   = 11'd0;   // 16-byte words to advance per source line
reg        dbl_lat   = 1'b0;
reg        pd_lat    = 1'b0;
reg        split_lat = 1'b0;
reg  [1:0] dep_lat   = 2'd0;
reg  [2:0] cat_lat   = 3'd0;
reg        en_lat    = 1'b0;

// Band latches: sampled at the start of vertical blanking (line V_ACT), so
// they are stable before the top band's first request (2 lines before the
// raster wraps) and its display at line 0.
reg [27:0] top_base_lat = 28'd0;
reg [27:0] bot_base_lat = 28'd0;
reg        top_en_lat   = 1'b0;
reg        bot_en_lat   = 1'b0;

// line-doubling shift: output lines per source line = 2 (480) or 4 (240p)
wire [1:0] vshift = dbl_lat ? 2'd2 : 2'd1;

// Per-line base stability filter: {fb_disp_half, fb_base} originates in
// another clock domain and may change mid-frame; adopt a value only after
// it has been sampled identical on two consecutive clocks, so a request
// can never latch a torn word (writes settle in well under a line).
reg [32:0] fbs_q      = 33'd0;
reg [32:0] fbs_stable = 33'd0;

always @(posedge clk) begin
	fbs_q <= {fb_disp_half, fb_base};
	if (fbs_q == {fb_disp_half, fb_base}) fbs_stable <= fbs_q;
end

//////////////////////////////////////////////////////////////////////////
// Fetch requests (video domain -> Avalon domain)
//////////////////////////////////////////////////////////////////////////

// Two output lines ahead of the raster, decide which SOURCE line (of which
// region) will be needed and request it once. Buffer parity = source line
// LSB, so the line being written is never the line being displayed - this
// holds across region seams too (each region restarts at src 0 an even
// number of output lines after the previous region's last line began).
reg        req_toggle = 1'b0;
reg        req_sof    = 1'b0;   // first line of its region: reset the render offset
reg        req_buf    = 1'b0;
reg  [1:0] req_region = RGN_GAME;
reg [27:0] req_base   = 28'd0;  // render base: this line's fb_base, in beats
reg  [8:0] req_beats  = 9'd0;   // beats to fetch (game lines; bands use BAND_BEATS)
reg        req_half   = 1'b0;   // this line's fb_disp_half
reg [11:0] last_req   = 12'hFFF;   // {region, src}
reg  [1:0] cnt_req    = 2'd0;

// sub-beat byte offset of each buffer's line, for the read side
reg  [3:0] line_roff [0:1];
initial begin line_roff[0] = 4'd0; line_roff[1] = 4'd0; end

// wraps only for the top band, whose first request lands 2 lines before
// the raster does (V_TOTAL-2 -> line 0)
wire [10:0] y_look_raw = vcnt + 11'd2;
wire [10:0] y_look     = (y_look_raw >= V_TOTAL) ? y_look_raw - V_TOTAL
                                                 : y_look_raw;

wire        look_top  = (y_look < Y0) && top_en_lat;
wire        look_game = (y_look >= Y0) && (y_look < Y1);
wire        look_bot  = (y_look >= Y1) && (y_look < V_ACT) && bot_en_lat;
wire        look_in   = look_top || look_game || look_bot;
wire  [1:0] look_rgn  = look_top ? RGN_TOP : look_game ? RGN_GAME : RGN_BOT;
wire [10:0] look_rel  = look_top  ? y_look
                      : look_game ? y_look - Y0
                                  : y_look - Y1;
wire  [1:0] look_vsh  = look_game ? vshift : 2'd1;   // bands are always 2x
/* verilator lint_off UNUSEDSIGNAL */
wire [10:0] look_shf = look_rel >> look_vsh;
/* verilator lint_on UNUSEDSIGNAL */
wire  [9:0] look_src = look_shf[9:0];
wire [11:0] look_key = {look_rgn, look_src};

// game-line fetch length: whole beats covering the FB-view bytes of one
// line (raw layout doubles in split mode), +1 for the 888 packed quirk
// (one byte past SRC_W*3 can be read), +1 when the base is mid-beat
wire  [3:0] look_roff  = split_lat ? {1'b0, fbs_stable[3], 2'b00}
                                   : fbs_stable[3:0];
/* verilator lint_off WIDTHTRUNC */
wire  [8:0] bb_lin     = pd_lat
                       ? ((dep_lat == 2'd2) ? 9'd61          // 976 >= 961 bytes
                        : (dep_lat == 2'd3) ? SRC_W/8        // 80
                                            : SRC_W/16)      // 40
                       : ((dep_lat == 2'd2) ? 9'd121         // 1936 >= 1921 bytes
                        : (dep_lat == 2'd3) ? SRC_W/4        // 160
                                            : SRC_W/8);      // 80
/* verilator lint_on WIDTHTRUNC */
wire  [8:0] bb_geo     = split_lat ? {bb_lin[7:0], 1'b0} : bb_lin;
wire  [8:0] look_beats = bb_geo + {8'd0, look_roff != 4'd0};

always @(posedge clk or posedge reset) begin
	if (reset) begin
		req_toggle <= 1'b0;
		last_req   <= 12'hFFF;
		cnt_req    <= 2'd0;
	end
	else begin
		if (vcnt == 11'd0 && hcnt == 12'd0) begin
			// DDR bytes per line double in split mode (2 DDR bytes per FB byte)
			adv_lat   <= fb_split ? fb_stride[13:3] : {1'b0, fb_stride[13:4]};
			dbl_lat   <= fb_line_dbl;
			pd_lat    <= fb_pix_dbl;
			split_lat <= fb_split;
			dep_lat   <= fb_depth;
			cat_lat   <= fb_concat;
			en_lat    <= fb_enable;
		end

		if (vcnt == V_ACT && hcnt == 12'd0) begin
			top_base_lat <= fb_top_base[31:4];   // [6:4] zero: 128B aligned
			bot_base_lat <= fb_bot_base[31:4];
			top_en_lat   <= (fb_top_base[31:7] != 25'd0);
			bot_en_lat   <= (fb_bot_base[31:7] != 25'd0);
			last_req     <= 12'hFFF;
		end

		if (hcnt == 12'd0 && look_in && look_key != last_req) begin
			req_sof    <= (look_src == 10'd0);
			req_buf    <= look_src[0];
			req_region <= look_rgn;
			req_base   <= fbs_stable[31:4];
			req_half   <= fbs_stable[32];
			req_beats  <= look_beats;
			line_roff[look_src[0]] <= look_game ? look_roff : 4'd0;
			last_req   <= look_key;
			cnt_req    <= cnt_req + 2'd1;
			req_toggle <= ~req_toggle;   // payload above is stable when this lands
		end
	end
end

//////////////////////////////////////////////////////////////////////////
// Avalon fetch FSM (avl_clk domain)
//////////////////////////////////////////////////////////////////////////

reg  [2:0] rt_sync     = 3'd0;
reg  [1:0] rst_sync    = 2'd0;
reg        fetching    = 1'b0;
reg        pending     = 1'b0;   // request arrived while still fetching
reg [27:0] line_off    = 28'd0;  // render offset: beats from the base, this region
reg  [8:0] w           = 9'd0;   // beat index within the line
reg  [8:0] beats_left  = 9'd0;   // beats still expected for the line
reg  [4:0] burst_beats = 5'd0;   // beats still expected for the current burst
reg        done_toggle = 1'b0;
reg        cur_split   = 1'b0;   // this fetch's layout: only game can be split
reg        cur_half    = 1'b0;   // ... and only game selects a 32-bit half

wire req_edge = rt_sync[2] ^ rt_sync[1];
wire req_game = (req_region == RGN_GAME);

// requests never interleave regions: line_off accumulates within one region
// and req_sof zeroes it at the region's first line. Bands are still
// base+offset - only their base is the per-frame band latch.
wire [27:0] band_base = (req_region == RGN_TOP) ? top_base_lat : bot_base_lat;

always @(posedge avl_clk) begin : fetch_fsm
	reg [27:0] na;
	reg [27:0] no;
	reg  [8:0] rem;

	// verilator lint_off SYNCASYNCNET
	rst_sync <= {rst_sync[0], reset};
	// verilator lint_on SYNCASYNCNET
	rt_sync  <= {rt_sync[1:0], req_toggle};

	if (avl_read && !avl_waitrequest) avl_read <= 1'b0;   // command accepted

	if (req_edge && fetching) pending <= 1'b1;

	if ((req_edge || pending) && !fetching) begin
		pending        <= 1'b0;
		no = req_sof ? 28'd0
		             : line_off + {17'd0, req_game ? adv_lat : BAND_ADV};
		line_off       <= no;
		na = (req_game ? req_base : band_base) + no;
		avl_address    <= na;
		avl_burstcount <= BC_FULL;         // every fetch is >= 80 beats: first burst is full
		avl_read       <= 1'b1;
		burst_beats    <= BB_FULL;
		beats_left     <= req_game ? req_beats : BAND_BEATS;
		cur_split      <= req_game & split_lat;
		cur_half       <= req_half;
		w              <= 9'd0;
		fetching       <= 1'b1;
	end
	else if (fetching && avl_readdatavalid) begin
		w           <= w + 9'd1;
		beats_left  <= beats_left - 9'd1;
		burst_beats <= burst_beats - 5'd1;
		if (burst_beats == 5'd1) begin                    // last beat of this burst
			rem = beats_left - 9'd1;
			if (rem == 9'd0) begin
				fetching    <= 1'b0;
				done_toggle <= ~done_toggle;
			end
			else begin
				// every burst except a shorter final one is BURST_LEN long
				avl_address    <= avl_address + ADDR_STEP;
				avl_burstcount <= (rem >= B9_FULL) ? BC_FULL : rem[7:0];
				burst_beats    <= (rem >= B9_FULL) ? BB_FULL : rem[4:0];
				avl_read       <= 1'b1;
			end
		end
	end

	if (rst_sync[1]) begin
		fetching <= 1'b0;
		avl_read <= 1'b0;
		pending  <= 1'b0;
	end
end

//////////////////////////////////////////////////////////////////////////
// Line buffers: four 32-bit banks of 512 (2 buffers x 161 beat-words),
// dual clock. The stored stream is the line's raw FB-view bytes starting
// at its beat-aligned fetch address: FB-view 32-bit word N of the stream
// -> bank N[1:0], address {buffer, N[9:2]}.
//
// Write side, beat w (128 bits): the stream words in this beat are
//   linear: n = 4w + j, j = 0..3, data = beat[32j +: 32]
//   split : n = 2w + h, h = 0..1, data = the selected 32-bit half of
//           beat[64h +: 64]
// (No head/tail trimming: a misaligned base's padding bytes are stored
// and skipped by the read side's byte offset.)
//////////////////////////////////////////////////////////////////////////

wire [10:0] base_n = cur_split ? {1'b0, w, 1'b0} : {w, 2'b00};

wire  [9:0] w0_pre;   // display-side window word (declared ahead of use)
wire        rbuf;
wire [31:0] rq [0:3];

generate
genvar gb;
for (gb = 0; gb < 4; gb = gb + 1) begin : bank
	reg [31:0] mem [0:511];
	reg  [8:0] radr = 9'd0;
	reg [31:0] q = 32'd0;

	// candidate offset for this bank: (gb - base_n) mod 4
	/* verilator lint_off WIDTHTRUNC */
	localparam [1:0] GB = gb;
	/* verilator lint_on WIDTHTRUNC */
	wire  [1:0] o2   = GB - base_n[1:0];
	wire        ok   = cur_split ? (o2 < 2'd2) : 1'b1;
	wire [10:0] n    = base_n + {9'd0, o2};

	wire [63:0] h64  = o2[0] ? avl_readdata[127:64] : avl_readdata[63:0];
	wire [31:0] w32  = o2[1] ? (o2[0] ? avl_readdata[127:96] : avl_readdata[95:64])
	                         : (o2[0] ? avl_readdata[63:32]  : avl_readdata[31:0]);
	// pvr_map32: bank 0 (half=0) = LOW 32 bits, bank 1 = HIGH
	wire [31:0] wd   = cur_split ? (cur_half ? h64[63:32] : h64[31:0]) : w32;

	always @(posedge avl_clk) begin
		if (fetching && avl_readdatavalid && ok) mem[{req_buf, n[9:2]}] <= wd;
	end

	// read side: this bank holds the unique word of the sliding window
	// w0..w0+3 whose index is GB mod 4 - one address bump when GB has
	// already wrapped past w0 (constantly false for bank 3, by design)
	/* verilator lint_off CMPCONST */
	wire bump = (GB < w0_pre[1:0]);
	/* verilator lint_on CMPCONST */
	always @(posedge clk) begin
		radr <= {rbuf, w0_pre[9:2] + (bump ? 8'd1 : 8'd0)};
		q    <= mem[radr];
	end
	assign rq[gb] = q;
end
endgenerate

//////////////////////////////////////////////////////////////////////////
// Display read path (3-stage: address, RAM read, byte funnel + depth
// convert). Addresses are computed for hcnt+1 so the RAMs see registered
// addresses only; RGB still emerges 2 clocks after the counters, and
// syncs/de/border are piped by 2 to stay aligned.
//////////////////////////////////////////////////////////////////////////

// active display region this line: game window or one of the border bands
wire        top_v = (vcnt < Y0) && top_en_lat;
wire        bot_v = (vcnt >= Y1) && (vcnt < V_ACT) && bot_en_lat;
wire        band_v = top_v || bot_v;

wire [10:0] y_rel   = vcnt - Y0;             // game-relative (underrun check)
wire [10:0] d_rel   = top_v ? vcnt : bot_v ? vcnt - Y1 : y_rel;
wire  [1:0] d_vsh   = band_v ? 2'd1 : vshift;
/* verilator lint_off UNUSEDSIGNAL */
wire [10:0] y_shf   = d_rel >> d_vsh;
wire [11:0] x_pre   = hcnt + 12'd1 - X0;     // lookahead: pixel needed next clk
/* verilator lint_on UNUSEDSIGNAL */
wire  [9:0] src_cur = y_shf[9:0];
assign      rbuf    = src_cur[0];

// FB-view byte address of the lookahead pixel within the stored stream:
// roff (the line base's sub-beat offset) + n * bytes-per-pixel, with the
// packed-888 quirk: pixel at even FB addr reads bytes addr+1..addr+3, at
// odd FB addr bytes addr-1..addr+1 (refsw2 Present) - so +-1 by the
// parity of (base + 3n), which is roff[0] ^ n[0].
// /2: source pixel 0..639; pixel_double game lines: /4, source 0..319
// (bands are always 640 wide at 2x)
wire  [9:0] n_pre    = (pd_lat && !band_v) ? x_pre[11:2] : x_pre[10:1];
wire  [1:0] disp_dep = band_v ? 2'd1 : dep_lat;   // bands read as 16bpp
wire  [3:0] roff_d   = band_v ? 4'd0 : line_roff[rbuf];
wire        par24    = roff_d[0] ^ n_pre[0];
wire [11:0] b_pre =
	((disp_dep == 2'd2) ? ({1'b0, n_pre, 1'b0} + {2'b00, n_pre}
	                       + (par24 ? 12'hFFF : 12'd1))    // 3n +- 1
	:(disp_dep == 2'd3) ? {n_pre, 2'b00}                   // 4n
	                    : {1'b0, n_pre, 1'b0})             // 2n
	+ {8'd0, roff_d};
assign w0_pre = b_pre[11:2];

wire        img_h   = (hcnt >= X0) && (hcnt < X1);

wire de_c  = (hcnt < H_ACT) && (vcnt < V_ACT);
wire hs_c  = (hcnt >= HS_BEG) && (hcnt < HS_END);
// VS edges must coincide with the HS leading edge (CEA-861; same equation
// as ascal's o_vsv): rise at HS_BEG of line VS_BEG, fall at HS_BEG of line
// VS_END. Toggling at hcnt==0 instead puts the VS edge 2008 px before HS,
// which some HDMI sinks reject as an unsupported mode.
wire vs_c  = (vcnt == VS_BEG && hcnt >= HS_BEG) ||
             (vcnt >  VS_BEG && vcnt <  VS_END) ||
             (vcnt == VS_END && hcnt <  HS_BEG);
wire vbl_c = (vcnt >= V_ACT);
wire img_c = img_h && (img_v || band_v);

reg [1:0] s1_w0lo = 2'd0, s2_w0lo = 2'd0;   // window rotation, piped with the RAM
reg [1:0] s1_blo  = 2'd0, s2_blo  = 2'd0;   // byte offset within the window
reg [4:0] pipe1   = 5'd0;   // {img, de, hs, vs, vbl}

always @(posedge clk) begin
	// stage 0/1 companions of the RAM pipeline in the generate above
	s1_w0lo <= w0_pre[1:0];
	s1_blo  <= b_pre[1:0];
	s2_w0lo <= s1_w0lo;
	s2_blo  <= s1_blo;
	pipe1   <= {img_c, de_c, hs_c, vs_c, vbl_c};

	// stage 2: rotate the window, funnel the pixel's bytes down, convert.
	// disp_dep/cat_lat/en_lat/band_v are line-constant, so using them 2
	// clocks "late" is safe (the affected edge pixels are border-black).
	begin : lane_mux
		reg [31:0] wlo, whi;
		reg [63:0] s64;
		reg [31:0] p32;
		reg [15:0] p16;
		reg  [7:0] r8, g8, b8;
		wlo = rq[s2_w0lo];
		whi = rq[s2_w0lo + 2'd1];
		s64 = {whi, wlo} >> {s2_blo, 3'b000};
		p32 = s64[31:0];
		p16 = p32[15:0];
		if (band_v) begin                    // bands: 565, MSB-replicated
			r8 = {p16[15:11], p16[15:13]};
			g8 = {p16[10:5],  p16[10:9]};
			b8 = {p16[4:0],   p16[4:2]};
		end
		else case (dep_lat)
			2'd0: begin                      // 0555, fb_concat appended
				r8 = {p16[14:10], cat_lat};
				g8 = {p16[9:5],   cat_lat};
				b8 = {p16[4:0],   cat_lat};
			end
			2'd1: begin                      // 565, fb_concat appended
				r8 = {p16[15:11], cat_lat};
				g8 = {p16[10:5],  cat_lat[2:1]};
				b8 = {p16[4:0],   cat_lat};
			end
			default: begin                   // 888 packed / 0888: R,G,B = bytes 2,1,0
				r8 = p32[23:16];
				g8 = p32[15:8];
				b8 = p32[7:0];
			end
		endcase
		if (pipe1[4] && (band_v || en_lat)) begin
			red   <= r8;
			green <= g8;
			blue  <= b8;
		end
		else begin
			red   <= 8'd0;
			green <= 8'd0;
			blue  <= 8'd0;
		end
	end
	de     <= pipe1[3];
	hsync  <= pipe1[2];
	vsync  <= pipe1[1];
	vblank <= pipe1[0];
	border <= pipe1[3] & ~pipe1[4];
end

//////////////////////////////////////////////////////////////////////////
// Raster status, frame pacing pulses, underrun detect
//////////////////////////////////////////////////////////////////////////

reg [2:0] dt_sync  = 3'd0;
reg [1:0] cnt_done = 2'd0;

always @(posedge clk or posedge reset) begin
	if (reset) begin
		dt_sync    <= 3'd0;
		cnt_done   <= 2'd0;
		underrun   <= 1'b0;
		vblank_in  <= 1'b0;
		vblank_out <= 1'b0;
		src_line   <= 10'd0;
	end
	else begin
		dt_sync <= {dt_sync[1:0], done_toggle};
		if (dt_sync[2] ^ dt_sync[1]) cnt_done <= cnt_done + 2'd1;

		src_line <= img_v ? src_cur : 10'd0;

		vblank_in  <= (vcnt == Y1 && hcnt == 12'd0);
		vblank_out <= (vcnt == Y0 && hcnt == 12'd0);

		// Just before the window pixels of the FIRST output line of each
		// source line: the fetch for this line (issued 2 output lines ago)
		// must have completed; only the next line's fetch may be in flight.
		if (img_v && hcnt == X0 - 12'd4 && y_rel[0] == 1'b0
		    && (cnt_req - cnt_done) >= 2'd2) underrun <= 1'b1;
	end
end

endmodule

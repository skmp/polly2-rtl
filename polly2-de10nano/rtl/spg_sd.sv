// Native-standard-definition RGB scanout for DreamSTer.
//
// The raster runs from a 27 MHz clock.  Horizontal timing is expressed in
// twice the 13.5 MHz BT.601 sample rate, which gives an exact half-line for
// both 525-line (858 clocks) and 625-line (864 clocks) systems.  Composite
// sync includes six pre-equalising, six serration and six post-equalising
// half-lines.  Interlaced fields contain an odd number of half-lines, so
// field two is naturally displaced by half a line.  The progressive modes
// restart with field-one phase and are the usual "240p/288p" CRT timings.
//
// A 640-pixel Dreamcast framebuffer is centred in the 720-pixel active
// interval.  PAL additionally centres the 480/240-line game image inside
// the 576/288-line active interval.  Interlaced output walks every other
// source line; native interlace selects SOF1/SOF2, while 480p-to-480i uses
// SOF1 and SOF1+one-line for the two fields.

module spg_sd
#(
	parameter SRC_W = 640
)
(
	input  wire        clk,
	input  wire        reset,

	input  wire [31:0] fb_base1,
	input  wire [31:0] fb_base2,
	input  wire [13:0] fb_stride,
	input  wire        fb_pix_dbl,
	input  wire        fb_split,
	input  wire        fb_disp_half1,
	input  wire        fb_disp_half2,
	input  wire [1:0]  fb_depth,
	input  wire [2:0]  fb_concat,
	input  wire        fb_enable,

	input  wire        mode_pal,
	input  wire        mode_interlace,
	input  wire        mode_native_interlace,

	input  wire         avl_clk,
	output reg          avl_read,
	output reg  [27:0]  avl_address,
	output reg  [7:0]   avl_burstcount,
	input  wire         avl_waitrequest,
	input  wire [127:0] avl_readdata,
	input  wire         avl_readdatavalid,

	output reg  [7:0]  red,
	output reg  [7:0]  green,
	output reg  [7:0]  blue,
	output reg         hsync,       // active-high composite sync
	output reg         vsync,       // field-sync indication (IRQ/debug)
	output reg         de,
	output reg         vblank,
	output reg         border,
	output reg         field,
	output reg  [9:0]  src_line,
	output reg         vblank_in,
	output reg         vblank_out,
	output reg         underrun
);

localparam [7:0]  BURST_LEN = 8'd16;
localparam [4:0]  BURST_BEATS = 5'd16;
localparam [27:0] BURST_STEP = 28'd16;

// ---------------------------------------------------------------------
// Raster and frame-boundary mode latching
// ---------------------------------------------------------------------

reg [10:0] scnt     = 11'd0; // clock within a half-line
reg [9:0]  field_hl = 10'd0; // half-line within this field/frame
reg        pal_lat  = 1'b0;
reg        ilace_lat = 1'b1;
reg        native_lat = 1'b0;
reg        blank_field = 1'b1;

wire [10:0] half_ticks = pal_lat ? 11'd864 : 11'd858;
wire [9:0]  last_half  = pal_lat ? 10'd624 : 10'd524;
wire        half_end   = (scnt == half_ticks - 11'd1);
wire        field_end  = half_end && (field_hl == last_half);
wire        frame_end  = field_end && (!ilace_lat || field);

always @(posedge clk or posedge reset) begin
	if (reset) begin
		scnt        <= 11'd0;
		field_hl    <= 10'd0;
		field       <= 1'b0;
		pal_lat     <= 1'b0;
		ilace_lat   <= 1'b1;
		native_lat  <= 1'b0;
		blank_field <= 1'b1;
	end
	else if (half_end) begin
		scnt <= 11'd0;
		if (field_hl == last_half) begin
			field_hl <= 10'd0;
			if (ilace_lat && !field) begin
				field       <= 1'b1;
				blank_field <= 1'b0;
			end
			else begin
				field <= 1'b0;
				blank_field <= (pal_lat != mode_pal) ||
				               (ilace_lat != mode_interlace);
				pal_lat    <= mode_pal;
				ilace_lat  <= mode_interlace;
				native_lat <= mode_native_interlace;
			end
		end
		else field_hl <= field_hl + 10'd1;
	end
	else scnt <= scnt + 11'd1;
end

// Horizontal origin is the leading edge of sync.  Each complete scan line
// consists of two half-lines.  PAL and NTSC use their BT.601 porch widths.
// Field two begins one half-line later than field one.  Keep the ordinary
// horizontal-sync grid continuous across that boundary: resetting field_hl
// alone would otherwise restart field two on the wrong half-line phase and
// make a CRT's horizontal PLL slew back into lock over the first visible
// lines (the characteristic folded top edge).
wire        half_phase = field_hl[0] ^ (ilace_lat && field);
wire [11:0] hfull = half_phase ? {1'b0, scnt} + {1'b0, half_ticks}
	                             : {1'b0, scnt};
// field_hl is local to each field, but field two starts halfway through the
// continuous line grid.  Shift its display coordinate back by one half-line
// so a physical scanline always pairs left and right halves from the same
// source line.  Keep the raw coordinate for the equalisation/serration train.
wire [10:0] raster_hl_ext = {1'b0, field_hl} -
	                         ((ilace_lat && field) ? 11'd1 : 11'd0);
wire [9:0] raster_hl = raster_hl_ext[9:0];
wire [11:0] hs_w  = pal_lat ? 12'd128 : 12'd126;
wire [11:0] eq_w  = pal_lat ? 12'd64  : 12'd63;
wire [11:0] serr_w = half_ticks - hs_w;
wire [11:0] act_x0 = pal_lat ? 12'd264 : 12'd246;
wire [11:0] game_x0 = act_x0 + 12'd80;
wire [11:0] game_x1 = game_x0 + 12'd1280;
wire [11:0] act_x1  = act_x0 + 12'd1440;

wire [9:0] act_y0_hl  = pal_lat ? 10'd48  : 10'd44;
wire [9:0] act_y1_hl  = pal_lat ? 10'd624 : 10'd524;
wire [9:0] game_y0_hl = pal_lat ? 10'd96  : 10'd44;
wire [9:0] game_y1_hl = game_y0_hl + 10'd480;

wire pre_eq  = (field_hl < 10'd6);
wire serrate = (field_hl >= 10'd6) && (field_hl < 10'd12);
wire post_eq = (field_hl >= 10'd12) && (field_hl < 10'd18);
wire csync_c = ((pre_eq || post_eq) && ({1'b0, scnt} < eq_w)) ||
	             (serrate && ({1'b0, scnt} < serr_w)) ||
	             (!pre_eq && !serrate && !post_eq && !half_phase &&
	              ({1'b0, scnt} < hs_w));
wire vs_c = (field_hl < 10'd18);

wire img_v = (raster_hl >= game_y0_hl) && (raster_hl < game_y1_hl);
wire de_v  = (raster_hl >= act_y0_hl) && (raster_hl < act_y1_hl);
wire [9:0] field_line = (raster_hl - game_y0_hl) >> 1;
wire [9:0] source_line = ilace_lat ? ({field_line[8:0], 1'b0} + field)
	                                  : field_line;

// ---------------------------------------------------------------------
// Framebuffer configuration and per-line base capture
// ---------------------------------------------------------------------

reg [10:0] adv_lat = 11'd0; // physical 16-byte beats per source line
reg        pd_lat = 1'b0;
reg        split_lat = 1'b0;
reg [1:0]  dep_lat = 2'd0;
reg [2:0]  cat_lat = 3'd0;
reg        en_lat = 1'b0;

reg [65:0] fbs_q = 66'd0;
reg [65:0] fbs_stable = 66'd0;
reg [31:0] base1_lat = 32'd0;
reg [31:0] base2_lat = 32'd0;
reg        half1_lat = 1'b0;
reg        half2_lat = 1'b0;
always @(posedge clk) begin
	fbs_q <= {fb_disp_half2, fb_base2, fb_disp_half1, fb_base1};
	if (fbs_q == {fb_disp_half2, fb_base2, fb_disp_half1, fb_base1})
		fbs_stable <= fbs_q;
end

always @(posedge clk) begin
	if (frame_end) begin
		adv_lat   <= fb_split ? fb_stride[13:3] : {1'b0, fb_stride[13:4]};
		pd_lat    <= fb_pix_dbl;
		split_lat <= fb_split;
		dep_lat   <= fb_depth;
		cat_lat   <= fb_concat;
		en_lat    <= fb_enable;
		base1_lat <= fbs_stable[31:0];
		half1_lat <= fbs_stable[32];
		base2_lat <= fbs_stable[64:33];
		half2_lat <= fbs_stable[65];
	end
end

// ---------------------------------------------------------------------
// Line requests: one scan line ahead, video clock -> Avalon clock.  With two
// alternating line buffers, requesting two lines ahead would overwrite the
// buffer currently being scanned before reaching the right side of the line.
// ---------------------------------------------------------------------

wire [10:0] look_hl_ext = raster_hl_ext + 11'd2;
wire        look_game = (look_hl_ext >= {1'b0, game_y0_hl}) &&
	                      (look_hl_ext <  {1'b0, game_y1_hl});
wire [9:0] look_fline = (look_hl_ext[9:0] - game_y0_hl) >> 1;
wire [10:0] look_key = {field, look_fline};

wire [3:0] look_roff1 = split_lat ? {1'b0, base1_lat[3], 2'b00}
	                               : base1_lat[3:0];
wire [3:0] look_roff2 = split_lat ? {1'b0, base2_lat[3], 2'b00}
	                               : base2_lat[3:0];
wire       use_sof2 = ilace_lat && field && native_lat;
wire [3:0] look_roff = use_sof2 ? look_roff2 : look_roff1;

wire [8:0] beats_linear = pd_lat
	? ((dep_lat == 2'd2) ? 9'd60 : (dep_lat == 2'd3) ? 9'd80 : 9'd40)
	: ((dep_lat == 2'd2) ? 9'd120 : (dep_lat == 2'd3) ? 9'd160 : 9'd80);
wire [8:0] beats_geo = split_lat ? {beats_linear[7:0], 1'b0} : beats_linear;
wire [8:0] look_beats = beats_geo + {8'd0, look_roff != 4'd0};

reg        req_toggle = 1'b0;
reg        req_sof = 1'b0;
reg        req_buf = 1'b0;
reg [27:0] req_base = 28'd0;
reg [10:0] req_adv = 11'd0;
reg [8:0]  req_beats = 9'd0;
reg        req_half = 1'b0;
reg [10:0] last_req = 11'h7ff;
reg [1:0]  cnt_req = 2'd0;
reg [3:0]  line_roff [0:1];
initial begin line_roff[0] = 4'd0; line_roff[1] = 4'd0; end

reg        look_game_r = 1'b0;
reg [10:0] look_key_r = 11'h7ff;
reg [9:0]  look_fline_r = 10'd0;
reg [3:0]  look_roff_r = 4'd0;
reg [8:0]  look_beats_r = 9'd0;
always @(posedge clk) begin
	look_game_r  <= look_game;
	look_key_r   <= look_key;
	look_fline_r <= look_fline;
	look_roff_r  <= look_roff;
	look_beats_r <= look_beats;
end

always @(posedge clk or posedge reset) begin
	if (reset) begin
		req_toggle <= 1'b0;
		last_req   <= 11'h7ff;
		cnt_req    <= 2'd0;
	end
	else begin
		if (field_hl == 10'd0 && scnt == 11'd0) last_req <= 11'h7ff;
		if (scnt == 11'd2 && look_game_r && look_key_r != last_req) begin
			req_sof   <= (look_fline_r == 10'd0);
			req_buf   <= look_fline_r[0];
			req_adv   <= ilace_lat ? {adv_lat[9:0], 1'b0} : adv_lat;
			req_beats <= look_beats_r;
			if (use_sof2) begin
				req_base <= base2_lat[31:4];
				req_half <= half2_lat;
			end
			else begin
				// A progressive full-resolution source has no SOF2 field;
				// field two begins one source stride after SOF1.
				req_base <= base1_lat[31:4] +
				            ((ilace_lat && field && !native_lat) ? adv_lat : 11'd0);
				req_half <= half1_lat;
			end
			line_roff[look_fline_r[0]] <= look_roff_r;
			last_req   <= look_key_r;
			cnt_req    <= cnt_req + 2'd1;
			req_toggle <= ~req_toggle;
		end
	end
end

// ---------------------------------------------------------------------
// Serialized Avalon fetcher
// ---------------------------------------------------------------------

reg [2:0] rt_sync = 3'd0;
reg [1:0] rst_sync = 2'd0;
reg       fetching = 1'b0;
reg       pending = 1'b0;
reg [27:0] line_off = 28'd0;
reg [8:0] w = 9'd0;
reg [8:0] beats_left = 9'd0;
reg [4:0] burst_left = 5'd0;
reg       done_toggle = 1'b0;
reg       cur_split = 1'b0;
reg       cur_half = 1'b0;
reg       cur_buf = 1'b0;

wire req_edge = rt_sync[2] ^ rt_sync[1];

always @(posedge avl_clk) begin : fetch_fsm
	reg [27:0] next_off;
	reg [8:0] rem;
	rst_sync <= {rst_sync[0], reset};
	rt_sync  <= {rt_sync[1:0], req_toggle};

	if (avl_read && !avl_waitrequest) avl_read <= 1'b0;
	if (req_edge && fetching) pending <= 1'b1;

	if ((req_edge || pending) && !fetching) begin
		pending    <= 1'b0;
		next_off  = req_sof ? 28'd0 : line_off + {17'd0, req_adv};
		line_off  <= next_off;
		avl_address    <= req_base + next_off;
		avl_burstcount <= BURST_LEN;
		avl_read       <= 1'b1;
		burst_left     <= BURST_BEATS;
		beats_left     <= req_beats;
		cur_split      <= split_lat;
		cur_half       <= req_half;
		cur_buf        <= req_buf;
		w              <= 9'd0;
		fetching       <= 1'b1;
	end
	else if (fetching && avl_readdatavalid) begin
		w           <= w + 9'd1;
		beats_left  <= beats_left - 9'd1;
		burst_left  <= burst_left - 5'd1;
		if (burst_left == 5'd1) begin
			rem = beats_left - 9'd1;
			if (rem == 9'd0) begin
				fetching    <= 1'b0;
				done_toggle <= ~done_toggle;
			end
			else begin
				avl_address    <= avl_address + BURST_STEP;
				avl_burstcount <= (rem >= 9'd16) ? 8'd16 : rem[7:0];
				burst_left     <= (rem >= 9'd16) ? 5'd16 : rem[4:0];
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

// ---------------------------------------------------------------------
// Two dual-clock line buffers, four 32-bit banks
// ---------------------------------------------------------------------

wire [10:0] base_n = cur_split ? {1'b0, w, 1'b0} : {w, 2'b00};
wire [9:0] w0_pre;
wire       rbuf;
wire [31:0] rq [0:3];

generate
genvar gb;
for (gb = 0; gb < 4; gb = gb + 1) begin : bank
	reg [31:0] mem [0:511];
	reg [8:0] radr = 9'd0;
	reg [31:0] q = 32'd0;
	localparam [1:0] GB = 2'(gb);
	wire [1:0] o2 = GB - base_n[1:0];
	wire ok = cur_split ? (o2 < 2'd2) : 1'b1;
	wire [10:0] n = base_n + {9'd0, o2};
	wire [63:0] h64 = o2[0] ? avl_readdata[127:64] : avl_readdata[63:0];
	wire [31:0] w32 = o2[1] ? (o2[0] ? avl_readdata[127:96] : avl_readdata[95:64])
	                              : (o2[0] ? avl_readdata[63:32]  : avl_readdata[31:0]);
	wire [31:0] wd = cur_split ? (cur_half ? h64[63:32] : h64[31:0]) : w32;
	always @(posedge avl_clk)
		if (fetching && avl_readdatavalid && ok) mem[{cur_buf, n[9:2]}] <= wd;
	/* verilator lint_off CMPCONST */
	wire bump = (GB < w0_pre[1:0]);
	/* verilator lint_on CMPCONST */
	always @(posedge clk) begin
		radr <= {rbuf, w0_pre[9:2] + (bump ? 8'd1 : 8'd0)};
		q <= mem[radr];
	end
	assign rq[gb] = q;
end
endgenerate

// ---------------------------------------------------------------------
// Pixel read, conversion and aligned sync pipeline
// ---------------------------------------------------------------------

wire [11:0] x_pre = hfull + 12'd2 - game_x0;
wire [9:0] n_pre = pd_lat ? x_pre[11:2] : x_pre[10:1];
reg [11:0] b_pre_r = 12'd0;
reg [3:0] roff_r = 4'd0;
reg       rbuf_r = 1'b0;
always @(posedge clk) begin
	roff_r <= line_roff[field_line[0]];
	rbuf_r <= field_line[0];
	b_pre_r <= ((dep_lat == 2'd2) ? ({1'b0, n_pre, 1'b0} + {2'b00, n_pre})
	          : (dep_lat == 2'd3) ? {n_pre, 2'b00}
	                              : {1'b0, n_pre, 1'b0}) + {8'd0, roff_r};
end
assign rbuf = rbuf_r;
assign w0_pre = b_pre_r[11:2];

wire img_h = (hfull >= game_x0) && (hfull < game_x1);
wire de_h  = (hfull >= act_x0) && (hfull < act_x1);
wire img_c = img_h && img_v && !blank_field;
wire de_c  = de_h && de_v;
wire vbl_c = !de_v;

reg [1:0] s1_w0lo = 2'd0, s2_w0lo = 2'd0;
reg [1:0] s1_blo = 2'd0, s2_blo = 2'd0;
reg [4:0] pipe1 = 5'd0; // img,de,csync,vsync,vblank

always @(posedge clk) begin
	s1_w0lo <= w0_pre[1:0];
	s1_blo  <= b_pre_r[1:0];
	s2_w0lo <= s1_w0lo;
	s2_blo  <= s1_blo;
	pipe1   <= {img_c, de_c, csync_c, vs_c, vbl_c};

	begin : lane_mux
		reg [31:0] wlo, whi;
		reg [63:0] s64;
		reg [31:0] p32;
		reg [15:0] p16;
		reg [7:0] r8, g8, b8;
		wlo = rq[s2_w0lo];
		whi = rq[s2_w0lo + 2'd1];
		s64 = {whi, wlo} >> {s2_blo, 3'b000};
		p32 = s64[31:0];
		p16 = p32[15:0];
		case (dep_lat)
			2'd0: begin
				r8 = {p16[14:10], cat_lat};
				g8 = {p16[9:5],   cat_lat};
				b8 = {p16[4:0],   cat_lat};
			end
			2'd1: begin
				r8 = {p16[15:11], cat_lat};
				g8 = {p16[10:5],  cat_lat[2:1]};
				b8 = {p16[4:0],   cat_lat};
			end
			default: begin
				r8 = p32[23:16];
				g8 = p32[15:8];
				b8 = p32[7:0];
			end
		endcase
		if (pipe1[4] && en_lat) begin
			red <= r8; green <= g8; blue <= b8;
		end
		else begin
			red <= 8'd0; green <= 8'd0; blue <= 8'd0;
		end
	end
	hsync  <= pipe1[2];
	vsync  <= pipe1[1];
	de     <= pipe1[3];
	vblank <= pipe1[0];
	border <= pipe1[3] && !pipe1[4];
end

// ---------------------------------------------------------------------
// Status and underrun detection
// ---------------------------------------------------------------------

reg [2:0] dt_sync = 3'd0;
reg [1:0] cnt_done = 2'd0;
always @(posedge clk or posedge reset) begin
	if (reset) begin
		dt_sync <= 3'd0;
		cnt_done <= 2'd0;
		underrun <= 1'b0;
		vblank_in <= 1'b0;
		vblank_out <= 1'b0;
		src_line <= 10'd0;
	end
	else begin
		dt_sync <= {dt_sync[1:0], done_toggle};
		if (dt_sync[2] ^ dt_sync[1]) cnt_done <= cnt_done + 2'd1;
		src_line <= img_v ? source_line : 10'd0;
		vblank_in  <= (raster_hl == game_y1_hl && scnt == 11'd0);
		vblank_out <= (raster_hl == game_y0_hl && scnt == 11'd0);
		if (img_v && !half_phase && hfull == game_x0 - 12'd4 &&
		    (cnt_req - cnt_done) >= 2'd2) underrun <= 1'b1;
	end
end

endmodule

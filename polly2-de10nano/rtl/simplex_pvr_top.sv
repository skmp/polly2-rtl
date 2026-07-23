//
// simplex_pvr_top - drop-in wrapper that adapts the layer-peeling `peel_core`
// to the MiSTer `emu` module's TWO standard Avalon-style DDR channels.
//
// This is the synthesis integration used INSIDE emu (S32X.sv), in place of the
// old rtl/pvr `pvr` instance. It replaces mister_top.sv's `sysmem_lite` bridge:
// here the two DDR channels are the emu-level DDRAM_* / DDRAM2_* ports directly.
//
//   * DDRAM_*  : peel_core's DDR READS  (region/objlist/param/texture) - one
//                64-bit burst in flight, driven by ddr_req/ddr_resp.
//   * DDRAM2_* : peel_core's framebuffer WRITES (shaded pixels packed 2/word).
//
// The emu top preloads VRAM into DDR and streams the PVR register dump into the
// core through wr_en/wr_addr/wr_data (byte-offset addressing, low 8 KB) before
// pulsing `go`; `done` pulses when the region array is fully rendered. The
// framebuffer is written to DDR at fb_base_word (64-bit words, 2 ARGB px/word)
// so the emu scanout can read it. The live PVR register struct is exposed on
// FB_*_SOF1/2 + TEST_SELECT as plain vectors (the host uses these for display
// and the render poll).
//
// NOTE on protocol: MiSTer's DDRAM_BUSY == Avalon waitrequest, and
// DDRAM_DOUT_READY == Avalon readdatavalid. The adapters below are byte-for-byte
// the same ones proven in mister_top.sv (ram1 read master + 2px/word fb write
// master); only the port names change.
//
module simplex_pvr_top import tsp_pkg::*; (
    input             clk,          // core clock (emu clk_sys)
    input             reset,        // active-high synchronous reset

    // ---- register/command load + run (driven by emu) ----
    input             wr_en,        // 1: write PVR reg wr_addr <= wr_data
    input      [12:0] wr_addr,      // BYTE offset into the reg space (low 8 KB)
    input      [31:0] wr_data,
    input             go,           // 1-cycle: start rendering the region array
    output            done,         // 1-cycle: region array fully processed

    // Debug: 0 = no texel fetches, shade with base (Gouraud-interpolated) colour
    // only (CONF_STR "Texel Reads" off). Pass-through to peel_core.
    input             tex_en,

    // ---- framebuffer DDR word base ----
    // The FB write base and split-VRAM half come from the core's OWN FB_W_SOF1
    // register (regs.fb_w_sof1), derived below - NOT external inputs. The write
    // always targets FB_W_SOF1; the SPG display read targets FB_R_SOF1 outside.

    // ---- live display registers (from the core's own reg file) ----
    // Exposed as plain vectors so the emu top need not import tsp_pkg.
    output     [31:0] FB_R_SOF1,
    output     [31:0] FB_R_SOF2,
    output     [31:0] FB_R_CTRL,
    output     [31:0] VO_CONTROL,
    output     [31:0] FB_W_SOF1,
    output     [31:0] FB_W_SOF2,
    // TEST_SELECT (reg 0x18): minicast writes 0xCAFEBABE here as the "regs are
    // ready, render now" sentinel. The emu poll FSM watches this.
    output     [31:0] TEST_SELECT,

    // ================= DDR READ channel (DDRAM_*, Avalon) =================
    output        DDRAM_CLK,
    input         DDRAM_BUSY,        // == waitrequest
    output  [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,        // raw 64-bit-word offset (emu adds DDRAM_BASE)
    input  [63:0] DDRAM_DOUT,
    input         DDRAM_DOUT_READY,  // == readdatavalid
    output        DDRAM_RD,

    // ================= FRAMEBUFFER WRITE channel (DDRAM2_*, Avalon) =======
    output        DDRAM2_CLK,
    input         DDRAM2_BUSY,       // == waitrequest
    output  [7:0] DDRAM2_BURSTCNT,
    output [28:0] DDRAM2_ADDR,       // raw 64-bit-word offset (emu adds DDRAM_BASE)
    output [63:0] DDRAM2_DIN,
    output  [7:0] DDRAM2_BE,
    output        DDRAM2_WE
);
    assign DDRAM_CLK  = clk;
    assign DDRAM2_CLK = clk;

    // ------------------------------------------------------------------
    // peel_core with the DDR read + framebuffer write injected.
    // ------------------------------------------------------------------
    ddr_rd_req_t  ddr_req;  ddr_rd_resp_t ddr_resp;
    fb_wr_req_t   fbw_req;  fb_wr_resp_t  fbw_resp;
    pvr_regs_t    regs;

    peel_core u_core (
        .clk(clk), .reset(reset),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .go(go), .done(done),
        //.tex_en(tex_en),
        .ddr_req(ddr_req), .ddr_resp(ddr_resp),
        .fbw_req(fbw_req), .fbw_resp(fbw_resp),
        .regs_out(regs)
    );

    assign FB_R_SOF1   = regs.fb_r_sof1;
    assign FB_R_SOF2   = regs.fb_r_sof2;
    assign FB_R_CTRL   = regs.fb_r_ctrl;
    assign VO_CONTROL  = regs.vo_control;
    assign FB_W_SOF1   = regs.fb_w_sof1;
    assign FB_W_SOF2   = regs.fb_w_sof2;
    assign TEST_SELECT = regs.test_select;

    // ==================================================================
    // DDR READ master: peel_core ddr_req/ddr_resp  <->  DDRAM_* (Avalon read).
    // peel_core issues one 64-bit-word-addressed burst read at a time and holds
    // ddr_req.rd until accepted. Avalon: assert read+address+burstcount until
    // !waitrequest (accepted), then `burst` readdatavalid beats stream back.
    // ==================================================================
    reg        rd_inflight = 1'b0;  // a read has been accepted, beats still returning
    reg [7:0]  rd_left     = 8'd0;  // beats remaining to return
    reg        rd_flush    = 1'b0;  // burst orphaned by a reset: swallow its beats
    // issue while the core requests, no read in flight, and not in reset
    wire       rd_issue = ddr_req.rd && !rd_inflight && !reset;
    assign DDRAM_RD       = rd_issue;
    // peel_core tags every read address as {4'b0011, word[24:0]} - the DC 64-bit
    // VRAM CS region marker (region/objlist/param/tex caches). The physical 64-bit
    // VRAM word offset is the low 25 bits; the host adds the DDR VRAM base. Strip
    // the region tag so DDRAM_ADDR is the raw VRAM word offset (matches how the
    // sim faux-DDR indexes vram[] by addr[19:0]).
    assign DDRAM_ADDR     = {4'b0000, ddr_req.addr[24:0]};
    assign DDRAM_BURSTCNT = ddr_req.burst;

    // core-facing response: busy while a read is accepted-and-returning, or while
    // our issue is still waiting on the bridge (waitrequest). dready is GATED on
    // rd_inflight: a readdatavalid pulse with no read outstanding (stray/late beat
    // from the DDR3 bridge) must never reach the core's arbiter - an uncounted
    // beat desyncs its d_beats bookkeeping and hangs the burst clients
    // (record_fetcher stuck mid-burst -> spanner_v2 busy=1 deadlock).
    assign ddr_resp.busy   = rd_inflight || (rd_issue && DDRAM_BUSY);
    assign ddr_resp.dout   = DDRAM_DOUT;
    assign ddr_resp.dready = DDRAM_DOUT_READY && rd_inflight && !rd_flush;

    // rd_inflight/rd_left are deliberately NOT cleared by reset: a burst the
    // bridge accepted before the reset still returns ALL its beats afterwards
    // (the HPS SDRAM controller executes accepted commands regardless of
    // fabric state). Keep counting so those stale beats are consumed here
    // instead of miscounting against the next render's first burst, which
    // would shift every later read until the fabric is reprogrammed. A reset
    // with a burst in flight sets rd_flush: the remaining beats are counted
    // but dready is suppressed, so the freshly-reset core's arbiter never
    // sees a beat it didn't request (an uncounted beat desyncs its d_beats
    // bookkeeping - see the note above). New issues stay blocked meanwhile
    // (ddr_resp.busy = rd_inflight, and rd_issue is gated on !reset).
    always @(posedge clk) begin
        if (reset && rd_inflight) rd_flush <= 1'b1;
        else if (!rd_inflight)    rd_flush <= 1'b0;

        if (!rd_inflight) begin
            if (rd_issue && !DDRAM_BUSY) begin  // accepted this cycle
                rd_inflight <= 1'b1;
                rd_left     <= ddr_req.burst;
            end
        end else if (DDRAM_DOUT_READY) begin
            if (rd_left <= 8'd1) rd_inflight <= 1'b0;
            rd_left <= rd_left - 8'd1;
        end
    end

    // ==================================================================
    // FRAMEBUFFER WRITE master (BURSTING, all FB_W_CTRL fb_packmode formats,
    // 32-bit "split" area or the dense 64-bit render-to-texture mirror).
    //
    // peel_core presents <=1 shaded ARGB8888 pixel/cycle with its screen
    // coordinate (px, py). Four stages, one register each:
    //
    //  hs: SCALER_CTL.hscale x-scaling - horizontally-adjacent pixel PAIRS
    //      are averaged per channel ((even+odd)>>1) into ONE pixel at
    //      px>>1: a 1280-wide render writes out 640 wide (supersampled
    //      anti-aliasing), a 640-wide one 320 wide (pairs with the display
    //      side's VO_CONTROL.pixel_double). The VO streams tile rows
    //      x-ascending, so pairing is positional (even latches, odd
    //      emits).
    //  s1: CONVERT to the fb_packmode wire format and compute the pixel's
    //      FB-view byte address  FB_W_SOF1 + py*stride*8 + px*bpp  (stride
    //      from FB_W_LINESTRIDE). Quantization follows refsw2's writeback:
    //      q = (c*maxval + T) / 255 with the 4x4 Bayer bias T when
    //      fb_dither (16-bit modes; T=0 otherwise). Formats:
    //        0: 0555 KRGB  K=fb_kval[7]      1: 565 RGB
    //        2: 4444 ARGB                    3: 1555 ARGB, A = (a8 >= fb_alpha_threshold)
    //        4: 888 RGB, 3 bytes/px packed   5: 0888 KRGB, K byte = fb_kval
    //        6: 8888 ARGB                    7: treated as 8888
    //      (refsw2 quirks NOT copied: its mode-0 4-byte pixel advance is a
    //      bug, and it writes K=0; modes 2/3/5 follow the DC spec since
    //      refsw2 doesn't implement them.)
    //  A : assemble the 2/3/4-byte pixels into FB-view 32-bit WORDS with
    //      per-byte enables (packed 888 pixels straddle word boundaries;
    //      a straddling pixel emits the completed word and keeps the tail).
    //  B : place 32-bit words into 64-bit DDR BEATS:
    //        FB_W_SOF1[24]=0 (32-bit area): FB word W -> DDR word W, in the
    //          32-bit half selected by SOF bit 22 (minicast's pvr_map32
    //          split-VRAM rule: bank 0 = LOW half, bank 1 = HIGH; the spg
    //          scanout and CPU area-1 accesses use the same mapping, so
    //          CPU-written FBs like ip.bin's read back). 2 16bpp px/beat.
    //        FB_W_SOF1[24]=1 (render to texture): the DENSE 64-bit-view
    //          mirror textures are fetched from - FB byte F -> DDR byte F,
    //          consecutive FB words pair into whole beats (4 16bpp px).
    //  C : the run/burst engine: ADDRESS-CONTIGUOUS beats accumulate in
    //      run_mem (up to BURST_MAX) and drain as ONE Avalon burst with
    //      PER-BEAT byte enables (f2sdram_safe_terminator passes BE per
    //      beat). A beat that can't extend the run (non-contiguous / full)
    //      is held to seed the next run; an idle gap (no pixel 2 cycles)
    //      cascades a flush s1 -> A -> B -> run -> DRAIN so a tile's tail
    //      is never stranded. The core is stalled only while draining.
    // ==================================================================
    localparam integer BURST_MAX = 16;      // beats per burst (16 x 8 bytes)

    // exact x/255 for x <= 16383: (x + (x>>8) + 1) >> 8
    function automatic [5:0] div255(input [13:0] x);
        reg [14:0] t;
        t = {1'b0, x} + {9'd0, x[13:8]} + 15'd1;
        div255 = t[13:8];
    endfunction
    // refsw2's bayerBias[y&3][x&3] (= 4x4 Bayer * 16 + 8)
    function automatic [7:0] bayer_t(input [3:0] yx);   // {py[1:0], px[1:0]}
        case (yx)
            4'd0:  bayer_t = 8'd8;    4'd1:  bayer_t = 8'd136;
            4'd2:  bayer_t = 8'd40;   4'd3:  bayer_t = 8'd168;
            4'd4:  bayer_t = 8'd200;  4'd5:  bayer_t = 8'd72;
            4'd6:  bayer_t = 8'd232;  4'd7:  bayer_t = 8'd104;
            4'd8:  bayer_t = 8'd56;   4'd9:  bayer_t = 8'd184;
            4'd10: bayer_t = 8'd24;   4'd11: bayer_t = 8'd152;
            4'd12: bayer_t = 8'd248;  4'd13: bayer_t = 8'd120;
            4'd14: bayer_t = 8'd216;  default: bayer_t = 8'd88;
        endcase
    endfunction
    function automatic [4:0] q5(input [7:0] c, input [7:0] t);
        reg [5:0] q;
        q  = div255({1'b0, c, 5'b00000} - {6'd0, c} + {6'd0, t});   // c*31 + t
        q5 = q[4:0];
    endfunction
    function automatic [5:0] q6(input [7:0] c, input [7:0] t);
        q6 = div255({c, 6'b000000} - {6'd0, c} + {6'd0, t});        // c*63 + t
    endfunction
    function automatic [3:0] q4(input [7:0] c, input [7:0] t);
        reg [5:0] q;
        q  = div255({2'b00, c, 4'b0000} - {6'd0, c} + {6'd0, t});   // c*15 + t
        q4 = q[3:0];
    endfunction

    // ---- write-format config (from the core's own registers) ----
    wire  [2:0] pm      = regs.fb_w_ctrl.fb_packmode;
    wire        dith    = regs.fb_w_ctrl.fb_dither;
    wire  [7:0] kval    = regs.fb_w_ctrl.fb_kval;
    wire  [7:0] ath     = regs.fb_w_ctrl.fb_alpha_threshold;
    wire [11:0] stride8 = {regs.fb_w_linestride.stride, 3'b000};   // bytes/line
    wire        wrtt    = regs.fb_w_sof1[24];   // dense 64-bit-view mirror
    wire [22:0] wbase   = wrtt ? regs.fb_w_sof1[22:0]
                               : {1'b0, regs.fb_w_sof1[21:0]};

    // ---- hs: SCALER_CTL.hscale pixel pairer (x 1/2, per-channel average) ----
    wire        hs_en = regs.scaler_ctl.hscale;
    reg  [31:0] hs_argb;                     // latched even-x pixel of the pair

    wire [8:0] hs_a = {1'b0, hs_argb[31:24]} + {1'b0, fbw_req.argb[31:24]};
    wire [8:0] hs_r = {1'b0, hs_argb[23:16]} + {1'b0, fbw_req.argb[23:16]};
    wire [8:0] hs_g = {1'b0, hs_argb[15:8]}  + {1'b0, fbw_req.argb[15:8]};
    wire [8:0] hs_b = {1'b0, hs_argb[7:0]}   + {1'b0, fbw_req.argb[7:0]};

    // the pixel a write is produced for: with hscale only odd x completes a
    // pair, emitting the average at x>>1
    wire        px_pass  = !hs_en || fbw_req.px[0];
    wire [31:0] sel_argb = hs_en ? {hs_a[8:1], hs_r[8:1], hs_g[8:1], hs_b[8:1]}
                                 : fbw_req.argb;
    wire [10:0] sel_px   = hs_en ? {1'b0, fbw_req.px[10:1]} : fbw_req.px;

    // ---- s0 (comb on the produced pixel): convert + address ----
    wire [7:0] c_a = sel_argb[31:24], c_r = sel_argb[23:16],
               c_g = sel_argb[15:8],  c_b = sel_argb[7:0];
    wire [7:0] bT  = dith ? bayer_t({fbw_req.py[1:0], sel_px[1:0]}) : 8'd0;

    reg [15:0] s0_p16;
    reg  [7:0] s0_b0, s0_b1, s0_b2, s0_b3;   // little-endian bytes at s0_addr
    reg  [2:0] s0_nb;
    always @* begin
        case (pm)
            3'd0:    s0_p16 = {kval[7],      q5(c_r,bT), q5(c_g,bT), q5(c_b,bT)};
            3'd1:    s0_p16 = {q5(c_r,bT),   q6(c_g,bT),             q5(c_b,bT)};
            3'd2:    s0_p16 = {q4(c_a,bT),   q4(c_r,bT), q4(c_g,bT), q4(c_b,bT)};
            default: s0_p16 = {c_a >= ath,   q5(c_r,bT), q5(c_g,bT), q5(c_b,bT)};
        endcase
        if (pm[2]) begin                     // 4/5/6/7: byte formats, B,G,R[,K/A]
            s0_b0 = c_b; s0_b1 = c_g; s0_b2 = c_r;
            s0_b3 = (pm == 3'd5) ? kval : c_a;
            s0_nb = (pm == 3'd4) ? 3'd3 : 3'd4;
        end else begin                       // 16-bit formats
            s0_b0 = s0_p16[7:0]; s0_b1 = s0_p16[15:8];
            s0_b2 = 8'd0; s0_b3 = 8'd0;
            s0_nb = 3'd2;
        end
    end

    wire [21:0] s0_row  = fbw_req.py * stride8;
    wire [13:0] s0_xoff = pm[2] ? ((pm == 3'd4) ? {2'b00, sel_px, 1'b0} + {3'd0, sel_px}
                                                : {1'b0, sel_px, 2'b00})
                                : {2'b00, sel_px, 1'b0};
    wire [22:0] s0_addr = wbase + {1'b0, s0_row} + {9'd0, s0_xoff};

    // ---- s1: registered converted pixel ----
    reg        s1_v = 1'b0;
    reg [22:0] s1_addr;
    reg  [7:0] s1_b [0:3];
    reg  [2:0] s1_nb;

    // ---- stage A state: FB-view 32-bit word being assembled ----
    reg        aw_v = 1'b0;
    reg [20:0] aw_w;                         // FB 32-bit word index (addr[22:2])
    reg [31:0] aw_d;
    reg  [3:0] aw_be;

    // ---- stage B state: 64-bit DDR beat being assembled ----
    reg        bw_v = 1'b0;
    reg [19:0] bw_w;                         // DDR 64-bit word index
    reg [63:0] bw_d;
    reg  [7:0] bw_be;

    // ---- stage C: run buffer + burst engine ----
    reg [63:0] run_d  [0:BURST_MAX-1];
    reg  [7:0] run_be [0:BURST_MAX-1];
    reg  [4:0] run_len;                      // beats buffered (0..16)
    reg [28:0] run_base;                     // DDR word address of run_d[0]
    reg [28:0] run_next;                     // expected DDR word addr of the next beat

    reg        bst_busy = 1'b0;              // 1 = DRAIN: streaming the burst
    reg  [4:0] bst_beat = 5'd0;              // beat index presented (0..run_len-1)

    // pending break-beat: couldn't extend the run (non-contig or full), seeds
    // the NEXT run once this one has drained.
    reg        hold_v;
    reg [63:0] hold_d;
    reg  [7:0] hold_be;
    reg [28:0] hold_addr;
    reg        acc_d;                        // a pixel was accepted last cycle

    // ---- stage A input placement (comb from s1) ----
    wire [20:0] a_w0  = s1_addr[22:2];
    wire  [1:0] a_off = s1_addr[1:0];
    wire        a_str = ({1'b0, a_off} + s1_nb) > 3'd4;   // spills into a_w0+1

    reg [31:0] a_d0, a_d1;
    reg  [3:0] a_be0, a_be1;
    integer aj;
    always @* begin
        a_d0 = 32'd0; a_d1 = 32'd0; a_be0 = 4'd0; a_be1 = 4'd0;
        for (aj = 0; aj < 4; aj = aj + 1) begin
            if (aj >= {30'd0, a_off} && (aj - {30'd0, a_off}) < {29'd0, s1_nb}) begin
                a_d0[8*aj +: 8] = s1_b[aj - {30'd0, a_off}];
                a_be0[aj]       = 1'b1;
            end
            if ((aj + 4 - {30'd0, a_off}) < {29'd0, s1_nb}) begin
                a_d1[8*aj +: 8] = s1_b[aj + 4 - {30'd0, a_off}];
                a_be1[aj]       = 1'b1;
            end
        end
    end

    wire a_take  = s1_v;
    wire a_match = aw_v && (a_w0 == aw_w);
    // a jump AND a straddle would need two emissions in one cycle; stall the
    // pixel one cycle instead (can't occur with a word-aligned SOF + stride,
    // but packed-888 render targets make it cheap to be safe)
    wire a_stall = a_take && aw_v && !a_match && a_str;

    // idle-gap flush trigger: no pixel accepted this or last cycle
    wire acc     = fbw_req.we && !fbw_resp.busy;
    wire fl_idle = !acc && !acc_d;

    // ---- stage A emission (comb) ----
    reg         emA_v;
    reg  [20:0] emA_w;
    reg  [31:0] emA_d;
    reg   [3:0] emA_be;
    always @* begin
        emA_v = 1'b0; emA_w = aw_w; emA_d = aw_d; emA_be = aw_be;
        if (a_take) begin
            if (aw_v && !a_match) begin
                emA_v = 1'b1;                            // old word goes out
            end else if (a_match && a_str) begin
                emA_v  = 1'b1;                           // completed word goes out
                emA_d  = aw_d | a_d0;
                emA_be = aw_be | a_be0;
            end else if (!aw_v && a_str) begin
                emA_v  = 1'b1;                           // w0 part passes through
                emA_w  = a_w0;
                emA_d  = a_d0;
                emA_be = a_be0;
            end
        end else if (fl_idle && aw_v) begin
            emA_v = 1'b1;                                // flush the partial word
        end
    end

    // ---- stage B mapping + emission (comb) ----
    wire [19:0] b_dw = wrtt ? emA_w[20:1] : emA_w[19:0];
    // which 32-bit half of the beat: RTT = dense (FB word parity); split area =
    // the fixed half from SOF bit 22, pvr_map32 rule: bank 0 -> LOW 32 bits,
    // bank 1 -> HIGH (the same rule the scanout's fb_disp_half reads back)
    wire        b_hi = wrtt ? emA_w[0] : regs.fb_w_sof1[22];
    wire [63:0] b_d  = b_hi ? {emA_d, 32'd0} : {32'd0, emA_d};
    wire  [7:0] b_be = b_hi ? {emA_be, 4'd0} : {4'd0, emA_be};
    wire        b_match = bw_v && (b_dw == bw_w);

    reg         emB_v;
    reg  [19:0] emB_w;
    reg  [63:0] emB_d;
    reg   [7:0] emB_be;
    always @* begin
        emB_v = 1'b0; emB_w = bw_w; emB_d = bw_d; emB_be = bw_be;
        if (emA_v && bw_v && !b_match)                        emB_v = 1'b1;
        else if (!emA_v && fl_idle && !aw_v && bw_v)          emB_v = 1'b1;
    end

    wire [28:0] emB_addr  = {9'd0, emB_w};
    wire        pk_contig = run_len != 5'd0 && (emB_addr == run_next);

    // Stall the core while draining, or for the rare two-emission pixel.
    assign fbw_resp.busy = bst_busy || a_stall;

    // ---- DDRAM2 burst outputs (driven in DRAIN) ----
    assign DDRAM2_WE       = bst_busy;
    assign DDRAM2_ADDR     = run_base;
    assign DDRAM2_BURSTCNT = {3'd0, run_len};
    assign DDRAM2_DIN      = run_d[bst_beat];
    assign DDRAM2_BE       = run_be[bst_beat];

    always @(posedge clk) begin
        if (reset) begin
            // Pipeline/run bookkeeping clears, but an IN-FLIGHT BURST IS NOT
            // ABORTED: the f2sdram port has already latched BURSTCNT and
            // counts raw data beats - dropping WE short leaves the hard
            // bridge expecting the missing beats forever. It then eats the
            // next burst's first beats as this one's tail, shifting every
            // subsequent FB write by the shortfall; that desync lives in the
            // HPS bridge, survives every fabric-side reset, and only clears
            // on reprogramming. So the DRAIN branch below keeps streaming
            // under reset until the burst completes - the leftover beats
            // rewrite stale FB bytes at their original addresses, harmless.
            // (BE is captured per beat at append time, so a mid-drain reg
            // file clear cannot change the mask of an in-flight burst.)
            s1_v <= 1'b0; aw_v <= 1'b0; bw_v <= 1'b0;
            acc_d <= 1'b0; hold_v <= 1'b0;
            if (!bst_busy) run_len <= 5'd0;
        end else begin
            acc_d <= acc;

            if (!bst_busy) begin
                // ================= ACCUM =================
                // hs: latch the even-x pixel of an hscale pair
                if (acc && hs_en && !fbw_req.px[0]) hs_argb <= fbw_req.argb;

                // s1 load (held while a_stall splits a two-emission pixel)
                if (!a_stall) begin
                    s1_v <= acc && px_pass;
                    if (acc) begin
                        s1_addr <= s0_addr;
                        s1_b[0] <= s0_b0; s1_b[1] <= s0_b1;
                        s1_b[2] <= s0_b2; s1_b[3] <= s0_b3;
                        s1_nb   <= s0_nb;
                    end
                end

                // stage A state
                if (a_take && !a_stall) begin
                    if (!aw_v || a_match) begin
                        if (a_str) begin
                            aw_v <= 1'b1; aw_w <= a_w0 + 21'd1;
                            aw_d <= a_d1; aw_be <= a_be1;
                        end else if (a_match) begin
                            aw_d <= aw_d | a_d0; aw_be <= aw_be | a_be0;
                        end else begin
                            aw_v <= 1'b1; aw_w <= a_w0;
                            aw_d <= a_d0; aw_be <= a_be0;
                        end
                    end else begin           // jump, no straddle: replace
                        aw_w <= a_w0; aw_d <= a_d0; aw_be <= a_be0;
                    end
                end else if (a_stall) begin
                    aw_v <= 1'b0;            // emitted; s1 retries next cycle
                end else if (fl_idle && aw_v) begin
                    aw_v <= 1'b0;            // flushed
                end

                // stage B state
                if (emA_v) begin
                    if (b_match) begin
                        bw_d <= bw_d | b_d; bw_be <= bw_be | b_be;
                    end else begin
                        bw_v <= 1'b1; bw_w <= b_dw;
                        bw_d <= b_d;  bw_be <= b_be;
                    end
                end else if (emB_v) begin
                    bw_v <= 1'b0;            // flushed
                end

                // stage C: append / hold+drain / idle drain
                if (emB_v) begin
                    if (run_len == 5'd0) begin
                        run_d[0]  <= emB_d;
                        run_be[0] <= emB_be;
                        run_base  <= emB_addr;
                        run_next  <= emB_addr + 29'd1;
                        run_len   <= 5'd1;
                    end else if (pk_contig && run_len != BURST_MAX[4:0]) begin
                        run_d[run_len]  <= emB_d;
                        run_be[run_len] <= emB_be;
                        run_next        <= run_next + 29'd1;
                        run_len         <= run_len + 5'd1;
                    end else begin
                        hold_v    <= 1'b1;
                        hold_d    <= emB_d;
                        hold_be   <= emB_be;
                        hold_addr <= emB_addr;
                        bst_busy  <= 1'b1; bst_beat <= 5'd0;   // -> DRAIN
                    end
                end else if (fl_idle && !aw_v && !bw_v && run_len != 5'd0) begin
                    bst_busy <= 1'b1; bst_beat <= 5'd0;        // -> DRAIN (idle)
                end
            end
        end

        // ================= DRAIN =================
        // stream run_d[0..run_len-1] as one burst (one beat / !BUSY cycle).
        // Runs UNDER RESET too - the accepted burst must complete (see the
        // reset note above).
        if (bst_busy && !DDRAM2_BUSY) begin
            if (bst_beat + 5'd1 >= run_len) begin
                // burst done: re-seed from a held break-beat, else empty.
                bst_busy <= 1'b0;
                bst_beat <= 5'd0;
                if (hold_v && !reset) begin
                    run_d[0]  <= hold_d;
                    run_be[0] <= hold_be;
                    run_base  <= hold_addr;
                    run_next  <= hold_addr + 29'd1;
                    run_len   <= 5'd1;
                    hold_v    <= 1'b0;
                end else begin
                    run_len <= 5'd0;
                end
            end else begin
                bst_beat <= bst_beat + 5'd1;
            end
        end
    end
endmodule

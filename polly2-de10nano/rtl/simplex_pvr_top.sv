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
//   * DDRAM2_* : peel_core's framebuffer WRITES (shaded pixels packed 2/word),
//                driven by polly2-core's `vo` block (rtl/vo.sv) - this wrapper
//                only injects the core's fbw port and the DDRAM2_* channel
//                into it.
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
// DDRAM_DOUT_READY == Avalon readdatavalid. The read adapter below is
// byte-for-byte the one proven in mister_top.sv (ram1 read master); only the
// port names change.
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
    // DDR READ master: peel_core ddr_req/ddr_resp  <->  DDRAM_* (Avalon read),
    // MULTI-OUTSTANDING: the core's arbiter pipelines up to 4 bursts (its order
    // FIFO routes returned beats by issue order, which the bridge preserves), so
    // this master accepts a new command whenever the bridge takes it and the
    // outstanding-BEAT budget allows, while earlier bursts still stream back.
    // Avalon: assert read+address+burstcount until !waitrequest (accepted), then
    // `burst` readdatavalid beats stream back, in command order.
    // ==================================================================
    // Outstanding-beat budget. Must cover the LARGEST single burst any client can
    // issue, or that request can never satisfy rd_cap and the core deadlocks
    // (rez_ingame: a 71-beat iterator record burst vs the old 64 budget). Worst
    // case is the iterator's record read: 3 hdr + 8 verts x 11 words (xyz + 2x
    // base + 2x offset + 2x uv) = 91 beats; 128 covers it and is the Avalon
    // 8-bit-burstcount legal max.
    localparam integer RD_MAX_BEATS = 128;
    reg [9:0]  rd_beats   = 10'd0;  // beats accepted but not yet returned
    reg        rd_flush   = 1'b0;   // bursts orphaned by a reset: swallow their beats
    wire       rd_cap     = ({2'd0, rd_beats} + {4'd0, ddr_req.burst}) <= 12'(RD_MAX_BEATS);
    wire       rd_issue   = ddr_req.rd && !reset && !rd_flush && rd_cap;
    assign DDRAM_RD       = rd_issue;
    // peel_core tags every read address as {4'b0011, word[24:0]} - the DC 64-bit
    // VRAM CS region marker (region/objlist/param/tex caches). The physical 64-bit
    // VRAM word offset is the low 25 bits; the host adds the DDR VRAM base. Strip
    // the region tag so DDRAM_ADDR is the raw VRAM word offset (matches how the
    // sim faux-DDR indexes vram[] by addr[19:0]).
    assign DDRAM_ADDR     = {4'b0000, ddr_req.addr[24:0]};
    assign DDRAM_BURSTCNT = ddr_req.burst;

    wire       rd_accept  = rd_issue && !DDRAM_BUSY;
    wire       rd_beat    = DDRAM_DOUT_READY && (rd_beats != 10'd0);

    // core-facing response: busy = cannot ACCEPT a command this cycle (bridge
    // waitrequest, budget exhausted, or flushing). dready is GATED on rd_beats:
    // a readdatavalid pulse with nothing outstanding (stray/late beat from the
    // DDR3 bridge) must never reach the core's arbiter - an unexpected beat
    // desyncs its order-FIFO bookkeeping and hangs the burst clients.
    assign ddr_resp.busy   = DDRAM_BUSY || !rd_cap || rd_flush || reset;
    assign ddr_resp.dout   = DDRAM_DOUT;
    assign ddr_resp.dready = rd_beat && !rd_flush;

    // rd_beats is deliberately NOT cleared by reset: bursts the bridge accepted
    // before the reset still return ALL their beats afterwards (the HPS SDRAM
    // controller executes accepted commands regardless of fabric state). Keep
    // counting so those stale beats are consumed here instead of miscounting
    // against the next render's first burst. A reset with beats in flight sets
    // rd_flush: the remaining beats are counted but dready is suppressed, so the
    // freshly-reset core's arbiter never sees a beat it didn't request. New
    // issues stay blocked meanwhile (busy includes rd_flush/reset).
    always @(posedge clk) begin
        if (reset && rd_beats != 10'd0) rd_flush <= 1'b1;
        else if (rd_beats == 10'd0)     rd_flush <= 1'b0;

        rd_beats <= rd_beats + (rd_accept ? {2'd0, ddr_req.burst} : 10'd0)
                             - (rd_beat   ? 10'd1                 : 10'd0);
    end

    // ==================================================================
    // VIDEO OUT (framebuffer write-out): the polly2-core `vo` block, with the
    // core's pixel port and the DDRAM2_* Avalon write channel injected. All
    // the format/packing/burst logic lives there.
    // ==================================================================
    vo u_vo (
        .clk(clk), .reset(reset),
        .fb_w_ctrl(regs.fb_w_ctrl),
        .fb_w_sof1(regs.fb_w_sof1),
        .fb_w_linestride(regs.fb_w_linestride),
        .scaler_ctl(regs.scaler_ctl),
        .fb_x_clip(regs.fb_x_clip),
        .fb_y_clip(regs.fb_y_clip),
        .fbw_req(fbw_req), .fbw_resp(fbw_resp),
        .ddr_busy(DDRAM2_BUSY),
        .ddr_burstcnt(DDRAM2_BURSTCNT),
        .ddr_addr(DDRAM2_ADDR),
        .ddr_din(DDRAM2_DIN),
        .ddr_be(DDRAM2_BE),
        .ddr_we(DDRAM2_WE)
    );
endmodule

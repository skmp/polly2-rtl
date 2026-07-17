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
    assign FB_W_SOF1   = regs.fb_w_sof1;
    assign FB_W_SOF2   = regs.fb_w_sof2;
    assign TEST_SELECT = regs.test_select;

    // FB write base + split-VRAM half, from the core's OWN FB_W_SOF1 register.
    // Byte offset [21:2] -> 64-bit word offset (2 ARGB px/word, "side" layout);
    // bit 22 selects the 32-bit half. Was previously fed in as fb_base_word/
    // fb_sel_upper - now internal so writes always follow FB_W_SOF1.
    wire [28:0] fb_base_word = {9'd0, regs.fb_w_sof1[21:2]};
    wire        fb_sel_upper = regs.fb_w_sof1[22];

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
    // FRAMEBUFFER WRITE master (BURSTING): peel_core fbw_req (<=1 ARGB px/cycle at a
    // linear index)  ->  DDRAM2_*, as 16bpp RGB565 in the Dreamcast split-VRAM
    // layout that ASCAL's native 16bpp path (fb_split_word) reads back.
    //
    // ARGB8888 -> RGB565: {R[7:3], G[7:2], B[7:3]} = argb[23:19],argb[15:10],argb[7:3].
    //
    // Split-VRAM layout: only ONE 32-bit half of each 64-bit DDR word carries this
    // framebuffer's pixels (the OTHER half belongs to the other 4 MB bank).
    // fb_sel_upper (= FB_W_SOF1[22]) picks which:
    //   fb_sel_upper=0 -> pixels in HIGH 32 bits [63:32]  (ASCAL: dr(63:32) useful)
    //   fb_sel_upper=1 -> pixels in LOW  32 bits [31:0]
    // Two horizontally-adjacent 16bpp pixels pack into that 32-bit half:
    //   even linear index -> low 16 of the half, odd -> high 16 of the half.
    // So one 64-bit DDR word holds 2 px; the interleave caps packing at 2 px/word
    // (cannot use 4 - the other half is the other bank). Byte-enable masks the used
    // half; f2sdram_safe_terminator passes byteenable per-beat, so every burst beat
    // carries the same half-mask -> bursting is safe.
    //
    // BURSTING: peel_core's VO streams a tile row-major (pix_idx contiguous for the
    // 32 px of a tile row, x=vo_i[4:0]); consecutive pixel PAIRS -> consecutive DDR
    // words -> we COMBINE a contiguous run of packed words into ONE Avalon burst
    // (BURSTCNT=N) instead of a single-beat write per pair. A run is flushed when:
    // the next word's address isn't contiguous (tile-row boundary / off-screen gap),
    // the run reaches BURST_MAX (one 32-px tile row = 16 words), or the core stops
    // presenting pixels (idle gap). While the run buffer has room the core is NOT
    // stalled (fbw_resp.busy low) -> pixels stream in at the VO rate, drain to DDR
    // in efficient bursts. Replaces the old single-beat + full-stall-per-pair master.
    //
    // NOTE: layout mirrors the old geo-arbiter 16bpp writeback (word=SOF[.:2]+idx,
    // half=bit22, 2 px/32-bit word). Verify vs a real frame; if bank-swapped, invert
    // fb_sel_upper; if a burst straddles a wrong boundary, the run-break check below
    // is where to adjust.
    // ==================================================================
    localparam integer BURST_MAX = 16;      // 16 words = 32 px = one tile row

    function [15:0] argb_to_565(input [31:0] a);
        argb_to_565 = {a[23:19], a[15:10], a[7:3]};   // R5 G6 B5
    endfunction

    // Two-phase model, no same-cycle races on shared state:
    //   ACCUM (bst_busy=0): pair pixels, append packed words to run_mem while they
    //     stay ADDRESS-CONTIGUOUS. On the first NON-contiguous word, on a full run
    //     (BURST_MAX), or on an idle gap, latch a pending break-word (if any) and
    //     drop into DRAIN. Pixels are accepted every cycle here (busy=0).
    //   DRAIN (bst_busy=1): stream run_mem[0..run_len-1] as ONE Avalon burst; the
    //     core is stalled (busy=1) for the few cycles this takes. Then re-seed the
    //     run with any pending break-word and return to ACCUM.
    // Since ACCUM never overlaps DRAIN, run_mem / run_len have a single writer per
    // cycle and the pixel stream can't be dropped.

    // ---- PACK: pair even/odd 565 pixels into one 32-bit half + its DDR word. ----
    reg        have_lo;                      // even-index 565 latched, awaiting pair
    reg [15:0] lo_px;
    reg [19:0] lo_idx;

    // ---- RUN buffer + burst engine ----
    reg  [31:0] run_mem [0:BURST_MAX-1];
    reg  [4:0]  run_len;                     // words buffered (0..16)
    reg  [28:0] run_base;                    // DDR word address of run_mem[0]
    reg  [28:0] run_next;                    // expected DDR word addr of the next word

    reg         bst_busy = 1'b0;             // 1 = DRAIN: streaming the burst
    reg  [4:0]  bst_beat = 5'd0;             // beat index presented (0..run_len-1)
    reg         bst_sel  = 1'b0;             // fb_sel_upper latched at DRAIN entry:
                                             // the half-mask must stay constant for
                                             // every beat of a burst, even if a reset
                                             // clears the reg file mid-drain

    // pending break-word: a packed word that couldn't extend the run (non-contig or
    // full) and must seed the NEXT run once this one has drained.
    reg         hold_v;
    reg  [31:0] hold_half;
    reg  [28:0] hold_addr;
    reg         we_d;                        // for idle-gap detection

    // this cycle's packed word (combinational: the odd pixel completes a pair).
    // pk_addr: the even pixel's linear index >>1 = its DDR 64-bit-word offset (2
    // px/word). {10'd0, lo_idx[19:1]} is 29 bits to match fb_base_word.
    //
    // Pixel order within the 32-bit half: EVEN (lower-index, latched in lo_px) -> LOW
    // 16 [15:0], ODD (this cycle) -> HIGH 16 [31:16], i.e. {odd, even}. This matches
    // the scanout. (Tried {even, odd} to fix an apparent pair-swap - it made the image
    // WORSE, so this order is correct; the swap artifact is elsewhere - likely TSP-
    // pipeline ordering of pix_idx, not the pack order.)
    wire [31:0] pk_half  = {argb_to_565(fbw_req.argb), lo_px};
    wire [28:0] pk_addr  = fb_base_word + {10'd0, lo_idx[19:1]};
    wire        pk_contig= run_len!=5'd0 && (pk_addr == run_next);

    // Stall the core only while draining (can't accept into the run during a burst).
    assign fbw_resp.busy = bst_busy;

    // ---- DDRAM2 burst outputs (driven in DRAIN) ----
    assign DDRAM2_WE       = bst_busy;
    assign DDRAM2_ADDR     = run_base;
    assign DDRAM2_BURSTCNT = {3'd0, run_len};
    assign DDRAM2_DIN      = bst_sel ? {32'd0, run_mem[bst_beat]}
                                     : {run_mem[bst_beat], 32'd0};
    assign DDRAM2_BE       = bst_sel ? 8'b0000_1111 : 8'b1111_0000;

    always @(posedge clk) begin
        if (reset) begin
            // Pairing/run bookkeeping clears, but an IN-FLIGHT BURST IS NOT
            // ABORTED: the f2sdram port has already latched BURSTCNT and
            // counts raw data beats - dropping WE short leaves the hard
            // bridge expecting the missing beats forever. It then eats the
            // next burst's first beats as this one's tail, shifting every
            // subsequent FB write by the shortfall; that desync lives in the
            // HPS bridge, survives every fabric-side reset, and only clears
            // on reprogramming. So the DRAIN branch below keeps streaming
            // under reset until the burst completes - the leftover beats
            // rewrite stale FB bytes at their original addresses, harmless.
            have_lo <= 1'b0; we_d <= 1'b0; hold_v <= 1'b0;
            if (!bst_busy) run_len <= 5'd0;
        end else begin
            we_d <= fbw_req.we && !fbw_resp.busy;

            if (!bst_busy) begin
                // ================= ACCUM =================
                // idle gap: core presented no pixel this or last cycle -> flush a
                // partial run so the tile's last words aren't stranded.
                if (!(fbw_req.we && !fbw_resp.busy) && !we_d && run_len!=5'd0) begin
                    bst_busy <= 1'b1; bst_beat <= 5'd0;      // -> DRAIN what we have
                    bst_sel  <= fb_sel_upper;
                end

                if (fbw_req.we) begin
                    if (!have_lo) begin
                        // even pixel: latch, wait for the odd pair
                        have_lo <= 1'b1;
                        lo_px   <= argb_to_565(fbw_req.argb);
                        lo_idx  <= fbw_req.pix_idx;
                    end else begin
                        // odd pixel: we now have a full packed word (pk_*)
                        have_lo <= 1'b0;
                        if (run_len==5'd0) begin
                            // start a fresh run
                            run_mem[0] <= pk_half;
                            run_base   <= pk_addr;
                            run_next   <= pk_addr + 29'd1;
                            run_len    <= 5'd1;
                        end else if (pk_contig && run_len!=BURST_MAX[4:0]) begin
                            // extend the contiguous run
                            run_mem[run_len] <= pk_half;
                            run_next         <= run_next + 29'd1;
                            run_len          <= run_len + 5'd1;
                        end else begin
                            // BREAK (non-contiguous) or run FULL: stash this word and
                            // drain the current run; the stashed word seeds the next.
                            hold_v    <= 1'b1;
                            hold_half <= pk_half;
                            hold_addr <= pk_addr;
                            bst_busy  <= 1'b1; bst_beat <= 5'd0;   // -> DRAIN
                            bst_sel   <= fb_sel_upper;
                        end
                    end
                end
            end
        end

        // ================= DRAIN =================
        // stream run_mem[0..run_len-1] as one burst (one beat / !BUSY cycle).
        // Runs UNDER RESET too - the accepted burst must complete (see the
        // reset note above).
        if (bst_busy && !DDRAM2_BUSY) begin
            if (bst_beat + 5'd1 >= run_len) begin
                // burst done: re-seed from a held break-word, else empty.
                bst_busy <= 1'b0;
                bst_beat <= 5'd0;
                if (hold_v && !reset) begin
                    run_mem[0] <= hold_half;
                    run_base   <= hold_addr;
                    run_next   <= hold_addr + 29'd1;
                    run_len    <= 5'd1;
                    hold_v     <= 1'b0;
                end else begin
                    run_len <= 5'd0;
                end
            end else begin
                bst_beat <= bst_beat + 5'd1;
            end
        end
    end
endmodule

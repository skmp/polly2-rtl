//
// vo - PVR VIDEO OUT (framebuffer write-out) master.
//
// Takes peel_core's shaded-pixel stream (the `fbw` port) and writes it to
// memory through an injected Avalon-style 64-bit DDR WRITE port. Both ports
// are injected so this block is reusable: the DE10-nano integration
// (simplex_pvr_top) hands it the emu DDRAM2_* channel, a sim wrapper can hand
// it a behavioral memory model.
//
// FRAMEBUFFER WRITE master (BURSTING, all FB_W_CTRL fb_packmode formats,
// 32-bit "split" area or the dense 64-bit render-to-texture mirror).
//
// peel_core presents <=1 shaded ARGB8888 pixel/cycle with its screen
// coordinate (px, py). FULLY STREAMING: one pixel per cycle is accepted and
// every stage below works concurrently on a different pixel.
//
//  hs: SCALER_CTL.hscale x-scaling - horizontally-adjacent pixel PAIRS
//      are averaged per channel ((even+odd)>>1) into ONE pixel at
//      px>>1: a 1280-wide render writes out 640 wide (supersampled
//      anti-aliasing), a 640-wide one 320 wide (pairs with the display
//      side's VO_CONTROL.pixel_double). The VO streams tile rows
//      x-ascending, so pairing is positional (even latches, odd
//      emits).
//  p0: register the produced (post-hs) pixel and READ THE BAYER ROM for it.
//      The dither bias is a synchronous 16x8 ROM lookup (block-RAM
//      inferrable), so it needs its own stage; that also splits the old
//      one-cycle convert path (py*stride multiply + the quantizer adder
//      chains were in series) across two clocks.
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
//  C : the run/burst engine: ADDRESS-CONTIGUOUS beats accumulate in a run
//      buffer (up to BURST_MAX) and drain as ONE Avalon burst with PER-BEAT
//      byte enables (f2sdram_safe_terminator passes BE per beat). There are
//      TWO run buffers, PING-PONGED: the accumulator fills one while the
//      burst engine drains the other, so a drain no longer stalls the pixel
//      stream (it used to cost one core cycle per beat - 2.0 cyc/px for
//      8888, 1.5 for 16bpp). The core is stalled only when a run must be
//      handed off while the previous one is STILL draining, i.e. only when
//      DDR itself is the bottleneck. A beat that can't extend the run
//      (non-contiguous / full) starts the next buffer directly; an idle gap
//      cascades a flush s1 -> A -> B -> run -> hand-off so a tile's tail is
//      never stranded.
//
// Both run buffers live in ONE simple-dual-port memory (write port =
// accumulator, read port = burst engine, never the same address in a cycle
// since the two sides always work on different buffers), synchronous read,
// so it infers block RAM (M10K) instead of ~1.2 kbit of registers + muxes.
//
module vo import tsp_pkg::*; #(
    // Beats per burst = beats per run buffer. Power of two. Two buffers of
    // this depth share one memory ({buffer, index} addressing).
    parameter integer BURST_MAX = 16
) (
    input             clk,           // core clock
    input             reset,         // active-high synchronous reset

    // ---- live PVR registers (from peel_core's own reg file) ----
    // Only the four the write-out actually needs, taken directly rather than as
    // the whole pvr_regs_t: format/dither/K/alpha-threshold, write base (bit 24
    // = dense RTT mirror, bit 22 = split-area bank), line stride, and the
    // hscale bit.
    input  fb_w_ctrl_reg_t       fb_w_ctrl,
    input                 [31:0] fb_w_sof1,
    input  fb_w_linestride_reg_t fb_w_linestride,
    input  scaler_ctl_reg_t      scaler_ctl,

    // ================= PIXEL port (from peel_core) =================
    input  fb_wr_req_t  fbw_req,
    output fb_wr_resp_t fbw_resp,

    // ================= DDR WRITE port (Avalon-style) ===============
    // ddr_busy == Avalon waitrequest. Byte enables are presented PER BEAT.
    input             ddr_busy,
    output      [7:0] ddr_burstcnt,
    output     [28:0] ddr_addr,       // raw 64-bit-word offset
    output     [63:0] ddr_din,
    output      [7:0] ddr_be,
    output            ddr_we
);
    localparam integer LW = $clog2(BURST_MAX);   // beat index bits per buffer

    // exact x/255 for x <= 16383: (x + (x>>8) + 1) >> 8
    function automatic [5:0] div255(input [13:0] x);
        reg [14:0] t;
        t = {1'b0, x} + {9'd0, x[13:8]} + 15'd1;
        div255 = t[13:8];
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
    wire  [2:0] pm      = fb_w_ctrl.fb_packmode;
    wire        dith    = fb_w_ctrl.fb_dither;
    wire  [7:0] kval    = fb_w_ctrl.fb_kval;
    wire  [7:0] ath     = fb_w_ctrl.fb_alpha_threshold;
    wire [11:0] stride8 = {fb_w_linestride.stride, 3'b000};   // bytes/line
    wire        wrtt    = fb_w_sof1[24];   // dense 64-bit-view mirror
    wire [22:0] wbase   = wrtt ? fb_w_sof1[22:0]
                               : {1'b0, fb_w_sof1[21:0]};

    // ---- hs: SCALER_CTL.hscale pixel pairer (x 1/2, per-channel average) ----
    wire        hs_en = scaler_ctl.hscale;
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

    // ---- 4x4 Bayer dither bias ROM: refsw2's bayerBias[y&3][x&3] ----
    // (= 4x4 Bayer * 16 + 8). Read SYNCHRONOUSLY off {py[1:0], px[1:0]} so the
    // table is a memory the fitter can drop into an M10K instead of building
    // the case tree out of logic; its output register IS the p0 stage.
    (* ramstyle = "M10K" *) reg [7:0] bayer_rom [0:15];
    initial begin
        bayer_rom[ 0] = 8'd8;    bayer_rom[ 1] = 8'd136;
        bayer_rom[ 2] = 8'd40;   bayer_rom[ 3] = 8'd168;
        bayer_rom[ 4] = 8'd200;  bayer_rom[ 5] = 8'd72;
        bayer_rom[ 6] = 8'd232;  bayer_rom[ 7] = 8'd104;
        bayer_rom[ 8] = 8'd56;   bayer_rom[ 9] = 8'd184;
        bayer_rom[10] = 8'd24;   bayer_rom[11] = 8'd152;
        bayer_rom[12] = 8'd248;  bayer_rom[13] = 8'd120;
        bayer_rom[14] = 8'd216;  bayer_rom[15] = 8'd88;
    end
    wire [3:0] bt_addr = {fbw_req.py[1:0], sel_px[1:0]};

    // ---- p0: the produced pixel + its Bayer bias, registered ----
    reg        p0_v = 1'b0;                  // a pixel was produced (post-hs)
    reg        p0_wr;                        // ... and it produces a write
    reg [31:0] p0_argb;
    reg [10:0] p0_px;
    reg  [9:0] p0_py;
    reg  [7:0] p0_bt;                        // bayer_rom[bt_addr]

    // ---- s0 (comb on the p0 pixel): convert + address ----
    wire [7:0] c_a = p0_argb[31:24], c_r = p0_argb[23:16],
               c_g = p0_argb[15:8],  c_b = p0_argb[7:0];
    wire [7:0] bT  = dith ? p0_bt : 8'd0;

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

    wire [21:0] s0_row  = p0_py * stride8;
    wire [13:0] s0_xoff = pm[2] ? ((pm == 3'd4) ? {2'b00, p0_px, 1'b0} + {3'd0, p0_px}
                                                : {1'b0, p0_px, 2'b00})
                                : {2'b00, p0_px, 1'b0};
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

    // ---- stage C: the two ping-pong run buffers (one dual-port memory) ----
    // Address = {buffer, beat index}. Write port: the accumulator, into the
    // buffer selected by acc_sel. Read port: the burst engine, out of dr_sel.
    // acc_sel != dr_sel whenever a drain is running, so the two ports never
    // touch the same address and the memory needs no read-during-write mode.
    (* ramstyle = "M10K" *) reg [63:0] run_d  [0:2*BURST_MAX-1];
    (* ramstyle = "M10K" *) reg  [7:0] run_be [0:2*BURST_MAX-1];
    reg [63:0] q_d;                          // registered read data == ddr_din
    reg  [7:0] q_be;

    reg        acc_sel;                      // buffer being filled
    reg [LW:0] acc_len;                      // beats buffered in it (0..BURST_MAX)
    reg [28:0] acc_base;                     // DDR word address of its beat 0
    reg [28:0] acc_next;                     // expected DDR word addr of the next beat

    reg        dr_busy = 1'b0;               // 1 = DRAIN: streaming a burst
    reg        dr_sel;                       // buffer being drained
    reg [LW:0] dr_len;                       // its beat count (== burstcount)
    reg [LW-1:0] dr_ptr;                     // beat index presented
    reg [28:0] dr_base;

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

    // idle-gap flush trigger: no pixel OFFERED this cycle and none left in the
    // pixel stages, so the partial word/beat/run can never be extended.
    // Deliberately keyed on fbw_req.we, NOT on `acc`: `acc` is gated by
    // fbw_resp.busy, which stall_c drives from emB_v - i.e. from fl_idle - so
    // using it here would close a combinational loop. A pixel that is offered
    // but held off (stall_c / a_stall) is still in flight, so suppressing the
    // flush for it is also the behaviour we want.
    wire acc     = fbw_req.we && !fbw_resp.busy;
    wire fl_idle = !fbw_req.we && !p0_v && !s1_v;

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
    wire        b_hi = wrtt ? emA_w[0] : fb_w_sof1[22];
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

    // ---- stage C control ----
    // An emitted beat either starts the (empty) run, extends it, or BREAKS it -
    // and a break hands the full run to the burst engine and opens the next
    // buffer with that beat as its first. An idle gap hands off whatever is
    // buffered. Either hand-off needs the OTHER buffer free (no drain running);
    // if it isn't, the pixel pipeline freezes (fbw_resp.busy) until it is.
    wire       run_ext   = (acc_len != 0) && (emB_addr == acc_next)
                                          && (acc_len != BURST_MAX[LW:0]);
    wire       brk       = emB_v && (acc_len != 0) && !run_ext;
    wire       idle_hand = !emB_v && fl_idle && !aw_v && !bw_v && (acc_len != 0);
    wire       hand      = (brk || idle_hand) && !dr_busy && !reset;
    wire       stall_c   = brk && dr_busy;

    // Stall the core while a hand-off waits on the previous drain, or for the
    // rare two-emission pixel.
    assign fbw_resp.busy = stall_c || a_stall;

    // ---- run memory ports ----
    // write: the emitted beat, into the current buffer (or beat 0 of the next
    //        one when it breaks the run)
    wire            mem_wr  = emB_v && !stall_c;
    wire            w_sel   = brk ? ~acc_sel : acc_sel;
    wire [LW-1:0]   w_idx   = brk ? {LW{1'b0}} : acc_len[LW-1:0];
    // read: one beat ahead of the burst engine - the address applied this cycle
    //       is the beat presented NEXT cycle, so q_d/q_be ARE ddr_din/ddr_be.
    //       Held while the slave stalls (ddr_busy), pointed at beat 0 of the
    //       buffer being handed off on the hand-off cycle itself.
    wire [LW:0]     dr_ptr_p1 = {1'b0, dr_ptr} + {{LW{1'b0}}, 1'b1};
    wire            beat_go   = dr_busy && !ddr_busy;
    wire            r_sel     = hand ? acc_sel : dr_sel;
    wire [LW-1:0]   r_idx     = hand    ? {LW{1'b0}}
                              : beat_go ? dr_ptr_p1[LW-1:0]
                                        : dr_ptr;

    always @(posedge clk) begin
        if (mem_wr) begin
            run_d [{w_sel, w_idx}] <= emB_d;
            run_be[{w_sel, w_idx}] <= emB_be;
        end
        q_d  <= run_d [{r_sel, r_idx}];
        q_be <= run_be[{r_sel, r_idx}];
    end

    // ---- DDR write outputs (driven in DRAIN) ----
    assign ddr_we       = dr_busy;
    assign ddr_addr     = dr_base;
    assign ddr_burstcnt = {{(8-LW-1){1'b0}}, dr_len};
    assign ddr_din      = q_d;
    assign ddr_be       = q_be;

    // ==================================================================
    // pixel pipeline + run accumulation
    // ==================================================================
    always @(posedge clk) begin
        if (reset) begin
            // The pixel stages and the ACCUMULATING run clear. The DRAIN side
            // below is untouched: an in-flight burst must complete (see its
            // note), and acc_sel/dr_sel are never reset either - they already
            // point at different buffers, so the restarted accumulator cannot
            // scribble on the buffer that is still streaming out.
            p0_v <= 1'b0; s1_v <= 1'b0; aw_v <= 1'b0; bw_v <= 1'b0;
            acc_len <= {(LW+1){1'b0}};
        end else if (!stall_c) begin
            // hs: latch the even-x pixel of an hscale pair
            if (acc && hs_en && !fbw_req.px[0]) hs_argb <= fbw_req.argb;

            // p0 + s1 load (held while a_stall splits a two-emission pixel)
            if (!a_stall) begin
                p0_v <= acc;
                if (acc) begin
                    p0_wr   <= px_pass;
                    p0_argb <= sel_argb;
                    p0_px   <= sel_px;
                    p0_py   <= fbw_req.py;
                    p0_bt   <= bayer_rom[bt_addr];
                end

                s1_v <= p0_v && p0_wr;
                if (p0_v) begin
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

            // stage C accumulation (the beat itself is written to run_d above)
            if (emB_v && (acc_len == 0)) begin          // opens a run
                acc_base <= emB_addr;
                acc_next <= emB_addr + 29'd1;
                acc_len  <= {{LW{1'b0}}, 1'b1};
            end else if (emB_v && run_ext) begin        // extends it
                acc_next <= acc_next + 29'd1;
                acc_len  <= acc_len + {{LW{1'b0}}, 1'b1};
            end else if (hand) begin                    // handed to the drain
                acc_sel  <= ~acc_sel;
                if (brk) begin                          // ... and reopened here
                    acc_base <= emB_addr;
                    acc_next <= emB_addr + 29'd1;
                    acc_len  <= {{LW{1'b0}}, 1'b1};
                end else begin
                    acc_len  <= {(LW+1){1'b0}};
                end
            end
        end
    end

    // ==================================================================
    // DRAIN: stream the handed-off buffer as one burst (one beat per !ddr_busy
    // cycle). Runs UNDER RESET too, and is never aborted: the f2sdram port has
    // already latched BURSTCNT and counts raw data beats - dropping WE short
    // leaves the hard bridge expecting the missing beats forever. It then eats
    // the next burst's first beats as this one's tail, shifting every
    // subsequent FB write by the shortfall; that desync lives in the HPS
    // bridge, survives every fabric-side reset, and only clears on
    // reprogramming. So the burst always finishes - the leftover beats rewrite
    // stale FB bytes at their original addresses, harmless. (BE is captured per
    // beat at append time, so a mid-drain reg file clear cannot change the mask
    // of an in-flight burst.) `hand` is gated on !reset, so no NEW burst starts
    // out of a resetting pipeline.
    // ==================================================================
    always @(posedge clk) begin
        if (hand) begin
            dr_busy <= 1'b1;
            dr_sel  <= acc_sel;
            dr_len  <= acc_len;
            dr_base <= acc_base;
            dr_ptr  <= {LW{1'b0}};
        end else if (beat_go) begin
            if (dr_ptr_p1 >= dr_len) dr_busy <= 1'b0;
            dr_ptr <= dr_ptr_p1[LW-1:0];
        end
    end
endmodule

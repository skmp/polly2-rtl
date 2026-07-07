//
// tex_fetch_pp - STREAMING single-texel fetch/decode over the pipelined tex_cache_4p
// port protocol. Accepts a NEW texel request EVERY cycle (valid/ready) and emits
// results IN ISSUE ORDER; it stalls (deasserts in_ready) ONLY when the underlying
// cache stalls on a genuine miss-fill. On an all-hit stream it sustains 1 texel/clk.
//
// Same texel math as before (tex_addr -> data cache -> optional VQ codebook read ->
// palette/decode). ORDERING IS FREE: the cache returns acks strictly in issue order
// per port, so a small side-data FIFO popped on ack reconstructs each result. There
// is exactly ONE path:
//
//   ISSUE : every accepted pixel issues a data-cache read (tc_req). NON-textured
//           pixels also issue one (harmless read; their decoded colour is forced to 0)
//           so they stay in the same in-order stream as textured pixels - no bypass
//           reorder logic. Side data (pixfmt/scan/offset/vq/palsel/vq_bytesel/tcw_addr
//           + a "textured" bit) is pushed into fifo_tc.
//   TC-ACK: tc_resp.ack pops fifo_tc (in order). VQ pixel -> issue vq_req from memtel,
//           push side into fifo_vq. Non-VQ (or non-textured) -> straight to DECODE.
//   VQ-ACK: vq_resp.ack pops fifo_vq -> memtel = vq codebook word -> DECODE.
//   DECODE: tex_decode(memtel, side) -> argb (forced 0 if !textured); out_valid.
//
// Because tcw (hence VQ-ness) is uniform across the four bilinear corners and, within
// a shade sub-phase, constant per triangle, the tc ack stream and the vq ack stream
// are each individually in-order and never collide (a non-VQ tc-ack and a vq-ack in
// the same cycle cannot both correspond to real texels of one uniform texture). The
// vq path is prioritised on the (workload-impossible) collision.
//
// PROTOCOL:
//   in_valid    : a new texel request is presented this clock
//   in_textured : 0 = non-textured pixel (flows through, argb forced to 0)
//   in_ready    : the fetcher can accept it this clock (== cache can accept a tc req)
//   out_valid   : argb corresponds to a completed fetch this clock (in issue order)
//   out_ready   : the consumer can accept a result this clock (BACKPRESSURE). When low,
//                 the completion pointer holds and results stay parked in the slot ring;
//                 the tc->vp->vq cache trips continue (acks cannot be deferred). Required
//                 so a corner that races ahead of its siblings (their cache still filling)
//                 cannot overrun the downstream corner-join FIFO.
//
module tex_fetch_pp import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             in_valid,
    input             in_textured,  // 0 = non-textured pixel: flow through, argb=0
    output            in_ready,
    input      [10:0] u,
    input      [10:0] v,
    input      [3:0]  miplevel,     // selected mip level (0 = base)
    input      [31:0] tsp,
    input      [31:0] tcw,
    input      [4:0]  text_ctrl,
    input             out_ready,    // consumer backpressure (see PROTOCOL above)
    output reg        out_valid,
    output reg [31:0] argb,

    // injected caches: data (texel/index) + VQ codebook (tex_cache_4p port protocol)
    output cache_req_t   tc_req,
    input  cache_resp_t  tc_resp,
    output cache_req_t   vq_req,
    input  cache_resp_t  vq_resp
);
    // ---- decode of the CURRENT (incoming) request; tex_addr is combinational ----
    wire [2:0]  in_texu = tsp[5:3], in_texv = tsp[2:0];
    wire [20:0] in_tcw_addr = tcw[20:0];
    wire        in_strdsel = tcw[25], in_scan = tcw[26];
    wire [2:0]  in_pixfmt = tcw[29:27];
    wire        in_vq = tcw[30];
    wire        in_mipmapped = tcw[31];
    wire [5:0]  in_palsel = tcw[26:21];

    wire [28:0] ta_byte; wire [2:0] ta_fbpp_shr; wire [19:0] ta_off;
    tex_addr u_ta (
        .tcw_addr(in_tcw_addr),.vq(in_vq),.scan(in_scan),.stride_sel(in_strdsel),
        .mipmapped(in_mipmapped),.pixfmt(in_pixfmt),
        .texu(in_texu),.texv(in_texv),.miplevel(miplevel),.text_ctrl(text_ctrl),
        .u(u),.v(v),
        .byte_addr(ta_byte),.fbpp_shr(ta_fbpp_shr),.offset(ta_off));

    // side-data bundle carried with each request. Field layout (MSB..LSB):
    //   [42] textured  [41:39] pixfmt  [38] scan  [37:34] off_lo  [33:31] off_bytesel
    //   [30] vq  [29:27] vq_bytesel  [26:6] tcw_addr  [5:0] palsel
    localparam integer SW = 1+3+1+4+3+1+3+21+6;   // = 43
    wire [SW-1:0] in_side = { in_textured, in_pixfmt, in_scan, ta_off[3:0], ta_byte[2:0],
                              in_vq, ta_byte[2:0], in_tcw_addr, in_palsel };

`ifndef SYNTHESIS
    // -------- tex_addr VECTOR DUMP (sim only) -----------------------------------------
    // One line per accepted texel request. Captures tex_addr INPUTS (tcw fields, texu/
    // texv, mip, u, v) and OUTPUTS (byte_addr, fbpp_shr, offset) so tex_addr can be
    // regression-tested standalone: given the inputs it must reproduce byte_addr/offset.
    // A twiddle/offset bug shows here as a byte_addr that doesn't match a correct twop().
    // Enabled with +texdump[=<file>] (default tex_vectors.log). Guarded so only ONE of
    // the 4 corner fetchers writes (avoids 4x duplicate files clobbering each other):
    // the caller passes +texdump and every corner opens the SAME name in APPEND, but to
    // keep lines coherent we only dump when this instance won the open (fd!=0).
    integer      txd_fd = 0;
    reg          txd_en = 1'b0;
    reg [1023:0] txd_name;
    integer      txd_seq = 0;
    initial begin
        if ($value$plusargs("texdump=%s", txd_name)) txd_en = 1'b1;
        else if ($test$plusargs("texdump")) begin txd_en = 1'b1; txd_name = "tex_vectors.log"; end
        if (txd_en) begin
            // append mode: all 4 corner instances share one file (interleaved but each
            // line is self-contained: it carries its own u,v). Header written once by
            // whichever instance opens first (harmless if repeated).
            txd_fd = $fopen(txd_name, "a");
        end
    end
    always @(posedge clk) begin
        if (!reset && txd_en && accept && in_textured) begin
            $fwrite(txd_fd, "%08x %0d %0d %0d %0d %0d %0d %0d %0d %0d  %07x %0d %05x\n",
                    tcw, in_vq, in_scan, in_strdsel, in_mipmapped, in_pixfmt,
                    in_texu, in_texv, u, v,
                    ta_byte, ta_fbpp_shr, ta_off);
            txd_seq = txd_seq + 1;
        end
    end
    final if (txd_en && txd_fd != 0) begin $fflush(txd_fd); $fclose(txd_fd); end
`endif

    // ============================================================================
    // FIXED-LATENCY PIPELINE (no FIFO, no reorder). Assumes the injected caches reply with
    // 1-CYCLE latency and HOLD internally on a miss: a request presented while resp.ready
    // is accepted and its {data} arrives the NEXT cycle; a miss simply keeps resp.ready low
    // until the fill completes (the fetcher never sees a NOT_OK, only a late accept). Every
    // pixel - VQ or not - traverses the SAME stages, so results leave in ISSUE ORDER at
    // 1 pixel/clock:
    //
    //   T0 : present tc_req (data cache) ; accepted when tc_resp.ready
    //   T1 : tc_resp.rdata is the tc word. If this pixel is VQ, present vq_req NOW (its
    //        codebook address is derived from the tc word this cycle). NON-VQ presents no
    //        vq_req -> the VQ cache is never polluted (matched-delay bubble through T2).
    //   T2 : vq_resp.rdata is the codebook word (VQ only); non-VQ carries its tc word.
    //   D  : tex_decode -> argb -> out_valid
    //
    // ONE global clock-enable `adv` shifts the whole pipe together, so there is never a
    // second in-flight result to buffer. It stalls when a stage needs a cache accept it
    // can't get this cycle (miss-fill: resp.ready low) or when out_ready is low.
    // ============================================================================

    // stage registers. The pixel enters T1 the cycle its tc word LANDS (one cycle after
    // accept), so T1 always holds {side, tc word} that agree. T0 (t0_*) is the 1-cycle
    // latch between accept and tc-landing.
    //   T0 : accepted, tc read in flight   (t0_v/t0_s)
    //   T1 : tc word landed + held         (t1_v/t1_s/t1_mem); if VQ, issue vq_req here
    //   T2 : vq word landed (VQ) / tc word (non-VQ)  (t2_v/t2_s/t2_mem)
    //   D  : decode
    reg          t0_v, t1_v, t2_v;
    reg [SW-1:0] t0_s, t1_s, t2_s;
    reg [63:0]   t0_mem;                        // HELD tc word for the T0 pixel (captured
                                                //   the cycle it lands, so a downstream
                                                //   stall never loses it)
    reg          t0_dv;                         // t0_mem valid (tc word captured)
    reg [63:0]   t1_mem;                        // HELD tc word for the T1 pixel
    reg [63:0]   t2_mem;                        // HELD resolved word (tc for non-VQ; vq
                                                //   codebook word once its read completes)
    reg          t2_dv;                         // t2_mem holds this pixel's final word

    // T1 pixel VQ-ness + its derived codebook address (from the HELD tc word).
    wire         t1_isvq   = t1_s[30] && t1_s[42];
    wire [2:0]   t1_vqbsel = t1_s[29:27];
    wire [20:0]  t1_taddr  = t1_s[26:6];
    wire [7:0]   t1_vqbyte = t1_mem[8*t1_vqbsel +: 8];
    wire [28:0]  t1_vqaddr = {8'd0, t1_taddr} + {21'd0, t1_vqbyte};
    wire         t2_isvq   = t2_s[30] && t2_s[42];

    // ---- PER-STAGE ADVANCE. Two 1-cycle caches (tc, vq) each hold `ready` low + stop
    //      acking during their own miss-fill. Cache rdata/ack is valid only the cycle after
    //      accept, so each stage CAPTURES its result the instant it lands (independent of a
    //      downstream stall) and advances only into a free successor. Computed output-first.
    //
    //   D  : drains when out_ready (tied high by the lockstep join, kept general).
    //   T2 : holds the VQ result. Captures vq word when vq_resp.ack lands (VQ); non-VQ has no
    //        2nd trip and is "done" on entry. Advances to D when done + D free.
    //   T1 : issues the VQ read; advances to T2 when its vq_req is ACCEPTED (vq_resp.ready)
    //        - or immediately for non-VQ - and T2 free.
    //   T0 : captures the tc word (tc_resp.ack); advances to T1 when captured + T1 free.
    //   in : accept when T0 free and the tc cache ready.
    wire d_adv   = out_ready;
    wire d_free  = !d_v || d_adv;

    // T2 result "here": non-VQ done on entry (t2_dv set at load); VQ when vq word captured
    // (t2_dv) or landing this cycle (vq_resp.ack). t2_word = the resolved memtel.
    wire t2_here  = t2_dv || (t2_v && t2_isvq && vq_resp.ack);
    wire [63:0] t2_word = t2_dv ? t2_mem : vq_resp.rdata;
    wire t2_adv   = t2_v && t2_here && d_free;
    wire t2_free  = !t2_v || t2_adv;

    wire vq_need  = t1_v && t1_isvq;   // t1_isvq gates on [42] textured -> never set if bypass
    wire t1_okvq  = !vq_need || vq_resp.ready;                 // VQ read accepted this cycle
    wire t1_adv   = t1_v && t1_okvq && t2_free;
    wire t1_free  = !t1_v || t1_adv;

    // T0's tc word is "here" if already captured (t0_dv) or landing this cycle (tc_resp.ack).
    // Per-pixel texture bypass: a NON-textured pixel (in_textured=0, from ISP.texture) does
    // NOT need a texel, so it must NOT issue a cache request or wait on the cache to accept -
    // it flows through the stages (argb forced 0) at 1/clk. Only TEXTURED pixels gate on the
    // cache. This removes the fetch-slot backpressure that non-textured pixels used to pay.
    // t0_bypass = the T0 pixel is non-textured (its side[42]=textured bit is 0).
    wire t0_bypass = t0_v && !t0_s[42];
    wire t0_here  = t0_bypass || t0_dv || (t0_v && tc_resp.ack);
    wire [63:0] t0_word = t0_dv ? t0_mem : tc_resp.rdata;
    wire t0_adv   = t0_v && t0_here && t1_free;
    wire t0_free  = !t0_v || t0_adv;

    // ---- T0 issue: accept a new pixel when T0 is free. A textured pixel also needs the tc
    //      cache ready (it will issue a tc_req); a non-textured pixel needs no cache. ----
    assign in_ready   = t0_free && (!in_textured || tc_resp.ready);
    wire   accept     = in_valid && in_ready;
    assign tc_req.req   = accept && in_textured;   // only textured pixels read the cache
    assign tc_req.waddr = { 3'b0, ta_byte[28:3] };

    // ---- T1 vq issue: the T1 pixel, if VQ, reads its codebook word from the HELD tc word,
    //      but only when it can also advance (T2 free) so the vq word lands into a free T2. ----
    assign vq_req.req   = vq_need && t2_free && vq_resp.ready;
    assign vq_req.waddr = t1_vqaddr;

    // ============ DECODE stage (fed from T2) ============
    reg        d_v;
    reg [63:0] d_memtel;
    reg [SW-1:0] d_side;

    (* rom_style = "block" *) reg [31:0] pal_rom [0:255];
    integer pri;
    initial for (pri=0; pri<256; pri=pri+1)
        pal_rom[pri] = {8'hFF, pri[7:0], pri[7:0], pri[7:0]};
    wire        d_txd    = d_side[42];
    wire [2:0]  d_pixfmt = d_side[41:39];
    wire        d_scan   = d_side[38];
    wire [3:0]  d_off_lo = d_side[37:34];
    wire [2:0]  d_off_b  = d_side[33:31];
    wire [5:0]  d_palsel = d_side[5:0];
    wire [7:0]  pal8_local = d_memtel[8*d_off_b +: 8];
    wire [3:0]  pal4_nib   = d_memtel[4*d_off_lo +: 4];
    wire [7:0]  pal8_idx   = {d_palsel[5:4], pal8_local};
    wire [7:0]  pal4_idx   = {d_palsel[3:0], pal4_nib};
    wire [7:0]  d_pal_idx  = (d_pixfmt==3'd6) ? pal8_idx :
                             (d_pixfmt==3'd5) ? pal4_idx : 8'd0;
    wire [31:0] d_pal_argb = pal_rom[d_pal_idx];

    wire [31:0] dec_argb;
    tex_decode u_dec (.pixfmt(d_pixfmt),.scan(d_scan),.memtel(d_memtel),
                      .offset_lo(d_off_lo),.pal_argb(d_pal_argb),.argb(dec_argb));

    always @(posedge clk) begin
        if (reset) begin
            t0_v<=0; t0_dv<=0; t1_v<=0; t2_v<=0; t2_dv<=0; d_v<=0; out_valid<=0;
            // clear the payload/data regs too so a cold (post-reset) pipeline can never
            // decode an X/garbage side word into the first few results.
            t0_s<=0; t1_s<=0; t2_s<=0; d_side<=0;
            t0_mem<=0; t1_mem<=0; t2_mem<=0; d_memtel<=0; argb<=0;
        end else begin
            // ---- in -> T0 : accept a new pixel. Its tc read is now in flight; t0_dv=0 until
            //      the tc word lands (captured below). ----
            if (accept)      begin t0_v <= 1'b1; t0_s <= in_side; t0_dv <= 1'b0; end
            else if (t0_adv)       t0_v <= 1'b0;

            // ---- T0 tc capture: the tc word lands the cycle after accept; grab + HOLD it
            //      regardless of any downstream stall so it is never lost. (Skipped when T0
            //      is advancing this cycle - then t0_word feeds T1 directly.) ----
            if (t0_v && !t0_dv && tc_resp.ack && !t0_adv) begin
                t0_mem <= tc_resp.rdata; t0_dv <= 1'b1;
            end

            // ---- T0 -> T1 : carry side + the (held or just-landed) tc word (t1_s/t1_mem
            //      agree). ----
            if (t0_adv)      begin t1_v <= 1'b1; t1_s <= t0_s; t1_mem <= t0_word; end
            else if (t1_adv)       t1_v <= 1'b0;

            // ---- T1 -> T2 : load T2. non-VQ is DONE immediately (t2_dv=1, word = tc word);
            //      VQ has issued its vq read this cycle -> awaits its ack (t2_dv=0). ----
            if (t1_adv)      begin t2_v <= 1'b1; t2_s <= t1_s; t2_mem <= t1_mem;
                                   t2_dv <= !(t1_s[30] && t1_s[42]); end   // done unless VQ
            else if (t2_adv)       t2_v <= 1'b0;

            // ---- T2 vq capture: the VQ codebook word lands the cycle after its read was
            //      accepted; grab + HOLD it regardless of a downstream stall. (Skipped when
            //      T2 is advancing this cycle - then t2_word feeds DECODE directly.) ----
            if (t2_v && t2_isvq && !t2_dv && vq_resp.ack && !t2_adv) begin
                t2_mem <= vq_resp.rdata; t2_dv <= 1'b1;
            end

            // ---- T2 -> DECODE : the resolved word (tc for non-VQ, vq codebook for VQ). ----
            if (t2_adv)      begin d_v <= 1'b1; d_side <= t2_s; d_memtel <= t2_word; end
            else if (d_adv)        d_v <= 1'b0;

            // ---- DECODE -> OUT ----
            out_valid <= d_v && d_adv;
            if (d_v && d_adv) argb <= d_txd ? dec_argb : 32'h00000000;
        end
    end
endmodule

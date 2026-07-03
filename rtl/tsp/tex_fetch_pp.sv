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

    // fifo depths. A VQ pixel occupies tc, THEN vp, THEN vq before completing. The
    // hazard: tc acks fire on the DATA cache's schedule (cannot be deferred), so if the
    // VQ cache stalls (miss-fill) while tc keeps acking, every outstanding tc entry
    // drains into vp AT ONCE. So vp MUST be able to hold every in-flight tc entry, and
    // vq every in-flight vp entry. We enforce ONE occupancy invariant on issue:
    //   tc_cnt + vp_cnt + vq_cnt < CAP
    // i.e. the TOTAL entries anywhere in the tc->vp->vq chain is bounded, and each FIFO
    // is sized to CAP so the worst-case redistribution (all in one FIFO) never overflows.
    localparam integer FD = 32, FAW = 5;    // each FIFO holds up to CAP entries
    localparam integer CAP = 24;            // max total entries in flight (< FD, margin)

    // fifo_tc: side data for tc requests in flight (issue order).
    reg  [SW-1:0] tcf [0:FD-1];
    reg  [FAW-1:0] tc_h, tc_t; reg [FAW:0] tc_cnt;

    // ============ ISSUE ============
    // Accept only when the data cache is ready AND the whole tc->vp->vq chain has room
    // for one more (total-occupancy invariant), so no in-flight entry is ever dropped
    // even if the VQ cache stalls while tc acks stream in.
    wire vp_room;   // forward ref (needs vp_cnt/vq_cnt)
    assign in_ready   = tc_resp.ready && vp_room;
    wire   accept     = in_valid && in_ready;
    assign tc_req.req   = accept;                    // every accepted pixel reads tc
    assign tc_req.waddr = { 3'b0, ta_byte[28:3] };   // 64-bit word addr = byte>>3
    wire tc_push = accept;
    wire tc_pop  = tc_resp.ack;

    // ============ TC-ACK -> VQ or DECODE ============
    wire [SW-1:0] tc_side   = tcf[tc_h];
    wire          tc_txd    = tc_side[42];
    wire          tc_is_vq  = tc_side[30] && tc_txd;   // non-textured never chains vq
    wire [2:0]    tc_vqbsel = tc_side[29:27];
    wire [20:0]   tc_taddr  = tc_side[26:6];
    wire [63:0]   tc_memtel = tc_resp.rdata;
    wire [7:0]    vq_byte   = tc_memtel[8*tc_vqbsel +: 8];
    wire [28:0]   vq_addr   = {8'd0, tc_taddr} + {21'd0, vq_byte};

    // ============ IN-ORDER COMPLETION QUEUE ============
    // A mixed VQ / non-VQ stream (consecutive pixels can differ in tcw) MUST still emit
    // results in ISSUE ORDER - a fast non-VQ pixel may not overtake an earlier in-flight
    // VQ pixel (2 cache trips). We record, per issue position (ring index), the side data
    // + a "done" flag + the resolved memtel. Cache results mark their slot done whenever
    // they land (tc for non-VQ, vq for VQ); a COMPLETION POINTER `cp` drains slots in
    // strict issue order, so output order == issue order regardless of tc/vq timing.
    //
    //  tcf[] (below) is the issue-order side-data ring (write index = issue position).
    //  slot_done[i] / slot_mem[i] : set when position i's final memtel is known.
    //  cp : next issue position to emit (drains when slot_done[cp]).
    reg           slot_done [0:FD-1];
    reg  [63:0]   slot_mem  [0:FD-1];
    reg  [FAW-1:0] cp;                             // completion pointer (issue order)
    reg  [FAW:0]   oc_cnt;                         // outstanding (issued, not completed)

    // ---- VQ-PENDING FIFO: a VQ tc-ack derives a vq codebook address; the vq cache may
    // be filling, so buffer {vq_addr, issue_pos, side} and issue vq_req when ready. ----
    reg  [28:0]   vpf_addr [0:FD-1];
    reg  [FAW-1:0] vpf_pos [0:FD-1];               // issue position of this vq entry
    reg  [FAW-1:0] vp_h, vp_t; reg [FAW:0] vp_cnt;
    // total-occupancy invariant: bound tc+vp+vq so no single FIFO can overflow even
    // if the whole chain redistributes into one FIFO during a stall.
    assign vp_room = ((tc_cnt + vp_cnt + vq_cnt) < CAP);
    wire vp_ne   = (vp_cnt != 0);
    wire vp_push = tc_pop && tc_is_vq;            // a VQ tc-ack enqueues a pending vq req
    // issue the head pending vq req when the vq cache can accept it
    assign vq_req.req   = vp_ne && vq_resp.ready;
    assign vq_req.waddr = vpf_addr[vp_h];
    wire vp_pop  = vq_req.req;                     // pending entry consumed on issue

    // fifo_vq: issue-position of vq requests ISSUED (awaiting vq ack), in issue order
    reg  [FAW-1:0] vqf_pos [0:FD-1];
    reg  [FAW-1:0] vq_h, vq_t; reg [FAW:0] vq_cnt;
    wire vq_push = vq_req.req;                      // push when the vq req is issued
    wire vq_pop  = vq_resp.ack;

    // completion drains slot cp when it has an outstanding entry whose memtel is known
    wire cp_ready = (oc_cnt != 0) && slot_done[cp];

    // ============ DECODE stage register ============
    reg        d_v;
    reg [63:0] d_memtel;
    reg [SW-1:0] d_side;

    // palette ROM placeholder (ARGB8888) - matches tex_fetch
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

    integer ri;
    always @(posedge clk) begin
        if (reset) begin
            tc_h<=0; tc_t<=0; tc_cnt<=0;
            vp_h<=0; vp_t<=0; vp_cnt<=0;
            vq_h<=0; vq_t<=0; vq_cnt<=0;
            cp<=0; oc_cnt<=0;
            d_v<=0; out_valid<=0;
            for (ri=0; ri<FD; ri=ri+1) slot_done[ri] <= 1'b0;
        end else begin
            out_valid <= 1'b0;

            // ---- ISSUE: allocate an issue-order slot; mark not-done ----
            if (tc_push) begin
                tcf[tc_t] <= in_side; slot_done[tc_t] <= 1'b0; tc_t <= tc_t + 1'b1;
            end

            // ---- TC ack (in issue order at tc_h): non-VQ resolves its slot now; VQ
            //      enqueues a pending vq req carrying its issue position. ----
            if (tc_pop) begin
                if (tc_is_vq) begin
                    // handled by the vq path; slot stays not-done until vq ack
                end else begin
                    slot_done[tc_h] <= 1'b1; slot_mem[tc_h] <= tc_memtel;
                end
                tc_h <= tc_h + 1'b1;
            end
            tc_cnt <= tc_cnt + (tc_push?1:0) - (tc_pop?1:0);

            // ---- vq-pending FIFO (address + issue position) ----
            if (vp_push) begin
                vpf_addr[vp_t] <= vq_addr; vpf_pos[vp_t] <= tc_h; vp_t <= vp_t + 1'b1;
            end
            if (vp_pop)  vp_h <= vp_h + 1'b1;
            vp_cnt <= vp_cnt + (vp_push?1:0) - (vp_pop?1:0);

            // ---- fifo_vq: carry issue position of each issued vq req ----
            if (vq_push) begin vqf_pos[vq_t] <= vpf_pos[vp_h]; vq_t <= vq_t + 1'b1; end
            if (vq_pop) begin
                slot_done[vqf_pos[vq_h]] <= 1'b1;
                slot_mem [vqf_pos[vq_h]] <= vq_resp.rdata;   // codebook word replaces memtel
                vq_h <= vq_h + 1'b1;
            end
            vq_cnt <= vq_cnt + (vq_push?1:0) - (vq_pop?1:0);

            // ---- COMPLETION: drain slot cp IN ISSUE ORDER when its memtel is known ----
            d_v <= 1'b0;
            if (cp_ready) begin
                d_memtel <= slot_mem[cp];
                d_side   <= tcf[cp];
                d_v      <= 1'b1;
                cp <= cp + 1'b1;
            end
            // oc_cnt = issued - completed
            oc_cnt <= oc_cnt + (tc_push?1:0) - (cp_ready?1:0);

            // decode output (non-textured -> argb 0)
            if (d_v) begin
                argb      <= d_txd ? dec_argb : 32'h00000000;
                out_valid <= 1'b1;
            end
        end
    end
endmodule

//
// tex_fetch4_q - QUEUED + COALESCING 4-corner raw texel fetch. Drop-in replacement
// for tex_fetch4_ob (same ports, same output contract): 4 byte-offsets in -> 4 raw
// 64-bit memory words out, decode payload rides through, owns the two shared
// 4-read-port caches (data + VQ).
//
// Two ideas over the lockstep tex_fetch4_ob:
//
//  * WORD DEDUP + ROW PACKING. A pixel's 4 corner fetches usually collapse to 1-2
//    unique 64-bit words (a word is an aligned 2x2 16bpp twiddled block), and
//    CONSECUTIVE pixels' quads overlap. The front dedups each pixel's corner word
//    addresses within the pixel AND against the currently-open 4-slot ROW; a pixel
//    whose words are all already in the row consumes NO new slot. One row = ONE
//    grouped lookup over the 4 cache read ports (the 4 data copies are broadcast-
//    filled duplicates, so ANY address can be served by ANY port) serving 1..N
//    pixels' texels.
//
//  * FIFO DECOUPLING. Rows queue in ROWQ before the cache; fetched 256-bit row
//    data queues in DATQ after it; pixels ride PIXQ in order with per-corner
//    {row-slot, byte-lane} refs. While a miss is filling, the EXPANDER keeps
//    draining already-fetched rows to the filter and the front keeps accepting
//    pixels - an isolated fill no longer stalls the whole shade pipe, and after
//    a stall the backlog drains at up to one ROW (up to 4+ pixels) per lookup.
//
// PIPELINE:
//   F0   (reg)  : accepted pixel; corner word addrs wa[i] = tex_addr + off[i][21:3]
//   F1   (comb) : dedup wa[] against the open row + earlier corners -> refs; append
//                 (fits) or close the row to ROWQ and open a fresh one (first=1).
//                 Pushes the pixel {first,tex,vq,vqbase,refs,lanes,pl} to PIXQ.
//                 The open row also closes when F1 has nothing to process or the
//                 row AGES out (ROW_AGE cycles) - bounds the first-pixel wait.
//   LOOKUP      : pops ROWQ, presents slots 0..n-1 on cache ports 0..n-1 as one
//                 group (group-atomic ack, alias-livelock handling in the cache);
//                 on ack pushes the 4x64b row data to DATQ. Issue is credit-gated
//                 so a DATQ push can never overflow.
//   EX   (comb) : PIXQ head + its row (DATQ head on first=1, else the held row_q)
//                 -> the pixel's 4 corner words.
//   V1/V2 (reg) : the tex_fetch4_ob T1/T2 stages verbatim - VQ codebook lookup
//                 (4-port grouped, index = data-word byte lane) and the output
//                 drain-pulse contract (out_valid = the cycle texel[] resolves).
//
// Ordering: single in-order queues end to end - outputs emerge in exact input
// order (the shade pipe's payload-FIFO contract).
//
// flush (render start): forwarded to both caches (valid-sweep) AND clears the
// queues/packer/stages. peel_core only flushes between renders with the shade
// pipe idle, so everything should already be empty (asserted in sim).
//
module tex_fetch4_q import tsp_pkg::*; #(
    parameter integer PLW = 1              // decode payload bus width (rides with the pixel)
) (
    input             clk,
    input             reset,
    input             flush,
    input             in_valid,
    input             tex,                // TEX: textured pixel
    input             vq,                 // VQ:  VQ-compressed texture
    input      [20:0] tex_addr,           // data base (64-bit-word units)
    input      [20:0] vq_addr,            // VQ codebook base (64-bit-word units)
    input      [21:0] tex_offset [0:3],   // per-corner byte offsets
    input      [PLW-1:0] in_pl,
    output            in_ready,           // 0 = stall (queues full); hold inputs

    output            out_valid,
    output     [63:0] texel [0:3],        // raw 64-bit memory words (undefined if !tex)
    output     [PLW-1:0] out_pl,

    // two DDR read ports to the parent arbiter ([0]=tc data, [1]=vq codebook)
    output ddr_rd_req_t  ddr_req  [0:1],
    input  ddr_rd_resp_t ddr_resp [0:1]
);
    localparam integer QDEPTH  = 64;   // ROWQ / DATQ depth
    localparam integer PIXQ_D  = 256;  // PIXQ depth (the pixel budget: how far the
                                       // front can run ahead of the expander; also
                                       // bounds ROWQ's reachable occupancy at
                                       // ~PIXQ_D / pixels-per-row)
    localparam integer ROW_AGE = 4;    // max cycles a non-empty row stays open

    wire clear = reset || flush;

    // ---------------- shared 4-read-port caches (data + VQ) ----------------
    // The data cache gets the FILL-LOOKAHEAD probe: while it is frozen filling, the
    // ROWQ head (the very next lookup group) is presented on the probe port so its
    // first missing line is DDR-requested back-to-back with the current fill. The
    // VQ side has no queue ahead of it - probe tied off.
    cache_req_t   tc_req [0:3], vq_req [0:3];
    cache_resp_t  tc_resp[0:3], vq_resp[0:3];
    wire        tcp_valid;
    wire [3:0]  tcp_mask;
    wire [28:0] tcp_waddr [0:3];
    wire [28:0] vqp_waddr [0:3];
    assign vqp_waddr[0] = 29'd0; assign vqp_waddr[1] = 29'd0;
    assign vqp_waddr[2] = 29'd0; assign vqp_waddr[3] = 29'd0;
    tex_cache_4p_1c u_tc4 (.clk(clk),.reset(reset),.flush(flush),
        .creq(tc_req),.cresp(tc_resp),
        .probe_valid(tcp_valid),.probe_mask(tcp_mask),.probe_waddr(tcp_waddr),
        .dreq(ddr_req[0]),.dresp(ddr_resp[0]));
    tex_cache_4p_1c u_vq4 (.clk(clk),.reset(reset),.flush(flush),
        .creq(vq_req),.cresp(vq_resp),
        .probe_valid(1'b0),.probe_mask(4'd0),.probe_waddr(vqp_waddr),
        .dreq(ddr_req[1]),.dresp(ddr_resp[1]));

    wire tc_ready = tc_resp[0].ready;      // all ports gate together
    wire vq_ready = vq_resp[0].ready;
    wire tc_ack   = tc_resp[0].ack;        // slot 0 is always valid in a row group
    wire vq_ack   = vq_resp[0].ack;

    integer i;
    genvar  gi;

    // ============================ F0: input register ============================
    reg           f0_v;
    reg           f0_tex, f0_vq;
    reg  [20:0]   f0_vqbase;
    reg  [28:0]   f0_wa   [0:3];          // corner 64-bit-word addresses
    reg  [2:0]    f0_lane [0:3];          // byte lane within the word (VQ index select)
    reg  [PLW-1:0] f0_pl;

    wire f1_ok;                            // F1 can process f0 this cycle
    wire f0_adv = f0_v && f1_ok;
    assign in_ready = !f0_v || f0_adv;
    wire   accept   = in_valid && in_ready;

    always @(posedge clk) begin
        if (clear) begin
            f0_v <= 1'b0; f0_tex <= 1'b0; f0_vq <= 1'b0; f0_vqbase <= '0; f0_pl <= '0;
            for (i=0;i<4;i=i+1) begin f0_wa[i] <= '0; f0_lane[i] <= '0; end
        end else if (accept) begin
            f0_v      <= 1'b1;
            f0_tex    <= tex; f0_vq <= vq; f0_vqbase <= vq_addr;
            f0_pl     <= in_pl;
            for (i=0;i<4;i=i+1) begin
                f0_wa[i]   <= {8'd0, tex_addr} + {10'd0, tex_offset[i][21:3]};
                f0_lane[i] <= tex_offset[i][2:0];
            end
        end else if (f0_adv) f0_v <= 1'b0;
    end

    // ============================ open row (packer state) ============================
    reg  [28:0] row_wa [0:3];
    reg  [2:0]  row_cnt;                   // slots used (0 => no open row)
    reg  [2:0]  row_age;                   // cycles the non-empty row has been open
    wire        row_open = (row_cnt != 3'd0);

    // ============================ F1: dedup + pack (comb) ============================
    // Per corner: match an open-row slot, else an earlier corner, else allocate.
    reg  [1:0]  ref_app  [0:3];            // refs if APPENDING to the open row
    reg  [3:0]  new_app;                   // corners allocating a new slot (append case)
    reg  [2:0]  n_new;                     // unique new words (append case)
    reg  [1:0]  ref_fresh[0:3];            // refs if OPENING a fresh row
    reg  [3:0]  new_fresh;                 // corners allocating (fresh case)
    reg  [2:0]  n_fresh;
    always @(*) begin
        n_new = 3'd0; n_fresh = 3'd0;
        new_app = 4'd0; new_fresh = 4'd0;
        for (int c=0; c<4; c=c+1) begin ref_app[c] = 2'd0; ref_fresh[c] = 2'd0; end
        for (int c=0; c<4; c=c+1) begin
            // ---- append case: open-row slots first, then earlier corners ----
            logic hit; hit = 1'b0;
            for (int s=0; s<4; s=s+1)
                if (!hit && (s < {29'd0,row_cnt}) && row_wa[s] == f0_wa[c]) begin
                    ref_app[c] = 2'(s); hit = 1'b1;
                end
            for (int p=0; p<4; p=p+1)
                if (!hit && (p < c) && f0_wa[p] == f0_wa[c]) begin
                    ref_app[c] = ref_app[p]; hit = 1'b1;
                end
            if (!hit) begin
                ref_app[c] = 2'(row_cnt + n_new);
                new_app[c] = 1'b1;
                n_new      = n_new + 3'd1;
            end
            // ---- fresh case: earlier corners only ----
            hit = 1'b0;
            for (int p=0; p<4; p=p+1)
                if (!hit && (p < c) && f0_wa[p] == f0_wa[c]) begin
                    ref_fresh[c] = ref_fresh[p]; hit = 1'b1;
                end
            if (!hit) begin
                ref_fresh[c] = 2'(n_fresh);
                new_fresh[c] = 1'b1;
                n_fresh      = n_fresh + 3'd1;
            end
        end
    end
    // an AGED row is treated as not-fitting: without this, a continuous stream of
    // all-dedup pixels (tiny texture: every pixel free) never closes the row, so its
    // FIRST pixel starves at the expander until PIXQ fills - a 64-pixel batching
    // oscillation (seen as TEX_STALL on mvsc2). Aging bounds the first-pixel wait to
    // ROW_AGE cycles: the aged row closes and the pixel opens a fresh one.
    wire aged = (row_age >= 3'(ROW_AGE));
    wire fits = row_open && !aged && ({1'b0,row_cnt} + {1'b0,n_new} <= 4'd4);

    // queue interfaces (declared here, instantiated below)
    wire pixq_full, rowq_full;

    // F1 can process: pixel entry always pushes; a not-fitting tex pixel also
    // pushes the closed row. Conservatively require space in both queues.
    assign f1_ok = !pixq_full && !rowq_full;

    // the pixel's refs / first-of-row flag as pushed
    wire        px_fresh = f0_tex && (!row_open || !fits);
    wire [1:0]  px_ref [0:3];
    generate for (gi=0; gi<4; gi=gi+1) begin : pref
        assign px_ref[gi] = px_fresh ? ref_fresh[gi] : ref_app[gi];
    end endgenerate

    // row close events (one ROWQ push port; mutually exclusive by construction):
    //   * a processing tex pixel that doesn't fit closes the row (and opens fresh)
    //   * otherwise the row closes when F1 is idle/stalled or the row aged out
    wire f1_proc     = f0_adv;                          // F1 processes f0 this cycle
    wire close_pixel = f1_proc && f0_tex && row_open && !fits;
    wire close_idle  = row_open && !f1_proc && !rowq_full
                       && (!(f0_v && f0_tex && fits) || (row_age >= 3'(ROW_AGE)));
    wire rowq_push   = close_pixel || close_idle;

    // packer state update
    always @(posedge clk) begin
        if (clear) begin
            row_cnt <= 3'd0; row_age <= 3'd0;
            for (i=0;i<4;i=i+1) row_wa[i] <= '0;
        end else begin
            if (f1_proc && f0_tex) begin
                if (px_fresh) begin
                    for (i=0;i<4;i=i+1) if (new_fresh[i]) row_wa[ref_fresh[i]] <= f0_wa[i];
                    row_cnt <= n_fresh;
                    row_age <= 3'd0;
                end else begin
                    for (i=0;i<4;i=i+1) if (new_app[i]) row_wa[ref_app[i]] <= f0_wa[i];
                    row_cnt <= row_cnt + n_new;
                    row_age <= (row_age == 3'd7) ? row_age : row_age + 3'd1;
                end
            end else if (close_idle) begin
                row_cnt <= 3'd0;
                row_age <= 3'd0;
            end else if (row_open)
                row_age <= (row_age == 3'd7) ? row_age : row_age + 3'd1;
        end
    end

    // aged-out close while a fitting pixel processes: NOT allowed (the pixel's refs
    // point into the open row), so aging only closes on non-processing cycles.

    // ============================ ROWQ: closed rows -> lookup ============================
    localparam integer ROWQ_W = 4 + 4*29;
    wire [3:0]        rq_mask_in = 4'((5'd1 << row_cnt) - 5'd1);  // row_cnt in 1..4
    wire [ROWQ_W-1:0] rowq_wdata = { rq_mask_in, row_wa[3], row_wa[2], row_wa[1], row_wa[0] };
    wire              rowq_ov;
    wire [ROWQ_W-1:0] rowq_rdata;
    wire              rowq_pop;
    wire [$clog2(QDEPTH)+2:0] rowq_count;
    tfq_fifo #(.W(ROWQ_W), .DEPTH(QDEPTH)) u_rowq (
        .clk(clk), .reset(clear),
        .push(rowq_push), .wdata(rowq_wdata), .full(rowq_full),
        .ovalid(rowq_ov), .odata(rowq_rdata), .pop(rowq_pop), .count(rowq_count));

    wire [3:0]  lk_mask_in = rowq_rdata[ROWQ_W-1 -: 4];
    wire [28:0] lk_wa_in [0:3];
    generate for (gi=0; gi<4; gi=gi+1) begin : lkw
        assign lk_wa_in[gi] = rowq_rdata[29*gi +: 29];
        assign tcp_waddr[gi] = lk_wa_in[gi];
    end endgenerate
    // fill-lookahead probe: present the head row whenever it exists and is not being
    // accepted this cycle (the cache only samples it while frozen filling).
    assign tcp_valid = rowq_ov && !rowq_pop;
    assign tcp_mask  = lk_mask_in;

    // ============================ PIXQ: pixels + refs ============================
    localparam integer PIXQ_W = 3 + 8 + 12 + 21 + PLW;
    wire [PIXQ_W-1:0] pixq_wdata = { px_fresh, f0_tex, f0_vq,
                                     px_ref[3], px_ref[2], px_ref[1], px_ref[0],
                                     f0_lane[3], f0_lane[2], f0_lane[1], f0_lane[0],
                                     f0_vqbase, f0_pl };
    wire              pixq_ov;
    wire [PIXQ_W-1:0] pixq_rdata;
    wire              pixq_pop;
    wire [$clog2(PIXQ_D)+2:0] pixq_count;
    tfq_fifo #(.W(PIXQ_W), .DEPTH(PIXQ_D)) u_pixq (
        .clk(clk), .reset(clear),
        .push(f1_proc), .wdata(pixq_wdata), .full(pixq_full),
        .ovalid(pixq_ov), .odata(pixq_rdata), .pop(pixq_pop), .count(pixq_count));

    wire         px_first, px_tex, px_vq;
    wire [1:0]   pxr  [0:3];
    wire [2:0]   pxl  [0:3];
    wire [20:0]  px_vqbase;
    wire [PLW-1:0] px_pl;
    assign { px_first, px_tex, px_vq,
             pxr[3], pxr[2], pxr[1], pxr[0],
             pxl[3], pxl[2], pxl[1], pxl[0],
             px_vqbase, px_pl } = pixq_rdata;

    // ============================ LOOKUP: ROWQ -> cache -> DATQ ============================
    reg        lk_v;                       // a row group is in the cache REPLY stage
    reg [3:0]  lk_mask;
    wire       datq_full;
    wire [$clog2(QDEPTH)+2:0] datq_count;

    // credit gate: when this row's ack eventually fires it pushes one DATQ entry;
    // at most one group is in flight, so free >= 2 at issue guarantees the push.
    /* verilator lint_off WIDTH */
    wire lk_credit = (datq_count + (lk_v ? 1 : 0)) <= (QDEPTH - 2);
    /* verilator lint_on WIDTH */
    wire lk_issue  = rowq_ov && tc_ready && lk_credit;
    assign rowq_pop = lk_issue;

    generate for (gi=0; gi<4; gi=gi+1) begin : tcrq
        assign tc_req[gi].req   = lk_issue && lk_mask_in[gi];
        assign tc_req[gi].waddr = lk_wa_in[gi];
    end endgenerate

    always @(posedge clk) begin
        if (clear) begin lk_v <= 1'b0; lk_mask <= 4'd0; end
        else begin
            if (lk_issue)    begin lk_v <= 1'b1; lk_mask <= lk_mask_in; end
            else if (tc_ack) lk_v <= 1'b0;
        end
    end

    // DATQ push: the group ack (group-atomic; slot 0 always valid).
    wire [255:0] datq_wdata = { tc_resp[3].rdata, tc_resp[2].rdata,
                                tc_resp[1].rdata, tc_resp[0].rdata };
    wire         datq_ov;
    wire [255:0] datq_rdata;
    wire         datq_pop;
    tfq_fifo #(.W(256), .DEPTH(QDEPTH)) u_datq (
        .clk(clk), .reset(clear),
        .push(lk_v && tc_ack), .wdata(datq_wdata), .full(datq_full),
        .ovalid(datq_ov), .odata(datq_rdata), .pop(datq_pop), .count(datq_count));

    // ============================ EX: pixel + row -> corner words ============================
    reg  [255:0] row_q;                    // the held (current) row data
    reg          row_q_v;

    wire t1_free;
    wire ex_row_ok = !px_tex || (px_first ? datq_ov : row_q_v);
    wire ex_here   = pixq_ov && ex_row_ok;
    wire ex_adv    = ex_here && t1_free;
    assign pixq_pop = ex_adv;
    assign datq_pop = ex_adv && px_tex && px_first;

    wire [255:0] ex_rsrc = px_first ? datq_rdata : row_q;
    wire [63:0]  ex_word [0:3];
    generate for (gi=0; gi<4; gi=gi+1) begin : exw
        assign ex_word[gi] = ex_rsrc[64*pxr[gi] +: 64];
    end endgenerate

    always @(posedge clk) begin
        if (clear) begin row_q <= '0; row_q_v <= 1'b0; end
        else if (ex_adv && px_tex && px_first) begin
            row_q <= datq_rdata; row_q_v <= 1'b1;
        end
    end

    // ============================ V1/V2: the tex_fetch4_ob T1/T2 stages ============================
    reg           t1_v, t1_tex, t1_vq;
    reg  [20:0]   t1_vqbase;
    reg  [2:0]    t1_lane [0:3];
    reg  [63:0]   t1_mem  [0:3];
    reg  [PLW-1:0] t1_pl;
    reg           t2_v, t2_dv, t2_vq;
    reg  [63:0]   t2_word [0:3];
    reg  [PLW-1:0] t2_pl;

    // VQ codebook address per corner (from the held V1 data word + lane)
    wire [7:0]  t1_idx    [0:3];
    wire [28:0] t1_vqaddr [0:3];
    generate for (gi=0; gi<4; gi=gi+1) begin : vqa
        assign t1_idx[gi]    = t1_mem[gi][ {t1_lane[gi], 3'd0} +: 8 ];
        assign t1_vqaddr[gi] = {8'd0, t1_vqbase} + {21'd0, t1_idx[gi]};
    end endgenerate

    // V2 -> out : result "here" (non-VQ done on entry; VQ when the codebook word lands)
    wire t2_here = t2_dv || (t2_v && t2_vq && vq_ack);
    wire t2_adv  = t2_v && t2_here;        // out_ready tied high -> always drains
    wire t2_free = !t2_v || t2_adv;

    // V1 -> V2 : VQ pixel needs its VQ read accepted; non-VQ advances immediately
    wire vq_need = t1_v && t1_tex && t1_vq;
    wire t1_okvq = !vq_need || vq_ready;
    wire t1_adv  = t1_v && t1_okvq && t2_free;
    assign t1_free = !t1_v || t1_adv;

    generate for (gi=0; gi<4; gi=gi+1) begin : vqrq
        assign vq_req[gi].req   = vq_need && t2_free && vq_ready;
        assign vq_req[gi].waddr = t1_vqaddr[gi];
    end endgenerate

    // output: same drain-pulse contract + VQ same-cycle bypass as tex_fetch4_ob
    generate for (gi=0; gi<4; gi=gi+1) begin : outw
        assign texel[gi] = (t2_v && t2_vq && !t2_dv) ? vq_resp[gi].rdata : t2_word[gi];
    end endgenerate
    assign out_pl    = t2_pl;
    assign out_valid = t2_adv;

    always @(posedge clk) begin
        if (clear) begin
            t1_v <= 1'b0; t2_v <= 1'b0; t2_dv <= 1'b0;
            t1_tex <= 1'b0; t1_vq <= 1'b0; t2_vq <= 1'b0;
            t1_vqbase <= '0; t1_pl <= '0; t2_pl <= '0;
            for (i=0;i<4;i=i+1) begin
                t1_mem[i] <= 64'd0; t2_word[i] <= 64'd0; t1_lane[i] <= 3'd0;
            end
        end else begin
            // ---- EX -> V1 ----
            if (ex_adv) begin
                t1_v <= 1'b1; t1_tex <= px_tex; t1_vq <= px_vq; t1_vqbase <= px_vqbase;
                for (i=0;i<4;i=i+1) begin t1_mem[i] <= ex_word[i]; t1_lane[i] <= pxl[i]; end
                t1_pl <= px_pl;
            end else if (t1_adv) t1_v <= 1'b0;

            // ---- V1 -> V2 ----
            if (t1_adv) begin
                t2_v  <= 1'b1; t2_vq <= (t1_tex && t1_vq);
                t2_dv <= !(t1_tex && t1_vq);
                for (i=0;i<4;i=i+1) t2_word[i] <= t1_mem[i];
                t2_pl <= t1_pl;
            end else if (t2_adv) t2_v <= 1'b0;

            // ---- V2 VQ capture (see tex_fetch4_ob: never fires with out_ready tied
            //      high - the bypass forwards vq_resp.rdata on the drain cycle) ----
            if (t2_v && t2_vq && !t2_dv && vq_ack && !t2_adv) begin
                for (i=0;i<4;i=i+1) t2_word[i] <= vq_resp[i].rdata;
                t2_dv <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    // ---- invariants ----
    always @(posedge clk) if (!clear) begin
        // a non-first tex pixel must find its row already held
        if (ex_adv && px_tex && !px_first && !row_q_v)
            $error("tex_fetch4_q %m: non-first pixel with no held row");
        // group ack must arrive only while a group is in flight
        if (tc_ack && !lk_v)
            $error("tex_fetch4_q %m: data-cache ack with no group in flight");
    end
    always @(posedge clk) if (flush && !reset) begin
        if (f0_v || row_open || rowq_ov || pixq_ov || datq_ov || lk_v || t1_v || t2_v)
            $error("tex_fetch4_q %m: flush with pixels/rows in flight");
    end
    // ---- +texqtrace: per-cycle queue occupancy trace ----
    // pixq/rowq/datq = total entries in each FIFO (RAM + in-flight + output buffer);
    // open = slots in the packer's open row; lk = a row group in the cache REPLY
    // stage; rdy/tcrdy = in_ready / data-cache ready; t1/t2 = V-stage occupancy.
    reg     tq_trace;
    integer tq_cyc;
    initial tq_trace = $test$plusargs("texqtrace");
    always @(posedge clk) begin
        if (reset) tq_cyc <= 0;
        else begin
            tq_cyc <= tq_cyc + 1;
            if (tq_trace)
                $display("[TEXQ] c=%0d pixq=%0d rowq=%0d datq=%0d open=%0d lk=%b rdy=%b tcrdy=%b t1=%b t2=%b",
                         tq_cyc, pixq_count, rowq_count, datq_count,
                         row_cnt, lk_v, in_ready, tc_ready, t1_v, t2_v);
        end
    end

    // ---- stats ----
    integer st_px, st_tpx, st_rows, st_slots, st_free_px;
    integer st_rowsz [1:4];
    always @(posedge clk) begin
        if (reset) begin
            st_px<=0; st_tpx<=0; st_rows<=0; st_slots<=0; st_free_px<=0;
            for (i=1;i<5;i=i+1) st_rowsz[i]<=0;
        end else begin
            if (f1_proc) begin
                st_px <= st_px + 1;
                if (f0_tex) begin
                    st_tpx <= st_tpx + 1;
                    if (!px_fresh && n_new == 0) st_free_px <= st_free_px + 1;
                end
            end
            if (rowq_push) begin
                st_rows  <= st_rows + 1;
                st_slots <= st_slots + {29'd0, row_cnt};
                st_rowsz[row_cnt] <= st_rowsz[row_cnt] + 1;
            end
        end
    end
    final $display("=== TEXQ %m: px=%0d (tex=%0d, free=%0d) rows=%0d slots=%0d rowsz[1..4]=%0d/%0d/%0d/%0d ===",
                   st_px, st_tpx, st_free_px, st_rows, st_slots,
                   st_rowsz[1], st_rowsz[2], st_rowsz[3], st_rowsz[4]);
`endif
endmodule

//
// tex_fetch4_ob - 4-corner raw texel fetch (rewrite; output-buffered). 4 byte-offsets in -> 4 raw 64-bit
// memory words out. Owns the two shared 4-read-port caches (data + VQ) as its ONLY
// submodules; the whole fetch pipeline is inline (no tex_fetch_core, no tex_decode).
//
// Addressing. tex_addr / vq_addr are 64-BIT-WORD base addresses (21b, DC VRAM). The 4
// corner offsets are in BYTES (20b). So per corner:
//   data word addr = tex_addr + offset[21:3]      (offset byte, its 64-bit-word part)
//   byte lane      = offset[2:0]                   (byte-within-word; also the VQ lane)
//
// Behaviour per corner:
//   !TEX          : issue NO request; output undefined (this fetcher is unused).
//   TEX & !VQ     : one data-cache read -> output = that raw 64-bit word. VQ idle.
//   TEX &  VQ     : data-cache read -> memtel ; index = memtel[8*offset[2:0] +: 8] ;
//                   VQ-cache read at (vq_addr + index) -> output = that 64-bit word.
//
// STREAMING: accepts a new request every cycle; the 4 corners run LOCKSTEP over the
// PIPELINED 2-cycle caches (see tex_cache_4p_1c: LOOK -> TEST -> REPLY, two groups in
// flight, acks in order). The pipe is sized to COVER that latency at full rate - each
// cache trip spans two stages, so two pixels can be in flight per cache:
//   T0a : data-cache read accepted (LOOK)      T0b : reply lands here (unstalled case)
//   T1  : data word held; if VQ, present the VQ read (codebook addr from the word)
//   T2a : VQ read accepted (LOOK)              T2b : VQ reply lands -> texel out
// Acks are pulses matched to pixels by ORDER; a stalled pixel captures its word in
// whichever stage it occupies (T0a and T0b both have capture registers - a tc ack can
// land in either; a vq ack always lands in T2b because T2b drains unconditionally).
//
// Exposes THREE DDR read ports to the parent arbiter ([0]=tc, [1]=vq, [2]=tc PREFETCH).
//
module tex_fetch4_ob import tsp_pkg::*; #(
    parameter integer PLW = 1              // decode payload bus width (rides with the pixel)
) (
    input             clk,
    input             reset,
    input             flush,             // render-start: invalidate both tex caches (no
                                         // cross-render texture coherency; see tex_cache_4p_1c)
    input             in_valid,
    input             tex,               // TEX: textured pixel
    input             vq,               // VQ:  VQ-compressed texture
    input      [20:0] tex_addr,          // data base (64-bit-word units)
    input      [20:0] vq_addr,           // VQ codebook base (64-bit-word units)
    input      [21:0] tex_offset [0:3],  // per-corner byte offsets (22b: up to 16bpp+mip)
    input      [PLW-1:0] in_pl,           // decode payload latched WITH the accepted pixel
    output            in_ready,          // 0 = stall (request FIFO full); hold inputs

    output            out_valid,
    output     [63:0] texel [0:3],       // raw 64-bit memory words (undefined if !tex)
    output     [PLW-1:0] out_pl,          // in_pl carried to align with out_valid/texel

    // three DDR read ports to the parent arbiter
    output ddr_rd_req_t  ddr_req  [0:2],   // [0]=tc, [1]=vq, [2]=tc PREFETCH
    input  ddr_rd_resp_t ddr_resp [0:2]
);
    // shared 4-read-port caches (data + VQ)
    cache_req_t   tc_req [0:3], vq_req [0:3];
    cache_resp_t  tc_resp[0:3], vq_resp[0:3];
    // pf_* is the data cache's prefill probe port (tag-only residency test), driven by
    // the streaming prefetch walker below. The VQ cache's probe is tied off (codebook
    // lines are not prefetched - their addresses depend on fetched data).
    wire tc_pf_gnt, tc_pf_ack, tc_pf_busy, vq_pf_ack, vq_pf_busy, tc_pf_fbusy;
    wire [3:0] tc_pf_hit, vq_pf_hit;
    // ---- PREFETCH WALKER (declared here, driven after the FIFO below) ----
    wire            la_probe;
    wire [4*29-1:0] la_waddr;
    wire            la_fill;
    wire [28:0]     la_faddr;
    tex_cache_4p_1c u_tc4 (.clk(clk),.reset(reset),.flush(flush),
        .creq(tc_req),.cresp(tc_resp),
        .pf_req(la_probe),.pf_waddr(la_waddr),.pf_gnt(tc_pf_gnt),
        .pf_ack(tc_pf_ack),.pf_hit(tc_pf_hit),.pf_busy(tc_pf_busy),
        .pf_fill(la_fill),.pf_faddr(la_faddr),.pf_fbusy(tc_pf_fbusy),
        .pfreq(ddr_req[2]),.pfresp(ddr_resp[2]),
        .dreq(ddr_req[0]),.dresp(ddr_resp[0]));
    tex_cache_4p_1c u_vq4 (.clk(clk),.reset(reset),.flush(flush),
        .creq(vq_req),.cresp(vq_resp),
        .pf_req(1'b0),.pf_waddr({(4*29){1'b0}}),.pf_gnt(),
        .pf_ack(vq_pf_ack),.pf_hit(vq_pf_hit),.pf_busy(vq_pf_busy),
        .pf_fill(1'b0),.pf_faddr(29'd0),.pf_fbusy(),
        .pfreq(),.pfresp('0),
        .dreq(ddr_req[1]),.dresp(ddr_resp[1]));

    // per-corner data-cache word address + VQ byte lane (combinational off inputs)
    wire [28:0] tc_waddr [0:3];
    wire [2:0]  vqlane   [0:3];
    genvar gi;
    generate for (gi=0; gi<4; gi=gi+1) begin : addr
        assign tc_waddr[gi] = {8'd0, tex_addr} + {10'd0, tex_offset[gi][21:3]};
        assign vqlane[gi]   = tex_offset[gi][2:0];
    end endgenerate

    // ============================================================================
    // PRE-CACHE REQUEST FIFO (32 deep, M10K, FWFT)
    // ============================================================================
    // Without this the front is welded to the cache: in_ready gated directly on
    // tc_ready, so a miss-fill froze the whole shade pipe. The FIFO decouples them -
    // the front keeps retiring pixels into it while the cache fills, and it is also
    // the QUEUE THE PREFETCH WALKER SCANS for the next miss (the lookahead pointer).
    //
    // It carries the WHOLE request bundle, not just the 4 addresses: tex/vq, the VQ
    // base, the per-corner VQ byte lanes and the decode payload all have to stay
    // aligned with their addresses once issue is decoupled from completion. At
    // 151+PLW bits x 32 that is still one M10K.
    //
    // TWO copies of the body share one write: copy A refills the FWFT head, copy B
    // is the walker's independent lookahead read port (a single simple-dual-port
    // RAM cannot serve both, and stealing refill cycles would throttle the head).
    localparam integer FQ_D  = 32, FQ_AW = 5;
    localparam integer FQ_W  = 1 + 1 + 21 + 4*3 + 4*29 + PLW;
    wire [FQ_W-1:0] fq_in = { tex, vq, vq_addr,
                              vqlane[0],  vqlane[1],  vqlane[2],  vqlane[3],
                              tc_waddr[0],tc_waddr[1],tc_waddr[2],tc_waddr[3],
                              in_pl };
    wire [FQ_W-1:0] fq_qa, fq_hd_w;
    reg  [FQ_W-1:0] fq_hd;   reg fq_hd_v;
    reg  [FQ_AW:0]  fq_wp, fq_rp;   reg [FQ_AW:0] fq_cnt;
    wire fq_full  = (fq_cnt == FQ_D[FQ_AW:0]);
    wire fq_push  = in_valid && !fq_full;
    wire fq_pop;                       // = the T0a accept, declared below
    wire fq_head_free = !fq_hd_v || fq_pop;
    wire fq_ram_has   = (fq_wp != fq_rp);
    wire [FQ_AW:0] fq_rp_nxt = (fq_head_free && fq_ram_has) ? fq_rp + 1'b1 : fq_rp;
    reg  [FQ_W-1:0] fq_pw_d; reg [FQ_AW:0] fq_pw_a; reg fq_pw_v;
    wire [FQ_W-1:0] fq_src = (fq_pw_v && (fq_pw_a == fq_rp)) ? fq_pw_d : fq_qa;
    bram_sdp #(.W(FQ_W), .D(FQ_D)) u_fq_a (            // head-refill copy
        .clk(clk), .we(fq_push), .waddr(fq_wp[FQ_AW-1:0]), .din(fq_in),
        .re(1'b1), .raddr(fq_rp_nxt[FQ_AW-1:0]), .q(fq_qa));
    // walker lookahead copy: same write, independent read
    wire [FQ_AW-1:0] fq_la_addr;   // driven by the prefetch walker below
    wire [FQ_W-1:0]  fq_la_q;
    bram_sdp #(.W(FQ_W), .D(FQ_D)) u_fq_b (
        .clk(clk), .we(fq_push), .waddr(fq_wp[FQ_AW-1:0]), .din(fq_in),
        .re(1'b1), .raddr(fq_la_addr), .q(fq_la_q));
    // FWFT head field unpack (these replace the raw module inputs downstream)
    assign fq_hd_w  = fq_hd;
    wire        f_tex    = fq_hd_w[FQ_W-1];
    wire        f_vq     = fq_hd_w[FQ_W-2];
    wire [20:0] f_vqbase = fq_hd_w[FQ_W-3 -: 21];
    wire [2:0]  f_lane  [0:3];
    wire [28:0] f_waddr [0:3];
    wire [PLW-1:0] f_pl = fq_hd_w[PLW-1:0];
    genvar gf;
    generate for (gf=0; gf<4; gf=gf+1) begin : fqu
        assign f_lane [gf] = fq_hd_w[PLW + 4*29 + (3-gf)*3 +: 3];
        assign f_waddr[gf] = fq_hd_w[PLW + (3-gf)*29 +: 29];
    end endgenerate
    always @(posedge clk) begin
        if (reset) begin
            fq_wp<=0; fq_rp<=0; fq_cnt<=0; fq_hd_v<=1'b0; fq_pw_v<=1'b0;
        end else begin
            fq_pw_v <= fq_push; fq_pw_a <= fq_wp; fq_pw_d <= fq_in;
            if (fq_push) fq_wp <= fq_wp + 1'b1;
            if (fq_head_free) begin
                if (fq_ram_has)   begin fq_hd <= fq_src; fq_hd_v <= 1'b1; fq_rp <= fq_rp + 1'b1; end
                else if (fq_push) begin fq_hd <= fq_in;  fq_hd_v <= 1'b1; fq_rp <= fq_rp + 1'b1; end
                else              fq_hd_v <= 1'b0;
            end
            fq_cnt <= fq_cnt + (fq_push?1:0) - (fq_pop?1:0);
        end
    end

    // ============================================================================
    // PREFETCH WALKER (#6 + #17) - STREAMING, one queue entry per cycle
    // ============================================================================
    // While the texel cache is FROZEN filling (tc_pf_busy) its four demand read
    // ports are idle, so we walk the queued requests ahead of the head and probe
    // them 4 tags/cycle. The first line that misses is issued on the cache's own
    // prefetch DDR client, so it fills BEHIND the demand line instead of waiting
    // for it. The pointer PERSISTS across fill episodes (#17's continuous re-arm):
    // successive probes resume ever deeper rather than re-examining the head.
    //
    // The probe reply is now PIPELINED (2 cycles after pf_gnt, registered compare in
    // the cache - see tex_cache_4p_1c), so the walker streams: it presents an entry
    // per cycle, tracks granted probes in a 2-deep address pipe, and matches acks to
    // grants by order. Non-textured entries are consumed without a probe. When a
    // probed entry misses, the first missing corner's line goes into a 2-deep FILL
    // SKID; pf_fill is held as a LEVEL until the receiver is free (which either
    // takes the line or drops a duplicate). Probing STALLS while any fill is
    // pending/in flight (a prefetch takes a whole DDR burst anyway), so the skid
    // never overflows: at most the 2 in-flight probes can still complete into it.
    //
    // A probe raced by a concurrent commit can yield a duplicate prefetch of a
    // just-filled line; the receiver's pf_dup drop and the harmless identical
    // rewrite bound the damage to one wasted burst.
    reg  [FQ_AW:0] la_p;                       // next entry to EXAMINE (>= fq_rp)
    reg  [FQ_AW:0] la_pres_r;                  // address whose data is in fq_la_q
    reg            la_q_v_r;                   // ...and it was a real entry
    wire           la_behind = (la_p - fq_rp) > (fq_wp - fq_rp);   // consumed past us
    wire [FQ_AW:0] la_pcl    = la_behind ? fq_rp : la_p;           // clamp to the head
    wire           la_q_ok   = la_q_v_r && (la_pres_r == la_pcl);  // entry data valid
    // the looked-at entry's four addresses + its textured flag
    wire           la_tex   = fq_la_q[FQ_W-1];
    generate for (gf=0; gf<4; gf=gf+1) begin : law
        assign la_waddr[29*gf +: 29] = fq_la_q[PLW + (3-gf)*29 +: 29];
    end endgenerate

    // ---- fill skid (4 deep; pf_fill level until the receiver consumes) ----
    reg [28:0] flq [0:3];
    reg [2:0]  flq_n;
    assign la_fill  = (flq_n != 3'd0);
    assign la_faddr = flq[0];
    wire   flq_pop  = la_fill && !tc_pf_fbusy;   // receiver takes or dup-drops it now

    // ---- probe reply -> fill CANDIDATE, in TWO register stages ----
    // pf_hit_r feeds ONLY the first stage, and only 3 bits of it: cm_v (any miss)
    // and cm_sel (which corner). Keeping the hit bits out of the grant/pointer cone
    // matters (routed into wk_stall they re-created a register->every-RAM-address-
    // port cone, ~-5.8ns), and keeping them out of the WIDE mux matters too: the
    // 29-bit corner select done combinationally off pf_hit_r was the last failing
    // family (~-1.3ns of routing from the cache's hit registers into 29 mux
    // selects). Now the wide mux runs a cycle later with a REGISTERED 2-bit select.
    wire [3:0] la_miss  = ~tc_pf_hit;
    wire [1:0] la_sel   = la_miss[0] ? 2'd0 : la_miss[1] ? 2'd1
                        : la_miss[2] ? 2'd2 : 2'd3;
    reg  [4*29-1:0] wp1_addr, wp2_addr, wp3_addr;  // granted-probe address pipe
    reg             wp1_v, wp2_v;
    reg             cm_v;                      // stage 1: a corner missed...
    reg  [1:0]      cm_sel;                    // ...and which one (registered select)
    reg             cand_v;                    // stage 2: candidate address resolved
    reg  [28:0]     cand_a;
    // dedup + push a cycle later, all off registers: drop a candidate whose LINE is
    // already queued (two nearby entries missing the same line would otherwise burn
    // two bursts on it)
    wire   flq_dup  = (flq_n >= 3'd1 && flq[0][28:2] == cand_a[28:2])
                   || (flq_n >= 3'd2 && flq[1][28:2] == cand_a[28:2])
                   || (flq_n >= 3'd3 && flq[2][28:2] == cand_a[28:2])
                   || (flq_n >= 3'd4 && flq[3][28:2] == cand_a[28:2]);
    wire   flq_take = cand_v && !flq_dup && (flq_n != 3'd4 || flq_pop);
    // stall = REGISTERED operands only (skid occupancy, candidate in flight at
    // either stage, receiver busy). It reacts one cycle later than a comb version
    // would, so up to 3 pushes can still arrive after it asserts (2 in-flight
    // probes + 1 candidate) - that is exactly why the skid is 4 deep. cm_v asserts
    // it at the same edge cand_v alone used to, so the lag analysis is unchanged.
    wire   wk_stall = (flq_n != 3'd0) || cm_v || cand_v || tc_pf_fbusy;

    assign la_probe = la_q_ok && la_tex && tc_pf_busy && !wk_stall;
    wire   la_gnt   = tc_pf_gnt;               // only ever high when la_probe is
    wire   la_cons  = la_q_ok && (!la_tex || la_gnt);
    wire [FQ_AW:0] la_nxt = la_cons ? (la_pcl + 1'b1) : la_pcl;
    assign fq_la_addr = la_nxt[FQ_AW-1:0];     // present next examine target

    integer fj;
    always @(posedge clk) begin
        if (reset) begin
            la_p <= '0; la_q_v_r <= 1'b0; wp1_v <= 1'b0; wp2_v <= 1'b0;
            cand_v <= 1'b0; flq_n <= 3'd0;
        end else begin
            la_p      <= la_nxt;
            la_pres_r <= la_nxt;
            la_q_v_r  <= (la_nxt != fq_wp);    // a real entry is being presented
            // granted-probe address pipe (matches the cache's 2-cycle probe reply)
            wp1_v <= la_gnt;  wp1_addr <= la_waddr;
            wp2_v <= wp1_v;   wp2_addr <= wp1_addr;
            wp3_addr <= wp2_addr;
            // fill candidate stage 1: WHETHER a corner missed + WHICH (3 bits off
            // pf_hit_r, nothing wider)
            cm_v   <= tc_pf_ack && (la_miss != 4'd0);
            cm_sel <= la_sel;
            // fill candidate stage 2: the wide corner mux, registered select
            cand_v <= cm_v;
            cand_a <= wp3_addr[29*cm_sel +: 29];
            // fill skid: shift down on pop, append the taken candidate (the append
            // is written after the shift so it wins on the overlapping index)
            if (flq_pop)
                for (fj=0; fj<3; fj=fj+1) flq[fj] <= flq[fj+1];
            if (flq_take)
                flq[flq_pop ? (flq_n[1:0] - 2'd1) : flq_n[1:0]] <= cand_a;
            flq_n <= flq_n + (flq_take ? 3'd1 : 3'd0) - (flq_pop ? 3'd1 : 3'd0);
`ifndef SYNTHESIS
            if (tc_pf_ack != wp2_v)
                $error("tex_fetch4_ob %m: walker probe pipe desynced from pf_ack");
            if (flq_take && !flq_pop && flq_n == 3'd4)
                $error("tex_fetch4_ob %m: fill skid overflow");
`endif
        end
    end

    // ============================================================================
    // Streaming pipeline, 4 corners lockstep. All corners share the accept/advance
    // decisions (they freeze together), so control is computed ONCE (corner 0's cache
    // readiness == all, since the 4-read-port cache gates all ports together).
    // Each cache trip spans TWO stages (T0a/T0b for tc, T2a/T2b for vq) to cover the
    // pipelined caches' 2-cycle reply at one pixel per cycle.
    // ============================================================================
    // ---- T0a: data-cache read accepted this pixel's cycle (cache LOOK) ----
    reg        t0a_v;
    reg        t0a_tex, t0a_vq;
    reg [20:0] t0a_vqbase;
    reg [2:0]  t0a_lane [0:3];
    reg [63:0] t0a_mem  [0:3];  // captured data word (only if the ack lands here)
    reg        t0a_dv;
    // ---- T0b: reply stage (ack lands here in the unstalled case) ----
    reg        t0b_v;
    reg        t0b_tex, t0b_vq;
    reg [20:0] t0b_vqbase;
    reg [2:0]  t0b_lane [0:3];
    reg [63:0] t0b_mem  [0:3];
    reg        t0b_dv;

    // ---- T1: data word held; if VQ, present the VQ read ----
    reg        t1_v;
    reg        t1_tex, t1_vq;
    reg [20:0] t1_vqbase;
    reg [2:0]  t1_lane [0:3];
    reg [63:0] t1_mem  [0:3];   // data word (per corner)

    // ---- T2a: VQ read accepted (cache LOOK); non-VQ just carries through ----
    reg        t2a_v, t2a_vq, t2a_dv;
    reg [63:0] t2a_word [0:3];
    // ---- T2b: VQ reply lands -> texel out ----
    reg        t2b_v, t2b_vq, t2b_dv;
    reg [63:0] t2b_word [0:3];

    // ---- decode PAYLOAD skew registers: ride every stage with the SAME advances as
    //      the corners, so the payload can NEVER desync from the texels regardless of
    //      the fetch's variable latency (VQ 2nd trip, miss-fills). ----
    reg [PLW-1:0] t0a_pl, t0b_pl, t1_pl, t2a_pl, t2b_pl;

    integer i;

    // VQ codebook address per corner (from the HELD T1 data word + lane)
    wire [7:0]  t1_idx  [0:3];
    wire [28:0] t1_vqaddr [0:3];
    generate for (gi=0; gi<4; gi=gi+1) begin : vqa
        assign t1_idx[gi]    = t1_mem[gi][ {t1_lane[gi], 3'd0} +: 8 ];   // byte lane*8
        assign t1_vqaddr[gi] = {8'd0, t1_vqbase} + {21'd0, t1_idx[gi]};
    end endgenerate

    // ---- per-stage advance (lockstep; gate on shared cache readiness) ----
    // data cache ready == tc_resp[0].ready (all 4 ports gate together); same for vq.
    wire tc_ready = tc_resp[0].ready;
    wire vq_ready = vq_resp[0].ready;
    wire tc_ack   = tc_resp[0].ack;
    wire vq_ack   = vq_resp[0].ack;

    // tc ack attribution BY ORDER: the oldest textured pixel still owed a word. It is
    // in T0b unless T0b's word already landed (or T0b holds a younger/untextured
    // pixel), in which case the ack belongs to the pixel still in T0a.
    wire tc_ack_t0b = tc_ack && t0b_v && t0b_tex && !t0b_dv;
    wire tc_ack_t0a = tc_ack && !tc_ack_t0b && t0a_v && t0a_tex && !t0a_dv;

    // T2b -> out : resolved on entry (non-VQ / captured), or the VQ ack lands now.
    wire t2b_here = t2b_dv || (t2b_v && t2b_vq && vq_ack);
    wire t2b_adv  = t2b_v && t2b_here;         // out_ready tied high -> always drains
    wire t2b_free = !t2b_v || t2b_adv;
    // T2a -> T2b : nothing to wait for (its VQ reply arrives in T2b at the earliest).
    wire t2a_adv  = t2a_v && t2b_free;
    wire t2a_free = !t2a_v || t2a_adv;

    // T1 -> T2a : VQ pixel needs its VQ read accepted; non-VQ advances immediately.
    wire vq_need = t1_v && t1_tex && t1_vq;
    wire t1_okvq = !vq_need || vq_ready;
    wire t1_adv  = t1_v && t1_okvq && t2a_free;
    wire t1_free = !t1_v || t1_adv;

    // T0b -> T1 : data word here (bypass for !tex; captured; or landing this cycle).
    wire t0b_bypass = t0b_v && !t0b_tex;
    wire t0b_here   = t0b_bypass || t0b_dv || tc_ack_t0b;
    wire t0b_adv    = t0b_v && t0b_here && t1_free;
    wire t0b_free   = !t0b_v || t0b_adv;
    // T0a -> T0b : nothing to wait for (its reply arrives in T0b at the earliest).
    wire t0a_adv    = t0a_v && t0b_free;
    wire t0a_free   = !t0a_v || t0a_adv;

    // ---- accept a new pixel: T0a free and (textured -> data cache ready) ----
    // the FRONT only needs FIFO room; the cache gates the FIFO's HEAD instead.
    assign in_ready = !fq_full;
    wire   accept   = fq_hd_v && t0a_free && (!f_tex || tc_ready);
    assign fq_pop   = accept;

    // ---- issue data-cache read (only textured pixels) ----
    generate for (gi=0; gi<4; gi=gi+1) begin : tcreq
        assign tc_req[gi].req   = accept && f_tex;
        assign tc_req[gi].waddr = f_waddr[gi];
    end endgenerate

    // ---- issue VQ read (T1 VQ pixel, when it can advance into a free T2a) ----
    generate for (gi=0; gi<4; gi=gi+1) begin : vqreq
        assign vq_req[gi].req   = vq_need && t2a_free && vq_ready;
        assign vq_req[gi].waddr = t1_vqaddr[gi];
    end endgenerate

    // ---- output ----
    // t2b_word holds the RESOLVED word ONLY once t2b_dv is set (non-VQ on entry; VQ
    // after its codebook read is captured). But a VQ pixel drains from T2b the SAME
    // cycle its codebook word lands (t2b_adv && vq_ack, still !t2b_dv) - the
    // register-capture below is guarded by !t2b_adv and never runs on that cycle, so
    // the register still holds the INDEX word. Combinationally bypass to
    // vq_resp.rdata for that drain cycle (the cache's rdata is itself registered, so
    // this is register -> mux -> pin). Without this the codebook lookup is skipped
    // and VQ textures fetch the raw index word.
    generate for (gi=0; gi<4; gi=gi+1) begin : out
        assign texel[gi] = (t2b_v && t2b_vq && !t2b_dv) ? vq_resp[gi].rdata : t2b_word[gi];
    end endgenerate
    assign out_pl = t2b_pl;    // payload rode every stage in lockstep with the texels
    // out_valid is the DRAIN PULSE (t2b_adv), NOT the T2b-occupied level. A VQ pixel
    // whose codebook read MISSES the cache lingers in T2b for the fill (t2b_v stays
    // high, but t2b_adv waits for vq_ack). The downstream decode has no stall - it
    // fires on every out_valid cycle - so a stretched level would re-decode the same
    // (frozen) payload each fill cycle and desync the pipe. t2b_adv pulses exactly
    // once, on the cycle texel resolves.
    assign out_valid = t2b_adv;

    // ---- data words to carry on a T0b -> T1 advance (held or just-landed) ----
    wire [63:0] t0b_word [0:3];
    generate for (gi=0; gi<4; gi=gi+1) begin : t0w
        assign t0b_word[gi] = t0b_dv ? t0b_mem[gi] : tc_resp[gi].rdata;
    end endgenerate

    always @(posedge clk) begin
        if (reset) begin
            t0a_v<=0; t0a_dv<=0; t0b_v<=0; t0b_dv<=0; t1_v<=0;
            t2a_v<=0; t2a_dv<=0; t2b_v<=0; t2b_dv<=0;
            t0a_tex<=0; t0a_vq<=0; t0b_tex<=0; t0b_vq<=0;
            t1_tex<=0; t1_vq<=0; t2a_vq<=0; t2b_vq<=0;
            for (i=0;i<4;i=i+1) begin
                t0a_mem[i]<=64'd0; t0b_mem[i]<=64'd0; t1_mem[i]<=64'd0;
                t2a_word[i]<=64'd0; t2b_word[i]<=64'd0;
                t0a_lane[i]<=3'd0; t0b_lane[i]<=3'd0; t1_lane[i]<=3'd0;
            end
        end else begin
            // ---- in -> T0a ----
            if (accept) begin
                t0a_v <= 1'b1; t0a_dv <= 1'b0;
                t0a_tex <= f_tex; t0a_vq <= f_vq; t0a_vqbase <= f_vqbase;
                for (i=0;i<4;i=i+1) t0a_lane[i] <= f_lane[i];
                t0a_pl <= f_pl;                          // payload rides the FIFO entry
            end else if (t0a_adv) t0a_v <= 1'b0;

            // ---- T0a capture: the ack can land here when T0b is stalled full ----
            if (tc_ack_t0a && !t0a_adv) begin
                for (i=0;i<4;i=i+1) t0a_mem[i] <= tc_resp[i].rdata;
                t0a_dv <= 1'b1;
            end

            // ---- T0a -> T0b (fold in an ack arriving on the advance cycle) ----
            if (t0a_adv) begin
                t0b_v <= 1'b1;
                t0b_tex <= t0a_tex; t0b_vq <= t0a_vq; t0b_vqbase <= t0a_vqbase;
                for (i=0;i<4;i=i+1) begin
                    t0b_lane[i] <= t0a_lane[i];
                    t0b_mem[i]  <= t0a_dv ? t0a_mem[i] : tc_resp[i].rdata;
                end
                t0b_dv <= t0a_dv || tc_ack_t0a;
                t0b_pl <= t0a_pl;
            end else if (t0b_adv) t0b_v <= 1'b0;

            // ---- T0b capture (word lands while waiting on T1) ----
            if (tc_ack_t0b && !t0b_adv) begin
                for (i=0;i<4;i=i+1) t0b_mem[i] <= tc_resp[i].rdata;
                t0b_dv <= 1'b1;
            end

            // ---- T0b -> T1 ----
            if (t0b_adv) begin
                t1_v <= 1'b1; t1_tex <= t0b_tex; t1_vq <= t0b_vq; t1_vqbase <= t0b_vqbase;
                for (i=0;i<4;i=i+1) begin t1_mem[i] <= t0b_word[i]; t1_lane[i] <= t0b_lane[i]; end
                t1_pl <= t0b_pl;
            end else if (t1_adv) t1_v <= 1'b0;

            // ---- T1 -> T2a : non-VQ resolved immediately (word = data); VQ awaits its ack ----
            if (t1_adv) begin
                t2a_v <= 1'b1; t2a_vq <= (t1_tex && t1_vq);
                t2a_dv <= !(t1_tex && t1_vq);          // done unless VQ
                for (i=0;i<4;i=i+1) t2a_word[i] <= t1_mem[i];  // data word (VQ resolves in T2b)
                t2a_pl <= t1_pl;
            end else if (t2a_adv) t2a_v <= 1'b0;

            // ---- T2a -> T2b ----
            if (t2a_adv) begin
                t2b_v <= 1'b1; t2b_vq <= t2a_vq; t2b_dv <= t2a_dv;
                for (i=0;i<4;i=i+1) t2b_word[i] <= t2a_word[i];
                t2b_pl <= t2a_pl;
            end else if (t2b_adv) t2b_v <= 1'b0;

            // ---- T2b VQ capture: guarded by !t2b_adv, but vq_ack implies t2b_adv
            //      (out_ready tied high -> the pixel drains the moment its word
            //      arrives), so this never fires - the combinational texel bypass
            //      above forwards vq_resp.rdata on that drain cycle instead. Kept in
            //      case out_ready ever gates T2b. ----
            if (t2b_v && t2b_vq && !t2b_dv && vq_ack && !t2b_adv) begin
                for (i=0;i<4;i=i+1) t2b_word[i] <= vq_resp[i].rdata;
                t2b_dv <= 1'b1;
            end

`ifndef SYNTHESIS
            // every ack must be owed by the pixel the order says it belongs to; an
            // unowed ack means the stage bookkeeping desynced from the cache pipe.
            if (tc_ack && !(tc_ack_t0b || tc_ack_t0a))
                $error("tex_fetch4_ob %m: tc ack with no owing pixel in T0a/T0b");
            if (vq_ack && !(t2b_v && t2b_vq && !t2b_dv))
                $error("tex_fetch4_ob %m: vq ack with no owing pixel in T2b");
`endif
        end
    end
endmodule

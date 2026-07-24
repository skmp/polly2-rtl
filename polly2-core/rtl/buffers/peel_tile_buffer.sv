//
// peel_tile_buffer - the layer-peel depth/tag tile buffer, banked into M10K, with
// its access pattern ENFORCED by typed per-client ports (not by convention).
//
// Storage: ONE simple-dual-port tile_ram (u_ram), WIDTH = 129 bits/lane packing
// {valid, tag2[31:0], tag[31:0], depth2[31:0], depth[31:0]}, NBANKS = LANES banks.
// Bank = x[BANK_BITS-1:0], addr = {y[4:0], x[4:BANK_BITS]} (AW bits, 1024/LANES
// entries/bank) - a whole LANES-pixel raster chunk is one address across all
// banks. For a 32x32 tile: LANES=8 -> 3 bank bits, 7-bit addr, 128/bank;
// LANES=4 -> 2 bank bits, 8-bit addr, 256/bank.
//
// The RAM has exactly ONE read port and ONE write port. This module multiplexes
// them across the render phases and OWNS the read/compare/write RMW so no external
// code can drive a port directly. The peel_core barriers serialize the phases, so
// only one read client and one write client is ever active per cycle; the module
// ASSERTS this (sim) and, being the sole driver, makes a mis-use un-representable.
//
// Read clients  (at most one asserted/cycle): raster stage-A | shade | PeelBuffers.
// Write clients (at most one asserted/cycle): raster stage-B | CLEAR | PeelBuffers.
//
// The registered read gives 1-cycle latency, so:
//   * RASTER: stage A (ras_a_valid) presents the chunk read; the NEXT cycle stage B
//     (ras_b_valid) feeds back the latched fragment fields, the internal depth
//     compare runs off the read-back chunk, and the passing lanes are written. The
//     per-lane pass/more results are echoed out (b_pass_lp / b_more) for the caller's
//     dt_pt reg + more_to_draw accumulate.
//   * SHADE: sh_rd_valid + sh_rd_id present a single-pixel read; the next cycle
//     sh_valid/sh_tag/sh_depth carry that pixel's staged fields.
//   * CLEAR: clr_valid writes {clr_depth, clr_tag} to all banks at clr_addr.
//   * PEELBUFFERS: an RMW walk - pb_rd_valid+pb_rd_addr read chunk N; the next cycle
//     pb_wr_valid+pb_wr_addr write the transformed chunk (depth2<-depth UNLESS depth is
//     the FLT_MAX sentinel -> keep old depth2; tag2<-tag or 0xFFFFFFFF when pb_first;
//     depth<-FLT_MAX, valid<-0). The sentinel guard preserves the opaque-Z reference a
//     later z_keep=1 empty-opaque entry inherits (see the PW_DEPTH2 write comment).
//
module peel_tile_buffer import tsp_pkg::*; #(
    parameter integer LANES = 8
) (
    input                       clk,
    input                       reset,

    // ---- RASTER stage A: present the read of the resolved chunk (y, x-base) ----
    input                       ras_a_valid,
    input      [4:0]            ras_a_y,
    input      [4:0]            ras_a_x,     // chunk base (LANES-aligned)

    // ---- RASTER stage B: RMW write-back of the chunk stage A read last cycle ----
    input                       ras_b_valid,
    input      [LANES-1:0]      b_inside,
    input      [32*LANES-1:0]   b_invw,      // per-lane new invW (flat)
    input      [4:0]            b_y,
    input      [4:0]            b_x,         // chunk base (LANES-aligned)
    input      [31:0]           b_tag,       // fragment CoreTag
    input      [2:0]            b_mode,      // ISP DepthMode (opaque path)
    input                       b_zwdis,     // ZWriteDis (opaque path)
    input                       b_peeling,   // 1 = layer-peel compare, 0 = opaque
    // ---- FORWARD punch-through resolve compare (b_peeling must be 0) ----
    // Plane mapping during the PT phase: zb = this pass's working best (nearest
    // candidate so far, seeded 0), zb2 = forward boundary (select strictly
    // NEARER-THAN-BEST and BEHIND-BOUNDARY, seeded FLT_MAX), tag2 = Zceil (the
    // opaque depth: candidate must beat it per the frag's ISP DepthMode - this
    // reuses the opaque comparator with its ob input muxed to tag2). All depths
    // are (0, FLT_MAX) positives, so the taps compare like integers. zwrite_dis
    // does not apply to PT/OP.
    input                       b_fwd,       // 1 = forward PT-resolve compare
    input      [LANES-1:0]      b_res,       // per-lane RESOLVED bit (alpha passed
                                             // in an earlier PT pass): lane inert
    output     [LANES-1:0]      b_pass_lp,   // per-lane peel accept (for dt_pt)
    output     [LANES-1:0]      b_more,      // per-lane MoreToDraw (peel)
    output     [32*LANES-1:0]   b_oldtag,    // per-lane RESIDENT pending tag (tagBufferA
                                             // read back in stage B) - the tag a peel
                                             // accept displaces; for the sort cache
    // per-lane STAGE-B WRITE-ENABLE (accept: inside & pass, peel or opaque). Mirrors
    // exactly the lanes this module writes back, so the split-out u_taginvw handoff
    // buffer can DUPLICATE the {valid,tag,invW} write with an identical mask.
    output     [LANES-1:0]      b_we,

    // ---- SHADE: single-pixel read (id = {y[4:0], x[4:0]}) ----
    input                       sh_rd_valid,
    input      [9:0]            sh_rd_id,
    output reg                  sh_valid,    // staged-this-pass bit  (1-cyc latency)
    output reg [31:0]           sh_tag,      // pending tag           (1-cyc latency)
    output reg [31:0]           sh_depth,    // depthBufferA (invW)   (1-cyc latency)

    // ---- CLEAR: write {depth, tag} background to all banks at clr_addr ----
    input                       clr_valid,
    input      [10-$clog2(LANES)-1:0] clr_addr,
    input      [31:0]           clr_depth,
    input      [31:0]           clr_tag,

    // ---- PEELBUFFERS RMW walk (read-ahead / delayed write) ----
    input                       pb_rd_valid,
    input      [10-$clog2(LANES)-1:0] pb_rd_addr,
    input                       pb_wr_valid,
    input      [10-$clog2(LANES)-1:0] pb_wr_addr,
    input                       pb_first,    // fold SetTagToMax: tag2 <- 0xFFFFFFFF
    // ---- PT forward-resolve walks (reuse the pb_rd/pb_wr cursors) ----
    //  pb_ptinit: seed the PT phase:  tag2 <- zb (Zceil = opaque depth),
    //             zb2 <- FLT_MAX (boundary = nearest), zb <- 0 (working seed),
    //             valid <- 0. tag kept.
    //  pb_ptswap: between PT passes:  zb2 <- (zb==0 ? zb2 : zb) (boundary
    //             advances only where the pass staged something - this also
    //             PRESERVES a resolved pixel's depth in zb2 forever, since a
    //             resolved lane never stages again), zb <- 0, valid <- 0.
    //             tag/tag2 kept.
    //  pb_ptfix : end of the PT phase: zb <- (pb_res ? pb_zres : tag2) = the
    //             final opaque reference Zfinal (the BLEND-written resolved
    //             depth, else the original opaque depth), valid <- 0. The
    //             following TL PeelBuffers then copies zb into zb2 and
    //             overwrites tag2, so nothing else needs restoring. pb_zres is
    //             the external Zres RAM's chunk read (same read-ahead cursor,
    //             same 1-cycle latency as this buffer's own read).
    input                       pb_ptinit,
    input                       pb_ptswap,
    input                       pb_ptfix,
    input      [LANES-1:0]      pb_res,      // per-lane resolved bit for pb_wr chunk
    input      [32*LANES-1:0]   pb_zres,     // per-lane blend-resolved depth
    // ---- z_keep depth-restore RMW (reuses the pb_rd/pb_wr cursors) ----
    // When pb_zkeep is asserted alongside the pb_wr write, the transform is NOT the
    // PeelBuffers reference-swap: instead it RESTORES the kept depth for a z_keep=1 OP
    // entry. After a peel, PW_DEPTH (zb) is left at the FLT_MAX sentinel that PeelBuffers
    // wrote every pass, while the real last-drawn (closest) depth survives in PW_DEPTH2
    // (zb2, the reference). Per pixel: zb <- (zb==FLT_MAX ? zb2 : zb); tag/tag2/valid are
    // preserved (the tag invalidate for the OP pre-walk is done in the SEPARATE u_taginvw
    // buffer). Only pixels the final peel pass left as the sentinel are restored, so an
    // OP-only predecessor (real zb, stale zb2) is untouched.
    input                       pb_zkeep
);
    localparam integer NB     = LANES;
    localparam integer BANK_BITS = $clog2(LANES);       // 3 for 8, 2 for 4
    localparam integer AW        = 10 - BANK_BITS;       // per-bank addr width (7 / 8)
    localparam integer PW_DEPTH  = 0;    // [31:0]  depthBufferA (zb)
    localparam integer PW_DEPTH2 = 32;   // [31:0]  depthBufferB (zb2, reference)
    localparam integer PW_TAG    = 64;   // [31:0]  tagBufferA   (pb)
    localparam integer PW_TAG2   = 96;   // [31:0]  tagBufferB   (pb2)
    localparam integer PW_VALID  = 128;  // [0]     tagStatus.valid
    localparam integer PEEL_W = 129;
    localparam [31:0]  FLT_MAX = 32'h7F7FFFFF;

    // -------------------- the block RAM --------------------
    reg  [NB-1:0]         we;
    reg  [AW*NB-1:0]      waddr;
    reg  [AW*NB-1:0]      raddr;
    reg  [PEEL_W*NB-1:0]  wdata;
    wire [PEEL_W*NB-1:0]  rdata;
    tile_ram #(.WIDTH(PEEL_W), .NBANKS(NB)) u_ram (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(raddr), .rdata(rdata)
    );

    // pack an AW-bit bank address {y[4:0], x[4:BANK_BITS]} onto all NB banks
    // (same addr on every bank; the chunk spans one addr across all banks).
    function automatic [AW*NB-1:0] pack_addr(input [4:0] y, input [4:0] xchunk);
        integer b;
        begin
            pack_addr = '0;
            for (b = 0; b < NB; b = b + 1)
                pack_addr[AW*b +: AW] = {y, xchunk[4:BANK_BITS]};
        end
    endfunction
    // per-lane field extractors from a packed chunk word
    function automatic [31:0] f_depth (input [PEEL_W*NB-1:0] w, input integer b);
        f_depth  = w[PEEL_W*b + PW_DEPTH  +: 32]; endfunction
    function automatic [31:0] f_depth2(input [PEEL_W*NB-1:0] w, input integer b);
        f_depth2 = w[PEEL_W*b + PW_DEPTH2 +: 32]; endfunction
    function automatic [31:0] f_tag   (input [PEEL_W*NB-1:0] w, input integer b);
        f_tag    = w[PEEL_W*b + PW_TAG    +: 32]; endfunction
    function automatic [31:0] f_tag2  (input [PEEL_W*NB-1:0] w, input integer b);
        f_tag2   = w[PEEL_W*b + PW_TAG2   +: 32]; endfunction
    function automatic       f_valid  (input [PEEL_W*NB-1:0] w, input integer b);
        f_valid  = w[PEEL_W*b + PW_VALID]; endfunction

    // -------------------- internal depth compare (stage B) --------------------
    // Runs off the read-back chunk (rdata = the chunk stage A read last cycle) using
    // the latched b_* fragment fields.
    wire [NB-1:0] ras_pass_op, ras_pass_lp, ras_more_lp, ras_pass_fwd, ras_more_fwd;
    wire [NB-1:0] lp_gt_zb, lp_lt_zb2;
    genvar gd;
    generate
        for (gd = 0; gd < NB; gd = gd + 1) begin : dcmp
            // forward mode: the opaque comparator doubles as the Zceil test
            // (candidate must beat the OPAQUE depth per the frag's DepthMode);
            // its ob input muxes to tag2, which holds Zceil during the PT phase.
            isp_depth_cmp u_cmp (
                .mode(b_mode),
                .nw  (b_invw[32*gd +: 32]),
                .ob  (b_fwd ? f_tag2(rdata, gd) : f_depth(rdata, gd)),
                .pass(ras_pass_op[gd]));
            isp_depth_cmp_lp u_cmp_lp (
                .nw   (b_invw[32*gd +: 32]),
                .tag  (b_tag),
                .zb   (f_depth (rdata, gd)),
                .zb2  (f_depth2(rdata, gd)),
                .pb   (f_tag   (rdata, gd)),
                .pb2  (f_tag2  (rdata, gd)),
                .valid(f_valid (rdata, gd)),
                .pass (ras_pass_lp[gd]),
                .more (ras_more_lp[gd]),
                .o_nw_gt_zb (lp_gt_zb[gd]),
                .o_nw_lt_zb2(lp_lt_zb2[gd]));
            assign b_oldtag[32*gd +: 32] = f_tag(rdata, gd);
            // FORWARD accept: beats Zceil (ras_pass_op with the ob mux), strictly
            // behind the boundary (nw < zb2), nearer than the working best
            // (nw > zb), and the lane not already resolved. No new comparators -
            // the lp taps are on exactly the right planes.
            wire fwd_cand = ras_pass_op[gd] && lp_lt_zb2[gd] && !b_res[gd];
            assign ras_pass_fwd[gd] = fwd_cand && lp_gt_zb[gd];
            // FORWARD MoreToDraw (drives the sort$ demote, exactly mirroring the
            // backward peel): a fragment is a FUTURE candidate iff it is in-window
            // but lost to the current best (the boundary will descend past the
            // winner, re-exposing it), or it is the displaced staged resident.
            // Consumed (z>=boundary), ceiling-occluded and resolved lanes get NO
            // demote - those fragments can never be selected again, so the sort$
            // skip set GROWS as pixels resolve.
            assign ras_more_fwd[gd] = (fwd_cand && !lp_gt_zb[gd])
                                   || (ras_pass_fwd[gd] && f_valid(rdata, gd));
        end
    endgenerate
    // peel accept / more are only meaningful on peel/forward lanes that are inside
    assign b_pass_lp = (b_peeling ? ras_pass_lp : b_fwd ? ras_pass_fwd : '0) & b_inside;
    assign b_more    = (b_peeling ? ras_more_lp : b_fwd ? ras_more_fwd : '0) & b_inside;
    // per-lane stage-B write-enable = inside & (peel | forward | opaque accept).
    // Exactly the `we[cw]` computed in the write mux below; exposed so u_taginvw
    // can duplicate the accepted {valid,tag,invW} write with an identical mask.
    assign b_we = ras_b_valid ? (b_inside &
                  (b_peeling ? ras_pass_lp : b_fwd ? ras_pass_fwd : ras_pass_op)) : '0;

    // -------------------- READ port mux --------------------
    always @(*) begin
        raddr = '0;
        if (ras_a_valid)      raddr = pack_addr(ras_a_y, ras_a_x);
        else if (sh_rd_valid) raddr = {NB{ {sh_rd_id[9:5], sh_rd_id[4:BANK_BITS]} }};
        else if (pb_rd_valid) raddr = {NB{pb_rd_addr}};
    end

    // -------------------- WRITE port mux --------------------
    integer cw;
    always @(*) begin
        we    = '0;
        waddr = '0;
        wdata = '0;

        if (clr_valid) begin                       // CLEAR: {depth, tag} all banks
            we    = {NB{1'b1}};
            waddr = {NB{clr_addr}};
            for (cw = 0; cw < NB; cw = cw + 1) begin
                wdata[PEEL_W*cw + PW_DEPTH +: 32] = clr_depth;
                wdata[PEEL_W*cw + PW_TAG   +: 32] = clr_tag;
                // depth2/tag2/valid don't-care for OP; PeelBuffers sets them.
            end
        end else if (pb_wr_valid && pb_ptinit) begin // PT phase seed
            we    = {NB{1'b1}};
            waddr = {NB{pb_wr_addr}};
            for (cw = 0; cw < NB; cw = cw + 1) begin
                wdata[PEEL_W*cw + PW_TAG2   +: 32] = f_depth(rdata, cw); // Zceil <- Zop
                wdata[PEEL_W*cw + PW_DEPTH2 +: 32] = FLT_MAX;            // boundary
                wdata[PEEL_W*cw + PW_DEPTH  +: 32] = 32'h0;              // working seed
                wdata[PEEL_W*cw + PW_TAG    +: 32] = f_tag(rdata, cw);
                wdata[PEEL_W*cw + PW_VALID]        = 1'b0;
            end
        end else if (pb_wr_valid && pb_ptswap) begin // PT boundary advance
            we    = {NB{1'b1}};
            waddr = {NB{pb_wr_addr}};
            for (cw = 0; cw < NB; cw = cw + 1) begin
                // advance only where the pass staged (zb!=0 seed): keeps a
                // resolved lane's depth parked in zb2, and an unstaged lane's
                // boundary where it was.
                wdata[PEEL_W*cw + PW_DEPTH2 +: 32] =
                    (f_depth(rdata, cw) == 32'h0) ? f_depth2(rdata, cw)
                                                  : f_depth (rdata, cw);
                wdata[PEEL_W*cw + PW_DEPTH  +: 32] = 32'h0;
                wdata[PEEL_W*cw + PW_TAG    +: 32] = f_tag (rdata, cw);
                wdata[PEEL_W*cw + PW_TAG2   +: 32] = f_tag2(rdata, cw);  // Zceil kept
                wdata[PEEL_W*cw + PW_VALID]        = 1'b0;
            end
        end else if (pb_wr_valid && pb_ptfix) begin // PT phase close: zb <- Zfinal
            we    = {NB{1'b1}};
            waddr = {NB{pb_wr_addr}};
            for (cw = 0; cw < NB; cw = cw + 1) begin
                wdata[PEEL_W*cw + PW_DEPTH  +: 32] =
                    pb_res[cw] ? pb_zres[32*cw +: 32]  // blend-resolved depth
                               : f_tag2  (rdata, cw);  // untouched: opaque depth
                wdata[PEEL_W*cw + PW_DEPTH2 +: 32] = f_depth2(rdata, cw);
                wdata[PEEL_W*cw + PW_TAG    +: 32] = f_tag (rdata, cw);
                wdata[PEEL_W*cw + PW_TAG2   +: 32] = f_tag2(rdata, cw);
                wdata[PEEL_W*cw + PW_VALID]        = 1'b0;
            end
        end else if (pb_wr_valid && pb_zkeep) begin // z_keep depth-restore RMW
            // zb <- (zb==FLT_MAX ? zb2 : zb); keep tag/tag2/valid/depth2. Undoes the
            // FLT_MAX sentinel a prior peel left in zb so a z_keep=1 OP entry depth-tests
            // against the real last-drawn depth (else GREATER always fails vs FLT_MAX and
            // the entry's OP - e.g. the THPS2 special bar - is wrongly occluded).
            we    = {NB{1'b1}};
            waddr = {NB{pb_wr_addr}};
            for (cw = 0; cw < NB; cw = cw + 1) begin
                wdata[PEEL_W*cw + PW_DEPTH  +: 32] =
                    (f_depth(rdata, cw) == FLT_MAX) ? f_depth2(rdata, cw)
                                                    : f_depth (rdata, cw);
                wdata[PEEL_W*cw + PW_DEPTH2 +: 32] = f_depth2(rdata, cw);
                wdata[PEEL_W*cw + PW_TAG    +: 32] = f_tag  (rdata, cw);
                wdata[PEEL_W*cw + PW_TAG2   +: 32] = f_tag2 (rdata, cw);
                wdata[PEEL_W*cw + PW_VALID]        = f_valid(rdata, cw);
            end
        end else if (pb_wr_valid) begin            // PeelBuffers RMW transform
            we    = {NB{1'b1}};
            waddr = {NB{pb_wr_addr}};
            for (cw = 0; cw < NB; cw = cw + 1) begin
                wdata[PEEL_W*cw + PW_DEPTH  +: 32] = FLT_MAX;
                // reference (zb2) <- zb (old depth), EXCEPT when zb is the FLT_MAX sentinel
                // (this pixel peeled NOTHING last pass): then KEEP the old zb2. Without this,
                // an entry's FIRST PeelBuffers would swap the sentinel in and discard the
                // carried reference - which for a z_keep=1 entry whose opaque list is EMPTY
                // is the only surviving copy of the opaque Z. That refsw2 bug wrongly z-fails
                // the entry's TR (e.g. the THPS2 OSD occluded by the frozen scene). Merging
                // odepth into zb2 this way needs no extra buffer - just the right reload.
                wdata[PEEL_W*cw + PW_DEPTH2 +: 32] =
                    (f_depth(rdata, cw) == FLT_MAX) ? f_depth2(rdata, cw)
                                                    : f_depth (rdata, cw);
                wdata[PEEL_W*cw + PW_TAG    +: 32] = f_tag  (rdata, cw);
                wdata[PEEL_W*cw + PW_TAG2   +: 32] =
                    pb_first ? 32'hFFFFFFFF : f_tag(rdata, cw);
                wdata[PEEL_W*cw + PW_VALID]        = 1'b0;
            end
        end else if (ras_b_valid) begin            // stage B: depth-cmp write-back
            waddr = pack_addr(b_y, b_x);
            for (cw = 0; cw < NB; cw = cw + 1) begin
                if (b_inside[cw]) begin
                    if (b_peeling || b_fwd) begin
                        // peel accept AND forward accept write the same fields:
                        // zb <- invW, pb <- tag, valid <- 1; boundary/Zceil kept.
                        if (b_peeling ? ras_pass_lp[cw] : ras_pass_fwd[cw]) begin
                            we[cw] = 1'b1;
                            wdata[PEEL_W*cw + PW_DEPTH  +: 32] = b_invw[32*cw +: 32];
                            wdata[PEEL_W*cw + PW_TAG    +: 32] = b_tag;
                            wdata[PEEL_W*cw + PW_VALID]        = 1'b1;
                            wdata[PEEL_W*cw + PW_DEPTH2 +: 32] = f_depth2(rdata, cw);
                            wdata[PEEL_W*cw + PW_TAG2   +: 32] = f_tag2  (rdata, cw);
                        end
                    end else begin
                        if (ras_pass_op[cw]) begin // opaque: tag<-tag, depth<-invW
                            we[cw] = 1'b1;
                            wdata[PEEL_W*cw + PW_DEPTH  +: 32] =
                                b_zwdis ? f_depth(rdata, cw) : b_invw[32*cw +: 32];
                            wdata[PEEL_W*cw + PW_TAG    +: 32] = b_tag;
                            wdata[PEEL_W*cw + PW_DEPTH2 +: 32] = f_depth2(rdata, cw);
                            wdata[PEEL_W*cw + PW_TAG2   +: 32] = f_tag2  (rdata, cw);
                            wdata[PEEL_W*cw + PW_VALID]        = f_valid (rdata, cw);
                        end
                    end
                end
            end
        end
    end

    // -------------------- SHADE single-pixel read output --------------------
    // 1-cycle latency: sh_rd_valid presented this cycle -> fields next cycle. The
    // lane is sh_rd_id[BANK_BITS-1:0]; latch it so the extract tracks the pixel.
    reg [BANK_BITS-1:0] sh_lane_r;
    always @(posedge clk) begin
        if (reset) sh_lane_r <= '0;
        else if (sh_rd_valid) sh_lane_r <= sh_rd_id[BANK_BITS-1:0];
    end
    always @(*) begin
        sh_valid = f_valid (rdata, sh_lane_r);
        sh_tag   = f_tag   (rdata, sh_lane_r);
        sh_depth = f_depth (rdata, sh_lane_r);
    end

`ifndef SYNTHESIS
    // enforce: at most one READ client and one WRITE client active per cycle.
    always @(posedge clk) if (!reset) begin
        if ((ras_a_valid + sh_rd_valid + pb_rd_valid) > 1)
            $error("peel_tile_buffer: multiple READ clients (%b%b%b)",
                   ras_a_valid, sh_rd_valid, pb_rd_valid);
        if ((clr_valid + pb_wr_valid + ras_b_valid) > 1)
            $error("peel_tile_buffer: multiple WRITE clients (%b%b%b)",
                   clr_valid, pb_wr_valid, ras_b_valid);
    end
`endif
endmodule

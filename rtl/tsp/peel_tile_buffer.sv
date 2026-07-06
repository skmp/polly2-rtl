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
//     pb_wr_valid+pb_wr_addr write the transformed chunk (depth2<-depth, tag2<-tag
//     or 0xFFFFFFFF when pb_first, depth<-FLT_MAX, valid<-0).
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
    output     [LANES-1:0]      b_pass_lp,   // per-lane peel accept (for dt_pt)
    output     [LANES-1:0]      b_more,      // per-lane MoreToDraw (peel)
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

    // ---- CLEAR: LAZY. clr_all pulses ONE cycle to invalidate the whole tile (valid_r<='0)
    //      and latch the background depth/tag; no RAM walk. A pixel with valid_r==0 reads the
    //      background (OP) / FLT_MAX+invalid (peel) via the stage-B read-mux below. ----
    input                       clr_all,     // 1-cyc: invalidate whole tile + latch bg
    input      [31:0]           clr_depth,   // background depth (default for un-written OP px)
    input      [31:0]           clr_tag,     // background tag

    // ---- PEELBUFFERS: LAZY. peel_swap pulses ONE cycle at the start of each peel pass:
    //      flip ab_sel (B_new = old A = the reference plane) and invalidate A (valid_r<='0,
    //      so the swapped-in A reads FLT_MAX/invalid). No RMW walk. pb_first (pass 1) forces
    //      the B-tag to 0xFFFFFFFF via first_peel_r (SetTagToMax). ----
    input                       peel_swap,   // 1-cyc: begin a peel pass (flip A/B, reset A)
    input                       pb_first     // this peel_swap is the tile's FIRST pass
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

    // -------------------- LAZY-CLEAR per-pixel valid register --------------------
    // `valid` (tagStatus.valid) is now a 1024-bit FF array cleared in ONE cycle by clr_all,
    // NOT a field walked into the RAM. A pixel with valid_r==0 is "not written since clear":
    // the stage-B read-mux substitutes the background (OP) or FLT_MAX+invalid (peel) for it.
    // The RAM's PW_VALID field is no longer read/written (kept in the word to avoid a resize).
    reg  [1023:0] valid_r;               // PACKED so the whole-tile clear is one `<= '0`
    reg  [31:0] bg_depth_r, bg_tag_r;    // latched at clr_all; the OP-default for un-written px

    // -------------------- A/B pointer (Tier 3: swap-by-field, no copy) --------------------
    // The RAM word holds BOTH field pairs {depth,tag} (pair 0) and {depth2,tag2} (pair 1).
    // `ab_sel` names which pair is the CURRENT-pass A: ab_sel=0 -> A=pair0(depth/tag),
    // B=pair1(depth2/tag2); ab_sel=1 -> swapped. PeelBuffers' "B_new = A_old" is just
    // `peel_swap` flipping ab_sel (no walk, no copy). The swapped-in A is masked fresh by
    // valid_r<='0. first_peel_r forces the B-tag (pb2) to 0xFFFFFFFF for pass 1 (SetTagToMax).
    reg  ab_sel;
    reg  first_peel_r;
    // A/B field offsets selected by ab_sel: A = the (ab_sel? pair1 : pair0) fields.
    integer OFF_DA, OFF_TA, OFF_DB, OFF_TB;
    always @* begin
        OFF_DA = ab_sel ? PW_DEPTH2 : PW_DEPTH;    // A depth
        OFF_TA = ab_sel ? PW_TAG2   : PW_TAG;      // A tag
        OFF_DB = ab_sel ? PW_DEPTH  : PW_DEPTH2;   // B depth (reference)
        OFF_TB = ab_sel ? PW_TAG    : PW_TAG2;     // B tag   (reference)
    end
    function automatic [31:0] fld(input [PEEL_W*NB-1:0] w, input integer off, input integer b);
        fld = w[PEEL_W*b + off +: 32]; endfunction
    // pixel index of lane b in the chunk at (y, xchunk-base): {y[4:0], x[4:0]} = y*32 + x.
    function automatic [9:0] pix_idx(input [4:0] y, input [4:0] xchunk, input integer b);
        pix_idx = {y, xchunk[4:BANK_BITS], b[BANK_BITS-1:0]};
    endfunction

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

    // -------------------- stage-B read-mux (LAZY-CLEAR defaulting) --------------------
    // The compare reads A (depth,tag,valid) through valid_r: a lane not written since the last
    // clr_all reads the DEFAULT instead of the stale RAM field:
    //   OP   (!b_peeling): depth=bg_depth_r, tag=bg_tag_r, valid don't-care (OP ignores valid)
    //   PEEL ( b_peeling): depth=FLT_MAX,    tag=0xFFFFFFFF, valid=0 (fresh A, nothing staged)
    // valid_r is read at stage B off the registered b_y/b_x - the SAME coords that addressed
    // rdata one cycle earlier - so the mask aligns with the read-back chunk. B (depth2/tag2)
    // is NEVER defaulted (real reference-plane content).
    // A (current pass) read through valid_r + ab_sel; B (reference) read raw via ab_sel,
    // with the B-tag forced to 0xFFFFFFFF on the first peel pass (SetTagToMax).
    wire [NB-1:0]  eff_valid;
    wire [32*NB-1:0] eff_depth, eff_tag, eff_depth2, eff_tag2;
    genvar gm;
    generate
        for (gm = 0; gm < NB; gm = gm + 1) begin : effmux
            wire v = valid_r[ pix_idx(b_y, b_x, gm) ];
            assign eff_valid[gm]            = v;
            assign eff_depth [32*gm +: 32]  = v ? fld(rdata, OFF_DA, gm)
                                                : (b_peeling ? FLT_MAX : bg_depth_r);
            assign eff_tag   [32*gm +: 32]  = v ? fld(rdata, OFF_TA, gm)
                                                : (b_peeling ? 32'hFFFFFFFF : bg_tag_r);
            assign eff_depth2[32*gm +: 32]  = fld(rdata, OFF_DB, gm);
            assign eff_tag2  [32*gm +: 32]  = first_peel_r ? 32'hFFFFFFFF
                                                           : fld(rdata, OFF_TB, gm);
        end
    endgenerate

    // -------------------- internal depth compare (stage B) --------------------
    // Runs off the read-back chunk (rdata = the chunk stage A read last cycle) using
    // the latched b_* fragment fields, via the lazy-clear read-mux (eff_*) above.
    wire [NB-1:0] ras_pass_op, ras_pass_lp, ras_more_lp;
    genvar gd;
    generate
        for (gd = 0; gd < NB; gd = gd + 1) begin : dcmp
            isp_depth_cmp u_cmp (
                .mode(b_mode),
                .nw  (b_invw[32*gd +: 32]),
                .ob  (eff_depth[32*gd +: 32]),
                .pass(ras_pass_op[gd]));
            isp_depth_cmp_lp u_cmp_lp (
                .nw   (b_invw[32*gd +: 32]),
                .tag  (b_tag),
                .zb   (eff_depth [32*gd +: 32]),
                .zb2  (eff_depth2[32*gd +: 32]),
                .pb   (eff_tag   [32*gd +: 32]),
                .pb2  (eff_tag2  [32*gd +: 32]),
                .valid(eff_valid[gd]),
                .pass (ras_pass_lp[gd]),
                .more (ras_more_lp[gd]));
        end
    endgenerate
    // peel accept / more are only meaningful on peeling lanes that are inside
    assign b_pass_lp = ras_pass_lp & b_inside & {NB{b_peeling}};
    assign b_more    = ras_more_lp & b_inside & {NB{b_peeling}};
    // per-lane stage-B write-enable = inside & (peel accept | opaque accept). This is
    // exactly the `we[cw]` computed in the write mux below; expose it so u_taginvw can
    // duplicate the accepted {valid,tag,invW} write with an identical mask.
    assign b_we = ras_b_valid ? (b_inside &
                  (b_peeling ? ras_pass_lp : ras_pass_op)) : '0;

    // -------------------- READ port mux --------------------
    // Only the raster stage-A read remains (shade tied off; PeelBuffers walk removed).
    always @(*) begin
        raddr = '0;
        if (ras_a_valid)      raddr = pack_addr(ras_a_y, ras_a_x);
        else if (sh_rd_valid) raddr = {NB{ {sh_rd_id[9:5], sh_rd_id[4:BANK_BITS]} }};
    end

    // -------------------- WRITE port mux --------------------
    // Only the raster stage-B write-back remains (CLEAR + PeelBuffers walks removed). It writes
    // the CURRENT-pass A field pair (OFF_DA/OFF_TA, per ab_sel); B (reference) is untouched by
    // raster. valid is a register (set in the clocked block below), not a RAM field. The
    // accepted-lane mask is b_we; the write DATA is the same per-lane depth/tag as before but
    // steered into the A pair. depth default (ZWriteDis keep / peel keep) uses eff_depth (the
    // lazy-clear/ab_sel-correct read), never a raw RAM field.
    integer cw;
    always @(*) begin
        we    = '0;
        waddr = '0;
        wdata = '0;
        if (ras_b_valid) begin
            waddr = pack_addr(b_y, b_x);
            for (cw = 0; cw < NB; cw = cw + 1) begin
                // The whole 129-bit word is written when we[cw]=1, so a written lane must
                // PRESERVE its B (reference) pair by copying it back. B is never defaulted.
                wdata[PEEL_W*cw + OFF_DB +: 32] = fld(rdata, OFF_DB, cw);
                wdata[PEEL_W*cw + OFF_TB +: 32] = fld(rdata, OFF_TB, cw);
                if (b_inside[cw]) begin
                    if (b_peeling) begin
                        if (ras_pass_lp[cw]) begin   // peel accept: A.depth<-invW, A.tag<-tag
                            we[cw] = 1'b1;
                            wdata[PEEL_W*cw + OFF_DA +: 32] = b_invw[32*cw +: 32];
                            wdata[PEEL_W*cw + OFF_TA +: 32] = b_tag;
                        end
                    end else begin
                        if (ras_pass_op[cw]) begin   // opaque: A.depth<-invW(or keep), A.tag<-tag
                            we[cw] = 1'b1;
                            wdata[PEEL_W*cw + OFF_DA +: 32] =
                                b_zwdis ? eff_depth[32*cw +: 32] : b_invw[32*cw +: 32];
                            wdata[PEEL_W*cw + OFF_TA +: 32] = b_tag;
                        end
                    end
                end
            end
        end
    end

    // -------------------- CONTROL: valid_r / bg / ab_sel / first_peel_r --------------------
    // clr_all  : whole-tile invalidate + latch bg (lazy CLEAR). Also normalize ab_sel<-0 and
    //            clear first_peel_r (a fresh tile starts with A=pair0, no peel yet).
    // peel_swap: start a peel pass -> flip ab_sel (B_new = old A), invalidate A (valid_r<='0),
    //            and set first_peel_r from pb_first (forces pb2=FFFFFFFF this pass only).
    // stage B  : each accepted lane marks its pixel valid_r<-1 (mask same as b_we/we).
    // clr_all and peel_swap are barrier-separated 1-cyc pulses; stage-B writes never coincide
    // with them (the peel_core barriers serialize CLEAR/PeelBuffers vs raster).
    always @(posedge clk) begin
        if (reset) begin
            valid_r <= '0;
            bg_depth_r <= '0; bg_tag_r <= '0; ab_sel <= 1'b0; first_peel_r <= 1'b0;
        end else begin
            if (clr_all) begin
                valid_r <= '0;
                bg_depth_r <= clr_depth; bg_tag_r <= clr_tag;
                ab_sel <= 1'b0; first_peel_r <= 1'b0;
            end else if (peel_swap) begin
                valid_r      <= '0;
                ab_sel       <= ~ab_sel;      // B_new = old A (reference); A_new = old B (masked)
                first_peel_r <= pb_first;     // pass 1: force pb2 <- FFFFFFFF (SetTagToMax)
            end else if (ras_b_valid) begin
                // mark accepted lanes valid (they now hold this pass's A fragment).
                for (cw = 0; cw < NB; cw = cw + 1)
                    if (we[cw]) valid_r[ pix_idx(b_y, b_x, cw) ] <= 1'b1;
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
    // enforce: at most one READ client and one WRITE client active per cycle. The CLEAR and
    // PeelBuffers RAM walks are gone (lazy valid_r + A/B swap), so RAM read = raster stage-A
    // (or the tied-off shade), RAM write = raster stage-B only. clr_all/peel_swap touch only
    // the valid_r/ab_sel registers, not the RAM port.
    always @(posedge clk) if (!reset) begin
        if ((ras_a_valid + sh_rd_valid) > 1)
            $error("peel_tile_buffer: multiple READ clients (%b%b)",
                   ras_a_valid, sh_rd_valid);
        // (single RAM write client ras_b_valid; clr_all/peel_swap are register-only pulses)
        if (clr_all && peel_swap)
            $error("peel_tile_buffer: clr_all and peel_swap same cycle");
    end
`endif
endmodule

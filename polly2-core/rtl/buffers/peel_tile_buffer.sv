//
// peel_tile_buffer - the layer-peel depth/tag tile buffer, banked into M10K, with
// its access pattern ENFORCED by typed per-client ports (not by convention).
//
// Storage: ONE simple-dual-port tile_ram (u_ram), WIDTH = 240 bits/lane packing
// {z3b[23:0], isptB, isptA, validB, tagB[31:0], zbB[30:0], valid, zceil[30:0],
// refsort[23:0], tag[31:0], depth2[30:0], depth[30:0]}, NBANKS = LANES banks.
// Slots A+B are the TWO-LAYER peel working set (A = farthest owed, shaded first;
// B = next). The zceil slot is PHASE-OWNED: opaque ceiling during the PT resolve,
// the zb3 nearest-deferred bound during TL peeling (see the zb3 port header
// below); z3b is zb3's PAIR companion (the SECOND-minimum owed depth, 24-bit
// round-up), which is what makes the front cull sound under two-layer.
// Depths are 31-bit SIGN-STRIPPED floats: invW is always positive non-zero, so
// the sign bit is never stored and positive-float ordering == unsigned ordering.
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
//     the FLT_MAX sentinel -> keep old depth2; refsort<-tag[23:0] or 0 when pb_first;
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
    input      [31*LANES-1:0]   b_invw,      // per-lane new invW (flat, sign-stripped)
    input      [4:0]            b_y,
    input      [4:0]            b_x,         // chunk base (LANES-aligned)
    input      [31:0]           b_tag,       // fragment CoreTag
    input      [2:0]            b_mode,      // ISP DepthMode (opaque path)
    input                       b_zwdis,     // ZWriteDis (opaque path)
    input                       b_peeling,   // 1 = layer-peel compare, 0 = opaque
    // ---- FORWARD punch-through resolve compare (b_peeling must be 0) ----
    // Plane mapping during the PT phase: zb/pb = this pass's working best (nearest
    // candidate so far, depth seeded 0), zb2/refsort = the forward BOUNDARY KEY
    // (seeded {FLT_MAX, max} = nearer than everything), zceil = the opaque depth
    // (candidate must beat it per the frag's ISP DepthMode - this reuses the opaque
    // comparator with its ob input muxed to zceil). The boundary carries a tag so a
    // coplanar group is stepped through one fragment per pass instead of being
    // skipped wholesale - see isp_depth_cmp_lp. zwrite_dis does not apply to PT/OP.
    input                       b_fwd,       // 1 = forward PT-resolve compare
    input      [LANES-1:0]      b_res,       // per-lane RESOLVED bit (alpha passed
                                             // in an earlier PT pass): lane inert
    input                       b_2l,        // LEVEL: two-layer peel enabled (the
                                             // +onelayer bisect switch drives it 0:
                                             // slot B then never stages and the walk
                                             // advance always takes slot A)
    input                       b_ispt,      // fragment came from the PT list (rides
                                             // into the slot ispt bits for the
                                             // taginvw images' alpha-test enable)
    output     [LANES-1:0]      b_pass_lp,   // per-lane slot-A accept (for dt_pt +
                                             // the u_taginvw A-image duplicate)
    output     [LANES-1:0]      b_pass_b,    // per-lane slot-B accept (peel only)
    output     [LANES-1:0]      b_bstg,      // per-lane: slot B STAGED this write -
                                             // a direct B-accept OR an A-accept
                                             // sliding a staged A in (the caller's
                                             // pass_bany must see both)
    output     [LANES-1:0]      b_more,      // per-lane MoreToDraw (peel)
    output     [LANES-1:0]      b_disp,      // per-lane: this `more` DISPLACED a
                                             // staged fragment out (demote b_oldtag;
                                             // a clear b_disp more demotes b_tag)
    output     [32*LANES-1:0]   b_oldtag,    // per-lane DISPLACED tag for the sort
                                             // cache: slot B's old tag (peel) / the
                                             // working best (PT forward)
    // per-lane STAGE-B WRITE-ENABLE (accept: inside & pass, peel or opaque). Mirrors
    // exactly the lanes this module writes back, so the split-out u_taginvw handoff
    // buffer can DUPLICATE the {valid,tag,invW} write with an identical mask.
    output     [LANES-1:0]      b_we,

    // ---- SHADE: single-pixel read (id = {y[4:0], x[4:0]}) ----
    input                       sh_rd_valid,
    input      [9:0]            sh_rd_id,
    output reg                  sh_valid,    // staged-this-pass bit  (1-cyc latency)
    output reg [31:0]           sh_tag,      // pending tag           (1-cyc latency)
    output reg [30:0]           sh_depth,    // depthBufferA (invW)   (1-cyc latency)

    // ---- CLEAR: write {depth, tag} background to all banks at clr_addr ----
    input                       clr_valid,
    input      [10-$clog2(LANES)-1:0] clr_addr,
    input      [30:0]           clr_depth,
    input      [31:0]           clr_tag,

    // ---- PEELBUFFERS RMW walk (read-ahead / delayed write) ----
    input                       pb_rd_valid,
    input      [10-$clog2(LANES)-1:0] pb_rd_addr,
    input                       pb_wr_valid,
    input      [10-$clog2(LANES)-1:0] pb_wr_addr,
    input                       pb_first,    // seed the peel reference sort field: refsort <- 0
    // ---- PT forward-resolve walks (reuse the pb_rd/pb_wr cursors) ----
    //  pb_ptinit: seed the PT phase:  zceil <- zb (the opaque depth),
    //             {zb2, refsort} <- {FLT_MAX, max} (boundary = nearer than
    //             everything), zb <- 0 (working seed), valid <- 0. tag kept.
    //  pb_ptswap: between PT passes:  {zb2, refsort} <- (zb==0 ? kept
    //             : {zb, tag[23:0]}) - the boundary KEY advances only where the
    //             pass staged something, which also PRESERVES a resolved pixel's
    //             depth in zb2 forever, since a resolved lane never stages again.
    //             zb <- 0, valid <- 0. tag/zceil kept.
    //  pb_ptfix : end of the PT phase: zb <- (pb_res ? pb_zres : zceil) = the
    //             final opaque reference Zfinal (the BLEND-written resolved
    //             depth, else the original opaque depth), valid <- 0. The
    //             following TL PeelBuffers then copies zb into zb2 and reseeds
    //             refsort, so nothing else needs restoring. pb_zres is
    //             the external Zres RAM's chunk read (same read-ahead cursor,
    //             same 1-cycle latency as this buffer's own read).
    input                       pb_ptinit,
    input                       pb_ptswap,
    input                       pb_ptfix,
    input      [LANES-1:0]      pb_res,      // per-lane resolved bit for pb_wr chunk
    input      [31*LANES-1:0]   pb_zres,     // per-lane blend-resolved depth
    // ---- z_keep depth-restore RMW (reuses the pb_rd/pb_wr cursors) ----
    // When pb_zkeep is asserted alongside the pb_wr write, the transform is NOT the
    // PeelBuffers reference-swap: instead it RESTORES the kept depth for a z_keep=1 OP
    // entry. After a peel, PW_DEPTH (zb) is left at the FLT_MAX sentinel that PeelBuffers
    // wrote every pass, while the real last-drawn (closest) depth survives in PW_DEPTH2
    // (zb2, the reference). Per pixel: zb <- (zb==FLT_MAX ? zb2 : zb); tag/refsort/zceil/valid are
    // preserved (the tag invalidate for the OP pre-walk is done in the SEPARATE u_taginvw
    // buffer). Only pixels the final peel pass left as the sentinel are restored, so an
    // OP-only predecessor (real zb, stale zb2) is untouched.
    input                       pb_zkeep,
    // ---- final-pass B fold (two-layer peel) ----------------------------------
    // Asserted for the S_PEEL_BFIN materialize walk's write-back: the peel loop
    // ended with slot B staged, and the POST-PEEL CONTRACT (z_keep successors
    // read zb / zb2 as "the last-drawn depth") requires zb to be the NEAREST
    // drawn fragment - which is B, not A. Transform: zb <- (validB ? zbB : zb);
    // every other field is KEPT verbatim.
    input                       pb_bfin,

    // ---- zb3: NEAREST DEFERRED DEPTH (the peel front-cull lookahead) ----------------
    // A TL peel pass converges zb DOWNWARD to the farthest fragment at-or-in-front of
    // the reference, so "deferred" is stable once it happens. zb3 accumulates the
    // MINIMUM depth over the fragments that still need drawing at this pixel:
    //   * deferred   (k_new > k_best)      -> candidate depth = nw
    //   * displaced  (accept while valid)  -> candidate depth = the old zb it evicts
    // Those two are EXACTLY the events that raise `more` (see isp_depth_cmp_lp), and
    // the candidate depth is the same old/new mux the sort cache demote already uses -
    // so zb3 needs one comparator per lane and no new decision logic.
    //
    // At pass end zb3 is precisely the depth the NEXT pass will select at that pixel,
    // so max(zb3) over the tile upper-bounds the next front and lets a whole triangle
    // in front of it be rejected before it is swept. UNDER-recording is safe (a missed
    // candidate only raises zb3, weakening the cull); over-recording never happens
    // because every value written is a real fragment depth.
    //
    // STORAGE IS THE PW_ZCEIL SLOT - zb3 costs no RAM at all. The opaque ceiling is
    // parked there by pb_ptinit and CONSUMED by pb_ptfix (into zb) before any TL peel
    // starts, and during TL passes every writer only ever KEEPS it - so the field is
    // provably dead exactly when zb3 is alive. The phases hand over through full-tile
    // walks: pb_ptinit re-parks the ceiling (clobbering zb3 residue), and each TL
    // PeelBuffers walk reseeds zb3 <- FLT_MAX. The FIRST such walk therefore reads
    // ceiling/CLEAR residue as "zb3", which is why the caller must discard the bound
    // it publishes on first_peel (see zf_v in peel_core).
    //
    // FLT_MAX means "nothing here will ever be selected again" and is EXCLUDED from
    // the max - otherwise one finished pixel pins the bound and no cull ever fires.
    // That exclusion is only valid while zb3 is complete, which is why the caller must
    // not trust the bound after a pass that skipped a sweep (see zf_ok in peel_core).
    output     [30:0]           pb_zb3_max,  // max over lanes of the read chunk's zb3,
                                             // FLT_MAX lanes excluded (valid with pb_rd's
                                             // data, i.e. alongside pb_wr)
    output                      pb_zb3_any,  // any lane of that chunk was not FLT_MAX
    // ---- z3b: zb3's PAIR companion, the SECOND-minimum owed depth per pixel ----
    // A TWO-LAYER pass consumes the two farthest owed fragments per pixel (A = min,
    // B = 2nd-min), so a sound front cull must clear the SECOND selection too - zb3
    // alone bounds only A (a triangle in front of every next-A can be exactly a
    // pixel's next-B: the original unsoundness). z3b tracks the 2nd-min over the
    // same candidate events, stored as 24 bits ROUNDED UP (drop invW[6:0], +1 if
    // any dropped bit set): over-stating the bound only weakens the cull - the
    // same safe direction as zb3's under-recording rule. Soundness inherits the
    // self-registration argument: a swept triangle's own depth is a candidate at
    // every covered pixel, so it can be culled only where >= 2 owed fragments sit
    // farther - exactly "can't be A or B next pass".
    // pb_z3b_max is the tile bound built the same way as pb_zb3_max, with a
    // per-lane fallback: a lane with only ONE owed fragment (z3b = sentinel)
    // contributes up24(zb3) - its next-B selection is any fragment in front of A,
    // so the A bound is the only sound one there. Lanes with zb3 = FLT_MAX are
    // excluded (nothing owed). Same validity companion: pb_zb3_any.
    output     [23:0]           pb_z3b_max,
    // ---- slot-B image export (two-layer peel): the read chunk's B fields, comb
    // off the SAME registered walk read as pb_zb3_* - peel_core forwards them into
    // the u_taginvw copy the B layer will shade from (the "materialize" write).
    output     [LANES-1:0]      pb_bt_valid,
    output     [32*LANES-1:0]   pb_bt_tag,
    output     [31*LANES-1:0]   pb_bt_invw,
    output     [LANES-1:0]      pb_bt_pt,
    output                      pb_bt_any    // any lane of this chunk staged a B
);
    localparam integer NB     = LANES;
    localparam integer BANK_BITS = $clog2(LANES);       // 3 for 8, 2 for 4
    localparam integer AW        = 10 - BANK_BITS;       // per-bank addr width (7 / 8)
    // Per-pixel per-lane record. PW_REFSORT carries the reference (TR) / boundary (PT)
    // tag sort field - the compare's composite key needs it in BOTH phases, and the
    // old tagBufferB slot cannot supply it during PT because that slot parks Zceil.
    // TWO-LAYER PEEL grew the record 150 -> 216 bits (slot B: depth+tag+valid, plus
    // the two ispt companions): at LANES=8 that is ceil(216/40) = 6 M10K per bank
    // (was 4), +16 blocks total. The B slot is what lets one pass consume two depth
    // layers - the pass-count-proportional costs it removes (re-sweeps, walks,
    // barriers) are the trade. The z3b pair field (216 -> 240) rides in the same
    // 6 blocks for free (see PW_Z3B).
    localparam integer PW_DEPTH   = 0;    // [30:0]  depthBufferA (zb)  working best
    localparam integer PW_DEPTH2  = 31;   // [30:0]  depthBufferB (zb2) reference / boundary
    localparam integer PW_TAG     = 62;   // [31:0]  tagBufferA   (pb)  working / staged tag
    localparam integer PW_REFSORT = 94;   // [23:0]  reference / boundary tag[23:0]
    localparam integer PW_ZCEIL   = 118;  // [30:0]  opaque ceiling (PT phase only)
    localparam integer PW_Z3      = PW_ZCEIL; // [30:0] zb3 (TL peel only) - see the
                                          // zb3 header: the slot is phase-owned, the
                                          // ceiling is dead once pb_ptfix consumed it
    localparam integer PW_VALID   = 149;  // [0]     tagStatus.valid (slot A)
    // ---- TWO-LAYER PEEL slot B (TR only): the pass's SECOND-farthest owed
    // fragment. Slot A (the fields above) is shaded first, B second - still
    // back-to-front. B's is_pt bit must be stored (the taginvw B-image needs it
    // and it is not derivable from the tag), and A's too (an A-accept slides old
    // A into B, ispt included).
    localparam integer PW_DEPTHB  = 150;  // [30:0]  slot B depth (zbB)
    localparam integer PW_TAGB    = 181;  // [31:0]  slot B tag
    localparam integer PW_VALIDB  = 213;  // [0]     slot B staged
    localparam integer PW_ISPTA   = 214;  // [0]     slot A fragment is PT-list
    localparam integer PW_ISPTB   = 215;  // [0]     slot B fragment is PT-list
    // z3b: the SECOND-minimum owed depth (24-bit round-up; see the pb_z3b_max port
    // header). 216 -> 240 is FREE M10K: at chunk depths <= 256 each block gives 40
    // bits of width, and PEEL_W=216 already paid for ceil(216/40) = 6 blocks/bank
    // = 240 bits of capacity - these are the 24 bits that were going spare.
    localparam integer PW_Z3B     = 216;  // [23:0]  zb3 pair (TL peel only)
    localparam integer PEEL_W = 240;
    localparam [30:0]  FLT_MAX = 31'h7F7FFFFF;
    // z3b's "fewer than two owed here" sentinel. up24() of any real depth tops out
    // at 24'hFF0000 (FLT_MAX >> 7 rounded up), so the all-ones code is never a value.
    localparam [23:0]  Z3B_MAX = 24'hFFFFFF;
    // reference-sort seeds. TR pass 1: "nothing rendered yet" = TAG_INVALID_SENTINEL,
    // whose sort field is 0, i.e. at-or-below every real fragment at the same depth.
    // PT init: the boundary starts NEARER than everything, so its sort field is max.
    localparam [23:0]  REFSORT_TR_FIRST = 24'h000000;
    localparam [23:0]  REFSORT_PT_INIT  = 24'hFFFFFF;
    // the three PT walks share one write-mux case (see the pb_ptwalk block)
    wire pb_ptwalk = pb_ptinit | pb_ptswap | pb_ptfix;

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

    // pack an AW-bit bank address onto all NB banks (same addr on every bank;
    // the chunk spans one addr across all banks). The address is the 10-bit
    // pixel index {y,x} shifted past the bank bits - written as one slice, NOT
    // as {y, x[4:BANK_BITS]}: at LANES=32 a chunk IS a whole row, so that inner
    // slice goes zero-width while [9:BANK_BITS] stays well formed.
    function automatic [AW*NB-1:0] pack_addr(input [4:0] y, input [4:0] xchunk);
        integer b;
        reg [9:0] pix;
        begin
            pack_addr = '0;
            pix = {y, xchunk};
            for (b = 0; b < NB; b = b + 1)
                pack_addr[AW*b +: AW] = pix[9:BANK_BITS];
        end
    endfunction
    // per-lane field extractors from a packed chunk word
    function automatic [30:0] f_depth (input [PEEL_W*NB-1:0] w, input integer b);
        f_depth  = w[PEEL_W*b + PW_DEPTH  +: 31]; endfunction
    function automatic [30:0] f_depth2(input [PEEL_W*NB-1:0] w, input integer b);
        f_depth2 = w[PEEL_W*b + PW_DEPTH2 +: 31]; endfunction
    function automatic [31:0] f_tag   (input [PEEL_W*NB-1:0] w, input integer b);
        f_tag    = w[PEEL_W*b + PW_TAG    +: 32]; endfunction
    // reference (TR) / boundary (PT) tag sort field - the compare's k_ref low half
    function automatic [23:0] f_refsort(input [PEEL_W*NB-1:0] w, input integer b);
        f_refsort = w[PEEL_W*b + PW_REFSORT +: 24]; endfunction
    // the WORKING tag's sort field: what refsort takes when the reference advances
    // (a part-select straight off the record - f_tag(...)[23:0] does not parse here)
    function automatic [23:0] f_tagsort(input [PEEL_W*NB-1:0] w, input integer b);
        f_tagsort = w[PEEL_W*b + PW_TAG    +: 24]; endfunction
    // the (sign-stripped) opaque depth, parked across the PT phase
    function automatic [30:0] f_zceil (input [PEEL_W*NB-1:0] w, input integer b);
        f_zceil  = w[PEEL_W*b + PW_ZCEIL  +: 31]; endfunction
    // the same slot under its TL-peel ownership: the zb3 nearest-deferred bound
    function automatic [30:0] f_z3    (input [PEEL_W*NB-1:0] w, input integer b);
        f_z3     = w[PEEL_W*b + PW_Z3     +: 31]; endfunction
    // zb3's pair companion: the 2nd-minimum owed depth (24-bit round-up domain)
    function automatic [23:0] f_z3b   (input [PEEL_W*NB-1:0] w, input integer b);
        f_z3b    = w[PEEL_W*b + PW_Z3B    +: 24]; endfunction
    // 31-bit depth -> the 24-bit z3b domain, ROUNDED UP (conservative: the stored
    // bound may only over-state, which weakens the cull). Monotonic in the
    // positive-float-bits ordering; never reaches Z3B_MAX for a real depth.
    function automatic [23:0] up24 (input [30:0] v);
        up24 = v[30:7] + {23'd0, |v[6:0]}; endfunction
    function automatic       f_valid  (input [PEEL_W*NB-1:0] w, input integer b);
        f_valid  = w[PEEL_W*b + PW_VALID]; endfunction
    // ---- slot B extractors ----
    function automatic [30:0] f_zbB   (input [PEEL_W*NB-1:0] w, input integer b);
        f_zbB    = w[PEEL_W*b + PW_DEPTHB +: 31]; endfunction
    function automatic [31:0] f_tagB  (input [PEEL_W*NB-1:0] w, input integer b);
        f_tagB   = w[PEEL_W*b + PW_TAGB   +: 32]; endfunction
    function automatic [23:0] f_tagBs (input [PEEL_W*NB-1:0] w, input integer b);
        f_tagBs  = w[PEEL_W*b + PW_TAGB   +: 24]; endfunction
    function automatic       f_validB (input [PEEL_W*NB-1:0] w, input integer b);
        f_validB = w[PEEL_W*b + PW_VALIDB]; endfunction
    function automatic       f_isptA (input [PEEL_W*NB-1:0] w, input integer b);
        f_isptA  = w[PEEL_W*b + PW_ISPTA]; endfunction
    function automatic       f_isptB (input [PEEL_W*NB-1:0] w, input integer b);
        f_isptB  = w[PEEL_W*b + PW_ISPTB]; endfunction

    // -------------------- internal depth compare (stage B) --------------------
    // Runs off the read-back chunk (rdata = the chunk stage A read last cycle) using
    // the latched b_* fragment fields.
    wire [NB-1:0] ras_pass_op, ras_pass_lp, ras_more_lp, ras_pass_fwd, ras_more_fwd;
    wire [NB-1:0] ras_pass_b, ras_disp_lp; // 2-layer peel: slot-B accept / displaced-out
    wire [NB-1:0] ras_slide;               // slot A was STAGED at this A-accept (slides in)
    wire [31*NB-1:0] zb3_nxt;              // per-lane zb3 after this fragment
    wire [24*NB-1:0] z3b_nxt;              // per-lane z3b (zb3 pair) after this fragment
    genvar gd;
    generate
        for (gd = 0; gd < NB; gd = gd + 1) begin : dcmp
            // forward mode: the opaque comparator doubles as the Zceil test; its
            // ob input muxes to the zceil field (the opaque depth). The
            // DepthMode is FORCED to 6 (greater-or-equal): PT has no configurable
            // depth mode - refsw2 forces mode=6 for PUNCHTHROUGH_PASS0/PASSN and
            // ignores the ISP field, so honoring a game's junk DepthMode here
            // would mis-compare against the opaque ceiling.
            isp_depth_cmp u_cmp (
                .mode(b_fwd ? 3'd6 : b_mode),
                .nw  (b_invw[31*gd +: 31]),
                .ob  (b_fwd ? f_zceil(rdata, gd) : f_depth(rdata, gd)),
                .pass(ras_pass_op[gd]));
            // ONE ordered compare serves both resolves - pt selects the direction.
            // The old pure-depth taps (nw>zb / nw<zb2) are gone: with the boundary
            // carrying a sort field, the PT window test IS the composite compare.
            wire cmp_pass, cmp_pass_b, cmp_disp, cmp_more;
            isp_depth_cmp_lp u_cmp_lp (
                .en2     (b_2l),
                .pt      (b_fwd),
                .nw      (b_invw[31*gd +: 31]),
                .tag     (b_tag),
                .zb      (f_depth  (rdata, gd)),
                .pb      (f_tag    (rdata, gd)),
                .zb2     (f_depth2 (rdata, gd)),
                .pb2_sort(f_refsort(rdata, gd)),
                .valid   (f_valid  (rdata, gd)),
                .zbB     (f_zbB    (rdata, gd)),
                .pbB_sort(f_tagBs  (rdata, gd)),
                .validB  (f_validB (rdata, gd)),
                .pass    (cmp_pass),
                .pass_b  (cmp_pass_b),
                .disp    (cmp_disp),
                .more    (cmp_more));
            assign ras_pass_lp[gd] = cmp_pass;
            assign ras_pass_b[gd]  = cmp_pass_b;
            assign ras_more_lp[gd] = cmp_more;
            // the DISPLACED tag for the sort cache: peel loses slot B's old tag,
            // the PT forward resolve loses the working best (as before)
            assign ras_disp_lp[gd] = cmp_disp;
            assign ras_slide[gd]   = f_valid(rdata, gd);
            assign b_oldtag[32*gd +: 32] = b_fwd ? f_tag(rdata, gd)
                                                 : (b_2l ? f_tagB(rdata, gd)
                                                         : f_tag(rdata, gd));
            // FORWARD accept: the ordered compare picks the nearest candidate strictly
            // below the boundary; on top of that PT needs the ceiling test (beats Zceil
            // via ras_pass_op with the ob mux) and the lane not already resolved. Those
            // two gates apply to `more` as well - a ceiling-occluded or resolved lane is
            // never a future candidate, so the sort$ skip set GROWS as pixels resolve.
            wire fwd_live = ras_pass_op[gd] && !b_res[gd];
            assign ras_pass_fwd[gd] = fwd_live && cmp_pass;
            assign ras_more_fwd[gd] = fwd_live && cmp_more;

            // ---- zb3 accumulate (consumed only when b_peeling - see the write mux).
            // `more` IS the "still needs drawing" predicate, and the candidate's
            // depth is the evicted resident on an accept, else the deferred fragment
            // itself - the same old/new mux the sort cache's demote tag already uses.
            wire        lp_cand   = b_inside[gd] & ras_more_lp[gd];
            wire [30:0] lp_cand_d = ras_disp_lp[gd] ? (b_2l ? f_zbB(rdata, gd)
                                                            : f_depth(rdata, gd))
                                                    : b_invw[31*gd +: 31];
            wire [30:0] zb3_old   = f_z3(rdata, gd);
            assign zb3_nxt[31*gd +: 31] =
                (lp_cand && (lp_cand_d < zb3_old)) ? lp_cand_d : zb3_old;
            // ---- z3b pair accumulate: classic two-register min tracking. A new
            // minimum DEMOTES the old one to the pair slot (up24(old min) <= any
            // stored pair value, so the demote is unconditional); otherwise the
            // candidate competes for the pair slot in the rounded domain. Every
            // event carries exactly ONE owed candidate (a defer is the fragment,
            // an accept's `more` is the single displaced-out resident), so one
            // tracker per lane is complete.
            wire [23:0] z3b_old = f_z3b(rdata, gd);
            wire [23:0] cand24  = up24(lp_cand_d);
            assign z3b_nxt[24*gd +: 24] =
                  !lp_cand                ? z3b_old
                : (lp_cand_d < zb3_old)   ? ((zb3_old == FLT_MAX) ? Z3B_MAX
                                                                  : up24(zb3_old))
                : (cand24 < z3b_old)      ? cand24
                                          : z3b_old;
        end
    endgenerate

    // per-chunk zb3 reduction for the caller's per-tile max, off the SAME registered
    // read the PeelBuffers walk already performs (no extra port, no extra pass).
    reg [30:0] zb3_mx; reg zb3_anyv; integer mz;
    reg [23:0] z3b_mx; reg [23:0] z3b_lb;
    always @(*) begin
        zb3_mx = 31'd0; zb3_anyv = 1'b0; z3b_mx = 24'd0; z3b_lb = 24'd0;
        for (mz = 0; mz < NB; mz = mz + 1)
            if (f_z3(rdata, mz) != FLT_MAX) begin
                zb3_anyv = 1'b1;
                if (f_z3(rdata, mz) > zb3_mx) zb3_mx = f_z3(rdata, mz);
                // per-lane two-layer bound: the pair when it exists, else the A
                // bound (single-owed lane: any fragment in front of A is its
                // next-B - see the pb_z3b_max port header)
                z3b_lb = (f_z3b(rdata, mz) != Z3B_MAX) ? f_z3b(rdata, mz)
                                                       : up24(f_z3(rdata, mz));
                if (z3b_lb > z3b_mx) z3b_mx = z3b_lb;
            end
    end
    assign pb_zb3_max = zb3_mx;
    assign pb_zb3_any = zb3_anyv;
    assign pb_z3b_max = z3b_mx;

    // slot-B image export for the materialize write (see the port comment)
    genvar gb;
    generate for (gb = 0; gb < NB; gb = gb + 1) begin : bexp
        assign pb_bt_valid[gb]          = f_validB(rdata, gb);
        assign pb_bt_tag [32*gb +: 32]  = f_tagB  (rdata, gb);
        assign pb_bt_invw[31*gb +: 31]  = f_zbB   (rdata, gb);
        assign pb_bt_pt  [gb]           = f_isptB (rdata, gb);
    end endgenerate
    assign pb_bt_any = |pb_bt_valid;
    // peel accept / more are only meaningful on peel/forward lanes that are inside
    assign b_pass_lp = (b_peeling ? ras_pass_lp : b_fwd ? ras_pass_fwd : '0) & b_inside;
    assign b_pass_b  = (b_peeling ? ras_pass_b : '0) & b_inside;
    // B staged: direct insert, or the slide of a STAGED A on an A-accept
    assign b_bstg    = (b_peeling ? (ras_pass_b | (ras_pass_lp & ras_slide)) : '0)
                     & b_inside;
    assign b_more    = (b_peeling ? ras_more_lp : b_fwd ? ras_more_fwd : '0) & b_inside;
    // displaced-out (demote b_oldtag): peel = the 2-slot compare's disp; PT fwd =
    // an accept that displaced a staged fragment (pass && valid, the old rule)
    assign b_disp    = (b_peeling ? ras_disp_lp
                       : b_fwd    ? (ras_pass_fwd & {NB{1'b1}}) : '0) & b_inside;
    // per-lane stage-B write-enable = inside & (peel | forward | opaque accept).
    // Exposed so u_taginvw can duplicate the accepted {valid,tag,invW} write with an
    // identical mask - it must see exactly the shaded fragments, so this stays
    // ACCEPT-ONLY even though the internal write set below is wider on peel lanes
    // (a DEFERRED lane also writes, to move zb3; its other fields are kept).
    assign b_we = ras_b_valid ? (b_inside &
                  (b_peeling ? ras_pass_lp : b_fwd ? ras_pass_fwd : ras_pass_op)) : '0;
    // the internal stage-B write set: accepts, PLUS (peel only) deferred lanes. A
    // deferred lane costs no extra RAM traffic - the port is idle on the cycles it
    // would use anyway.
    wire [NB-1:0] ras_we = b_inside &
                  (b_peeling ? (ras_pass_lp | ras_pass_b | ras_more_lp)
                             : b_fwd ? ras_pass_fwd : ras_pass_op);

    // -------------------- READ port mux --------------------
    always @(*) begin
        raddr = '0;
        if (ras_a_valid)      raddr = pack_addr(ras_a_y, ras_a_x);
        else if (sh_rd_valid) raddr = {NB{ sh_rd_id[9:BANK_BITS] }};
        else if (pb_rd_valid) raddr = {NB{pb_rd_addr}};
    end

    // -------------------- WRITE port mux --------------------
    // ONE per-bank transform with PER-FIELD selects, not five full-width datapaths
    // behind a priority mux. At NB=32 that mux was PEEL_W*NB = 4800 bits wide with
    // five inputs, and it was the largest single item in this module - while most of
    // its width is fields that most sources simply KEEP. Written per field, each one
    // sees only its own distinct candidates: `tag` has three (clear / stage-B / kept)
    // rather than five, `zceil` three, `valid` three. Same idea the PT walks already
    // used ("folding them into a single case keeps the write mux at ONE input instead
    // of three"), applied across all of them.
    //
    // The source priority is unchanged and load-bearing: CLEAR > PT walk > z_keep >
    // PeelBuffers > stage-B. Where a source wrote a don't-care ZERO before (CLEAR
    // into depth2/refsort/zceil, which PeelBuffers sets before any read), it still
    // writes zero - this is a restructure, not a semantic change, and the 42-scene
    // sweep is expected to come back bit-identical.
    wire w_clr = clr_valid;
    wire w_pt  = !w_clr && pb_wr_valid &&  pb_ptwalk;
    wire w_bf  = !w_clr && pb_wr_valid && !pb_ptwalk &&  pb_bfin;
    wire w_zk  = !w_clr && pb_wr_valid && !pb_ptwalk && !pb_bfin &&  pb_zkeep;
    wire w_pb  = !w_clr && pb_wr_valid && !pb_ptwalk && !pb_bfin && !pb_zkeep;
    wire w_ras = !w_clr && !pb_wr_valid && ras_b_valid;

    integer cw;
    always @(*) begin : wmux
        reg [30:0] f_zb, f_zb2, f_zc, f_zB;
        reg [31:0] f_tg, f_tB;
        reg [23:0] f_rs;
        reg        f_vl, f_vB, f_iA, f_iB;

        we    = w_ras ? ras_we
              : ((w_clr || w_pt || w_zk || w_pb || w_bf) ? {NB{1'b1}} : '0);
        waddr = w_clr               ? {NB{clr_addr}}
              : (w_pt || w_zk || w_pb || w_bf) ? {NB{pb_wr_addr}}
              : w_ras               ? pack_addr(b_y, b_x)
                                    : '0;
        wdata = '0;

        for (cw = 0; cw < NB; cw = cw + 1) begin
            // the resident fields, read once per bank
            f_zb  = f_depth  (rdata, cw);
            f_zb2 = f_depth2 (rdata, cw);
            f_tg  = f_tag    (rdata, cw);
            f_rs  = f_refsort(rdata, cw);
            f_zc  = f_zceil  (rdata, cw);
            f_vl  = f_valid  (rdata, cw);
            f_zB  = f_zbB    (rdata, cw);
            f_tB  = f_tagB   (rdata, cw);
            f_vB  = f_validB (rdata, cw);
            f_iA  = f_isptA  (rdata, cw);
            f_iB  = f_isptB  (rdata, cw);

            // zb: the working depth. PT fix restores Zfinal (the blend's resolved
            // depth where the pixel locked, else the opaque Z parked in zceil);
            // init/swap seed 0; PeelBuffers seeds the FLT_MAX sentinel; z_keep undoes
            // a sentinel left by a prior peel so a z_keep=1 OP tests against the real
            // last-drawn depth.
            wdata[PEEL_W*cw + PW_DEPTH +: 31] =
                  w_clr ? clr_depth
                : w_pt  ? (pb_ptfix ? (pb_res[cw] ? pb_zres[31*cw +: 31] : f_zc)
                                    : 31'h0)
                : w_bf  ? (f_vB ? f_zB : f_zb)   // fold B into "last drawn" (z_keep)
                : w_zk  ? ((f_zb == FLT_MAX) ? f_zb2 : f_zb)
                : w_pb  ? FLT_MAX
                : w_ras ? (b_peeling ? (ras_pass_lp[cw] ? b_invw[31*cw +: 31] : f_zb)
                         : b_fwd     ? b_invw[31*cw +: 31]
                                     : (b_zwdis ? f_zb : b_invw[31*cw +: 31]))
                        : 31'h0;

            // zb2: the TR reference / PT boundary. PeelBuffers advances it to the old
            // zb EXCEPT when that is the FLT_MAX sentinel (this pixel peeled nothing
            // last pass), which would otherwise discard the only surviving copy of the
            // opaque Z for a z_keep entry with an empty opaque list. PT swap advances
            // only where the pass staged (zb != 0), which also parks a resolved lane's
            // depth here forever.
            wdata[PEEL_W*cw + PW_DEPTH2 +: 31] =
                  w_clr ? 31'h0
                : w_pt  ? (pb_ptinit ? FLT_MAX
                         : pb_ptswap ? ((f_zb == 31'h0) ? f_zb2 : f_zb)
                                     : f_zb2)
                // TWO-LAYER advance: the NEAREST fragment drawn this pass is slot
                // B when it staged, else slot A, else keep (the sentinel rule).
                // !pb_first: the FIRST walk of a peel may read slot-B RESIDUE of a
                // PREVIOUS entry's final pass (the read-only BFIN materialize leaves
                // it staged for z_keep's sake) - the seed must come from zb (the OP
                // depth), never from residue.
                : w_pb  ? ((f_vB && !pb_first) ? f_zB
                                               : ((f_zb == FLT_MAX) ? f_zb2 : f_zb))
                        : f_zb2;                      // z_keep and stage-B keep it

            wdata[PEEL_W*cw + PW_TAG +: 32] =
                  w_clr ? clr_tag
                : w_ras ? ((b_peeling && !ras_pass_lp[cw]) ? f_tg   // deferred: keep
                                                           : b_tag)
                // the resting tag is zb2's COMPANION (the sentinel path re-derives
                // refsort from it): when B advanced the reference, B's tag rests
                : w_pb  ? ((f_vB && !pb_first) ? f_tB : f_tg)
                        : f_tg;                       // every other walk keeps it

            // the reference SORT field moves with zb2 above, by the SAME condition, so
            // the boundary KEY advances as one - that is what steps a coplanar group
            // one fragment at a time.
            wdata[PEEL_W*cw + PW_REFSORT +: 24] =
                  w_clr ? 24'h0
                : w_pt  ? (pb_ptinit ? REFSORT_PT_INIT
                         : pb_ptswap ? ((f_zb == 31'h0) ? f_rs : f_tagsort(rdata, cw))
                                     : f_rs)
                : w_pb  ? (pb_first ? REFSORT_TR_FIRST
                                    : (f_vB ? f_tB[23:0] : f_tagsort(rdata, cw)))
                                    // (pb_first wins, so B residue cannot leak here)
                        : f_rs;                       // z_keep and stage-B keep it

            // ONE slot, two phase-owned meanings (see the zb3 header):
            //   ceiling: parked by ptinit, kept by ptswap/ptfix/z_keep/fwd/opaque.
            //   zb3    : reseeded FLT_MAX by every TL PeelBuffers walk (the caller
            //            samples the OLD value off this same read, so the walk is
            //            exactly the pass boundary), accumulated by peel stage-B.
            wdata[PEEL_W*cw + PW_ZCEIL +: 31] =
                  w_clr ? 31'h0
                : (w_pt && pb_ptinit)    ? f_zb       // park the opaque Z for the PT phase
                : w_pb                   ? FLT_MAX    // zb3 <- "nothing owed" for the pass
                : (w_ras && b_peeling)   ? zb3_nxt[31*cw +: 31]
                                         : f_zc;

            wdata[PEEL_W*cw + PW_VALID] =
                  (w_zk || w_bf) ? f_vl
                : w_ras ? (b_peeling ? (ras_pass_lp[cw] ? 1'b1 : f_vl)  // deferred: keep
                         : b_fwd ? 1'b1 : f_vl)
                        : 1'b0;                       // clear / PT walk / PeelBuffers

            // ---- TWO-LAYER slot B + the ispt companions ----
            // stage-B peel: an A-accept SLIDES old A into B (depth/tag/valid/ispt
            // move as one); a B-accept writes the fragment into B; everything else
            // keeps. Walks: PeelBuffers consumed B into the reference above ->
            // reset; PT walks/CLEAR zero it; z_keep keeps (dead fields there).
            wdata[PEEL_W*cw + PW_DEPTHB +: 31] =
                  (w_zk || w_bf)         ? f_zB
                : (w_ras && b_peeling)   ? (ras_pass_lp[cw] ? f_zb
                                          : ras_pass_b[cw]  ? b_invw[31*cw +: 31]
                                                            : f_zB)
                : (w_ras)                ? f_zB
                                         : 31'h0;
            wdata[PEEL_W*cw + PW_TAGB +: 32] =
                  (w_zk || w_bf)         ? f_tB
                : (w_ras && b_peeling)   ? (ras_pass_lp[cw] ? f_tg
                                          : ras_pass_b[cw]  ? b_tag
                                                            : f_tB)
                : (w_ras)                ? f_tB
                                         : 32'h0;
            wdata[PEEL_W*cw + PW_VALIDB] =
                  (w_zk || w_bf)         ? f_vB
                : (w_ras && b_peeling)   ? (ras_pass_lp[cw] ? (b_2l && f_vl)
                                          : ras_pass_b[cw]  ? 1'b1
                                                            : f_vB)
                : (w_ras)                ? f_vB
                                         : 1'b0;
            wdata[PEEL_W*cw + PW_ISPTA] =
                  (w_zk || w_bf)         ? f_iA
                : (w_ras && b_peeling)   ? (ras_pass_lp[cw] ? b_ispt : f_iA)
                : (w_ras)                ? f_iA
                                         : 1'b0;
            wdata[PEEL_W*cw + PW_ISPTB] =
                  (w_zk || w_bf)         ? f_iB
                : (w_ras && b_peeling)   ? (ras_pass_lp[cw] ? f_iA
                                          : ras_pass_b[cw]  ? b_ispt
                                                            : f_iB)
                : (w_ras)                ? f_iB
                                         : 1'b0;

            // z3b: zb3's pair - same lifecycle: reseeded to the sentinel by every
            // TL PeelBuffers walk (and CLEAR, for hygiene), accumulated by peel
            // stage-B, dead (kept) everywhere else. Residue before the first walk
            // is discarded by the caller's first_peel gate, like zb3's.
            wdata[PEEL_W*cw + PW_Z3B +: 24] =
                  (w_clr || w_pb)        ? Z3B_MAX
                : (w_ras && b_peeling)   ? z3b_nxt[24*cw +: 24]
                                         : f_z3b(rdata, cw);
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

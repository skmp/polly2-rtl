//
// isp_depth_cmp_lp - RM_TRANSLUCENT_AUTOSORT ("layer peeling") depth/tag
// compare, one lane, combinational.
//
// invW is 1/w: LARGER = CLOSER. The peel walks FAR -> NEAR, one layer per pass,
// so each pass keeps the FARTHEST fragment still strictly after the reference.
//
// Two depth buffers per pixel: `zb` (current pass, depthBufferA - the farthest
// not-yet-drawn fragment found so far this pass) and `zb2` (the reference depth
// from the previous peel pass, depthBufferB). Two tag buffers: `pb` (this pass's
// pending tag) and `pb2` (last-rendered tag). A per-pixel `valid` bit
// (tagStatus.valid) marks that this pass already staged a fragment.
//
// ---------------------------------------------------------------------------
// COMPOSITE SORT KEY (replaces refsw2's separate depth compare + coincident-tag
// tie-break). refsw2's rule at the reference plane was
//     if (invW == *zb2 && tag >= tagRendered) reject;
// which lets only SMALLER tags through after tagRendered has been drawn - so a
// stack of coplanar translucent polys peels in DECREASING tag order, i.e. the
// LAST-submitted one is blended FIRST. That is reverse submission order and it
// is wrong: for coincident fragments the PVR draws in submission order, earliest
// behind. refsw2 is not a valid reference here.
//
// The fix: fold the tag into the depth to form a key that is unique per fragment,
// so no two fragments are ever "coplanar" as far as the compare is concerned:
//
//     key = { depth[30:0], tag[23:0] }
//
//   * depth is the primary field - unchanged ordering for non-coincident frags.
//   * tag[23:0] (PARAMETER_TAG_SORT_MASK) is param_offs_in_words:tag_offset, which
//     increases with submission order, so at equal depth the SMALLER tag is the
//     FARTHER (drawn first) fragment - back-to-front, matching submission order.
//
// No explicit "is pb2 valid" test is needed: the invalid sentinel 0x8000_0000 has
// tag[23:0]==0, so it sorts at or below every real fragment at the same depth and
// the reference test lets them all through. This is why the pb2 sentinel MUST be
// 0x8000_0000 and not 0xFFFF_FFFF - the old max-tag sentinel sorts ABOVE every real
// fragment and would reject every coincident fragment on pass 1. See pb_first in
// peel_tile_buffer.
//
// KNOWN HOLE (deliberate, measured): a REAL fragment whose tag[23:0] is 0 - the
// record at param offset 0, first triangle - ties exactly with the sentinel, so if
// it is also exactly coincident with the pass-1 reference depth (the opaque surface)
// it is rejected and never drawn. Records at param offset 0 are NOT rare (9 of the 51
// polly2-data dumps have them; psy2_boot 156, shenmue_menu 51, sw_ep1_menu 18), but
// the additional exact-coincidence-with-opaque condition does not occur in any of the
// 42 golden scenes - verified by rendering all of them with and without a tie-break
// bit appended to the key. If a scene ever shows a dropped overlay, append ~tag[31]
// as the key LSB (one bit, sentinel then sorts strictly below every real fragment)
// and the hole closes; depth_cmp_lp_tb pins the current behaviour either way.
//
// The three-way rule collapses to two comparisons on the key:
//
//     k_new >  k_best  -> nearer than this pass's best; defer to a later pass (more)
//     k_new <= k_ref   -> at or before the reference; already drawn -> reject
//     otherwise        -> accept (new farthest-remaining); displacing a staged
//                         fragment costs another pass (more)
//
// k_new == k_ref is exactly the fragment the previous pass rendered, so the ref
// test must be <= (a strict < would re-accept it forever).
//
// Outputs:
//   pass  - write this fragment (caller sets zb<-nw, pb<-new_tag, valid<-1)
//   more  - MoreToDraw: another peel pass is needed after this one
//
// Depths are 31-bit SIGN-STRIPPED floats (always positive non-zero, sign bit
// not stored): positive floats order like unsigned integers, so the depth
// compares are plain unsigned operators, and so is the concatenated key.
//
module isp_depth_cmp_lp (
    input      [30:0] nw,       // new depth (invW, sign-stripped) for this fragment
    input      [31:0] tag,      // new fragment's CoreTag
    input      [30:0] zb,       // depthBufferA (this pass, farthest-remaining so far)
    input      [30:0] zb2,      // depthBufferB (reference from prior pass)
    input      [31:0] pb,       // tagBufferA   (this pass, pending tag)
    input      [31:0] pb2,      // tagBufferB   (last-rendered tag)
    input             valid,    // tagStatus.valid (staged this pass)
    output reg        pass,     // write fragment (zb<-nw, pb<-tag, valid<-1)
    output reg        more,     // MoreToDraw feedback
    // raw comparator taps for the FORWARD (punch-through resolve) compare in
    // peel_tile_buffer: with the PT plane mapping zb=working-best, zb2=forward
    // boundary, these are exactly `nearer than best` and `behind boundary` - the
    // forward accept reuses them instead of instantiating new comparators.
    // DEPTH ONLY (no tag): the PT phase parks Zceil in tag2, so pb2 is not a tag
    // there, and the PT window test is a pure depth window.
    output            o_nw_gt_zb,   // nw >  zb
    output            o_nw_lt_zb2   // nw <  zb2
);
    localparam int KW = 31 + 24;        // {depth, tag[23:0]}

    wire [KW-1:0] k_new  = { nw,  tag[23:0] };
    wire [KW-1:0] k_best = { zb,  pb [23:0] };
    wire [KW-1:0] k_ref  = { zb2, pb2[23:0] };

    wire k_gt_best = (k_new >  k_best);
    wire k_le_ref  = (k_new <= k_ref);

    // pure-depth taps for the PT forward resolve (unchanged)
    assign o_nw_gt_zb  = (nw >  zb);
    assign o_nw_lt_zb2 = (nw <  zb2);

    always @* begin
        pass = 1'b0;
        more = 1'b0;

        if (k_gt_best) begin
            // nearer than this pass's best -> defer to a later pass.
            more = 1'b1;
        end else if (k_le_ref) begin
            // at or before the reference key -> already drawn -> reject.
        end else begin
            // accept: new farthest-remaining fragment for this pass. If one was
            // already staged it is displaced and must be re-drawn later.
            pass = 1'b1;
            if (valid)
                more = 1'b1;
        end
    end
endmodule

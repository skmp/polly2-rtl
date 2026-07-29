//
// isp_depth_cmp_lp - refsw2 RM_TRANSLUCENT_AUTOSORT ("layer peeling") depth/tag
// compare, one lane, combinational.
//
// Mirrors PixelFlush_isp<RM_TRANSLUCENT_AUTOSORT> in
// ../devcast/libswirl/rend/refsw2/refsw_tile.cpp. invW is 1/w: LARGER = CLOSER.
//
// Two depth buffers per pixel: `zb` (current pass, depthBufferA - the closest
// fragment found so far this pass, in front of the reference) and `zb2` (the
// reference depth from the previous peel pass, depthBufferB). Two tag buffers:
// `pb` (this pass's pending tag) and `pb2` (last-rendered tag). A per-pixel
// `valid` bit (tagStatus.valid) marks that this pass already staged a fragment.
//
// Sort order between coincident (== depth) fragments uses the low 24 bits of the
// tag (PARAMETER_TAG_SORT_MASK = 0x00FFFFFF); "earlier or same" => keep the one
// already peeled.
//
// Outputs:
//   pass  - write this fragment (caller sets zb<-nw, pb<-new_tag, valid<-1)
//   more  - MoreToDraw: another peel pass is needed after this one
//
// refsw reference:
//   if (invW <  *zb2) reject;                                   // behind ref plane
//   if (invW == *zb2 && sort(tag)<=sort(*pb2) && *pb2!=~0) reject;
//   if (invW == *zb) {
//       if (sort(tag)<=sort(*pb2) && *pb2!=~0) reject;
//       if (valid) {
//           if (sort(tag) > sort(*pb)) { more=1; reject; }      // later than pending
//           // else replace (earlier)
//       }
//   }
//   // accept:
//   if (valid) more=1;                                          // displaced a staged frag
//   // caller: *zb=invW; valid=1; *pb=tag;
//
module isp_depth_cmp_lp (
    input      [31:0] nw,       // new depth (invW) for this fragment
    input      [31:0] tag,      // new fragment's CoreTag
    input      [31:0] zb,       // depthBufferA (this pass, closest-so-far)
    input      [31:0] zb2,      // depthBufferB (reference from prior pass)
    input      [31:0] pb,       // tagBufferA   (this pass, pending tag)
    input      [31:0] pb2,      // tagBufferB   (last-rendered tag)
    input             valid,    // tagStatus.valid (staged this pass)
    output reg        pass,     // write fragment (zb<-nw, pb<-tag, valid<-1)
    output reg        more,     // MoreToDraw feedback
    // raw comparator taps for the FORWARD (punch-through resolve) compare in
    // peel_tile_buffer: with the PT plane mapping zb=working-best, zb2=forward
    // boundary, these are exactly `nearer than best` and `behind boundary` - the
    // forward accept reuses them instead of instantiating new comparators.
    output            o_nw_gt_zb,   // nw >  zb
    output            o_nw_lt_zb2   // nw <  zb2
);
    // signed-float greater-than a > b (no NaN/inf; DaZ handled by ==0 test),
    // identical to isp_depth_cmp.
    function fgt(input [31:0] a, input [31:0] b);
        reg az,bz; reg [30:0] am,bm;
        begin
            az=(a[30:0]==0); bz=(b[30:0]==0);
            am=a[30:0]; bm=b[30:0];
            if (az&&bz)           fgt=1'b0;
            else if (a[31]^b[31]) fgt = b[31];      // a>b if b negative
            else if (~a[31])      fgt = (am>bm);     // both >=0
            else                  fgt = (am<bm);     // both <0
        end
    endfunction

    // float equal (DaZ: +/-0 compare equal)
    function feq(input [31:0] a, input [31:0] b);
        begin
            feq = (a[30:0]==31'd0 && b[30:0]==31'd0) ? 1'b1 : (a==b);
        end
    endfunction

    localparam [23:0] SORT_MASK_HI = 24'hFFFFFF; // documents PARAMETER_TAG_SORT_MASK
    // sort key = low 24 bits of the tag. `pb` (this pass's pending tag) is unused: refsw2's
    // RM_TRANSLUCENT tie-break only compares against pb2 (the last-rendered tag at the ref
    // plane); the invW==zb pending-tag stage a prior rework added is not in refsw2.
    wire [23:0] s_new = tag[23:0];
    wire [23:0] s_pb2 = pb2[23:0];

    wire nw_gt_zb  = fgt(nw, zb);           // invW >  zb   (mode-3 LESS_EQUAL pre-test)
    wire nw_lt_zb2 = fgt(zb2, nw);          // invW <  zb2
    wire nw_eq_zb2 = feq(nw, zb2);          // invW == zb2
    wire pb2_valid = (pb2 != 32'hFFFFFFFF); // last-rendered tag is real
    assign o_nw_gt_zb  = nw_gt_zb;
    assign o_nw_lt_zb2 = nw_lt_zb2;

    always @* begin
        pass = 1'b0;
        more = 1'b0;

        // refsw PixelFlush_isp forces mode=3 (LESS_EQUAL) for AUTOSORT and runs it
        // BEFORE the AUTOSORT case: reject any fragment NEARER than the current best
        // (invW > zb). This is what makes each pass keep the FARTHEST fragment >= the
        // reference plane (peel far->near, blend back-to-front). Without it the pass
        // climbs to the nearest fragment and farther layers are lost.
        // EXACT mirror of refsw2 PixelFlush_isp<RM_TRANSLUCENT> (mode 3), which is:
        //   if (invW >  *zb)  { MoreToDraw = true; return; }          // pretest (defer nearer)
        //   if (invW <  *zb2) return;                                 // (A) behind reference
        //   if (invW == *zb2 && tag >= (*pb2 & ~TAG_INVALID)) return; // (B) coincident, later-tag
        //   *zb = invW;  if (*pb != INVALID) MoreToDraw = true;  *pb = tag;   // accept, last-wins
        // The coincident tie-break is `tag >= tagRendered` (reject the LATER-or-equal tag at the
        // reference plane), which drives the coplanar sort order. A prior rework of this block
        // (inverted `<=` + an extra invW==zb tag-ordering stage) reversed that order and broke
        // coplanar sorting (shenmue_menu). There is no separate invW==zb tag check in refsw2:
        // an invW==zb fragment simply accepts (last-wins) and sets MoreToDraw on displacement.
        if (nw_gt_zb) begin
            // invW > zb: nearer than this pass's best -> defer to a later pass.
            more = 1'b1;
        end else if (nw_lt_zb2) begin
            // (A) invW < zb2: behind the reference plane -> reject.
        end else if (nw_eq_zb2 && pb2_valid && (s_new >= s_pb2)) begin
            // (B) coincident with the ref-plane fragment already rendered, and this one sorts
            // LATER-or-equal (tag >= tagRendered) -> already handled -> reject.
        end else begin
            // accept (last-wins). If a fragment was already staged this pass, it is displaced
            // and must be re-drawn in a later pass (refsw: *pb != INVALID -> MoreToDraw).
            pass = 1'b1;
            if (valid)
                more = 1'b1;
        end
    end
endmodule

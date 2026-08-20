//
// isp_depth_cmp_lp - depth/tag compare for BOTH ordered resolves, one lane,
// combinational:
//   pt = 0  RM_TRANSLUCENT_AUTOSORT layer peeling  - walk FAR -> NEAR
//   pt = 1  punch-through forward resolve          - walk NEAR -> FAR
//
// invW is 1/w: LARGER = CLOSER.
//
// ---------------------------------------------------------------------------
// COMPOSITE SORT KEY
//
//     key = { depth[30:0], tag[23:0] }
//
//   * depth is the primary field.
//   * tag[23:0] (PARAMETER_TAG_SORT_MASK) is param_offs_in_words:tag_offset, which
//     increases with submission order.
//
// The key is UNIQUE per fragment, so no two fragments are ever "coplanar" as far as
// the compare is concerned. Both resolves are then just an ordered walk of that key,
// in opposite directions, and BOTH use the same two comparisons:
//
//   TR (pt=0), ascending - each pass keeps the SMALLEST key strictly above the
//   reference, so layers come out far->near and, at equal depth, in submission order
//   (earliest tag behind). refsw2's rule here was `invW == zb2 && tag >= tagRendered
//   -> reject`, which peels a coplanar stack in DECREASING tag order - reverse
//   submission, and wrong. refsw2 is not a valid reference for this.
//
//   PT (pt=1), descending - each pass keeps the LARGEST key strictly below the
//   boundary, i.e. the nearest not-yet-tried candidate. The shade then alpha-tests
//   it; if it fails, the boundary advances past it and the next pass takes the next
//   one. With a DEPTH-ONLY boundary (the previous design) a coplanar group was
//   skipped wholesale once the boundary landed on that depth - a failed alpha test
//   on the first of them punched a hole through the whole plane. Carrying the tag in
//   the boundary steps within the plane instead.
//
// Both walks terminate: the key is unique and the reference/boundary moves strictly
// in one direction each pass.
//
//   pt=0:  k_new >  k_best  -> nearer than this pass's best; defer      (more)
//          k_new <= k_ref   -> at or before the reference; already drawn -> reject
//          otherwise        -> accept; displacing a staged fragment costs a pass
//
//   pt=1:  k_new >= k_ref   -> at or nearer than the boundary; already tried -> reject
//          k_new <  k_best  -> farther than this pass's best; defer      (more)
//          otherwise        -> accept; displacing a staged fragment costs a pass
//
// The reference tests are non-strict on the equal side in both directions: k_new ==
// k_ref is exactly the fragment the previous pass handled, and re-accepting it would
// not terminate.
//
// SEEDS (peel_tile_buffer): the "best" plane starts at the extreme the walk moves
// away from - FLT_MAX for TR, 0 for PT - so the first candidate always wins; the
// reference starts at the opposite extreme.
//
// The pb2 sort field is 24 bits, NOT a full tag: it is the only part of the reference
// the compare needs, and during the PT phase the tag2 slot is busy parking Zceil, so
// the boundary sort lives in its own field (PW_REFSORT).
//
// KNOWN HOLE (deliberate, measured): a REAL fragment whose tag[23:0] is 0 - the
// record at param offset 0, first triangle - ties exactly with the TR "nothing
// rendered yet" sentinel, whose sort field is also 0. If such a fragment is also
// exactly coincident with the pass-1 reference depth (the opaque surface) it is
// rejected and never drawn. Records at param offset 0 are NOT rare (9 of the 51
// polly2-data dumps have them; psy2_boot 156, shenmue_menu 51, sw_ep1_menu 18), but
// the additional exact-coincidence condition does not occur in any of the 42 golden
// scenes - verified by rendering all of them with and without a tie-break bit
// appended to the key. If a scene ever shows a dropped overlay, append ~tag[31] as
// the key LSB (the sentinel then sorts strictly below every real fragment) and the
// hole closes; depth_cmp_lp_tb pins the current behaviour either way.
//
// Depths are 31-bit SIGN-STRIPPED floats (always positive non-zero, sign bit not
// stored): positive floats order like unsigned integers, so the depth compares are
// plain unsigned operators, and so is the concatenated key.
//
// ---------------------------------------------------------------------------
// TWO-LAYER PEELING (pt=0 only). The TR working set is now a 2-element sorted
// insertion list: slot A = this pass's FARTHEST owed fragment (the old zb/pb,
// shaded first), slot B = the NEXT one (shaded second, still back-to-front).
// One pass thereby consumes TWO depth layers. The walk direction and the
// reference test are unchanged; only the "best" side grew a slot:
//
//   k_new <= k_ref            -> reject (already drawn)
//   k_new <  kA               -> pass   (A' = new, old A slides to B; a staged
//                                        old B is DISPLACED OUT -> more)
//   kA <= k_new < kB          -> pass_b (B' = new; a staged old B is DISPLACED
//                                        OUT -> more)
//   k_new >= kB               -> defer  (more)
//
// kB is +inf while !validB (nothing staged in B yet), so the first two
// candidates of a pass land in order without stored seeds. validB implies
// validA (B only fills via a valid A), which the caller may assert.
//
// disp marks a DISPLACED-OUT more (the lost fragment is the OLD B - its tag is
// the caller's demote target) as opposed to a deferred one (the demote target
// is the incoming fragment). A fragment sliding A->B is NOT lost and produces
// neither more nor a demote.
//
// PT (pt=1) is untouched: single working slot, exactly the old behaviour; the
// B inputs are ignored and pass_b/disp never assert (disp's role is played by
// the old pass&&valid convention, which the caller folds in).
// ---------------------------------------------------------------------------
module isp_depth_cmp_lp (
    input             en2,       // 1 = two-layer TR (slot B active); 0 = the exact
                                 // single-slot behaviour (+onelayer bisect switch)
    input             pt,        // 0 = TR layer peel (ascending), 1 = PT resolve (descending)
    input      [30:0] nw,        // new depth (invW, sign-stripped) for this fragment
    input      [31:0] tag,       // new fragment's CoreTag
    input      [30:0] zb,        // depthBufferA - slot A depth (TR) / working best (PT)
    input      [31:0] pb,        // tagBufferA   - slot A tag
    input      [30:0] zb2,       // depthBufferB - reference (TR) / boundary (PT) depth
    input      [23:0] pb2_sort,  // PW_REFSORT   - reference / boundary tag sort field
    input             valid,     // tagStatus.valid (slot A staged this pass)
    input      [30:0] zbB,       // TR slot B depth
    input      [23:0] pbB_sort,  // TR slot B tag sort field (tagB[23:0])
    input             validB,    // TR slot B staged this pass
    output reg        pass,      // A-accept: zb<-nw, pb<-tag, valid<-1 (B <- old A)
    output reg        pass_b,    // TR B-accept: zbB<-nw, tagB<-tag, validB<-1
    output reg        disp,      // TR: this `more` displaced OLD B out (demote tagB)
    output reg        more       // MoreToDraw feedback
);
    localparam int KW = 31 + 24;        // {depth, tag[23:0]}

    wire [KW-1:0] k_new  = { nw,  tag[23:0] };
    wire [KW-1:0] k_best = { zb,  pb [23:0] };
    wire [KW-1:0] k_ref  = { zb2, pb2_sort  };
    wire [KW-1:0] k_b    = { zbB, pbB_sort  };

    // gt_best is shared between the modes (it means "not the new A" walking up,
    // "accept" walking down); the reference test just changes which side is stale.
    wire gt_best = (k_new >  k_best);
    // TR: at/behind slot B -> defer. An EMPTY B counts as +inf, so the first
    // candidate above A always lands in B. TIMING: the empty case overrides the
    // 1-bit VERDICT after the compare instead of muxing all KW bits of k_b in
    // front of the carry chain (this compare sits in the peel RMW loop, the
    // binding path family). Equivalent to `k_new >= all-ones` because k_new can
    // never BE all-ones: nw is a sign-stripped finite invW <= 31'h7F7FFFFF.
    wire gt_b    = validB && (k_new >= k_b);
    wire gt_ref  = (k_new >  k_ref);    // pt=0: !gt_ref  == (k_new <= k_ref)
    wire lt_ref  = (k_new <  k_ref);    // pt=1: !lt_ref  == (k_new >= k_ref)

    always @* begin
        pass   = 1'b0;
        pass_b = 1'b0;
        disp   = 1'b0;
        more   = 1'b0;

        if (!pt && !en2) begin
            // ---- single-slot TR (bisect mode): the pre-two-layer behaviour ----
            if (gt_best) begin
                more = 1'b1;                    // nearer than the best -> a later pass
            end else if (!gt_ref) begin
                                                // at/before the reference -> already drawn
            end else begin
                pass = 1'b1;
                if (valid) begin
                    more = 1'b1; disp = 1'b1;   // displaced the staged fragment
                end
            end
        end else if (!pt) begin
            // ---- TR: ascending, keep the TWO smallest keys above the reference ----
            if (!gt_ref) begin
                                                // at/before the reference -> already drawn
            end else if (!gt_best) begin
                pass = 1'b1;                    // new A; old A slides to B
                if (validB) begin
                    more = 1'b1; disp = 1'b1;   // ...displacing the staged old B out
                end
            end else if (!gt_b) begin
                pass_b = 1'b1;                  // lands between A and B
                if (validB) begin
                    more = 1'b1; disp = 1'b1;   // the staged old B is displaced out
                end
            end else begin
                more = 1'b1;                    // behind both slots -> a later pass
            end
        end else begin
            // ---- PT: descending, keep the largest key below the boundary ----
            if (!lt_ref) begin
                                                // at/nearer than the boundary -> tried
            end else if (!gt_best) begin
                more = 1'b1;                    // farther than the best -> a later pass
            end else begin
                pass = 1'b1;
                if (valid) more = 1'b1;         // displaced a staged fragment
            end
        end
    end
endmodule

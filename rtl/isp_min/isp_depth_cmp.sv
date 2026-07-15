//
// isp_depth_cmp - refsw depth compare, one lane, combinational.
//
// Two personalities, selected by `peel`:
//
// peel=0 (opaque): refsw DepthMode compare. pass = "does the new invW pass
// against the stored depth zb" per ISP DepthMode (refsw: 0 never, 1 less,
// 2 equal, 3 less-or-equal, 4 greater, 5 not-equal, 6 greater-or-equal,
// 7 always; "reject" cases inverted to a pass flag). `more` stays 0.
//
// peel=1 (autosort layer peel): refsw2 RM_TRANSLUCENT_AUTOSORT depth/tag
// compare, mirroring PixelFlush_isp<RM_TRANSLUCENT_AUTOSORT> in
// ../devcast/libswirl/rend/refsw2/refsw_tile.cpp. invW is 1/w: LARGER=CLOSER.
//
// Two depth buffers per pixel: `zb` (current pass, depthBufferA - the closest
// fragment found so far this pass, in front of the reference) and `zb2` (the
// reference depth from the previous peel pass, depthBufferB). Two tag buffers:
// `pb` (this pass's pending tag) and `pb2` (last-rendered tag). A per-pixel
// `valid` bit (tagStatus.valid) marks that this pass already staged a fragment.
//
// Sort order between coincident (== depth) fragments uses the low 24 bits of
// the tag (PARAMETER_TAG_SORT_MASK = 0x00FFFFFF); "earlier or same" => keep
// the one already peeled.
//
// refsw peel reference:
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
// Depth values are non-negative finite floats (no NaN/inf/-0; DaZ handled
// upstream), so IEEE bit patterns order monotonically and every depth compare
// is a plain 32-bit unsigned integer compare. The nw-vs-zb comparators are
// shared between both personalities. Instantiate one per rasterizer lane; at
// opaque-only sites tie peel=1'b0 (and the peel-only inputs to '0) and the
// whole peel cone prunes away.
//
module isp_depth_cmp (
    input             peel,   // 0: opaque DepthMode compare, 1: autosort layer peel
    input      [2:0]  mode,   // ISP DepthMode (isp_word[31:29])  [opaque only]
    input      [31:0] nw,     // new depth (invW)
    input      [31:0] tag,    // new fragment's CoreTag           [peel only]
    input      [31:0] zb,     // stored depth / depthBufferA (closest-so-far)
    input      [31:0] zb2,    // depthBufferB (reference, prior pass) [peel only]
    input      [31:0] pb,     // tagBufferA (this pass, pending tag)  [peel only]
    input      [31:0] pb2,    // tagBufferB (last-rendered tag)       [peel only]
    input             valid,  // tagStatus.valid (staged this pass)   [peel only]
    output            pass,   // write fragment (peel: zb<-nw, pb<-tag, valid<-1)
    output            more    // MoreToDraw feedback              [peel only]
);
    // shared nw-vs-zb comparators (both personalities)
    wire eq = (nw == zb);
    wire gt = (nw >  zb);
    wire lt = (nw <  zb);

    // -------------------- opaque DepthMode --------------------
    reg pass_op;
    always @* begin
        case (mode)
            3'd0: pass_op = 1'b0;      // never
            3'd1: pass_op = lt;        // less  (new < old)
            3'd2: pass_op = eq;        // equal
            3'd3: pass_op = lt|eq;     // less-or-equal
            3'd4: pass_op = gt;        // greater
            3'd5: pass_op = ~eq;       // not-equal
            3'd6: pass_op = gt|eq;     // greater-or-equal
            3'd7: pass_op = 1'b1;      // always
        endcase
    end

    // -------------------- autosort layer peel --------------------
    localparam [23:0] SORT_MASK_HI = 24'hFFFFFF; // documents PARAMETER_TAG_SORT_MASK
    // sort key = low 24 bits of the tag
    wire [23:0] s_new = tag[23:0];
    wire [23:0] s_pb  = pb [23:0];
    wire [23:0] s_pb2 = pb2[23:0];

    wire nw_lt_zb2 = (nw <  zb2);           // invW <  zb2
    wire nw_eq_zb2 = (nw == zb2);           // invW == zb2
    wire pb2_valid = (pb2 != 32'hFFFFFFFF); // last-rendered tag is real

    reg pass_lp, more_lp;
    always @* begin
        pass_lp = 1'b0;
        more_lp = 1'b0;

        // refsw PixelFlush_isp forces mode=3 (LESS_EQUAL) for AUTOSORT and runs it
        // BEFORE the AUTOSORT case: reject any fragment NEARER than the current best
        // (invW > zb). This is what makes each pass keep the FARTHEST fragment >= the
        // reference plane (peel far->near, blend back-to-front). Without it the pass
        // climbs to the nearest fragment and farther layers are lost.
        if (gt) begin
            // ZFAIL (mode 3: invW > zb) -> nearer than current best this pass.
            // refsw sets MoreToDraw here for AUTOSORT: this nearer fragment still
            // needs to be drawn in a later pass.
            more_lp = 1'b1;
        end else if (nw_lt_zb2) begin
            // behind the reference plane -> reject (ZFAIL4)
        end else if (nw_eq_zb2 && (s_new <= s_pb2) && pb2_valid) begin
            // coincident with a fragment already peeled at the ref plane, and
            // this one sorts earlier-or-same -> already handled (ZFAIL7)
        end else begin
            // default: accept
            pass_lp = 1'b1;

            if (eq) begin // invW == zb
                if ((s_new <= s_pb2) && pb2_valid) begin
                    // earlier-or-same as last-rendered -> reject (ZFAIL5)
                    pass_lp = 1'b0;
                end else if (valid) begin
                    if (s_new > s_pb) begin
                        // later than the current pending -> defer to a later pass
                        more_lp = 1'b1;   // ZFAIL6
                        pass_lp = 1'b0;
                    end
                    // else: earlier than pending -> replace (fall through, pass=1)
                end
            end

            // if we accept and there was already a staged fragment this pass,
            // that displaced fragment needs another peel pass.
            if (pass_lp && valid)
                more_lp = 1'b1;
        end
    end

    assign pass = peel ? pass_lp : pass_op;
    assign more = peel & more_lp;
endmodule

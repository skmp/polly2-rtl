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
    output reg        more      // MoreToDraw feedback
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
    // sort key = low 24 bits of the tag
    wire [23:0] s_new = tag[23:0];
    wire [23:0] s_pb  = pb [23:0];
    wire [23:0] s_pb2 = pb2[23:0];

    wire nw_gt_zb  = fgt(nw, zb);           // invW >  zb   (mode-3 LESS_EQUAL pre-test)
    wire nw_lt_zb2 = fgt(zb2, nw);          // invW <  zb2
    wire nw_eq_zb2 = feq(nw, zb2);          // invW == zb2
    wire nw_eq_zb  = feq(nw, zb);           // invW == zb
    wire pb2_valid = (pb2 != 32'hFFFFFFFF); // last-rendered tag is real

    always @* begin
        pass = 1'b0;
        more = 1'b0;

        // refsw PixelFlush_isp forces mode=3 (LESS_EQUAL) for AUTOSORT and runs it
        // BEFORE the AUTOSORT case: reject any fragment NEARER than the current best
        // (invW > zb). This is what makes each pass keep the FARTHEST fragment >= the
        // reference plane (peel far->near, blend back-to-front). Without it the pass
        // climbs to the nearest fragment and farther layers are lost.
        if (nw_gt_zb) begin
            // ZFAIL (mode 3: invW > zb) -> nearer than current best this pass.
            // refsw sets MoreToDraw here for AUTOSORT: this nearer fragment still
            // needs to be drawn in a later pass.
            more = 1'b1;
        end else if (nw_lt_zb2) begin
            // behind the reference plane -> reject (ZFAIL4)
        end else if (nw_eq_zb2 && (s_new <= s_pb2) && pb2_valid) begin
            // coincident with a fragment already peeled at the ref plane, and
            // this one sorts earlier-or-same -> already handled (ZFAIL7)
        end else begin
            // default: accept
            pass = 1'b1;

            if (nw_eq_zb) begin
                if ((s_new <= s_pb2) && pb2_valid) begin
                    // earlier-or-same as last-rendered -> reject (ZFAIL5)
                    pass = 1'b0;
                end else if (valid) begin
                    if (s_new > s_pb) begin
                        // later than the current pending -> defer to a later pass
                        more = 1'b1;   // ZFAIL6
                        pass = 1'b0;
                    end
                    // else: earlier than pending -> replace (fall through, pass=1)
                end
            end

            // if we accept and there was already a staged fragment this pass,
            // that displaced fragment needs another peel pass.
            if (pass && valid)
                more = 1'b1;
        end
    end
endmodule

//
// isp_primitive_iterator - consumes ONE object-list entry (triangle STRIP or
// triangle ARRAY) and iterates its triangles, reading position (X,Y,Z) per
// vertex from the parameter buffer. UV/color/offset/tsp/tcw are skipped here
// (address arithmetic only); the plane cache re-decodes the full record later.
//
// Shared record layout (refsw decode_pvr_vertices, refsw_tile.cpp:293): at a
// record base, isp is at +0 (tsp/tcw at +4/+8 present but unread); if
// two_volumes (=shadow) a second tsp1/tcw1 pair follows, so vertices start
// hdr_words later. Vertex k's XYZ are 3 CONTIGUOUS words at
//   hdr_words + k*stride_w   (in 32-bit VIEW words from the record base)
//   hdr_words = 3 (+2 if two_volumes) ; stride_w = 3 + skip*(1+two_volumes)
//
// STRIP  (refsw RenderTriangleStrip, refsw_lists.cpp:176): ONE record, up to 8
//   vertices, up to 6 triangles. Triangle i exists iff mask[5-i] is set. Winding
//   ALTERNATES with i: even i -> (v[i], v[i+1], v[i+2]); odd i -> (v[i+1], v[i],
//   v[i+2]). All triangles share the entry's param_offs; tag_offset = i.
// TRI ARRAY (refsw RenderTriangleArray, refsw_lists.cpp:206): `count` (=prims+1)
//   SEPARATE records, each 3 vertices, tag_offset=0, own param_offs.
//
// MEMORY: DIRECT DDR read port (dreq/dresp, single 64-bit channel via the shared
// arbiter). A whole record is read in ONE BURST: the needed words (isp + each
// vertex's XYZ) are picked out of the burst beat stream by view-word offset;
// attribute gap words are streamed past and discarded. For a strip this reads
// the entire strip (isp + up to 8 verts) as one DDR transaction, paying DDR
// latency ONCE; the strip's triangles then emit from local storage (isp_r,
// vslot[]) with no further memory traffic.
//
// 32-bit VIEW (refsw pvr_map32): a view-word q maps to physical 64-bit word
// q[19:0], low half if bank q[20]==0 else high half. Consecutive view-words in a
// bank = same half of consecutive physical words. A record is small and never
// crosses the bank boundary, so bank is constant for the whole burst: we burst
// `span` physical words from the record's base and take one half per beat.
//
// Handshake: triangle_ready (LEVEL) <-> triangle_done (1-cycle) per triangle;
// prim_done (1-cycle) when the whole entry is exhausted.
//
module isp_primitive_iterator import tsp_pkg::*; (
    input                  clk,
    input                  reset,
    input                  start,          // 1-cycle: begin iterating `entry`
    input      [26:0]      param_base,     // PARAM_BASE & 0xF00000 (byte addr)
    input                  intensity_shadow, // FPU_SHAD_SCALE.intensity_shadow
    input      entry_type_e    entry_type, // ENT_STRIP or ENT_TRI (ENT_QUAD n/a)
    input      objlist_entry_t entry,      // mask valid for STRIP; count for ARRAY
    output reg             busy,

    output triangle_out_t  trio,
    input  triangle_ack_t  ack,

    // direct DDR3 read port (64-bit beats, via shared arbiter)
    output ddr_rd_req_t    dreq,
    input  ddr_rd_resp_t   dresp
);
    wire is_array = (entry_type != ENT_STRIP);

    // ---- geometry (latched at start) ----
    reg [26:0] rec_base;      // byte addr of the CURRENT record (isp word)
    reg [2:0]  skip_r; reg shadow_r; reg [5:0] mask_r; reg ishadow_r;
    reg [20:0] po_r;          // param_offs_in_words of the CURRENT record
    reg [4:0]  count_r;       // array: number of records (prims+1)
    reg [4:0]  prim_r;        // array: current record index 0..count-1
    // two_volumes = shadow & ~intensity_shadow (refsw RenderTriangle*).
    wire       two_vol   = shadow_r & ~ishadow_r;
    wire [4:0] stride_w  = 5'd3 + skip_r * (two_vol ? 5'd2 : 5'd1);   // words/vertex
    wire [4:0] hdr_words = two_vol ? 5'd5 : 5'd3;                     // isp,tsp,tcw(,+2)
    wire [26:0] hdr_bytes = {22'b0, hdr_words, 2'b00};
    wire [26:0] stride_bytes = {stride_w, 2'b00};
    wire [26:0] rec_bytes = hdr_bytes + 27'd3 * stride_bytes;        // array record
    wire [20:0] rec_words = rec_bytes[22:2];

    // vertices to read: strip needs 8 (random access across its triangles),
    // array needs 3.
    wire [3:0]  nverts = is_array ? 4'd3 : 4'd8;

    // vertex slot storage (up to 8 vertices' XYZ) + isp word
    xyz_t vslot [0:7];
    reg [31:0] isp_r;

    // ---- output regs ----
    reg            tri_ready_r;
    xyz_t          v0_r, v1_r, v2_r;
    core_tag_t     tag_r;
    reg            pdone_r;
    assign trio.triangle_ready = tri_ready_r;
    assign trio.isp            = isp_r;
    assign trio.v0 = v0_r; assign trio.v1 = v1_r; assign trio.v2 = v2_r;
    assign trio.tag            = tag_r;
    assign trio.is_pt          = 1'b0;   // non-pf path: no PT/TL peel list-kind
    assign trio.prim_done      = pdone_r;

    // ==================== burst record reader ====================
    // rec_base view-word base + bank (constant over the small record).
    wire [24:0] base_vw   = rec_base[26:2];      // 32-bit-VIEW word index
    wire        rec_bank  = base_vw[20];
    wire [19:0] base_phys = base_vw[19:0];        // physical 64-bit word of view base
    // span (view-words) = last needed offset + 1 = hdr_words + (nverts-1)*stride_w + 3
    wire [8:0]  span_vw   = {4'b0, hdr_words} + ({5'b0,(nverts-4'd1)} * {4'b0,stride_w}) + 9'd3;

    // needed-word walk (monotonic offsets): ni=0 -> isp@0; ni>=1 -> vertex
    // (ni-1)/3, component (ni-1)%3, at offset hdr_words + vertex*stride_w + comp.
    reg  [5:0]  ni;                 // needed-item index 0..(1+3*nverts-1)
    wire [5:0]  n_last = 6'd1 + 6'd3 * {2'b0, nverts} - 6'd1;
    wire        ni_isp = (ni == 6'd0);
    // ni_vx = (ni-1)/3, ni_cmp = (ni-1)%3 : instead of a hardware divider, these
    // are tracked incrementally (ni advances by 1, so cmp cycles 0->1->2->0 and vx
    // increments on the wrap). See the R_STREAM `ni <= ni + 1` step.
    reg  [3:0]  ni_vx;              // vertex index for the current ni
    reg  [1:0]  ni_cmp;             // component (0=x,1=y,2=z) for the current ni
    wire [8:0]  need_off = ni_isp ? 9'd0
                         : {4'b0, hdr_words} + ({5'b0, ni_vx} * {4'b0, stride_w})
                                             + {7'b0, ni_cmp};

    // burst engine
    localparam R_IDLE=2'd0, R_REQ=2'd1, R_STREAM=2'd2;
    reg [1:0]  rst;
    reg [8:0]  beat;                // view-word offset of the incoming beat (0..span-1)
    wire [31:0] beat_half = rec_bank ? dresp.dout[63:32] : dresp.dout[31:0];

    reg        dreq_rd_r; reg [28:0] dreq_addr_r; reg [7:0] dreq_burst_r;
    assign dreq.rd    = dreq_rd_r;
    assign dreq.addr  = dreq_addr_r;
    assign dreq.burst = dreq_burst_r;

    reg [3:0]  nfilled;            // vertices fully captured so far (Z landed)
    reg        rd_done;            // pulse: record fully read

    // strip vertex selection: winding alternates with i.
    function automatic [3:0] va(input [2:0] i); va = {1'b0,i} + (i[0] ? 4'd1 : 4'd0); endfunction
    function automatic [3:0] vb(input [2:0] i); vb = {1'b0,i} + (i[0] ? 4'd0 : 4'd1); endfunction

    function automatic core_tag_t mk_tag(input [2:0] toff);
        mk_tag = '{ invalid:1'b0, pad:2'b00,
                    cache_bypass:isp_r[ISP_CACHEBYPASS_BIT],
                    shadow:shadow_r, skip:skip_r,
                    param_offs_in_words:po_r, tag_offset:toff };
    endfunction

    // ---- emit FSM ----
    localparam S_IDLE   = 4'd0,
               S_RSTART = 4'd1,   // kick off the record burst
               S_SEEK   = 4'd2,   // strip: seek s_i to next set mask bit
               S_PRESENT= 4'd3,   // hold triangle_ready, wait triangle_done
               S_NEXTREC= 4'd4,   // array: advance to next record or finish
               S_PDONE  = 4'd5;
    reg [3:0] st;
    reg [2:0] s_i;

    always @(posedge clk) begin
        if (reset) begin
            st<=S_IDLE; busy<=0; tri_ready_r<=0; pdone_r<=0;
            rst<=R_IDLE; dreq_rd_r<=0; nfilled<=0; rd_done<=0;
        end else begin
            pdone_r <= 1'b0;
            dreq_rd_r <= 1'b0;
            rd_done <= 1'b0;

            // ================= burst record reader =================
            case (rst)
            R_IDLE: ; // waits for S_RSTART to arm it
            R_REQ: if (!dresp.busy) begin
                dreq_rd_r    <= 1'b1;
                dreq_addr_r  <= {4'b0011, 5'b0, base_phys};   // {tag, 25-bit phys word}
                dreq_burst_r <= span_vw[7:0];                  // one beat per view-word
                beat         <= 9'd0;
                ni           <= 6'd0;
                ni_vx        <= 4'd0;   // ni=1 -> (vertex 0, comp 0)
                ni_cmp       <= 2'd0;
                rst          <= R_STREAM;
            end
            R_STREAM: if (dresp.dready) begin
                // pick out the needed word when this beat's offset matches.
                if (beat == need_off) begin
                    if (ni_isp) isp_r <= beat_half;
                    else begin
                        case (ni_cmp)
                            2'd0:    vslot[ni_vx].x <= beat_half;
                            2'd1:    vslot[ni_vx].y <= beat_half;
                            default: vslot[ni_vx].z <= beat_half;  // 2'd2
                        endcase
                        if (ni_cmp == 2'd2) nfilled <= nfilled + 4'd1;
                    end
                    ni <= ni + 6'd1;
                    // advance the (vertex, component) trackers in lockstep with ni
                    // (replaces (ni-1)/3 and (ni-1)%3 -> no hardware divider).
                    // Leaving isp (ni==0): next is (v0,c0), already 0 from R_REQ.
                    if (!ni_isp) begin
                        if (ni_cmp == 2'd2) begin
                            ni_cmp <= 2'd0;
                            ni_vx  <= ni_vx + 4'd1;
                        end else begin
                            ni_cmp <= ni_cmp + 2'd1;
                        end
                    end
                end
                if (beat == span_vw - 9'd1) begin
                    rst <= R_IDLE; rd_done <= 1'b1;   // burst complete
                end else beat <= beat + 9'd1;
            end
            default: rst <= R_IDLE;
            endcase

            // ======================= emit FSM =======================
            case (st)
            S_IDLE: if (start) begin
                rec_base <= param_base + {entry.param_offs_in_words,2'b00};
                skip_r   <= entry.skip;
                shadow_r <= entry.shadow;
                ishadow_r <= intensity_shadow;
                mask_r   <= entry.mask;
                po_r     <= entry.param_offs_in_words;
                count_r  <= entry.count;
                prim_r   <= 5'd0;
                busy     <= 1'b1;
                st       <= S_RSTART;
            end

            // kick off the burst for this record; emit waits on nfilled.
            S_RSTART: begin
                nfilled <= 4'd0;
                rst     <= R_REQ;
                s_i     <= 3'd0;
                st      <= is_array ? S_PRESENT : S_SEEK;
            end

            // ---- STRIP: seek s_i to the next set mask bit (mask[5-i]) ----
            // Wait until verts s_i..s_i+2 are captured (nfilled > s_i+2).
            S_SEEK: begin
                if (nfilled > {1'b0,s_i} + 4'd2) begin
                    if (mask_r[3'd5 - s_i]) begin
                        v0_r <= vslot[va(s_i)]; v1_r <= vslot[vb(s_i)];
                        v2_r <= vslot[{1'b0,s_i}+4'd2];
                        tag_r <= mk_tag(s_i);
                        tri_ready_r <= 1'b1;
                        st <= S_PRESENT;
                    end else if (s_i == 3'd5) st <= S_PDONE;
                    else s_i <= s_i + 3'd1;
                end
            end

            // present the triangle; on ack advance to next triangle/record.
            S_PRESENT: begin
                if (is_array && !tri_ready_r) begin
                    if (nfilled >= 4'd3) begin
                        v0_r<=vslot[0]; v1_r<=vslot[1]; v2_r<=vslot[2];
                        tag_r<=mk_tag(3'd0);
                        tri_ready_r <= 1'b1;
                    end
                end else begin
                    tri_ready_r <= 1'b1;
                    if (ack.triangle_done) begin
                        tri_ready_r <= 1'b0;
                        if (is_array) st <= S_NEXTREC;
                        else if (s_i == 3'd5) st <= S_PDONE;
                        else begin s_i <= s_i + 3'd1; st <= S_SEEK; end
                    end
                end
            end

            // ---- ARRAY: advance to the next record or finish ----
            S_NEXTREC: begin
                if (prim_r == count_r - 5'd1) st <= S_PDONE;
                else begin
                    prim_r   <= prim_r + 5'd1;
                    rec_base <= rec_base + rec_bytes;
                    po_r     <= po_r + rec_words;
                    st       <= S_RSTART;
                end
            end

            S_PDONE: begin busy<=0; pdone_r<=1'b1; st<=S_IDLE; end
            default: st<=S_IDLE;
            endcase
        end
    end
endmodule

//
// isp_primitive_iterator - consumes ONE object-list entry (triangle STRIP or
// triangle ARRAY) and iterates its triangles, reading position (X,Y,Z) per
// vertex from the parameter buffer. UV/color/offset/tsp/tcw are skipped here
// (address arithmetic only); the plane cache re-decodes the full record later.
//
// Shared record-read engine (refsw decode_pvr_vertices, refsw_tile.cpp:293):
// at a record base, isp is at +0 (tsp/tcw at +4/+8 present but unread); if
// two_volumes (=shadow) a second tsp1/tcw1 pair follows, so vertices start
// hdr_bytes later. Vertex k begins at rec_base + hdr_bytes + k*stride_bytes:
//   hdr_bytes    = 12 (+8 if two_volumes)
//   stride_bytes = (3 + skip*(1+two_volumes)) * 4
// Only the first 3 words (XYZ) of each vertex are read.
//
// STRIP  (refsw RenderTriangleStrip, refsw_lists.cpp:176): ONE record, up to 8
//   vertices, up to 6 triangles. Triangle i exists iff mask[5-i] is set. Winding
//   ALTERNATES with i: even i -> (v[i], v[i+1], v[i+2]); odd i -> (v[i+1], v[i],
//   v[i+2]) (first two swapped => inverted winding). All triangles share the
//   entry's param_offs; tag_offset = i.
//
// TRI ARRAY (refsw RenderTriangleArray, refsw_lists.cpp:206): `count` (=prims+1)
//   SEPARATE records, each a full record with 3 vertices. Each emits one
//   triangle with tag_offset = 0 and param_offs = that record's own word offset
//   (base advances by hdr_bytes + 3*stride_bytes per element).
//
// Handshake: triangle_ready (LEVEL) <-> triangle_done (1-cycle) per triangle;
// prim_done (1-cycle) when the whole entry is exhausted. DI: injected 256-bit
// param data cache (creq/cresp).
//
module isp_primitive_iterator import tsp_pkg::*; (
    input                  clk,
    input                  reset,
    input                  start,          // 1-cycle: begin iterating `entry`
    input      [26:0]      param_base,     // PARAM_BASE & 0xF00000 (byte addr)
    input      entry_type_e    entry_type, // ENT_STRIP or ENT_TRI (ENT_QUAD n/a)
    input      objlist_entry_t entry,      // mask valid for STRIP; count for ARRAY
    output reg             busy,

    output triangle_out_t  trio,
    input  triangle_ack_t  ack,

    // injected 256-bit param data cache
    output cache_req256_t  creq,
    input  cache_resp256_t cresp
);
    wire is_array = (entry_type != ENT_STRIP);

    // ---- 32-bit word reader over the 256-bit line cache ----
    reg  [26:0] raddr; reg rd_go; reg [31:0] rword; reg rword_v; reg [2:0] rsel;
    reg  [26:0] creq_laddr_r; reg creq_req_r;
    assign creq.req   = creq_req_r;
    assign creq.laddr = creq_laddr_r;

    always @(posedge clk) begin
        rword_v    <= 1'b0;
        creq_req_r <= 1'b0;                // default: 1-cycle pulse
        if (rd_go) begin
            creq_req_r   <= 1'b1;
            creq_laddr_r <= raddr[26:5];
            rsel         <= raddr[4:2];
        end
        if (cresp.ack) begin rword <= cresp.rdata[32*rsel +: 32]; rword_v <= 1'b1; end
        if (reset) creq_req_r <= 1'b0;
    end

    // ---- geometry (latched at start) ----
    reg [26:0] rec_base;      // byte addr of the CURRENT record (isp word)
    reg [2:0]  skip_r; reg shadow_r; reg [5:0] mask_r;
    reg [20:0] po_r;          // param_offs_in_words of the CURRENT record
    reg [4:0]  count_r;       // array: number of records (prims+1)
    reg [4:0]  prim_r;        // array: current record index 0..count-1
    wire       two_vol   = shadow_r;
    wire [4:0] stride_w  = 5'd3 + skip_r * (two_vol ? 5'd2 : 5'd1);   // words/vertex
    wire [26:0] hdr_bytes = two_vol ? 27'd20 : 27'd12;
    wire [26:0] stride_bytes = {stride_w,2'b00};
    // array element size (record) = header + 3 vertices, in bytes and in words
    wire [26:0] rec_bytes = hdr_bytes + 27'd3 * stride_bytes;
    wire [20:0] rec_words = rec_bytes[22:2];

    // how many vertices to read for the current record: strip needs all 8 (random
    // access across its triangles), array needs just 3.
    wire [3:0]  nverts = is_array ? 4'd3 : 4'd8;

    // vertex slot storage (up to 8 vertices' XYZ)
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
    assign trio.prim_done      = pdone_r;

    // ---- walk state ----
    localparam S_IDLE  = 4'd0,
               S_ISP    = 4'd1,   // issue read of isp word
               S_ISPW   = 4'd2,   // wait isp word
               S_VADDR  = 4'd3,   // compute this vertex's XYZ addr
               S_VX     = 4'd4,   // issue X read
               S_VXW    = 4'd5,   // capture X, issue Y read
               S_VY     = 4'd6,   // capture Y, issue Z read
               S_VZ     = 4'd7,   // capture Z
               S_VNEXT  = 4'd8,   // advance vidx or move to emit
               S_SEEK   = 4'd9,   // strip: seek s_i to next set mask bit
               S_PRESENT= 4'd10,  // hold triangle_ready, wait triangle_done
               S_NEXTREC= 4'd11,  // array: advance to the next record or finish
               S_PDONE  = 4'd12;  // pulse prim_done
    reg [3:0] st;

    reg [3:0] vidx;      // which vertex currently being fetched
    reg [26:0] vaddr;    // running byte addr of the vertex's X word
    reg [2:0]  s_i;      // strip triangle index 0..5

    // strip vertex selection: winding alternates with i.
    //   even i: v0=v[i],   v1=v[i+1]     odd i: v0=v[i+1], v1=v[i]   (v2=v[i+2])
    function automatic [3:0] va(input [2:0] i); va = {1'b0,i} + (i[0] ? 4'd1 : 4'd0); endfunction
    function automatic [3:0] vb(input [2:0] i); vb = {1'b0,i} + (i[0] ? 4'd0 : 4'd1); endfunction

    // build the CoreTag for the triangle currently being presented.
    function automatic core_tag_t mk_tag(input [2:0] toff);
        mk_tag = '{ invalid:1'b0, pad:2'b00,
                    cache_bypass:isp_r[ISP_CACHEBYPASS_BIT],
                    shadow:shadow_r, skip:skip_r,
                    param_offs_in_words:po_r, tag_offset:toff };
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            st<=S_IDLE; busy<=0; tri_ready_r<=0; pdone_r<=0; rd_go<=0;
        end else begin
            pdone_r <= 1'b0;
            rd_go   <= 1'b0;

            case (st)
            S_IDLE: if (start) begin
                rec_base <= param_base + {entry.param_offs_in_words,2'b00};
                skip_r   <= entry.skip;
                shadow_r <= entry.shadow;
                mask_r   <= entry.mask;
                po_r     <= entry.param_offs_in_words;
                count_r  <= entry.count;    // array only
                prim_r   <= 5'd0;
                busy     <= 1'b1;
                st       <= S_ISP;
            end

            // ---- read the current record: isp + nverts vertices' XYZ ----
            S_ISP:  begin raddr<=rec_base; rd_go<=1'b1; st<=S_ISPW; end
            S_ISPW: if (rword_v) begin isp_r<=rword; vidx<=4'd0; st<=S_VADDR; end

            S_VADDR: begin
                vaddr <= rec_base + hdr_bytes + (vidx * stride_bytes);
                st    <= S_VX;
            end
            S_VX:  begin raddr<=vaddr;          rd_go<=1'b1; st<=S_VXW; end
            S_VXW: if (rword_v) begin vslot[vidx].x<=rword; raddr<=vaddr+27'd4; rd_go<=1'b1; st<=S_VY; end
            S_VY:  if (rword_v) begin vslot[vidx].y<=rword; raddr<=vaddr+27'd8; rd_go<=1'b1; st<=S_VZ; end
            S_VZ:  if (rword_v) begin vslot[vidx].z<=rword; st<=S_VNEXT; end
            S_VNEXT: begin
                if (vidx == nverts-4'd1) begin
                    // record read complete
                    if (is_array) begin
                        // array: emit the single triangle (v0,v1,v2), tag_offset=0
                        v0_r<=vslot[0]; v1_r<=vslot[1]; v2_r<=vslot[2];
                        tag_r<=mk_tag(3'd0);
                        st<=S_PRESENT;
                    end else begin
                        s_i<=3'd0; st<=S_SEEK;
                    end
                end else begin vidx<=vidx+4'd1; st<=S_VADDR; end
            end

            // ---- STRIP: seek s_i to the next set mask bit (mask[5-i]) ----
            S_SEEK: begin
                if (mask_r[3'd5 - s_i]) begin
                    v0_r <= vslot[va(s_i)]; v1_r <= vslot[vb(s_i)]; v2_r <= vslot[{1'b0,s_i}+4'd2];
                    tag_r <= mk_tag(s_i);
                    st <= S_PRESENT;
                end else if (s_i == 3'd5) st <= S_PDONE;
                else s_i <= s_i + 3'd1;
            end

            // present the triangle; on ack advance to the next triangle/record.
            S_PRESENT: begin
                tri_ready_r <= 1'b1;
                if (ack.triangle_done) begin
                    tri_ready_r <= 1'b0;
                    if (is_array) st <= S_NEXTREC;
                    else if (s_i == 3'd5) st <= S_PDONE;   // strip exhausted
                    else begin s_i <= s_i + 3'd1; st <= S_SEEK; end
                end
            end

            // ---- ARRAY: advance to the next record or finish ----
            S_NEXTREC: begin
                if (prim_r == count_r - 5'd1) st <= S_PDONE;
                else begin
                    prim_r   <= prim_r + 5'd1;
                    rec_base <= rec_base + rec_bytes;      // next element's record
                    po_r     <= po_r + rec_words;          // its own param offset
                    st       <= S_ISP;
                end
            end

            S_PDONE: begin busy<=0; pdone_r<=1'b1; st<=S_IDLE; end
            default: st<=S_IDLE;
            endcase
        end
    end
endmodule

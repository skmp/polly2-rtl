// record_fetcher - fetch + decode ONE PowerVR param record (GetFpuEntry) from DDR.
//
// TWO exact DDR bursts per record, decoded ON THE FLY as the beats stream in
// (no line cache, no next-line prefetch, no re-fetches):
//   burst 1 (3 words @ rec)          : isp / tsp / tcw header words.
//   burst 2 (vertex region @ vb)     : vb = rec + (two_vol?20:12) + toff*stride;
//     length = 2*stride + fields_per_vertex words (covers all 3 vertices' fields).
//     Each arriving word at offset w fills EVERY vertex v whose field window
//     contains it (r = w - v*stride, 0 <= r < fpv): strip vertices OVERLAP when
//     stride < fpv, and the same word legitimately lands in two vertices.
// Everything needed to size/aim burst 2 is known before it issues: skip/toff/
// two_vol come from the TAG; texture/uv16/offset (-> fpv and the r->field map)
// come from the burst-1 isp word.
//
// Field map per vertex (r = word offset within the vertex):
//   r=0 x, r=1 y, r=2 z,
//   texture&&uv16 : r=3 {u16,v16}          col at r=4
//   texture&&!uv16: r=3 u, r=4 v           col at r=5
//   !texture      :                        col at r=3
//   offset        : ofs at col+1
//
// Decode semantics identical to the old line-reader FSM (same field selection off
// the FETCHED isp word); only the transport changed. Ports unchanged.
//
module record_fetcher import tsp_pkg::*; (
    input                clk,
    input                reset,
    input                start,              // 1-cyc: fetch+decode the record for `tag`
    input      [31:0]    tag,                // CoreTag
    input      [26:0]    param_base,
    input                intensity_shadow,   // regs.fpu_shad_scale.intensity_shadow
    output reg           busy,               // start..done
    output reg           done,               // 1-cyc: outputs valid
    output reg [31:0]    o_isp, o_tsp, o_tcw,
    output reg [31:0]    o_x[0:2], o_y[0:2], o_z[0:2],
    output reg [31:0]    o_u[0:2], o_v[0:2], o_col[0:2], o_ofs[0:2],
    // its OWN DDR arbiter client
    output ddr_rd_req_t  dreq,
    input  ddr_rd_resp_t dresp
);
    // ---- latched tag + its decoded fields ----
    reg  [31:0] r_tag;
    wire [2:0]  r_skip     = r_tag[26:24];
    wire [2:0]  r_toff     = r_tag[2:0];
    wire        r_two_vol  = r_tag[27] & ~intensity_shadow;
    wire [4:0]  r_stride_w = 5'd3 + r_skip * (r_two_vol ? 5'd2 : 5'd1);

    // ---- decoded isp flags (off the FETCHED isp word, valid after burst-1 beat 0) ----
    wire f_texture = o_isp[ISP_TEXTURE_BIT];
    wire f_offset  = o_isp[ISP_OFFSET_BIT];
    wire f_uv16    = o_isp[ISP_UV16_BIT];

    // per-vertex field positions (valid once o_isp is loaded)
    wire [3:0] pos_col = 4'd3 + (f_texture ? (f_uv16 ? 4'd1 : 4'd2) : 4'd0);
    wire [3:0] pos_ofs = pos_col + 4'd1;
    wire [3:0] fpv     = pos_col + 4'd1 + (f_offset ? 4'd1 : 4'd0);

    // ---- record addressing (32-bit VIEW word indices) ----
    // record byte base = param_base + {4'd0, tag[23:3], 2'b00}
    reg  [26:0] rec_b;                        // record byte base
    wire [24:0] rec_w = rec_b[26:2];          // view word index
    // vertex region base (view words): rec + (two_vol?5:3) + toff*stride
    wire [24:0] vb_w  = rec_w + (r_two_vol ? 25'd5 : 25'd3)
                              + {20'd0, r_toff} * {20'd0, r_stride_w};
    // burst-2 length: 2*stride + fpv words (last field of vertex 2)
    wire [7:0]  v_len = {2'd0, r_stride_w, 1'b0} + {4'd0, fpv};

    // view word -> physical: bank = word[20] (half select), wofs = word[19:0]
    function automatic [28:0] vw_addr(input [24:0] vw);
        vw_addr = {4'b0011, 5'b0, vw[19:0]};
    endfunction

    // ---- burst engine ----
    localparam B_IDLE=3'd0, B_H_REQ=3'd1, B_H_DATA=3'd2, B_V_REQ=3'd3, B_V_DATA=3'd4,
               B_DONE=3'd5;
    reg [2:0]  bst;
    reg [7:0]  beat;                          // beat counter within the burst
    reg        v_bank;                        // burst-2 bank (word[20] of vb_w)
    reg        h_bank;                        // burst-1 bank
    wire [31:0] h_word = h_bank ? dresp.dout[63:32] : dresp.dout[31:0];
    wire [31:0] v_word = v_bank ? dresp.dout[63:32] : dresp.dout[31:0];

    reg        ts_rd_r; reg [28:0] ts_addr_r; reg [7:0] ts_burst_r;
    assign dreq.rd    = ts_rd_r;
    assign dreq.addr  = ts_addr_r;
    assign dreq.burst = ts_burst_r;

    // ---- streaming vertex-field decode (combinational per arriving beat) ----
    // beat = word offset w within the vertex region; for each vertex v, r = w - v*stride.
    integer v;
    reg [7:0] rr;

`ifndef SYNTHESIS
    integer fx_dbg_cyc;
    always @(posedge clk) begin
        if (reset) fx_dbg_cyc <= 0; else fx_dbg_cyc <= fx_dbg_cyc + 1;
        if ($test$plusargs("fxtrace")) begin
            if (ts_rd_r)  $display("[FX c%0d] BURST addr=%07x n=%0d", fx_dbg_cyc, ts_addr_r, ts_burst_r);
            if (done)     $display("[FX c%0d] DONE", fx_dbg_cyc);
        end
    end
`endif

    always @(posedge clk) begin
        if (reset) begin
            bst <= B_IDLE; busy <= 1'b0; done <= 1'b0; ts_rd_r <= 1'b0;
        end else begin
            done    <= 1'b0;
            ts_rd_r <= 1'b0;

            case (bst)
            B_IDLE: if (start) begin
                busy  <= 1'b1;
                r_tag <= tag;
                rec_b <= param_base + {4'd0, tag[23:3], 2'b00};
                bst   <= B_H_REQ;
            end

            // ---- burst 1: 3 header words @ rec ----
            B_H_REQ: if (!dresp.busy) begin
                ts_rd_r    <= 1'b1;
                ts_addr_r  <= vw_addr(rec_w);
                ts_burst_r <= 8'd3;
                h_bank     <= rec_w[20];
                beat       <= 8'd0;
                bst        <= B_H_DATA;
            end
            B_H_DATA: if (dresp.dready) begin
                case (beat)
                8'd0: o_isp <= h_word;
                8'd1: o_tsp <= h_word;
                default: o_tcw <= h_word;
                endcase
                beat <= beat + 8'd1;
                if (beat == 8'd2) begin
                    for (v = 0; v < 3; v = v + 1) begin
                        o_u[v]<=32'd0; o_v[v]<=32'd0; o_col[v]<=32'd0; o_ofs[v]<=32'd0;
                    end
                    bst <= B_V_REQ;
                end
            end

            // ---- burst 2: the whole vertex region @ vb (flags now valid) ----
            B_V_REQ: if (!dresp.busy) begin
                ts_rd_r    <= 1'b1;
                ts_addr_r  <= vw_addr(vb_w);
                ts_burst_r <= v_len;
                v_bank     <= vb_w[20];
                beat       <= 8'd0;
                bst        <= B_V_DATA;
            end
            B_V_DATA: if (dresp.dready) begin
                // this word is offset `beat` in the region; fill every vertex whose
                // field window contains it (vertices overlap when stride < fpv).
                for (v = 0; v < 3; v = v + 1) begin
                    rr = beat - v[1:0] * {3'd0, r_stride_w};
                    if (beat >= v[1:0] * {3'd0, r_stride_w} && rr < {4'd0, fpv}) begin
                        if      (rr == 8'd0) o_x[v] <= v_word;
                        else if (rr == 8'd1) o_y[v] <= v_word;
                        else if (rr == 8'd2) o_z[v] <= v_word;
                        else if (f_texture && f_uv16 && rr == 8'd3) begin
                            o_u[v] <= {v_word[31:16], 16'd0};
                            o_v[v] <= {v_word[15:0],  16'd0};
                        end
                        else if (f_texture && !f_uv16 && rr == 8'd3) o_u[v] <= v_word;
                        else if (f_texture && !f_uv16 && rr == 8'd4) o_v[v] <= v_word;
                        else if (rr == {4'd0, pos_col})              o_col[v] <= v_word;
                        else if (f_offset && rr == {4'd0, pos_ofs})  o_ofs[v] <= v_word;
                    end
                end
                beat <= beat + 8'd1;
                if (beat == v_len - 8'd1) bst <= B_DONE;
            end

            B_DONE: begin
                done <= 1'b1;
                busy <= 1'b0;
                bst  <= B_IDLE;
            end
            default: bst <= B_IDLE;
            endcase
        end
    end
endmodule

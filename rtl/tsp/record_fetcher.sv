// record_fetcher - fetch + decode ONE PowerVR param record (GetFpuEntry) from DDR.
//
// Extracted verbatim from peel_core's spanner miss path so it can be instantiated
// TWICE (a demand fetcher + a prefetcher) to give the spanner a 2-deep record cache.
// Given a CoreTag, it:
//   * decodes the tag fields (skip / tag_offset / two_vol / stride),
//   * fetches the 3-word ISP/TSP/TCW record header (record byte base =
//       param_base + {4'd0, tag[23:3], 2'b00}),
//   * STREAMS the 3 vertices (1 word/clock) selecting the texture / uv16 / offset
//     fields off the FETCHED isp word exactly as the old inline decode did off
//     cur_isp, and
//   * pulses `done` with o_isp/o_tsp/o_tcw + o_x/y/z/u/v/col/ofs[0:2] valid.
//
// It owns its OWN DDR arbiter client (dreq/dresp) with the SAME burst-8 8-word
// sliding-window line reader as before (tw0 demand line + tw1 sequential prefetch
// line, burst=8). Decode semantics are BIT-FOR-BIT identical to the old FH_/FV_
// FSM in peel_core; only cur_*/fv_* became o_*/o_x-etc and the state enum is local.
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
    // ---- latched tag + its decoded fields (mirror sh_* wires off the latched tag) ----
    reg  [31:0] r_tag;
    wire [2:0]  r_skip     = r_tag[26:24];
    wire [2:0]  r_toff     = r_tag[2:0];
    wire        r_two_vol  = r_tag[27] & ~intensity_shadow;
    wire [4:0]  r_stride_w = 5'd3 + r_skip * (r_two_vol ? 5'd2 : 5'd1);
    wire [26:0] r_stride_b = {r_stride_w, 2'b00};

    // ---- decoded isp flags of the record being fetched (off the FETCHED isp word) ----
    wire f_texture = o_isp[ISP_TEXTURE_BIT];
    wire f_offset  = o_isp[ISP_OFFSET_BIT];
    wire f_uv16    = o_isp[ISP_UV16_BIT];

    // ---- 32-bit word reader: DIRECT DDR, 8-word sliding-window (as object_list_parser) ----
    // f_go with a byte address (f_addr) returns the word NEXT cycle in
    // f_word/f_word_v on a resident line. Each miss fetches a whole 256-bit line
    // (burst=8) into tw0 (demand) or tw1 (prefetch of tw0+1). Drives dreq/dresp.
    reg  [26:0] f_addr; reg f_go; reg [31:0] f_word; reg f_word_v;
    reg  [255:0] tw0; reg [21:0] t0_tag; reg t0_v;
    reg  [255:0] tw1; reg [21:0] t1_tag; reg t1_v;
    reg          tpend; reg [21:0] tline; reg [2:0] tsel;

    localparam TF_IDLE=2'd0, TF_MISS=2'd1, TF_FILL=2'd2;
    reg [1:0]   tfst;
    reg [21:0]  tf_line; reg tf_is_pf; reg [2:0] tf_beat; reg [255:0] tf_acc;
    wire        tf_bank    = tf_line[17];
    wire [19:0] tf_wofs_b  = {tf_line[16:0], 3'b000};
    wire [28:0] tf_base_wd = {9'b0, tf_wofs_b};
    wire [31:0] tf_half    = tf_bank ? dresp.dout[63:32] : dresp.dout[31:0];

    reg        ts_rd_r; reg [28:0] ts_addr_r; reg [7:0] ts_burst_r;
    assign dreq.rd    = ts_rd_r;
    assign dreq.addr  = ts_addr_r;
    assign dreq.burst = ts_burst_r;

    always @(posedge clk) begin
        f_word_v <= 1'b0;
        ts_rd_r  <= 1'b0;

        if (f_go) begin tpend <= 1'b1; tline <= f_addr[26:5]; tsel <= f_addr[4:2]; end

        if (tpend) begin
            if (t0_v && t0_tag == tline) begin
                f_word <= tw0[32*tsel +: 32]; f_word_v <= 1'b1; if (!f_go) tpend <= 1'b0;
            end else if (t1_v && t1_tag == tline) begin
                tw0 <= tw1; t0_tag <= t1_tag; t0_v <= 1'b1; t1_v <= 1'b0;
                f_word <= tw1[32*tsel +: 32]; f_word_v <= 1'b1; if (!f_go) tpend <= 1'b0;
            end
        end

        case (tfst)
        TF_IDLE: begin
            if (tpend && !(t0_v && t0_tag==tline) && !(t1_v && t1_tag==tline)) begin
                tf_line <= tline; tf_is_pf <= 1'b0; tf_beat <= 3'd0; t1_v <= 1'b0;
                tfst <= TF_MISS;
            end else if (t0_v && !(t1_v && t1_tag == t0_tag + 22'd1)) begin
                tf_line <= t0_tag + 22'd1; tf_is_pf <= 1'b1; tf_beat <= 3'd0;
                tfst <= TF_MISS;
            end
        end
        TF_MISS: if (!dresp.busy) begin
            ts_rd_r    <= 1'b1;
            ts_addr_r  <= {4'b0011, tf_base_wd[24:0]};
            ts_burst_r <= 8'd8;
            tfst       <= TF_FILL;
        end
        TF_FILL: if (dresp.dready) begin
            tf_acc[32*tf_beat +: 32] <= tf_half;
            if (tf_beat == 3'd7) begin
                if (tf_is_pf) begin tw1 <= { tf_half, tf_acc[223:0] }; t1_tag <= tf_line; t1_v <= 1'b1; end
                else          begin tw0 <= { tf_half, tf_acc[223:0] }; t0_tag <= tf_line; t0_v <= 1'b1; end
                tfst <= TF_IDLE;
            end else tf_beat <= tf_beat + 3'd1;
        end
        default: tfst <= TF_IDLE;
        endcase

        if (reset) begin t0_v<=0; t1_v<=0; tpend<=0; tfst<=TF_IDLE; ts_rd_r<=0; end
    end

    // ---- decode FSM (was peel_core's spanner P_FH_*/P_FV/P_TSP_RUN states) ----
    reg [26:0] f_rec, f_vtx;       // record base / current vertex base byte addr
    reg [1:0]  fv_i;               // vertex being fetched 0..2
    reg [2:0]  fv_fld;             // field sequencer (see FLD_* below)
    integer    j;

    // vertex field ids
    localparam [2:0] FLD_X=0, FLD_Y=1, FLD_Z=2, FLD_UV16=3, FLD_U=4, FLD_V=5,
                     FLD_COL=6, FLD_OFS=7;

    localparam D_IDLE=0, D_FH_ISP=1, D_FH_ISPW=2, D_FH_TSPW=3, D_FH_TCWW=4,
               D_FV=5, D_DONE=6;
    reg [2:0]  ds;

    always @(posedge clk) begin
        if (reset) begin
            ds <= D_IDLE; busy <= 1'b0; done <= 1'b0; f_go <= 1'b0;
        end else begin
            done <= 1'b0;
            f_go <= 1'b0;

            case (ds)
            D_IDLE: if (start) begin
                busy   <= 1'b1;
                r_tag  <= tag;
                // record byte base = param_base + {4'd0, tag[23:3], 2'b00}
                f_rec  <= param_base + {4'd0, tag[23:3], 2'b00};
                ds     <= D_FH_ISP;
            end

            // ---- param record header fetch (was P_FH_*) ----
            D_FH_ISP:  begin f_addr<=f_rec; f_go<=1'b1; ds<=D_FH_ISPW; end
            D_FH_ISPW: if (f_word_v) begin
                        o_isp = f_word;
                        f_addr<=f_rec+27'd4; f_go<=1'b1; ds<=D_FH_TSPW;
                    end
            D_FH_TSPW: if (f_word_v) begin
                        o_tsp = f_word;
                        f_addr<=f_rec+27'd8; f_go<=1'b1; ds<=D_FH_TCWW;
                    end
            D_FH_TCWW: if (f_word_v) begin
                        o_tcw = f_word;
                        f_vtx <= f_rec + (r_two_vol ? 27'd20 : 27'd12)
                                       + {22'd0, r_toff} * r_stride_b;
                        fv_i  <= 2'd0;
                        fv_fld<= FLD_X;
                        for (j = 0; j < 3; j = j + 1) begin
                            o_u[j]=32'd0; o_v[j]=32'd0; o_col[j]=32'd0; o_ofs[j]=32'd0;
                        end
                        // present the FIRST vertex read (FLD_X of vtx0) now, then stream
                        // in D_FV at 1 word/cycle.
                        f_addr <= f_rec + (r_two_vol ? 27'd20 : 27'd12)
                                        + {22'd0, r_toff} * r_stride_b;   // = f_vtx (FLD_X)
                        f_go   <= 1'b1;
                        ds <= D_FV;
                    end

            // STREAMING vertex fetch, 1 word/clock. Each cycle with f_word_v: sample the
            // current field, decide the NEXT field/vertex, and PRESENT that next read in
            // the SAME cycle (f_go+f_addr) so the reader streams back-to-back on a warm
            // line. On a cold line f_word_v stalls and we hold. Identical decode to the
            // old spanner P_FV (f_texture/f_uv16/f_offset off the fetched isp = o_isp).
            D_FV: if (f_word_v) begin
                reg [2:0]  nfld; reg [26:0] nvtx; reg [26:0] naddr; reg fv_done;
                reg [1:0]  nvi;
                nfld = fv_fld; nvtx = f_vtx; nvi = fv_i; fv_done = 1'b0;
                // ---- sample current field + choose next field within this vertex ----
                case (fv_fld)
                FLD_X: begin o_x[fv_i] = f_word; nfld = FLD_Y; end
                FLD_Y: begin o_y[fv_i] = f_word; nfld = FLD_Z; end
                FLD_Z: begin o_z[fv_i] = f_word;
                             nfld = f_texture ? (f_uv16 ? FLD_UV16 : FLD_U) : FLD_COL; end
                FLD_UV16: begin o_u[fv_i] = {f_word[31:16],16'd0};
                                o_v[fv_i] = {f_word[15:0], 16'd0}; nfld = FLD_COL; end
                FLD_U: begin o_u[fv_i] = f_word; nfld = FLD_V; end
                FLD_V: begin o_v[fv_i] = f_word; nfld = FLD_COL; end
                FLD_COL: begin o_col[fv_i] = f_word;
                               if (f_offset) nfld = FLD_OFS;
                               else if (fv_i == 2'd2) fv_done = 1'b1;
                               else begin nvi = fv_i + 2'd1; nvtx = f_vtx + r_stride_b; nfld = FLD_X; end
                          end
                default: begin // FLD_OFS
                               o_ofs[fv_i] = f_word;
                               if (fv_i == 2'd2) fv_done = 1'b1;
                               else begin nvi = fv_i + 2'd1; nvtx = f_vtx + r_stride_b; nfld = FLD_X; end
                          end
                endcase
                // ---- next byte address for nfld at vertex nvtx ----
                case (nfld)
                FLD_X:    naddr = nvtx;
                FLD_Y:    naddr = nvtx + 27'd4;
                FLD_Z:    naddr = nvtx + 27'd8;
                FLD_UV16,
                FLD_U:    naddr = nvtx + 27'd12;
                FLD_V:    naddr = nvtx + 27'd16;
                FLD_COL:  naddr = nvtx + 27'd12 + (f_texture ? (f_uv16 ? 27'd4 : 27'd8) : 27'd0);
                default:  naddr = nvtx + 27'd16 + (f_texture ? (f_uv16 ? 27'd4 : 27'd8) : 27'd0);
                endcase
                if (fv_done) begin
                    // record fully fetched + decoded -> pulse done.
                    done <= 1'b1;
                    busy <= 1'b0;
                    ds   <= D_IDLE;
                end else begin
                    fv_fld <= nfld; fv_i <= nvi; f_vtx <= nvtx;
                    f_addr <= naddr; f_go <= 1'b1;   // present next read THIS cycle
                    ds <= D_FV;
                end
            end

            default: ds <= D_IDLE;
            endcase
        end
    end
endmodule

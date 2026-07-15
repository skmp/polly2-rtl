// frontend_tsp_tb_top - frontend_isp_tb_top + the TSP back-end: on tile FLUSH,
// every pixel's CoreTag is shaded through a tag-keyed TSP plane cache:
//
//   per pixel: tag -> plane-cache lookup (64-entry, keyed by the FULL 32-bit
//   CoreTag; cache_bypass is IGNORED - entries are always cached)
//     miss: fetch the param record via a TSP data cache (refsw GetFpuEntry /
//           decode_pvr_vertices: isp/tsp/tcw + 3 vertices from tag_offset,
//           XYZ + UV(f32 or f16) + base col + offset col), run tsp_setup_min,
//           store the 10 interpolation planes + isp/tsp/tcw into the cache
//     hit : planes come straight from the cache
//   then tsp_shade runs for the pixel (invW from the depth buffer, textures
//   through 2 tex_caches over VRAM) and the ARGB result goes to a color buffer.
//   Once all 1024 pixels are shaded the color buffer is written to the 640x480
//   framebuffer at (tile_x*32, tile_y*32) - same place the tag TB wrote tags.
//
module frontend_tsp_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
    // register write path (C++ TB loads the PVR reg dump through this before go)
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    input             go,             // 1-cycle: start rendering the region array
    output reg        done            // 1-cycle: region array fully processed
);
    // -------------------- reg_file --------------------
    pvr_regs_t  regs;
    fog_rd_req_t fog_req; fog_rd_resp_t fog_resp;
    pal_rd_req_t pal_req; pal_rd_resp_t pal_resp;
    assign fog_req = '0; assign pal_req = '0;
    reg_file u_rf (.clk(clk),.reset(reset),.wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),
        .regs(regs),.fog_req(fog_req),.fog_resp(fog_resp),.pal_req(pal_req),.pal_resp(pal_resp));

    wire [26:0] region_base = regs.region_base[26:0];
    wire [26:0] param_base  = (regs.param_base[26:0] & 27'h0F00000); // PARAM_BASE & 0xF00000
    wire        region_v1   = (regs.fpu_param_cfg.region_header_type == 1'b0);

    // -------------------- 8 MB behavioral VRAM (1M x 64-bit) --------------------
    (* verilator public_flat_rw *) reg [63:0] vram [0:1048575];

    // region port - BURST + latency model (region parser now reads DDR directly
    // with an 8-word burst; a single-beat stub would hang its line fill).
    localparam integer RA_RD_LAT = 8;
    ddr_rd_req_t  ra_dreq; ddr_rd_resp_t ra_dresp;
    reg ra_busy_d; reg [19:0] ra_word; reg [7:0] ra_beats, ra_lat;
    reg [63:0] ra_do; reg ra_dv;
    assign ra_dresp.busy=ra_busy_d; assign ra_dresp.dout=ra_do; assign ra_dresp.dready=ra_dv;
    always @(posedge clk) begin
        ra_dv <= 1'b0;
        if (reset) ra_busy_d <= 1'b0;
        else if (!ra_busy_d) begin
            if (ra_dreq.rd) begin ra_busy_d<=1'b1; ra_word<=ra_dreq.addr[19:0];
                ra_beats<=ra_dreq.burst; ra_lat<=RA_RD_LAT[7:0]; end
        end else if (ra_lat != 0) ra_lat <= ra_lat - 8'd1;
        else begin
            ra_do<=vram[ra_word]; ra_dv<=1'b1; ra_word<=ra_word+20'd1;
            if (ra_beats <= 8'd1) ra_busy_d <= 1'b0;
            ra_beats <= ra_beats - 8'd1;
        end
    end
    // objlist + param ports - BURST + latency model (each a single 64-bit channel
    // via the shared arbiter): a read is accepted for RD_LAT dead cycles, then
    // `burst` consecutive beats stream out one/cycle from incrementing addresses.
    localparam integer RD_LAT = 8;
    // objlist port
    ddr_rd_req_t  ol_dreq; ddr_rd_resp_t ol_dresp;
    reg ol_busy_d; reg [19:0] ol_word; reg [7:0] ol_beats, ol_lat;
    reg [63:0] ol_do; reg ol_dv;
    assign ol_dresp.busy=ol_busy_d; assign ol_dresp.dout=ol_do; assign ol_dresp.dready=ol_dv;
    always @(posedge clk) begin
        ol_dv <= 1'b0;
        if (reset) ol_busy_d <= 1'b0;
        else if (!ol_busy_d) begin
            if (ol_dreq.rd) begin ol_busy_d<=1'b1; ol_word<=ol_dreq.addr[19:0];
                ol_beats<=ol_dreq.burst; ol_lat<=RD_LAT[7:0]; end
        end else if (ol_lat != 0) ol_lat <= ol_lat - 8'd1;
        else begin
            ol_do<=vram[ol_word]; ol_dv<=1'b1; ol_word<=ol_word+20'd1;
            if (ol_beats <= 8'd1) ol_busy_d <= 1'b0;
            ol_beats <= ol_beats - 8'd1;
        end
    end
    // param (ISP / vertex XYZ) port
    ddr_rd_req_t  pr_dreq; ddr_rd_resp_t pr_dresp;
    reg pr_busy; reg [19:0] pr_word; reg [7:0] pr_beats, pr_lat;
    reg [63:0] pr_do; reg pr_dv;
    assign pr_dresp.busy=pr_busy; assign pr_dresp.dout=pr_do; assign pr_dresp.dready=pr_dv;
    always @(posedge clk) begin
        pr_dv <= 1'b0;
        if (reset) pr_busy <= 1'b0;
        else if (!pr_busy) begin
            if (pr_dreq.rd) begin pr_busy<=1'b1; pr_word<=pr_dreq.addr[19:0];
                pr_beats<=pr_dreq.burst; pr_lat<=RD_LAT[7:0]; end
        end else if (pr_lat != 0) pr_lat <= pr_lat - 8'd1;
        else begin
            pr_do<=vram[pr_word]; pr_dv<=1'b1; pr_word<=pr_word+20'd1;
            if (pr_beats <= 8'd1) pr_busy <= 1'b0;
            pr_beats <= pr_beats - 8'd1;
        end
    end
    // TSP param port - BURST + latency model (param reader now reads DDR directly
    // with an 8-word burst; a single-beat stub would hang its line fill).
    localparam integer TS_RD_LAT = 8;
    ddr_rd_req_t  ts_dreq; ddr_rd_resp_t ts_dresp;
    reg ts_busy_d; reg [19:0] ts_word; reg [7:0] ts_beats, ts_lat;
    reg [63:0] ts_do; reg ts_dv;
    assign ts_dresp.busy=ts_busy_d; assign ts_dresp.dout=ts_do; assign ts_dresp.dready=ts_dv;
    always @(posedge clk) begin
        ts_dv <= 1'b0;
        if (reset) ts_busy_d <= 1'b0;
        else if (!ts_busy_d) begin
            if (ts_dreq.rd) begin ts_busy_d<=1'b1; ts_word<=ts_dreq.addr[19:0];
                ts_beats<=ts_dreq.burst; ts_lat<=TS_RD_LAT[7:0]; end
        end else if (ts_lat != 0) ts_lat <= ts_lat - 8'd1;
        else begin
            ts_do<=vram[ts_word]; ts_dv<=1'b1; ts_word<=ts_word+20'd1;
            if (ts_beats <= 8'd1) ts_busy_d <= 1'b0;
            ts_beats <= ts_beats - 8'd1;
        end
    end
    // texture ports (64-bit view = physical, no de-interleave). The pipelined
    // shader has 4 corner fetchers, each with a {data, VQ} cache pair -> 8 DDR
    // ports. A generate loop builds the read stubs.
    genvar gi_tex;
    ddr_rd_req_t  tex_dreq [0:7];
    ddr_rd_resp_t tex_dresp [0:7];
    generate
      for (gi_tex = 0; gi_tex < 8; gi_tex = gi_tex + 1) begin : texddr
        reg [63:0] do_r; reg dv_r;
        assign tex_dresp[gi_tex].busy=1'b0;
        assign tex_dresp[gi_tex].dout=do_r;
        assign tex_dresp[gi_tex].dready=dv_r;
        always @(posedge clk) begin
            dv_r<=0;
            if (tex_dreq[gi_tex].rd) begin do_r<=vram[tex_dreq[gi_tex].addr[19:0]]; dv_r<=1; end
        end
      end
    endgenerate

    // -------------------- caches --------------------
    // Region parser, OL parser, ISP iterator AND TSP param fetch all read DDR
    // DIRECTLY (own 8-word sliding-window line reader) via ra_/ol_/pr_/ts_dreq.
    // No data_cache256.

    // 4 corner fetchers x {data (tc), VQ codebook}. tex_dreq/dresp index:
    //   corner c: data = 2*c, VQ = 2*c+1.
    cache_req_t   pp_tc_req [0:3], pp_vq_req [0:3];
    cache_resp_t  pp_tc_resp[0:3], pp_vq_resp[0:3];
    generate
      for (gi_tex = 0; gi_tex < 4; gi_tex = gi_tex + 1) begin : texcache
        tex_cache u_tc (.clk(clk),.reset(reset),
            .creq(pp_tc_req[gi_tex]),.cresp(pp_tc_resp[gi_tex]),
            .dreq(tex_dreq[2*gi_tex]),.dresp(tex_dresp[2*gi_tex]));
        tex_cache u_vq (.clk(clk),.reset(reset),
            .creq(pp_vq_req[gi_tex]),.cresp(pp_vq_resp[gi_tex]),
            .dreq(tex_dreq[2*gi_tex+1]),.dresp(tex_dresp[2*gi_tex+1]));
      end
    endgenerate

    // -------------------- parsers --------------------
    reg          ra_start;
    wire         ra_busy, ra_tiles_parsed;
    region_out_t ra_out; region_ack_t ra_ack;
    region_array_parser u_ra (.clk(clk),.reset(reset),.start(ra_start),
        .region_base(region_base),.region_v1(region_v1),.busy(ra_busy),
        .tiles_parsed(ra_tiles_parsed),.rout(ra_out),.ack(ra_ack),
        .dreq(ra_dreq),.dresp(ra_dresp));

    reg          ol_start; reg [26:0] ol_list_ptr;
    wire         ol_busy, ol_done;
    prim_out_t   ol_prim; prim_ack_t ol_ack;
    object_list_parser u_ol (.clk(clk),.reset(reset),.start(ol_start),
        .list_ptr(ol_list_ptr),.busy(ol_busy),.done(ol_done),
        .prim(ol_prim),.ack(ol_ack),.dreq(ol_dreq),.dresp(ol_dresp));

    reg              it_start; objlist_entry_t it_entry; entry_type_e it_etype;
    wire             it_busy;
    triangle_out_t   it_trio; triangle_ack_t it_ack;
    isp_primitive_iterator u_it (.clk(clk),.reset(reset),.start(it_start),
        .intensity_shadow(regs.fpu_shad_scale.intensity_shadow),
        .param_base(param_base),.entry_type(it_etype),.entry(it_entry),.busy(it_busy),
        .trio(it_trio),.ack(it_ack),.dreq(pr_dreq),.dresp(pr_dresp));

    // -------------------- depth/tag tile + color buffer + framebuffer --------------------
    localparam integer TILE_W = 32, TILE_H = 32;
    reg [31:0] dt_depth [0:TILE_W*TILE_H-1];   // invW depth per tile pixel
    reg [31:0] dt_tag   [0:TILE_W*TILE_H-1];   // CoreTag per tile pixel
    reg [31:0] col_buf  [0:TILE_W*TILE_H-1];   // shaded ARGB per tile pixel

    (* verilator public_flat_rw *) reg [31:0] fb [0:640*480-1];  // shaded colors

    // -------------------- int -> float (tile origin, 0..2016) --------------------
    function automatic [31:0] i2f(input [15:0] v);
        integer i, p; reg [38:0] m;
        begin
            p = -1;
            for (i = 0; i < 16; i = i + 1) if (v[i]) p = i;
            if (p < 0) i2f = 32'd0;
            else begin
                m   = {23'd0, v} << (23 - p);
                i2f = {1'b0, 8'(127 + p), m[22:0]};
            end
        end
    endfunction

    // -------------------- ISP triangle setup (as tile_engine_top) --------------------
    // isp_word_su/su_tag feed the SETUP stage (triangle N+1); isp_word/tri_tag are
    // the ACTIVE raster triangle (N) used by the depth compare / tag write.
    reg         isp_start;
    reg  [31:0] isp_word, isp_word_su;
    reg  [31:0] t_x1,t_y1,t_z1, t_x2,t_y2,t_z2, t_x3,t_y3,t_z3;
    reg  [31:0] t_xbase, t_ybase;
    reg  [31:0] tri_tag, su_tag;          // active / setup triangle CoreTag
    wire        isp_done, isp_sgn_neg, isp_cull;
    wire [4:0]  w_bx0, w_bx1, w_by0, w_by1;   // tile-local bbox from setup
    wire [31:0] w_dx12,w_dx23,w_dx31,w_dx41, w_dy12,w_dy23,w_dy31,w_dy41;
    wire [31:0] w_c1,w_c2,w_c3,w_c4, w_ddx,w_ddy,w_cinvw;

    isp_setup_min u_isp (
        .clk(clk), .reset(reset), .start(isp_start), .done(isp_done),
        .isp_word(isp_word_su),
        .x1(t_x1), .y1(t_y1), .z1(t_z1),
        .x2(t_x2), .y2(t_y2), .z2(t_z2),
        .x3(t_x3), .y3(t_y3), .z3(t_z3),
        .xbase(t_xbase), .ybase(t_ybase),
        .sgn_neg(isp_sgn_neg), .cull(isp_cull),
        .dx12(w_dx12), .dx23(w_dx23), .dx31(w_dx31), .dx41(w_dx41),
        .dy12(w_dy12), .dy23(w_dy23), .dy31(w_dy31), .dy41(w_dy41),
        .c1(w_c1), .c2(w_c2), .c3(w_c3), .c4(w_c4),
        .ddx_invw(w_ddx), .ddy_invw(w_ddy), .c_invw(w_cinvw),
        .bx0(w_bx0), .bx1(w_bx1), .by0(w_by0), .by1(w_by1)
    );

    // latched setup results (rasterizer consumes these)
    reg [31:0] isp_dx12,isp_dx23,isp_dx31,isp_dx41;
    reg [31:0] isp_dy12,isp_dy23,isp_dy31,isp_dy41;
    reg [31:0] isp_c1,isp_c2,isp_c3,isp_c4;
    reg [31:0] isp_ddx_invw, isp_ddy_invw, isp_c_invw;

    // -------------------- ISP rasterize (as tile_engine_top) --------------------
    // 8 depth lanes/clock, matching the real FPGA (32 lanes is DSP-heavy). Sim
    // models the same 8 lanes so cycle counts reflect hardware.
    localparam integer RAS_LANES = 8;
    reg  [4:0]  ras_y, ras_x;
    reg  [4:0]  rbx0, rbx1, rby1;   // active bbox sweep bounds (chunk-aligned x)
    // combinational: issue a chunk every raster-sweep cycle, in phase with ras_x/y
    // (a registered pulse lags one cycle -> pairs with the advanced ras_x and
    //  drops the first chunk of every tile).
    wire        ras_in_valid = (rs_st == RS_RAS);
    wire        ras_out_valid;
    wire [RAS_LANES-1:0]    ras_inside;
    wire [32*RAS_LANES-1:0] ras_invw_flat;
    function [31:0] ras_invw(input integer lane);
        ras_invw = ras_invw_flat[32*lane +: 32];
    endfunction

    wire [4:0] ras_ox, ras_oy;     // coords echoed with the result chunk
    isp_raster_line #(.LANES(RAS_LANES)) u_line (
        .clk(clk), .reset(reset),
        .in_valid(ras_in_valid), .y(ras_y), .x_base(ras_x),
        .c1(isp_c1), .c2(isp_c2), .c3(isp_c3), .c4(isp_c4),
        .dx12(isp_dx12),.dx23(isp_dx23),.dx31(isp_dx31),.dx41(isp_dx41),
        .dy12(isp_dy12),.dy23(isp_dy23),.dy31(isp_dy31),.dy41(isp_dy41),
        .ddx(isp_ddx_invw),.ddy(isp_ddy_invw),.c_invw(isp_c_invw),
        .out_valid(ras_out_valid),
        .inside_mask(ras_inside),
        .invw_flat(ras_invw_flat),
        .out_x(ras_ox), .out_y(ras_oy)
    );

    wire [2:0] depth_mode = isp_word[31:29];
    wire       zwrite_dis = isp_word[26];

    // per-lane refsw DepthMode compare at the RESULT chunk coords (streamed).
    wire [RAS_LANES-1:0] ras_pass;
    generate
        for (genvar gd = 0; gd < RAS_LANES; gd = gd + 1) begin : dcmp
            isp_depth_cmp u_cmp (
                .peel(1'b0), .tag(32'h0), .zb2(32'h0), .pb(32'h0), .pb2(32'h0),
                .valid(1'b0), .more(),
                .mode(depth_mode),
                .nw  (ras_invw_flat[32*gd +: 32]),
                .zb  (dt_depth[{ras_oy, ras_ox + 5'(gd)}]),
                .pass(ras_pass[gd]));
        end
    endgenerate

    // ==================================================================
    // TSP plane cache: 64 entries, keyed by the FULL CoreTag word.
    // cache_bypass is deliberately IGNORED (always cache). Miss -> param
    // fetch (GetFpuEntry) + tsp_setup_min; per entry: 10 planes {ddx,ddy,c}
    // + the record's isp/tsp/tcw words.
    // ==================================================================
    localparam integer PC_N = 64;
    reg            pc_valid [0:PC_N-1];
    reg [31:0]     pc_tag   [0:PC_N-1];
    reg [31:0]     pc_isp   [0:PC_N-1];
    reg [31:0]     pc_tsp   [0:PC_N-1];
    reg [31:0]     pc_tcw   [0:PC_N-1];
    reg [31:0]     pc_ddx   [0:PC_N-1][0:9];
    reg [31:0]     pc_ddy   [0:PC_N-1][0:9];
    reg [31:0]     pc_c     [0:PC_N-1][0:9];

    // current entry (feeds tsp_shade)
    reg [31:0] cur_isp, cur_tsp, cur_tcw;
    reg [31:0] cur_ddx [0:9];
    reg [31:0] cur_ddy [0:9];
    reg [31:0] cur_c   [0:9];

    // shade-pass state
    reg [9:0]  shp;           // current tile pixel 0..1023
    reg [31:0] sh_tag;        // that pixel's CoreTag
    reg [31:0] sh_invw;       // that pixel's depth-buffer invW
    // slot: param_offs low bits XOR tag_offset (strip triangles share param_offs)
    wire [5:0] sh_slot = sh_tag[8:3] ^ {3'b000, sh_tag[2:0]};
    // CoreTag fields (ISP_BACKGND_T layout)
    wire [20:0] sh_po   = sh_tag[23:3];
    wire [2:0]  sh_skip = sh_tag[26:24];
    wire [2:0]  sh_toff = sh_tag[2:0];
    wire        sh_two_vol = sh_tag[27] & ~regs.fpu_shad_scale.intensity_shadow;
    wire [4:0]  sh_stride_w = 5'd3 + sh_skip * (sh_two_vol ? 5'd2 : 5'd1);
    wire [26:0] sh_stride_b = {sh_stride_w, 2'b00};

    // ---- 32-bit word reader: DIRECT DDR, 8-word sliding-window (as object_list_parser) ----
    reg  [26:0] f_addr; reg f_go; reg [31:0] f_word; reg f_word_v; reg [2:0] f_sel;
    reg  [255:0] tw0; reg [21:0] t0_tag; reg t0_v;
    reg  [255:0] tw1; reg [21:0] t1_tag; reg t1_v;
    reg          tpend; reg [21:0] tline; reg [2:0] tsel;

    localparam TF_IDLE=2'd0, TF_MISS=2'd1, TF_FILL=2'd2;
    reg [1:0]   tfst;
    reg [21:0]  tf_line; reg tf_is_pf; reg [2:0] tf_beat; reg [255:0] tf_acc;
    wire        tf_bank    = tf_line[17];
    wire [19:0] tf_wofs_b  = {tf_line[16:0], 3'b000};
    wire [28:0] tf_base_wd = {9'b0, tf_wofs_b};
    wire [31:0] tf_half    = tf_bank ? ts_dresp.dout[63:32] : ts_dresp.dout[31:0];

    reg        ts_rd_r; reg [28:0] ts_addr_r; reg [7:0] ts_burst_r;
    assign ts_dreq.rd    = ts_rd_r;
    assign ts_dreq.addr  = ts_addr_r;
    assign ts_dreq.burst = ts_burst_r;

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
        TF_MISS: if (!ts_dresp.busy) begin
            ts_rd_r    <= 1'b1;
            ts_addr_r  <= {4'b0011, tf_base_wd[24:0]};
            ts_burst_r <= 8'd8;
            tfst       <= TF_FILL;
        end
        TF_FILL: if (ts_dresp.dready) begin
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

    // fetched vertices (3) - decode_pvr_vertex fields
    reg [31:0] fv_x[0:2], fv_y[0:2], fv_z[0:2];
    reg [31:0] fv_u[0:2], fv_v[0:2], fv_col[0:2], fv_ofs[0:2];
    reg [1:0]  fv_i;           // vertex being fetched 0..2
    reg [2:0]  fv_fld;         // field sequencer (see FV_* below)
    reg [26:0] f_rec, f_vtx;   // record base / current vertex base byte addr
    reg [26:0] f_ptr;          // running word pointer

    // decoded isp flags of the record being fetched
    wire f_texture = cur_isp[ISP_TEXTURE_BIT];
    wire f_offset  = cur_isp[ISP_OFFSET_BIT];
    wire f_gouraud = cur_isp[ISP_GOURAUD_BIT];
    wire f_uv16    = cur_isp[ISP_UV16_BIT];

    // -------------------- TSP setup (plane producer) --------------------
    reg         tsp_start;
    wire        tsp_done, tsp_pvalid;
    wire [3:0]  tsp_pidx;
    wire [31:0] tsp_pddx, tsp_pddy, tsp_pc;
    tsp_setup_min u_tsp (
        .clk(clk), .reset(reset), .start(tsp_start), .done(tsp_done),
        .gouraud(f_gouraud), .texture(f_texture), .offset(f_offset),
        .x1(fv_x[0]),.y1(fv_y[0]),.z1(fv_z[0]),
        .x2(fv_x[1]),.y2(fv_y[1]),.z2(fv_z[1]),
        .x3(fv_x[2]),.y3(fv_y[2]),.z3(fv_z[2]),
        .xbase(t_xbase), .ybase(t_ybase),
        .u1(fv_u[0]),.v1(fv_v[0]),.u2(fv_u[1]),.v2(fv_v[1]),.u3(fv_u[2]),.v3(fv_v[2]),
        .col1(fv_col[0]),.col2(fv_col[1]),.col3(fv_col[2]),
        .ofs1(fv_ofs[0]),.ofs2(fv_ofs[1]),.ofs3(fv_ofs[2]),
        .plane_valid(tsp_pvalid), .plane_idx(tsp_pidx),
        .o_ddx(tsp_pddx), .o_ddy(tsp_pddy), .o_c(tsp_pc)
    );

    // -------------------- TSP shade (FULLY PIPELINED, 1 pixel/clock) --------------------
    // The producer FSM presents a resolved pixel (planes from the plane cache +
    // its tsp/tcw/isp flags) on pp_in_valid; tsp_shade_pp streams results out on
    // pp_out_valid, carrying the pixel index (0..1023) as the id so the consumer
    // can write col_buf[out_id]. pp_stall (any texel fetcher busy) freezes the
    // pipe; the producer holds while stalled.
    reg          pp_in_valid;
    reg  [9:0]   pp_in_id;       // = pixel index shp
    reg  [4:0]   pp_px, pp_py;
    reg  [31:0]  pp_invw;
    reg  [31:0]  pp_tsp, pp_tcw; reg pp_ptex, pp_pofs;
    reg  [31:0]  pp_ddx [0:9];
    reg  [31:0]  pp_ddy [0:9];
    reg  [31:0]  pp_c   [0:9];
    wire         pp_stall;
    wire         pp_out_valid;
    wire [9:0]   pp_out_id;
    wire [31:0]  pp_out_argb;

    tsp_shade_pp #(.IDW(10)) u_shade (
        .clk(clk),.reset(reset),
        .in_valid(pp_in_valid),.in_id(pp_in_id),.px(pp_px),.py(pp_py),.invw_in(pp_invw),
        .in_ddx(pp_ddx),.in_ddy(pp_ddy),.in_c(pp_c),
        .tsp(pp_tsp),.tcw(pp_tcw),.text_ctrl(regs.text_control[4:0]),
        .pp_texture(pp_ptex),.pp_offset(pp_pofs),
        .out_valid(pp_out_valid),.out_id(pp_out_id),.out_argb(pp_out_argb),
        .stall(pp_stall),
        .tc_req(pp_tc_req),.tc_resp(pp_tc_resp),.vq_req(pp_vq_req),.vq_resp(pp_vq_resp));

    // -------------------- orchestration FSM --------------------
    // Decoupled producer / consumer (as frontend_isp_tb_top): the region->objlist
    // path pushes OL entries into an 8-deep entry FIFO (eq); a concurrent iterator-
    // consumer (it_cst) drains eq, runs the iterator, and pushes triangles into an
    // 8-deep triangle FIFO (fq); a concurrent setup||raster consumer pops fq and
    // rasterizes into the tile buffer. BARRIER: at every region-state boundary the
    // producer waits for both FIFOs empty AND the consumer idle so CLEAR/OP/PT/TR/
    // FLUSH stay strictly ordered on the shared tile depth/tag buffer.
    localparam S_IDLE=0, S_RA=1, S_STATE=2,
               S_OL_RUN=4,                 // producer: OL entries -> entry FIFO
               S_RA_ACK=9, S_DONE=10,
               S_DRAIN=11,                 // barrier: wait consumer idle + FIFOs empty
               // shade pass (FLUSH): producer walks pixels, feeds tsp_shade_pp
               SH_PIX=16, SH_LOOK=17,
               FH_ISP=18, FH_ISPW=19, FH_TSPW=20, FH_TCWW=21,
               FV_RD=22, FV_W=23,
               TSP_RUN=24, SH_PRESENT=25, SH_DRAIN=26, SH_OUT=27;
    reg [4:0] st;

    // consumer sub-FSMs
    localparam SU_IDLE=0, SU_RUN=1;              reg su_st;
    localparam RS_IDLE=0, RS_RAS=1, RS_DRAIN=2;  reg [1:0] rs_st;

    // ---- entry FIFO (object_list_parser -> iterator), depth 8 ----
    localparam integer EQ_N = 8;
    reg [1:0]       eq_etype [0:EQ_N-1];
    objlist_entry_t eq_entry [0:EQ_N-1];
    reg [3:0] eq_head, eq_tail; reg [4:0] eq_count;
    reg       eq_push, eq_pop;
    wire eq_full  = (eq_count == EQ_N);
    wire eq_empty = (eq_count == 0);
    localparam IT_IDLE=0, IT_RUN=1; reg it_cst;   // iterator-consumer FSM

    // ---- triangle FIFO (producer -> consumer), depth 8 ----
    localparam integer FIFO_N = 8;
    reg [31:0] fq_isp [0:FIFO_N-1];
    reg [31:0] fq_tag [0:FIFO_N-1];
    reg [31:0] fq_x1[0:FIFO_N-1], fq_y1[0:FIFO_N-1], fq_z1[0:FIFO_N-1];
    reg [31:0] fq_x2[0:FIFO_N-1], fq_y2[0:FIFO_N-1], fq_z2[0:FIFO_N-1];
    reg [31:0] fq_x3[0:FIFO_N-1], fq_y3[0:FIFO_N-1], fq_z3[0:FIFO_N-1];
    reg [3:0]  fq_head, fq_tail;   // ring indices 0..FIFO_N-1 (0..7)
    reg [4:0]  fq_count;
    reg        fifo_push, fifo_pop; // 1-cycle intents (reconciled into fq_count)
    wire fq_full  = (fq_count == FIFO_N);
    wire fq_empty = (fq_count == 0);

    reg        pend_valid, prim_seen;
    reg [31:0] pend_dx12,pend_dx23,pend_dx31,pend_dx41;
    reg [31:0] pend_dy12,pend_dy23,pend_dy31,pend_dy41;
    reg [31:0] pend_c1,pend_c2,pend_c3,pend_c4;
    reg [31:0] pend_ddx,pend_ddy,pend_cinvw, pend_isp, pend_tag;
    reg [4:0]  pend_bx0,pend_bx1,pend_by0,pend_by1;  // tile-local bounding box

    // consumer fully idle: entry FIFO empty, iterator idle & not busy, setup +
    // raster + pend handoff all idle.
    wire consumer_idle = eq_empty && (it_cst==IT_IDLE) && !it_busy
                       && (su_st==SU_IDLE) && (rs_st==RS_IDLE) && !pend_valid;

    // shade pass pixel accounting: producer index shp, consumer count sh_out_n
    integer sh_out_n;
    // streamed rasterizer: chunks in flight (issued but not yet consumed)
    localparam integer NCHUNK = (TILE_W/RAS_LANES) * TILE_H;
    integer ras_inflight;

    // vertex field ids for FV_RD/FV_W
    localparam [2:0] FLD_X=0, FLD_Y=1, FLD_Z=2, FLD_UV16=3, FLD_U=4, FLD_V=5,
                     FLD_COL=6, FLD_OFS=7;

    integer tri_count, cull_count, miss_count, hit_count, tri_seen;
    reg [5:0] cur_tx, cur_ty;      // latched tile coords (stable during lists)
    integer i, l, j;
    integer px, py;

    always @(posedge clk) begin
        if (reset) begin
            st<=S_IDLE; done<=0; ra_start<=0; ol_start<=0; it_start<=0;
            isp_start<=0; tsp_start<=0; pp_in_valid<=0; f_go<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            tri_count<=0; cull_count<=0; miss_count<=0; hit_count<=0; tri_seen<=0;
            sh_out_n<=0; ras_inflight<=0;
            su_st<=SU_IDLE; rs_st<=RS_IDLE;
            pend_valid<=0; prim_seen<=0;
            fq_head<=0; fq_tail<=0; fq_count<=0;
            eq_head<=0; eq_tail<=0; eq_count<=0; it_cst<=IT_IDLE;
            for (i = 0; i < PC_N; i = i + 1) pc_valid[i] = 1'b0;
        end else begin
            done<=0; ra_start<=0; ol_start<=0; it_start<=0;
            isp_start<=0; tsp_start<=0; pp_in_valid<=0; f_go<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            eq_push = 1'b0;

            // -------- streamed rasterizer CONSUMER (runs every cycle) --------
            if (ras_out_valid) begin
                for (l = 0; l < RAS_LANES; l = l + 1) begin
                    /* verilator lint_off WIDTH */
                    if (ras_inside[l] && ras_pass[l]) begin
                        if (!zwrite_dis)
                            dt_depth[{27'd0,ras_oy}*TILE_W + {27'd0,ras_ox} + l] = ras_invw(l);
                        dt_tag[{27'd0,ras_oy}*TILE_W + {27'd0,ras_ox} + l] = tri_tag;
                    end
                    /* verilator lint_on WIDTH */
                end
            end
            ras_inflight <= ras_inflight + (ras_in_valid ? 1 : 0) - (ras_out_valid ? 1 : 0);

            // -------- shade pipeline CONSUMER (runs every cycle) --------
            // a fresh result is present when out_valid && !stall (out_valid holds
            // through a stall since the whole pipe is frozen).
            if (pp_out_valid && !pp_stall) begin
                col_buf[pp_out_id] = pp_out_argb;
                sh_out_n <= sh_out_n + 1;
            end

            case (st)
            S_IDLE: if (go) begin ra_start<=1; st<=S_RA; end

            S_RA: begin
                if (ra_tiles_parsed) st<=S_DONE;
                else if (ra_out.list_ready) begin
                    cur_tx <= ra_out.tile_x; cur_ty <= ra_out.tile_y;
                    st<=S_STATE;
                end
            end

            S_STATE: begin
                // tile origin (floats) for both isp_setup and tsp_setup
                t_xbase <= i2f({10'd0, cur_tx} * 16'd32);
                t_ybase <= i2f({10'd0, cur_ty} * 16'd32);
                case (ra_out.state)
                // CLEAR touches the whole tile buffer: BARRIER first (consumer of
                // the previous state must be fully done).
                RSTATE_CLEAR: if (consumer_idle && fq_empty) begin
                    // as tile_engine_top TILE_CLEAR: {bg depth, bg CoreTag}
                    for (i = 0; i < TILE_W*TILE_H; i = i + 1) begin
                        dt_depth[i] = regs.isp_backgnd_d;
                        dt_tag[i]   = regs.isp_backgnd_t;
                    end
                    ra_ack.list_done <= 1'b1; st <= S_RA_ACK;
                end
                RSTATE_OP, RSTATE_PT, RSTATE_TR: begin
                    ol_list_ptr <= ra_out.list_ptr;
                    ol_start <= 1'b1;
                    st <= S_OL_RUN;
                end
                // FLUSH shades the whole tile buffer: BARRIER first.
                RSTATE_FLUSH: if (consumer_idle && fq_empty) begin
                    // shade every pixel of the tile (stream through tsp_shade_pp),
                    // then write out the colors.
                    // IMPORTANT: the plane cache is TILE-LOCAL - tsp_setup_min
                    // anchors the interpolation planes at this tile's origin
                    // (t_xbase/t_ybase). A cached tag from a PREVIOUS tile holds
                    // planes anchored at the wrong origin, so the cache MUST be
                    // invalidated at the start of every tile's shade pass.
                    for (i = 0; i < PC_N; i = i + 1) pc_valid[i] = 1'b0;
                    $display("[TILE %0d,%0d] shade+flush", cur_tx, cur_ty);
                    shp <= 10'd0; sh_out_n <= 0;
                    st <= SH_PIX;
                end
                default: begin ra_ack.list_done <= 1'b1; st <= S_RA_ACK; end
                endcase
            end

            // S_OL_RUN: PRODUCER - push each OL entry into the entry FIFO (eq) and
            // ack the OL parser so it decodes the next entry ahead. STRIP/TRI are
            // queued; QUAD is skipped. On list end (ol_done) -> BARRIER (S_DRAIN).
            // The iterator CONSUMER (it_cst) runs concurrently, popping eq into the
            // triangle FIFO independent of `st`.
            S_OL_RUN: begin
                if (ol_done) st <= S_DRAIN;
                else if (ol_prim.entry_ready && !ol_ack.entry_done) begin
                    if (ol_prim.entry_type == ENT_STRIP ||
                        ol_prim.entry_type == ENT_TRI) begin
                        if (!eq_full) begin
                            eq_etype[eq_tail[2:0]] <= ol_prim.entry_type;
                            eq_entry[eq_tail[2:0]] <= ol_prim.entry;
                            eq_tail <= (eq_tail==EQ_N-1) ? 4'd0 : eq_tail+4'd1;
                            eq_push = 1'b1;
                            ol_ack.entry_done <= 1'b1;
                        end
                    end else begin
                        ol_ack.entry_done <= 1'b1;   // quad: skip (ack, don't queue)
                    end
                end
            end

            // BARRIER at list end: wait for the entry FIFO + iterator + triangle
            // FIFO + setup/raster to all drain before letting region advance.
            S_DRAIN: if (fq_empty && consumer_idle) begin
                ra_ack.list_done <= 1'b1;
                st <= S_RA_ACK;
            end

            // ---------------- shade pass (FLUSH) ----------------
            // PRODUCER: resolve pixel shp's planes (plane cache; miss = fetch +
            // tsp_setup) then present it to the pipelined shader. The CONSUMER
            // (top of the always block) writes results into col_buf by id.
            SH_PIX: begin
                sh_tag  <= dt_tag[shp];
                sh_invw <= dt_depth[shp];
                st <= SH_LOOK;
            end

            // plane-cache lookup by the full tag (cache_bypass ignored)
            SH_LOOK: begin
                if (pc_valid[sh_slot] && pc_tag[sh_slot] == sh_tag) begin
                    hit_count <= hit_count + 1;
                    cur_isp = pc_isp[sh_slot];
                    cur_tsp = pc_tsp[sh_slot];
                    cur_tcw = pc_tcw[sh_slot];
                    for (j = 0; j < 10; j = j + 1) begin
                        cur_ddx[j] = pc_ddx[sh_slot][j];
                        cur_ddy[j] = pc_ddy[sh_slot][j];
                        cur_c[j]   = pc_c[sh_slot][j];
                    end
                    st <= SH_PRESENT;
                end else begin
                    miss_count <= miss_count + 1;
                    f_rec <= param_base + {4'd0, sh_po, 2'b00};
                    st <= FH_ISP;
                end
            end

            // ---- param record fetch (refsw GetFpuEntry / decode_pvr_vertices) ----
            FH_ISP:  begin f_addr<=f_rec; f_go<=1'b1; st<=FH_ISPW; end
            FH_ISPW: if (f_word_v) begin
                        cur_isp = f_word;
                        f_addr<=f_rec+27'd4; f_go<=1'b1; st<=FH_TSPW;
                    end
            FH_TSPW: if (f_word_v) begin
                        cur_tsp = f_word;
                        f_addr<=f_rec+27'd8; f_go<=1'b1; st<=FH_TCWW;
                    end
            FH_TCWW: if (f_word_v) begin
                        cur_tcw = f_word;
                        // first vertex = tag_offset (in-order, refsw GetFpuEntry)
                        f_vtx <= f_rec + (sh_two_vol ? 27'd20 : 27'd12)
                                       + {22'd0, sh_toff} * sh_stride_b;
                        fv_i  <= 2'd0;
                        fv_fld<= FLD_X;
                        // zero all fields (disabled planes/attrs read as 0)
                        for (j = 0; j < 3; j = j + 1) begin
                            fv_u[j]=32'd0; fv_v[j]=32'd0; fv_col[j]=32'd0; fv_ofs[j]=32'd0;
                        end
                        st <= FV_RD;
                    end

            // issue the read for the current field of the current vertex
            FV_RD: begin
                case (fv_fld)
                FLD_X:    f_ptr = f_vtx;
                FLD_Y:    f_ptr = f_vtx + 27'd4;
                FLD_Z:    f_ptr = f_vtx + 27'd8;
                FLD_UV16,
                FLD_U:    f_ptr = f_vtx + 27'd12;
                FLD_V:    f_ptr = f_vtx + 27'd16;
                // col follows xyz+uv; ofs follows col
                FLD_COL:  f_ptr = f_vtx + 27'd12
                                + (f_texture ? (f_uv16 ? 27'd4 : 27'd8) : 27'd0);
                default:  f_ptr = f_vtx + 27'd16
                                + (f_texture ? (f_uv16 ? 27'd4 : 27'd8) : 27'd0); // FLD_OFS
                endcase
                f_addr <= f_ptr; f_go <= 1'b1; st <= FV_W;
            end

            FV_W: if (f_word_v) begin
                case (fv_fld)
                FLD_X: begin fv_x[fv_i] = f_word; fv_fld <= FLD_Y;  st <= FV_RD; end
                FLD_Y: begin fv_y[fv_i] = f_word; fv_fld <= FLD_Z;  st <= FV_RD; end
                FLD_Z: begin
                    fv_z[fv_i] = f_word;
                    if (f_texture) begin
                        fv_fld <= f_uv16 ? FLD_UV16 : FLD_U; st <= FV_RD;
                    end else begin fv_fld <= FLD_COL; st <= FV_RD; end
                end
                FLD_UV16: begin
                    // DC 16-bit UV: each half is the top 16 bits of an f32
                    fv_u[fv_i] = {f_word[31:16], 16'd0};
                    fv_v[fv_i] = {f_word[15:0],  16'd0};
                    fv_fld <= FLD_COL; st <= FV_RD;
                end
                FLD_U: begin fv_u[fv_i] = f_word; fv_fld <= FLD_V;   st <= FV_RD; end
                FLD_V: begin fv_v[fv_i] = f_word; fv_fld <= FLD_COL; st <= FV_RD; end
                FLD_COL: begin
                    fv_col[fv_i] = f_word;
                    if (f_offset) begin fv_fld <= FLD_OFS; st <= FV_RD; end
                    else if (fv_i == 2'd2) begin
                        // all 3 vertices in: zero the planes (disabled attrs
                        // stay 0) and kick tsp_setup_min
                        for (j = 0; j < 10; j = j + 1) begin
                            cur_ddx[j]=32'd0; cur_ddy[j]=32'd0; cur_c[j]=32'd0;
                            pc_ddx[sh_slot][j]=32'd0; pc_ddy[sh_slot][j]=32'd0;
                            pc_c[sh_slot][j]=32'd0;
                        end
                        tsp_start <= 1'b1; st <= TSP_RUN;
                    end
                    else begin fv_i <= fv_i + 2'd1; f_vtx <= f_vtx + sh_stride_b;
                               fv_fld <= FLD_X; st <= FV_RD; end
                end
                default: begin // FLD_OFS
                    fv_ofs[fv_i] = f_word;
                    if (fv_i == 2'd2) begin
                        for (j = 0; j < 10; j = j + 1) begin
                            cur_ddx[j]=32'd0; cur_ddy[j]=32'd0; cur_c[j]=32'd0;
                            pc_ddx[sh_slot][j]=32'd0; pc_ddy[sh_slot][j]=32'd0;
                            pc_c[sh_slot][j]=32'd0;
                        end
                        tsp_start <= 1'b1; st <= TSP_RUN;
                    end
                    else begin fv_i <= fv_i + 2'd1; f_vtx <= f_vtx + sh_stride_b;
                               fv_fld <= FLD_X; st <= FV_RD; end
                end
                endcase
            end

            // wait for tsp_setup_min; planes stream into cur_* AND the cache
            // via the tsp_pvalid capture below; on done, commit the cache meta.
            TSP_RUN: if (tsp_done) begin
                pc_valid[sh_slot] = 1'b1;
                pc_tag[sh_slot]   = sh_tag;
                pc_isp[sh_slot]   = cur_isp;
                pc_tsp[sh_slot]   = cur_tsp;
                pc_tcw[sh_slot]   = cur_tcw;
                st <= SH_PRESENT;
            end

            // present pixel shp to the pipelined shader. Hold while the pipe is
            // stalled (a texel miss). The CONSUMER at the top drains col_buf.
            SH_PRESENT: if (!pp_stall) begin
                pp_in_valid <= 1'b1;
                pp_in_id    <= shp;
                pp_px       <= shp[4:0];
                pp_py       <= shp[9:5];
                pp_invw     <= sh_invw;
                pp_tsp      <= cur_tsp;
                pp_tcw      <= cur_tcw;
                pp_ptex     <= cur_isp[ISP_TEXTURE_BIT];
                pp_pofs     <= cur_isp[ISP_OFFSET_BIT];
                for (j = 0; j < 10; j = j + 1) begin
                    pp_ddx[j] <= cur_ddx[j];
                    pp_ddy[j] <= cur_ddy[j];
                    pp_c[j]   <= cur_c[j];
                end
                if (shp == 10'd1023) st <= SH_DRAIN;
                else begin shp <= shp + 10'd1; st <= SH_PIX; end
            end

            // all 1024 pixels presented: wait for the pipeline to drain, then
            // write the shaded tile to the 640x480 fb.
            SH_DRAIN: if (sh_out_n >= 1024) begin
                for (i = 0; i < TILE_W*TILE_H; i = i + 1) begin
                    /* verilator lint_off WIDTH */
                    px = {26'd0, cur_tx}*32 + (i % TILE_W);
                    py = {26'd0, cur_ty}*32 + (i / TILE_W);
                    /* verilator lint_on WIDTH */
                    if (px < 640 && py < 480)
                        fb[py*640 + px] = col_buf[i];
                end
                ra_ack.list_done <= 1'b1; st <= S_RA_ACK;
            end

            S_RA_ACK: st <= S_RA;

            S_DONE: begin
                $display("=== done: %0d triangles rasterized, %0d culled, tsp$ %0d hits / %0d misses ===",
                         tri_count, cull_count, hit_count, miss_count);
                done<=1'b1; st<=S_IDLE;
            end
            default: st<=S_IDLE;
            endcase

            // ======== ITERATOR CONSUMER: entry FIFO -> iterator -> tri FIFO ========
            // Runs independent of `st`. IT_IDLE: pop an entry, start the iterator.
            // IT_RUN: drain the iterator's triangles into the triangle FIFO (stall
            // when full); on prim_done + iterator idle, return to IT_IDLE.
            eq_pop    = 1'b0;
            fifo_push = 1'b0;
            case (it_cst)
            IT_IDLE: if (!eq_empty && !it_busy && !it_start) begin
                it_entry <= eq_entry[eq_head[2:0]];
                it_etype <= entry_type_e'(eq_etype[eq_head[2:0]]);
                it_start <= 1'b1;
                prim_seen <= 1'b0;
                eq_head <= (eq_head==EQ_N-1) ? 4'd0 : eq_head+4'd1;
                eq_pop  = 1'b1;
                it_cst  <= IT_RUN;
            end
            IT_RUN: begin
                if (it_trio.prim_done) prim_seen <= 1'b1;
                if (it_trio.triangle_ready && !fq_full && !it_ack.triangle_done) begin
                    fq_isp[fq_tail[2:0]] <= it_trio.isp;
                    fq_tag[fq_tail[2:0]] <= it_trio.tag;
                    fq_x1[fq_tail[2:0]]<=it_trio.v0.x; fq_y1[fq_tail[2:0]]<=it_trio.v0.y; fq_z1[fq_tail[2:0]]<=it_trio.v0.z;
                    fq_x2[fq_tail[2:0]]<=it_trio.v1.x; fq_y2[fq_tail[2:0]]<=it_trio.v1.y; fq_z2[fq_tail[2:0]]<=it_trio.v1.z;
                    fq_x3[fq_tail[2:0]]<=it_trio.v2.x; fq_y3[fq_tail[2:0]]<=it_trio.v2.y; fq_z3[fq_tail[2:0]]<=it_trio.v2.z;
                    it_ack.triangle_done <= 1'b1;   // advance iterator to next tri
                    fq_tail  <= (fq_tail==FIFO_N-1) ? 4'd0 : fq_tail+4'd1;
                    fifo_push = 1'b1;
                    tri_seen <= tri_seen + 1;
                    if (tri_seen % 100 == 0)
                        $display("[TILE %0d,%0d] TRI %0d tag=%08h isp=%08h",
                            cur_tx, cur_ty, tri_seen, it_trio.tag, it_trio.isp);
                end
                if (prim_seen && !it_busy) it_cst <= IT_IDLE;   // entry finished
            end
            endcase

            // ================= CONSUMER: FIFO -> setup -> raster =================
            // ---- SETUP: pop FIFO -> isp_setup_min -> pend_* ----
            fifo_pop = 1'b0;
            case (su_st)
            SU_IDLE: if (!fq_empty && !pend_valid) begin
                isp_word_su <= fq_isp[fq_head[2:0]]; su_tag <= fq_tag[fq_head[2:0]];
                t_x1<=fq_x1[fq_head[2:0]]; t_y1<=fq_y1[fq_head[2:0]]; t_z1<=fq_z1[fq_head[2:0]];
                t_x2<=fq_x2[fq_head[2:0]]; t_y2<=fq_y2[fq_head[2:0]]; t_z2<=fq_z2[fq_head[2:0]];
                t_x3<=fq_x3[fq_head[2:0]]; t_y3<=fq_y3[fq_head[2:0]]; t_z3<=fq_z3[fq_head[2:0]];
                fq_head <= (fq_head==FIFO_N-1) ? 4'd0 : fq_head+4'd1;
                fifo_pop = 1'b1;
                isp_start <= 1'b1;
                su_st <= SU_RUN;
            end
            SU_RUN: if (isp_done) begin
                if (isp_cull) begin
                    cull_count <= cull_count + 1;   // culled: don't fill pend
                end else begin
                    pend_dx12<=w_dx12;pend_dx23<=w_dx23;pend_dx31<=w_dx31;pend_dx41<=w_dx41;
                    pend_dy12<=w_dy12;pend_dy23<=w_dy23;pend_dy31<=w_dy31;pend_dy41<=w_dy41;
                    pend_c1<=w_c1;pend_c2<=w_c2;pend_c3<=w_c3;pend_c4<=w_c4;
                    pend_ddx<=w_ddx;pend_ddy<=w_ddy;pend_cinvw<=w_cinvw;
                    pend_isp<=isp_word_su; pend_tag<=su_tag;
                    pend_valid <= 1'b1;
                    // tile-local bounding box, computed by isp_setup_min.
                    pend_bx0 <= w_bx0; pend_bx1 <= w_bx1;
                    pend_by0 <= w_by0; pend_by1 <= w_by1;
                end
                su_st <= SU_IDLE;
            end
            endcase

            // ---- RASTER: pend_* -> active planes -> BOUNDING-BOX sweep ----
            // Only sweep the chunks/rows the triangle's tile-local bbox covers.
            // x bounds are chunk-aligned (down to a RAS_LANES-wide chunk); rows go
            // by0..by1 inclusive. The rasterizer's inside-test still gates writes.
            case (rs_st)
            RS_IDLE: if (pend_valid) begin
                isp_dx12<=pend_dx12;isp_dx23<=pend_dx23;isp_dx31<=pend_dx31;isp_dx41<=pend_dx41;
                isp_dy12<=pend_dy12;isp_dy23<=pend_dy23;isp_dy31<=pend_dy31;isp_dy41<=pend_dy41;
                isp_c1<=pend_c1;isp_c2<=pend_c2;isp_c3<=pend_c3;isp_c4<=pend_c4;
                isp_ddx_invw<=pend_ddx;isp_ddy_invw<=pend_ddy;isp_c_invw<=pend_cinvw;
                isp_word<=pend_isp; tri_tag<=pend_tag;
                pend_valid<=1'b0;               // free the handoff for setup
                tri_count<=tri_count+1;
                // chunk-aligned x range + row range from the bbox
                rbx0 <= pend_bx0 & 5'(~(RAS_LANES-1));
                rbx1 <= pend_bx1 & 5'(~(RAS_LANES-1));
                rby1 <= pend_by1;
                ras_y <= pend_by0;
                ras_x <= pend_bx0 & 5'(~(RAS_LANES-1));
                rs_st <= RS_RAS;
            end
            RS_RAS: begin
                if (ras_x == rbx1) begin
                    ras_x <= rbx0;
                    if (ras_y == rby1) rs_st <= RS_DRAIN;
                    else ras_y <= ras_y + 5'd1;
                end else begin
                    ras_x <= ras_x + 5'(RAS_LANES);
                end
            end
            RS_DRAIN: if (ras_inflight==0 && !ras_in_valid && !ras_out_valid) rs_st<=RS_IDLE;
            endcase

            // ---- FIFO count maintenance (single update; push/pop may coincide) ----
            fq_count <= fq_count + (fifo_push ? 5'd1 : 5'd0) - (fifo_pop ? 5'd1 : 5'd0);
            eq_count <= eq_count + (eq_push  ? 5'd1 : 5'd0) - (eq_pop   ? 5'd1 : 5'd0);

            // plane stream capture (runs regardless of FSM state)
            if (tsp_pvalid) begin
                cur_ddx[tsp_pidx] = tsp_pddx;
                cur_ddy[tsp_pidx] = tsp_pddy;
                cur_c[tsp_pidx]   = tsp_pc;
                pc_ddx[sh_slot][tsp_pidx] = tsp_pddx;
                pc_ddy[sh_slot][tsp_pidx] = tsp_pddy;
                pc_c[sh_slot][tsp_pidx]   = tsp_pc;
            end
        end
    end
endmodule

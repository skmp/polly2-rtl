// peel_core - the layer-peeling tile render core, with the DDR controller and the
// framebuffer INJECTED as dependencies (ports). Contains: reg_file, the 6-client
// single-channel DDR arbiter, the data/texture caches, region/objlist/iterator
// parsers, ISP setup+raster, the pipelined TSP shade+blend, and the unified PT+TL
// peel FSM. The single 64-bit DDR read channel below the arbiter is exposed as
// ddr_req/ddr_resp; the shaded framebuffer is streamed out one pixel/cycle on fbw_*.
//
//   per pixel: tag -> plane-cache lookup (64-entry, keyed by the FULL 32-bit
//   CoreTag) miss: fetch param record (GetFpuEntry) + tsp_setup_min; hit: planes
//   from cache. tsp_shade_pp shades (textures via two tex_cache_4p over the shared
//   DDR channel), blend composites the layer, PT/TL peel back-to-front.
//
// Wrappers provide the DDR/fb backend:
//   frontend_tsp_lp_tb_top : faux DDR controller (behavioral vram[]) + fb[]  (sim)
//   mister_top             : real HPS Avalon ram1 read + framebuffer write  (synth)
//
module peel_core import tsp_pkg::*; (
    input             clk,
    input             reset,
    // register/command load (host writes the PVR reg dump before `go`)
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    input             go,             // 1-cycle: start rendering the region array
    output reg        done,           // 1-cycle: region array fully processed

    // ---- injected DDR read controller (single 64-bit channel below the arbiter) ----
    output ddr_rd_req_t  ddr_req,
    input  ddr_rd_resp_t ddr_resp,

    // ---- injected framebuffer write port (one 32-bit pixel per accepted cycle) ----
    output fb_wr_req_t   fbw_req,
    input  fb_wr_resp_t  fbw_resp
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

    // ==================== SINGLE SHARED DDR CHANNEL (arbiter) ====================
    // Real hardware (MiSTer) has ONE 64-bit DDR read channel. All six clients -
    // region array (ra), object list (ol), ISP param/vertex (pr), TSP param (ts),
    // and the two 4-read-port texture caches (tc data, vq codebook) - are
    // arbitrated onto the INJECTED single-channel DDR controller (ddr_req/ddr_resp;
    // one read in flight). Priority (high->low): tc, vq, ts, pr, ol, ra - shade-
    // critical clients win, geometry fills between. Per-client PENDING latch
    // captures each 1-cycle rd pulse so a request is never lost while the channel
    // is busy elsewhere. The controller (faux or real Avalon) owns latency+burst.
    ddr_rd_req_t  ra_dreq, ol_dreq, pr_dreq, ts_dreq;
    ddr_rd_resp_t ra_dresp, ol_dresp, pr_dresp, ts_dresp;
    ddr_rd_req_t  tex_dreq [0:1];      // [0]=tc data, [1]=vq codebook
    ddr_rd_resp_t tex_dresp [0:1];

    // 0=tc 1=vq 2=ts 3=pr 4=ol 5=ra (priority high->low)
    reg  [5:0]  pend;
    reg  [28:0] pa [0:5]; reg [7:0] pb [0:5];
    wire [5:0]  rd_pulse = { ra_dreq.rd, ol_dreq.rd, pr_dreq.rd, ts_dreq.rd,
                             tex_dreq[1].rd, tex_dreq[0].rd };
    wire [28:0] ca [0:5]; wire [7:0] cbv [0:5];
    assign ca[0]=tex_dreq[0].addr; assign cbv[0]=tex_dreq[0].burst;
    assign ca[1]=tex_dreq[1].addr; assign cbv[1]=tex_dreq[1].burst;
    assign ca[2]=ts_dreq.addr;     assign cbv[2]=ts_dreq.burst;
    assign ca[3]=pr_dreq.addr;     assign cbv[3]=pr_dreq.burst;
    assign ca[4]=ol_dreq.addr;     assign cbv[4]=ol_dreq.burst;
    assign ca[5]=ra_dreq.addr;     assign cbv[5]=ra_dreq.burst;

    wire       any_pend = |pend;
    wire [2:0] d_win = pend[0] ? 3'd0 : pend[1] ? 3'd1 : pend[2] ? 3'd2 :
                       pend[3] ? 3'd3 : pend[4] ? 3'd4 : 3'd5;
    // A read is in flight (d_busy) from when we grant until the last beat arrives.
    // d_beats counts remaining beats; the injected controller streams ddr_resp.
    reg        d_busy; reg [2:0] d_owner;
    reg [7:0]  d_beats;
    reg        d_issued;   // ddr_req.rd already pulsed for the current grant
    integer di;

    // drive the injected DDR controller: issue the granted read once, then wait
    // for `d_beats` dready beats. ddr_req.rd is a 1-cycle pulse (accepted when
    // !ddr_resp.busy). We assert it on grant and hold-until-accepted.
    assign ddr_req.rd    = d_busy && !d_issued;
    assign ddr_req.addr  = pa[d_owner];
    assign ddr_req.burst = d_beats;

    always @(posedge clk) begin
        if (reset) begin d_busy <= 1'b0; pend <= 6'd0; d_issued <= 1'b0; end
        else begin
            for (di=0; di<6; di=di+1)
                if (rd_pulse[di]) begin pend[di] <= 1'b1; pa[di] <= ca[di]; pb[di] <= cbv[di]; end
            if (!d_busy) begin
                if (any_pend) begin
                    d_busy   <= 1'b1; d_owner <= d_win;
                    d_beats  <= pb[d_win];
                    d_issued <= 1'b0;
                    pend[d_win] <= (rd_pulse[d_win]);  // clear grant (unless re-pulsed same cyc)
                end
            end else begin
                // hold ddr_req.rd until the controller accepts it
                if (ddr_req.rd && !ddr_resp.busy) d_issued <= 1'b1;
                // count returned beats; release the channel after the last
                if (ddr_resp.dready) begin
                    if (d_beats <= 8'd1) begin d_busy <= 1'b0; d_issued <= 1'b0; end
                    d_beats <= d_beats - 8'd1;
                end
            end
        end
    end
    // a client cannot issue while the channel is busy or it has a pending request
    assign tex_dresp[0].busy = d_busy || pend[0];
    assign tex_dresp[1].busy = d_busy || pend[1];
    assign ts_dresp.busy     = d_busy || pend[2];
    assign pr_dresp.busy     = d_busy || pend[3];
    assign ol_dresp.busy     = d_busy || pend[4];
    assign ra_dresp.busy     = d_busy || pend[5];
    assign tex_dresp[0].dout=ddr_resp.dout; assign tex_dresp[1].dout=ddr_resp.dout;
    assign ts_dresp.dout=ddr_resp.dout; assign pr_dresp.dout=ddr_resp.dout;
    assign ol_dresp.dout=ddr_resp.dout; assign ra_dresp.dout=ddr_resp.dout;
    assign tex_dresp[0].dready = ddr_resp.dready && (d_owner==3'd0);
    assign tex_dresp[1].dready = ddr_resp.dready && (d_owner==3'd1);
    assign ts_dresp.dready     = ddr_resp.dready && (d_owner==3'd2);
    assign pr_dresp.dready     = ddr_resp.dready && (d_owner==3'd3);
    assign ol_dresp.dready     = ddr_resp.dready && (d_owner==3'd4);
    assign ra_dresp.dready     = ddr_resp.dready && (d_owner==3'd5);

    // -------------------- caches --------------------
    // Region parser, OL parser, ISP iterator AND TSP param fetch all read DDR
    // directly (each with its own 8-word sliding-window line reader). No caches.

    // The 4 corner fetchers share ONE 4-read-port data cache + ONE 4-read-port VQ
    // cache (2x dual-port M10K each, full copy), replacing the 8 per-corner
    // tex_cache instances. Simultaneous same-line misses dedupe to one DDR read;
    // distinct-line misses serialize (the pipe stalls while any corner is busy).
    cache_req_t   pp_tc_req [0:3], pp_vq_req [0:3];
    cache_resp_t  pp_tc_resp[0:3], pp_vq_resp[0:3];
    tex_cache_4p_1c u_tc4 (.clk(clk),.reset(reset),.creq(pp_tc_req),.cresp(pp_tc_resp),
        .dreq(tex_dreq[0]),.dresp(tex_dresp[0]));
    tex_cache_4p_1c u_vq4 (.clk(clk),.reset(reset),.creq(pp_vq_req),.cresp(pp_vq_resp),
        .dreq(tex_dreq[1]),.dresp(tex_dresp[1]));

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

    // Prefetching iterator: streaming entry input (entry_valid/entry_ack) driven
    // from the entry FIFO head, ping-pong record buffers so the next record's DDR
    // burst overlaps the current record's triangle emit. The barrier gates on the
    // iterator's AUTHORITATIVE level busy (it_pf_busy), NOT a pulse-cleared reg -
    // the peel loop re-runs the OL list per pass; the iterator restarts simply by
    // having entries streamed into it again (idle -> busy as new entries arrive).
    wire             it_entry_valid, it_entry_ack, it_pf_busy;
    objlist_entry_t  it_entry; entry_type_e it_etype;   // combinational eq head
    triangle_out_t   it_trio; triangle_ack_t it_ack;
    isp_primitive_iterator_pf u_it (.clk(clk),.reset(reset),
        .intensity_shadow(regs.fpu_shad_scale.intensity_shadow),
        .param_base(param_base),
        .entry_valid(it_entry_valid),.entry_type(it_etype),.entry(it_entry),
        .entry_ack(it_entry_ack),.busy(it_pf_busy),
        .trio(it_trio),.ack(it_ack),.dreq(pr_dreq),.dresp(pr_dresp));

    // -------------------- depth/tag tile + color buffer + framebuffer --------------------
    // IMPROVEMENT #3 (APPLIED) - M10K banking of the tile buffers, ABSTRACTED into
    // dedicated buffer modules that OWN the RAM ports and ENFORCE the access pattern
    // (typed per-client request ports + a same-cycle single-driver assertion), rather
    // than leaving an inline port mux governed only by convention:
    //   * peel_tile_buffer (u_peel): the five peel depth/tag buffers packed into ONE
    //     129-bit x 8-bank tile_ram {valid, tag2, tag, depth2, depth} per lane. It
    //     owns the depth compare (isp_depth_cmp / isp_depth_cmp_lp) and the raster
    //     stage-A read / stage-B RMW, the shade single-pixel read, the CLEAR walk and
    //     the PeelBuffers RMW walk. Bank = x[2:0], addr = {y[4:0], x[4:3]}.
    //   * color_tile_buffer (u_col): col_buf as a single 1024x32 M10K. It owns the
    //     blend RMW (2-stage CA read / CB tsp_blend+write) and the FLUSH read.
    // The registered reads force the raster compare and the blend into 2-stage
    // pipelines and CLEAR/PeelBuffers into 128-chunk walks; the peel_core barriers
    // serialize the raster / shade / bulk phases so each buffer's single read+write
    // port is never contended. dt_pt stays a REGISTER array (1 bit x 1024, negligible
    // M10K, read combinationally by the blend alpha test).
    //
    // The 4-way streamed setup + 8-deep plane FIFO (#1), the prefetch iterator +
    // it_pf_busy barrier (#2), and the 1px/cycle combinational FLUSH (#4) are also
    // applied.
    localparam integer TILE_W = 32, TILE_H = 32;
    // Raster/tile-buffer lane count. The tile buffer is banked LANES-wide; the
    // per-bank chunk address is CHUNK_AW bits and the CLEAR/PeelBuffers walk runs
    // over NCHUNK chunks. (LANES=8 -> 7-bit addr, 128 chunks; 4 -> 8-bit, 256.)
    localparam integer RAS_LANES = 4;
    localparam integer NCHUNK   = (TILE_W/RAS_LANES) * TILE_H;   // chunks/tile
    localparam integer CHUNK_AW = $clog2(NCHUNK);                // per-bank addr width
    localparam [31:0] FLT_MAX = 32'h7F7FFFFF;  // refsw PeelBuffers depth clear value

    // dt_pt kept as a register array (see note above)
    reg        dt_pt [0:TILE_W*TILE_H-1];      // winning peel fragment came from PT list

    // ---- peel tile buffer control (typed ports; driven by the raster/shade/FSM) ----
    reg                    pb_ra_valid;         // (=ras_out_valid: stage-A read)
    reg                    pb_clr_valid;        // CLEAR walk write
    reg  [CHUNK_AW-1:0]    pb_clr_addr;
    reg                    pb_bufrd_valid;      // PeelBuffers read-ahead
    reg  [CHUNK_AW-1:0]    pb_bufrd_addr;
    reg                    pb_bufwr_valid;      // PeelBuffers delayed write
    reg  [CHUNK_AW-1:0]    pb_bufwr_addr;
    reg                    pb_shrd_valid;       // shade single-pixel read
    reg  [9:0]             pb_shrd_id;
    wire                   sh_valid_o;          // <- staged bit  (1-cyc after shrd)
    wire [31:0]            sh_tag_o, sh_depth_o;
    wire [RAS_LANES-1:0]   b_pass_lp;           // per-lane peel accept (for dt_pt)
    wire [RAS_LANES-1:0]   b_more;              // per-lane MoreToDraw

    // ---- color tile buffer control (typed ports) ----
    reg                    cb_ca_valid;         // blend stage CA read
    reg  [9:0]             cb_ca_id;
    reg                    cb_fl_valid;         // FLUSH read
    reg  [9:0]             cb_fl_id;
    wire [31:0]            col_rd_argb;         // registered read (dst / flush pixel)

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

    // -------------------- ISP triangle setup (4-way interleaved streamed) --------------------
    // isp_word/tri_tag are the ACTIVE raster triangle (popped from the plane FIFO
    // pq) used by the depth compare / tag write. The streamed setup accepts from the
    // tri FIFO (fq) head and retires planes into the 8-deep plane FIFO (pq).
    reg  [31:0] isp_word;                  // active (raster) triangle's isp
    reg  [31:0] t_xbase, t_ybase;
    reg  [31:0] tri_tag;                   // active (raster) triangle's CoreTag
    wire        isp_sgn_neg, isp_cull;
    wire [4:0]  w_bx0, w_bx1, w_by0, w_by1;   // tile-local bbox from setup
    wire [31:0] w_dx12,w_dx23,w_dx31,w_dx41, w_dy12,w_dy23,w_dy31,w_dy41;
    wire [31:0] w_c1,w_c2,w_c3,w_c4, w_ddx,w_ddy,w_cinvw;

    // Streaming setup interface: accept a triangle from the tri FIFO (fq) whenever
    // in_ready, retire one (out_valid) into the plane FIFO (pq) when out_ready.
    //   su_in_valid  : fq has a triangle AND pq has room (throttle at pq near-full)
    //   su_out_valid : retire; push non-culled planes into pq (out_ready = !pq_full)
    //   su_busy      : any slot in flight (barrier).
    wire        su_in_valid, su_in_ready, su_out_valid, su_busy;
    wire [31:0] su_out_tag, su_out_isp;
    // gate on fq_out_valid (the head entry is loaded in the output register), not
    // just !fq_empty: the M10K read that fills fq_out lags a pushed entry by a cycle.
    assign su_in_valid = fq_out_valid && (pq_count <= 5'd4);

    isp_setup_streamed u_isp (
        .clk(clk), .reset(reset),
        .in_valid(su_in_valid), .in_ready(su_in_ready),
        .isp_word(fq_out[FF_ISP +:32]), .in_tag(fq_out[FF_TAG +:32]),
        .x1(fq_out[FF_X1 +:32]), .y1(fq_out[FF_Y1 +:32]), .z1(fq_out[FF_Z1 +:32]),
        .x2(fq_out[FF_X2 +:32]), .y2(fq_out[FF_Y2 +:32]), .z2(fq_out[FF_Z2 +:32]),
        .x3(fq_out[FF_X3 +:32]), .y3(fq_out[FF_Y3 +:32]), .z3(fq_out[FF_Z3 +:32]),
        .xbase(t_xbase), .ybase(t_ybase),
        .busy(su_busy),
        .out_ready(!pq_full),
        .out_valid(su_out_valid), .out_tag(su_out_tag), .out_isp(su_out_isp),
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

    // `peeling` selects the layer-peel (RM_TRANSLUCENT_AUTOSORT) compare for the
    // active raster triangle; OP uses the plain opaque DepthMode compare. Set when
    // the active region state is PT or TR (PT treated as TR for now).
    reg        peeling;

    // ---- raster consumer stage-A -> stage-B pipeline (registered read in u_peel) ----
    // Stage A (on ras_out_valid): u_peel presents the peel-RAM READ for the resolved
    // chunk. Stage B (next cycle, b_valid): u_peel feeds back the read chunk, runs its
    // internal depth compare off the latched b_* fields, and writes back the passing
    // lanes. It echoes b_pass_lp (peel accept, for dt_pt) and b_more (MoreToDraw).
    reg                    b_valid;
    reg [RAS_LANES-1:0]    b_inside;
    reg [32*RAS_LANES-1:0] b_invw;
    reg [4:0]              b_ox, b_oy;
    reg [31:0]             b_tag;
    reg [2:0]              b_mode;
    reg                    b_zwdis;
    reg                    b_peeling;   // carry the peel/opaque select into stage B
    reg                    b_which;     // peel_which snapshot (PT list => dt_pt=1)

    // ---- peel + color tile buffers (own the RAM ports + access-pattern enforcement) ----
    peel_tile_buffer #(.LANES(RAS_LANES)) u_peel (
        .clk(clk), .reset(reset),
        // raster stage A
        .ras_a_valid(pb_ra_valid), .ras_a_y(ras_oy), .ras_a_x(ras_ox),
        // raster stage B
        .ras_b_valid(b_valid), .b_inside(b_inside), .b_invw(b_invw),
        .b_y(b_oy), .b_x(b_ox), .b_tag(b_tag), .b_mode(b_mode),
        .b_zwdis(b_zwdis), .b_peeling(b_peeling),
        .b_pass_lp(b_pass_lp), .b_more(b_more),
        // shade single-pixel read
        .sh_rd_valid(pb_shrd_valid), .sh_rd_id(pb_shrd_id),
        .sh_valid(sh_valid_o), .sh_tag(sh_tag_o), .sh_depth(sh_depth_o),
        // CLEAR
        .clr_valid(pb_clr_valid), .clr_addr(pb_clr_addr),
        .clr_depth(regs.isp_backgnd_d), .clr_tag(regs.isp_backgnd_t),
        // PeelBuffers RMW walk
        .pb_rd_valid(pb_bufrd_valid), .pb_rd_addr(pb_bufrd_addr),
        .pb_wr_valid(pb_bufwr_valid), .pb_wr_addr(pb_bufwr_addr),
        .pb_first(first_peel)
    );

    color_tile_buffer #(.DEPTH(TILE_W*TILE_H)) u_col (
        .clk(clk), .reset(reset),
        .bl_ca_valid(cb_ca_valid), .bl_ca_id(cb_ca_id),
        .bl_cb_valid(cb_valid), .cb_id(cb_id), .cb_argb(cb_argb),
        .cb_tsp(cb_tsp), .cb_at_en(cb_at_en), .alpha_ref(regs.pt_alpha_ref[7:0]),
        .fl_rd_valid(cb_fl_valid), .fl_id(cb_fl_id),
        .rd_argb(col_rd_argb)
    );

    // ==================================================================
    // TSP plane cache: 64 entries, keyed by the FULL CoreTag word, banked into M10K
    // in the plane_cache module (u_pc). cache_bypass is deliberately IGNORED (always
    // cache). Miss -> param fetch (GetFpuEntry) + tsp_setup_min; per entry: 10 planes
    // {ddx,ddy,c} + the record's isp/tsp/tcw words. The wide plane payload lives in
    // M10K (registered read -> the plane-cache lookup is a 1-cycle registered read,
    // pipelined as stage L1->L2 of the streaming shade producer: L1 presents the read,
    // L2 samples hit + payload); the small tag/valid mirror stays in logic for the
    // single-cycle invalidate. cur_* is the live working entry (feeds tsp_shade); the
    // whole cur_* bundle is committed to the cache in one write at TSP_RUN.
    // ==================================================================
    localparam integer PC_N = 64;

    // current entry (feeds tsp_shade)
    reg [31:0] cur_isp, cur_tsp, cur_tcw;
    reg [31:0] cur_ddx [0:9];
    reg [31:0] cur_ddy [0:9];
    reg [31:0] cur_c   [0:9];

    // flat 320-bit views of cur_* (lane j at [32*j +: 32]) for the cache write port
    wire [319:0] cur_ddx_flat, cur_ddy_flat, cur_c_flat;
    genvar gpc;
    generate
      for (gpc = 0; gpc < 10; gpc = gpc + 1) begin : pcflat
        assign cur_ddx_flat[32*gpc +: 32] = cur_ddx[gpc];
        assign cur_ddy_flat[32*gpc +: 32] = cur_ddy[gpc];
        assign cur_c_flat  [32*gpc +: 32] = cur_c  [gpc];
      end
    endgenerate

    // plane_cache control (typed ports; driven by the shade FSM)
    reg          pc_inval;                 // clear all valid (S_SHADE_START, 1-cyc reg)
    reg          pc_lu_req;                // lookup (COMBINATIONAL: streaming stage L1)
    reg          pc_wr_req;                // commit (TSP_RUN, 1-cyc reg)
    wire         pc_rd_valid, pc_hit;
    wire [31:0]  pc_o_isp, pc_o_tsp, pc_o_tcw;
    wire [319:0] pc_o_ddx, pc_o_ddy, pc_o_c;
    plane_cache #(.NENT(PC_N), .SLOTW(6)) u_pc (
        .clk(clk), .reset(reset), .inval(pc_inval),
        .lu_req(pc_lu_req), .lu_slot(pc_lu_slot_c), .lu_tag(pc_lu_tag_c),
        .rd_valid(pc_rd_valid), .hit(pc_hit),
        .o_isp(pc_o_isp), .o_tsp(pc_o_tsp), .o_tcw(pc_o_tcw),
        .o_ddx(pc_o_ddx), .o_ddy(pc_o_ddy), .o_c(pc_o_c),
        .wr_req(pc_wr_req), .wr_slot(sh_slot), .wr_tag(sh_tag),
        .wr_isp(cur_isp), .wr_tsp(cur_tsp), .wr_tcw(cur_tcw),
        .wr_ddx(cur_ddx_flat), .wr_ddy(cur_ddy_flat), .wr_c(cur_c_flat)
    );

    // shade-pass state
    reg [9:0]  shp;           // next tile pixel 0..1023 to ISSUE into the stream
    reg [9:0]  fw_i;          // framebuffer-writeout pixel 0..1023
    reg [31:0] sh_tag;        // the MISS pixel's CoreTag (drives the fetch + cache write)
    reg [31:0] sh_invw;       // the MISS pixel's depth-buffer invW (fed to the shader)
    reg [9:0]  sh_id;         // the MISS pixel's tile index (fed to the shader)

    // ---- STREAMING shade producer pipeline registers (SH_PRESENT) ----
    // Two register stages feed tsp_shade_pp at 1 pixel/clock in the all-hit case:
    //   L0 issue -> {va,ida}   : a peel-buffer read was presented last cycle for ida
    //   L1 lookup -> {vb,idb..} : a plane-cache read was presented last cycle for idb
    //   L2 present (combinational) : pc_hit/pc_o_* resolve idb -> tsp_shade_pp
    reg        va;            // stage A occupied (peel read in flight for ida)
    reg [9:0]  ida;
    reg        vb;            // stage B occupied (cache read in flight for idb)
    reg [9:0]  idb;
    reg [31:0] tagb;          // idb's CoreTag (for the present + a possible miss)
    reg [31:0] invwb;         // idb's depth-buffer invW
    reg        iss_more;      // still pixels left to ISSUE at L0 (shp<=1023)

    // slot: param_offs low bits XOR tag_offset (strip triangles share param_offs)
    wire [5:0] sh_slot = sh_tag[8:3] ^ {3'b000, sh_tag[2:0]};

    // plane-cache lookup address for THIS cycle (pipelined; see the request block).
    // The read port is driven from L1 (a fresh peel result) or, while a present is
    // stalled on a texture miss, re-driven for stage B to hold pc_hit/pc_o_* alive.
    reg  [31:0] pc_lu_tag_c;
    wire [5:0]  pc_lu_slot_c = pc_lu_tag_c[8:3] ^ {3'b000, pc_lu_tag_c[2:0]};
    // CoreTag fields (ISP_BACKGND_T layout)
    wire [20:0] sh_po   = sh_tag[23:3];
    wire [2:0]  sh_skip = sh_tag[26:24];
    wire [2:0]  sh_toff = sh_tag[2:0];
    wire        sh_two_vol = sh_tag[27] & ~regs.fpu_shad_scale.intensity_shadow;
    wire [4:0]  sh_stride_w = 5'd3 + sh_skip * (sh_two_vol ? 5'd2 : 5'd1);
    wire [26:0] sh_stride_b = {sh_stride_w, 2'b00};

    // ---- 32-bit word reader: DIRECT DDR, 8-word sliding-window (as object_list_parser) ----
    // f_go with a byte address (f_addr) returns the word NEXT cycle in
    // f_word/f_word_v on a resident line. Each miss fetches a whole 256-bit line
    // (burst=8) into tw0 (demand) or tw1 (prefetch of tw0+1). Drives ts_dreq/ts_dresp.
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
    // The streaming producer presents a resolved pixel (planes from the plane cache
    // on a hit, or from cur_* on a just-fetched miss) on pp_in_valid; tsp_shade_pp
    // streams results out on pp_out_valid, carrying the pixel index (0..1023) as the
    // id so the consumer can write col_buf[out_id]. pp_stall (any texel fetcher busy)
    // freezes the pipe; the producer holds the presented pixel while stalled.
    // The pp_* inputs are driven COMBINATIONALLY (see the pp-input mux) so a pixel can
    // be presented the same cycle its planes resolve (no extra latch stage).
    reg          pp_in_valid;
    reg  [9:0]   pp_in_id;
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
    wire [31:0]  pp_out_tsp;

    tsp_shade_pp #(.IDW(10)) u_shade (
        .clk(clk),.reset(reset),
        .in_valid(pp_in_valid),.in_id(pp_in_id),.px(pp_px),.py(pp_py),.invw_in(pp_invw),
        .in_ddx(pp_ddx),.in_ddy(pp_ddy),.in_c(pp_c),
        .tsp(pp_tsp),.tcw(pp_tcw),.text_ctrl(regs.text_control[4:0]),
        .pp_texture(pp_ptex),.pp_offset(pp_pofs),
        .out_valid(pp_out_valid),.out_id(pp_out_id),.out_argb(pp_out_argb),
        .out_tsp(pp_out_tsp),
        .stall(pp_stall),
        .tc_req(pp_tc_req),.tc_resp(pp_tc_resp),.vq_req(pp_vq_req),.vq_resp(pp_vq_resp));

`ifndef SYNTHESIS
    // -------- tsp_shade_pp INPUT DUMP (sim only) --------------------------------------
    // Dumps every pixel ACCEPTED by the shader (pp_in_valid && !pp_stall) with all of its
    // inputs, so the exact per-pixel stream feeding tsp_shade_pp can be diffed against the
    // serial reference / refsw. Enabled at runtime with +shadedump[=<file>] (default file
    // shade_pp_input.log); zero cost otherwise. One header + one CSV-ish line per accept:
    //   seq id px py invw tsp tcw text_ctrl ptex pofs ddx[0..9] ddy[0..9] c[0..9]
    integer      sd_fd = 0;
    reg          sd_en = 1'b0;
    reg [1023:0] sd_name;
    integer      sd_seq = 0;
    integer      sd_i;
    initial begin
        if ($value$plusargs("shadedump=%s", sd_name)) sd_en = 1'b1;
        else if ($test$plusargs("shadedump")) begin sd_en = 1'b1; sd_name = "shade_pp_input.log"; end
        if (sd_en) begin
            sd_fd = $fopen(sd_name, "w");
            $fwrite(sd_fd, "# tsp_shade_pp input dump: one line per accepted pixel\n");
            $fwrite(sd_fd, "# seq id px py invw tsp tcw text_ctrl ptex pofs ddx0..9 ddy0..9 c0..9\n");
        end
    end
    always @(posedge clk) begin
        if (!reset && sd_en && pp_in_valid && !pp_stall) begin
            $fwrite(sd_fd, "%0d %0d %0d %0d %08x %08x %08x %02x %0d %0d",
                    sd_seq, pp_in_id, pp_px, pp_py, pp_invw, pp_tsp, pp_tcw,
                    regs.text_control[4:0], pp_ptex, pp_pofs);
            for (sd_i = 0; sd_i < 10; sd_i = sd_i + 1) $fwrite(sd_fd, " %08x", pp_ddx[sd_i]);
            for (sd_i = 0; sd_i < 10; sd_i = sd_i + 1) $fwrite(sd_fd, " %08x", pp_ddy[sd_i]);
            for (sd_i = 0; sd_i < 10; sd_i = sd_i + 1) $fwrite(sd_fd, " %08x", pp_c[sd_i]);
            $fwrite(sd_fd, "\n");
            sd_seq = sd_seq + 1;
        end
    end
    final if (sd_en && sd_fd != 0) begin
        $fflush(sd_fd);
        $fclose(sd_fd);
        $display("[peel_core] tsp_shade_pp input dump: %0d pixels written to %0s", sd_seq, sd_name);
    end
`endif

    // -------- blend unit: the very end of the TSP pipeline (refsw BlendingUnit) --------
    // The blend RMW now lives INSIDE u_col (color_tile_buffer): a 2-stage pipeline
    // over the M10K color buffer.
    //   stage CA (on pp_out_valid && !pp_stall): latch cb_* and assert cb_ca_valid to
    //     present the col-RAM READ of cb_id; cb_valid<=1.
    //   stage CB (next cycle, cb_valid): u_col reads OLD col_buf[cb_id] = the dst,
    //     runs tsp_blend combinationally, and writes col_ram[cb_id] <- blend_out.
    // Because the shade sub-phase presents pixels in ASCENDING shp order and the pipe
    // is in-order, out ids never repeat within a sub-phase -> CA id N and CB id N-1
    // are always distinct, so no same-address RMW hazard. SH_DRAIN additionally waits
    // !cb_valid before returning so the trailing blend lands before the next phase
    // (peel pass / FLUSH) touches the color buffer.
    reg          cb_valid;
    reg  [9:0]   cb_id;
    reg  [31:0]  cb_argb, cb_tsp;
    reg          cb_at_en;    // alpha-test enable snapshot (peeling && dt_pt[id])

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
               // shade pass (FLUSH): the STREAMING shade producer (see SH_PRESENT).
               // SH_MPRES presents a cache-MISS-resolved pixel (planes from cur_*)
               // after the FH_*/FV_*/TSP_RUN fetch, then restarts the stream.
               SH_MPRES=16,
               FH_ISP=18, FH_ISPW=19, FH_TSPW=20, FH_TCWW=21,
               FV_RD=22, FV_W=23,
               TSP_RUN=24, SH_PRESENT=25, SH_DRAIN=26, SH_OUT=27,
               // unified PT+TL peel loop: init pb2, PeelBuffers, run, check
               S_PEEL_INIT=28, S_PEEL_BUF=29, S_PEEL_CHK=30,
               // shared shade sub-phase entry + OP-done return + FLUSH writeout
               S_SHADE_START=31, S_OP_DONE=32, S_FLUSH_WR=33,
               // M10K bulk-op walks over the peel RAM ports (128 chunk addrs each):
               S_CLEAR_WR=34,              // CLEAR: write {bg_depth, bg_tag} chunks
               S_PEEL_BUF_RUN=35,          // PeelBuffers RMW walk (read A -> write B)
               S_FLUSH_RD=37;              // FLUSH: prime col-RAM read of pixel fw_i
    reg [5:0] st;

    // consumer sub-FSM (setup is now the streamed pipeline u_isp -> pq FIFO)
    // RS_POP absorbs the 1-cycle registered-read latency of the M10K plane FIFO:
    // RS_IDLE issues the read (pq_ram[pq_head] -> pq_rdw) and advances head; RS_POP
    // splices pq_rdw into the active plane regs and starts the sweep.
    localparam RS_IDLE=0, RS_POP=1, RS_RAS=2, RS_DRAIN=3;  reg [2:0] rs_st;

    // ---- unified PT+TL layer-peel pass loop (TB-FSM; refsw do..while(MoreToDraw)) ----
    reg        more_to_draw;      // set by the raster consumer during a peel pass
    reg        op_shaded;         // OP shade (background/opaque -> col_buf) done this tile
    reg [31:0] pt_ptr_l, tr_ptr_l;// latched PT / TL list pointers for this tile
    reg        has_pt,  has_tr;   // this tile has a PT / TL list
    reg        peel_which;        // 0 = rasterizing PT list, 1 = TL list (this pass)
    reg [7:0]  peel_pass;         // pass counter (safety bound)
    localparam integer PEEL_MAX_PASS = 64;

    // ---- M10K bulk-op walk counters (NCHUNK addresses = whole 32x32 tile) ----
    reg [CHUNK_AW-1:0]  cl_i;     // CLEAR chunk-address counter 0..NCHUNK-1
    reg [CHUNK_AW-1:0]  pb_i;     // PeelBuffers chunk-address counter 0..NCHUNK-1
    reg [CHUNK_AW-1:0]  pb_rd;    // PeelBuffers read-ahead chunk (1 ahead of pb_i)
    reg        pb_pipe;         // PeelBuffers RMW pipe primed (stage-B has valid rdata)
    reg        first_peel;      // this tile's FIRST PeelBuffers (folds refsw SetTagToMax:
                                //   pb2 <- 0xFFFFFFFF instead of copying tagA)

    // ---- single shared shade sub-phase (ONE tsp_shade_pp pipeline) ----
    // Invoked as a subroutine after OP and after each peel pass. The TSP pipeline
    // ALWAYS blends (refsw PixelFlush_tsp always runs BlendingUnit); the tag's
    // SrcInstr/DstInstr decide the effect (opaque tags use ONE/ZERO = overwrite).
    // shade_mode only selects WHICH pixels are shaded, not whether we blend:
    //   0 = OP  : shade every pixel of the tile
    //   1 = PEEL: shade only pixels staged this pass (dt_valid)
    // shade_ret : FSM state to return to once the shade sub-phase drains.
    reg        shade_mode;
    reg [5:0]  shade_ret;
    integer    sh_pending;   // pixels presented this shade sub-phase (PEEL skips some)

    // ---- STREAMING shade producer control (combinational; see SH_PRESENT) ----
    wire sh_streaming  = (st == SH_PRESENT);
    // stage A carries a pixel that IS shaded this pass (PEEL skips !sh_valid_o pixels).
    // sh_valid_o is the peel result for ida (the read presented last cycle).
    wire sh_A_staged   = va && (shade_mode ? sh_valid_o : 1'b1);
    // stage B resolved this cycle: pc_hit / pc_o_* correspond to idb (read last cycle).
    wire sh_present_v   = sh_streaming && vb && pc_hit;     // a hit ready to present
    wire sh_present_acc = sh_present_v && !pp_stall;        // accepted by the shader
    wire sh_miss        = sh_streaming && vb && !pc_hit;    // B is a plane-cache miss
    // advance the front unless a hit present is stalled or B is a miss (miss -> fetch).
    wire sh_adv         = sh_streaming && !sh_miss && !(sh_present_v && pp_stall);
    // SH_MPRES: the miss-resolved pixel (idb) is being presented from cur_*; it is
    // accepted when the shader isn't stalled. On accept we return to SH_PRESENT, so
    // this is the cycle to re-present ida's peel read (stage A survived the fetch).
    wire sh_mpres_acc   = (st == SH_MPRES) && !pp_stall;

    // ---- entry FIFO (object_list_parser -> iterator), depth 8 ----
    localparam integer EQ_N = 8;
    reg [1:0]       eq_etype [0:EQ_N-1];
    objlist_entry_t eq_entry [0:EQ_N-1];
    reg [3:0] eq_head, eq_tail; reg [4:0] eq_count;
    reg       eq_push, eq_pop;
    wire eq_full  = (eq_count == EQ_N);
    wire eq_empty = (eq_count == 0);

    // entry FIFO head -> prefetching iterator's streaming input. The iterator pulls
    // entries via entry_valid/entry_ack; the barrier observes list-done via
    // eq_empty && !it_pf_busy (no pull FSM, no it_cst / prim_seen tracking).
    always @(*) begin
        it_entry = eq_entry[eq_head[2:0]];
        it_etype = entry_type_e'(eq_etype[eq_head[2:0]]);
    end
    assign it_entry_valid = !eq_empty;

    // ---- triangle FIFO (producer -> consumer), depth 8 ----
    // Like pq, the data lives in ONE M10K word per entry instead of 11 register
    // arrays. But setup reads the head COMBINATIONALLY (its .x1/.y1/... ports), which
    // M10K can't do, so this is a FIRST-WORD-FALL-THROUGH FIFO with a registered
    // "output register" fq_out that always holds the head entry, pre-read one cycle
    // ahead. accept (su_in_valid && in_ready) IS the pop: it consumes fq_out and, the
    // same cycle, issues the M10K read of the NEXT head so fq_out is refreshed next
    // cycle -> zero-bubble back-to-back accepts (the read latency exactly fills the
    // gap). fq_out_valid gates su_in_valid so setup never consumes a not-yet-loaded
    // head. Push into the slot being (re)loaded is BYPASSED from the write data, since
    // no_rw_check M10K returns OLD data on a same-address same-cycle read+write.
    localparam integer FIFO_N = 8;
    localparam integer FQ_W = 352;   // 11 * 32
    localparam integer FF_ISP=0,  FF_TAG=32,
                       FF_X1=64,  FF_Y1=96,  FF_Z1=128,
                       FF_X2=160, FF_Y2=192, FF_Z2=224,
                       FF_X3=256, FF_Y3=288, FF_Z3=320;
    (* ramstyle = "M10K, no_rw_check" *) reg [FQ_W-1:0] fq_ram [0:FIFO_N-1];
    reg [FQ_W-1:0] fq_out;         // registered head entry (FWFT output register)
    reg            fq_out_valid;   // fq_out holds a valid head entry
    reg [3:0]  fq_head, fq_tail;   // ring indices 0..FIFO_N-1 (0..7)
    reg [4:0]  fq_count;
    reg        fifo_push, fifo_pop; // 1-cycle intents (reconciled into fq_count)

    // assemble the push word from the iterator's triangle
    wire [FQ_W-1:0] fq_wrw;
    assign fq_wrw[FF_ISP +:32] = it_trio.isp;  assign fq_wrw[FF_TAG +:32] = it_trio.tag;
    assign fq_wrw[FF_X1  +:32] = it_trio.v0.x; assign fq_wrw[FF_Y1 +:32] = it_trio.v0.y;
    assign fq_wrw[FF_Z1  +:32] = it_trio.v0.z;
    assign fq_wrw[FF_X2  +:32] = it_trio.v1.x; assign fq_wrw[FF_Y2 +:32] = it_trio.v1.y;
    assign fq_wrw[FF_Z2  +:32] = it_trio.v1.z;
    assign fq_wrw[FF_X3  +:32] = it_trio.v2.x; assign fq_wrw[FF_Y3 +:32] = it_trio.v2.y;
    assign fq_wrw[FF_Z3  +:32] = it_trio.v2.z;
    wire fq_full  = (fq_count == FIFO_N);
    wire fq_empty = (fq_count == 0);

    // ---- 8-deep PLANE FIFO (pq): streamed setup -> rasterizer ----
    // Decouples the (interleaved) setup from the rasterizer so setup runs ahead and
    // fills the FIFO instead of lock-stepping through the old 1-deep pend handoff.
    localparam integer PQ_N = 8;
    // Plane FIFO data now lives in ONE M10K word per entry instead of ~21 separate
    // register arrays (~5.6 kbit of FFs -> block RAM). Every field is written once at
    // push (pq_tail) and read once at pop (pq_head), and the read is ALREADY registered
    // (isp_*/rbx*/ras_* latch it in RS_IDLE), so a registered-read M10K is a drop-in:
    // push and pop never target the same address in the same cycle (pop only fires when
    // !pq_empty -> head!=tail; push is blocked by out_ready=!pq_full when head==tail),
    // so no_rw_check is safe. Only the small head/tail/count control stays in logic.
    localparam integer PQ_W = 564;   // 17*32 + 4*5
    localparam integer QF_DX12=0,  QF_DX23=32,  QF_DX31=64,  QF_DX41=96;
    localparam integer QF_DY12=128,QF_DY23=160, QF_DY31=192, QF_DY41=224;
    localparam integer QF_C1=256,  QF_C2=288,   QF_C3=320,   QF_C4=352;
    localparam integer QF_DDX=384, QF_DDY=416,  QF_CINVW=448;
    localparam integer QF_ISP=480, QF_TAG=512;
    localparam integer QF_BX0=544, QF_BX1=549,  QF_BY0=554,  QF_BY1=559;   // 5b each
    (* ramstyle = "M10K, no_rw_check" *) reg [PQ_W-1:0] pq_ram [0:PQ_N-1];
    reg [PQ_W-1:0] pq_rdw;            // registered read word (valid the cycle after pop)
    reg [3:0]  pq_head, pq_tail;
    reg [4:0]  pq_count;
    reg        pq_push, pq_pop;
    wire pq_full  = (pq_count == PQ_N);
    wire pq_empty = (pq_count == 0);

    // assemble the push word from the retiring planes
    wire [PQ_W-1:0] pq_wrw;
    assign pq_wrw[QF_DX12 +: 32] = w_dx12; assign pq_wrw[QF_DX23 +: 32] = w_dx23;
    assign pq_wrw[QF_DX31 +: 32] = w_dx31; assign pq_wrw[QF_DX41 +: 32] = w_dx41;
    assign pq_wrw[QF_DY12 +: 32] = w_dy12; assign pq_wrw[QF_DY23 +: 32] = w_dy23;
    assign pq_wrw[QF_DY31 +: 32] = w_dy31; assign pq_wrw[QF_DY41 +: 32] = w_dy41;
    assign pq_wrw[QF_C1   +: 32] = w_c1;   assign pq_wrw[QF_C2   +: 32] = w_c2;
    assign pq_wrw[QF_C3   +: 32] = w_c3;   assign pq_wrw[QF_C4   +: 32] = w_c4;
    assign pq_wrw[QF_DDX  +: 32] = w_ddx;  assign pq_wrw[QF_DDY  +: 32] = w_ddy;
    assign pq_wrw[QF_CINVW+: 32] = w_cinvw;
    assign pq_wrw[QF_ISP  +: 32] = su_out_isp; assign pq_wrw[QF_TAG +: 32] = su_out_tag;
    assign pq_wrw[QF_BX0  +:  5] = w_bx0;  assign pq_wrw[QF_BX1  +:  5] = w_bx1;
    assign pq_wrw[QF_BY0  +:  5] = w_by0;  assign pq_wrw[QF_BY1  +:  5] = w_by1;

    // consumer fully idle: entry FIFO empty, iterator authoritative-idle (it_pf_busy
    // clear: no record buffered/being read/emitted/outstanding), streamed setup
    // idle (!su_busy), raster idle, and the plane FIFO empty. Using it_pf_busy (not
    // a pulse-cleared reg) is the isp_core fix: a drained pulse racing a refilled eq
    // could open the barrier while triangles were still pending -> next state's
    // CLEAR/PeelBuffers/FLUSH would corrupt live tile data. The peel loop re-runs
    // the OL list per pass; the barrier waits for it_pf_busy to clear each pass.
    // include !b_valid: the depth-cmp write-back (stage B) is one cycle behind
    // ras_out_valid, so the last chunk's write to the peel RAM may still be in flight
    // when rs_st returns to RS_IDLE. CLEAR/PeelBuffers must not walk the RAM until it
    // lands (isp_core fix).
    // also gate on !su_out_valid: isp_setup_streamed clears its slot_busy (so
    // su_busy drops) the SAME cycle it schedules out_valid, so a triangle RETIRES
    // into the plane FIFO the cycle AFTER su_busy falls. Without this, the barrier
    // could open on !su_busy && pq_empty while su_out_valid was still pushing that
    // last triangle into pq - it would then rasterize DURING the shade phase,
    // corrupting the peel buffer and clashing on the peel-RAM read port. Holding on
    // su_out_valid keeps the barrier closed until the triangle lands in pq (then
    // !pq_empty / rs_st keep it closed until the raster drains it).
    wire consumer_idle = eq_empty && !it_pf_busy
                       && !su_busy && !su_out_valid && (rs_st==RS_IDLE) && pq_empty
                       && !b_valid;

    // shade pass pixel accounting: producer index shp, consumer count sh_out_n
    integer sh_out_n;
    // streamed rasterizer: chunks in flight (issued but not yet consumed)
    // (NCHUNK defined at top of module)
    integer ras_inflight;

    // vertex field ids for FV_RD/FV_W
    localparam [2:0] FLD_X=0, FLD_Y=1, FLD_Z=2, FLD_UV16=3, FLD_U=4, FLD_V=5,
                     FLD_COL=6, FLD_OFS=7;

    integer tri_count, cull_count, miss_count, hit_count, tri_seen;
    reg [5:0] cur_tx, cur_ty;      // latched tile coords (stable during lists)
    integer i, l, j;

`ifndef SYNTHESIS
    // ---------------- performance counters (sim only) ----------------
    // Two INDEPENDENT classifications (ISP/raster engine, TSP/shade engine), each
    // charging every clock to exactly one bucket -> each set sums to pc_total. The two
    // engines can be busy the SAME cycle (they overlap), so keeping them separate shows
    // real per-engine utilisation. Plus a top-level FSM-state view (pc_top_*). Dumped
    // at S_DONE.
    integer pc_total;
    // ISP / raster engine (classified by rs_st)
    integer pc_ras_active;      // RS_RAS: rasterizing chunks
    integer pc_ras_pop;         // RS_POP: plane-FIFO pop + splice
    integer pc_ras_drain;       // RS_DRAIN: raster pipe drain
    integer pc_ras_idle;        // RS_IDLE: not rasterizing (waiting / nothing to do)
    // TSP / shade engine (classified by top FSM `st` when in a shade sub-phase)
    integer pc_sh_present;      // SH_PRESENT accepted: pixel issued into shade pipe
    integer pc_sh_tex_stall;    // SH_PRESENT && pp_stall: blocked on texture fetch
    integer pc_sh_setup_wait;   // TSP_RUN: waiting on tsp_setup_min (plane-cache MISS)
    integer pc_sh_fetch;        // FH_*/FV_*: fetching vertex params from DDR (miss)
    integer pc_sh_look;         // SH_PRESENT frozen/fill: front lookup, not presenting
    integer pc_sh_drain;        // SH_DRAIN: shade pipe drain
    integer pc_sh_none;         // not in a shade sub-phase this clock
    // top-level phase view (whole-core, mutually exclusive by `st` group)
    integer pc_top_clear;       // S_CLEAR_WR
    integer pc_top_peelbuf;     // S_PEEL_BUF_RUN
    integer pc_top_flush;       // S_FLUSH_RD/WR (framebuffer writeout / scanout)
    integer pc_top_ol;          // S_OL_RUN (region/objlist walk feeding the iterator)
    integer pc_top_barrier;     // S_DRAIN (wait consumer idle)
    integer pc_top_shade;       // any shade sub-phase (SH_*/FH_*/FV_*/TSP_RUN)
    integer pc_top_other;       // remaining setup/idle states
    // extra: texture-stall clocks regardless of state; setup(tsp) invocation clocks
    integer pc_tex_busy;        // pp_stall asserted (texture pipe busy) any clock
    integer pc_su_busy;         // streamed ISP-setup busy (su_busy) any clock
`endif

    // ---- COMBINATIONAL framebuffer-write (FLUSH), valid/ready handshake ----
    // fbw_req is presented + accepted the SAME cycle so a blocking controller works
    // (busy holds; we advance fw_i only when the pixel is consumed). The screen
    // pixel for the linear tile index fw_i (0..1023): x=fw_i[4:0], y=fw_i[9:5].
    // fbw_req.argb comes from the col RAM's REGISTERED read (cr_rdata): the combi
    // read-port block below presents cr_raddr=fw_i whenever we HOLD the pixel, so
    // cr_rdata == col_ram[fw_i]. On entry S_FLUSH_RD primes the read for pixel 0.
    wire [10:0] fw_px = {5'd0, cur_tx}*11'd32 + {6'd0, fw_i[4:0]};
    wire [10:0] fw_py = {5'd0, cur_ty}*11'd32 + {6'd0, fw_i[9:5]};
    wire        fw_onscreen = (fw_px < 11'd640) && (fw_py < 11'd480);
    always @(*) begin
        fbw_req.we      = (st==S_FLUSH_WR) && fw_onscreen;
        fbw_req.pix_idx = fw_py*20'd640 + {9'd0, fw_px};
        fbw_req.argb    = col_rd_argb;           // u_col registered read of fw_i
    end
    // a pixel is consumed this cycle when: on-screen and the sink accepted it, OR
    // off-screen (nothing to write -> skip immediately).
    wire fw_pix_consumed = (st==S_FLUSH_WR) &&
                           ( (fw_onscreen && !fbw_resp.busy) || !fw_onscreen );

`ifndef SYNTHESIS
    // -------- FRAMEBUFFER-WRITE dump (sim only): the FINAL output, screen (x,y,argb) as
    // actually written. Reconstructing an image from this vs the BMP isolates whether any
    // weave lives in FLUSH/scanout (fb writes already blocky) or in the BMP writer (fb
    // writes smooth). +fbdump[=<file>] (default fb_writes.log). ----
    integer      fbd_fd = 0; reg fbd_en = 1'b0; reg [1023:0] fbd_name; integer fbd_n = 0;
    initial begin
        if ($value$plusargs("fbdump=%s", fbd_name)) fbd_en=1'b1;
        else if ($test$plusargs("fbdump")) begin fbd_en=1'b1; fbd_name="fb_writes.log"; end
        if (fbd_en) begin fbd_fd=$fopen(fbd_name,"w"); $fwrite(fbd_fd,"# x y argb (tile tx,ty fw_i)\n"); end
    end
    always @(posedge clk) if (!reset && fbd_en && fbw_req.we && fw_pix_consumed) begin
        $fwrite(fbd_fd, "%0d %0d %08x %0d %0d %0d\n", fw_px, fw_py, col_rd_argb, cur_tx, cur_ty, fw_i);
        fbd_n = fbd_n + 1;
    end
    final if (fbd_en && fbd_fd!=0) begin $fflush(fbd_fd); $fclose(fbd_fd);
        $display("[peel_core] framebuffer writes: %0d -> %0s", fbd_n, fbd_name); end
`endif

    // ============ COMBINATIONAL buffer request ports (valid THIS cycle) ============
    // Drive u_peel / u_col's typed request ports from the FSM + pipeline state. The
    // buffer modules own the RAM ports, the compare, the RMW write-data and the
    // single-driver enforcement; here we just say WHICH client is active this cycle.
    // The region barriers keep raster / shade / bulk phases disjoint, so at most one
    // read client and one write client is ever asserted.
    always @(*) begin
        // ---- peel buffer ----
        pb_ra_valid    = ras_out_valid;               // stage-A read (chunk resolved)
        // STREAMING shade: L0 presents a peel read every advance cycle (id=shp, the
        // pixel being issued). When a present is held (texture stall) the front freezes
        // but we RE-present ida's read so stage A's peel result stays alive on sh_*.
        // On a cache MISS the front leaves SH_PRESENT to fetch (sh_streaming drops), so
        // stage A's peel result is lost; as we RETURN (SH_MPRES accept, sh_mpres_acc),
        // re-present ida's read so sh_* is fresh the cycle we re-enter SH_PRESENT.
        if (sh_streaming)      begin pb_shrd_valid = (sh_adv ? iss_more : va);
                                     pb_shrd_id    = (sh_adv ? shp : ida); end
        else if (sh_mpres_acc) begin pb_shrd_valid = va; pb_shrd_id = ida; end
        else                   begin pb_shrd_valid = 1'b0; pb_shrd_id = ida; end
        pb_clr_valid   = (st == S_CLEAR_WR);          // CLEAR walk write
        pb_clr_addr    = cl_i;
        pb_bufrd_valid = (st == S_PEEL_BUF_RUN);      // PeelBuffers read-ahead
        pb_bufrd_addr  = pb_rd;
        pb_bufwr_valid = (st == S_PEEL_BUF_RUN) && pb_pipe;  // PeelBuffers delayed write
        pb_bufwr_addr  = pb_i;
        // (stage-B write is driven by the b_valid port directly on u_peel)

        // ---- color buffer ----
        // STREAMING shade pipe: pp_out_valid is a clean 1-cycle pulse INDEPENDENT of
        // pp_stall (the back-end drains while the front may be stalled on a texture
        // miss). Consume it whenever high - gating on !pp_stall would drop results that
        // emerge during a miss (the old frozen-pipe contract no longer holds).
        cb_ca_valid = pp_out_valid;                   // blend stage CA read (out_id)
        cb_ca_id    = pp_out_id;
        cb_fl_valid = (st == S_FLUSH_RD || st == S_FLUSH_WR);   // FLUSH read (fw_i)
        cb_fl_id    = fw_i;

        // ---- plane cache lookup (STREAMING) ----
        // On an advance cycle L1 looks up the pixel whose peel result is on sh_* now
        // (stage A, tag = sh_tag_o), if it is shaded this pass. While a present is
        // held on a texture stall we instead RE-issue stage B's lookup so pc_hit/pc_o_*
        // stay valid for the pixel we're re-presenting. (u_peel and u_pc are separate
        // RAMs, so the peel read and the cache read both fire every cycle.)
        if (sh_streaming && !sh_adv && vb) begin       // present held: hold stage B
            pc_lu_req   = 1'b1;
            pc_lu_tag_c = tagb;
        end else if (sh_streaming && sh_adv && sh_A_staged) begin
            pc_lu_req   = 1'b1;
            pc_lu_tag_c = sh_tag_o;
        end else begin
            pc_lu_req   = 1'b0;
            pc_lu_tag_c = sh_tag_o;
        end
    end

    // ---- pp-input mux: drive tsp_shade_pp's inputs COMBINATIONALLY ----
    // HIT  (SH_PRESENT): planes straight from the plane cache (pc_o_*), id/invw from
    //                    the stage-B pipeline registers.
    // MISS (SH_MPRES)  : planes from cur_* (just fetched + committed), id/invw the
    //                    latched miss context. pp_in_valid is held while in either
    //                    present state until the shader accepts (!pp_stall).
    integer pj;
    always @(*) begin
        if (st == SH_MPRES) begin
            pp_in_valid = 1'b1;
            pp_in_id    = sh_id;
            pp_invw     = sh_invw;
            pp_tsp      = cur_tsp;
            pp_tcw      = cur_tcw;
            pp_ptex     = cur_isp[ISP_TEXTURE_BIT];
            pp_pofs     = cur_isp[ISP_OFFSET_BIT];
            for (pj = 0; pj < 10; pj = pj + 1) begin
                pp_ddx[pj] = cur_ddx[pj];
                pp_ddy[pj] = cur_ddy[pj];
                pp_c[pj]   = cur_c[pj];
            end
        end else begin                                 // HIT stream (or idle => valid=0)
            pp_in_valid = sh_present_v;
            pp_in_id    = idb;
            pp_invw     = invwb;
            pp_tsp      = pc_o_tsp;
            pp_tcw      = pc_o_tcw;
            pp_ptex     = pc_o_isp[ISP_TEXTURE_BIT];
            pp_pofs     = pc_o_isp[ISP_OFFSET_BIT];
            for (pj = 0; pj < 10; pj = pj + 1) begin
                pp_ddx[pj] = pc_o_ddx[32*pj +: 32];
                pp_ddy[pj] = pc_o_ddy[32*pj +: 32];
                pp_c[pj]   = pc_o_c  [32*pj +: 32];
            end
        end
        pp_px = pp_in_id[4:0];
        pp_py = pp_in_id[9:5];
    end

    always @(posedge clk) begin
        if (reset) begin
            st<=S_IDLE; done<=0; ra_start<=0; ol_start<=0;
            tsp_start<=0; f_go<=0;
            va<=1'b0; vb<=1'b0; iss_more<=1'b0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            tri_count<=0; cull_count<=0; miss_count<=0; hit_count<=0; tri_seen<=0;
            sh_out_n<=0; ras_inflight<=0;
`ifndef SYNTHESIS
            pc_total<=0;
            pc_ras_active<=0; pc_ras_pop<=0; pc_ras_drain<=0; pc_ras_idle<=0;
            pc_sh_present<=0; pc_sh_tex_stall<=0; pc_sh_setup_wait<=0; pc_sh_fetch<=0;
            pc_sh_look<=0; pc_sh_drain<=0; pc_sh_none<=0;
            pc_top_clear<=0; pc_top_peelbuf<=0; pc_top_flush<=0; pc_top_ol<=0;
            pc_top_barrier<=0; pc_top_shade<=0; pc_top_other<=0;
            pc_tex_busy<=0; pc_su_busy<=0;
`endif
            rs_st<=RS_IDLE;
            pq_head<=0; pq_tail<=0; pq_count<=0;
            fq_head<=0; fq_tail<=0; fq_count<=0; fq_out_valid<=1'b0;
            eq_head<=0; eq_tail<=0; eq_count<=0;
            peeling<=1'b0; more_to_draw<=1'b0; peel_pass<=8'd0; op_shaded<=1'b0;
            has_pt<=1'b0; has_tr<=1'b0; peel_which<=1'b0;
            b_valid<=1'b0; cb_valid<=1'b0;
            cl_i<='0; pb_i<='0; pb_rd<='0; pb_pipe<=1'b0; first_peel<=1'b0;
            pc_inval<=1'b0; pc_wr_req<=1'b0;
            // (plane cache valid bits are cleared by u_pc's own reset; pc_lu_req is
            //  combinational, driven by the streaming shade pipeline)
        end else begin
`ifndef SYNTHESIS
            // -------- performance counters: charge THIS clock to its buckets --------
            // Only count while the core is doing tile work (not the top-level idle wait
            // for a start). Approximate "active" as: not S_IDLE, or any engine busy.
            if (st != S_IDLE || rs_st != RS_IDLE || su_busy) begin
                pc_total <= pc_total + 1;

                // ISP / raster engine (by rs_st)
                case (rs_st)
                    RS_RAS:   pc_ras_active <= pc_ras_active + 1;
                    RS_POP:   pc_ras_pop    <= pc_ras_pop    + 1;
                    RS_DRAIN: pc_ras_drain  <= pc_ras_drain  + 1;
                    default:  pc_ras_idle   <= pc_ras_idle   + 1;   // RS_IDLE
                endcase

                // TSP / shade engine (by top FSM `st`, shade sub-phases only)
                if (st == SH_PRESENT) begin
                    if      (sh_present_v && pp_stall) pc_sh_tex_stall <= pc_sh_tex_stall + 1;
                    else if (sh_present_acc)           pc_sh_present   <= pc_sh_present   + 1;
                    else                               pc_sh_look      <= pc_sh_look      + 1; // fill/lookup
                end else if (st == SH_MPRES) begin
                    if (pp_stall) pc_sh_tex_stall <= pc_sh_tex_stall + 1;
                    else          pc_sh_present    <= pc_sh_present    + 1;
                end else if (st == TSP_RUN)                       pc_sh_setup_wait <= pc_sh_setup_wait + 1;
                else if (st==FH_ISP||st==FH_ISPW||st==FH_TSPW||st==FH_TCWW||
                         st==FV_RD||st==FV_W)                     pc_sh_fetch <= pc_sh_fetch + 1;
                else if (st==SH_DRAIN)                            pc_sh_drain <= pc_sh_drain + 1;
                else                                              pc_sh_none  <= pc_sh_none  + 1;

                // top-level phase view (whole-core)
                if (st==S_CLEAR_WR)                               pc_top_clear   <= pc_top_clear   + 1;
                else if (st==S_PEEL_BUF_RUN)                      pc_top_peelbuf <= pc_top_peelbuf + 1;
                else if (st==S_FLUSH_RD||st==S_FLUSH_WR)          pc_top_flush   <= pc_top_flush   + 1;
                else if (st==S_OL_RUN)                            pc_top_ol      <= pc_top_ol      + 1;
                else if (st==S_DRAIN)                             pc_top_barrier <= pc_top_barrier + 1;
                else if (st==SH_MPRES||
                         st==SH_PRESENT||st==SH_DRAIN||st==TSP_RUN||
                         st==FH_ISP||st==FH_ISPW||st==FH_TSPW||st==FH_TCWW||
                         st==FV_RD||st==FV_W)                     pc_top_shade   <= pc_top_shade   + 1;
                else                                              pc_top_other   <= pc_top_other   + 1;

                if (pp_stall) pc_tex_busy <= pc_tex_busy + 1;
                if (su_busy)  pc_su_busy  <= pc_su_busy  + 1;
            end
`endif
            done<=0; ra_start<=0; ol_start<=0;
            tsp_start<=0; f_go<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            eq_push = 1'b0;
            pc_inval<=1'b0; pc_wr_req<=1'b0;  // 1-cyc strobes (pc_lu_req is combi)
            // fbw_req is driven COMBINATIONALLY (see the FLUSH write block below).

            // ============ streamed rasterizer CONSUMER: stage A -> stage B ============
            // Stage A (ras_out_valid): the combinational peel-RAM read of chunk
            // {ras_oy,ras_ox} is already presented; latch the result fields for the
            // compare next cycle. Stage B (b_valid): the combinational RAM block runs
            // the depth compare off pr_rdata and writes the passing lanes back to the
            // peel RAM. Here in stage B we also write the dt_pt REG (kept out of the
            // RAM) and accumulate more_to_draw (moved off the old combinational path).
            b_valid <= 1'b0;
            if (ras_out_valid) begin
                b_valid  <= 1'b1;
                b_inside <= ras_inside;
                b_invw   <= ras_invw_flat;
                b_ox     <= ras_ox;
                b_oy     <= ras_oy;
                b_tag    <= tri_tag;
                b_mode   <= depth_mode;
                b_zwdis  <= zwrite_dis;
                b_peeling<= peeling;
                b_which  <= peel_which;
            end
            // Stage B side effects on peel_core state, from u_peel's echoed results
            // (b_pass_lp / b_more are already masked by inside & peeling in u_peel):
            //   dt_pt (reg) <- winning fragment came from the PT list (b_which==0),
            //   more_to_draw <- any lane wants another peel pass (refsw do..while).
            if (b_valid) begin
                for (l = 0; l < RAS_LANES; l = l + 1) begin
                    /* verilator lint_off WIDTH */
                    if (b_pass_lp[l])
                        dt_pt[{27'd0,b_oy}*TILE_W + {27'd0,b_ox} + l] = (b_which==1'b0);
                    if (b_more[l]) more_to_draw <= 1'b1;
                    /* verilator lint_on WIDTH */
                end
            end
            ras_inflight <= ras_inflight + (ras_in_valid ? 1 : 0) - (ras_out_valid ? 1 : 0);

            // ============ shade pipeline CONSUMER: blend stage CA -> CB ============
            // A fresh result is present when out_valid && !stall (out_valid holds
            // through a stall since the whole pipe is frozen). Stage CA latches the
            // pixel + snapshots the alpha-test enable (peeling && dt_pt[id], dt_pt is
            // a reg), presents the col-RAM read of out_id (combi block), and counts it
            // as drained. Stage CB (cb_valid): cr_rdata = OLD col_buf[id] = dst, the
            // blend runs combinationally, and the combi block writes col_ram[id].
            cb_valid <= 1'b0;
            if (pp_out_valid) begin                    // clean pulse; NOT gated on stall
                cb_valid <= 1'b1;
                cb_id    <= pp_out_id;
                cb_argb  <= pp_out_argb;
                cb_tsp   <= pp_out_tsp;
                cb_at_en <= peeling && dt_pt[pp_out_id];   // PT alpha-test enable
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
                // the previous state must be fully done). The M10K CLEAR is a 128-
                // chunk write walk (S_CLEAR_WR) instead of a single-cycle for-loop.
                RSTATE_CLEAR: if (consumer_idle && fq_empty) begin
                    // as tile_engine_top TILE_CLEAR: {bg depth, bg CoreTag}. Every
                    // pixel's tag = background tag and is "valid" for OP shading
                    // (refsw ClearBuffers sets tagStatus.valid=true), so the OP
                    // shade fills col_buf with the background color.
                    op_shaded <= 1'b0;   // OP shade not yet run for this tile
                    has_pt <= 1'b0; has_tr <= 1'b0;   // PT/TL lists for this tile: none yet
                    cl_i <= '0; st <= S_CLEAR_WR;
                end
                // OPAQUE: single pass, plain DepthMode compare (no peeling).
                RSTATE_OP: begin
                    peeling  <= 1'b0;
                    ol_list_ptr <= ra_out.list_ptr;
                    ol_start <= 1'b1;
                    st <= S_OL_RUN;
                end
                // PT / TR: just LATCH the list pointer + present flag and ack. The
                // UNIFIED peel (both lists together, back-to-front) runs at FLUSH so
                // PT fragments (opaque-or-hole via alpha test) correctly occlude TL
                // fragments behind them within the same peel passes.
                RSTATE_PT: begin
                    pt_ptr_l  <= ra_out.list_ptr; has_pt <= 1'b1;
                    ra_ack.list_done <= 1'b1; st <= S_RA_ACK;
                end
                RSTATE_TR: begin
                    tr_ptr_l  <= ra_out.list_ptr; has_tr <= 1'b1;
                    ra_ack.list_done <= 1'b1; st <= S_RA_ACK;
                end
                // FLUSH: (1) if any PT/TL geometry, run the unified peel now (blends
                // into col_buf); (2) then copy col_buf -> fb.
                RSTATE_FLUSH: if (consumer_idle && fq_empty) begin
                    if (has_pt || has_tr) begin
                        // ensure the OP/background shade ran so col_buf is the base
                        // image the peel layers blend over.
                        if (!op_shaded) begin
                            peeling    <= 1'b0;
                            shade_mode <= 1'b0;
                            op_shaded  <= 1'b1;
                            shade_ret  <= S_PEEL_INIT;
                            st <= S_SHADE_START;
                        end else begin
                            peeling <= 1'b1;
                            st <= S_PEEL_INIT;
                        end
                    end else begin
                        fw_i <= 10'd0; st <= S_FLUSH_RD;   // prime col-RAM read of px 0
                    end
                end
                default: begin ra_ack.list_done <= 1'b1; st <= S_RA_ACK; end
                endcase
            end

            // CLEAR write walk: the combi block writes background {depth,tag} to all
            // banks at address cl_i each cycle; here we just walk cl_i 0..NCHUNK-1.
            S_CLEAR_WR: begin
                if (cl_i == CHUNK_AW'(NCHUNK-1)) begin ra_ack.list_done <= 1'b1; st <= S_RA_ACK; end
                else cl_i <= cl_i + 1'b1;
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
            //  - OP  : run the OP shade sub-phase, then ack the region.
            //  - peel: run the peel shade sub-phase, then decide whether to peel again.
            S_DRAIN: if (fq_empty && consumer_idle) begin
                if (peeling) begin
                    // Unified peel: after the PT list, rasterize the TL list into the
                    // same buffers (if present) BEFORE shading, so both sort together.
                    if (peel_which==1'b0 && has_tr) begin
                        peel_which <= 1'b1;
                        ol_list_ptr <= tr_ptr_l; ol_start <= 1'b1;
                        st <= S_OL_RUN;
                    end else begin
                        shade_mode <= 1'b1;      // PEEL: shade only valid pixels
                        shade_ret  <= S_PEEL_CHK;
                        st <= S_SHADE_START;
                    end
                end else begin
                    shade_mode <= 1'b0;          // OP: shade every pixel
                    shade_ret  <= S_OP_DONE;
                    st <= S_SHADE_START;
                end
            end

            // OP shade drained -> mark this tile OP-shaded, ack the OP region.
            S_OP_DONE: begin op_shaded <= 1'b1; ra_ack.list_done <= 1'b1; st <= S_RA_ACK; end

            // -------- layer-peel pass loop (refsw2 RM_TRANSLUCENT_AUTOSORT) --------
            // refsw SetTagToMax(): set tagBufferA (dt_tag) = 0xFFFFFFFF for the whole
            // tile. The FIRST PeelBuffers then copies A->B so pb2 = 0xFFFFFFFF on
            // pass 1 (NOT the OP tags). depthA (dt_depth) still holds the OP depth,
            // which PeelBuffers copies to the reference zb2. Note: this discards the
            // OP tags in dt_tag, but the OP shade already ran (col_buf holds it), so
            // dt_tag is only used as the peel pending tag from here on.
            // refsw SetTagToMax() is FOLDED into the first PeelBuffers of this tile
            // (see S_PEEL_BUF_RUN + the combi block): instead of a separate walk
            // writing dt_tag=0xFFFFFFFF then copying A->B, the first PeelBuffers
            // writes tag2 <- 0xFFFFFFFF directly (first_peel), while still copying
            // depth2 <- depth (the OP depth reference). Net pass-1 state is identical:
            // pb2 = 0xFFFFFFFF, zb2 = OP depth.
            S_PEEL_INIT: begin
                peeling    <= 1'b1;  // (pre-peel OP shade may have cleared it)
                peel_pass  <= 8'd0;  // reset the pass counter for THIS tile's peel
                first_peel <= 1'b1;  // fold SetTagToMax into the first PeelBuffers
                st <= S_PEEL_BUF;
            end

            // PeelBuffers(FLT_MAX, 0): per pixel depth2<-depth, tag2<-tag (or
            // 0xFFFFFFFF on pass 1 via first_peel), depth<-FLT_MAX, valid<-0. As an
            // M10K RMW this is a read(A chunk N)->write(B transformed chunk N-1) walk
            // over 128 chunk addresses (S_PEEL_BUF_RUN). dt_pt is a reg: cleared here
            // in one cycle (else a stale PT flag fires the alpha test on TR pixels).
            // On pass 1 dt_depth holds the OP result (nothing clobbers it between OP
            // and the peel); later passes it holds the previous pass's closest layer;
            // copying live dt_depth every pass is correct - no snapshot needed.
            S_PEEL_BUF: begin
                for (i = 0; i < TILE_W*TILE_H; i = i + 1)
                    dt_pt[i] = 1'b0;
                more_to_draw <= 1'b0;
                pb_rd   <= '0;       // read-ahead chunk
                pb_i    <= '0;       // write chunk (1 behind read once primed)
                pb_pipe <= 1'b0;     // stage-B not yet primed
                st <= S_PEEL_BUF_RUN;
            end

            // PeelBuffers RMW walk: the combi block presents the READ of chunk pb_rd
            // and (when pb_pipe) WRITES the transformed chunk pb_i (= previous pb_rd,
            // whose data is now in pr_rdata). Advance read, delay write by one, finish
            // after the last chunk (NCHUNK-1) has been written back.
            S_PEEL_BUF_RUN: begin
                pb_pipe <= 1'b1;
                pb_i    <= pb_rd;
                if (pb_pipe && pb_i == CHUNK_AW'(NCHUNK-1)) begin
                    // whole tile transformed -> issue the object list for this pass.
                    first_peel <= 1'b0;
                    peel_pass  <= peel_pass + 8'd1;
                    // start with the PT list if present, else the TL list.
                    if (has_pt) begin
                        peel_which <= 1'b0;                 // rasterizing PT list
                        ol_list_ptr <= pt_ptr_l; ol_start <= 1'b1;
                    end else begin
                        peel_which <= 1'b1;                 // TL list
                        ol_list_ptr <= tr_ptr_l; ol_start <= 1'b1;
                    end
                    st <= S_OL_RUN;
                end else if (pb_rd != CHUNK_AW'(NCHUNK-1)) begin
                    pb_rd <= pb_rd + 1'b1;
                end
            end

            // After a pass's peel-shade drained: another peel pass if a fragment was
            // deferred (more_to_draw) and under the bound; else write out.
            S_PEEL_CHK: begin
                if (more_to_draw && peel_pass < PEEL_MAX_PASS[7:0]) begin
                    st <= S_PEEL_BUF;
                end else begin
                    peeling <= 1'b0;
                    fw_i <= 10'd0; st <= S_FLUSH_RD;   // prime col-RAM read of px 0
                end
            end

            // FLUSH read: prime the col-RAM read of pixel fw_i (combi block presents
            // cr_raddr=fw_i); cr_rdata is valid next cycle in S_FLUSH_WR.
            S_FLUSH_RD: st <= S_FLUSH_WR;

            // FLUSH writeout: STREAM the accumulation buffer (col_ram) to the
            // framebuffer at ONE PIXEL PER CYCLE. fbw_req.argb comes from cr_rdata
            // (the registered read of fw_i, held stable while fw_i holds); here we
            // only ADVANCE fw_i, and only when the pixel is consumed (fw_pix_consumed):
            // on-screen pixel accepted (we && !busy) OR an off-screen pixel (skipped).
            // A busy on-screen pixel HOLDS fw_i so the combinational fbw_req keeps
            // presenting it -> works with a real controller that blocks. When fw_i
            // advances, the combi read of the NEW fw_i is presented THIS cycle, so
            // cr_rdata is ready next cycle: stay in S_FLUSH_WR (the just-consumed
            // pixel is done; the next pixel's data lands before we re-present it).
            S_FLUSH_WR: begin
                if (fw_pix_consumed) begin
                    if (fw_i == 10'd1023) begin ra_ack.list_done <= 1'b1; st <= S_RA_ACK; end
                    else begin fw_i <= fw_i + 10'd1; st <= S_FLUSH_RD; end
                end
            end

            // ---------------- shade sub-phase (shared, ONE tsp pipeline) ----------
            // Invalidate the tile-local plane cache, reset the pixel walk, and
            // start streaming pixels. shade_mode selects which pixels; shade_ret is
            // where we go when the pipe drains.
            S_SHADE_START: begin
                pc_inval <= 1'b1;             // clear the plane cache (1-cyc bulk)
                shp <= 10'd0; sh_out_n <= 0; sh_pending <= 0;
                // prime the streaming front: nothing in flight yet, all 1024 to issue.
                va <= 1'b0; vb <= 1'b0; iss_more <= 1'b1;
                st <= SH_PRESENT;
            end

            // ================= STREAMING shade PRODUCER (1 px/clk good case) =========
            // Three overlapping stages feed tsp_shade_pp, gated together by sh_adv:
            //   L0 issue   : present the peel-buffer read of shp (pb_shrd_* combi); shp++
            //   L1 lookup  : peel result for ida on sh_* -> present the plane-cache read
            //                of its tag (pc_lu_* combi); PEEL-skip !sh_valid_o pixels
            //   L2 present : pc_hit/pc_o_* resolve idb -> drive tsp_shade_pp (pp mux)
            // A cache MISS at L2 freezes the front (sh_adv=0) and branches to the fetch
            // subroutine (FH_*/FV_*/TSP_RUN); on return SH_MPRES presents idb from cur_*.
            // A texture-stall present holds the front in place (sh_adv=0) but re-issues
            // both in-flight reads (see the request block) so sh_*/pc_* stay alive.
            SH_PRESENT: begin
                if (sh_adv) begin
                    // ---- L2 present: a hit was accepted this cycle (sh_adv guarantees
                    //      !(sh_present_v && pp_stall), so a valid hit IS taken). ----
                    if (sh_present_v) hit_count <= hit_count + 1;

                    // ---- L1 -> L2: stage A's resolved pixel enters stage B (its
                    //      plane-cache read was presented THIS cycle -> pc_* next cyc).
                    //      PEEL-skipped pixels (!sh_A_staged) drop as a bubble. ----
                    if (sh_A_staged) begin
                        vb    <= 1'b1;
                        idb   <= ida;
                        tagb  <= sh_tag_o;
                        invwb <= sh_depth_o;
                        sh_pending <= sh_pending + 1;
                    end else begin
                        vb <= 1'b0;
                    end

                    // ---- L0 -> L1: issue the next pixel's peel read (presented THIS
                    //      cycle via pb_shrd_*), advance shp, retire iss_more at 1023. ----
                    if (iss_more) begin
                        va  <= 1'b1;
                        ida <= shp;
                        if (shp == 10'd1023) iss_more <= 1'b0;
                        else                 shp <= shp + 10'd1;
                    end else begin
                        va <= 1'b0;
                    end

                    // ---- drain: front empty and nothing left to issue -> done. ----
                    if (!iss_more && !va && !sh_A_staged) st <= SH_DRAIN;
                end else if (sh_miss) begin
                    // ---- L2 miss: freeze the front, latch idb's context, fetch. The
                    //      slot fields derive from the `sh_tag` reg, but f_rec must use
                    //      tagb NOW (sh_tag updates next cycle). ----
                    miss_count <= miss_count + 1;
                    sh_tag  <= tagb;                 // drives sh_po/sh_toff/... for fetch
                    sh_invw <= invwb;                // idb's depth (fed to the shader)
                    sh_id   <= idb;                  // idb's tile index (fed to the shader)
                    f_rec   <= param_base + {4'd0, tagb[23:3], 2'b00};
                    st <= FH_ISP;
                end
                // else: hit-present held on a texture stall -> hold (front re-issues).
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
                        end
                        tsp_start <= 1'b1; st <= TSP_RUN;
                    end
                    else begin fv_i <= fv_i + 2'd1; f_vtx <= f_vtx + sh_stride_b;
                               fv_fld <= FLD_X; st <= FV_RD; end
                end
                endcase
            end

            // wait for tsp_setup_min; planes stream into cur_* via the tsp_pvalid
            // capture below. On done, commit the WHOLE cur_* bundle to the plane
            // cache in one write (pc_wr_req; u_pc's write ports are wired to sh_tag +
            // cur_*). cur_* is complete by tsp_done (setup emits all planes first).
            TSP_RUN: if (tsp_done) begin
                pc_wr_req <= 1'b1;            // commit the fetched entry to the cache
                st <= SH_MPRES;
            end

            // MISS PRESENT: the plane cache was just filled for idb; present that pixel
            // straight from cur_* (the pp-input mux drives pp_in_valid=1 while here).
            // Hold until the shader accepts (!pp_stall), then RETURN to the stream.
            // The request block re-presents ida's peel read on this accepting cycle
            // (sh_mpres_acc), so stage A's sh_* is fresh when we re-enter SH_PRESENT.
            // Stage B is now empty (idb consumed): vb<=0; stage A (va/ida) survived the
            // fetch and resumes at L1 next cycle.
            SH_MPRES: if (!pp_stall) begin
                vb <= 1'b0;                  // idb consumed (miss already counted)
                st <= SH_PRESENT;
            end

            // all presented pixels drained: return to the caller (shade_ret).
            // sh_out_n counts blend stage-CA events; also wait !cb_valid so the
            // trailing stage-CB col_ram write lands before the next phase (peel pass
            // reads col via the blend dst, or FLUSH reads col_ram). The framebuffer
            // writeout happens later at RSTATE_FLUSH.
            SH_DRAIN: if (sh_out_n >= sh_pending && !cb_valid) begin
                st <= shade_ret;
            end

            S_RA_ACK: st <= S_RA;

            S_DONE: begin
                $display("=== done: %0d triangles rasterized, %0d culled, tsp$ %0d hits / %0d misses ===",
                         tri_count, cull_count, hit_count, miss_count);
`ifndef SYNTHESIS
                $display("=== PERF (active clks=%0d) ===", pc_total);
                $display("  ISP/raster:  RAS=%0d (%0d%%)  POP=%0d  DRAIN=%0d  IDLE=%0d (%0d%%)",
                    pc_ras_active, (pc_ras_active*100)/(pc_total?pc_total:1),
                    pc_ras_pop, pc_ras_drain,
                    pc_ras_idle, (pc_ras_idle*100)/(pc_total?pc_total:1));
                $display("  TSP/shade:   PRESENT=%0d (%0d%%)  TEX_STALL=%0d (%0d%%)  SETUP_WAIT=%0d (%0d%%)",
                    pc_sh_present, (pc_sh_present*100)/(pc_total?pc_total:1),
                    pc_sh_tex_stall, (pc_sh_tex_stall*100)/(pc_total?pc_total:1),
                    pc_sh_setup_wait, (pc_sh_setup_wait*100)/(pc_total?pc_total:1));
                $display("               FETCH=%0d (%0d%%)  CACHE_LOOK=%0d (%0d%%)  DRAIN=%0d  none=%0d",
                    pc_sh_fetch, (pc_sh_fetch*100)/(pc_total?pc_total:1),
                    pc_sh_look, (pc_sh_look*100)/(pc_total?pc_total:1),
                    pc_sh_drain, pc_sh_none);
                $display("  top phases:  SHADE=%0d (%0d%%)  CLEAR=%0d  PEELBUF=%0d  FLUSH=%0d (%0d%%)",
                    pc_top_shade, (pc_top_shade*100)/(pc_total?pc_total:1),
                    pc_top_clear, pc_top_peelbuf,
                    pc_top_flush, (pc_top_flush*100)/(pc_total?pc_total:1));
                $display("               OL_WALK=%0d (%0d%%)  BARRIER=%0d (%0d%%)  other=%0d",
                    pc_top_ol, (pc_top_ol*100)/(pc_total?pc_total:1),
                    pc_top_barrier, (pc_top_barrier*100)/(pc_total?pc_total:1),
                    pc_top_other);
                $display("  resources:   tex_busy=%0d (%0d%%)  isp_setup_busy=%0d (%0d%%)",
                    pc_tex_busy, (pc_tex_busy*100)/(pc_total?pc_total:1),
                    pc_su_busy, (pc_su_busy*100)/(pc_total?pc_total:1));
`endif
                done<=1'b1; st<=S_IDLE;
            end
            default: st<=S_IDLE;
            endcase

            // ======== ENTRY FIFO -> prefetching iterator -> tri FIFO ========
            // The iterator pulls entries itself (entry_valid/entry_ack); we pop the
            // eq FIFO on ack and push its emitted triangles into fq. No it_cst pull
            // FSM / prim_seen: the barrier observes list-done via !it_pf_busy.
            eq_pop    = 1'b0;
            fifo_push = 1'b0;

            // entry FIFO pop when the iterator consumes the head entry
            if (it_entry_ack && !eq_empty) begin
                eq_head <= (eq_head==EQ_N-1) ? 4'd0 : eq_head+4'd1;
                eq_pop  = 1'b1;
            end

            // push emitted triangles into the tri FIFO (hold-until-space handshake)
            if (it_trio.triangle_ready && !fq_full && !it_ack.triangle_done) begin
                fq_ram[fq_tail[2:0]] <= fq_wrw;   // one packed M10K word
                it_ack.triangle_done <= 1'b1;   // advance iterator to next tri
                fq_tail  <= (fq_tail==FIFO_N-1) ? 4'd0 : fq_tail+4'd1;
                fifo_push = 1'b1;
                tri_seen <= tri_seen + 1;
                if (tri_seen % 100 == 0)
                    $display("[TILE %0d,%0d] TRI %0d tag=%08h isp=%08h",
                        cur_tx, cur_ty, tri_seen, it_trio.tag, it_trio.isp);
            end

            // ============ CONSUMER: tri FIFO -> streamed setup -> plane FIFO ============
            fifo_pop = 1'b0;
            pq_push  = 1'b0;

            // present a triangle to the streaming setup; pop fq when accepted.
            // su_in_valid is assigned combinationally outside the always block.
            // accept IS the pop: it consumes the head entry sitting in fq_out.
            if (su_in_valid && su_in_ready) begin
                fq_head <= (fq_head==FIFO_N-1) ? 4'd0 : fq_head+4'd1;
                fifo_pop = 1'b1;
            end

            // ---- FWFT read-ahead: keep fq_out loaded with the head entry ----
            // Reload fq_out when it was just consumed (fifo_pop) or is empty
            // (!fq_out_valid). The source is the post-pop head (fq_nh). An entry is
            // available there iff the occupancy at fq_nh is > 0: that's the current
            // count minus (this cycle's pop) plus (a push landing at fq_nh this cycle).
            // A push whose tail == fq_nh must be BYPASSED from fq_wrw, because the
            // no_rw_check M10K read below would return the OLD word for that address.
            if (fifo_pop || !fq_out_valid) begin
                reg [3:0] fq_nh;                 // next head to present
                reg [4:0] fq_avail;              // entries at/after fq_nh
                reg       fq_push_here;          // this cycle's push targets fq_nh
                fq_nh = fifo_pop ? ((fq_head==FIFO_N-1) ? 4'd0 : fq_head+4'd1) : fq_head;
                // occupancy after this cycle's pop (push is accounted via bypass below)
                fq_avail = fq_count - (fifo_pop ? 5'd1 : 5'd0);
                fq_push_here = fifo_push && (fq_tail[2:0] == fq_nh[2:0]);
                if (fq_push_here) begin
                    fq_out       <= fq_wrw;      // bypass: RAM would return stale word
                    fq_out_valid <= 1'b1;
                end else if (fq_avail != 0) begin
                    fq_out       <= fq_ram[fq_nh[2:0]];   // registered M10K read
                    fq_out_valid <= 1'b1;
                end else begin
                    fq_out_valid <= 1'b0;        // nothing to present next cycle
                end
            end

            // retire: on out_valid, push non-culled triangles into the plane FIFO.
            if (su_out_valid) begin
                if (isp_cull) begin
                    cull_count <= cull_count + 1;
                end else begin
                    pq_ram[pq_tail[2:0]] <= pq_wrw;   // one packed M10K word
                    pq_tail <= (pq_tail==PQ_N-1) ? 4'd0 : pq_tail+4'd1;
                    pq_push  = 1'b1;
                end
            end

            // ---- RASTER: pop plane FIFO -> active planes -> BOUNDING-BOX sweep ----
            // Only sweep the chunks/rows the triangle's tile-local bbox covers.
            // x bounds are chunk-aligned (down to a RAS_LANES-wide chunk); rows go
            // by0..by1 inclusive. The rasterizer's inside-test still gates writes.
            pq_pop = 1'b0;
            case (rs_st)
            RS_IDLE: if (!pq_empty) begin
                // issue the M10K read; head advances now, data lands in pq_rdw next cyc
                pq_rdw <= pq_ram[pq_head[2:0]];
                pq_head <= (pq_head==PQ_N-1) ? 4'd0 : pq_head+4'd1;
                pq_pop  = 1'b1;
                rs_st   <= RS_POP;
            end
            RS_POP: begin
                // pq_rdw now holds the popped entry: splice it into the active planes.
                isp_dx12<=pq_rdw[QF_DX12 +:32]; isp_dx23<=pq_rdw[QF_DX23 +:32];
                isp_dx31<=pq_rdw[QF_DX31 +:32]; isp_dx41<=pq_rdw[QF_DX41 +:32];
                isp_dy12<=pq_rdw[QF_DY12 +:32]; isp_dy23<=pq_rdw[QF_DY23 +:32];
                isp_dy31<=pq_rdw[QF_DY31 +:32]; isp_dy41<=pq_rdw[QF_DY41 +:32];
                isp_c1<=pq_rdw[QF_C1 +:32]; isp_c2<=pq_rdw[QF_C2 +:32];
                isp_c3<=pq_rdw[QF_C3 +:32]; isp_c4<=pq_rdw[QF_C4 +:32];
                isp_ddx_invw<=pq_rdw[QF_DDX +:32]; isp_ddy_invw<=pq_rdw[QF_DDY +:32];
                isp_c_invw<=pq_rdw[QF_CINVW +:32];
                isp_word<=pq_rdw[QF_ISP +:32]; tri_tag<=pq_rdw[QF_TAG +:32];
                tri_count<=tri_count+1;
                // chunk-aligned x range + row range from the bbox
                rbx0 <= pq_rdw[QF_BX0 +:5] & 5'(~(RAS_LANES-1));
                rbx1 <= pq_rdw[QF_BX1 +:5] & 5'(~(RAS_LANES-1));
                rby1 <= pq_rdw[QF_BY1 +:5];
                ras_y <= pq_rdw[QF_BY0 +:5];
                ras_x <= pq_rdw[QF_BX0 +:5] & 5'(~(RAS_LANES-1));
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
            // also wait for the depth-cmp write-back (stage B, b_valid) to land, else
            // the NEXT triangle's stage-A read races this triangle's last stage-B
            // write to the same peel-RAM word (RAW -> stale depth -> corruption).
            RS_DRAIN: if (ras_inflight==0 && !ras_in_valid && !ras_out_valid
                          && !b_valid) rs_st<=RS_IDLE;
            endcase

            // ---- FIFO count maintenance (single update; push/pop may coincide) ----
            fq_count <= fq_count + (fifo_push ? 5'd1 : 5'd0) - (fifo_pop ? 5'd1 : 5'd0);
            eq_count <= eq_count + (eq_push  ? 5'd1 : 5'd0) - (eq_pop   ? 5'd1 : 5'd0);
            pq_count <= pq_count + (pq_push  ? 5'd1 : 5'd0) - (pq_pop   ? 5'd1 : 5'd0);

            // plane stream capture (runs regardless of FSM state). Only cur_* is
            // filled now; the whole bundle is committed to the plane cache in one
            // pc_wr_req at TSP_RUN (no per-plane cache writes).
            if (tsp_pvalid) begin
                cur_ddx[tsp_pidx] = tsp_pddx;
                cur_ddy[tsp_pidx] = tsp_pddy;
                cur_c[tsp_pidx]   = tsp_pc;
            end
        end
    end
endmodule

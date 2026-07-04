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
    // Real hardware (MiSTer) has ONE 64-bit DDR read channel. All SEVEN clients -
    // region array (ra), object list (ol), ISP param/vertex (pr), the DEMAND record
    // fetcher (ts, was the single TSP-param fetcher), the record PREFETCHER (pf),
    // and the two 4-read-port texture caches (tc data, vq codebook) - are
    // arbitrated onto the INJECTED single-channel DDR controller (ddr_req/ddr_resp;
    // one read in flight). Priority (high->low): tc, vq, ts(demand), pr, ol, ra, pf
    // (prefetch) - shade-critical clients win, geometry fills between, and the
    // best-effort record PREFETCH is LOWEST so it never delays a demand read (it
    // only warms lines when the channel is otherwise idle). Per-client PENDING latch
    // captures each 1-cycle rd pulse so a request is never lost while the channel
    // is busy elsewhere. The controller (faux or real Avalon) owns latency+burst.
    ddr_rd_req_t  ra_dreq, ol_dreq, pr_dreq, ts_dreq;
    ddr_rd_resp_t ra_dresp, ol_dresp, pr_dresp, ts_dresp;
    ddr_rd_req_t  tex_dreq [0:1];      // [0]=tc data, [1]=vq codebook
    ddr_rd_resp_t tex_dresp [0:1];

    // 0=tc 1=vq 2=ts(record fetch: demand OR prefetch, muxed) 3=pr 4=ol 5=ra
    // (priority high->low). The demand fetcher and prefetcher SHARE the ts client:
    // the prefetch only runs when the demand fetcher is idle (mutually exclusive), so
    // one DDR port suffices (see the record_fetcher mux below).
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
    wire                   sh_pt_o;             // <- PT-list-won bit (blend alpha-test)
    wire [RAS_LANES-1:0]   b_pass_lp;           // per-lane peel accept (for dt_pt)
    wire [RAS_LANES-1:0]   b_more;              // per-lane MoreToDraw
    wire [RAS_LANES-1:0]   b_we;                // per-lane stage-B accept (-> u_taginvw)

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
    reg  [31:0] t_xbase, t_ybase;          // ISP's current tile origin (raster/ISP setup)
    // SPANNER's OWN tile origin: the spanner runs BEHIND ISP and may be shading an
    // earlier tile, so tsp_setup_min (u_tsp) must use the xbase/ybase of the tile the
    // SPANNER is resolving, NOT ISP's live t_xbase. Latched per pass at P_IDLE from the
    // handed-off tile coords (ti_tx/ti_ty).
    reg  [5:0]  spn_tx, spn_ty;
    reg  [31:0] spn_xbase, spn_ybase;
    reg         pc_cold;                   // force plane-cache inval on the first pass
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
        .b_pass_lp(b_pass_lp), .b_more(b_more), .b_we(b_we),
        // shade single-pixel read: MOVED to the split-out u_taginvw handoff buffer.
        // u_peel stays ISP-private (depth compare + PeelBuffers only); its shade port
        // is tied off.
        .sh_rd_valid(1'b0), .sh_rd_id(10'd0),
        .sh_valid(), .sh_tag(), .sh_depth(),
        // CLEAR
        .clr_valid(pb_clr_valid), .clr_addr(pb_clr_addr),
        .clr_depth(regs.isp_backgnd_d), .clr_tag(regs.isp_backgnd_t),
        // PeelBuffers RMW walk
        .pb_rd_valid(pb_bufrd_valid), .pb_rd_addr(pb_bufrd_addr),
        .pb_wr_valid(pb_bufwr_valid), .pb_wr_addr(pb_bufwr_addr),
        .pb_first(first_peel)
    );

    // ---- PING-PONG ISP->TSP handoff buffer (u_taginvw): the {valid,tag,invW} slice
    // TSP shade reads, split out of u_peel so it can be double-buffered. ISP stage-B
    // writes a DUPLICATE of its u_peel accept into the PRODUCER half (tag_prod); TSP
    // shade reads the CONSUMER half (tag_cons). With tag_prod==tag_cons this is exactly
    // today's single-buffer behavior; advancing the toggles at tile handoff (Milestone
    // 2) lets ISP rasterize tile N+1 into the other half while TSP shades tile N. ----
    // TWO independent ping-pong indices:
    //  * u_taginvw {tag,invW} is PER-PASS: htile = the half ISP rasters/CLEARs a shade-
    //    input into (flips each raster pass); tsp_tag = the half TSP reads. Per-pass so
    //    raster pass P+1 fills one half while TSP shades pass P from the other.
    //  * u_col is PER-TILE and ping-pongs only TSP<->VO: tsp_col = the half TSP blends a
    //    whole tile's passes into (flips only when TSP posts a finished tile), col_vo =
    //    the half VO drains.
    reg          htile;                  // ISP u_taginvw producer half (per pass)
    reg          tsp_tag;                // TSP u_taginvw consumer half (per pass)
    reg          tsp_col;               // TSP u_col blend half (per tile)
    wire         tag_prod = htile;       // half ISP raster/CLEAR writes
    wire         tag_cons = tsp_tag;     // half TSP shade reads
    wire         sh_valid_h [0:1];
    wire         sh_pt_h    [0:1];
    wire [31:0]  sh_tag_h   [0:1], sh_depth_h [0:1];
    genvar gti;
    generate
      for (gti = 0; gti < 2; gti = gti + 1) begin : gtibuf
        wire ti_prod = (tag_prod == gti[0]);
        wire ti_cons = (tag_cons == gti[0]);
        taginvw_tile_buffer #(.LANES(RAS_LANES)) u_taginvw (
            .clk(clk), .reset(reset),
            // stage-B accept duplicate (producer half only)
            .wr_valid(ti_prod && b_valid), .wr_we(b_we),
            .wr_y(b_oy), .wr_x(b_ox), .wr_tag(b_tag), .wr_invw(b_invw),
            .wr_pt(b_peeling && (b_which==1'b0)),   // PT alpha-test enable (peel + PT list)
            // CLEAR (producer half only)
            .clr_valid(ti_prod && pb_clr_valid), .clr_addr(pb_clr_addr),
            .clr_depth(regs.isp_backgnd_d), .clr_tag(regs.isp_backgnd_t),
            // PeelBuffers valid-clear walk (producer half; mirrors u_peel's pb write)
            .pbc_valid(ti_prod && pb_bufwr_valid), .pbc_addr(pb_bufwr_addr),
            // shade single-pixel read (consumer half only)
            .sh_rd_valid(ti_cons && pb_shrd_valid), .sh_rd_id(pb_shrd_id),
            .sh_valid(sh_valid_h[gti]), .sh_tag(sh_tag_h[gti]), .sh_depth(sh_depth_h[gti]),
            .sh_pt(sh_pt_h[gti]),
            // 4-wide aligned read (spanner_v2) - tied off until the spanner integration
            .rd4_valid(1'b0), .rd4_group('0),
            .g4_valid(), .g4_tag(), .g4_invw(), .g4_pt()
        );
      end
    endgenerate
    assign sh_valid_o = sh_valid_h[tsp_tag];
    assign sh_tag_o   = sh_tag_h  [tsp_tag];
    assign sh_depth_o = sh_depth_h[tsp_tag];
    assign sh_pt_o    = sh_pt_h   [tsp_tag];

    // ---- PING-PONG color buffer (2 halves): TSP blend fills the half of the tile it
    // is shading (col_prod = tsp_half); the decoupled video-out engine drains col_vo.
    // A finished tile's color is posted to VO (by TSP, on a last-flagged shade), so
    // ISP/TSP shade the next tile's color into the other half while VO streams this
    // one to the framebuffer. ----
    wire         col_prod = tsp_col;     // TSP blends a whole tile into this u_col half
    reg          col_vo;                 // which half VO reads out
    wire [31:0]  col_rd_argb_h [0:1];    // per-half registered read
    // blend (CA read / CB write) targets the producer half only; FLUSH read targets
    // the VO half only. gcol picks per-instance whether it is prod or vo this cycle.
    genvar gcol;
    generate
      for (gcol = 0; gcol < 2; gcol = gcol + 1) begin : gcolbuf
        wire is_prod = (col_prod == gcol[0]);
        wire is_vo   = (col_vo   == gcol[0]);
        color_tile_buffer #(.DEPTH(TILE_W*TILE_H)) u_col (
            .clk(clk), .reset(reset),
            .bl_ca_valid(is_prod && cb_ca_valid), .bl_ca_id(cb_ca_id),
            .bl_cb_valid(is_prod && cb_valid), .cb_id(cb_id), .cb_argb(cb_argb),
            .cb_tsp(cb_tsp), .cb_at_en(cb_at_en), .alpha_ref(regs.pt_alpha_ref[7:0]),
            .fl_rd_valid(is_vo && cb_fl_valid), .fl_id(cb_fl_id),
            .rd_argb(col_rd_argb_h[gcol])
        );
      end
    endgenerate
    // blend dst read comes from the producer half; VO read from the VO half.
    assign col_rd_argb    = col_rd_argb_h[col_prod];   // blend dst (CA)
    wire [31:0] vo_rd_argb = col_rd_argb_h[col_vo];    // VO flush pixel

    // ============ SPANNER -> TSP ping-pong span buffers (resolved shade inputs) ======
    // The spanner (spn FSM) resolves every pixel's planes (plane/setup cache + prefetch)
    // and WRITES the full tsp_shade_pp input into spn_buf[spn_prod]. The trivial TSP
    // reader drains spn_buf[tsp_rd] at 1 px/clk. Per-half ready credit sb_ready[h] (set
    // by the spanner when a pass's buffer is complete, cleared by TSP when drained) +
    // per-half metadata (mode/last/postonly/coords) - same handshake shape as u_taginvw.
    reg          spn_prod;               // half the spanner writes (per pass)
    reg          tsp_rd;                 // half the TSP reader drains (per pass)
    reg  [1:0]   sb_ready;               // per-half: spanner done, awaiting TSP
    reg          sb_last [0:1];          // per-half: tile's final shade -> post color
    reg          sb_post [0:1];          // per-half: post-only (OP-only FLUSH, no shade)
    reg  [5:0]   sb_tx [0:1], sb_ty [0:1];
    // spanner write port (combinational drive from the spn FSM below)
    reg          sbw_we;
    reg  [9:0]   sbw_addr;
    reg          sbw_shade;
    reg          sbw_at;                 // PT alpha-test enable
    reg  [31:0]  sbw_invw, sbw_tsp, sbw_tcw;
    reg          sbw_ptex, sbw_pofs;
    reg  [31:0]  sbw_ddx [0:9], sbw_ddy [0:9], sbw_c [0:9];
    // TSP reader read port
    reg  [9:0]   sbr_addr;
    wire         sbr_shade [0:1];
    wire         sbr_at [0:1];
    wire [31:0]  sbr_invw [0:1], sbr_tsp [0:1], sbr_tcw [0:1];
    wire         sbr_ptex [0:1], sbr_pofs [0:1];
    wire [31:0]  sbr_ddx [0:1][0:9], sbr_ddy [0:1][0:9], sbr_c [0:1][0:9];
    genvar gsb;
    generate
      for (gsb = 0; gsb < 2; gsb = gsb + 1) begin : gspanbuf
        wire sb_is_prod = (spn_prod == gsb[0]);
        span_buffer #(.DEPTH(TILE_W*TILE_H)) u_span (
            .clk(clk),
            .we(sb_is_prod && sbw_we), .waddr(sbw_addr),
            .w_shade(sbw_shade), .w_at(sbw_at), .w_invw(sbw_invw),
            .w_ptex(sbw_ptex), .w_pofs(sbw_pofs),
            .w_tsp(sbw_tsp), .w_tcw(sbw_tcw),
            .w_ddx(sbw_ddx), .w_ddy(sbw_ddy), .w_c(sbw_c),
            .raddr(sbr_addr),
            .r_shade(sbr_shade[gsb]), .r_at(sbr_at[gsb]), .r_invw(sbr_invw[gsb]),
            .r_ptex(sbr_ptex[gsb]), .r_pofs(sbr_pofs[gsb]),
            .r_tsp(sbr_tsp[gsb]), .r_tcw(sbr_tcw[gsb]),
            .r_ddx(sbr_ddx[gsb]), .r_ddy(sbr_ddy[gsb]), .r_c(sbr_c[gsb])
        );
      end
    endgenerate

    // ---- DECOUPLED VIDEO-OUT (FLUSH) engine + color-buffer credit handshake ----
    // Each color half carries a 1-bit "full" credit col_full[h]: the TSP side sets it
    // when it HANDS a finished tile's color to VO (posting the tile coords), the VO
    // engine clears it when the flush completes. TSP can only start blending into
    // col_prod when that half is FREE (!col_full[col_prod]); with 2 halves this lets
    // ISP/TSP shade tile N+1 while VO streams tile N. vo_tx/vo_ty are the coords of
    // the half VO is currently draining (latched per posted buffer).
    reg  [1:0]  col_full;                 // per-half: holds a finished tile for VO
    reg  [5:0]  col_tx [0:1];             // per-half posted tile x
    reg  [5:0]  col_ty [0:1];             // per-half posted tile y
    reg  [5:0]  vo_tx, vo_ty;             // coords of the half VO is draining
    reg  [9:0]  vo_i;                     // VO writeout pixel 0..1023
    localparam VO_IDLE=2'd0, VO_RD=2'd1, VO_WR=2'd2;
    reg  [1:0]  vst;                      // video-out FSM state
    // TSP posts a finished color buffer to VO: sets the credit, latches coords, flips
    // the producer half. Driven as a 1-cycle intent from the main FSM (see FLUSH).
    reg         col_post;                 // 1-cyc: hand col_prod to VO
    reg         col_post_hp;              // which half is being posted
    reg  [5:0]  col_post_tx, col_post_ty; // coords to post
    reg         ra_done_l;                // latched region-array-done (pulse is 1-cyc)

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

    // ---- SPANNER walk state (resolve every pixel's planes -> span buffer) ----
    // The spanner walks x = 0..1023 of the CONSUMER u_taginvw half (tsp_tag), resolves
    // each pixel's planes (plane cache hit, or DDR fetch + tsp_setup_min on a miss) and
    // WRITES the full shade record into span_buffer[spn_prod][x]. sh_tag/sh_invw/sh_id
    // are the pixel currently being resolved (also feed the fetch + cache write on a miss).
    reg [9:0]  spx;           // the tile pixel 0..1023 the spanner is resolving
    // ---- PIPELINED resolve (L0/L1/L2, 1 px/clk on hits; like M2's shade front but
    // writing the span buffer instead of the shader). L0: present u_taginvw read of
    // spx. L1(va/ida): sh_* resolved -> present plane-cache lookup. L2(vb/idb/..):
    // pc_hit/pc_o_* resolved -> WRITE span buffer (hit) / miss -> freeze + fetch. ----
    reg        sva;           // L1 occupied (u_taginvw read in flight for sida)
    reg [9:0]  sida;
    reg        svb;           // L2 occupied (plane-cache read in flight for sidb)
    reg [9:0]  sidb;
    reg [31:0] stagb;         // sidb's tag (for a miss)
    reg [31:0] sinvwb;        // sidb's invW
    reg        satb;          // sidb's PT alpha-test bit
    reg        sstaged;       // sidb is shaded this pass (else a shade=0 skip write)
    reg        siss_more;     // still pixels to ISSUE at L0 (spx<=1023)
    reg [31:0] sh_tag;        // the resolving pixel's CoreTag (drives fetch + cache write)
    reg [31:0] sh_invw;       // the resolving pixel's depth-buffer invW (-> span buffer)
    reg [9:0]  sh_id;         // the resolving pixel's tile index (-> span buffer addr)
    reg        sh_at;         // the resolving pixel's PT alpha-test enable (-> span buffer)

    // plane-cache slot hash (ONE definition, used by both the write path (sh_slot) and
    // the lookup path (pc_lu_slot_c) so they can never diverge): param_offs low bits XOR
    // tag_offset (strip triangles share param_offs, so ^tag[2:0] spreads them across
    // slots). (A wider tag[14:9]^tag[8:3]^tag[2:0] hash was tried but measured 2-3% MORE
    // misses over the full scene; the 1-entry victim cache absorbs the residual pairwise
    // aliasing this simpler hash leaves.)
    function automatic [5:0] pc_slot(input [31:0] tag);
        pc_slot = tag[8:3] ^ {3'b000, tag[2:0]};
    endfunction

    wire [5:0] sh_slot = pc_slot(sh_tag);

    // plane-cache lookup address for THIS cycle (pipelined; see the request block).
    // The read port is driven from L1 (a fresh peel result) or, while a present is
    // stalled on a texture miss, re-driven for stage B to hold pc_hit/pc_o_* alive.
    reg  [31:0] pc_lu_tag_c;
    wire [5:0]  pc_lu_slot_c = pc_slot(pc_lu_tag_c);

    // ==================== TWO record_fetchers: demand + prefetch ====================
    // The param-record fetch+decode (GetFpuEntry: fetch isp/tsp/tcw + stream the 3
    // vertices) lives in record_fetcher, instantiated TWICE to give the spanner a
    // 2-deep record cache so a prefetched record doesn't thrash the demand fetch:
    //   * u_fetch    (DEMAND)   : on a plane-cache miss the spanner starts it and waits
    //                             its done, then latches o_* into cur_*/fv_* and runs
    //                             tsp_setup_min + P_TSP_RUN as before. DDR client `ts`.
    //   * u_prefetch (PREFETCH) : the SCAN sub-FSM (pf_st) runs it on the next uncached
    //                             tag during P_TSP_RUN's setup wait; its done sets the
    //                             prefetch shadow (pf_ready/pf_rtag). A later demand miss
    //                             whose tag matches the shadow is PROMOTED (no demand
    //                             fetch). DDR client `pf` (lowest priority).
    // Each owns an internal burst-8 8-word sliding-window line reader (tw0 demand line +
    // tw1 sequential-prefetch line); decode semantics are identical to the old inline
    // FH_/FV_ FSM.
    // Both record_fetchers SHARE the single `ts` DDR client. They are mutually
    // exclusive: the prefetch only starts when the demand fetcher is idle (!fx_busy),
    // so at most one drives DDR at a time. Mux their dreq onto ts_dreq; ts_dresp fans
    // to both (only the active one consumes it).
    ddr_rd_req_t  fx_dreq, pf_dreq;
    reg          fx_start;                 // 1-cyc: start the DEMAND fetch
    reg  [31:0]  fx_tag;                   // demand fetch tag
    wire         fx_busy, fx_done;
    wire [31:0]  fx_isp, fx_tsp, fx_tcw;
    wire [31:0]  fx_x[0:2], fx_y[0:2], fx_z[0:2];
    wire [31:0]  fx_u[0:2], fx_v[0:2], fx_col[0:2], fx_ofs[0:2];
    record_fetcher u_fetch (
        .clk(clk), .reset(reset),
        .start(fx_start), .tag(fx_tag), .param_base(param_base),
        .intensity_shadow(regs.fpu_shad_scale.intensity_shadow),
        .busy(fx_busy), .done(fx_done),
        .o_isp(fx_isp), .o_tsp(fx_tsp), .o_tcw(fx_tcw),
        .o_x(fx_x), .o_y(fx_y), .o_z(fx_z),
        .o_u(fx_u), .o_v(fx_v), .o_col(fx_col), .o_ofs(fx_ofs),
        .dreq(fx_dreq), .dresp(ts_dresp)
    );

    reg          pf_start;                 // 1-cyc: start the PREFETCH
    reg  [31:0]  pf_ptag;                  // prefetch tag
    wire         pf_busy, pf_done;
    wire [31:0]  pfr_isp, pfr_tsp, pfr_tcw;
    wire [31:0]  pfr_x[0:2], pfr_y[0:2], pfr_z[0:2];
    wire [31:0]  pfr_u[0:2], pfr_v[0:2], pfr_col[0:2], pfr_ofs[0:2];
    record_fetcher u_prefetch (
        .clk(clk), .reset(reset),
        .start(pf_start), .tag(pf_ptag), .param_base(param_base),
        .intensity_shadow(regs.fpu_shad_scale.intensity_shadow),
        .busy(pf_busy), .done(pf_done),
        .o_isp(pfr_isp), .o_tsp(pfr_tsp), .o_tcw(pfr_tcw),
        .o_x(pfr_x), .o_y(pfr_y), .o_z(pfr_z),
        .o_u(pfr_u), .o_v(pfr_v), .o_col(pfr_col), .o_ofs(pfr_ofs),
        .dreq(pf_dreq), .dresp(ts_dresp)
    );
    // share the ts client: the two fetchers are mutually exclusive (prefetch only runs
    // when the demand fetcher is idle; a demand miss waits in P_PF_WAIT if a prefetch is
    // in flight), so at most one asserts dreq.rd at a time. Mux by WHICH is requesting
    // (request-driven, NOT busy-driven) so a read is never dropped: a busy-driven mux
    // could point at the idle fetcher while the active one pulses .rd -> lost read ->
    // that fetcher stuck in TF_MISS forever -> deadlock.
    assign ts_dreq.rd    = fx_dreq.rd | pf_dreq.rd;
    assign ts_dreq.addr  = fx_dreq.rd ? fx_dreq.addr  : pf_dreq.addr;
    assign ts_dreq.burst = fx_dreq.rd ? fx_dreq.burst : pf_dreq.burst;

    // prefetch shadow: u_prefetch's decoded record is held here (its outputs are wires,
    // so latch a stable copy at pf_done) until a demand miss consumes it or a fresh
    // prefetch overwrites it. pf_ready set at pf_done, cleared when promoted/consumed.
    reg          pf_ready;                 // shadow holds a valid decoded record
    reg  [31:0]  pf_rtag;                  // the tag the shadow decoded
    reg  [31:0]  ps_isp, ps_tsp, ps_tcw;
    reg  [31:0]  ps_x[0:2], ps_y[0:2], ps_z[0:2];
    reg  [31:0]  ps_u[0:2], ps_v[0:2], ps_col[0:2], ps_ofs[0:2];

    // fetched vertices (3) - the DEMAND record's decoded verts (feed tsp_setup_min).
    // Latched from a promoted shadow or from u_fetch's o_* when the demand fetch lands.
    reg [31:0] fv_x[0:2], fv_y[0:2], fv_z[0:2];
    reg [31:0] fv_u[0:2], fv_v[0:2], fv_col[0:2], fv_ofs[0:2];

    // decoded isp flags of the demand record (drive tsp_setup_min off cur_isp)
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
        .xbase(spn_xbase), .ybase(spn_ybase),   // the SPANNER's tile origin (not ISP's)
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
    reg  [10:0]  pp_in_id;    // [9:0]=pixel id, [10]=PT alpha-test enable (rides through)
    reg  [4:0]   pp_px, pp_py;
    reg  [31:0]  pp_invw;
    reg  [31:0]  pp_tsp, pp_tcw; reg pp_ptex, pp_pofs;
    reg  [31:0]  pp_ddx [0:9];
    reg  [31:0]  pp_ddy [0:9];
    reg  [31:0]  pp_c   [0:9];
    wire         pp_stall;
    wire         pp_out_valid;
    wire [10:0]  pp_out_id;   // [9:0]=pixel id, [10]=PT alpha-test enable
    wire [31:0]  pp_out_argb;
    wire [31:0]  pp_out_tsp;

    tsp_shade_pp #(.IDW(11)) u_shade (
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
               // unified PT+TL peel loop: init pb2, PeelBuffers, run, check
               S_PEEL_INIT=28, S_PEEL_BUF=29,
               S_OP_DONE=32,
               // M10K bulk-op walks over the peel RAM ports (128 chunk addrs each):
               S_CLEAR_WR=34,              // CLEAR: write {bg_depth, bg_tag} chunks
               S_PEEL_BUF_RUN=35;          // PeelBuffers RMW walk (read A -> write B)
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
    reg        shade_mode;   // latched by TSP from ti_mode[] at T_IDLE
    integer    sh_pending;   // pixels presented this shade sub-phase (PEEL skips some)

    // ---- CONCURRENT TSP shade FSM (tst) + ISP<->TSP handshake (Milestone 2) ----
    // The shade sub-phase is now its own state machine (tst), stepped every cycle in
    // the SAME always block as the ISP FSM (st) and the raster consumer (rs_st) - like
    // rs_st, it runs CONCURRENTLY with st. This lets the ISP FSM rasterize tile N+1 (its
    // CLEAR + OP/peel raster into the OTHER u_taginvw/u_col half) while the TSP FSM
    // still shades tile N. Cross-FSM handshake (all regs written only in this one block,
    // so no multi-driver):
    // PER-HALF READY CREDIT (ping-pong producer/consumer, like ISP->TSP and TSP->VO):
    //   ti_ready[h] : ISP has finished rastering a shade-input into u_taginvw half h;
    //                 TSP may shade it. Set by ISP when a raster pass/OP completes,
    //                 CLEARED by TSP when it finishes shading h. Per-half metadata:
    //                 ti_mode (OP/PEEL), ti_last (final shade of the tile -> post color
    //                 to VO on drain), ti_tx/ti_ty (tile coords for the post).
    // ISP toggles htile per raster PASS (not just per tile): shade pass P reads half A
    // while raster pass P+1 writes half B -> raster P+1 OVERLAPS shade P. ISP stalls
    // before rastering into a half that is still ti_ready (TSP hasn't consumed it).
    // ---- SPANNER FSM (spn): OWNS plane cache / word reader / setup / cur_* ----
    // Walks x=0..1023 of the CONSUMER u_taginvw half, resolving each pixel's planes and
    // writing the full shade record into span_buffer[spn_prod]. PIPELINED L0/L1/L2 (like
    // M2's shade front) so hits resolve at 1 px/clk; a plane-cache MISS freezes the
    // pipeline and runs the param/vertex fetch + tsp_setup_min:
    //   P_RUN    : the L0/L1/L2 pipeline (L0 taginvw read, L1 cache lookup, L2 buf write)
    //   P_FETCH_W: wait for u_fetch.done (the DEMAND record_fetcher decodes the miss),
    //              then latch o_* -> cur_*/fv_*. A miss whose tag == the prefetch shadow
    //              (pf_ready && pf_rtag==sh_tag) SKIPS this: it latches the shadow and
    //              jumps straight to P_TSP_RUN (ZERO demand fetch).
    //   P_TSP_RUN: run tsp_setup_min on cur_*/fv_*, commit cur_* to the plane cache.
    //   P_MPRES  : write cur_* (just fetched) into the span buffer for sidb; resume P_RUN
    //   P_PF_WAIT: a prefetch is in flight at miss time -> wait for it (don't start a
    //              redundant/colliding demand fetch), then promote-or-fetch.
    localparam P_IDLE=0, P_RUN=1, P_MPRES=2, P_PF_WAIT=3,
               P_FETCH_W=4, P_TSP_RUN=10, P_DONE=12;
    reg [3:0]  spn;
    // pipelined resolve control (combinational; mirrors M2's shade front):
    wire spn_run     = (spn == P_RUN);
    // L1 staged: the pixel on sh_* (sida) is shaded this pass.
    wire spn_A_stg   = sva && (shade_mode ? sh_valid_o : 1'b1);
    // L2 resolved this cycle: pc_hit/pc_o_* correspond to sidb (looked up last cycle),
    // but only meaningful when sidb was staged (sstaged). A miss freezes + fetches.
    wire spn_miss    = spn_run && svb && sstaged && !pc_hit;
    wire spn_adv     = spn_run && !spn_miss;   // no texture stall here (that's downstream)

    // ==================== SCAN-PREFETCH (decode the NEXT miss's record under this
    // miss's SETUP_WAIT, into u_prefetch's 2-deep shadow) ====================
    // While the spanner sits in P_TSP_RUN waiting on tsp_done, the pipeline is frozen
    // so the u_taginvw shade-read port (pb_shrd) and the plane-cache lookup port (pc_lu)
    // are idle, AND the demand fetcher (u_fetch) is done. This best-effort sub-FSM
    // (pf_st) uses those idle ports to SCAN FORWARD from the next pixel for the NEXT tag
    // that MISSES the cache (and is staged), then FULLY DECODES that miss's record into
    // the SECOND record_fetcher (u_prefetch) - not just warming DDR lines, but producing
    // a ready-to-use decoded record held in the prefetch shadow (pf_ready/pf_rtag/ps_*).
    // When the spanner later returns to P_RUN and reaches that pixel, its demand miss is
    // PROMOTED from the shadow with ZERO demand fetch (see P_RUN miss path). It NEVER
    // touches the demand fetch state (u_fetch/cur_*/fv_*) - only u_prefetch. It NEVER
    // stalls/extends P_TSP_RUN: the instant tsp_done arrives, P_TSP_RUN proceeds and
    // pf_st returns to PF_OFF, abandoning any partial scan (a started u_prefetch keeps
    // running on its own DDR client and lands in the shadow whenever it finishes; only
    // ONE prefetch is ever in flight, gated by !pf_busy). Prefetch is 1-deep; a wrong/
    // partial prefetch just means a cold demand fetch later (no correctness impact).
    localparam PF_OFF=0, PF_SCAN0=1, PF_SCAN1=2, PF_SCAN2=3, PF_ISSUE=4, PF_DONE=5;
    reg [2:0]  pf_st;
    reg [9:0]  pf_scan;       // next pixel to examine at PF_SCAN0
    reg        pf_sv;         // PF_SCAN0->1: a taginvw read is in flight for pf_sid
    reg [9:0]  pf_sid;        // pixel id whose taginvw read is in flight
    reg [31:0] pf_tag;        // the found-miss tag (issued to u_prefetch)
    // pf drives the shade-read port while presenting a scan read (PF_SCAN0), and the
    // plane-cache lookup port the cycle after (PF_SCAN1, tag now resolved on sh_tag_o).
    wire       pf_drive_shrd = (pf_st == PF_SCAN0);
    wire       pf_drive_lu   = (pf_st == PF_SCAN1);

    // ---- TSP READER FSM (tsp_st): drains span_buffer[tsp_rd] -> tsp_shade_pp ----
    //   R_IDLE : pick a ready half (sb_ready[tsp_rd]); post-only -> R_POST
    //   R_RUN  : STREAMING 1 px/clk. sbr_addr=tsp_i presents pixel tsp_i's read; the
    //            pixel FED this cycle is the one presented last cycle (rd_i, rd_v). Hold
    //            on pp_stall. rd_last marks the final pixel.
    //   R_DRAIN: all fed; wait blend to drain (sh_out_n>=sh_pending && !cb_valid)
    //   R_POST : post the finished tile's u_col to VO (on sb_last)
    localparam R_IDLE=0, R_RUN=1, R_DRAIN=3, R_POST=4;
    reg [2:0]  tsp_st;
    reg [9:0]  tsp_i;         // reader pixel index being PRESENTED (raddr) this cycle
    reg [9:0]  rd_i;          // pixel whose data is on sbr_* now (presented last cycle)
    reg        rd_v;          // rd_i valid (a read was presented last cycle)
    reg        rd_last;       // rd_i is the last pixel (1023)

    reg  [1:0] ti_ready;      // per-half: rastered, awaiting shade
    reg        ti_mode [0:1]; // per-half OP(0)/PEEL(1)
    reg        ti_last [0:1]; // per-half: this is the tile's final shade -> post color
    reg        ti_postonly[0:1]; // per-half: no shade, just post u_col to VO (OP-only
                                 // tile's FLUSH: color already accumulated by the OP shade)
    reg  [5:0] ti_tx [0:1], ti_ty [0:1];  // per-half tile coords (for the VO post)

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
    // ---- SPANNER pipeline probe: are passes/pixels being dropped? ----
    // pc_hand  = passes ISP hands to the spanner (ti_ready sets, incl. post-only)
    // pc_span  = passes the spanner finishes (P_DONE + post-only, sets sb_ready)
    // pc_drain = passes the reader finishes (R_DRAIN + R_POST)
    // pc_blend = pixels blended into u_col (cb_valid pulses)
    // pc_swrite= span-buffer writes with shade=1 (pixels the spanner marked shaded)
    // If pc_hand != pc_span != pc_drain -> passes dropped. If pc_swrite != pc_blend
    // (over the run) -> per-pixel drop between span-fill and blend.
    integer pc_hand, pc_span, pc_drain, pc_blend, pc_swrite;
    // pc_prefetch = SCAN-prefetches issued (a next-miss found -> u_prefetch started
    // under P_TSP_RUN's SETUP_WAIT). pc_pf_hit = demand misses SERVED from the prefetch
    // shadow (pf_ready && pf_rtag==tag) -> zero demand fetch. Best-effort overlap metric.
    integer pc_prefetch, pc_pf_hit;
    integer pc_pf_wasted;   // a READY shadow clobbered by a new prefetch, never consumed
    // miss-classification leak counters: why a demand miss did NOT promote.
    integer pc_m_promote;   // shadow ready + tag match at miss (zero-wait hit)
    integer pc_m_waithit;   // prefetch in flight -> P_PF_WAIT -> matched (hit after wait)
    integer pc_m_waitmiss;  // prefetch in flight -> P_PF_WAIT -> WRONG tag -> demand fetch
    integer pc_m_cold;      // no prefetch in flight/ready -> straight demand fetch
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
    // ---- 3-ENGINE occupancy cross-tab: which of {ISP, SPANNER, TSP} are busy each
    // cycle. Full 8-way (I=ISP raster/geometry busy, S=spanner busy, T=reader busy).
    // pc_occ[{I,S,T}] indexed I*4+S*2+T -> [0]=none .. [7]=all three. pc_all3 = the
    // ideal (3-way parallel). Also per-engine totals (busy any cycle) for utilisation.
    integer pc_occ [0:7];       // occupancy histogram, index = {isp,spn,tsp}
    integer pc_i;               // loop var (reset / dump)
    integer pc_isp_busy, pc_spn_busy, pc_tsp_busy;   // per-engine busy-cycle totals
    integer pc_shwait;          // ISP stalled on the u_taginvw credit (S_PEEL_BUF)
    integer pc_post_stall;      // reader stalled on the u_col credit (R_POST)
    integer pc_op_ff;           // OP-region shade fire-and-forgets (count of requests)
`endif

    // ---- COMBINATIONAL framebuffer-write (VIDEO-OUT / FLUSH), valid/ready ----
    // Driven by the DECOUPLED video-out FSM (vst / vo_i / vo_tx / vo_ty), which runs
    // CONCURRENTLY with ISP/TSP: it streams the VO half of the ping-pong color buffer
    // (vo_rd_argb) to the framebuffer while ISP/TSP shade the next tile into the other
    // half. fbw_req is presented + accepted the SAME cycle so a blocking controller
    // works (busy holds; vo_i advances only when the pixel is consumed). The screen
    // pixel for the linear tile index vo_i (0..1023): x=vo_i[4:0], y=vo_i[9:5].
    wire [10:0] fw_px = {5'd0, vo_tx}*11'd32 + {6'd0, vo_i[4:0]};
    wire [10:0] fw_py = {5'd0, vo_ty}*11'd32 + {6'd0, vo_i[9:5]};
    wire        fw_onscreen = (fw_px < 11'd640) && (fw_py < 11'd480);
    always @(*) begin
        fbw_req.we      = (vst==VO_WR) && fw_onscreen;
        fbw_req.pix_idx = fw_py*20'd640 + {9'd0, fw_px};
        fbw_req.argb    = vo_rd_argb;             // VO-half registered read of vo_i
    end
    // a pixel is consumed this cycle when: on-screen and the sink accepted it, OR
    // off-screen (nothing to write -> skip immediately).
    wire fw_pix_consumed = (vst==VO_WR) &&
                           ( (fw_onscreen && !fbw_resp.busy) || !fw_onscreen );

`ifndef SYNTHESIS
    // -------- FRAMEBUFFER-WRITE dump (sim only): the FINAL output, screen (x,y,argb) as
    // actually written. Reconstructing an image from this vs the BMP isolates whether any
    // weave lives in FLUSH/scanout (fb writes already blocky) or in the BMP writer (fb
    // writes smooth). +fbdump[=<file>] (default fb_writes.log). ----
    // +missdump : per-miss trace of {expected (prefetcher's held/in-flight tag),
    // actual (demanded tag)} + which fetch path was taken. Off by default (8990 lines).
    reg          md_en = 1'b0;
    initial if ($test$plusargs("missdump")) md_en = 1'b1;

    // -------- +spandump : capture the TSP-INPUT buffer per shade pass --------------------
    // Dumps the {valid,tag,invW,pt} the spanner reads for every tile pixel (0..1023) of a
    // pass into spanner_input_<N>.bin, plus a per-pass header {shade_mode,xbase,ybase,
    // param_base,intensity_shadow,npix,tx,ty}. These are the exact IN vectors spanner_v2
    // consumes, so its standalone TB can replay real menu2/doa2 tiles. Filled as the
    // spanner walks (L1 carry, id order) and flushed at P_DONE. Off unless +spandump.
    reg           spd_en = 1'b0;
    integer       spd_n  = 0;             // pass counter -> filename index
    reg           cap_valid [0:1023];
    reg  [31:0]   cap_tag   [0:1023];
    reg  [31:0]   cap_invw  [0:1023];
    reg           cap_pt    [0:1023];
    initial if ($test$plusargs("spandump")) spd_en = 1'b1;
    // write a 32-bit word as TEXT (one 8-hex-digit token per line). A binary %c dump is
    // NOT usable: Verilator's $fwrite("%c",..) silently drops any 0x00 byte, which
    // desyncs a packed stream full of zero bytes (tags/invW/valid). Text is unambiguous.
    task automatic spd_wr32(input integer fd, input [31:0] w);
        $fwrite(fd, "%08x\n", w);
    endtask

    integer      fbd_fd = 0; reg fbd_en = 1'b0; reg [1023:0] fbd_name; integer fbd_n = 0;
    initial begin
        if ($value$plusargs("fbdump=%s", fbd_name)) fbd_en=1'b1;
        else if ($test$plusargs("fbdump")) begin fbd_en=1'b1; fbd_name="fb_writes.log"; end
        if (fbd_en) begin fbd_fd=$fopen(fbd_name,"w"); $fwrite(fbd_fd,"# x y argb (tile tx,ty fw_i)\n"); end
    end
    always @(posedge clk) if (!reset && fbd_en && fbw_req.we && fw_pix_consumed) begin
        $fwrite(fbd_fd, "%0d %0d %08x %0d %0d %0d\n", fw_px, fw_py, vo_rd_argb, vo_tx, vo_ty, vo_i);
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
    integer swi;
    always @(*) begin
        // ---- peel buffer ----
        pb_ra_valid    = ras_out_valid;               // stage-A read (chunk resolved)
        // SPANNER L0: present the u_taginvw read of spx every advance cycle; on a miss
        // freeze we re-present sida's read so sh_* stays alive; on P_MPRES accept we
        // re-present sida to resume. (Mirrors M2's pb_shrd drive.)
        if (spn_run)          begin pb_shrd_valid = (spn_adv ? siss_more : sva);
                                    pb_shrd_id    = (spn_adv ? spx : sida); end
        else if (spn==P_MPRES)begin pb_shrd_valid = sva; pb_shrd_id = sida; end
        // SCAN-prefetch (P_TSP_RUN only): present the taginvw read of pf_scan while
        // scanning for the next-miss tag. pf_drive_shrd is set by the pf FSM below.
        else if (pf_drive_shrd) begin pb_shrd_valid = 1'b1; pb_shrd_id = pf_scan; end
        else                  begin pb_shrd_valid = 1'b0; pb_shrd_id = sida; end
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
        cb_ca_id    = pp_out_id[9:0];                 // [10] is the at-bit
        // FLUSH read is driven by the DECOUPLED video-out FSM (vst), on the VO half.
        cb_fl_valid = (vst == VO_RD || vst == VO_WR); // VO read (vo_i)
        cb_fl_id    = vo_i;

        // ---- span buffer READ (TSP reader), 1 px/clk streaming ----
        // Normally present tsp_i (the pixel to feed NEXT cycle). While the shader is
        // stalled we hold rd_i (the pixel being fed NOW) so its record stays on sbr_*.
        sbr_addr = pp_stall ? rd_i : tsp_i;

        // ---- plane cache lookup (SPANNER L1) ----
        // On an advance cycle L1 presents the lookup of sida's tag (sh_tag_o, resolved
        // this cycle) if staged; pc_hit/pc_o_* land next cycle at L2. On a miss freeze
        // we re-present sidb's tag (stagb) so pc_hit/pc_o_* stay valid for the pixel we
        // re-resolve after the fetch.
        if (spn_run && !spn_adv && svb) begin
            pc_lu_req   = 1'b1;
            pc_lu_tag_c = stagb;
        end else if (spn_run && spn_adv && spn_A_stg) begin
            pc_lu_req   = 1'b1;
            pc_lu_tag_c = sh_tag_o;
        end else if (pf_drive_lu) begin
            // SCAN-prefetch (P_TSP_RUN only): look up the scanned pixel's tag (resolved
            // last cycle onto sh_tag_o) in the plane cache; pc_hit lands next cycle.
            pc_lu_req   = 1'b1;
            pc_lu_tag_c = sh_tag_o;
        end else begin
            pc_lu_req   = 1'b0;
            pc_lu_tag_c = sh_tag_o;
        end

        // ---- span buffer WRITE (spanner L2), 1 px/clk ----
        // On an advance cycle, L2 writes the record for sidb (the pixel looked up last
        // cycle): staged HIT -> planes from pc_o_* (shade=1); not-staged -> shade=0. On
        // P_MPRES (miss just fetched+set-up) -> write sidb from cur_* (shade=1).
        sbw_we    = 1'b0;
        sbw_addr  = sidb;
        sbw_shade = 1'b0;
        sbw_at    = satb;
        sbw_invw  = sinvwb;
        sbw_tsp   = 32'd0;
        sbw_tcw   = 32'd0;
        sbw_ptex  = 1'b0;
        sbw_pofs  = 1'b0;
        for (swi = 0; swi < 10; swi = swi + 1) begin
            sbw_ddx[swi] = 32'd0; sbw_ddy[swi] = 32'd0; sbw_c[swi] = 32'd0;
        end
        if (spn_adv && svb) begin
            sbw_we   = 1'b1;
            sbw_addr = sidb;
            if (!sstaged) begin
                sbw_shade = 1'b0;            // PEEL-skipped pixel
            end else begin                  // staged HIT (a miss would freeze, not adv)
                sbw_shade = 1'b1;
                sbw_tsp   = pc_o_tsp;
                sbw_tcw   = pc_o_tcw;
                sbw_ptex  = pc_o_isp[ISP_TEXTURE_BIT];
                sbw_pofs  = pc_o_isp[ISP_OFFSET_BIT];
                for (swi = 0; swi < 10; swi = swi + 1) begin
                    sbw_ddx[swi] = pc_o_ddx[32*swi +: 32];
                    sbw_ddy[swi] = pc_o_ddy[32*swi +: 32];
                    sbw_c[swi]   = pc_o_c  [32*swi +: 32];
                end
            end
        end else if (spn == P_MPRES) begin  // miss-resolved pixel from cur_*
            sbw_we    = 1'b1;
            sbw_addr  = sidb;
            sbw_shade = 1'b1;
            sbw_tsp   = cur_tsp;
            sbw_tcw   = cur_tcw;
            sbw_ptex  = cur_isp[ISP_TEXTURE_BIT];
            sbw_pofs  = cur_isp[ISP_OFFSET_BIT];
            for (swi = 0; swi < 10; swi = swi + 1) begin
                sbw_ddx[swi] = cur_ddx[swi];
                sbw_ddy[swi] = cur_ddy[swi];
                sbw_c[swi]   = cur_c[swi];
            end
        end
    end

    // ---- pp-input mux: drive tsp_shade_pp's inputs COMBINATIONALLY ----
    // The TSP READER (tsp_st) drains span_buffer[tsp_rd]: in R_FEED the record for
    // pixel tsp_i (read presented last cycle in R_REQ) is on sbr_*[tsp_rd]. Present it
    // to the shader when it is a shaded pixel (r_shade); hold on pp_stall. id/invw and
    // all planes come straight from the span buffer - no cache/cur_* here anymore.
    integer pj;
    always @(*) begin
        pp_in_valid = (tsp_st == R_RUN) && rd_v && sbr_shade[tsp_rd];
        pp_in_id    = {sbr_at[tsp_rd], rd_i};    // fed pixel = rd_i; [10]=PT alpha-test
        pp_invw     = sbr_invw[tsp_rd];
        pp_tsp      = sbr_tsp[tsp_rd];
        pp_tcw      = sbr_tcw[tsp_rd];
        pp_ptex     = sbr_ptex[tsp_rd];
        pp_pofs     = sbr_pofs[tsp_rd];
        for (pj = 0; pj < 10; pj = pj + 1) begin
            pp_ddx[pj] = sbr_ddx[tsp_rd][pj];
            pp_ddy[pj] = sbr_ddy[tsp_rd][pj];
            pp_c[pj]   = sbr_c  [tsp_rd][pj];
        end
        pp_px = pp_in_id[4:0];
        pp_py = pp_in_id[9:5];    // [10] is the at-bit, not part of px/py
    end

    always @(posedge clk) begin
        if (reset) begin
            st<=S_IDLE; done<=0; ra_start<=0; ol_start<=0;
            tsp_start<=0; fx_start<=0; pf_start<=0;
            pf_ready<=1'b0; pf_rtag<=32'd0;
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
            for (pc_i=0; pc_i<8; pc_i=pc_i+1) pc_occ[pc_i]<=0;
            pc_isp_busy<=0; pc_spn_busy<=0; pc_tsp_busy<=0;
            pc_shwait<=0; pc_post_stall<=0; pc_op_ff<=0;
            pc_hand<=0; pc_span<=0; pc_drain<=0; pc_blend<=0; pc_swrite<=0;
            pc_prefetch<=0; pc_pf_hit<=0; pc_pf_wasted<=0;
            pc_m_promote<=0; pc_m_waithit<=0; pc_m_waitmiss<=0; pc_m_cold<=0;
`endif
            rs_st<=RS_IDLE;
            pq_head<=0; pq_tail<=0; pq_count<=0;
            fq_head<=0; fq_tail<=0; fq_count<=0; fq_out_valid<=1'b0;
            eq_head<=0; eq_tail<=0; eq_count<=0;
            peeling<=1'b0; more_to_draw<=1'b0; peel_pass<=8'd0; op_shaded<=1'b0;
            has_pt<=1'b0; has_tr<=1'b0; peel_which<=1'b0;
            b_valid<=1'b0; cb_valid<=1'b0;
            cl_i<='0; pb_i<='0; pb_rd<='0; pb_pipe<=1'b0; first_peel<=1'b0;
            col_post<=1'b0;                   // color post-to-VO intent
            ra_done_l<=1'b0;                  // latched region-done
            // SPANNER + TSP reader FSMs
            spn<=P_IDLE; spx<=10'd0;
            sva<=1'b0; svb<=1'b0; siss_more<=1'b0; sstaged<=1'b0;
            spn_tx<=6'h3f; spn_ty<=6'h3f; pc_cold<=1'b1;   // force 1st-pass inval
            spn_xbase<=32'd0; spn_ybase<=32'd0;
            // SCAN-prefetch sub-FSM
            pf_st<=PF_OFF; pf_scan<=10'd0; pf_sv<=1'b0; pf_sid<=10'd0;
            pf_tag<=32'd0;
            spn_prod<=1'b0;
            tsp_st<=R_IDLE; tsp_i<=10'd0; rd_v<=1'b0; rd_i<=10'd0; rd_last<=1'b0; tsp_rd<=1'b0;
            sb_ready<=2'b00;
            sb_last[0]<=1'b0; sb_last[1]<=1'b0;
            sb_post[0]<=1'b0; sb_post[1]<=1'b0;
            ti_ready<=2'b00; tsp_tag<=1'b0; tsp_col<=1'b0;
            ti_postonly[0]<=1'b0; ti_postonly[1]<=1'b0;
            // htile = ISP u_taginvw producer half (per pass); tsp_tag/tsp_col above.
            htile<=1'b0;
            pc_inval<=1'b0; pc_wr_req<=1'b0;
            // (plane cache valid bits are cleared by u_pc's own reset; pc_lu_req is
            //  combinational, driven by the spanner)
        end else begin
`ifndef SYNTHESIS
            // -------- performance counters: charge THIS clock to its buckets --------
            // Only count while the core is doing tile work (not the top-level idle wait
            // for a start). Approximate "active" as: not S_IDLE, or any engine busy
            // (raster, setup, OR the decoupled video-out engine).
            if (st != S_IDLE || rs_st != RS_IDLE || su_busy || vst != VO_IDLE
                             || spn != P_IDLE || tsp_st != R_IDLE) begin
                pc_total <= pc_total + 1;
                // decoupled VO engine busy (framebuffer writeout / scanout).
                if (vst != VO_IDLE) pc_top_flush <= pc_top_flush + 1;

                // ISP / raster engine (by rs_st)
                case (rs_st)
                    RS_RAS:   pc_ras_active <= pc_ras_active + 1;
                    RS_POP:   pc_ras_pop    <= pc_ras_pop    + 1;
                    RS_DRAIN: pc_ras_drain  <= pc_ras_drain  + 1;
                    default:  pc_ras_idle   <= pc_ras_idle   + 1;   // RS_IDLE
                endcase

                // TSP / shade engine now SPLIT: the SPANNER resolves planes (its miss
                // fetch / setup-wait dominate) and the TSP READER feeds the shader.
                if (tsp_st == R_RUN) begin
                    if      (pp_in_valid && pp_stall) pc_sh_tex_stall <= pc_sh_tex_stall + 1;
                    else if (pp_in_valid)             pc_sh_present   <= pc_sh_present   + 1;
                    else                              pc_sh_look      <= pc_sh_look      + 1;
                end else if (spn == P_TSP_RUN)                    pc_sh_setup_wait <= pc_sh_setup_wait + 1;
                else if (spn==P_FETCH_W)                          pc_sh_fetch <= pc_sh_fetch + 1;
                else if (spn==P_RUN||spn==P_MPRES)                pc_sh_look  <= pc_sh_look  + 1;
                else if (tsp_st==R_DRAIN)                         pc_sh_drain <= pc_sh_drain + 1;
                else                                              pc_sh_none  <= pc_sh_none  + 1;

                // top-level phase view (whole-core). SHADE now = spanner OR reader busy.
                if (st==S_CLEAR_WR)                               pc_top_clear   <= pc_top_clear   + 1;
                else if (st==S_PEEL_BUF_RUN)                      pc_top_peelbuf <= pc_top_peelbuf + 1;
                else if (st==S_OL_RUN)                            pc_top_ol      <= pc_top_ol      + 1;
                else if (st==S_DRAIN)                             pc_top_barrier <= pc_top_barrier + 1;
                else                                              pc_top_other   <= pc_top_other   + 1;
                if (spn != P_IDLE || tsp_st != R_IDLE)            pc_top_shade   <= pc_top_shade   + 1;

                if (pp_stall) pc_tex_busy <= pc_tex_busy + 1;
                if (su_busy)  pc_su_busy  <= pc_su_busy  + 1;

                // ---- 3-ENGINE occupancy cross-tab ----
                // ISP busy = producing/consuming geometry or walking a buffer (raster,
                // setup, CLEAR/PeelBuffers walk, OL walk). SPANNER busy = spn!=P_IDLE.
                // TSP reader busy = tsp_st!=R_IDLE. Histogram all 8 {isp,spn,tsp} combos.
                begin : occacct
                    reg e_isp, e_spn, e_tsp; reg [2:0] occ;
                    e_isp = (rs_st != RS_IDLE) || su_busy ||
                            (st==S_CLEAR_WR) || (st==S_PEEL_BUF_RUN) || (st==S_OL_RUN);
                    e_spn = (spn != P_IDLE);
                    e_tsp = (tsp_st != R_IDLE);
                    occ = {e_isp, e_spn, e_tsp};
                    pc_occ[occ] <= pc_occ[occ] + 1;
                    if (e_isp) pc_isp_busy <= pc_isp_busy + 1;
                    if (e_spn) pc_spn_busy <= pc_spn_busy + 1;
                    if (e_tsp) pc_tsp_busy <= pc_tsp_busy + 1;
                    // stalls: ISP on the u_taginvw credit; reader on the u_col credit.
                    if (st==S_PEEL_BUF && ti_ready[htile]) pc_shwait <= pc_shwait + 1;
                    if (tsp_st==R_POST && col_full[tsp_col]) pc_post_stall <= pc_post_stall + 1;
                end
            end
`endif
            done<=0; ra_start<=0; ol_start<=0;
            tsp_start<=0; fx_start<=0; pf_start<=0;  // 1-cyc fetcher start strobes
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            eq_push = 1'b0;
            pc_inval<=1'b0; pc_wr_req<=1'b0;  // 1-cyc strobes (pc_lu_req is combi)
            col_post<=1'b0;                   // 1-cyc: color-buffer post-to-VO intent
            // fbw_req is driven COMBINATIONALLY by the decoupled VO engine.

            // ---- prefetch shadow capture: latch u_prefetch's decoded record on its
            // done pulse into the stable shadow (its o_* are wires). pf_rtag was latched
            // when the prefetch was ISSUED (pf_start below). Sets pf_ready; a demand miss
            // that matches promotes it (clearing pf_ready), else the next issued prefetch
            // overwrites it. ----
            if (pf_done) begin
                ps_isp <= pfr_isp; ps_tsp <= pfr_tsp; ps_tcw <= pfr_tcw;
                for (j = 0; j < 3; j = j + 1) begin
                    ps_x[j]<=pfr_x[j]; ps_y[j]<=pfr_y[j]; ps_z[j]<=pfr_z[j];
                    ps_u[j]<=pfr_u[j]; ps_v[j]<=pfr_v[j];
                    ps_col[j]<=pfr_col[j]; ps_ofs[j]<=pfr_ofs[j];
                end
                pf_ready <= 1'b1;
            end

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
                cb_id    <= pp_out_id[9:0];
                cb_argb  <= pp_out_argb;
                cb_tsp   <= pp_out_tsp;
                cb_at_en <= pp_out_id[10];   // PT alpha-test enable (rode through shader)
                sh_out_n <= sh_out_n + 1;
`ifndef SYNTHESIS
                pc_blend <= pc_blend + 1;
`endif
            end
`ifndef SYNTHESIS
            if (sbw_we && sbw_shade) pc_swrite <= pc_swrite + 1;  // spanner shaded-px writes
`endif

            case (st)
            S_IDLE: if (go) begin ra_start<=1; st<=S_RA; end

            S_RA: begin
                // region array fully walked, but the DECOUPLED video-out engine may
                // still be draining the last posted tile(s) - wait for it to go idle
                // and all color credits to clear before signalling done (else a TB that
                // samples the framebuffer on `done` misses the trailing VO writes).
                // ra_tiles_parsed is a 1-CYCLE PULSE, so LATCH it (ra_done_l) and hold
                // in S_RA until VO drains - otherwise the pulse is lost while VO is busy
                // and the FSM deadlocks in S_RA (the last-tile-writeout hang).
                // Frame done only once the WHOLE pipeline has drained: the concurrent
                // TSP shade FSM idle with no pending u_taginvw halves, AND the video-out
                // engine idle with no pending u_col halves.
                if (ra_tiles_parsed) ra_done_l <= 1'b1;
                if (ra_done_l || ra_tiles_parsed) begin
                    // Whole 3-stage pipeline drained: spanner idle, reader idle, no
                    // pending ISP->spanner (ti_ready) or spanner->reader (sb_ready)
                    // halves, no in-flight color POST intent (col_post is a 1-cyc pulse
                    // that sets col_full NEXT cycle - must not race the gate), and VO
                    // idle with no pending u_col halves. Missing !col_post here dropped
                    // the FINAL tile's writeout (last-tile-black bug).
                    if (spn==P_IDLE && tsp_st==R_IDLE &&
                        ti_ready==2'b00 && sb_ready==2'b00 &&
                        !col_post && vst==VO_IDLE && col_full==2'b00) begin
                        ra_done_l <= 1'b0;
                        st<=S_DONE;
                    end
                end
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
                // gate on !ti_ready[htile]: CLEAR writes u_taginvw[htile], which TSP may
                // still be reading from an earlier pass (ping-pong back-pressure).
                RSTATE_CLEAR: if (consumer_idle && fq_empty && !ti_ready[htile]) begin
                    // as tile_engine_top TILE_CLEAR: {bg depth, bg CoreTag}. Every
                    // pixel's tag = background tag and is "valid" for OP shading
                    // (refsw ClearBuffers sets tagStatus.valid=true), so the OP
                    // shade fills col_buf with the background color.
                    op_shaded <= 1'b0;   // OP shade not yet run for this tile
                    has_pt <= 1'b0; has_tr <= 1'b0;   // PT/TL lists for this tile: none yet
                    cl_i <= '0; st <= S_CLEAR_WR;
                end
                // OPAQUE: single pass, plain DepthMode compare (no peeling). Gate on
                // !ti_ready[htile] (raster writes u_taginvw[htile]).
                RSTATE_OP: if (!ti_ready[htile]) begin
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
                        // Peel tile. If no OP region ran, the background OP shade must
                        // run first (peel passes blend over it). It's a normal shade
                        // handoff into htile (not last); S_PEEL_INIT follows.
                        if (!op_shaded) begin
                            op_shaded <= 1'b1;
                            ti_ready[htile] <= 1'b1;
                            ti_mode [htile] <= 1'b0;             // OP background
                            ti_last [htile] <= 1'b0;
                            ti_postonly[htile] <= 1'b0;
                            ti_tx[htile] <= cur_tx; ti_ty[htile] <= cur_ty;
                            htile <= ~htile;
`ifndef SYNTHESIS
                            pc_hand <= pc_hand + 1;
`endif
                        end
                        peeling <= 1'b1;
                        st <= S_PEEL_INIT;
                    end else begin
                        // OP-only tile: color already accumulated in u_col by the OP
                        // shade. Issue a POST-ONLY handoff so TSP hands u_col to VO
                        // (after the OP shade drains, in TSP's in-order queue).
                        ti_ready[htile] <= 1'b1;
                        ti_postonly[htile] <= 1'b1;
                        ti_last [htile] <= 1'b1;
                        ti_tx[htile] <= cur_tx; ti_ty[htile] <= cur_ty;
                        htile <= ~htile;
`ifndef SYNTHESIS
                        pc_hand <= pc_hand + 1;
`endif
                        ra_ack.list_done <= 1'b1; st <= S_RA_ACK;
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
                    // same half (both lists build this pass's staged frags) BEFORE the
                    // shade, so they sort together.
                    if (peel_which==1'b0 && has_tr) begin
                        peel_which <= 1'b1;
                        ol_list_ptr <= tr_ptr_l; ol_start <= 1'b1;
                        st <= S_OL_RUN;
                    end else begin
                        // PEEL pass fully rastered into u_taginvw[htile]. HAND it to TSP
                        // (set the ready credit) and RUN AHEAD: flip htile so the next
                        // pass rasters into the OTHER half while TSP shades this one.
                        // more_to_draw (set during this pass's raster) tells us if this
                        // is the LAST pass -> ti_last so TSP posts the color to VO.
                        ti_ready[htile] <= 1'b1;
                        ti_mode [htile] <= 1'b1;                 // PEEL
                        ti_last [htile] <= !more_to_draw;
                        ti_tx   [htile] <= cur_tx; ti_ty[htile] <= cur_ty;
                        htile <= ~htile;
`ifndef SYNTHESIS
                        pc_hand <= pc_hand + 1;
`endif
                        if (more_to_draw && peel_pass < PEEL_MAX_PASS[7:0])
                            st <= S_PEEL_BUF;    // do another pass (PeelBuffers+raster)
                        else begin
                            // last pass: tile done producing. Ack region (FLUSH); TSP
                            // will post the color when this final shade drains.
                            peeling <= 1'b0;
                            ra_ack.list_done <= 1'b1; st <= S_RA_ACK;
                        end
                    end
                end else begin
                    // OP region fully rastered into u_taginvw[htile]. HAND to TSP and run
                    // ahead. NOT last: the tile's FLUSH state (later) issues the final
                    // post-only shade (ti_last) that hands color to VO.
                    ti_ready[htile] <= 1'b1;
                    ti_mode [htile] <= 1'b0;                     // OP
                    ti_last [htile] <= 1'b0;
                    ti_tx   [htile] <= cur_tx; ti_ty[htile] <= cur_ty;
                    htile <= ~htile;
`ifndef SYNTHESIS
                    pc_op_ff <= pc_op_ff + 1;
                    pc_hand  <= pc_hand + 1;
`endif
                    st <= S_OP_DONE;
                end
            end

            // OP shade HANDED to TSP (running concurrently) -> mark tile OP-shaded,
            // ack the OP region. Do NOT wait for the shade to drain.
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
                st <= S_PEEL_BUF;    // S_PEEL_BUF gates on !ti_ready[htile]
            end

            // PeelBuffers(FLT_MAX, 0): per pixel depth2<-depth, tag2<-tag (or
            // 0xFFFFFFFF on pass 1 via first_peel), depth<-FLT_MAX, valid<-0. As an
            // M10K RMW this is a read(A chunk N)->write(B transformed chunk N-1) walk
            // over 128 chunk addresses (S_PEEL_BUF_RUN). dt_pt is a reg: cleared here
            // in one cycle (else a stale PT flag fires the alpha test on TR pixels).
            // On pass 1 dt_depth holds the OP result (nothing clobbers it between OP
            // and the peel); later passes it holds the previous pass's closest layer;
            // copying live dt_depth every pass is correct - no snapshot needed.
            // STALL before writing the new htile half until TSP has consumed it
            // (!ti_ready[htile]): PeelBuffers' pbc walk clears this half's valid and the
            // pass's raster fills it, so it must be free (ping-pong back-pressure - if
            // ISP N+1 finished before TSP N, ISP waits here).
            S_PEEL_BUF: if (!ti_ready[htile]) begin
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

            // (peel pass continuation + tile posting are now handled inline in S_DRAIN
            // via ti_ready handoff to the concurrent TSP FSM; S_PEEL_CHK/S_POST/
            // S_SHADE_WAIT are gone.)

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
                // NOTE: single-bucket classifier (reader wins when both busy), so these
                // are LOWER bounds on the spanner's work when it overlaps the reader; the
                // ENGINES/OCCUPANCY cross-tab below is the non-collapsed truth.
                $display("  TSP READER:  PRESENT=%0d (%0d%%)  TEX_STALL=%0d (%0d%%)  DRAIN=%0d",
                    pc_sh_present, (pc_sh_present*100)/(pc_total?pc_total:1),
                    pc_sh_tex_stall, (pc_sh_tex_stall*100)/(pc_total?pc_total:1),
                    pc_sh_drain);
                $display("  SPANNER:     CACHE_LOOK=%0d (%0d%%)  FETCH=%0d (%0d%%)  SETUP_WAIT=%0d (%0d%%)  none=%0d",
                    pc_sh_look, (pc_sh_look*100)/(pc_total?pc_total:1),
                    pc_sh_fetch, (pc_sh_fetch*100)/(pc_total?pc_total:1),
                    pc_sh_setup_wait, (pc_sh_setup_wait*100)/(pc_total?pc_total:1),
                    pc_sh_none);
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
                // ---- 3-engine occupancy: ISP raster || SPANNER resolve || TSP reader ----
                $display("  ENGINES busy: ISP=%0d (%0d%%)  SPANNER=%0d (%0d%%)  TSP=%0d (%0d%%)",
                    pc_isp_busy, (pc_isp_busy*100)/(pc_total?pc_total:1),
                    pc_spn_busy, (pc_spn_busy*100)/(pc_total?pc_total:1),
                    pc_tsp_busy, (pc_tsp_busy*100)/(pc_total?pc_total:1));
                $display("  OCCUPANCY (isp,spn,tsp):  none=%0d  I=%0d  S=%0d  T=%0d",
                    pc_occ[0], pc_occ[4], pc_occ[2], pc_occ[1]);
                $display("     I+S=%0d  I+T=%0d  S+T=%0d  ALL3=%0d (%0d%%)",
                    pc_occ[6], pc_occ[5], pc_occ[3],
                    pc_occ[7], (pc_occ[7]*100)/(pc_total?pc_total:1));
                $display("     stalls: ISP-on-taginvw=%0d (%0d%%)  TSP-on-ucol=%0d (%0d%%)  OP_ff=%0d",
                    pc_shwait,     (pc_shwait*100)/(pc_total?pc_total:1),
                    pc_post_stall, (pc_post_stall*100)/(pc_total?pc_total:1),
                    pc_op_ff);
                $display("  SPAN PROBE:  hand=%0d span=%0d drain=%0d  (dropped passes: hand-drain=%0d)",
                    pc_hand, pc_span, pc_drain, pc_hand - pc_drain);
                $display("               swrite(shaded px)=%0d  blend(px)=%0d  (dropped px=%0d)",
                    pc_swrite, pc_blend, pc_swrite - pc_blend);
                $display("               scan-prefetch=%0d  pf_hit(served from shadow)=%0d  wasted(ready,never used)=%0d",
                    pc_prefetch, pc_pf_hit, pc_pf_wasted);
                $display("               miss class: promote=%0d waithit=%0d waitmiss=%0d cold=%0d  (of %0d misses)",
                    pc_m_promote, pc_m_waithit, pc_m_waitmiss, pc_m_cold, miss_count);
`endif
                done<=1'b1; st<=S_IDLE;
            end
            default: st<=S_IDLE;
            endcase

            // ================= CONCURRENT SPANNER FSM (spn) =================
            // Runs every cycle alongside `st` / `rs_st` / the TSP reader. OWNS the plane
            // cache (u_pc), the word reader (f_*), the fetched verts (fv_*), tsp_setup_min
            // (u_tsp) and cur_*. It CONSUMES the ISP->spanner input half (ti_ready/ti_mode/
            // ti_last/ti_postonly/ti_tx/ti_ty[tsp_tag]) and PRODUCES a fully-resolved span
            // buffer (span_buffer[spn_prod]), handing it off via sb_ready[spn_prod]. It
            // walks x=0..1023 of the CONSUMER u_taginvw half, resolving each pixel's planes
            // (plane-cache hit -> pc_o_*; miss -> DDR fetch + tsp_setup_min -> cur_*) and
            // writing the record into the span buffer (combinational sbw_* drive above).
            case (spn)
            // Pick the next READY input half (in order via tsp_tag). Stall if the span
            // buffer half we would write (spn_prod) is still owned by the TSP reader
            // (sb_ready[spn_prod]). Post-only inputs skip the pixel walk.
            P_IDLE: if (ti_ready[tsp_tag] && !sb_ready[spn_prod]) begin
                if (ti_postonly[tsp_tag]) begin
                    // OP-only tile FLUSH: no shade; hand a post-only span half to the
                    // reader (color already accumulated in u_col). Free the input half.
                    sb_ready[spn_prod] <= 1'b1;
                    sb_post [spn_prod] <= 1'b1;
                    sb_last [spn_prod] <= 1'b1;         // post-only implies last
                    sb_tx   [spn_prod] <= ti_tx[tsp_tag];
                    sb_ty   [spn_prod] <= ti_ty[tsp_tag];
                    ti_ready[tsp_tag]  <= 1'b0;
                    spn_prod <= ~spn_prod;
                    tsp_tag  <= ~tsp_tag;
`ifndef SYNTHESIS
                    pc_span <= pc_span + 1;
`endif
                end else begin
                    // The spanner's tile origin for u_tsp (its OWN tile, not ISP's live
                    // t_xbase, since the spanner runs behind ISP). Latch from the handed
                    // coords and compute xbase/ybase (as S_STATE does for ISP).
                    spn_tx <= ti_tx[tsp_tag]; spn_ty <= ti_ty[tsp_tag];
                    spn_xbase <= i2f({4'd0, ti_tx[tsp_tag]} * 16'd32);
                    spn_ybase <= i2f({4'd0, ti_ty[tsp_tag]} * 16'd32);
                    // TILE-GATED plane-cache invalidate: only wipe when the tile CHANGES
                    // (xbase/ybase differ). Within a tile's peel passes the same tags
                    // recur with IDENTICAL planes (pure fn of vertices + xbase/ybase), so
                    // keeping the cache warm across passes turns passes 2..N into hits.
                    if (ti_tx[tsp_tag] != spn_tx || ti_ty[tsp_tag] != spn_ty || pc_cold)
                        pc_inval <= 1'b1;
                    pc_cold <= 1'b0;
                    shade_mode <= ti_mode[tsp_tag];
                    // prime the pipeline: nothing in flight, all 1024 to issue at L0.
                    spx <= 10'd0; sva <= 1'b0; svb <= 1'b0; siss_more <= 1'b1;
                    spn <= P_RUN;
                end
            end

            // ---- PIPELINED resolve (L0/L1/L2, 1 px/clk on hits) ----
            //   L0: present u_taginvw read of spx (pb_shrd, combi); spx++
            //   L1(sva/sida): sh_* resolved -> present plane-cache lookup (pc_lu, combi)
            //   L2(svb/sidb): pc_hit/pc_o_* -> WRITE span buffer (combi sbw_*)
            // A MISS at L2 (staged && !pc_hit) freezes the front and fetches; P_MPRES
            // writes the miss-resolved pixel then resumes. Skipped (!staged) pixels are
            // written shade=0 at L2 as a bubble.
            P_RUN: begin
                if (spn_adv) begin
                    if (svb && sstaged) hit_count <= hit_count + 1;
`ifndef SYNTHESIS
                    // [HIT]: a staged L2 pixel resolved from the plane cache (advancing,
                    // so it wasn't a miss). Shows the full tag stream interleaved with
                    // the [MISS] lines.
                    if (md_en && svb && sstaged)
                        $display("[HIT ] px%0d tag=%08x", sidb, stagb);
`endif
                    // L1 -> L2: sida's resolved pixel enters L2 (cache read presented
                    // this cycle -> pc_* next). Carry staged/at/invw/tag.
                    if (sva) begin
                        svb    <= 1'b1;
                        sidb   <= sida;
                        stagb  <= sh_tag_o;
                        sinvwb <= sh_depth_o;
                        satb   <= sh_pt_o;
                        sstaged<= spn_A_stg;
`ifndef SYNTHESIS
                        // +spandump: capture pixel sida's TSP input (id order, once/px).
                        if (spd_en) begin
                            cap_valid[sida] <= sh_valid_o;
                            cap_tag  [sida] <= sh_tag_o;
                            cap_invw [sida] <= sh_depth_o;
                            cap_pt   [sida] <= sh_pt_o;
                        end
`endif
                    end else begin
                        svb <= 1'b0;
                    end
                    // L0 -> L1: issue the next pixel's read (presented this cycle via
                    // pb_shrd), advance spx, retire siss_more at 1023.
                    if (siss_more) begin
                        sva  <= 1'b1;
                        sida <= spx;
                        if (spx == 10'd1023) siss_more <= 1'b0;
                        else                 spx <= spx + 10'd1;
                    end else begin
                        sva <= 1'b0;
                    end
                    // drain: nothing left to issue and both stages empty -> pass done.
                    if (!siss_more && !sva && !svb) spn <= P_DONE;
                end else if (spn_miss) begin
                    // L2 miss: freeze, latch sidb's context for the resolve.
                    miss_count <= miss_count + 1;
                    sh_tag  <= stagb; sh_invw <= sinvwb; sh_id <= sidb; sh_at <= satb;
                    // PROMOTE: the SCAN prefetcher may already have decoded this exact
                    // tag into the shadow (pf_ready && pf_rtag==stagb). If so, latch the
                    // shadow into cur_*/fv_* and jump straight to setup - ZERO demand
                    // fetch. Else start the DEMAND record_fetcher and wait its done.
                    if (pf_ready && pf_rtag == stagb) begin
                        cur_isp <= ps_isp; cur_tsp <= ps_tsp; cur_tcw <= ps_tcw;
                        for (j = 0; j < 3; j = j + 1) begin
                            fv_x[j]<=ps_x[j]; fv_y[j]<=ps_y[j]; fv_z[j]<=ps_z[j];
                            fv_u[j]<=ps_u[j]; fv_v[j]<=ps_v[j];
                            fv_col[j]<=ps_col[j]; fv_ofs[j]<=ps_ofs[j];
                        end
                        for (j = 0; j < 10; j = j + 1) begin
                            cur_ddx[j]<=32'd0; cur_ddy[j]<=32'd0; cur_c[j]<=32'd0;
                        end
                        pf_ready  <= 1'b0;             // consume the shadow
                        tsp_start <= 1'b1;
                        spn <= P_TSP_RUN;
`ifndef SYNTHESIS
                        pc_pf_hit <= pc_pf_hit + 1;
                        pc_m_promote <= pc_m_promote + 1;
                        if (md_en) $display("[MISS #%0d] PROMOTE  expected=%08x actual=%08x (shadow hit, zero fetch)",
                            miss_count, pf_rtag, stagb);
`endif
                    end else if (pf_busy || pf_done) begin
                        // a prefetch is IN FLIGHT (or completing THIS cycle: pf_done drops
                        // pf_busy and sets pf_ready non-blocking, so both read 0 here for
                        // one cycle - must not fall through to COLD and discard it). Wait
                        // in P_PF_WAIT for pf_ready, then promote if our tag else fetch.
                        spn <= P_PF_WAIT;
`ifndef SYNTHESIS
                        if (md_en) $display("[MISS #%0d] WAIT     expected=%08x actual=%08x (prefetch in flight, %s)",
                            miss_count, pf_rtag, stagb, (pf_rtag==stagb) ? "MATCH" : "MISMATCH");
`endif
                    end else begin
                        fx_tag   <= stagb;
                        fx_start <= 1'b1;
                        spn <= P_FETCH_W;
`ifndef SYNTHESIS
                        pc_m_cold <= pc_m_cold + 1;
                        if (md_en) $display("[MISS #%0d] FETCH    expected=%08x actual=%08x (COLD: no prefetch ready/busy; ready=%0b rtag=%08x)",
                            miss_count, pf_rtag, stagb, pf_ready, pf_rtag);
`endif
                    end
                end
            end

            // A prefetch was in flight at miss time. Wait for pf_READY (the shadow is
            // captured + valid), NOT just !pf_busy: pf_ready/ps_* are set by the capture
            // block on pf_done, which is the SAME cycle busy drops - so gating on !pf_busy
            // reads pf_ready one cycle too early (still 0, ps_* stale) -> spurious WAITMISS
            // even when the tag matched. Gating on pf_ready fixes that.
            P_PF_WAIT: if (pf_ready) begin
                if (pf_rtag == sh_tag) begin
                    cur_isp <= ps_isp; cur_tsp <= ps_tsp; cur_tcw <= ps_tcw;
                    for (j = 0; j < 3; j = j + 1) begin
                        fv_x[j]<=ps_x[j]; fv_y[j]<=ps_y[j]; fv_z[j]<=ps_z[j];
                        fv_u[j]<=ps_u[j]; fv_v[j]<=ps_v[j];
                        fv_col[j]<=ps_col[j]; fv_ofs[j]<=ps_ofs[j];
                    end
                    for (j = 0; j < 10; j = j + 1) begin
                        cur_ddx[j]<=32'd0; cur_ddy[j]<=32'd0; cur_c[j]<=32'd0;
                    end
                    pf_ready  <= 1'b0;
                    tsp_start <= 1'b1;
                    spn <= P_TSP_RUN;
`ifndef SYNTHESIS
                    pc_pf_hit <= pc_pf_hit + 1;
                    pc_m_waithit <= pc_m_waithit + 1;
                    if (md_en) $display("[MISS #%0d] WAITHIT  expected=%08x actual=%08x (waited for prefetch, matched)",
                        miss_count, pf_rtag, sh_tag);
`endif
                end else begin
                    fx_tag   <= sh_tag;   // prefetch was a different tag -> demand fetch
                    fx_start <= 1'b1;
                    spn <= P_FETCH_W;
`ifndef SYNTHESIS
                    pc_m_waitmiss <= pc_m_waitmiss + 1;
                    if (md_en) $display("[MISS #%0d] WAITMISS expected=%08x actual=%08x (waited but WRONG tag -> demand fetch)",
                        miss_count, pf_rtag, sh_tag);
`endif
                end
            end

            // ---- DEMAND record fetch: wait for u_fetch.done, latch its decoded o_*
            // into cur_*/fv_* (zero the planes for tsp_setup_min to fill), start setup. ----
            P_FETCH_W: if (fx_done) begin
                cur_isp <= fx_isp; cur_tsp <= fx_tsp; cur_tcw <= fx_tcw;
                for (j = 0; j < 3; j = j + 1) begin
                    fv_x[j]<=fx_x[j]; fv_y[j]<=fx_y[j]; fv_z[j]<=fx_z[j];
                    fv_u[j]<=fx_u[j]; fv_v[j]<=fx_v[j];
                    fv_col[j]<=fx_col[j]; fv_ofs[j]<=fx_ofs[j];
                end
                for (j = 0; j < 10; j = j + 1) begin
                    cur_ddx[j]<=32'd0; cur_ddy[j]<=32'd0; cur_c[j]<=32'd0;
                end
                tsp_start <= 1'b1;
                spn <= P_TSP_RUN;
            end

            // wait for tsp_setup_min; commit cur_* to the plane cache (was T_TSP_RUN).
            // Next cycle P_MPRES writes cur_* into the span buffer for sidb.
            P_TSP_RUN: if (tsp_done) begin
                pc_wr_req <= 1'b1;
                spn <= P_MPRES;
            end

            // MISS write: the combi block wrote cur_* into span_buffer[spn_prod][sidb]
            // this cycle (shade=1). sidb (L2) is consumed -> svb<=0; L1 (sva/sida)
            // survived the fetch and resumes at L1 next cycle. Back to the pipeline.
            P_MPRES: begin
                svb <= 1'b0;
                spn <= P_RUN;
            end

            // pass fully resolved into span_buffer[spn_prod]. Hand it to the TSP reader
            // (sb_ready credit + metadata), free the ISP->spanner input half, flip the
            // producer half, advance tsp_tag to the next input pass.
            P_DONE: begin
                sb_ready[spn_prod] <= 1'b1;
                sb_post [spn_prod] <= 1'b0;
                sb_last [spn_prod] <= ti_last[tsp_tag];
                sb_tx   [spn_prod] <= ti_tx  [tsp_tag];
                sb_ty   [spn_prod] <= ti_ty  [tsp_tag];
                ti_ready[tsp_tag]  <= 1'b0;      // free the input half for ISP
                spn_prod <= ~spn_prod;
                tsp_tag  <= ~tsp_tag;
`ifndef SYNTHESIS
                pc_span <= pc_span + 1;
                // +spandump: flush this pass's captured TSP-input buffer to
                // spanner_input_<spd_n>.txt (TEXT: one 8-hex-digit word per line; header
                // of 9 words then 1024 records of {valid,tag,invw,pt}).
                if (spd_en) begin : spd_flush
                    integer spf; integer si; string spname;
                    spname = $sformatf("spanner_input_%0d.txt", spd_n);
                    spf = $fopen(spname, "w");
                    if (spf != 0) begin
                        spd_wr32(spf, 32'h53504E31);                 // magic "SPN1"
                        spd_wr32(spf, {31'd0, shade_mode});
                        spd_wr32(spf, spn_xbase);
                        spd_wr32(spf, spn_ybase);
                        spd_wr32(spf, {5'd0, param_base});
                        spd_wr32(spf, {31'd0, regs.fpu_shad_scale.intensity_shadow});
                        spd_wr32(spf, 32'd1024);                     // npix
                        spd_wr32(spf, {26'd0, spn_tx});
                        spd_wr32(spf, {26'd0, spn_ty});
                        for (si = 0; si < 1024; si = si + 1) begin
                            spd_wr32(spf, {31'd0, cap_valid[si]});
                            spd_wr32(spf, cap_tag[si]);
                            spd_wr32(spf, cap_invw[si]);
                            spd_wr32(spf, {31'd0, cap_pt[si]});
                        end
                        $fclose(spf);
                        $display("[peel_core] spandump: pass %0d -> %0s", spd_n, spname);
                    end
                    spd_n = spd_n + 1;
                end
`endif
                spn <= P_IDLE;
            end
            default: spn <= P_IDLE;
            endcase

            // ================= SCAN-PREFETCH sub-FSM (pf_st) =================
            // Active ONLY while spn==P_TSP_RUN (the shade-read + cache-lookup ports are
            // idle then and the demand fetcher u_fetch is done). Best-effort: forced to
            // PF_OFF the moment we leave P_TSP_RUN (tsp_done -> P_MPRES), abandoning any
            // partial scan. Never gates P_TSP_RUN. It SCANS for the next-miss tag using
            // the idle shade-read + plane-cache ports, then hands that tag to the SECOND
            // record_fetcher (u_prefetch) via pf_start, which fully decodes it into the
            // prefetch shadow (pf_ready/pf_rtag/ps_*) on its OWN DDR client. It NEVER
            // touches the demand path (u_fetch / cur_* / fv_*). Only ONE prefetch is
            // in flight (issue gated on !pf_busy). A promoted demand miss (P_RUN above)
            // consumes the shadow with zero demand fetch.
            if (spn != P_TSP_RUN) begin
                // outside the setup window: idle. (Also (re)armed here so a fresh
                // P_TSP_RUN entry restarts the scan from the current pipeline front.)
                pf_st <= PF_OFF;
                pf_sv <= 1'b0;
            end else begin
                case (pf_st)
                // arm: start scanning from the next unresolved pixel (sida if the L1
                // slot is live, else spx). Nothing pending -> stay off.
                PF_OFF: begin
                    pf_sv <= 1'b0;
                    if (sva) begin
                        pf_scan <= sida; pf_st <= PF_SCAN0;
                    end else if (siss_more) begin
                        pf_scan <= spx;  pf_st <= PF_SCAN0;
                    end
                    // else: pipeline draining, no pixels left to scan -> stay PF_OFF.
                end
                // present the u_taginvw shade-read of pf_scan (pb_shrd driven combi via
                // pf_drive_shrd). Its {valid,tag,depth} resolve onto sh_*_o next cycle.
                PF_SCAN0: begin
                    pf_sv  <= 1'b1;
                    pf_sid <= pf_scan;
                    pf_st  <= PF_SCAN1;
                end
                // sh_*_o now hold pf_sid's tag/staged. If NOT staged (shade_mode &&
                // !sh_valid_o) skip it; else present the plane-cache lookup (pc_lu driven
                // combi via pf_drive_lu); pc_hit lands next cycle at PF_SCAN2.
                PF_SCAN1: begin
                    if (shade_mode && !sh_valid_o) begin
                        // skipped pixel: advance to the next (respect pass end 1023).
                        if (pf_sid == 10'd1023) pf_st <= PF_DONE;
                        else begin pf_scan <= pf_sid + 10'd1; pf_st <= PF_SCAN0; end
                    end else begin
                        pf_tag <= sh_tag_o;   // remember in case this is the miss
                        pf_st  <= PF_SCAN2;
                    end
                end
                // pc_hit resolved for pf_sid's tag. Keep scanning if it's a HIT, OR if
                // its tag == the CURRENT miss's tag (stagb): that tag is being resolved
                // right now and committed to the cache at this P_TSP_RUN's done, so by
                // the time the spanner reaches this pixel it'll be a HIT - prefetching it
                // is wasted and steals the slot from the true next-distinct miss. Only a
                // tag that is uncached AND != stagb is a genuine future demand miss.
                PF_SCAN2: begin
                    // skip: a hit, the current miss's own tag (stagb), OR a tag ALREADY
                    // sitting ready in the shadow (pf_ready && pf_rtag==pf_tag) - no need
                    // to re-prefetch what we already have.
                    if (pc_hit || (pf_tag == stagb) || (pf_ready && pf_rtag == pf_tag)) begin
                        if (pf_sid == 10'd1023) pf_st <= PF_DONE;
                        else begin pf_scan <= pf_sid + 10'd1; pf_st <= PF_SCAN0; end
                    end else if (!pf_busy) begin
                        // found the next miss (pf_tag captured at PF_SCAN1). Only issue
                        // when u_prefetch is free (one prefetch in flight); its done will
                        // set pf_ready/pf_rtag via the shadow-capture block above.
`ifndef SYNTHESIS
                        pc_prefetch <= pc_prefetch + 1;
                        // WASTED: a DIFFERENT-tag ready shadow is being clobbered without
                        // ever having been consumed (mis-prediction). Same-tag re-issues
                        // are skipped above, so this only counts genuine waste.
                        if (pf_ready && pf_rtag != pf_tag) begin
                            pc_pf_wasted <= pc_pf_wasted + 1;
                            if (md_en) $display("[PREFETCH] WASTED ready tag=%08x clobbered by new tag=%08x",
                                pf_rtag, pf_tag);
                        end
                        if (md_en) $display("[PREFETCH] issue tag=%08x (scanned pixel %0d, during miss tag=%08x)",
                            pf_tag, pf_sid, stagb);
`endif
                        pf_ptag  <= pf_tag;
                        pf_rtag  <= pf_tag;   // shadow will decode THIS tag
                        pf_ready <= 1'b0;     // invalidate any stale shadow
                        pf_start <= 1'b1;
                        pf_st    <= PF_ISSUE;
                    end
                    // else (pf_busy): a prefetch is still running; leave it and idle.
                end
                // prefetch issued: idle until we leave P_TSP_RUN (its done lands in the
                // shadow asynchronously via the capture block, even after PF_OFF).
                PF_ISSUE: pf_st <= PF_DONE;
                // scan exhausted / issued: idle until we leave P_TSP_RUN.
                PF_DONE: ;
                default: pf_st <= PF_OFF;
                endcase
            end

            // ================= CONCURRENT TSP READER FSM (tsp_st) =================
            // Trivial drain of span_buffer[tsp_rd] into tsp_shade_pp at 1 px/clk. All
            // plane-cache miss latency was absorbed upstream by the spanner, so this
            // never stalls except on pp_stall (texture miss) - hold the current pixel.
            // On sb_last it posts the finished tile's color (u_col[tsp_col]) to VO.
            case (tsp_st)
            // pick the next READY span half (in order via tsp_rd). Post-only -> post now.
            R_IDLE: if (sb_ready[tsp_rd]) begin
                if (sb_post[tsp_rd]) begin
                    tsp_st <= R_POST;
                end else begin
                    tsp_i     <= 10'd0;      // address to PRESENT next cycle
                    rd_v      <= 1'b0;       // nothing fed yet (1-cyc read latency)
                    rd_last   <= 1'b0;
                    sh_out_n  <= 0;
                    sh_pending <= 0;
                    tsp_st <= R_RUN;
                end
            end

            // STREAMING 1 px/clk drain. sbr_addr=tsp_i (combi) presents pixel tsp_i's
            // read THIS cycle; its data lands NEXT cycle. So the pixel being FED this
            // cycle is the one presented last cycle (rd_i, marked rd_v): its record is on
            // sbr_*[tsp_rd] now. The pp-input mux presents it (pp_in_valid when rd_v &&
            // r_shade); on pp_stall we HOLD (don't advance the present addr, so the held
            // pixel's data stays on sbr_*). When the last fed pixel (rd_last) is accepted,
            // go drain the blend.
            R_RUN: begin
                if (!pp_stall) begin
                    // this cycle FEEDS pixel rd_i (data on sbr_* now, if rd_v).
                    if (rd_v && sbr_shade[tsp_rd]) sh_pending <= sh_pending + 1;
                    if (rd_v && rd_last) begin
                        rd_v   <= 1'b0;
                        tsp_st <= R_DRAIN;
                    end else begin
                        // the pixel presented THIS cycle (tsp_i) becomes next cycle's fed
                        // pixel; advance the present address.
                        rd_v    <= 1'b1;
                        rd_i    <= tsp_i;
                        rd_last <= (tsp_i == 10'd1023);
                        if (tsp_i != 10'd1023) tsp_i <= tsp_i + 10'd1;
                    end
                end
                // else pp_stall: hold tsp_i/rd_i/rd_v so the fed pixel's read stays valid.
            end

            // wait for the shade+blend pipe to drain (all fed pixels emerged and the
            // trailing blend RMW landed). Free this span half; advance tsp_rd. If this
            // was the tile's FINAL shade (sb_last) hand u_col to VO (R_POST).
            R_DRAIN: if (sh_out_n >= sh_pending && !cb_valid) begin
                sb_ready[tsp_rd] <= 1'b0;
`ifndef SYNTHESIS
                pc_drain <= pc_drain + 1;
`endif
                if (sb_last[tsp_rd]) tsp_st <= R_POST;
                else begin
                    tsp_rd <= ~tsp_rd;
                    tsp_st <= R_IDLE;
                end
            end

            // POST the finished tile's color (u_col[tsp_col]) to the VO engine via the
            // u_col ping-pong credit: stall until VO has drained this half
            // (!col_full[tsp_col]), then set the credit + coords, flip tsp_col, advance.
            // Post-only halves reach here without R_DRAIN, so free the credit here too.
            R_POST: if (!col_full[tsp_col]) begin
                col_post    <= 1'b1;
                col_post_hp <= tsp_col;
                col_post_tx <= sb_tx[tsp_rd];
                col_post_ty <= sb_ty[tsp_rd];
                tsp_col <= ~tsp_col;             // next tile -> other u_col half
                sb_ready[tsp_rd] <= 1'b0;        // free (covers the post-only path)
`ifndef SYNTHESIS
                if (sb_post[tsp_rd]) pc_drain <= pc_drain + 1;  // post-only: not via R_DRAIN
`endif
                tsp_rd <= ~tsp_rd;
                tsp_st <= R_IDLE;
            end
            default: tsp_st <= R_IDLE;
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

    // ==================== DECOUPLED VIDEO-OUT (FLUSH) ENGINE ====================
    // Runs CONCURRENTLY with ISP/TSP. Owns the per-half color credit col_full and
    // the VO consumption pointer col_vo. col_full[h] is SET here from the main FSM's
    // 1-cycle col_post intent (single writer -> no multi-driver conflict) and CLEARED
    // when the half's flush completes. VO drains halves in production order: it waits
    // for col_full[col_vo], streams that half's 1024 pixels to fbw (1 px/cyc, holding
    // on fbw_resp.busy), then clears the credit and advances col_vo. The combinational
    // fbw_req / cb_fl_* drivers key off vst / vo_i / vo_tx / vo_ty (see above).
    always @(posedge clk) begin
        if (reset) begin
            vst<=VO_IDLE; vo_i<=10'd0; col_vo<=1'b0; col_full<=2'b00;
            vo_tx<=6'd0; vo_ty<=6'd0;
        end else begin
            // SET credit from the main FSM's post intent (main FSM flips col_prod).
            if (col_post) begin
                col_full[col_post_hp] <= 1'b1;
                col_tx[col_post_hp]   <= col_post_tx;
                col_ty[col_post_hp]   <= col_post_ty;
            end

            case (vst)
            VO_IDLE: if (col_full[col_vo]) begin
                // this half holds a finished tile: latch its coords, prime pixel 0.
                vo_tx <= col_tx[col_vo]; vo_ty <= col_ty[col_vo];
                vo_i  <= 10'd0;
                vst   <= VO_RD;          // cb_fl_* presents the read of vo_i=0
            end
            VO_RD: vst <= VO_WR;         // registered read lands next cycle
            VO_WR: if (fw_pix_consumed) begin
                if (vo_i == 10'd1023) begin
                    col_full[col_vo] <= 1'b0;                 // release the half
                    col_vo <= ~col_vo;                       // next half in order
                    vst    <= VO_IDLE;
                end else begin
                    vo_i <= vo_i + 10'd1; vst <= VO_RD;       // present next pixel read
                end
            end
            default: vst <= VO_IDLE;
            endcase
        end
    end
endmodule

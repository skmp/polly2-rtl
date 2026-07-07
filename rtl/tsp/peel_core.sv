// peel_core - the layer-peeling tile render core, with the DDR controller and the
// framebuffer INJECTED as dependencies (ports). Contains: reg_file, the 6-client
// single-channel DDR arbiter, the data/texture caches, region/objlist/iterator
// parsers, ISP setup+raster, the pipelined TSP shade+blend, and the unified PT+TL
// peel FSM. The single 64-bit DDR read channel below the arbiter is exposed as
// ddr_req/ddr_resp; the shaded framebuffer is streamed out one pixel/cycle on fbw_*.
//
//   per pixel: tag -> plane-cache lookup (64-entry, keyed by the FULL 32-bit
//   CoreTag) miss: fetch param record (GetFpuEntry) + tsp_setup_min; hit: planes
//   from cache. tsp_shade_v2_pp shades (textures via two tex_cache_4p over the shared
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
    pal_rd_req_t pal_req [0:3]; pal_rd_resp_t pal_resp [0:3];   // 4 corner palette read ports
    assign fog_req = '0;
    // pal_req[*] driven by the shader's 4 palette read ports (pp_pal_addr) below.
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
    // The two texture caches (data + VQ) now live INSIDE tsp_shade_v2_pp's tex_unit; the
    // shader drives tex_dreq[0]/tex_dreq[1] (this core's DDR arbiter tc/vq clients) directly
    // via its ddr_req/ddr_resp ports (wired at the shader instance below).

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
    reg              it_entry_pt;                       // combinational eq head list-kind (PT)
    triangle_out_t   it_trio; triangle_ack_t it_ack;
    isp_primitive_iterator_pf u_it (.clk(clk),.reset(reset),
        .intensity_shadow(regs.fpu_shad_scale.intensity_shadow),
        .param_base(param_base),
        .entry_valid(it_entry_valid),.entry_type(it_etype),.entry(it_entry),
        .entry_pt(it_entry_pt),
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
    reg  [31:0] tri_tag;                   // active (raster) triangle's CoreTag
    reg         tri_is_pt;                 // active (raster) triangle's list-kind (PT)
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
    wire        su_out_pt;    // list-kind (PT) of the retiring triangle
    // gate on fq_out_valid (the head entry is loaded in the output register), not
    // just !fq_empty: the M10K read that fills fq_out lags a pushed entry by a cycle.
    assign su_in_valid = fq_out_valid && (pq_count <= 5'd4);

    isp_setup_streamed u_isp (
        .clk(clk), .reset(reset),
        .in_valid(su_in_valid), .in_ready(su_in_ready),
        .isp_word(fq_out[FF_ISP +:32]), .in_tag(fq_out[FF_TAG +:32]), .in_pt(fq_out[FF_PT]),
        .x1(fq_out[FF_X1 +:32]), .y1(fq_out[FF_Y1 +:32]), .z1(fq_out[FF_Z1 +:32]),
        .x2(fq_out[FF_X2 +:32]), .y2(fq_out[FF_Y2 +:32]), .z2(fq_out[FF_Z2 +:32]),
        .x3(fq_out[FF_X3 +:32]), .y3(fq_out[FF_Y3 +:32]), .z3(fq_out[FF_Z3 +:32]),
        .xbase(t_xbase), .ybase(t_ybase),
        .busy(su_busy),
        .out_ready(!pq_full),
        .out_valid(su_out_valid), .out_tag(su_out_tag), .out_pt(su_out_pt), .out_isp(su_out_isp),
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
    reg                    b_which;     // per-triangle is_pt (tri_is_pt) snapshot (PT => dt_pt=1)

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
    // spanner_v2 drives the 4-wide aligned read (declared here; driven in the spanner region)
    wire        spv_rd_valid;
    wire [9:0]  spv_rd_group;
    // per-half 4-wide aligned read outputs; the spanner consumes the CONSUMER half (tsp_tag)
    wire [3:0]  g4_valid_h [0:1];
    wire [31:0] g4_tag_h   [0:1][0:3];
    wire [31:0] g4_invw_h  [0:1][0:3];
    wire [3:0]  g4_pt_h    [0:1];
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
            // single-pixel shade read retired: spanner_v2 uses the 4-wide port
            .sh_rd_valid(1'b0), .sh_rd_id(10'd0),
            .sh_valid(), .sh_tag(), .sh_depth(), .sh_pt(),
            // 4-wide aligned read (spanner_v2), driven on the CONSUMER half only
            .rd4_valid(ti_cons && spv_rd_valid), .rd4_group(spv_rd_group),
            .g4_valid(g4_valid_h[gti]), .g4_tag(g4_tag_h[gti]),
            .g4_invw(g4_invw_h[gti]), .g4_pt(g4_pt_h[gti])
        );
      end
    endgenerate

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

    // ============ SPANNER_v2 -> TSP shared DENSE span RING ==========================
    // spanner_v2 writes shaded spans into ONE shared ring dense_span_buffer (slot = span_head,
    // wrapping): {start, id, rep, invw[0:3], at}. The reader walks a pass's ring range
    // [md_base .. +md_cnt) and EXPANDS each span's rep pixels (pixel k = start+k) into the
    // shade pipe, looking up the shared triangle_setups RING [id] for planes.
    //
    // DEEPER PIPELINING: the ring (2048 = two worst-case tiles) + an N-deep pass-metadata FIFO
    // replace the old 2-half ping-pong, so the spanner can run SEVERAL passes ahead of the
    // reader (bounded by MD_N and the spanner's go-FIFO depth), not just one. Each pass the
    // spanner hands PUSHES one descriptor {base,cnt,last,post,tx,ty}; the reader POPs the head.
    localparam integer SPAN_NSLOT = 2*TILE_W*TILE_H;   // 2048
    localparam integer SPAN_AW    = $clog2(SPAN_NSLOT); // 11 (slot address width)
    localparam integer MD_N       = 8;                  // passes in flight (== spanner GF depth).
                                                        // 8, not 4: during PEEL few spans/planes
                                                        // survive, so the DATA rings (span 2048 /
                                                        // plane 1024) rarely fill even with 8
                                                        // passes queued - only this control FIFO
                                                        // (+ the spanner go-FIFO GF_AW) grows.
    localparam integer MD_AW      = $clog2(MD_N);        // 3
    reg  [SPAN_AW-1:0] md_base [0:MD_N-1];  // per-pass ring base slot (span_pass_base)
    reg  [SPAN_AW:0]   md_cnt  [0:MD_N-1];  // per-pass span count (0 => empty pass)
    reg                md_last [0:MD_N-1];  // per-pass: tile's final shade -> post color
    reg                md_post [0:MD_N-1];  // per-pass: post-only (OP-only FLUSH, no shade)
    reg  [5:0]         md_tx   [0:MD_N-1], md_ty [0:MD_N-1];
    reg  [MD_AW:0]     md_wp, md_rp;        // FIFO ptrs (extra MSB for full/empty disambig)
    wire               md_empty = (md_wp == md_rp);
    wire               md_full  = (md_wp[MD_AW] != md_rp[MD_AW]) &&
                                  (md_wp[MD_AW-1:0] == md_rp[MD_AW-1:0]);
`ifndef SYNTHESIS
    // sim-only running counter: total spans QUEUED but not yet freed by the reader. Added when
    // a real pass is pushed (md_cnt), subtracted when the reader frees a pass at R_DRAIN. Used
    // by the +tsplag "spans behind" trace. A running counter avoids summing a moving FIFO window
    // (stale slots / mid-cycle md_rp advance made a combinational sum unreliable).
    integer spans_inflight;
    // remember each pushed pass's span count so R_DRAIN can subtract the SAME value on free,
    // indexed by the reader's md_rp (the pass being freed).
    reg [SPAN_AW:0] md_cnt_dbg [0:MD_N-1];
`endif
    // dense span buffer WRITE bus (spanner_v2 sp_* port; driven in the spanner region below)
    wire               sp_we;
    wire [SPAN_AW-1:0] sp_slot;             // ring write slot (span_head)
    wire [9:0]         sp_start, sp_id;
    wire [2:0]         sp_rep;
    wire [31:0]        sp_invw [0:3];
    wire               sp_at;
    // TSP reader read port (one span/slot) into the shared ring
    reg  [SPAN_AW-1:0] dsr_addr;
    wire [9:0]         dsr_start, dsr_id;
    wire [2:0]         dsr_rep;
    wire [31:0]        dsr_invw  [0:3];
    wire               dsr_at;
    dense_span_buffer #(.DEPTH(SPAN_NSLOT)) u_span (
        .clk(clk),
        .we(sp_we), .waddr(sp_slot),
        .w_start(sp_start), .w_id(sp_id), .w_rep(sp_rep), .w_invw(sp_invw), .w_at(sp_at),
        .raddr(dsr_addr),
        .r_start(dsr_start), .r_id(dsr_id), .r_rep(dsr_rep),
        .r_invw(dsr_invw), .r_at(dsr_at)
    );

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
    // v2 TSP front: spanner_v2 (SPANGEN + SETUP), span_expander, shared triangle_setups RING.
    // Replaces the old plane_cache + dual record_fetcher + tsp_setup_min + spn pixel-walk.
    // spanner_v2 reads the CONSUMER taginvw half 4 aligned px/clk, coalesces same-tag runs
    // into spans, bump-allocates a dense setup id per distinct triangle into the shared ring,
    // fetches+sets-up its planes into triangle_setups[id], and streams sparse spans. The
    // span_expander converts each span to per-pixel span_buffer_v2 writes. The reader walks
    // span_buffer_v2 densely and looks up triangle_setups[id] for the planes.
    //
    // RING: triangle_setups is ONE shared instance (no ping-pong). spanner_v2 bump-allocates
    // ids (top_tag); when a pass's setups are all written it records the tile's end pointer;
    // the reader pulses spv_rd_done when it finishes draining that pass, freeing the range.
    // ==================================================================

    // ---- spanner_v2 control glue ----
    reg         spv_start;            // 1-cyc: begin a tile pass
    wire        spv_busy;
    wire        spv_tsp_go;           // ring go pulse (go-FIFO auto-records the tile end)
    reg         spv_rd_done;          // 1-cyc: reader freed the oldest handed tile's ring range
    reg         spv_shade_mode;       // spn_xbase/ybase/tx/ty declared with the ISP origins

    // ---- 4-wide taginvw read muxed to the CONSUMER half (tsp_tag). g4_*_h come from the
    // taginvw generate above; spv_rd_valid/spv_rd_group are driven by spanner_v2 below. ----
    wire [31:0] g4_tag_c  [0:3];
    wire [31:0] g4_invw_c [0:3];
    wire [3:0]  g4_valid_c = g4_valid_h[tsp_tag];
    wire [3:0]  g4_pt_c    = g4_pt_h[tsp_tag];
    genvar gm;
    generate
      for (gm = 0; gm < 4; gm = gm + 1) begin : g4mux
        assign g4_tag_c [gm] = g4_tag_h [tsp_tag][gm];
        assign g4_invw_c[gm] = g4_invw_h[tsp_tag][gm];
      end
    endgenerate

    // ---- spanner_v2 -> triangle_setups (SETUP write) + dense_span_buffer (SPANGEN spans) ----
    // sp_* dense span write bus is declared with the dense_span_buffer above. The span-count
    // range (sp_first/sp_last/sp_cnt_z) is captured per pass by the glue at busy->0.
    wire         ts_we;
    wire [9:0]   ts_id;
    wire [31:0]  ts_isp, ts_tsp, ts_tcw;
    wire [319:0] ts_ddx, ts_ddy, ts_c;
    wire         sp_ready;
    wire [SPAN_AW:0] spv_sp_range_base, spv_sp_range_cnt;  // this pass's span ring range

    spanner_v2 #(.NSLOT(TILE_W*TILE_H), .SLOTW(10),
                 .SPAN_NSLOT(SPAN_NSLOT), .SPAN_W(SPAN_AW)) u_spanner (
        .clk(clk), .reset(reset),
        .start(spv_start), .busy(spv_busy), .shade_mode(spv_shade_mode),
        .xbase(spn_xbase), .ybase(spn_ybase), .param_base(param_base),
        .intensity_shadow(regs.fpu_shad_scale.intensity_shadow),
        .tsp_go(spv_tsp_go), .tsp_rd_done(spv_rd_done),
        .rd_valid(spv_rd_valid), .rd_group(spv_rd_group),
        .ti_valid(g4_valid_c), .ti_tag(g4_tag_c), .ti_invw(g4_invw_c), .ti_pt(g4_pt_c),
        .ts_we(ts_we), .ts_id(ts_id), .ts_isp(ts_isp), .ts_tsp(ts_tsp), .ts_tcw(ts_tcw),
        .ts_ddx(ts_ddx), .ts_ddy(ts_ddy), .ts_c(ts_c),
        .sp_we(sp_we), .sp_slot(sp_slot),
        .sp_range_base(spv_sp_range_base), .sp_range_cnt(spv_sp_range_cnt),
        .sp_start(sp_start), .sp_id(sp_id), .sp_rep(sp_rep),
        .sp_invw(sp_invw), .sp_at(sp_at), .sp_ready(sp_ready),
        .dreq(ts_dreq), .dresp(ts_dresp)
    );
    // The expander is gone: spanner_v2 writes dense_span_buffer directly. sp_ready is 1'b1
    // (the dense buffer accepts one span/clk unconditionally - no rep-cycle backpressure).
    assign sp_ready = 1'b1;

    // shared triangle_setups RING (spanner writes by id, reader reads by the span's id)
    reg  [9:0]   tsg_raddr;
    wire [31:0]  tsg_r_tsp, tsg_r_tcw;
    wire         tsg_r_ptex, tsg_r_pofs;
    wire [31:0]  tsg_r_ddx [0:9], tsg_r_ddy [0:9], tsg_r_c [0:9];
    triangle_setups #(.DEPTH(TILE_W*TILE_H), .AW(10)) u_tsg (
        .clk(clk),
        .we(ts_we), .waddr(ts_id),
        .w_isp(ts_isp), .w_tsp(ts_tsp), .w_tcw(ts_tcw),
        .w_ddx(ts_ddx), .w_ddy(ts_ddy), .w_c(ts_c),
        .raddr(tsg_raddr),
        .r_tsp(tsg_r_tsp), .r_tcw(tsg_r_tcw), .r_ptex(tsg_r_ptex), .r_pofs(tsg_r_pofs),
        .r_ddx(tsg_r_ddx), .r_ddy(tsg_r_ddy), .r_c(tsg_r_c)
    );


    // -------------------- TSP shade (FULLY PIPELINED, 1 pixel/clock) --------------------
    // The streaming producer presents a resolved pixel (planes from the plane cache
    // on a hit, or from cur_* on a just-fetched miss) on pp_in_valid; tsp_shade_v2_pp
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

    // pixel palette read ports (shader -> reg_file's 4-copy PAL RAM)
    wire [9:0] pp_pal_addr [0:3];
    assign pal_req[0].raddr = pp_pal_addr[0]; assign pal_req[1].raddr = pp_pal_addr[1];
    assign pal_req[2].raddr = pp_pal_addr[2]; assign pal_req[3].raddr = pp_pal_addr[3];
    wire [31:0] pp_pal_data [0:3];
    assign pp_pal_data[0] = pal_resp[0].rdata; assign pp_pal_data[1] = pal_resp[1].rdata;
    assign pp_pal_data[2] = pal_resp[2].rdata; assign pp_pal_data[3] = pal_resp[3].rdata;

    tsp_shade_v2_pp #(.IDW(11)) u_shade (
        .clk(clk),.reset(reset),
        .in_valid(pp_in_valid),.in_id(pp_in_id),.px(pp_px),.py(pp_py),.invw_in(pp_invw),
        .in_ddx(pp_ddx),.in_ddy(pp_ddy),.in_c(pp_c),
        .tsp(pp_tsp),.tcw(pp_tcw),.text_ctrl(regs.text_control[4:0]),
        .pal_fmt(regs.pal_ram_ctrl[1:0]),
        .pp_texture(pp_ptex),.pp_offset(pp_pofs),
        .out_valid(pp_out_valid),.out_id(pp_out_id),.out_argb(pp_out_argb),
        .out_tsp(pp_out_tsp),
        .stall(pp_stall),
        .pal_addr(pp_pal_addr),.pal_data(pp_pal_data),
        .ddr_req(tex_dreq),.ddr_resp(tex_dresp));

`ifndef SYNTHESIS
    // -------- tsp_shade_v2_pp INPUT DUMP (sim only) --------------------------------------
    // Dumps every pixel ACCEPTED by the shader (pp_in_valid && !pp_stall) with all of its
    // inputs, so the exact per-pixel stream feeding tsp_shade_v2_pp can be diffed against the
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
            $fwrite(sd_fd, "# tsp_shade_v2_pp input dump: one line per accepted pixel\n");
            $fwrite(sd_fd, "# seq id px py invw tsp tcw text_ctrl ptex pofs ddx0..9 ddy0..9 c0..9\n");
        end
    end
    always @(posedge clk) begin
        if (!reset && sd_en && pp_in_valid && !pp_stall) begin
            $fwrite(sd_fd, "%0d %0d %0d %0d %0d %0d %08x %08x %08x %02x %0d %0d",
                    sd_seq, md_tx[md_rp[MD_AW-1:0]], md_ty[md_rp[MD_AW-1:0]], pp_in_id, pp_px, pp_py,
                    pp_invw, pp_tsp, pp_tcw,
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
        $display("[peel_core] tsp_shade_v2_pp input dump: %0d pixels written to %0s", sd_seq, sd_name);
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

    // ---- single shared shade sub-phase (ONE tsp_shade_v2_pp pipeline) ----
    // Invoked as a subroutine after OP and after each peel pass. The TSP pipeline
    // ALWAYS blends (refsw PixelFlush_tsp always runs BlendingUnit); the tag's
    // SrcInstr/DstInstr decide the effect (opaque tags use ONE/ZERO = overwrite).
    // shade_mode only selects WHICH pixels are shaded, not whether we blend:
    //   0 = OP  : shade every pixel of the tile
    //   1 = PEEL: shade only pixels staged this pass (dt_valid)
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
    // ---- SPANNER_v2 GLUE FSM (spn) ----
    // Starts spanner_v2 on a ready input half, waits its busy->0 (all spans emitted + all
    // setups written into the shared triangle_setups ring), then hands the span_buffer_v2
    // half to the reader. All resolve/fetch/setup work lives inside spanner_v2; this FSM is
    // pure handshake glue (post-only tiles skip the spanner run entirely).
    localparam G_IDLE=0, G_START=1, G_RUN=2;
    reg [1:0]  spn;

    // ---- TSP READER FSM (tsp_st): pops the head pass descriptor (md FIFO), walks that pass's
    // span RING range [md_base .. +md_cnt) with wrap, EXPANDS each span's rep pixels, looks up
    // triangle_setups[id], feeds tsp_shade_v2_pp.
    //   R_IDLE : pop-peek the head descriptor (md_rp); post-only/empty -> post/skip
    //   R_RUN  : per span: read span (Stage A, dsr_*), latch + expand rep pixels (Stage B),
    //            present triangle_setups[id]; feed pp from the carried pixel + planes (Stage C).
    //            Advance span_ptr (wrapping) only when a span finishes; stop via span_left.
    //   R_DRAIN: all fed; wait blend to drain, then free this pass's ring range (spv_rd_done)
    //            and pop md_rp (unless md_last -> R_POST pops).
    //   R_POST : post the finished tile's u_col to VO (on md_last), pop md_rp
    localparam R_IDLE=0, R_RUN=1, R_DRAIN=3, R_POST=4;
    reg [2:0]  tsp_st;
    // DENSE reader pipeline (3 decoupled stages, no bubble):
    //  A) READ    : dsr_addr=span_ptr issues a slot read (registered, lands next cycle).
    //               span_ptr advances per read issued; sb_rd_pend tracks a read in flight.
    //  B) SKID    : ns_* holds ONE prefetched span (the resolved dsr_*), decoupling the
    //               fixed 1-cycle read latency from the VARIABLE (1..4 cyc) expand below.
    //  C) EXPAND  : cs_* is the span being expanded; cs_k walks 0..rep-1 -> Stage C -> pp.
    // The skid lets READ run ahead and refill while EXPAND is busy, so every slot is
    // consumed exactly once, in order, with no idle cycle between spans.
    reg [SPAN_AW-1:0] span_ptr; // the IN-FLIGHT ring slot (Stage A addr), held stable, wraps
    reg        rd_live;       // a slot read is OUTSTANDING (issued, not yet consumed)
    reg        sb_rd_pend;    // the outstanding read has RESOLVED on dsr_* this cycle
    reg        span_more;     // a slot remains AFTER the in-flight one (derived from span_left)
    reg [SPAN_AW:0] span_left; // spans not yet CONSUMED (incl the in-flight one); md_cnt at prime
    // Stage B skid: one prefetched span awaiting EXPAND.
    reg        ns_v;
    reg [9:0]  ns_start, ns_id;
    reg [2:0]  ns_rep;
    reg [31:0] ns_invw [0:3];
    reg        ns_at;
    // Stage C expand: current span being expanded + pixel counter k
    reg        cs_v;          // a span is being expanded (cs_* valid)
    reg [9:0]  cs_start, cs_id;
    reg [2:0]  cs_rep;
    reg [31:0] cs_invw [0:3];
    reg        cs_at;
    reg [2:0]  cs_k;          // pixel-within-span 0..rep-1
    // Stage C: the pixel emitted last cycle -> feeds pp with fresh planes (tsg_r_* for cs_id).
    reg        s2_v;          // Stage C occupied (a pixel to feed pp this cycle)
    reg [9:0]  s2_p;          // pixel index (y:x)
    reg [31:0] s2_invw;
    reg        s2_at;
    reg [9:0]  s2_id;         // held to re-present the tsg read on pp_stall

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
    reg             eq_ispt  [0:EQ_N-1];   // per-entry list-kind (PT), tagged at push
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
        it_entry_pt = eq_ispt[eq_head[2:0]];
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
    localparam integer FQ_W = 353;   // 11 * 32 + 1 (is_pt)
    localparam integer FF_ISP=0,  FF_TAG=32,
                       FF_X1=64,  FF_Y1=96,  FF_Z1=128,
                       FF_X2=160, FF_Y2=192, FF_Z2=224,
                       FF_X3=256, FF_Y3=288, FF_Z3=320,
                       FF_PT=352;    // list-kind (PT) bit
    (* ramstyle = "M10K, no_rw_check" *) reg [FQ_W-1:0] fq_ram [0:FIFO_N-1];
    reg [FQ_W-1:0] fq_out;         // registered head entry (FWFT output register)
    reg            fq_out_valid;   // fq_out holds a valid head entry
    reg [3:0]  fq_head, fq_tail;   // ring indices 0..FIFO_N-1 (0..7)
    reg [4:0]  fq_count;
    reg        fifo_push, fifo_pop; // 1-cycle intents (reconciled into fq_count)

    // assemble the push word from the iterator's triangle
    wire [FQ_W-1:0] fq_wrw;
    assign fq_wrw[FF_ISP +:32] = it_trio.isp;  assign fq_wrw[FF_TAG +:32] = it_trio.tag;
    assign fq_wrw[FF_PT]       = it_trio.is_pt;
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
    localparam integer PQ_W = 565;   // 17*32 + 4*5 + 1 (is_pt)
    localparam integer QF_DX12=0,  QF_DX23=32,  QF_DX31=64,  QF_DX41=96;
    localparam integer QF_DY12=128,QF_DY23=160, QF_DY31=192, QF_DY41=224;
    localparam integer QF_C1=256,  QF_C2=288,   QF_C3=320,   QF_C4=352;
    localparam integer QF_DDX=384, QF_DDY=416,  QF_CINVW=448;
    localparam integer QF_ISP=480, QF_TAG=512;
    localparam integer QF_BX0=544, QF_BX1=549,  QF_BY0=554,  QF_BY1=559;   // 5b each
    localparam integer QF_PT=564;    // list-kind (PT) bit
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
    assign pq_wrw[QF_PT]         = su_out_pt;
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
    // ---- ISP-ALONE breakdown: cycles where ISP is busy but SPANNER and TSP are BOTH idle
    // (occ==I, the non-overlapped ISP work), partitioned by which `st` phase ISP is in. This
    // tells us where the un-overlappable ISP time goes: CLEAR/PeelBuffers M10K walks vs OL
    // parse vs barrier vs credit-stall vs setup/other. Indices:
    localparam integer IA_CLEAR=0, IA_PEELBUF=1, IA_OL=2, IA_BARRIER=3,
                       IA_SHWAIT=4, IA_SETUP=5, IA_OTHER=6, IA_N=7;
    integer pc_isp_alone [0:IA_N-1];
    // ---- RS_IDLE breakdown: the raster consumer sits in RS_IDLE (pc_ras_idle) whenever the
    // plane FIFO has no triangle to raster. Partition those cycles by the top `st` phase to
    // see WHY raster is idle: CLEAR/PeelBuffers M10K walks, OL parse, barrier, shade-wait
    // credit, or genuinely overlapped with the spanner/reader shading a prior pass (RI_SHADE
    // = good idle - raster done, downstream still busy). Same index scheme + a SHADE bucket.
    localparam integer RI_CLEAR=0, RI_PEELBUF=1, RI_OL=2, RI_BARRIER=3, RI_SHWAIT=4,
                       RI_SHADE=5, RI_OTHER=6, RI_N=7;
    integer pc_ras_idle_by [0:RI_N-1];
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
    always @(*) begin
        // ---- peel buffer ----
        pb_ra_valid    = ras_out_valid;               // stage-A read (chunk resolved)
        pb_clr_valid   = (st == S_CLEAR_WR);          // CLEAR walk write
        pb_clr_addr    = cl_i;
        pb_bufrd_valid = (st == S_PEEL_BUF_RUN);      // PeelBuffers read-ahead
        pb_bufrd_addr  = pb_rd;
        pb_bufwr_valid = (st == S_PEEL_BUF_RUN) && pb_pipe;  // PeelBuffers delayed write
        pb_bufwr_addr  = pb_i;
        // (stage-B write is driven by the b_valid port directly on u_peel)

        // ---- color buffer ----
        // STREAMING shade pipe: pp_out_valid is a clean 1-cycle pulse INDEPENDENT of
        // pp_stall (the back-end drains while the front may be stalled on a texture miss).
        cb_ca_valid = pp_out_valid;                   // blend stage CA read (out_id)
        cb_ca_id    = pp_out_id[9:0];                 // [10] is the at-bit
        // FLUSH read is driven by the DECOUPLED video-out FSM (vst), on the VO half.
        cb_fl_valid = (vst == VO_RD || vst == VO_WR); // VO read (vo_i)
        cb_fl_id    = vo_i;

        // ---- TSP reader read-address presentation (dense span walk + expand) ----
        // Stage A: dsr_addr = span_ptr = the IN-FLIGHT slot, held stable until consumed into
        // the skid (so the registered read output dsr_* stays valid across a multi-cycle expand).
        // setups ring: present the CURRENT expanding span's id (cs_id) so planes are stable
        // across the span's rep pixels. On pp_stall, hold both (re-present s2_id for planes).
        dsr_addr  = span_ptr;
        tsg_raddr = pp_stall ? s2_id : cs_id;
    end

    // ---- pp-input mux: drive tsp_shade_v2_pp's inputs COMBINATIONALLY from stage S2 ----
    // S2 holds pixel s2_p: {shade,invw,at} carried from S1; planes are fresh on tsg_r_* (the
    // setups read of s2's id, presented last cycle). Present to the shader when s2 is a
    // shaded pixel; hold on pp_stall (the reader FSM freezes the whole pipeline).
    integer pj;
    integer pj2;   // reader span-expand invw copy loop
    always @(*) begin
        pp_in_valid = (tsp_st == R_RUN) && s2_v;   // every emitted span pixel is shaded
        pp_in_id    = {s2_at, s2_p};             // fed pixel = s2_p; [10]=PT alpha-test
        pp_invw     = s2_invw;
        pp_tsp      = tsg_r_tsp;
        pp_tcw      = tsg_r_tcw;
        pp_ptex     = tsg_r_ptex;
        pp_pofs     = tsg_r_pofs;
        for (pj = 0; pj < 10; pj = pj + 1) begin
            pp_ddx[pj] = tsg_r_ddx[pj];
            pp_ddy[pj] = tsg_r_ddy[pj];
            pp_c[pj]   = tsg_r_c  [pj];
        end
        pp_px = pp_in_id[4:0];
        pp_py = pp_in_id[9:5];    // [10] is the at-bit, not part of px/py
    end

    always @(posedge clk) begin
        if (reset) begin
            st<=S_IDLE; done<=0; ra_start<=0; ol_start<=0;
            spv_start<=1'b0; spv_rd_done<=1'b0;
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
            for (pc_i=0; pc_i<IA_N; pc_i=pc_i+1) pc_isp_alone[pc_i]<=0;
            for (pc_i=0; pc_i<RI_N; pc_i=pc_i+1) pc_ras_idle_by[pc_i]<=0;
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
            // SPANNER_v2 glue + TSP reader FSMs
            spn<=G_IDLE;
            spv_shade_mode<=1'b0;
            spn_tx<=6'h3f; spn_ty<=6'h3f;
            spn_xbase<=32'd0; spn_ybase<=32'd0;
            tsp_st<=R_IDLE;
            span_ptr<='0; span_left<='0; rd_live<=1'b0; sb_rd_pend<=1'b0; span_more<=1'b0; ns_v<=1'b0;
            cs_v<=1'b0; cs_k<=3'd0; s2_v<=1'b0; s2_id<=10'd0;
            md_wp<='0; md_rp<='0;                 // span pass-metadata FIFO ptrs
`ifndef SYNTHESIS
            spans_inflight<=0;
`endif
            ti_ready<=2'b00; tsp_tag<=1'b0; tsp_col<=1'b0;
            ti_postonly[0]<=1'b0; ti_postonly[1]<=1'b0;
            // htile = ISP u_taginvw producer half (per pass); tsp_tag/tsp_col above.
            htile<=1'b0;
        end else begin
`ifndef SYNTHESIS
            // -------- performance counters: charge THIS clock to its buckets --------
            // Only count while the core is doing tile work (not the top-level idle wait
            // for a start). Approximate "active" as: not S_IDLE, or any engine busy
            // (raster, setup, OR the decoupled video-out engine).
            if (st != S_IDLE || rs_st != RS_IDLE || su_busy || vst != VO_IDLE
                             || spv_busy || spn != G_IDLE || tsp_st != R_IDLE) begin
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
                end else if (spv_busy)                            pc_sh_setup_wait <= pc_sh_setup_wait + 1;
                else if (tsp_st==R_DRAIN)                         pc_sh_drain <= pc_sh_drain + 1;
                else                                              pc_sh_none  <= pc_sh_none  + 1;

                // top-level phase view (whole-core). SHADE now = spanner OR reader busy.
                if (st==S_CLEAR_WR)                               pc_top_clear   <= pc_top_clear   + 1;
                else if (st==S_PEEL_BUF_RUN)                      pc_top_peelbuf <= pc_top_peelbuf + 1;
                else if (st==S_OL_RUN)                            pc_top_ol      <= pc_top_ol      + 1;
                else if (st==S_DRAIN)                             pc_top_barrier <= pc_top_barrier + 1;
                else                                              pc_top_other   <= pc_top_other   + 1;
                if (spv_busy || spn != G_IDLE || tsp_st != R_IDLE) pc_top_shade  <= pc_top_shade   + 1;

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
                    e_spn = spv_busy || (spn != G_IDLE);
                    e_tsp = (tsp_st != R_IDLE);
                    occ = {e_isp, e_spn, e_tsp};
                    pc_occ[occ] <= pc_occ[occ] + 1;
                    if (e_isp) pc_isp_busy <= pc_isp_busy + 1;
                    if (e_spn) pc_spn_busy <= pc_spn_busy + 1;
                    if (e_tsp) pc_tsp_busy <= pc_tsp_busy + 1;
                    // stalls: ISP on the u_taginvw credit; reader on the u_col credit.
                    if (st==S_PEEL_BUF && ti_ready[htile]) pc_shwait <= pc_shwait + 1;
                    if (tsp_st==R_POST && col_full[tsp_col]) pc_post_stall <= pc_post_stall + 1;
                    // ISP-ALONE breakdown (occ==I: ISP busy, spanner+reader BOTH idle). Classify
                    // by top `st`. e_isp only sets for the M10K walks / OL / raster / setup, so
                    // this partitions the non-overlapped ISP work into its actual sinks.
                    if (e_isp && !e_spn && !e_tsp) begin
                        if      (st==S_CLEAR_WR)                  pc_isp_alone[IA_CLEAR]   <= pc_isp_alone[IA_CLEAR]   + 1;
                        else if (st==S_PEEL_BUF_RUN)              pc_isp_alone[IA_PEELBUF] <= pc_isp_alone[IA_PEELBUF] + 1;
                        else if (st==S_OL_RUN)                    pc_isp_alone[IA_OL]      <= pc_isp_alone[IA_OL]      + 1;
                        else if (st==S_DRAIN)                     pc_isp_alone[IA_BARRIER] <= pc_isp_alone[IA_BARRIER] + 1;
                        else if (st==S_PEEL_BUF && ti_ready[htile]) pc_isp_alone[IA_SHWAIT] <= pc_isp_alone[IA_SHWAIT] + 1;
                        else if (su_busy || rs_st!=RS_IDLE)       pc_isp_alone[IA_SETUP]   <= pc_isp_alone[IA_SETUP]   + 1;
                        else                                      pc_isp_alone[IA_OTHER]   <= pc_isp_alone[IA_OTHER]   + 1;
                    end
                    // RS_IDLE breakdown: raster consumer idle (pc_ras_idle), by top `st`. A
                    // SHADE bucket separates GOOD idle (raster done, spanner/reader still
                    // shading a prior pass -> overlapped) from the serial M10K-walk/barrier idle.
                    if (rs_st==RS_IDLE) begin
                        if      (st==S_CLEAR_WR)                    pc_ras_idle_by[RI_CLEAR]   <= pc_ras_idle_by[RI_CLEAR]   + 1;
                        else if (st==S_PEEL_BUF_RUN)                pc_ras_idle_by[RI_PEELBUF] <= pc_ras_idle_by[RI_PEELBUF] + 1;
                        else if (st==S_OL_RUN)                      pc_ras_idle_by[RI_OL]      <= pc_ras_idle_by[RI_OL]      + 1;
                        else if (st==S_DRAIN)                       pc_ras_idle_by[RI_BARRIER] <= pc_ras_idle_by[RI_BARRIER] + 1;
                        else if (st==S_PEEL_BUF && ti_ready[htile]) pc_ras_idle_by[RI_SHWAIT]  <= pc_ras_idle_by[RI_SHWAIT]  + 1;
                        else if (e_spn || e_tsp)                    pc_ras_idle_by[RI_SHADE]   <= pc_ras_idle_by[RI_SHADE]   + 1;
                        else                                        pc_ras_idle_by[RI_OTHER]   <= pc_ras_idle_by[RI_OTHER]   + 1;
                    end
                end
            end
`endif
            done<=0; ra_start<=0; ol_start<=0;
            spv_start<=1'b0; spv_rd_done<=1'b0;  // 1-cyc spanner start / ring-free strobes
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            eq_push = 1'b0;
            col_post<=1'b0;                   // 1-cyc: color-buffer post-to-VO intent
            // fbw_req is driven COMBINATIONALLY by the decoupled VO engine.

            // ============ streamed rasterizer CONSUMER: stage A -> stage B ============
            // Stage A (ras_out_valid): the combinational peel-RAM read of chunk
            // {ras_oy,ras_ox} is already presented; latch the result fields for the
            // compare next cycle. Stage B (b_valid): the combinational RAM block runs
            // the depth compare off pr_rdata and writes the passing lanes back to the
            // peel RAM. Here in stage B we also write the dt_pt REG (kept out of the
            // RAM) and accumulate more_to_draw (moved off the old combinational path).
            b_valid <= 1'b0;
`ifndef SYNTHESIS
            if ($test$plusargs("coaltrace") && b_valid && (|b_we))
                $display("[WRITE] htile=%b tile(%0d,%0d) y=%0d x=%0d tag=%08x", htile, cur_tx, cur_ty, b_oy, b_ox, b_tag);
            if ($test$plusargs("coaltrace") && spv_start)
                $display("[START] tsp_tag=%b spn tile(%0d,%0d) shade_mode(~ti)=%b ti_ready=%b", tsp_tag, ti_tx[tsp_tag], ti_ty[tsp_tag], ~ti_mode[tsp_tag], ti_ready);
            // +passtrace: log every shade handoff START (tile, OP/PEEL mode, last, postonly)
            if ($test$plusargs("passtrace") && spv_start)
                $display("[PASS] tile(%0d,%0d) mode=%s last=%b postonly=%b",
                         ti_tx[tsp_tag], ti_ty[tsp_tag],
                         ti_mode[tsp_tag] ? "PEEL" : "OP  ",
                         ti_last[tsp_tag], ti_postonly[tsp_tag]);
`endif
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
                b_which  <= tri_is_pt;   // per-triangle list-kind (threaded via fq/pq), NOT the
                                         // live peel_which reg -> safe when PT+TL coexist in-flight
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
`ifndef SYNTHESIS
            // +blendtrace: at CB, log the dst (col_rd_argb) the blend reads for pixel 327/328
            // in tile(7,4). Reveals if a layer reads a STALE/wrong dst (composite divergence).
            if ($test$plusargs("blendtrace") && cb_valid && md_tx[md_rp[MD_AW-1:0]]==7
                && md_ty[md_rp[MD_AW-1:0]]==4
                && (cb_id==10'd327 || cb_id==10'd328))
                $display("[BLENDCB] tile(7,4) id=%0d dst=%08x src=%08x tsp=%08x",
                         cb_id, col_rd_argb, cb_argb, cb_tsp);
`endif
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
                // +blendtrace: log the blend of the suspect pixel (tile(7,4), local id 328 = px8
                // py10). Shows the source color this layer produced (dst it reads is next cyc).
                if ($test$plusargs("blendtrace") && md_tx[md_rp[MD_AW-1:0]]==7
                    && md_ty[md_rp[MD_AW-1:0]]==4
                    && (pp_out_id[9:0]==10'd327 || pp_out_id[9:0]==10'd328))
                    $display("[BLEND] tile(7,4) id=%0d src=%08x tsp=%08x at=%b md_rp=%0d col_prod=%b",
                             pp_out_id[9:0], pp_out_argb, pp_out_tsp, pp_out_id[10], md_rp[MD_AW-1:0], tsp_col);
`endif
            end
`ifndef SYNTHESIS
            if (sp_we) pc_swrite <= pc_swrite + 1;   // spans written to the dense buffer
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
                    // pending ISP->spanner (ti_ready) or spanner->reader (md FIFO not
                    // empty), no in-flight color POST intent (col_post is a 1-cyc pulse
                    // that sets col_full NEXT cycle - must not race the gate), and VO
                    // idle with no pending u_col halves. Missing !col_post here dropped
                    // the FINAL tile's writeout (last-tile-black bug).
                    if (spn==G_IDLE && !spv_busy && tsp_st==R_IDLE &&
                        ti_ready==2'b00 && md_empty &&
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
                if (ol_done) begin
                    // PT->TL MERGE: within a peel pass, chain the TL list DIRECTLY onto the PT
                    // list (no S_DRAIN between) - both stream into eq/iterator/setup/pq back-to-
                    // back and raster in FIFO order (PT before TL), each triangle carrying its
                    // own is_pt bit (eq_ispt). This removes one full raster-drain barrier per
                    // pass. Only the end of the TL list (or a non-peel list) hits S_DRAIN.
                    if (peeling && peel_which==1'b0 && has_tr) begin
                        peel_which  <= 1'b1;             // now queuing the TL list
                        ol_list_ptr <= tr_ptr_l; ol_start <= 1'b1;
                        // stay in S_OL_RUN; the TL entries push behind the PT entries in eq
`ifndef SYNTHESIS
                        if ($test$plusargs("mergetrace")) $display("[PT->TL MERGE] tile(%0d,%0d) has_pt=%b has_tr=%b", cur_tx, cur_ty, has_pt, has_tr);
`endif
                    end else begin
`ifndef SYNTHESIS
                        if ($test$plusargs("mergetrace") && peeling) $display("[S_DRAIN peel] tile(%0d,%0d) peel_which=%b has_pt=%b has_tr=%b", cur_tx, cur_ty, peel_which, has_pt, has_tr);
`endif
                        st <= S_DRAIN;
                    end
                end
                else if (ol_prim.entry_ready && !ol_ack.entry_done) begin
                    if (ol_prim.entry_type == ENT_STRIP ||
                        ol_prim.entry_type == ENT_TRI) begin
                        if (!eq_full) begin
                            eq_etype[eq_tail[2:0]] <= ol_prim.entry_type;
                            eq_entry[eq_tail[2:0]] <= ol_prim.entry;
                            eq_ispt [eq_tail[2:0]] <= (peel_which==1'b0);  // list-kind tag
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
                    // Both the PT and TL lists of this pass have already been rastered into
                    // the same u_taginvw[htile]/u_peel (the PT->TL chain in S_OL_RUN streamed
                    // them back-to-back with no barrier between). This single barrier ensures
                    // raster fully drained before the NEXT pass's PeelBuffers walks u_peel.
                    begin
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
                // WHY is raster IDLE? Partition RS_IDLE by top `st`. %% is of the IDLE total.
                // SHADE = overlapped (good: raster done, spanner/reader still shading); the
                // rest is serial ISP overhead with no downstream running.
                $display("     IDLE by phase: CLEAR=%0d(%0d%%) PEELBUF=%0d(%0d%%) OL=%0d(%0d%%) BARRIER=%0d(%0d%%) SHWAIT=%0d(%0d%%) SHADE-overlap=%0d(%0d%%) OTHER=%0d(%0d%%)",
                    pc_ras_idle_by[RI_CLEAR],   (pc_ras_idle_by[RI_CLEAR]*100)  /(pc_ras_idle?pc_ras_idle:1),
                    pc_ras_idle_by[RI_PEELBUF], (pc_ras_idle_by[RI_PEELBUF]*100)/(pc_ras_idle?pc_ras_idle:1),
                    pc_ras_idle_by[RI_OL],      (pc_ras_idle_by[RI_OL]*100)     /(pc_ras_idle?pc_ras_idle:1),
                    pc_ras_idle_by[RI_BARRIER], (pc_ras_idle_by[RI_BARRIER]*100)/(pc_ras_idle?pc_ras_idle:1),
                    pc_ras_idle_by[RI_SHWAIT],  (pc_ras_idle_by[RI_SHWAIT]*100) /(pc_ras_idle?pc_ras_idle:1),
                    pc_ras_idle_by[RI_SHADE],   (pc_ras_idle_by[RI_SHADE]*100)  /(pc_ras_idle?pc_ras_idle:1),
                    pc_ras_idle_by[RI_OTHER],   (pc_ras_idle_by[RI_OTHER]*100)  /(pc_ras_idle?pc_ras_idle:1));
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
                // ISP-ALONE (occ==I) breakdown: where the non-overlapped ISP time goes. %% is
                // of the ISP-alone total (pc_occ[4]), so the buckets sum to ~100%%.
                $display("     ISP-ALONE=%0d (%0d%% of total): CLEAR=%0d(%0d%%) PEELBUF=%0d(%0d%%) OL=%0d(%0d%%) BARRIER=%0d(%0d%%) SHWAIT=%0d(%0d%%) SETUP/RAS=%0d(%0d%%) OTHER=%0d",
                    pc_occ[4], (pc_occ[4]*100)/(pc_total?pc_total:1),
                    pc_isp_alone[IA_CLEAR],   (pc_isp_alone[IA_CLEAR]*100)  /(pc_occ[4]?pc_occ[4]:1),
                    pc_isp_alone[IA_PEELBUF], (pc_isp_alone[IA_PEELBUF]*100)/(pc_occ[4]?pc_occ[4]:1),
                    pc_isp_alone[IA_OL],      (pc_isp_alone[IA_OL]*100)     /(pc_occ[4]?pc_occ[4]:1),
                    pc_isp_alone[IA_BARRIER], (pc_isp_alone[IA_BARRIER]*100)/(pc_occ[4]?pc_occ[4]:1),
                    pc_isp_alone[IA_SHWAIT],  (pc_isp_alone[IA_SHWAIT]*100) /(pc_occ[4]?pc_occ[4]:1),
                    pc_isp_alone[IA_SETUP],   (pc_isp_alone[IA_SETUP]*100)  /(pc_occ[4]?pc_occ[4]:1),
                    pc_isp_alone[IA_OTHER]);
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

            // ================= SPANNER_v2 GLUE FSM (spn) =================
            // Runs every cycle alongside `st`/`rs_st`/the TSP reader. Starts spanner_v2 on a
            // ready CONSUMER input half, waits its busy->0 (all spans emitted + all setups
            // written into the shared ring), then hands the span_buffer_v2 half to the reader
            // and frees the input half. Post-only tiles (OP FLUSH) skip the spanner run.
            case (spn)
            G_IDLE: if (ti_ready[tsp_tag] && !md_full) begin
                if (ti_postonly[tsp_tag]) begin
                    // OP-only tile FLUSH: no shade; PUSH a post-only descriptor to the reader
                    // (color already accumulated in u_col). No spanner run, no ring range
                    // (md_cnt=0, md_post=1 -> reader goes straight to R_POST, no ring free).
                    md_base[md_wp[MD_AW-1:0]] <= '0;
                    md_cnt [md_wp[MD_AW-1:0]] <= '0;
                    md_post[md_wp[MD_AW-1:0]] <= 1'b1;
                    md_last[md_wp[MD_AW-1:0]] <= 1'b1;         // post-only implies last
                    md_tx  [md_wp[MD_AW-1:0]] <= ti_tx[tsp_tag];
                    md_ty  [md_wp[MD_AW-1:0]] <= ti_ty[tsp_tag];
                    md_wp <= md_wp + 1'b1;
                    ti_ready[tsp_tag]  <= 1'b0;
                    tsp_tag  <= ~tsp_tag;
`ifndef SYNTHESIS
                    pc_span <= pc_span + 1;
                    md_cnt_dbg[md_wp[MD_AW-1:0]] <= '0;  // post-only: 0 spans (never R_DRAIN-subtracted)
`endif
                end else begin
                    // Latch the spanner's OWN tile origin (it runs behind ISP) + shade mode,
                    // and pulse start. tsp_tag stays put during the run (the 4-wide read and
                    // the span write both reference it).
                    spn_tx <= ti_tx[tsp_tag]; spn_ty <= ti_ty[tsp_tag];
                    spn_xbase <= i2f({4'd0, ti_tx[tsp_tag]} * 16'd32);
                    spn_ybase <= i2f({4'd0, ti_ty[tsp_tag]} * 16'd32);
                    // POLARITY: peel_core ti_mode is 0=OP,1=PEEL; spanner_v2 shade_mode is
                    // 1=OP(shade all),0=PEEL(gate on ti_valid) -> INVERT.
                    spv_shade_mode <= ~ti_mode[tsp_tag];
                    spv_start <= 1'b1;
                    spn <= G_START;
`ifndef SYNTHESIS
                    // TSP lag at pass START: passes already handed but not yet drained (md
                    // FIFO occupancy = md_wp - md_rp; nothing pushed yet this pass).
                    if ($test$plusargs("tsplag"))
                        $display("[SPN-START] tile(%0d,%0d) mode=%s TSP is %0d pass(es) / %0d span(s) behind (max %0d passes, tsp_st=%0d)",
                                 ti_tx[tsp_tag], ti_ty[tsp_tag], ti_mode[tsp_tag]?"PEEL":"OP  ",
                                 md_wp - md_rp, spans_inflight, MD_N, tsp_st);
`endif
                end
            end

            // wait for the start to be accepted (busy rises 1 cycle after start).
            G_START: if (spv_busy) spn <= G_RUN;

            // spanner running: hand off when done (!spv_busy: SPANGEN drained + all setups
            // written + all spans written to the ring). PUSH a descriptor carrying this pass's
            // span RING RANGE {base, cnt} so the reader knows where/how many slots to walk.
            G_RUN: if (!spv_busy) begin
`ifndef SYNTHESIS
                if ($test$plusargs("passtrace"))
                    $display("[SPN->] tile(%0d,%0d) mode=%s base=%0d cnt=%0d",
                             ti_tx[tsp_tag], ti_ty[tsp_tag], ti_mode[tsp_tag]?"PEEL":"OP  ",
                             spv_sp_range_base[SPAN_AW-1:0], spv_sp_range_cnt);
                // TSP lag: passes handed to the reader but not yet drained (md FIFO occupancy).
                // AFTER this push it is (md_wp+1 - md_rp); reader idle => 0 behind. Max = MD_N.
                if ($test$plusargs("tsplag"))
                    // spans_inflight is maintained as a running counter (added on push here,
                    // subtracted when the reader frees a pass) - timing-clean, no stale-slot sum.
                    // +spv_sp_range_cnt: this pass's spans (its md_cnt NBA lands next cycle).
                    $display("[SPN-END] tile(%0d,%0d) TSP is %0d pass(es) / %0d span(s) behind (max %0d passes, tsp_st=%0d)",
                             ti_tx[tsp_tag], ti_ty[tsp_tag],
                             (md_wp + 1'b1) - md_rp,
                             spans_inflight + {{(32-(SPAN_AW+1)){1'b0}}, spv_sp_range_cnt},
                             MD_N, tsp_st);
`endif
                md_base[md_wp[MD_AW-1:0]] <= spv_sp_range_base[SPAN_AW-1:0]; // ring base slot
                md_cnt [md_wp[MD_AW-1:0]] <= spv_sp_range_cnt;               // # spans (0=empty)
                md_post[md_wp[MD_AW-1:0]] <= 1'b0;
                md_last[md_wp[MD_AW-1:0]] <= ti_last[tsp_tag];
                md_tx  [md_wp[MD_AW-1:0]] <= ti_tx  [tsp_tag];
                md_ty  [md_wp[MD_AW-1:0]] <= ti_ty  [tsp_tag];
                md_wp <= md_wp + 1'b1;
                ti_ready[tsp_tag]  <= 1'b0;         // free the input half for ISP
                tsp_tag  <= ~tsp_tag;
`ifndef SYNTHESIS
                pc_span <= pc_span + 1;
                // running "spans behind" counter: this pass adds its span count. Record the
                // count per-slot so R_DRAIN subtracts the exact same value when it frees.
                spans_inflight <= spans_inflight + {{(32-(SPAN_AW+1)){1'b0}}, spv_sp_range_cnt};
                md_cnt_dbg[md_wp[MD_AW-1:0]] <= spv_sp_range_cnt;
`endif
                spn <= G_IDLE;
            end
            default: spn <= G_IDLE;
            endcase

            // ================= CONCURRENT TSP READER FSM (tsp_st) =================
            // Dense drain of span_buffer_v2[tsp_rd] -> triangle_setups[id] -> tsp_shade_v2_pp,
            // 1 px/clk. Two registered-read stages: S1 = span buffer, S2 = setups ring. S2
            // feeds the shader (combi pp mux). The whole pipe holds on pp_stall. On sb_last it
            // posts the finished tile's color (u_col[tsp_col]) to VO.
            case (tsp_st)
            // pick the next READY span half (in order via tsp_rd). Post-only -> post now.
            // Empty pass (no spans) -> nothing to shade: go straight to DRAIN/POST.
            // A shading pass blends into col_prod=tsp_col; don't start until VO has FREED that
            // half (!col_full[tsp_col]). The dense reader shades far faster than the old per-
            // pixel walk, so without this it laps the VO engine and blends into a half VO is
            // still flushing (col_prod==col_vo read conflict). (An empty pass does no blend,
            // so it doesn't need the gate; post-only takes R_POST which has its own gate.)
            R_IDLE: if (!md_empty && (md_post[md_rp[MD_AW-1:0]] || md_cnt[md_rp[MD_AW-1:0]]=='0
                                      || !col_full[tsp_col])) begin
                if (md_post[md_rp[MD_AW-1:0]]) begin
                    tsp_st <= R_POST;
                end else if (md_cnt[md_rp[MD_AW-1:0]] == '0) begin
                    // 0 spans: no shade work. Skip to DRAIN (frees ring range; posts if last).
                    sh_out_n <= 0; sh_pending <= 0;
                    rd_live <= 1'b0; sb_rd_pend <= 1'b0; span_more <= 1'b0; span_left <= '0;
                    ns_v <= 1'b0; cs_v <= 1'b0; s2_v <= 1'b0;
                    tsp_st <= R_DRAIN;
                end else begin
`ifndef SYNTHESIS
                    if ($test$plusargs("passtrace"))
                        $display("[->RD] tile(%0d,%0d) base=%0d cnt=%0d",
                                 md_tx[md_rp[MD_AW-1:0]], md_ty[md_rp[MD_AW-1:0]],
                                 md_base[md_rp[MD_AW-1:0]], md_cnt[md_rp[MD_AW-1:0]]);
`endif
                    // Prime the READ stage at this pass's ring BASE. dsr_addr=span_ptr is held
                    // stable, so the base slot's registered read resolves next cycle. span_left =
                    // spans not yet consumed (incl the in-flight one); span_more = >1 remaining.
                    span_ptr   <= md_base[md_rp[MD_AW-1:0]];      // in-flight slot = pass base
                    span_left  <= md_cnt [md_rp[MD_AW-1:0]];      // spans remaining
                    rd_live    <= 1'b1;                           // base read outstanding
                    sb_rd_pend <= 1'b0;                           // base read resolves NEXT cyc
                    span_more  <= (md_cnt[md_rp[MD_AW-1:0]] > 1); // slots after the base one?
                    ns_v <= 1'b0; cs_v <= 1'b0; s2_v <= 1'b0; cs_k <= 3'd0;
                    sh_out_n <= 0; sh_pending <= 0;
                    tsp_st   <= R_RUN;
                end
            end

            // DENSE span walk + expand - THREE decoupled stages advancing each !pp_stall cycle.
            // A 1-deep skid (+ a bypass) decouples the fixed 1-cycle dense-read latency from the
            // VARIABLE 1..4-cycle expand, so every slot is consumed EXACTLY ONCE, in order, with
            // no skip and no double-read. Steady state (rep>=2 spans) is bubble-free: the read
            // runs ahead into the skid while the current span expands. A lone rep-1 span can
            // cost a single bubble cycle (its 1-cycle expand can't hide the next slot's read),
            // which is harmless.
            //  A) READ  : dsr_addr=span_ptr = the IN-FLIGHT slot, held stable until consumed;
            //             its registered read lands next cycle. span_ptr advances (to the next
            //             slot within [0..sb_span_last]) only when the in-flight read is consumed
            //             (consume_read); sb_rd_pend = the held slot's read has resolved on dsr_*.
            //  B) SKID  : ns_* holds one prefetched span; filled from dsr_* (fill) when the read
            //             resolved and the skid is empty/draining and it wasn't bypassed.
            //  C) EXPAND: emit cs_*[cs_k] -> s2_* -> pp; cs_k walks 0..rep-1. On span finish,
            //             accept the next span from the SKID, or BYPASS straight off dsr_* when
            //             the skid is empty but a read resolved this cycle. rep==0 (unwritten
            //             slot) is guarded - never expanded (cs_rep-1 would underflow to 7).
            R_RUN: if (!pp_stall) begin
                // ---- local decisions (all declared first; SV: decls precede statements) ----
                reg        span_done, accept, fill, dsr_rdy, src_v, consume_read;
                reg [9:0]  src_start, src_id;
                reg [2:0]  src_rep;
                reg        src_at;
                reg [31:0] src_invw [0:3];
                integer    si;
                // current expand span finishes this cycle (or none in flight)
                span_done = !cs_v || (cs_k == cs_rep - 3'd1);
                // a slot read resolved on dsr_* this cycle
                dsr_rdy   = sb_rd_pend;
                // The next span to feed EXPAND comes from the SKID (ns_*) if full, else a
                // BYPASS directly off dsr_* when a read resolved this cycle (bubble-free 1-deep
                // skid). src_* selects between them.
                src_v = ns_v || dsr_rdy;
                if (ns_v) begin
                    src_start = ns_start; src_id = ns_id; src_rep = ns_rep; src_at = ns_at;
                    for (si=0; si<4; si=si+1) src_invw[si] = ns_invw[si];
                end else begin  // bypass from dsr_* (shared ring, no half index)
                    src_start = dsr_start; src_id = dsr_id;
                    src_rep = dsr_rep; src_at = dsr_at;
                    for (si=0; si<4; si=si+1) src_invw[si] = dsr_invw[si];
                end
                // accept a span into EXPAND when the current one finishes and a src is available.
                accept = span_done && src_v;
                // the in-flight dsr_* read is CONSUMED this cycle iff it resolved AND either the
                // skid can take it (empty now, or drained by accept) OR it was BYPASSED straight
                // into EXPAND (accept while skid empty). This is what advances the read pointer.
                consume_read = dsr_rdy && (!ns_v || accept);
                // it goes into the SKID (fill) unless it was bypassed into EXPAND this cycle.
                fill   = consume_read && !(accept && !ns_v);

                // --- Stage C: emit the pixel the current cs points at (this cycle's cs/k) ---
                if (cs_v) begin
                    s2_v    <= 1'b1;
                    s2_p    <= cs_start + {7'd0, cs_k};
                    s2_invw <= cs_invw[cs_k];
                    s2_at   <= cs_at;
                    s2_id   <= cs_id;
                    sh_pending <= sh_pending + 1;
                    if (!span_done) cs_k <= cs_k + 3'd1;   // mid-span: next pixel
                end else s2_v <= 1'b0;

                // --- EXPAND accept: feed the next span (skid or bypass) into cs_* on finish. ---
                if (span_done) begin
                    if (src_v) begin
`ifndef SYNTHESIS
                        // +rdslot: log EVERY span accepted into EXPAND (skid or bypass) for
                        // tile(7,4) covering pixels 324..331, so all passes (incl. bypass) show.
                        if ($test$plusargs("rdslot") && md_tx[md_rp[MD_AW-1:0]]==7
                            && md_ty[md_rp[MD_AW-1:0]]==4
                            && src_start >= 10'd324 && src_start <= 10'd328)
                            $display("[RDACC] tile(7,4) start=%0d id=%0d rep=%0d invw0=%08x via=%s",
                                     src_start, src_id, src_rep, src_invw[0], ns_v ? "skid" : "bypass");
`endif
                        // guard rep==0 (never expand a would-be empty slot).
                        cs_v     <= (src_rep != 3'd0);
                        cs_k     <= 3'd0;
                        cs_start <= src_start;
                        cs_id    <= src_id;
                        cs_rep   <= src_rep;
                        cs_at    <= src_at;
                        for (pj2 = 0; pj2 < 4; pj2 = pj2 + 1) cs_invw[pj2] <= src_invw[pj2];
                    end else begin
                        cs_v <= 1'b0;   // nothing available: EXPAND idles
                    end
                end

                // --- Stage B skid update ---
                if (fill) begin
`ifndef SYNTHESIS
                    // +rdslot: log every accepted dense span for tile(7,4) whose run covers the
                    // suspect pixel (local px8 py10 => start 10*32+8=328, or a span containing it).
                    if ($test$plusargs("rdslot") && md_tx[md_rp[MD_AW-1:0]]==7
                        && md_ty[md_rp[MD_AW-1:0]]==4)
                        $display("[RDSLOT] tile(7,4) sp=%0d start=%0d id=%0d rep=%0d invw0=%08x bypass=%b",
                                 span_ptr, dsr_start, dsr_id, dsr_rep,
                                 dsr_invw[0], (accept && !ns_v));
`endif
                    ns_v     <= 1'b1;                    // in-flight read -> skid
                    ns_start <= dsr_start;
                    ns_id    <= dsr_id;
                    ns_rep   <= dsr_rep;
                    ns_at    <= dsr_at;
                    for (pj2 = 0; pj2 < 4; pj2 = pj2 + 1) ns_invw[pj2] <= dsr_invw[pj2];
                end else if (accept && ns_v) begin
                    ns_v <= 1'b0;       // skid drained into EXPAND, nothing new -> empty
                end

                // --- Stage A read pointer / pend tracking ---
                // dsr_addr = span_ptr is held stable, so the in-flight slot's registered read
                // stays valid on dsr_* until CONSUMED into the skid (fill). On fill, advance
                // span_ptr to the next RING slot (if any); its read then needs one cycle to
                // resolve, so sb_rd_pend drops for that one cycle. WRAP-SAFE: last/more are
                // derived from span_left (spans remaining, incl the in-flight one), NEVER from a
                // pointer-equality against a wrapped end pointer. span_ptr wraps at SPAN_NSLOT
                // (power-of-two) by width. This is the one-read-in-flight invariant.
                if (consume_read) begin
                    // the in-flight read (span_ptr) was taken (into skid or bypassed to EXPAND).
                    span_left <= span_left - 1'b1;              // one span consumed
                    if (span_more) begin                        // (span_left > 1 at prime/advance)
                        span_ptr   <= span_ptr + 1'b1;          // advance (wraps within the ring)
                        span_more  <= (span_left > 2);          // >1 will remain AFTER this consume
                        sb_rd_pend <= 1'b0;                     // new slot resolves NEXT cycle
                        // rd_live stays 1: a new read is now outstanding.
                    end else begin
                        // last slot consumed - no more reads outstanding. sb_rd_pend/rd_live
                        // both clear and STAY clear so the drain detect can fire.
                        sb_rd_pend <= 1'b0;
                        rd_live    <= 1'b0;
                    end
                end else if (rd_live) begin
                    // a read is outstanding and NOT consumed this cycle: it has resolved on dsr_*
                    // (1 cycle after issue) -> mark valid. (Held stable until consumed.)
                    sb_rd_pend <= 1'b1;
                end
                // else (!consume_read && !rd_live): reads exhausted - hold sb_rd_pend=0.

                // --- drain detect: no read outstanding, skid empty, expand + Stage C idle ---
                if (!rd_live && !ns_v && span_done && !cs_v && !s2_v)
                    tsp_st <= R_DRAIN;
            end
            // else pp_stall: hold the whole pipeline (addresses re-presented by the combi mux).

            // wait for the shade+blend pipe to drain (all fed pixels emerged and the trailing
            // blend RMW landed). Free this pass's span+plane ring range; pop the descriptor
            // (unless heading to R_POST, which still needs md_tx/ty/post -> it pops instead).
            // If this was the tile's FINAL shade (md_last) hand u_col to VO (R_POST).
            R_DRAIN: if (sh_out_n >= sh_pending && !cb_valid) begin
                spv_rd_done      <= 1'b1;        // free this pass's ring range (real pass)
`ifndef SYNTHESIS
                pc_drain <= pc_drain + 1;
                // running "spans behind": this pass's spans leave the queue now (ring freed).
                spans_inflight <= spans_inflight - {{(32-(SPAN_AW+1)){1'b0}}, md_cnt_dbg[md_rp[MD_AW-1:0]]};
`endif
                if (md_last[md_rp[MD_AW-1:0]]) tsp_st <= R_POST;  // pop happens in R_POST
                else begin
                    md_rp  <= md_rp + 1'b1;      // pop this pass's descriptor
                    tsp_st <= R_IDLE;
                end
            end

            // POST the finished tile's color (u_col[tsp_col]) to the VO engine via the u_col
            // ping-pong credit. Post-only descriptors reach here without R_DRAIN (no ring range
            // -> no spv_rd_done); pop the descriptor here too.
            R_POST: if (!col_full[tsp_col]) begin
                col_post    <= 1'b1;
                col_post_hp <= tsp_col;
                col_post_tx <= md_tx[md_rp[MD_AW-1:0]];
                col_post_ty <= md_ty[md_rp[MD_AW-1:0]];
                tsp_col <= ~tsp_col;             // next tile -> other u_col half
`ifndef SYNTHESIS
                if (md_post[md_rp[MD_AW-1:0]]) pc_drain <= pc_drain + 1;  // post-only: not via R_DRAIN
`endif
                md_rp  <= md_rp + 1'b1;          // pop this pass's descriptor
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
                tri_is_pt<=pq_rdw[QF_PT];
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

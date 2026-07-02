//
// isp_core - ISP-only render core (no TSP), DDR read + framebuffer write injected.
//
// This is the frontendisp path (region -> objlist -> primitive iterator ->
// isp_setup_min -> isp_raster_line -> isp_depth_cmp -> {invW, CoreTag} write)
// packaged as a synthesizable core with its dependencies injected as ports, in
// the SAME style as peel_core:
//   * a single shared 64-bit DDR READ channel (ddr_req/ddr_resp) below a
//     fixed-priority arbiter over the three read clients (region/objlist/param),
//   * a framebuffer WRITE channel (fbw_req/fbw_resp): one 32-bit value per pixel.
//
// There is NO texture memory, NO shading, and NO colour buffer. The value written
// to the framebuffer per pixel is the raw 32-bit CoreTag left in the tag buffer by
// the ISP depth/tag pass (the classic "tag visualisation" of the deferred tile) -
// exactly what frontend_isp_tb flushed into its fb[] and rendered to output.bmp.
//
// mister_top_isp injects the real HPS Avalon backend; a sim wrapper can inject a
// faux behavioral DDR + fb.
//
module isp_core import tsp_pkg::*; (
    input             clk,
    input             reset,
    // register write path (HPS / C++ TB loads the PVR reg dump before go)
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    input             go,             // 1-cycle: start rendering the region array
    output reg        done,           // 1-cycle: region array fully processed

    // ---- injected DDR read controller (single 64-bit channel below the arbiter) ----
    output ddr_rd_req_t  ddr_req,
    input  ddr_rd_resp_t ddr_resp,

    // ---- injected framebuffer write (one 32-bit CoreTag per pixel) ----
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
    // Three read clients - region parser (via its 256-bit line cache), object-list
    // parser (direct burst), primitive iterator (direct burst) - arbitrated onto
    // the injected single 64-bit DDR read channel (ddr_req/ddr_resp).
    //
    // Client indices (fixed priority, lowest = highest priority):
    //   0 = param (pr, latency-critical during raster feed)
    //   1 = objlist (ol)
    //   2 = region (ra, direct DDR)
    localparam integer NCLI = 3;
    ddr_rd_req_t  cli_req  [0:NCLI-1];
    ddr_rd_resp_t cli_resp [0:NCLI-1];

    // per-client pending latch (a request captured, awaiting/holding the channel)
    reg        pend [0:NCLI-1];
    reg [28:0] pa   [0:NCLI-1];   // latched word address (full 29-bit DDR addr)
    reg [7:0]  pb   [0:NCLI-1];   // latched burst length
    wire       rd_pulse [0:NCLI-1];
    wire [28:0] ca [0:NCLI-1];
    wire [7:0]  cbv[0:NCLI-1];
    genvar gc;
    generate
        for (gc = 0; gc < NCLI; gc = gc + 1) begin : cli_wires
            assign rd_pulse[gc] = cli_req[gc].rd && !pend[gc];
            assign ca[gc]       = cli_req[gc].addr;
            assign cbv[gc]      = cli_req[gc].burst;
        end
    endgenerate

    // fixed-priority winner among pending clients
    wire [1:0] d_win = pend[0] ? 2'd0 : pend[1] ? 2'd1 : 2'd2;

    reg        d_busy; reg [1:0] d_owner;
    reg [7:0]  d_beats;
    reg        d_issued;

    assign ddr_req.rd    = d_busy && !d_issued;
    assign ddr_req.addr  = pa[d_owner];
    assign ddr_req.burst = d_beats;

    integer di;
    always @(posedge clk) begin
        if (reset) begin
            d_busy <= 1'b0; d_issued <= 1'b0; d_beats <= 8'd0; d_owner <= 2'd0;
            for (di = 0; di < NCLI; di = di + 1) pend[di] <= 1'b0;
        end else begin
            // capture new requests into the per-client pending latch
            for (di = 0; di < NCLI; di = di + 1)
                if (rd_pulse[di]) begin pend[di] <= 1'b1; pa[di] <= ca[di]; pb[di] <= cbv[di]; end

            if (!d_busy) begin
                if (pend[0] || pend[1] || pend[2]) begin
                    d_busy   <= 1'b1; d_owner <= d_win;
                    d_beats  <= pb[d_win];
                    d_issued <= 1'b0;
                    pend[d_win] <= (rd_pulse[d_win]);  // clear grant (unless re-pulsed same cyc)
                end
            end else begin
                // hold ddr_req.rd until the controller accepts it
                if (ddr_req.rd && !ddr_resp.busy) d_issued <= 1'b1;
                if (ddr_resp.dready) begin
                    if (d_beats <= 8'd1) begin d_busy <= 1'b0; d_issued <= 1'b0; end
                    d_beats <= d_beats - 8'd1;
                end
            end
        end
    end

    // client-facing responses: busy while the channel is granted to someone else or
    // this client's request is latched-but-not-serviced; dready gated by ownership.
    generate
        for (gc = 0; gc < NCLI; gc = gc + 1) begin : cli_resp_w
            assign cli_resp[gc].busy   = d_busy || pend[gc];
            assign cli_resp[gc].dout   = ddr_resp.dout;
            assign cli_resp[gc].dready = ddr_resp.dready && (d_owner == gc[1:0]);
        end
    endgenerate

    // named handles onto the arbiter clients
    ddr_rd_req_t  pr_dreq; ddr_rd_resp_t pr_dresp;   // param
    ddr_rd_req_t  ol_dreq; ddr_rd_resp_t ol_dresp;   // objlist
    ddr_rd_req_t  ra_dreq; ddr_rd_resp_t ra_dresp;   // region (direct DDR)
    assign cli_req[0] = pr_dreq; assign pr_dresp = cli_resp[0];
    assign cli_req[1] = ol_dreq; assign ol_dresp = cli_resp[1];
    assign cli_req[2] = ra_dreq; assign ra_dresp = cli_resp[2];

    // -------------------- parsers --------------------
    // All three readers (region / objlist / iterator) read DDR DIRECTLY via their
    // own 8-word sliding-window line reader (no data_cache256).
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

    // -------------------- depth/tag tile (M10K-backed) --------------------
    // 32x32 tile, 8 banks (one per raster lane): bank = x[2:0], addr = {y,x[4:3]}
    // (7 bits, 128 entries/bank). Each entry packs {depth[31:0], tag[31:0]} = 64b,
    // so a whole 8-lane chunk is one addr across the 8 banks. Registered read
    // (1-cycle latency) => the depth compare is pipelined one stage (see consumer).
    localparam integer TILE_W = 32, TILE_H = 32;
    localparam integer TR_W = 64;              // {depth, tag} per lane
    localparam integer NB   = RAS_LANES;       // 8 banks

    // tile_ram controls are COMBINATIONAL (driven from pipeline/FSM state) so the
    // RAM's internal registered read gives exactly 1-cycle latency: address valid
    // in cycle N -> rdata valid N+1. (Registering these here would add an extra
    // cycle of skew and the compare would read the WRONG chunk.)
    reg  [NB-1:0]        tr_we;
    reg  [7*NB-1:0]      tr_waddr;   // stage-B write-back address
    reg  [7*NB-1:0]      tr_raddr;   // stage-A / CLEAR / FLUSH read address
    reg  [TR_W*NB-1:0]   tr_wdata;
    wire [TR_W*NB-1:0]   tr_rdata;

    // Simple-dual-port: stage-A reads chunk N while stage-B writes chunk N-1 in
    // the SAME cycle -> the streaming rasterizer keeps 8 pixels/clock.
    tile_ram #(.WIDTH(TR_W), .NBANKS(NB)) u_tile (
        .clk(clk), .we(tr_we), .waddr(tr_waddr), .wdata(tr_wdata),
        .raddr(tr_raddr), .rdata(tr_rdata)
    );

    // pack a 7-bit bank address {y[4:0], x[4:3]} for all 8 banks (same addr/bank)
    function automatic [7*NB-1:0] tr_pack_addr(input [4:0] y, input [4:0] xchunk);
        integer b;
        begin
            tr_pack_addr = '0;
            for (b = 0; b < NB; b = b + 1)
                tr_pack_addr[7*b +: 7] = {y, xchunk[4:3]};
        end
    endfunction

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

    // -------------------- ISP triangle setup --------------------
    reg         isp_start;
    reg  [31:0] isp_word;                 // active (raster) triangle's isp
    reg  [31:0] isp_word_su;              // setup (next) triangle's isp
    reg  [31:0] t_x1,t_y1,t_z1, t_x2,t_y2,t_z2, t_x3,t_y3,t_z3;
    reg  [31:0] t_xbase, t_ybase;
    reg  [31:0] su_tag;                   // setup triangle's CoreTag
    reg  [31:0] tri_tag;                  // active (raster) triangle's CoreTag
    wire        isp_done, isp_sgn_neg, isp_cull;
    wire [4:0]  w_bx0, w_bx1, w_by0, w_by1;
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

    reg [31:0] isp_dx12,isp_dx23,isp_dx31,isp_dx41;
    reg [31:0] isp_dy12,isp_dy23,isp_dy31,isp_dy41;
    reg [31:0] isp_c1,isp_c2,isp_c3,isp_c4;
    reg [31:0] isp_ddx_invw, isp_ddy_invw, isp_c_invw;

    // -------------------- ISP rasterize --------------------
    localparam integer RAS_LANES = 8;
    reg  [4:0]  ras_y, ras_x;
    reg  [4:0]  rbx0, rbx1, rby1;
    wire        ras_in_valid = (rs_st == RS_RAS);
    wire        ras_out_valid;
    wire [RAS_LANES-1:0]    ras_inside;
    wire [32*RAS_LANES-1:0] ras_invw_flat;
    function [31:0] ras_invw(input integer lane);
        ras_invw = ras_invw_flat[32*lane +: 32];
    endfunction

    wire [4:0] ras_ox, ras_oy;
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

    // ---- consumer stage A -> B pipeline registers (see always block) ----
    // Stage A latches the raster result and issues the tile_ram read; stage B
    // (next cycle) receives tr_rdata (old depth/tag chunk), runs the compares and
    // writes back. b_* are the stage-B copies of the stage-A result fields.
    reg                  b_valid;
    reg [RAS_LANES-1:0]  b_inside;
    reg [32*RAS_LANES-1:0] b_invw;
    reg [4:0]            b_ox, b_oy;
    reg [31:0]           b_tag;
    reg [2:0]            b_mode;
    reg                  b_zwdis;

    // old depth per lane comes from the registered tile_ram read (bank b = lane b);
    // low 32b of each 64b word is the tag, high 32b is the depth.
    wire [RAS_LANES-1:0] ras_pass;
    genvar gd;
    generate
        for (gd = 0; gd < RAS_LANES; gd = gd + 1) begin : dcmp
            isp_depth_cmp u_cmp (
                .mode(b_mode),
                .nw  (b_invw[32*gd +: 32]),
                .ob  (tr_rdata[TR_W*gd + 32 +: 32]),   // old depth (high half)
                .pass(ras_pass[gd]));
        end
    endgenerate

    // -------------------- orchestration --------------------
    localparam S_IDLE=0, S_RA=1, S_STATE=2,
               S_OL_RUN=4,
               S_RA_ACK=9, S_DONE=10,
               S_DRAIN=11, S_FLUSH_WR=12,
               S_CLEAR_WR=13, S_FLUSH_RD=14;
    reg [3:0] st;

    localparam SU_IDLE=0, SU_RUN=1;              reg su_st;
    localparam RS_IDLE=0, RS_RAS=1, RS_DRAIN=2;  reg [1:0] rs_st;

    localparam integer EQ_N = 8;
    reg [1:0]       eq_etype [0:EQ_N-1];
    objlist_entry_t eq_entry [0:EQ_N-1];
    reg [3:0] eq_head, eq_tail; reg [4:0] eq_count;
    reg       eq_push, eq_pop;
    wire eq_full  = (eq_count == EQ_N);
    wire eq_empty = (eq_count == 0);
    localparam IT_IDLE=0, IT_RUN=1; reg it_cst;

    localparam integer FIFO_N = 8;
    reg [31:0] fq_isp [0:FIFO_N-1];
    reg [31:0] fq_tag [0:FIFO_N-1];
    reg [31:0] fq_x1[0:FIFO_N-1], fq_y1[0:FIFO_N-1], fq_z1[0:FIFO_N-1];
    reg [31:0] fq_x2[0:FIFO_N-1], fq_y2[0:FIFO_N-1], fq_z2[0:FIFO_N-1];
    reg [31:0] fq_x3[0:FIFO_N-1], fq_y3[0:FIFO_N-1], fq_z3[0:FIFO_N-1];
    reg [3:0]  fq_head, fq_tail;
    reg [4:0]  fq_count;
    reg        fifo_push, fifo_pop;
    wire fq_full  = (fq_count == FIFO_N);
    wire fq_empty = (fq_count == 0);

    reg        pend_valid;
    reg [31:0] pend_dx12,pend_dx23,pend_dx31,pend_dx41;
    reg [31:0] pend_dy12,pend_dy23,pend_dy31,pend_dy41;
    reg [31:0] pend_c1,pend_c2,pend_c3,pend_c4;
    reg [31:0] pend_ddx,pend_ddy,pend_cinvw;
    reg [31:0] pend_isp, pend_tag;
    reg [4:0]  pend_bx0,pend_bx1,pend_by0,pend_by1;

    reg prim_seen;
    // include !b_valid: the depth-cmp write-back pipeline is one cycle behind
    // ras_out_valid, so the last chunk's write may still be in flight when
    // rs_st returns to RS_IDLE. CLEAR/FLUSH must not touch the RAM until it lands.
    wire consumer_idle = eq_empty && (it_cst==IT_IDLE) && !it_busy
                       && (su_st==SU_IDLE) && (rs_st==RS_IDLE) && !pend_valid
                       && !b_valid;

    reg [5:0] cur_tx, cur_ty;
    integer i, l;
    integer px, py;
    reg [6:0]  cl_i;          // CLEAR chunk-address counter 0..127
    reg [6:0]  fw_ch;         // FLUSH chunk-address counter 0..127
    reg [2:0]  fw_lane;       // FLUSH lane within chunk 0..7
    reg        fl_prime;      // FLUSH: first read priming (unused placeholder)

    localparam integer NCHUNK = (TILE_W/RAS_LANES) * TILE_H;
    integer ras_inflight;

    // ============ COMBINATIONAL tile_ram control (address valid this cycle) ============
    // READ  port: stage A (raster consumer, on ras_out_valid) OR CLEAR/FLUSH read.
    // WRITE port: stage B (depth-cmp write-back, on b_valid) OR CLEAR write.
    // Presenting addresses combinationally makes the RAM's registered read give
    // exactly 1-cycle latency, so stage B (next cycle) sees THIS chunk's old data.
    integer cw;
    always @(*) begin
        tr_we    = '0;
        tr_waddr = '0;
        tr_raddr = '0;
        tr_wdata = '0;

        // ---- READ port ----
        if (ras_out_valid)                 // stage A: read chunk being resolved
            tr_raddr = tr_pack_addr(ras_oy, ras_ox);
        else if (st == S_FLUSH_RD || st == S_FLUSH_WR)
            tr_raddr = {NB{fw_ch}};        // FLUSH: hold chunk address

        // ---- WRITE port ----
        if (st == S_CLEAR_WR) begin        // CLEAR: background to all 8 banks
            tr_we    = {NB{1'b1}};
            tr_waddr = {NB{cl_i}};
            for (cw = 0; cw < RAS_LANES; cw = cw + 1) begin
                tr_wdata[TR_W*cw + 32 +: 32] = regs.isp_backgnd_d;
                tr_wdata[TR_W*cw +: 32]      = regs.isp_backgnd_t;
            end
        end else if (b_valid) begin        // stage B: depth-cmp write-back
            tr_waddr = tr_pack_addr(b_oy, b_ox);
            for (cw = 0; cw < RAS_LANES; cw = cw + 1) begin
                if (b_inside[cw] && ras_pass[cw]) begin
                    tr_we[cw] = 1'b1;
                    tr_wdata[TR_W*cw + 32 +: 32] =
                        b_zwdis ? tr_rdata[TR_W*cw + 32 +: 32] : b_invw[32*cw +: 32];
                    tr_wdata[TR_W*cw +: 32]      = b_tag;
                end
            end
        end
    end

    // -------------------- profiling counters (whole render) --------------------
    integer tri_count, cull_count, tri_seen;
    integer cyc_setup_run;   // isp_setup_min actively running (SU_RUN)
    integer cyc_su_wfetch;   // setup idle: no triangle from fetch yet (fetch-bound)
    integer cyc_su_wrast;    // setup idle: triangle ready but pend full (raster-bound)
    integer cyc_ras;         // raster sweeping (RS_RAS)
    integer cyc_ras_drain;   // raster draining (RS_DRAIN)
    integer cyc_ras_idle;    // raster idle waiting on pend
    integer cyc_total;       // total cycles from go to done

    always @(posedge clk) begin
        if (reset) begin
            st<=S_IDLE; done<=0; ra_start<=0; ol_start<=0; it_start<=0;
            isp_start<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            ras_inflight<=0;
            su_st<=SU_IDLE; rs_st<=RS_IDLE; pend_valid<=0; prim_seen<=0;
            fq_head<=0; fq_tail<=0; fq_count<=0;
            eq_head<=0; eq_tail<=0; eq_count<=0; it_cst<=IT_IDLE;
            cl_i<=0; fw_ch<=0; fw_lane<=0; fl_prime<=0; fbw_req.we<=1'b0;
            b_valid<=1'b0;
            tri_count<=0; cull_count<=0; tri_seen<=0;
            cyc_setup_run<=0; cyc_su_wfetch<=0; cyc_su_wrast<=0;
            cyc_ras<=0; cyc_ras_drain<=0; cyc_ras_idle<=0; cyc_total<=0;
        end else begin
            done<=0; ra_start<=0; ol_start<=0; it_start<=0;
            isp_start<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            eq_push = 1'b0;
            fbw_req.we <= 1'b0;   // default: no fb pixel (re-asserted in S_FLUSH_WR)

            // ================= streamed rasterizer CONSUMER (8 px/clock) =================
            // Simple-dual-port tile_ram (addresses driven combinationally above):
            // stage A presents the READ for chunk N (this cycle) and latches its
            // result fields; stage B (next cycle, on b_valid) receives tr_rdata =
            // chunk N's OLD data, the dcmp generate compares, and the combinational
            // WRITE port writes back the passing lanes. Stage A read (chunk N+1) and
            // stage B write (chunk N) share the cycle on the RAM's two ports.
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
            end
            ras_inflight <= ras_inflight + (ras_in_valid ? 1 : 0) - (ras_out_valid ? 1 : 0);

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
                case (ra_out.state)
                // CLEAR: write background {depth,tag} to all 128 chunk-words (all
                // 8 banks at each address) - one address/cycle, 128 cycles.
                RSTATE_CLEAR: if (consumer_idle && fq_empty) begin
                    cl_i <= 7'd0; st <= S_CLEAR_WR;
                end
                RSTATE_OP, RSTATE_PT, RSTATE_TR: begin
                    ol_list_ptr <= ra_out.list_ptr;
                    ol_start <= 1'b1;
                    t_xbase <= i2f({10'd0, cur_tx} * 16'd32);
                    t_ybase <= i2f({10'd0, cur_ty} * 16'd32);
                    st <= S_OL_RUN;
                end
                // FLUSH: stream the 32x32 tag buffer out to the framebuffer.
                RSTATE_FLUSH: if (consumer_idle && fq_empty) begin
                    fw_ch <= 7'd0; fw_lane <= 3'd0; fl_prime <= 1'b1;
                    st <= S_FLUSH_RD;
                end
                default: begin ra_ack.list_done <= 1'b1; st <= S_RA_ACK; end
                endcase
            end

            // CLEAR write loop: the combinational block writes background to all 8
            // banks at address cl_i each cycle; here we just walk cl_i 0..127.
            S_CLEAR_WR: begin
                if (cl_i == 7'd127) begin ra_ack.list_done <= 1'b1; st <= S_RA_ACK; end
                else cl_i <= cl_i + 7'd1;
            end

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
                        ol_ack.entry_done <= 1'b1;   // quad: skip
                    end
                end
            end

            S_DRAIN: if (fq_empty && consumer_idle) begin
                ra_ack.list_done <= 1'b1; st <= S_RA_ACK;
            end

            // FLUSH read: the combinational block presents chunk fw_ch's read
            // address; tr_rdata is valid next cycle in S_FLUSH_WR.
            S_FLUSH_RD: begin
                fw_lane <= 3'd0;
                st      <= S_FLUSH_WR;
            end

            // FLUSH writeout: emit the current chunk's 8 lanes (tags) one pixel/
            // cycle. Chunk fw_ch covers: addr={y,x[4:3]} so y=fw_ch[6:2],
            // x = {fw_ch[1:0], fw_lane}. Off-screen pixels skipped. (The comb block
            // holds tr_raddr = fw_ch across all 8 lanes.)
            S_FLUSH_WR: begin
                /* verilator lint_off WIDTH */
                px = {26'd0, cur_tx}*32 + {fw_ch[1:0], fw_lane};   // x in tile
                py = {26'd0, cur_ty}*32 + fw_ch[6:2];              // y in tile
                /* verilator lint_on WIDTH */
                if (px >= 640 || py >= 480) begin
                    // off-screen: skip without a write, advance lane/chunk
                    if (fw_lane == 3'd7) begin
                        if (fw_ch == 7'd127) begin ra_ack.list_done <= 1'b1; st <= S_RA_ACK; end
                        else begin fw_ch <= fw_ch + 7'd1; st <= S_FLUSH_RD; end
                    end else fw_lane <= fw_lane + 3'd1;
                end else begin
                    fbw_req.we      <= 1'b1;
                    /* verilator lint_off WIDTH */
                    fbw_req.pix_idx <= py*640 + px;
                    /* verilator lint_on WIDTH */
                    fbw_req.argb    <= tr_rdata[TR_W*fw_lane +: 32];   // tag (low 32b)
                    // advance only once the write is accepted
                    if (fbw_req.we && !fbw_resp.busy) begin
                        fbw_req.we <= 1'b0;
                        if (fw_lane == 3'd7) begin
                            if (fw_ch == 7'd127) begin ra_ack.list_done <= 1'b1; st <= S_RA_ACK; end
                            else begin fw_ch <= fw_ch + 7'd1; st <= S_FLUSH_RD; end
                        end else fw_lane <= fw_lane + 3'd1;
                    end
                end
            end

            S_RA_ACK: st <= S_RA;

            S_DONE: begin
                $display("=== done: %0d triangles rasterized, %0d culled, %0d cycles ===",
                         tri_count, cull_count, cyc_total);
                $display("=== profile: setup_run=%0d su_wait_fetch=%0d su_wait_rast=%0d ras=%0d ras_drain=%0d ras_idle=%0d ===",
                         cyc_setup_run, cyc_su_wfetch, cyc_su_wrast,
                         cyc_ras, cyc_ras_drain, cyc_ras_idle);
                if (tri_count + cull_count > 0)
                    $display("=== per-setup: setup_run=%0d (over %0d setups incl %0d culled) ===",
                             cyc_setup_run/(tri_count+cull_count), tri_count+cull_count, cull_count);
                if (tri_count > 0)
                    $display("=== per-triangle: setup_run=%0d su_wait_fetch=%0d su_wait_rast=%0d ras=%0d drain=%0d ===",
                             cyc_setup_run/tri_count, cyc_su_wfetch/tri_count, cyc_su_wrast/tri_count,
                             cyc_ras/tri_count, cyc_ras_drain/tri_count);
                done<=1'b1; st<=S_IDLE;
            end
            default: st<=S_IDLE;
            endcase

            // ---- profiling accumulation (whole render, go..done) ----
            if (st != S_IDLE && st != S_DONE) cyc_total <= cyc_total + 1;
            if (su_st==SU_RUN)          cyc_setup_run <= cyc_setup_run + 1;
            else if (fq_empty)          cyc_su_wfetch <= cyc_su_wfetch + 1;
            else if (pend_valid)        cyc_su_wrast  <= cyc_su_wrast  + 1;
            if (rs_st==RS_RAS)          cyc_ras       <= cyc_ras + 1;
            else if (rs_st==RS_DRAIN)   cyc_ras_drain <= cyc_ras_drain + 1;
            else if (!pend_valid)       cyc_ras_idle  <= cyc_ras_idle + 1;

            // ======== ITERATOR CONSUMER: entry FIFO -> iterator -> tri FIFO ========
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
                    it_ack.triangle_done <= 1'b1;
                    fq_tail  <= (fq_tail==FIFO_N-1) ? 4'd0 : fq_tail+4'd1;
                    fifo_push = 1'b1;
                    tri_seen <= tri_seen + 1;
                    if (tri_seen % 100 == 0)
                        $display("[TILE %0d,%0d] TRI %0d tag=%08h isp=%08h",
                            cur_tx, cur_ty, tri_seen, it_trio.tag, it_trio.isp);
                end
                if (prim_seen && !it_busy) it_cst <= IT_IDLE;
            end
            endcase

            // ================= CONSUMER: FIFO -> setup -> raster =================
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
                    cull_count <= cull_count + 1;
                end else begin
                    pend_dx12<=w_dx12; pend_dx23<=w_dx23; pend_dx31<=w_dx31; pend_dx41<=w_dx41;
                    pend_dy12<=w_dy12; pend_dy23<=w_dy23; pend_dy31<=w_dy31; pend_dy41<=w_dy41;
                    pend_c1<=w_c1; pend_c2<=w_c2; pend_c3<=w_c3; pend_c4<=w_c4;
                    pend_ddx<=w_ddx; pend_ddy<=w_ddy; pend_cinvw<=w_cinvw;
                    pend_isp<=isp_word_su; pend_tag<=su_tag;
                    pend_valid <= 1'b1;
                    pend_bx0 <= w_bx0; pend_bx1 <= w_bx1;
                    pend_by0 <= w_by0; pend_by1 <= w_by1;
                end
                su_st <= SU_IDLE;
            end
            endcase

            case (rs_st)
            RS_IDLE: if (pend_valid) begin
                isp_dx12<=pend_dx12; isp_dx23<=pend_dx23; isp_dx31<=pend_dx31; isp_dx41<=pend_dx41;
                isp_dy12<=pend_dy12; isp_dy23<=pend_dy23; isp_dy31<=pend_dy31; isp_dy41<=pend_dy41;
                isp_c1<=pend_c1; isp_c2<=pend_c2; isp_c3<=pend_c3; isp_c4<=pend_c4;
                isp_ddx_invw<=pend_ddx; isp_ddy_invw<=pend_ddy; isp_c_invw<=pend_cinvw;
                isp_word<=pend_isp; tri_tag<=pend_tag;
                pend_valid <= 1'b0;
                tri_count  <= tri_count + 1;
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
            // also wait for the depth-cmp write-back pipeline (b_valid) to land,
            // else the NEXT triangle's stage-A read races this triangle's last
            // stage-B write to the same word (RAW -> stale depth -> corruption).
            RS_DRAIN: if (ras_inflight == 0 && !ras_in_valid && !ras_out_valid
                          && !b_valid)
                rs_st <= RS_IDLE;
            endcase

            // ---- FIFO count maintenance ----
            fq_count <= fq_count + (fifo_push ? 5'd1 : 5'd0) - (fifo_pop ? 5'd1 : 5'd0);
            eq_count <= eq_count + (eq_push  ? 5'd1 : 5'd0) - (eq_pop   ? 5'd1 : 5'd0);
        end
    end
endmodule

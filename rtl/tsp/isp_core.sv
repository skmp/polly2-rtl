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
    // Fixed priority, lowest index wins (d_win checks pend[0] first). Order is
    // intentionally PRIM > OL > region array: the primitive iterator feeds the
    // raster/setup pipeline (most latency-critical), the object-list parser feeds
    // the iterator, and the region-array parser runs once per tile:
    //   0 = param  (pr) - primitive iterator vertex/param reads  (HIGHEST)
    //   1 = objlist (ol) - object-list entry reads
    //   2 = region (ra) - region-array entry reads                (LOWEST)
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

    // Prefetching iterator: streaming entry input (entry_valid/entry_ack) driven
    // from the entry FIFO head, ping-pong record buffers so the next record's DDR
    // burst overlaps the current record's triangle emit (hides fetch behind setup).
    wire             it_entry_valid, it_entry_ack, it_pf_busy;
    triangle_out_t   it_trio; triangle_ack_t it_ack;
    isp_primitive_iterator_pf u_it (.clk(clk),.reset(reset),
        .intensity_shadow(regs.fpu_shad_scale.intensity_shadow),
        .param_base(param_base),
        .entry_valid(it_entry_valid),.entry_type(it_etype),.entry(it_entry),
        .entry_pt(1'b0),   // isp_core: tag-only path, no PT/TL peel list-kind
        .entry_ack(it_entry_ack),.busy(it_pf_busy),
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
    reg  [31:0] isp_word;                 // active (raster) triangle's isp
    reg  [31:0] t_xbase, t_ybase;         // tile origin (stable per tile-state)
    reg  [31:0] tri_tag;                  // active (raster) triangle's CoreTag
    wire        isp_sgn_neg, isp_cull;
    wire [4:0]  w_bx0, w_bx1, w_by0, w_by1;
    wire [31:0] w_dx12,w_dx23,w_dx31,w_dx41, w_dy12,w_dy23,w_dy31,w_dy41;
    wire [31:0] w_c1,w_c2,w_c3,w_c4, w_ddx,w_ddy,w_cinvw;

    // Setup produces to a common interface the pq-push consumes:
    //   su_in_valid/su_in_ready (accept from fq), su_out_valid + w_*/su_out_tag/
    //   su_out_isp/isp_cull (retire into pq), su_busy (barrier).
    wire        su_in_valid, su_in_ready, su_out_valid, su_busy;
    wire [31:0] su_out_tag, su_out_isp;
    assign su_in_valid = !fq_empty && (pq_count <= 5'd4);

    // 4-way interleaved streaming setup: accepts a triangle from the tri FIFO
    // whenever su_in_ready, retires one (out_valid) ~every 4 clocks -> ~14 cyc/tri
    // throughput vs 56, same 4 mac lanes. tag carries the CoreTag through.
    isp_setup_streamed u_isp (
        .clk(clk), .reset(reset),
        .in_valid(su_in_valid), .in_ready(su_in_ready),
        .isp_word(fq_isp[fq_head[2:0]]), .in_tag(fq_tag[fq_head[2:0]]), .in_pt(1'b0),
        .quad(fq_quad[fq_head[2:0]]),
        .x4(fq_x4[fq_head[2:0]]), .y4(fq_y4[fq_head[2:0]]),
        .x1(fq_x1[fq_head[2:0]]), .y1(fq_y1[fq_head[2:0]]), .z1(fq_z1[fq_head[2:0]]),
        .x2(fq_x2[fq_head[2:0]]), .y2(fq_y2[fq_head[2:0]]), .z2(fq_z2[fq_head[2:0]]),
        .x3(fq_x3[fq_head[2:0]]), .y3(fq_y3[fq_head[2:0]]), .z3(fq_z3[fq_head[2:0]]),
        .xbase(t_xbase), .ybase(t_ybase),
        .busy(su_busy),
        .out_ready(!pq_full),
        .out_valid(su_out_valid), .out_tag(su_out_tag), .out_pt(/*unused*/), .out_isp(su_out_isp),
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
        .probe(1'b0), .probe_reject(), .probe_valid(),   // corner-probe unused in isp_core
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

    localparam RS_IDLE=0, RS_RAS=1, RS_DRAIN=2;  reg [1:0] rs_st;

    localparam integer EQ_N = 8;
    reg [1:0]       eq_etype [0:EQ_N-1];
    objlist_entry_t eq_entry [0:EQ_N-1];
    reg [3:0] eq_head, eq_tail; reg [4:0] eq_count;
    reg       eq_push, eq_pop;
    wire eq_full  = (eq_count == EQ_N);
    wire eq_empty = (eq_count == 0);

    // entry FIFO head -> prefetching iterator's streaming input. The iterator pulls
    // entries via entry_valid/entry_ack; the region barrier observes list-done via
    // eq_empty && !it_pf_busy (no flush/drained handshake).
    objlist_entry_t it_entry;   // = eq_entry[head]  (combinational)
    entry_type_e    it_etype;   // = eq_etype[head]
    always @(*) begin
        it_entry = eq_entry[eq_head[2:0]];
        it_etype = entry_type_e'(eq_etype[eq_head[2:0]]);
    end
    assign it_entry_valid = !eq_empty;

    localparam integer FIFO_N = 8;
    reg [31:0] fq_isp [0:FIFO_N-1];
    reg [31:0] fq_tag [0:FIFO_N-1];
    reg [31:0] fq_x1[0:FIFO_N-1], fq_y1[0:FIFO_N-1], fq_z1[0:FIFO_N-1];
    reg [31:0] fq_x2[0:FIFO_N-1], fq_y2[0:FIFO_N-1], fq_z2[0:FIFO_N-1];
    reg [31:0] fq_x3[0:FIFO_N-1], fq_y3[0:FIFO_N-1], fq_z3[0:FIFO_N-1];
    reg [31:0] fq_x4[0:FIFO_N-1], fq_y4[0:FIFO_N-1];   // QUAD 4th vertex (X/Y only)
    reg        fq_quad[0:FIFO_N-1];                     // 1 = quad record
    reg [3:0]  fq_head, fq_tail;
    reg [4:0]  fq_count;
    reg        fifo_push, fifo_pop;
    wire fq_full  = (fq_count == FIFO_N);
    wire fq_empty = (fq_count == 0);

    // ---- 8-deep PLANE FIFO (pq): setup -> raster ----
    // Decouples isp_setup_min (56 cyc/tri) from the rasterizer so setup runs ahead
    // and fills the FIFO instead of lock-stepping through a 1-deep handoff.
    localparam integer PQ_N = 8;
    reg [31:0] pq_dx12[0:PQ_N-1],pq_dx23[0:PQ_N-1],pq_dx31[0:PQ_N-1],pq_dx41[0:PQ_N-1];
    reg [31:0] pq_dy12[0:PQ_N-1],pq_dy23[0:PQ_N-1],pq_dy31[0:PQ_N-1],pq_dy41[0:PQ_N-1];
    reg [31:0] pq_c1[0:PQ_N-1],pq_c2[0:PQ_N-1],pq_c3[0:PQ_N-1],pq_c4[0:PQ_N-1];
    reg [31:0] pq_ddx[0:PQ_N-1],pq_ddy[0:PQ_N-1],pq_cinvw[0:PQ_N-1];
    reg [31:0] pq_isp[0:PQ_N-1],pq_tag[0:PQ_N-1];
    reg [4:0]  pq_bx0[0:PQ_N-1],pq_bx1[0:PQ_N-1],pq_by0[0:PQ_N-1],pq_by1[0:PQ_N-1];
    reg [3:0]  pq_head, pq_tail;
    reg [4:0]  pq_count;
    reg        pq_push, pq_pop;
    wire pq_full  = (pq_count == PQ_N);
    wire pq_empty = (pq_count == 0);

    // Barrier idle uses the iterator's AUTHORITATIVE level-busy (it_pf_busy: any
    // record buffered/being read/emitted/outstanding) instead of a pulse-cleared
    // tracker reg, which could desync (drained pulse racing a refilled eq) and open
    // the barrier while entries/triangles were still pending -> next tile's
    // CLEAR/FLUSH corrupts live tile data.
    // include !b_valid: the depth-cmp write-back pipeline is one cycle behind
    // ras_out_valid, so the last chunk's write may still be in flight when
    // rs_st returns to RS_IDLE. CLEAR/FLUSH must not touch the RAM until it lands.
    wire consumer_idle = eq_empty && !it_pf_busy
                       && !su_busy && (rs_st==RS_IDLE) && pq_empty
                       && !b_valid;

    reg [5:0] cur_tx, cur_ty;
    integer i, l;
    integer px, py;
    reg [6:0]  cl_i;          // CLEAR chunk-address counter 0..127
    reg [6:0]  fw_ch;         // FLUSH chunk-address counter 0..127
    reg [2:0]  fw_lane;       // FLUSH lane within chunk 0..7
    reg        fl_prime;      // FLUSH: first read priming (unused placeholder)

    // ---- COMBINATIONAL framebuffer-write (FLUSH), valid/ready handshake ----
    // fbw_req is driven from the FLUSH state so present + accept are same-cycle:
    // works with a real controller that blocks (busy holds; we advance only when
    // the pixel is consumed). The tile x,y for the current {fw_ch,fw_lane}:
    wire [10:0] fw_px = {5'd0, cur_tx}*11'd32 + {6'd0, fw_ch[1:0], fw_lane};
    wire [10:0] fw_py = {5'd0, cur_ty}*11'd32 + {6'd0, fw_ch[6:2]};
    wire        fw_onscreen = (fw_px < 11'd640) && (fw_py < 11'd480);
    always @(*) begin
        fbw_req.we      = (st==S_FLUSH_WR) && fw_onscreen;
        fbw_req.pix_idx = fw_py*20'd640 + {9'd0, fw_px};
        fbw_req.argb    = tr_rdata[TR_W*fw_lane +: 32];   // tag (low 32b)
    end
    // a pixel is consumed this cycle when: on-screen and the sink accepted it, OR
    // off-screen (nothing to write -> skip immediately).
    wire fw_pix_consumed = (st==S_FLUSH_WR) &&
                           ( (fw_onscreen && !fbw_resp.busy) || !fw_onscreen );

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
    // producer-side breakdown (why su_wait_fetch is high)
    integer cyc_it_busy;     // iterator active (reading a record / emitting)
    integer cyc_it_ddrwait;  // iterator wants DDR but channel busy elsewhere
    integer cyc_it_noeq;     // iterator idle: entry FIFO empty (OL behind)
    integer cyc_ol_busy;     // OL parser active
    integer cyc_fq_full;     // tri FIFO full (producer blocked by slow setup/raster)
    integer cyc_eq_full;     // entry FIFO full (iterator behind OL)
    // record-level decomposition of the producer
    integer n_records;       // iterator entries started (IT_IDLE -> IT_RUN)
    integer cyc_it_reading;  // IT_RUN, no triangle presented yet (record fetch/bubble)
    integer cyc_it_blocked;  // IT_RUN, triangle ready but fq_full (downstream block)
    integer cyc_it_emit;     // IT_RUN, triangle presented + accepted (productive)
    // per-phase (top FSM state) cycle breakdown - where the whole render time goes
    integer cyc_ph_ra;       // S_RA (region walk) + S_STATE
    integer cyc_ph_ol;       // S_OL_RUN (walking a list + emitting triangles)
    integer cyc_ph_drain;    // S_DRAIN (waiting for iterator/FIFO to empty)
    integer cyc_ph_clear;    // S_CLEAR_WR
    integer cyc_ph_flush;    // S_FLUSH_RD + S_FLUSH_WR
    integer cyc_ph_ack;      // S_RA_ACK
    integer n_tiles;         // list_ready events (tile-states processed)
    // S_DRAIN split: still-rasterizing (real work) vs pure barrier-wait latency
    integer cyc_drain_work;  // S_DRAIN while raster/setup/pq still busy (legit)
    integer cyc_drain_wait;  // S_DRAIN while everything raster-side idle (waste)

    always @(posedge clk) begin
        if (reset) begin
            st<=S_IDLE; done<=0; ra_start<=0; ol_start<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            ras_inflight<=0;
            rs_st<=RS_IDLE;
            pq_head<=0; pq_tail<=0; pq_count<=0;
            fq_head<=0; fq_tail<=0; fq_count<=0;
            eq_head<=0; eq_tail<=0; eq_count<=0;
            cl_i<=0; fw_ch<=0; fw_lane<=0; fl_prime<=0;
            b_valid<=1'b0;
            tri_count<=0; cull_count<=0; tri_seen<=0;
            cyc_setup_run<=0; cyc_su_wfetch<=0; cyc_su_wrast<=0;
            cyc_ras<=0; cyc_ras_drain<=0; cyc_ras_idle<=0; cyc_total<=0;
            cyc_it_busy<=0; cyc_it_ddrwait<=0; cyc_it_noeq<=0;
            cyc_ol_busy<=0; cyc_fq_full<=0; cyc_eq_full<=0;
            n_records<=0; cyc_it_reading<=0; cyc_it_blocked<=0; cyc_it_emit<=0;
            cyc_ph_ra<=0; cyc_ph_ol<=0; cyc_ph_drain<=0; cyc_ph_clear<=0;
            cyc_ph_flush<=0; cyc_ph_ack<=0; n_tiles<=0;
            cyc_drain_work<=0; cyc_drain_wait<=0;
        end else begin
            done<=0; ra_start<=0; ol_start<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0;
            eq_push = 1'b0;

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

            // DEBUG (disabled): per-8x1-block FIFO-depth + OL/PRIM status trace.
            // if (ras_in_valid)
            //     $display("[8x1] eq_depth=%0d fq_depth=%0d pq_depth=%0d OL=%s PRIM=%s",
            //         eq_count, fq_count, pq_count,
            //         (ol_prim.entry_ready && eq_full) ? "W" : (ol_busy ? "P" : "."),
            //         it_trio.triangle_ready ? "P" : (it_pf_busy ? "R" : "."));

            case (st)
            S_IDLE: if (go) begin ra_start<=1; st<=S_RA; end

            S_RA: begin
                if (ra_tiles_parsed) st<=S_DONE;
                else if (ra_out.list_ready) begin
                    cur_tx <= ra_out.tile_x; cur_ty <= ra_out.tile_y;
                    n_tiles <= n_tiles + 1;
                    st<=S_STATE;
                end
            end

            S_STATE: begin
                case (ra_out.state)
                // CLEAR: write background {depth,tag} to all 128 chunk-words (all
                // 8 banks at each address) - one address/cycle, 128 cycles.
                RSTATE_CLEAR: if (consumer_idle && fq_empty) begin
                    cl_i <= 7'd0; st <= S_CLEAR_WR;
                    // $display("[CLEAR] tile=%0d,%0d bgd=%08h bgt=%08h",
                    //     cur_tx, cur_ty, regs.isp_backgnd_d, regs.isp_backgnd_t);
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
                    // $display("[FLUSH] tile=%0d,%0d -> fb (%0d,%0d)..(%0d,%0d)",
                    //     cur_tx, cur_ty, cur_tx*32, cur_ty*32, cur_tx*32+31, cur_ty*32+31);
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
                // when the OL list is fully walked, go to the drain barrier; the
                // iterator finishes what's queued in eq (observed via !it_pf_busy).
                if (ol_done) st <= S_DRAIN;
                else if (ol_prim.entry_ready && !ol_ack.entry_done) begin
                    // strips, tri arrays AND quad arrays all queue to the iterator
                    if (!eq_full) begin
                        eq_etype[eq_tail[2:0]] <= ol_prim.entry_type;
                        eq_entry[eq_tail[2:0]] <= ol_prim.entry;
                        eq_tail <= (eq_tail==EQ_N-1) ? 4'd0 : eq_tail+4'd1;
                        eq_push = 1'b1;
                        ol_ack.entry_done <= 1'b1;
                        // DEBUG (disabled): one line per object-list entry read.
                        // $display("[OLREAD] tile=%0d,%0d type=%0d param_offs=%0h skip=%0d shadow=%0d mask=%02h count=%0d",
                        //     cur_tx, cur_ty, ol_prim.entry_type,
                        //     ol_prim.entry.param_offs_in_words, ol_prim.entry.skip,
                        //     ol_prim.entry.shadow, ol_prim.entry.mask, ol_prim.entry.count);
                    end
                end
            end

            // wait for the whole producer/consumer chain to drain: consumer_idle
            // gates on eq_empty + !it_pf_busy (iterator authoritative) + !su_busy +
            // rs idle + pq_empty + !b_valid, plus fq_empty here.
            S_DRAIN: if (fq_empty && consumer_idle) begin
                ra_ack.list_done <= 1'b1; st <= S_RA_ACK;
            end

            // FLUSH read: the combinational block presents chunk fw_ch's read
            // address; tr_rdata is valid next cycle in S_FLUSH_WR.
            S_FLUSH_RD: begin
                fw_lane <= 3'd0;
                st      <= S_FLUSH_WR;
            end

            // FLUSH writeout: emit the current chunk's 8 lanes (tags) at ONE PIXEL
            // PER CYCLE. fbw_req is driven COMBINATIONALLY (see fb write block) from
            // {fw_ch,fw_lane}; here we only ADVANCE, and only when the pixel is
            // consumed: on-screen pixel accepted (fbw_req.we && !fbw_resp.busy) OR
            // an off-screen pixel (skipped, no write). A busy on-screen pixel holds
            // the counters so the combinational fbw_req keeps presenting it - so this
            // works with a real controller that blocks. Chunk boundary -> S_FLUSH_RD
            // for one cycle to re-address the tile RAM.
            S_FLUSH_WR: begin
                if (fw_pix_consumed) begin
                    if (fw_lane == 3'd7) begin
                        if (fw_ch == 7'd127) begin ra_ack.list_done <= 1'b1; st <= S_RA_ACK; end
                        else begin fw_ch <= fw_ch + 7'd1; st <= S_FLUSH_RD; end
                    end else fw_lane <= fw_lane + 3'd1;
                end
            end

            S_RA_ACK: st <= S_RA;

            S_DONE: begin
                $display("=== done: %0d triangles rasterized, %0d culled, %0d cycles ===",
                         tri_count, cull_count, cyc_total);
                $display("=== profile: setup_run=%0d su_wait_fetch=%0d su_wait_rast=%0d ras=%0d ras_drain=%0d ras_idle=%0d ===",
                         cyc_setup_run, cyc_su_wfetch, cyc_su_wrast,
                         cyc_ras, cyc_ras_drain, cyc_ras_idle);
                $display("=== producer: it_busy=%0d it_ddrwait=%0d it_noeq=%0d ol_busy=%0d fq_full=%0d eq_full=%0d ===",
                         cyc_it_busy, cyc_it_ddrwait, cyc_it_noeq,
                         cyc_ol_busy, cyc_fq_full, cyc_eq_full);
                $display("=== records: n=%0d it_reading=%0d it_blocked=%0d it_emit=%0d ===",
                         n_records, cyc_it_reading, cyc_it_blocked, cyc_it_emit);
                $display("=== phases: tiles=%0d ra=%0d ol=%0d drain=%0d clear=%0d flush=%0d ack=%0d ===",
                         n_tiles, cyc_ph_ra, cyc_ph_ol, cyc_ph_drain,
                         cyc_ph_clear, cyc_ph_flush, cyc_ph_ack);
                if (n_tiles > 0)
                    $display("=== per-tile-state: ra=%0d ol=%0d drain=%0d clear=%0d flush=%0d ===",
                             cyc_ph_ra/n_tiles, cyc_ph_ol/n_tiles, cyc_ph_drain/n_tiles,
                             cyc_ph_clear/n_tiles, cyc_ph_flush/n_tiles);
                $display("=== drain split: work=%0d wait=%0d ===",
                         cyc_drain_work, cyc_drain_wait);
                if (n_records > 0)
                    $display("=== per-record: reading=%0d blocked=%0d emit=%0d tris/rec=%0d ===",
                             cyc_it_reading/n_records, cyc_it_blocked/n_records,
                             cyc_it_emit/n_records, tri_count/n_records);
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
            if (su_busy)                cyc_setup_run <= cyc_setup_run + 1;  // >=1 slot in flight
            else if (fq_empty)          cyc_su_wfetch <= cyc_su_wfetch + 1;
            else if (pq_count > 5'd4)   cyc_su_wrast  <= cyc_su_wrast  + 1;  // setup throttled: plane FIFO near-full
            if (rs_st==RS_RAS)          cyc_ras       <= cyc_ras + 1;
            else if (rs_st==RS_DRAIN)   cyc_ras_drain <= cyc_ras_drain + 1;
            else if (pq_empty)          cyc_ras_idle  <= cyc_ras_idle + 1;   // raster idle: plane FIFO empty

            // per-phase (top FSM) breakdown: where the whole render time actually goes
            case (st)
            S_RA, S_STATE:            cyc_ph_ra    <= cyc_ph_ra + 1;
            S_OL_RUN:                 cyc_ph_ol    <= cyc_ph_ol + 1;
            S_DRAIN: begin
                cyc_ph_drain <= cyc_ph_drain + 1;
                // split: raster/setup/pq/fq still doing work (legit) vs pure
                // barrier-wait latency (raster-side fully idle but not yet released)
                if (su_busy || (rs_st!=RS_IDLE) || !pq_empty
                    || !fq_empty || b_valid)
                    cyc_drain_work <= cyc_drain_work + 1;
                else
                    cyc_drain_wait <= cyc_drain_wait + 1;
            end
            S_CLEAR_WR:               cyc_ph_clear <= cyc_ph_clear + 1;
            S_FLUSH_RD, S_FLUSH_WR:   cyc_ph_flush <= cyc_ph_flush + 1;
            S_RA_ACK:                 cyc_ph_ack   <= cyc_ph_ack + 1;
            default: ;
            endcase

            // ---- producer-side breakdown (diagnose su_wait_fetch) ----
            if (it_pf_busy)                 cyc_it_busy    <= cyc_it_busy + 1;
            // iterator asserting a DDR read but the shared channel won't accept it
            if (pr_dreq.rd && pr_dresp.busy) cyc_it_ddrwait <= cyc_it_ddrwait + 1;
            // iterator active but no entry queued (OL parser can't keep up)
            if (it_pf_busy && eq_empty && !it_trio.triangle_ready)
                                            cyc_it_noeq    <= cyc_it_noeq + 1;
            if (ol_busy)                    cyc_ol_busy    <= cyc_ol_busy + 1;
            if (fq_full)                    cyc_fq_full    <= cyc_fq_full + 1;
            if (eq_full)                    cyc_eq_full    <= cyc_eq_full + 1;
            // decomposition of the iterator's active time
            if (it_pf_busy) begin
                if (!it_trio.triangle_ready)    cyc_it_reading <= cyc_it_reading + 1;
                else if (fq_full)               cyc_it_blocked <= cyc_it_blocked + 1;
                else if (!it_ack.triangle_done) cyc_it_emit    <= cyc_it_emit + 1;
            end

            // ============ ENTRY FIFO -> prefetching iterator -> tri FIFO ============
            // The iterator pulls entries itself via entry_valid/entry_ack; we just
            // pop the eq FIFO on ack and push its emitted triangles into fq.
            eq_pop    = 1'b0;
            fifo_push = 1'b0;
            it_ack.triangle_done <= 1'b0;

            // entry FIFO pop when the iterator consumes the head entry
            if (it_entry_ack && !eq_empty) begin
                eq_head <= (eq_head==EQ_N-1) ? 4'd0 : eq_head+4'd1;
                eq_pop  = 1'b1;
                n_records <= n_records + 1;
                // DEBUG (disabled): one line per entry LOADED by the iterator.
                // $display("[PRIMLOAD] tile=%0d,%0d type=%0d param_offs=%0h skip=%0d shadow=%0d mask=%02h count=%0d",
                //     cur_tx, cur_ty, it_etype, it_entry.param_offs_in_words,
                //     it_entry.skip, it_entry.shadow, it_entry.mask, it_entry.count);
            end

            // push emitted triangles into the tri FIFO (hold-until-space handshake)
            if (it_trio.triangle_ready && !fq_full && !it_ack.triangle_done) begin
                fq_isp[fq_tail[2:0]] <= it_trio.isp;
                fq_tag[fq_tail[2:0]] <= it_trio.tag;
                fq_x1[fq_tail[2:0]]<=it_trio.v0.x; fq_y1[fq_tail[2:0]]<=it_trio.v0.y; fq_z1[fq_tail[2:0]]<=it_trio.v0.z;
                fq_x2[fq_tail[2:0]]<=it_trio.v1.x; fq_y2[fq_tail[2:0]]<=it_trio.v1.y; fq_z2[fq_tail[2:0]]<=it_trio.v1.z;
                fq_x3[fq_tail[2:0]]<=it_trio.v2.x; fq_y3[fq_tail[2:0]]<=it_trio.v2.y; fq_z3[fq_tail[2:0]]<=it_trio.v2.z;
                fq_x4[fq_tail[2:0]]<=it_trio.v3x;  fq_y4[fq_tail[2:0]]<=it_trio.v3y;
                fq_quad[fq_tail[2:0]]<=it_trio.quad;
                it_ack.triangle_done <= 1'b1;
                fq_tail  <= (fq_tail==FIFO_N-1) ? 4'd0 : fq_tail+4'd1;
                fifo_push = 1'b1;
                tri_seen <= tri_seen + 1;
                // DEBUG (disabled): per-100-triangle progress log.
                // if (tri_seen % 100 == 0)
                //     $display("[TILE %0d,%0d] TRI %0d tag=%08h isp=%08h",
                //         cur_tx, cur_ty, tri_seen, it_trio.tag, it_trio.isp);
            end

            // (barrier now uses the iterator's authoritative level busy: it_pf_busy)

            // ============ CONSUMER: tri FIFO -> streaming setup -> plane FIFO ============
            fifo_pop = 1'b0;
            pq_push  = 1'b0;

            // present a triangle to the streaming setup; pop fq when accepted.
            // su_in_valid is assigned combinationally outside the always block.
            if (su_in_valid && su_in_ready) begin
                fq_head <= (fq_head==FIFO_N-1) ? 4'd0 : fq_head+4'd1;
                fifo_pop = 1'b1;
            end

            // retire: on out_valid, push non-culled triangles into the plane FIFO.
            if (su_out_valid) begin
                if (isp_cull) begin
                    cull_count <= cull_count + 1;
                end else begin
                    pq_dx12[pq_tail[2:0]]<=w_dx12; pq_dx23[pq_tail[2:0]]<=w_dx23;
                    pq_dx31[pq_tail[2:0]]<=w_dx31; pq_dx41[pq_tail[2:0]]<=w_dx41;
                    pq_dy12[pq_tail[2:0]]<=w_dy12; pq_dy23[pq_tail[2:0]]<=w_dy23;
                    pq_dy31[pq_tail[2:0]]<=w_dy31; pq_dy41[pq_tail[2:0]]<=w_dy41;
                    pq_c1[pq_tail[2:0]]<=w_c1; pq_c2[pq_tail[2:0]]<=w_c2;
                    pq_c3[pq_tail[2:0]]<=w_c3; pq_c4[pq_tail[2:0]]<=w_c4;
                    pq_ddx[pq_tail[2:0]]<=w_ddx; pq_ddy[pq_tail[2:0]]<=w_ddy;
                    pq_cinvw[pq_tail[2:0]]<=w_cinvw;
                    pq_isp[pq_tail[2:0]]<=su_out_isp; pq_tag[pq_tail[2:0]]<=su_out_tag;
                    pq_bx0[pq_tail[2:0]]<=w_bx0; pq_bx1[pq_tail[2:0]]<=w_bx1;
                    pq_by0[pq_tail[2:0]]<=w_by0; pq_by1[pq_tail[2:0]]<=w_by1;
                    pq_tail <= (pq_tail==PQ_N-1) ? 4'd0 : pq_tail+4'd1;
                    pq_push  = 1'b1;
                end
            end

            pq_pop = 1'b0;
            case (rs_st)
            RS_IDLE: if (!pq_empty) begin
                isp_dx12<=pq_dx12[pq_head[2:0]]; isp_dx23<=pq_dx23[pq_head[2:0]];
                isp_dx31<=pq_dx31[pq_head[2:0]]; isp_dx41<=pq_dx41[pq_head[2:0]];
                isp_dy12<=pq_dy12[pq_head[2:0]]; isp_dy23<=pq_dy23[pq_head[2:0]];
                isp_dy31<=pq_dy31[pq_head[2:0]]; isp_dy41<=pq_dy41[pq_head[2:0]];
                isp_c1<=pq_c1[pq_head[2:0]]; isp_c2<=pq_c2[pq_head[2:0]];
                isp_c3<=pq_c3[pq_head[2:0]]; isp_c4<=pq_c4[pq_head[2:0]];
                isp_ddx_invw<=pq_ddx[pq_head[2:0]]; isp_ddy_invw<=pq_ddy[pq_head[2:0]];
                isp_c_invw<=pq_cinvw[pq_head[2:0]];
                isp_word<=pq_isp[pq_head[2:0]]; tri_tag<=pq_tag[pq_head[2:0]];
                pq_head <= (pq_head==PQ_N-1) ? 4'd0 : pq_head+4'd1;
                pq_pop  = 1'b1;
                tri_count  <= tri_count + 1;
                rbx0 <= pq_bx0[pq_head[2:0]] & 5'(~(RAS_LANES-1));
                rbx1 <= pq_bx1[pq_head[2:0]] & 5'(~(RAS_LANES-1));
                rby1 <= pq_by1[pq_head[2:0]];
                ras_y <= pq_by0[pq_head[2:0]];
                ras_x <= pq_bx0[pq_head[2:0]] & 5'(~(RAS_LANES-1));
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
            pq_count <= pq_count + (pq_push  ? 5'd1 : 5'd0) - (pq_pop   ? 5'd1 : 5'd0);
        end
    end
endmodule

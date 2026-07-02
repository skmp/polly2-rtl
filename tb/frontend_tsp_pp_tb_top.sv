// frontend_tsp_pp_tb_top - TRIPLE-BUFFERED, three-stage concurrent tile pipeline.
//
// Same rendering as frontend_tsp_tb_top, but the three per-tile stages run
// CONCURRENTLY on rotating tile buffers (ping/pong/pang):
//
//   slot N   : ISP stage   - region/objlist walk, primitive iterate, isp_setup,
//                            streamed rasterize -> dt_depth[N]/dt_tag[N]
//   slot N-1 : TSP stage   - per-pixel plane-cache lookup (+param fetch+tsp_setup
//                            on miss) -> tsp_shade_pp -> col_buf[N-1]
//   slot N-2 : WRITEOUT    - copy col_buf[N-2] -> 640x480 framebuffer
//
// Each stage is an independent FSM (separate always block) owning ONE slot at a
// time; slots rotate through FREE -> ISP -> TSP -> WRITE -> FREE. The stages are
// resource-disjoint: ISP uses region/objlist/param data caches + isp_setup/
// raster; TSP uses the tsp param cache + plane cache + tsp_setup + 4 corner tex
// caches; writeout touches only fb. They share only the behavioral VRAM (via
// separate cache DDR ports) so they truly overlap.
//
module frontend_tsp_pp_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    input             go,
    output reg        done
);
    localparam integer TILE_W = 32, TILE_H = 32, NPIX = TILE_W*TILE_H;
    localparam integer NSLOT = 3;

    // -------------------- reg_file --------------------
    pvr_regs_t  regs;
    fog_rd_req_t fog_req; fog_rd_resp_t fog_resp;
    pal_rd_req_t pal_req; pal_rd_resp_t pal_resp;
    assign fog_req = '0; assign pal_req = '0;
    reg_file u_rf (.clk(clk),.reset(reset),.wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),
        .regs(regs),.fog_req(fog_req),.fog_resp(fog_resp),.pal_req(pal_req),.pal_resp(pal_resp));

    wire [26:0] region_base = regs.region_base[26:0];
    wire [26:0] param_base  = (regs.param_base[26:0] & 27'h0F00000);
    wire        region_v1   = (regs.fpu_param_cfg.region_header_type == 1'b0);

    // -------------------- 8 MB behavioral VRAM --------------------
    (* verilator public_flat_rw *) reg [63:0] vram [0:1048575];

    // DDR read stub factory - simple 1-beat model (used by ra + ts)
    `define DDRPORT(NM) \
        ddr_rd_req_t NM``_dreq; ddr_rd_resp_t NM``_dresp; \
        reg [63:0] NM``_do; reg NM``_dv; \
        assign NM``_dresp.busy=1'b0; assign NM``_dresp.dout=NM``_do; assign NM``_dresp.dready=NM``_dv; \
        always @(posedge clk) begin NM``_dv<=0; if(NM``_dreq.rd) begin NM``_do<=vram[NM``_dreq.addr[19:0]]; NM``_dv<=1; end end

    `DDRPORT(ra) `DDRPORT(ts)

    // objlist + param ports - BURST + latency model (each a single 64-bit channel):
    // a read is accepted for RD_LAT dead cycles, then `burst` consecutive beats
    // stream out one/cycle from incrementing addresses. The OL parser and ISP
    // iterator read DDR DIRECTLY through these (no line cache).
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
    // param port
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

    // texture DDR ports (4 corners x {data,VQ} = 8)
    genvar gi_tex;
    ddr_rd_req_t  tex_dreq [0:7];
    ddr_rd_resp_t tex_dresp [0:7];
    generate
      for (gi_tex = 0; gi_tex < 8; gi_tex = gi_tex + 1) begin : texddr
        reg [63:0] do_r; reg dv_r;
        assign tex_dresp[gi_tex].busy=1'b0;
        assign tex_dresp[gi_tex].dout=do_r; assign tex_dresp[gi_tex].dready=dv_r;
        always @(posedge clk) begin
            dv_r<=0; if (tex_dreq[gi_tex].rd) begin do_r<=vram[tex_dreq[gi_tex].addr[19:0]]; dv_r<=1; end
        end
      end
    endgenerate

    // -------------------- caches --------------------
    // Region parser + TSP param reader keep their 256-bit line caches; the OL
    // parser and ISP iterator read DDR DIRECTLY (own line buffers / burst).
    cache_req256_t ra_creq, ts_creq;
    cache_resp256_t ra_cresp, ts_cresp;
    data_cache256 u_ra_c (.clk(clk),.reset(reset),.creq(ra_creq),.cresp(ra_cresp),.dreq(ra_dreq),.dresp(ra_dresp));
    data_cache256 u_ts_c (.clk(clk),.reset(reset),.creq(ts_creq),.cresp(ts_cresp),.dreq(ts_dreq),.dresp(ts_dresp));

    cache_req_t   pp_tc_req [0:3], pp_vq_req [0:3];
    cache_resp_t  pp_tc_resp[0:3], pp_vq_resp[0:3];
    generate
      for (gi_tex = 0; gi_tex < 4; gi_tex = gi_tex + 1) begin : texcache
        tex_cache u_tc (.clk(clk),.reset(reset),.creq(pp_tc_req[gi_tex]),.cresp(pp_tc_resp[gi_tex]),
            .dreq(tex_dreq[2*gi_tex]),.dresp(tex_dresp[2*gi_tex]));
        tex_cache u_vq (.clk(clk),.reset(reset),.creq(pp_vq_req[gi_tex]),.cresp(pp_vq_resp[gi_tex]),
            .dreq(tex_dreq[2*gi_tex+1]),.dresp(tex_dresp[2*gi_tex+1]));
      end
    endgenerate

    // -------------------- parsers --------------------
    reg          ra_start;
    wire         ra_busy, ra_tiles_parsed;
    region_out_t ra_out; region_ack_t ra_ack;
    region_array_parser u_ra (.clk(clk),.reset(reset),.start(ra_start),
        .region_base(region_base),.region_v1(region_v1),.busy(ra_busy),
        .tiles_parsed(ra_tiles_parsed),.rout(ra_out),.ack(ra_ack),.creq(ra_creq),.cresp(ra_cresp));

    reg          ol_start; reg [26:0] ol_list_ptr;
    wire         ol_busy, ol_done;
    prim_out_t   ol_prim; prim_ack_t ol_ack;
    object_list_parser u_ol (.clk(clk),.reset(reset),.start(ol_start),
        .list_ptr(ol_list_ptr),.busy(ol_busy),.done(ol_done),.prim(ol_prim),.ack(ol_ack),
        .dreq(ol_dreq),.dresp(ol_dresp));

    reg              it_start; objlist_entry_t it_entry; entry_type_e it_etype;
    wire             it_busy;
    triangle_out_t   it_trio; triangle_ack_t it_ack;
    isp_primitive_iterator u_it (.clk(clk),.reset(reset),.start(it_start),
        .intensity_shadow(regs.fpu_shad_scale.intensity_shadow),
        .param_base(param_base),.entry_type(it_etype),.entry(it_entry),.busy(it_busy),
        .trio(it_trio),.ack(it_ack),.dreq(pr_dreq),.dresp(pr_dresp));

    // -------------------- triple-buffered tile slots --------------------
    // slot_state lifecycle: FREE -> ISP -> TSPRDY -> TSPRUN -> WRRDY -> FREE.
    // A SINGLE arbiter (below) owns slot_state[]; the three engines drive 1-cycle
    // request pulses (each carries the slot index) so there is exactly one driver.
    localparam SL_FREE=0, SL_ISP=1, SL_TSPRDY=2, SL_TSPRUN=3, SL_WRRDY=4, SL_WRBUSY=5;
    reg [2:0]  slot_state [0:NSLOT-1];
    reg [5:0]  slot_tx [0:NSLOT-1];
    reg [5:0]  slot_ty [0:NSLOT-1];
    reg [31:0] dt_depth [0:NSLOT-1][0:NPIX-1];
    reg [31:0] dt_tag   [0:NSLOT-1][0:NPIX-1];
    reg [31:0] col_buf  [0:NSLOT-1][0:NPIX-1];

    // -------------------- CENTRAL SCHEDULER --------------------
    // The scheduler is the SOLE owner of slot_state[]. It grants exactly one
    // slot to each engine (grant + slot index), advances slot_state on grant,
    // and reclaims the slot when the engine pulses its *_fin. Engines NEVER read
    // slot_state - this makes all transitions race-free (single writer).
    //
    // Grants (scheduler -> engine): held stable while the engine owns the slot.
    reg        isp_grant; reg [1:0] isp_gslot;   // ISP fills this slot
    reg        tsp_grant; reg [1:0] tsp_gslot;   // TSP shades this slot
    reg        wr_grant;  reg [1:0] wr_gslot;    // writeout copies this slot
    // Finish pulses (engine -> scheduler): 1-cycle when the engine is done.
    reg        isp_fin, tsp_fin, wr_fin;
    // ISP finished consuming the whole region array (no more tiles).
    reg        isp_no_more;

    integer    si;
    reg [1:0]  fs;                                // scratch: found free/ready slot
    always @(posedge clk) begin
        if (reset) begin
            for (si=0; si<NSLOT; si=si+1) slot_state[si] <= SL_FREE;
            isp_grant<=0; tsp_grant<=0; wr_grant<=0;
        end else begin
            // ---- ISP grant: idle grant a FREE slot if tiles remain ----
            if (!isp_grant && !isp_no_more) begin
                if      (slot_state[0]==SL_FREE) fs=2'd0;
                else if (slot_state[1]==SL_FREE) fs=2'd1;
                else if (slot_state[2]==SL_FREE) fs=2'd2;
                else                             fs=2'd3;
                if (fs!=2'd3) begin
                    isp_gslot<=fs; slot_state[fs]<=SL_ISP; isp_grant<=1'b1;
                end
            end else if (isp_fin) begin
                slot_state[isp_gslot] <= SL_TSPRDY;   // hand to TSP
                isp_grant <= 1'b0;
            end

            // ---- TSP grant: idle grant a TSPRDY slot ----
            if (!tsp_grant) begin
                if      (slot_state[0]==SL_TSPRDY) fs=2'd0;
                else if (slot_state[1]==SL_TSPRDY) fs=2'd1;
                else if (slot_state[2]==SL_TSPRDY) fs=2'd2;
                else                               fs=2'd3;
                if (fs!=2'd3) begin
                    tsp_gslot<=fs; slot_state[fs]<=SL_TSPRUN; tsp_grant<=1'b1;
                end
            end else if (tsp_fin) begin
                slot_state[tsp_gslot] <= SL_WRRDY;    // hand to writeout
                tsp_grant <= 1'b0;
            end

            // ---- writeout grant: idle grant a WRRDY slot ----
            if (!wr_grant) begin
                if      (slot_state[0]==SL_WRRDY) fs=2'd0;
                else if (slot_state[1]==SL_WRRDY) fs=2'd1;
                else if (slot_state[2]==SL_WRRDY) fs=2'd2;
                else                              fs=2'd3;
                if (fs!=2'd3) begin
                    wr_gslot<=fs; slot_state[fs]<=SL_WRBUSY; wr_grant<=1'b1;
                end
            end else if (wr_fin) begin
                slot_state[wr_gslot] <= SL_FREE;      // recycle
                wr_grant <= 1'b0;
            end
        end
    end

    (* verilator public_flat_rw *) reg [31:0] fb [0:640*480-1];

    // int -> float (tile origin)
    function automatic [31:0] i2f(input [15:0] v);
        integer i, p; reg [38:0] m;
        begin
            p = -1;
            for (i = 0; i < 16; i = i + 1) if (v[i]) p = i;
            if (p < 0) i2f = 32'd0;
            else begin m = {23'd0, v} << (23 - p); i2f = {1'b0, 8'(127 + p), m[22:0]}; end
        end
    endfunction

    // ===================================================================
    // ISP STAGE (engine A): owns slot_isp. Region/objlist/primitive walk +
    // isp_setup_min + streamed isp_raster_line into dt_depth[slot_isp]/dt_tag.
    // ===================================================================
    wire [1:0]  slot_isp = isp_gslot;  // ISP always renders into its granted slot
    reg  [5:0]  isp_tx, isp_ty;
    reg  [31:0] t_xbase, t_ybase;

    // isp_setup. isp_word_su feeds the SETUP unit (triangle N+1); isp_word is the
    // ACTIVE raster triangle's isp (N) used by the depth compare / tag write.
    reg         isp_start; reg [31:0] isp_word, isp_word_su;
    reg  [31:0] t_x1,t_y1,t_z1, t_x2,t_y2,t_z2, t_x3,t_y3,t_z3;
    reg  [31:0] tri_tag, su_tag;
    wire        isp_done, isp_sgn_neg, isp_cull;
    wire [4:0]  w_bx0, w_bx1, w_by0, w_by1;   // tile-local bbox from setup
    wire [31:0] w_dx12,w_dx23,w_dx31,w_dx41, w_dy12,w_dy23,w_dy31,w_dy41;
    wire [31:0] w_c1,w_c2,w_c3,w_c4, w_ddx,w_ddy,w_cinvw;
    isp_setup_min u_isp (
        .clk(clk), .reset(reset), .start(isp_start), .done(isp_done), .isp_word(isp_word_su),
        .x1(t_x1),.y1(t_y1),.z1(t_z1),.x2(t_x2),.y2(t_y2),.z2(t_z2),.x3(t_x3),.y3(t_y3),.z3(t_z3),
        .xbase(t_xbase), .ybase(t_ybase), .sgn_neg(isp_sgn_neg), .cull(isp_cull),
        .dx12(w_dx12),.dx23(w_dx23),.dx31(w_dx31),.dx41(w_dx41),
        .dy12(w_dy12),.dy23(w_dy23),.dy31(w_dy31),.dy41(w_dy41),
        .c1(w_c1),.c2(w_c2),.c3(w_c3),.c4(w_c4),.ddx_invw(w_ddx),.ddy_invw(w_ddy),.c_invw(w_cinvw),
        .bx0(w_bx0),.bx1(w_bx1),.by0(w_by0),.by1(w_by1));

    reg [31:0] isp_dx12,isp_dx23,isp_dx31,isp_dx41;
    reg [31:0] isp_dy12,isp_dy23,isp_dy31,isp_dy41;
    reg [31:0] isp_c1,isp_c2,isp_c3,isp_c4;
    reg [31:0] isp_ddx_invw, isp_ddy_invw, isp_c_invw;

    // streamed rasterizer. HW depth does a full 32-px line/clock (DSP-heavy on
    // fabric, so synth keeps 8); Verilator sim uses 32 = whole line/clock so the
    // sweep is 32 cyc/tri instead of 128.
    localparam integer RAS_LANES = 8;
    reg  [4:0]  ras_y, ras_x;
    reg  [4:0]  rbx0, rbx1, rby1;   // active bbox sweep bounds (chunk-aligned x)
    reg  [4:0]  st_a;                    // ISP engine state
    wire        ras_in_valid;
    wire        ras_out_valid;
    wire [RAS_LANES-1:0]    ras_inside;
    wire [32*RAS_LANES-1:0] ras_invw_flat;
    wire [4:0]  ras_ox, ras_oy;
    function [31:0] ras_invw(input integer lane); ras_invw = ras_invw_flat[32*lane +: 32]; endfunction

    isp_raster_line #(.LANES(RAS_LANES)) u_line (
        .clk(clk), .reset(reset), .in_valid(ras_in_valid), .y(ras_y), .x_base(ras_x),
        .c1(isp_c1),.c2(isp_c2),.c3(isp_c3),.c4(isp_c4),
        .dx12(isp_dx12),.dx23(isp_dx23),.dx31(isp_dx31),.dx41(isp_dx41),
        .dy12(isp_dy12),.dy23(isp_dy23),.dy31(isp_dy31),.dy41(isp_dy41),
        .ddx(isp_ddx_invw),.ddy(isp_ddy_invw),.c_invw(isp_c_invw),
        .out_valid(ras_out_valid),.inside_mask(ras_inside),.invw_flat(ras_invw_flat),
        .out_x(ras_ox),.out_y(ras_oy));

    wire [2:0] depth_mode = isp_word[31:29];
    wire       zwrite_dis = isp_word[26];
    wire [RAS_LANES-1:0] ras_pass;
    generate
      for (gi_tex = 0; gi_tex < RAS_LANES; gi_tex = gi_tex + 1) begin : dcmp
        isp_depth_cmp u_cmp (.mode(depth_mode),
            .nw(ras_invw_flat[32*gi_tex +: 32]),
            .ob(dt_depth[slot_isp][{ras_oy, ras_ox + 5'(gi_tex)}]),.pass(ras_pass[gi_tex]));
      end
    endgenerate

    // ISP engine states. The producer (region -> objlist -> entry FIFO) runs
    // AHEAD; a concurrent iterator-consumer (it_cst) pops entries -> runs the
    // iterator -> pushes triangles into the triangle FIFO; the setup/raster
    // sub-FSMs pop that FIFO. All three overlap so the iterator's per-triangle
    // read latency is hidden behind setup+raster of earlier triangles.
    localparam A_IDLE=0, A_RA=2, A_STATE=3, A_OL_RUN=4,
               A_DRAIN=6,
               A_RA_ACK=11, A_RA_ACK_NEXT=12, A_DONE=13;
    // setup sub-FSM
    localparam SU_IDLE=0, SU_RUN=1;
    reg su_st;
    // raster sub-FSM
    localparam RS_IDLE=0, RS_RAS=1, RS_DRAIN=2;
    reg [1:0] rs_st;

    // ---- entry FIFO (object_list_parser -> iterator), depth 8 ----
    localparam integer EQ_N = 8;
    reg [1:0]       eq_etype [0:EQ_N-1];
    objlist_entry_t eq_entry [0:EQ_N-1];
    reg [3:0] eq_head, eq_tail; reg [4:0] eq_count;
    reg       eq_push, eq_pop;
    wire eq_full  = (eq_count == EQ_N);
    wire eq_empty = (eq_count == 0);
    localparam IT_IDLE=0, IT_RUN=1; reg it_cst;   // iterator-consumer FSM
    reg prim_seen;   // iterator pulsed prim_done for the current entry

    // ---- triangle FIFO (producer -> consumer), depth 8 ----
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

    // 1-deep pending-planes handoff (setup -> raster)
    reg        pend_valid;
    reg [31:0] pend_dx12,pend_dx23,pend_dx31,pend_dx41;
    reg [31:0] pend_dy12,pend_dy23,pend_dy31,pend_dy41;
    reg [31:0] pend_c1,pend_c2,pend_c3,pend_c4;
    reg [31:0] pend_ddx,pend_ddy,pend_cinvw, pend_isp, pend_tag;
    reg [4:0]  pend_bx0,pend_bx1,pend_by0,pend_by1;  // tile-local bounding box
    assign ras_in_valid = (rs_st == RS_RAS);

    // consumer fully idle: entry FIFO empty, iterator idle & not busy, setup +
    // raster + pend handoff all idle.
    wire consumer_idle = eq_empty && (it_cst==IT_IDLE) && !it_busy
                       && (su_st==SU_IDLE) && (rs_st==RS_IDLE) && !pend_valid;

    localparam integer NCHUNK = (TILE_W/RAS_LANES) * TILE_H;
    integer ras_inflight;
    integer tri_count, cull_count, tri_seen;
    integer ai, al;

    // ===================================================================
    // TSP STAGE (engine B): finds a SL_TSPRDY slot, shades all pixels into its
    // col_buf via the plane cache + tsp_setup_min + tsp_shade_pp.
    // ===================================================================
    wire [1:0]  slot_tsp = tsp_gslot;   // TSP always shades its granted slot
    reg  [5:0]  tsp_tx, tsp_ty;
    reg  [31:0] tt_xbase, tt_ybase;   // tile origin for THIS TSP tile

    // plane cache
    localparam integer PC_N = 64;
    reg            pc_valid [0:PC_N-1];
    reg [31:0]     pc_tag   [0:PC_N-1];
    reg [31:0]     pc_isp   [0:PC_N-1];
    reg [31:0]     pc_tsp   [0:PC_N-1];
    reg [31:0]     pc_tcw   [0:PC_N-1];
    reg [31:0]     pc_ddx   [0:PC_N-1][0:9];
    reg [31:0]     pc_ddy   [0:PC_N-1][0:9];
    reg [31:0]     pc_c     [0:PC_N-1][0:9];

    reg [31:0] cur_isp, cur_tsp, cur_tcw;
    reg [31:0] cur_ddx [0:9]; reg [31:0] cur_ddy [0:9]; reg [31:0] cur_c [0:9];

    reg [9:0]  shp;
    reg [31:0] sh_tag, sh_invw;
    wire [5:0] sh_slot = sh_tag[8:3] ^ {3'b000, sh_tag[2:0]};
    // combinational fields of the CURRENT pixel's tag (stage-0 streaming lookup)
    wire [31:0] nx_tag  = dt_tag[slot_tsp][shp];
    wire [5:0]  nx_slot = nx_tag[8:3] ^ {3'b000, nx_tag[2:0]};
    wire [20:0] sh_po   = sh_tag[23:3];
    wire [2:0]  sh_skip = sh_tag[26:24];
    wire [2:0]  sh_toff = sh_tag[2:0];
    wire        sh_two_vol = sh_tag[27] & ~regs.fpu_shad_scale.intensity_shadow;
    wire [4:0]  sh_stride_w = 5'd3 + sh_skip * (sh_two_vol ? 5'd2 : 5'd1);
    wire [26:0] sh_stride_b = {sh_stride_w, 2'b00};

    // TSP param reader over ts$
    reg  [26:0] f_addr; reg f_go; reg [31:0] f_word; reg f_word_v; reg [2:0] f_sel;
    reg  [26:0] ts_laddr_r; reg ts_req_r;
    assign ts_creq.req = ts_req_r; assign ts_creq.laddr = ts_laddr_r;
    always @(posedge clk) begin
        f_word_v<=1'b0; ts_req_r<=1'b0;
        if (f_go) begin ts_req_r<=1'b1; ts_laddr_r<={5'd0,f_addr[26:5]}; f_sel<=f_addr[4:2]; end
        if (ts_cresp.ack) begin f_word<=ts_cresp.rdata[32*f_sel +: 32]; f_word_v<=1'b1; end
        if (reset) ts_req_r<=1'b0;
    end

    reg [31:0] fv_x[0:2], fv_y[0:2], fv_z[0:2];
    reg [31:0] fv_u[0:2], fv_v[0:2], fv_col[0:2], fv_ofs[0:2];
    reg [1:0]  fv_i; reg [2:0] fv_fld;
    reg [26:0] f_rec, f_vtx, f_ptr;
    wire f_texture = cur_isp[ISP_TEXTURE_BIT];
    wire f_offset  = cur_isp[ISP_OFFSET_BIT];
    wire f_gouraud = cur_isp[ISP_GOURAUD_BIT];
    wire f_uv16    = cur_isp[ISP_UV16_BIT];

    reg         tsp_start;
    wire        tsp_done, tsp_pvalid; wire [3:0] tsp_pidx;
    wire [31:0] tsp_pddx, tsp_pddy, tsp_pc;
    tsp_setup_min u_tsp (
        .clk(clk), .reset(reset), .start(tsp_start), .done(tsp_done),
        .gouraud(f_gouraud), .texture(f_texture), .offset(f_offset),
        .x1(fv_x[0]),.y1(fv_y[0]),.z1(fv_z[0]),.x2(fv_x[1]),.y2(fv_y[1]),.z2(fv_z[1]),
        .x3(fv_x[2]),.y3(fv_y[2]),.z3(fv_z[2]),
        .xbase(tt_xbase), .ybase(tt_ybase),
        .u1(fv_u[0]),.v1(fv_v[0]),.u2(fv_u[1]),.v2(fv_v[1]),.u3(fv_u[2]),.v3(fv_v[2]),
        .col1(fv_col[0]),.col2(fv_col[1]),.col3(fv_col[2]),
        .ofs1(fv_ofs[0]),.ofs2(fv_ofs[1]),.ofs3(fv_ofs[2]),
        .plane_valid(tsp_pvalid), .plane_idx(tsp_pidx), .o_ddx(tsp_pddx),.o_ddy(tsp_pddy),.o_c(tsp_pc));

    reg          pp_in_valid; reg [9:0] pp_in_id; reg [4:0] pp_px, pp_py; reg [31:0] pp_invw;
    reg  [31:0]  pp_tsp, pp_tcw; reg pp_ptex, pp_pofs;
    reg  [31:0]  pp_ddx [0:9]; reg [31:0] pp_ddy [0:9]; reg [31:0] pp_c [0:9];
    wire         pp_stall, pp_out_valid; wire [9:0] pp_out_id; wire [31:0] pp_out_argb;
    wire         pp_accept = pp_in_valid && !pp_stall;  // pipe consumes this edge
    tsp_shade_pp #(.IDW(10)) u_shade (
        .clk(clk),.reset(reset),
        .in_valid(pp_in_valid),.in_id(pp_in_id),.px(pp_px),.py(pp_py),.invw_in(pp_invw),
        .in_ddx(pp_ddx),.in_ddy(pp_ddy),.in_c(pp_c),
        .tsp(pp_tsp),.tcw(pp_tcw),.text_ctrl(regs.text_control[4:0]),
        .pp_texture(pp_ptex),.pp_offset(pp_pofs),
        .out_valid(pp_out_valid),.out_id(pp_out_id),.out_argb(pp_out_argb),.stall(pp_stall),
        .tc_req(pp_tc_req),.tc_resp(pp_tc_resp),.vq_req(pp_vq_req),.vq_resp(pp_vq_resp));

    localparam B_STREAM=14;
    localparam B_IDLE=0, B_GETSLOT=1, B_PIX=2, B_LOOK=3,
               B_FH_ISP=4, B_FH_ISPW=5, B_FH_TSPW=6, B_FH_TCWW=7,
               B_FV_RD=8, B_FV_W=9, B_RUN=10, B_PRESENT=11, B_DRAIN=12, B_WAITDROP=13;
    reg [3:0] st_b;
    localparam [2:0] FLD_X=0, FLD_Y=1, FLD_Z=2, FLD_UV16=3, FLD_U=4, FLD_V=5, FLD_COL=6, FLD_OFS=7;
    integer sh_out_n, miss_count, hit_count, bj;
    // TSP-engine cycle breakdown (whole run)
    integer cyc_b_total;   // cycles st_b is doing shade work (not idle/getslot)
    integer cyc_b_present; // offering a pixel & accepted (throughput cycles)
    integer cyc_b_stall;   // offering but pipe stalled (texture fetch busy)
    integer cyc_b_miss;    // in the miss fetch/setup path (B_FH_*/B_FV_*/B_RUN)
    integer cyc_b_drain;   // B_DRAIN waiting for the pipe to empty
    integer cyc_b_idle;    // B_IDLE/B_GETSLOT/B_WAITDROP (no granted slot)

    // ===================================================================
    // WRITEOUT STAGE (engine C): finds a SL_WRRDY slot, copies col_buf -> fb.
    // ===================================================================
    wire [1:0]  slot_wr = wr_gslot;    // writeout copies its granted slot
    localparam C_IDLE=0, C_GETSLOT=1, C_COPY=2, C_WAITDROP=3;
    reg [1:0] st_c;
    integer wpx, wpy;

    // done bookkeeping: overall render finishes when ISP has consumed all tiles
    // AND all slots have drained back to FREE.
    reg isp_finished;

    // ==================== ISP ENGINE ====================
    always @(posedge clk) begin
        if (reset) begin
            st_a<=A_IDLE; ra_start<=0; ol_start<=0; it_start<=0; isp_start<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            ras_inflight<=0; tri_count<=0; cull_count<=0; tri_seen<=0;
            isp_finished<=0; isp_fin<=0; isp_no_more<=0;
            su_st<=SU_IDLE; rs_st<=RS_IDLE;
            pend_valid<=0; prim_seen<=0;
            fq_head<=0; fq_tail<=0; fq_count<=0;
            eq_head<=0; eq_tail<=0; eq_count<=0; it_cst<=IT_IDLE;
        end else begin
            ra_start<=0; ol_start<=0; it_start<=0; isp_start<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            isp_fin<=0;
            eq_push = 1'b0;

            // streamed rasterizer consumer -> dt_depth/dt_tag of slot_isp
            if (ras_out_valid) begin
                for (al=0; al<RAS_LANES; al=al+1) begin
                    /* verilator lint_off WIDTH */
                    if (ras_inside[al] && ras_pass[al]) begin
                        if (!zwrite_dis)
                            dt_depth[slot_isp][{27'd0,ras_oy}*TILE_W + {27'd0,ras_ox} + al] = ras_invw(al);
                        dt_tag[slot_isp][{27'd0,ras_oy}*TILE_W + {27'd0,ras_ox} + al] = tri_tag;
                    end
                    /* verilator lint_on WIDTH */
                end
            end
            ras_inflight <= ras_inflight + (ras_in_valid?1:0) - (ras_out_valid?1:0);

            case (st_a)
            A_IDLE: if (go) begin ra_start<=1; st_a<=A_RA; end

            // Wait for the region parser to present a state AND for the scheduler
            // to have granted us a slot (isp_grant). ISP renders into isp_gslot.
            A_RA: begin
                if (ra_tiles_parsed) begin
                    isp_finished<=1; isp_no_more<=1; st_a<=A_DONE;
                end else if (ra_out.list_ready && isp_grant) begin
                    isp_tx <= ra_out.tile_x; isp_ty <= ra_out.tile_y;
                    slot_tx[slot_isp] <= ra_out.tile_x; slot_ty[slot_isp] <= ra_out.tile_y;
                    st_a<=A_STATE;
                end
            end

            A_STATE: begin
                t_xbase <= i2f({10'd0, isp_tx} * 16'd32);
                t_ybase <= i2f({10'd0, isp_ty} * 16'd32);
                $display("[ISP tile %0d,%0d slot%0d state=%b]", isp_tx, isp_ty, slot_isp, ra_out.state);
                case (ra_out.state)
                RSTATE_CLEAR: begin
                    for (ai=0; ai<NPIX; ai=ai+1) begin
                        dt_depth[slot_isp][ai] = regs.isp_backgnd_d;
                        dt_tag[slot_isp][ai]   = regs.isp_backgnd_t;
                    end
                    ra_ack.list_done<=1'b1; st_a<=A_RA_ACK;
                end
                RSTATE_OP, RSTATE_PT, RSTATE_TR: begin
                    ol_list_ptr<=ra_out.list_ptr; ol_start<=1'b1; st_a<=A_OL_RUN;
                end
                RSTATE_FLUSH: begin
                    // ISP done for this tile: tell the scheduler (isp_fin) which
                    // hands the slot to TSP and drops our grant. Go wait for the
                    // next grant in A_RA.
                    isp_fin <= 1'b1;
                    ra_ack.list_done<=1'b1; st_a<=A_RA_ACK_NEXT;
                end
                default: begin ra_ack.list_done<=1'b1; st_a<=A_RA_ACK; end
                endcase
            end

            // A_OL_RUN: PRODUCER - push each OL entry into the entry FIFO (eq) and
            // ack the OL parser so it decodes the next entry ahead. STRIP/TRI are
            // queued; QUAD is skipped. On list end (ol_done) -> BARRIER (A_DRAIN).
            // The iterator CONSUMER (it_cst) runs concurrently below, popping eq
            // into the triangle FIFO independent of st_a.
            A_OL_RUN: begin
                if (ol_done) st_a<=A_DRAIN;
                else if (ol_prim.entry_ready && !ol_ack.entry_done) begin
                    if (ol_prim.entry_type==ENT_STRIP || ol_prim.entry_type==ENT_TRI) begin
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
            A_DRAIN: if (fq_empty && consumer_idle) begin
                ra_ack.list_done<=1'b1; st_a<=A_RA_ACK;
            end

            A_RA_ACK: st_a<=A_RA;                       // same granted slot, next state of same tile
            // tile done: wait for the scheduler to consume isp_fin (drop the old
            // grant) before A_RA looks for the next grant, so we don't re-render
            // the next tile into the just-handed-off slot.
            A_RA_ACK_NEXT: if (!isp_grant) st_a<=A_RA;
            A_DONE: st_a<=A_DONE;                       // ISP idle
            default: st_a<=A_IDLE;
            endcase

            // ==== ITERATOR CONSUMER: entry FIFO -> iterator -> tri FIFO ====
            // Runs independent of st_a. IT_IDLE: pop an entry, start the iterator.
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
                end
                if (prim_seen && !it_busy) it_cst <= IT_IDLE;   // entry finished
            end
            endcase

            // ============ CONSUMER: FIFO -> setup -> raster ============
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
                isp_start <= 1'b1; su_st <= SU_RUN;
            end
            SU_RUN: if (isp_done) begin
                if (isp_cull) cull_count <= cull_count + 1;
                else begin
                    pend_dx12<=w_dx12;pend_dx23<=w_dx23;pend_dx31<=w_dx31;pend_dx41<=w_dx41;
                    pend_dy12<=w_dy12;pend_dy23<=w_dy23;pend_dy31<=w_dy31;pend_dy41<=w_dy41;
                    pend_c1<=w_c1;pend_c2<=w_c2;pend_c3<=w_c3;pend_c4<=w_c4;
                    pend_ddx<=w_ddx;pend_ddy<=w_ddy;pend_cinvw<=w_cinvw;
                    pend_isp<=isp_word_su; pend_tag<=su_tag; pend_valid<=1'b1;
                    // tile-local bounding box, computed by isp_setup_min.
                    pend_bx0<=w_bx0; pend_bx1<=w_bx1; pend_by0<=w_by0; pend_by1<=w_by1;
                end
                su_st <= SU_IDLE;
            end
            endcase

            // ---- RASTER: pend_* -> active planes -> BOUNDING-BOX sweep ----
            // Only sweep the chunks/rows the triangle's tile-local bbox covers.
            case (rs_st)
            RS_IDLE: if (pend_valid) begin
                isp_dx12<=pend_dx12;isp_dx23<=pend_dx23;isp_dx31<=pend_dx31;isp_dx41<=pend_dx41;
                isp_dy12<=pend_dy12;isp_dy23<=pend_dy23;isp_dy31<=pend_dy31;isp_dy41<=pend_dy41;
                isp_c1<=pend_c1;isp_c2<=pend_c2;isp_c3<=pend_c3;isp_c4<=pend_c4;
                isp_ddx_invw<=pend_ddx;isp_ddy_invw<=pend_ddy;isp_c_invw<=pend_cinvw;
                isp_word<=pend_isp; tri_tag<=pend_tag;
                pend_valid<=1'b0; tri_count<=tri_count+1;
                // chunk-aligned x range + row range from the bbox
                rbx0 <= pend_bx0 & 5'(~(RAS_LANES-1));
                rbx1 <= pend_bx1 & 5'(~(RAS_LANES-1));
                rby1 <= pend_by1;
                ras_y <= pend_by0;
                ras_x <= pend_bx0 & 5'(~(RAS_LANES-1));
                rs_st<=RS_RAS;
            end
            RS_RAS: begin
                if (ras_x==rbx1) begin
                    ras_x<=rbx0;
                    if (ras_y==rby1) rs_st<=RS_DRAIN; else ras_y<=ras_y+5'd1;
                end else ras_x<=ras_x+5'(RAS_LANES);
            end
            RS_DRAIN: if (ras_inflight==0 && !ras_in_valid && !ras_out_valid) rs_st<=RS_IDLE;
            endcase

            // ---- FIFO count maintenance (single update; push/pop may coincide) ----
            fq_count <= fq_count + (fifo_push ? 5'd1 : 5'd0) - (fifo_pop ? 5'd1 : 5'd0);
            eq_count <= eq_count + (eq_push  ? 5'd1 : 5'd0) - (eq_pop   ? 5'd1 : 5'd0);
        end
    end

    // ==================== TSP ENGINE ====================
    always @(posedge clk) begin
        if (reset) begin
            st_b<=B_IDLE; tsp_start<=0; pp_in_valid<=0; f_go<=0; tsp_fin<=0;
            sh_out_n<=0; miss_count<=0; hit_count<=0;
            cyc_b_total<=0; cyc_b_present<=0; cyc_b_stall<=0; cyc_b_miss<=0;
            cyc_b_drain<=0; cyc_b_idle<=0;
            for (bj=0; bj<PC_N; bj=bj+1) pc_valid[bj] <= 1'b0;
        end else begin
            tsp_start<=0; pp_in_valid<=0; f_go<=0; tsp_fin<=0;

            // ---- TSP-engine cycle breakdown ----
            if (st_b==B_IDLE || st_b==B_GETSLOT || st_b==B_WAITDROP)
                cyc_b_idle <= cyc_b_idle + 1;
            else begin
                cyc_b_total <= cyc_b_total + 1;
                if (st_b==B_DRAIN)          cyc_b_drain   <= cyc_b_drain + 1;
                else if (st_b==B_STREAM) begin
                    if (pp_accept)          cyc_b_present <= cyc_b_present + 1;
                    else if (pp_in_valid)   cyc_b_stall   <= cyc_b_stall + 1;
                end
                else                        cyc_b_miss    <= cyc_b_miss + 1; // FH_/FV_/RUN
            end

            // shade pipeline consumer -> col_buf[slot_tsp]
            if (pp_out_valid && !pp_stall) begin
                col_buf[slot_tsp][pp_out_id] = pp_out_argb;
                sh_out_n <= sh_out_n + 1;
            end

            // plane stream capture (whenever tsp_setup emits a plane)
            if (tsp_pvalid) begin
                cur_ddx[tsp_pidx]=tsp_pddx; cur_ddy[tsp_pidx]=tsp_pddy; cur_c[tsp_pidx]=tsp_pc;
                pc_ddx[sh_slot][tsp_pidx]=tsp_pddx; pc_ddy[sh_slot][tsp_pidx]=tsp_pddy; pc_c[sh_slot][tsp_pidx]=tsp_pc;
            end

            case (st_b)
            B_IDLE: st_b<=B_GETSLOT;

            // wait for the scheduler to grant a TSPRDY slot (tsp_grant). Reset
            // per-tile shade state + invalidate the tile-local plane cache.
            B_GETSLOT: if (tsp_grant) begin
                for (bj=0; bj<PC_N; bj=bj+1) pc_valid[bj] <= 1'b0;
                shp<=10'd0; sh_out_n<=0;
                tsp_tx <= slot_tx[tsp_gslot]; tsp_ty <= slot_ty[tsp_gslot];
                tt_xbase <= i2f({10'd0, slot_tx[tsp_gslot]} * 16'd32);
                tt_ybase <= i2f({10'd0, slot_ty[tsp_gslot]} * 16'd32);
                $display("[TSP shade tile %0d,%0d slot%0d]", slot_tx[tsp_gslot], slot_ty[tsp_gslot], tsp_gslot);
                st_b<=B_STREAM;
            end

            // STREAMING PRODUCER: plane-cache lookup is stage 0 of the shader
            // pipeline. Each clock we look up pixel shp's tag COMBINATIONALLY and,
            // on a hit, drive its planes/invw straight into tsp_shade_pp with
            // in_valid - 1 pixel/clock. shp advances only when the pipe accepts
            // (pp_accept), so a texel stall holds the pixel; a MISS pauses the
            // stream to fetch the record + run tsp_setup (filling the cache), then
            // re-enters B_STREAM at the same shp (now a hit).
            // STREAMING PRODUCER (stage 0 = plane-cache lookup). `shp` is the NEXT
            // pixel to LOAD; the pixel currently offered to the pipe lives in
            // pp_in_id (with its planes in pp_*). We load a new pixel exactly once,
            // when the pipe is free to take one (nothing offered yet, or the
            // current offer was accepted this cycle) - so no pixel is presented
            // twice. On load we advance shp. When the last pixel (id 1023) is
            // accepted, drain. A cache MISS pauses the stream to fetch+setup, then
            // re-enters B_STREAM at the same shp (now a hit). 1 pixel/clock on hits.
            B_STREAM: begin
                // NOTE: pp_in_valid defaults to 0 at the top of the block, so we
                // must RE-ASSERT it every cycle we are holding an offered pixel.
                if (pp_accept && pp_in_id == 10'd1023) begin
                    // last pixel consumed: done offering (leave valid at its 0 dflt).
                    st_b <= B_DRAIN;
                end else if (!pp_in_valid || pp_accept) begin
                    // pipe is free to accept a new pixel this cycle: look up shp.
                    sh_invw <= dt_depth[slot_tsp][shp];
                    if (pc_valid[nx_slot] && pc_tag[nx_slot]==nx_tag) begin
                        // HIT: offer pixel shp, advance to the next.
                        hit_count <= hit_count + 1;
                        pp_in_valid <= 1'b1;
                        pp_in_id <= shp; pp_px <= shp[4:0]; pp_py <= shp[9:5];
                        pp_invw <= dt_depth[slot_tsp][shp];
                        pp_tsp <= pc_tsp[nx_slot]; pp_tcw <= pc_tcw[nx_slot];
                        pp_ptex <= pc_isp[nx_slot][ISP_TEXTURE_BIT];
                        pp_pofs <= pc_isp[nx_slot][ISP_OFFSET_BIT];
                        for (bj=0;bj<10;bj=bj+1) begin pp_ddx[bj]<=pc_ddx[nx_slot][bj]; pp_ddy[bj]<=pc_ddy[nx_slot][bj]; pp_c[bj]<=pc_c[nx_slot][bj]; end
                        shp <= shp + 10'd1;
                    end else begin
                        // MISS: stop offering (valid stays 0), fetch + tsp_setup.
                        miss_count<=miss_count+1;
                        sh_tag <= nx_tag;
                        f_rec<=param_base + {4'd0, nx_tag[23:3], 2'b00};
                        st_b<=B_FH_ISP;
                    end
                end else begin
                    // holding an offered-but-not-yet-accepted pixel (pipe stalled):
                    // re-assert valid + keep pp_* stable so the pixel isn't dropped.
                    pp_in_valid <= 1'b1;
                end
            end
            B_FH_ISP:  begin f_addr<=f_rec; f_go<=1'b1; st_b<=B_FH_ISPW; end
            B_FH_ISPW: if (f_word_v) begin cur_isp=f_word; f_addr<=f_rec+27'd4; f_go<=1'b1; st_b<=B_FH_TSPW; end
            B_FH_TSPW: if (f_word_v) begin cur_tsp=f_word; f_addr<=f_rec+27'd8; f_go<=1'b1; st_b<=B_FH_TCWW; end
            B_FH_TCWW: if (f_word_v) begin
                cur_tcw=f_word;
                f_vtx <= f_rec + (sh_two_vol?27'd20:27'd12) + {22'd0,sh_toff}*sh_stride_b;
                fv_i<=2'd0; fv_fld<=FLD_X;
                for (bj=0;bj<3;bj=bj+1) begin fv_u[bj]=32'd0; fv_v[bj]=32'd0; fv_col[bj]=32'd0; fv_ofs[bj]=32'd0; end
                st_b<=B_FV_RD;
            end
            B_FV_RD: begin
                case (fv_fld)
                FLD_X: f_ptr=f_vtx; FLD_Y: f_ptr=f_vtx+27'd4; FLD_Z: f_ptr=f_vtx+27'd8;
                FLD_UV16,FLD_U: f_ptr=f_vtx+27'd12; FLD_V: f_ptr=f_vtx+27'd16;
                FLD_COL: f_ptr=f_vtx+27'd12+(f_texture?(f_uv16?27'd4:27'd8):27'd0);
                default: f_ptr=f_vtx+27'd16+(f_texture?(f_uv16?27'd4:27'd8):27'd0);
                endcase
                f_addr<=f_ptr; f_go<=1'b1; st_b<=B_FV_W;
            end
            B_FV_W: if (f_word_v) begin
                case (fv_fld)
                FLD_X: begin fv_x[fv_i]=f_word; fv_fld<=FLD_Y; st_b<=B_FV_RD; end
                FLD_Y: begin fv_y[fv_i]=f_word; fv_fld<=FLD_Z; st_b<=B_FV_RD; end
                FLD_Z: begin fv_z[fv_i]=f_word;
                    if (f_texture) begin fv_fld<=f_uv16?FLD_UV16:FLD_U; st_b<=B_FV_RD; end
                    else begin fv_fld<=FLD_COL; st_b<=B_FV_RD; end
                end
                FLD_UV16: begin fv_u[fv_i]={f_word[31:16],16'd0}; fv_v[fv_i]={f_word[15:0],16'd0}; fv_fld<=FLD_COL; st_b<=B_FV_RD; end
                FLD_U: begin fv_u[fv_i]=f_word; fv_fld<=FLD_V; st_b<=B_FV_RD; end
                FLD_V: begin fv_v[fv_i]=f_word; fv_fld<=FLD_COL; st_b<=B_FV_RD; end
                FLD_COL: begin fv_col[fv_i]=f_word;
                    if (f_offset) begin fv_fld<=FLD_OFS; st_b<=B_FV_RD; end
                    else if (fv_i==2'd2) begin
                        for (bj=0;bj<10;bj=bj+1) begin cur_ddx[bj]=32'd0;cur_ddy[bj]=32'd0;cur_c[bj]=32'd0;
                            pc_ddx[sh_slot][bj]=32'd0;pc_ddy[sh_slot][bj]=32'd0;pc_c[sh_slot][bj]=32'd0; end
                        tsp_start<=1'b1; st_b<=B_RUN;
                    end else begin fv_i<=fv_i+2'd1; f_vtx<=f_vtx+sh_stride_b; fv_fld<=FLD_X; st_b<=B_FV_RD; end
                end
                default: begin fv_ofs[fv_i]=f_word;
                    if (fv_i==2'd2) begin
                        for (bj=0;bj<10;bj=bj+1) begin cur_ddx[bj]=32'd0;cur_ddy[bj]=32'd0;cur_c[bj]=32'd0;
                            pc_ddx[sh_slot][bj]=32'd0;pc_ddy[sh_slot][bj]=32'd0;pc_c[sh_slot][bj]=32'd0; end
                        tsp_start<=1'b1; st_b<=B_RUN;
                    end else begin fv_i<=fv_i+2'd1; f_vtx<=f_vtx+sh_stride_b; fv_fld<=FLD_X; st_b<=B_FV_RD; end
                end
                endcase
            end
            B_RUN: if (tsp_done) begin
                pc_valid[sh_slot]=1'b1; pc_tag[sh_slot]=sh_tag;
                pc_isp[sh_slot]=cur_isp; pc_tsp[sh_slot]=cur_tsp; pc_tcw[sh_slot]=cur_tcw;
                st_b<=B_STREAM;   // re-lookup shp (now a hit) and resume streaming
            end
            B_PRESENT: if (!pp_stall) begin
                pp_in_valid<=1'b1; pp_in_id<=shp; pp_px<=shp[4:0]; pp_py<=shp[9:5]; pp_invw<=sh_invw;
                pp_tsp<=cur_tsp; pp_tcw<=cur_tcw; pp_ptex<=cur_isp[ISP_TEXTURE_BIT]; pp_pofs<=cur_isp[ISP_OFFSET_BIT];
                for (bj=0;bj<10;bj=bj+1) begin pp_ddx[bj]<=cur_ddx[bj]; pp_ddy[bj]<=cur_ddy[bj]; pp_c[bj]<=cur_c[bj]; end
                if (shp==10'd1023) st_b<=B_DRAIN; else begin shp<=shp+10'd1; st_b<=B_PIX; end
            end
            B_DRAIN: if (sh_out_n >= 1024) begin
                tsp_fin <= 1'b1;                 // scheduler hands slot to writeout
                st_b<=B_WAITDROP;
            end
            // wait for the scheduler to consume tsp_fin (drop the grant) before
            // looking for the next TSPRDY slot.
            B_WAITDROP: if (!tsp_grant) st_b<=B_GETSLOT;
            default: st_b<=B_GETSLOT;
            endcase
        end
    end

    // ==================== WRITEOUT ENGINE ====================
    reg [4:0] wr_row;                    // tile row 0..31 being copied
    always @(posedge clk) begin
        if (reset) begin
            st_c<=C_IDLE; done<=0; wr_fin<=0;
        end else begin
            done<=0; wr_fin<=0;
            case (st_c)
            C_IDLE: st_c<=C_GETSLOT;
            // wait for a granted WRRDY slot; else, when everything is idle and
            // drained after ISP finished, signal overall done.
            C_GETSLOT: begin
                if (wr_grant) begin
                    wr_row <= 5'd0; st_c<=C_COPY;
                end else if (isp_finished && !isp_grant && !tsp_grant &&
                         slot_state[0]==SL_FREE && slot_state[1]==SL_FREE && slot_state[2]==SL_FREE) begin
                    $display("=== done ===");
                    $display("=== TSP engine: total=%0d present=%0d stall=%0d miss=%0d drain=%0d idle=%0d (hits=%0d misses=%0d) ===",
                             cyc_b_total, cyc_b_present, cyc_b_stall, cyc_b_miss,
                             cyc_b_drain, cyc_b_idle, hit_count, miss_count);
                    done<=1'b1; st_c<=C_IDLE;
                end
            end
            // copy one 32-pixel tile row per cycle into the 640x480 framebuffer
            C_COPY: begin
                for (wpx=0; wpx<TILE_W; wpx=wpx+1) begin
                    /* verilator lint_off WIDTH */
                    wpy = {26'd0, slot_ty[slot_wr]}*32 + wr_row;
                    if (({26'd0,slot_tx[slot_wr]}*32 + wpx) < 640 && wpy < 480)
                        fb[wpy*640 + {26'd0,slot_tx[slot_wr]}*32 + wpx] =
                            col_buf[slot_wr][wr_row*TILE_W + wpx];
                    /* verilator lint_on WIDTH */
                end
                if (wr_row == 5'(TILE_H-1)) begin
                    wr_fin <= 1'b1;   // scheduler frees the slot
                    $display("[WR tile %0d,%0d slot%0d]", slot_tx[slot_wr], slot_ty[slot_wr], slot_wr);
                    st_c<=C_WAITDROP;
                end else wr_row <= wr_row + 5'd1;
            end
            // wait for the scheduler to consume wr_fin (drop the grant)
            C_WAITDROP: if (!wr_grant) st_c<=C_GETSLOT;
            default: st_c<=C_IDLE;
            endcase
        end
    end
endmodule

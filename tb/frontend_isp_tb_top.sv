// frontend_isp_tb_top - frontend_tb_top + REAL ISP: triangle setup + rasterize
// with depth-test + CoreTag param-tag writes, exactly as in tile_engine_top's
// CMD_TRIANGLE_ISP_SETUP / CMD_TRIANGLE_ISP_RASTERIZE path:
//
//   region_array_parser -> object_list_parser -> isp_primitive_iterator
//     -> isp_setup_min (edge/invW planes, tile-local at the tile origin)
//     -> isp_raster_line (8 lanes/clk, 32x32 tile sweep)
//     -> depth compare (isp_depth_cmp, refsw DepthMode) -> {invW, CoreTag} write
//
// Region states:
//   CLEAR : depth/tag tile <= {ISP_BACKGND_D, ISP_BACKGND_T}  (bg CoreTag)
//   OP/PT/TR: walk the object list, setup+rasterize every strip triangle
//   FLUSH : copy the tile's 32x32 tag buffer into a 640x480 framebuffer at
//           (tile_x*32, tile_y*32); the C++ TB renders fb tags to output.bmp.
//
// The depth/tag tile store is a plain TB reg array (same RMW behavior as the
// top's banked tile_ram, without the banking).
//
module frontend_isp_tb_top import tsp_pkg::*; (
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

    // region port
    ddr_rd_req_t  ra_dreq; ddr_rd_resp_t ra_dresp;
    reg [63:0] ra_do; reg ra_dv;
    assign ra_dresp.busy=1'b0; assign ra_dresp.dout=ra_do; assign ra_dresp.dready=ra_dv;
    always @(posedge clk) begin ra_dv<=0; if(ra_dreq.rd) begin ra_do<=vram[ra_dreq.addr[19:0]]; ra_dv<=1; end end
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

    // -------------------- caches --------------------
    // Region parser keeps its 256-bit line cache; the OL parser and ISP iterator
    // read DDR DIRECTLY (own line buffers / burst) via ol_dreq / pr_dreq.
    cache_req256_t ra_creq;
    cache_resp256_t ra_cresp;
    data_cache256 u_ra_c (.clk(clk),.reset(reset),.creq(ra_creq),.cresp(ra_cresp),.dreq(ra_dreq),.dresp(ra_dresp));

    // -------------------- parsers --------------------
    reg          ra_start;
    wire         ra_busy, ra_tiles_parsed;
    region_out_t ra_out; region_ack_t ra_ack;
    region_array_parser u_ra (.clk(clk),.reset(reset),.start(ra_start),
        .region_base(region_base),.region_v1(region_v1),.busy(ra_busy),
        .tiles_parsed(ra_tiles_parsed),.rout(ra_out),.ack(ra_ack),
        .creq(ra_creq),.cresp(ra_cresp));

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

    // -------------------- depth/tag tile + 640x480 framebuffer --------------------
    localparam integer TILE_W = 32, TILE_H = 32;
    reg [31:0] dt_depth [0:TILE_W*TILE_H-1];   // invW depth per tile pixel
    reg [31:0] dt_tag   [0:TILE_W*TILE_H-1];   // CoreTag per tile pixel

    (* verilator public_flat_rw *) reg [31:0] fb [0:640*480-1];  // flushed tags

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
    // isp_word_su feeds the SETUP unit (triangle N+1); isp_word is the ACTIVE
    // raster triangle's isp (N), used by the depth compare / tag write. They are
    // distinct because setup runs one triangle ahead of the raster sweep.
    reg         isp_start;
    reg  [31:0] isp_word;                 // active (raster) triangle's isp
    reg  [31:0] isp_word_su;              // setup (next) triangle's isp
    reg  [31:0] t_x1,t_y1,t_z1, t_x2,t_y2,t_z2, t_x3,t_y3,t_z3;
    reg  [31:0] t_xbase, t_ybase;
    reg  [31:0] su_tag;                   // setup triangle's CoreTag
    reg  [31:0] tri_tag;                  // active (raster) triangle's CoreTag
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
    // combinational: issue a chunk every raster-sweep cycle, in phase with
    // ras_x/y (a registered pulse would lag and drop the first chunk per tile).
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

    // per-lane refsw DepthMode compare (isp_depth_cmp). Reads old depth at the
    // RESULT chunk coords (ras_ox,ras_oy) - the chunks stream out back-to-back,
    // so the result addresses trail the issue side by the pipeline latency.
    wire [RAS_LANES-1:0] ras_pass;
    generate
        for (genvar gd = 0; gd < RAS_LANES; gd = gd + 1) begin : dcmp
            isp_depth_cmp u_cmp (
                .mode(depth_mode),
                .nw  (ras_invw_flat[32*gd +: 32]),
                .ob  (dt_depth[{ras_oy, ras_ox + 5'(gd)}]),
                .pass(ras_pass[gd]));
        end
    endgenerate

    // -------------------- orchestration: decoupled producer / consumer --------------------
    // PRODUCER (region -> objlist -> iterator) runs AHEAD, pushing each triangle
    // into an 8-deep triangle FIFO. CONSUMER (setup ∥ raster) pops the FIFO and
    // rasterizes into the tile buffer. This hides the iterator's ~87-cyc per-
    // triangle read latency behind the setup+raster of earlier triangles.
    //
    // BARRIER: the FIFO holds triangles of ONE region-state only. CLEAR/OP/PT/TR/
    // FLUSH all touch the SAME tile depth/tag buffer and MUST stay ordered, so at
    // every region-state boundary the producer waits until the FIFO is empty AND
    // the consumer is idle (current state fully rastered) before advancing.
    localparam S_IDLE=0, S_RA=1, S_STATE=2,
               S_OL_RUN=4,                 // producer: OL entries -> entry FIFO
               S_RA_ACK=9, S_DONE=10,
               S_DRAIN=11;                 // barrier: wait consumer idle + FIFOs empty
    reg [3:0] st;

    // consumer sub-FSMs
    localparam SU_IDLE=0, SU_RUN=1;              reg su_st;
    localparam RS_IDLE=0, RS_RAS=1, RS_DRAIN=2;  reg [1:0] rs_st;

    // ---- entry FIFO (object_list_parser -> iterator), depth 8 ----
    // Decouples the OL parser (decode next entry) from the iterator (burst-read
    // records). The OL parser keeps decoding entries ahead into eq while the
    // iterator drains the current entry.
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

    // 1-deep pending-planes handoff (setup -> raster)
    reg        pend_valid;
    reg [31:0] pend_dx12,pend_dx23,pend_dx31,pend_dx41;
    reg [31:0] pend_dy12,pend_dy23,pend_dy31,pend_dy41;
    reg [31:0] pend_c1,pend_c2,pend_c3,pend_c4;
    reg [31:0] pend_ddx,pend_ddy,pend_cinvw;
    reg [31:0] pend_isp, pend_tag;
    reg [4:0]  pend_bx0,pend_bx1,pend_by0,pend_by1;  // tile-local bounding box

    reg prim_seen;   // iterator pulsed prim_done for the current entry
    // consumer fully idle: entry FIFO empty, iterator idle & not busy, setup +
    // raster + pend handoff all idle.
    wire consumer_idle = eq_empty && (it_cst==IT_IDLE) && !it_busy
                       && (su_st==SU_IDLE) && (rs_st==RS_IDLE) && !pend_valid;

    integer tri_count, cull_count, tri_seen;
    // profiling counters (cycles spent in each activity while walking entries)
    integer cyc_setup_run;   // isp_setup_min actively running (SU_RUN)
    integer cyc_su_wait;     // (unused now; kept for compat)
    integer cyc_su_wfetch;   // setup idle: no triangle from fetch yet (fetch-bound)
    integer cyc_su_wrast;    // setup idle: triangle ready but pend full (raster-bound)
    integer cyc_fe_wait;     // fetch blocked on the iterator producing a triangle
    integer cyc_ras;         // raster sweeping (RS_RAS)
    integer cyc_ras_drain;   // raster draining (RS_DRAIN)
    integer cyc_ras_idle;    // raster idle waiting on pend (RS_IDLE, in S_PRIM)
    integer cyc_prim;        // total cycles in S_PRIM
    reg [5:0] cur_tx, cur_ty;      // latched tile coords (stable during lists)
    integer i, l;
    integer px, py;

    // streamed rasterizer bookkeeping: chunks in flight (issued but not yet
    // consumed). One triangle = TILE_W/RAS_LANES * TILE_H chunks. The consumer
    // runs every cycle on ras_out_valid; the sweep is done when all issued and
    // all drained.
    localparam integer NCHUNK = (TILE_W/RAS_LANES) * TILE_H;   // 4*32 = 128
    integer ras_inflight;

    always @(posedge clk) begin
        if (reset) begin
            st<=S_IDLE; done<=0; ra_start<=0; ol_start<=0; it_start<=0;
            isp_start<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            tri_count<=0; cull_count<=0; tri_seen<=0; ras_inflight<=0;
            su_st<=SU_IDLE; rs_st<=RS_IDLE; pend_valid<=0; prim_seen<=0;
            fq_head<=0; fq_tail<=0; fq_count<=0;
            eq_head<=0; eq_tail<=0; eq_count<=0; it_cst<=IT_IDLE;
            cyc_setup_run<=0; cyc_su_wait<=0; cyc_ras<=0; cyc_ras_drain<=0;
            cyc_ras_idle<=0; cyc_prim<=0;
            cyc_su_wfetch<=0; cyc_su_wrast<=0; cyc_fe_wait<=0;
        end else begin
            done<=0; ra_start<=0; ol_start<=0; it_start<=0;
            isp_start<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            eq_push = 1'b0;

            // -------- streamed rasterizer CONSUMER (runs every cycle) --------
            // A result chunk emerges LAT cycles after issue; write depth/tag for
            // its passing lanes at the echoed (ras_ox,ras_oy). Independent of the
            // FSM so results drain while new chunks are still being issued.
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
            // inflight = issued (ras_in_valid pulse) - consumed (ras_out_valid).
            // ras_in_valid is the registered value driving the pipe THIS edge, so
            // it exactly counts one issue per chunk that actually entered.
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
                // CLEAR touches the whole tile buffer: BARRIER first (consumer of
                // the previous state must be fully done).
                RSTATE_CLEAR: if (consumer_idle && fq_empty) begin
                    for (i = 0; i < TILE_W*TILE_H; i = i + 1) begin
                        dt_depth[i] = regs.isp_backgnd_d;
                        dt_tag[i]   = regs.isp_backgnd_t;
                    end
                    ra_ack.list_done <= 1'b1; st <= S_RA_ACK;
                end
                RSTATE_OP, RSTATE_PT, RSTATE_TR: begin
                    ol_list_ptr <= ra_out.list_ptr;
                    ol_start <= 1'b1;
                    t_xbase <= i2f({10'd0, cur_tx} * 16'd32);
                    t_ybase <= i2f({10'd0, cur_ty} * 16'd32);
                    st <= S_OL_RUN;
                end
                // FLUSH reads the whole tile buffer: BARRIER first.
                RSTATE_FLUSH: if (consumer_idle && fq_empty) begin
                    for (i = 0; i < TILE_W*TILE_H; i = i + 1) begin
                        /* verilator lint_off WIDTH */
                        px = {26'd0, cur_tx}*32 + (i % TILE_W);
                        py = {26'd0, cur_ty}*32 + (i / TILE_W);
                        /* verilator lint_on WIDTH */
                        if (px < 640 && py < 480)
                            fb[py*640 + px] = dt_tag[i];
                    end
                    ra_ack.list_done <= 1'b1; st <= S_RA_ACK;
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
                ra_ack.list_done <= 1'b1; st <= S_RA_ACK;
            end

            S_RA_ACK: st <= S_RA;

            S_DONE: begin
                $display("=== done: %0d triangles rasterized, %0d culled ===",
                         tri_count, cull_count);
                $display("=== profile (S_PRIM=%0d of %0d total): setup_run=%0d su_wait_fetch=%0d su_wait_rast=%0d fe_wait=%0d ras=%0d ras_drain=%0d ras_idle=%0d ===",
                         cyc_prim, /*total via $time not avail*/ cyc_prim,
                         cyc_setup_run, cyc_su_wfetch, cyc_su_wrast, cyc_fe_wait,
                         cyc_ras, cyc_ras_drain, cyc_ras_idle);
                // setup runs on EVERY triangle (rasterized + culled); divide its
                // cycles by the total setups so the per-setup number is honest.
                // The others (fetch/raster stalls) are per RASTERIZED triangle.
                if (tri_count + cull_count > 0)
                    $display("=== per-setup: setup_run=%0d (over %0d setups incl %0d culled) ===",
                             cyc_setup_run/(tri_count+cull_count), tri_count+cull_count, cull_count);
                if (tri_count > 0)
                    $display("=== per-triangle: setup_run=%0d su_wait_fetch=%0d su_wait_rast=%0d fe_wait=%0d ras=%0d drain=%0d ===",
                             cyc_setup_run/tri_count, cyc_su_wfetch/tri_count, cyc_su_wrast/tri_count,
                             cyc_fe_wait/tri_count, cyc_ras/tri_count, cyc_ras_drain/tri_count);
                done<=1'b1; st<=S_IDLE;
            end
            default: st<=S_IDLE;
            endcase

            // ---- profiling (whole render) ----
            cyc_prim <= cyc_prim + 1;
            if (su_st==SU_RUN)          cyc_setup_run <= cyc_setup_run + 1;
            else if (fq_empty)          cyc_su_wfetch <= cyc_su_wfetch + 1; // consumer starved (producer/iterator behind)
            else if (pend_valid)        cyc_su_wrast  <= cyc_su_wrast  + 1; // FIFO has work but raster busy
            if (rs_st==RS_RAS)          cyc_ras       <= cyc_ras + 1;
            else if (rs_st==RS_DRAIN)   cyc_ras_drain <= cyc_ras_drain + 1;
            else if (!pend_valid)       cyc_ras_idle  <= cyc_ras_idle + 1;

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
                    pend_dx12<=w_dx12; pend_dx23<=w_dx23; pend_dx31<=w_dx31; pend_dx41<=w_dx41;
                    pend_dy12<=w_dy12; pend_dy23<=w_dy23; pend_dy31<=w_dy31; pend_dy41<=w_dy41;
                    pend_c1<=w_c1; pend_c2<=w_c2; pend_c3<=w_c3; pend_c4<=w_c4;
                    pend_ddx<=w_ddx; pend_ddy<=w_ddy; pend_cinvw<=w_cinvw;
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
            // by0..by1 inclusive. The rasterizer's inside-test still gates writes,
            // so this only skips rows/cols entirely outside the triangle.
            case (rs_st)
            RS_IDLE: if (pend_valid) begin
                isp_dx12<=pend_dx12; isp_dx23<=pend_dx23; isp_dx31<=pend_dx31; isp_dx41<=pend_dx41;
                isp_dy12<=pend_dy12; isp_dy23<=pend_dy23; isp_dy31<=pend_dy31; isp_dy41<=pend_dy41;
                isp_c1<=pend_c1; isp_c2<=pend_c2; isp_c3<=pend_c3; isp_c4<=pend_c4;
                isp_ddx_invw<=pend_ddx; isp_ddy_invw<=pend_ddy; isp_c_invw<=pend_cinvw;
                isp_word<=pend_isp; tri_tag<=pend_tag;
                pend_valid <= 1'b0;             // free the handoff for setup
                tri_count  <= tri_count + 1;
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
            RS_DRAIN: if (ras_inflight == 0 && !ras_in_valid && !ras_out_valid)
                rs_st <= RS_IDLE;
            endcase

            // ---- FIFO count maintenance (single update; push/pop may coincide) ----
            fq_count <= fq_count + (fifo_push ? 5'd1 : 5'd0) - (fifo_pop ? 5'd1 : 5'd0);
            eq_count <= eq_count + (eq_push  ? 5'd1 : 5'd0) - (eq_pop   ? 5'd1 : 5'd0);
        end
    end
endmodule

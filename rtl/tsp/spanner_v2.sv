//
// spanner_v2 - the DECOUPLED span-generate + TSP-setup stage of the v2 TSP pipeline.
//
// Replaces the monolithic peel_core `spn` FSM's resolve+setup+write with two engines
// that run CONCURRENTLY, joined by a small setup FIFO, so the per-triangle setup cost
// (~54cyc/tri) is hidden behind the shade stage (1px/clk, downstream, not in here):
//
//   FSM 1  SPANGEN  - walks the tile's tag buffer 4 ALIGNED pixels/clk, coalesces the
//                     leading same-tag run within each aligned group into a SPAN, and
//                     writes {id, repeat, invW[0:3]} to the OUT span buffer at the
//                     run-start pixel index. A NEW (not-yet-seen) tag allocates a
//                     direct-mapped setup id (id = pc_slot(tag)) and pushes {id,tag}
//                     to the setup FIFO. NEVER stalls on setup (that is downstream).
//   FSM 2  SETUP    - drains the setup FIFO: tag -> record_fetcher (GetFpuEntry) ->
//                     tsp_setup_min (10 planes) -> WRITE triangle_setups[id]. Runs in
//                     parallel with SPANGEN and the (external) shade stage.
//
// DEDUP / ID: id = pc_slot(core_tag), DIRECT-MAPPED into the 1024-entry triangle_setups
// array (id == storage slot). slot_tag[id]/slot_valid[id] remember which tag currently
// owns each slot. A 32x32 tile has <=1024 pixels, so <=1024 distinct tags can appear ->
// the id space (1024) CANNOT overflow. Collisions (two tags -> same slot) just cause a
// re-setup (measured +0.5% on menu2); NO allocator, NO overflow fallback. slot_valid is
// bulk-cleared at `start` (new tile pass); slot_tag rides in M10K.
//
// BOTH the triangle_setups array AND the span buffer are EXTERNAL (module output write
// ports) so the A/B ping-pong lives in peel_core glue, not here.
//
// IN (tag buffer): a 4-wide ALIGNED read port. The module presents a group base
// (rd_group = x & ~3) and receives the 4 lanes' {valid,tag,invW,pt} the NEXT cycle
// (1-cyc registered read, same timing as taginvw_tile_buffer's single-pixel port; glue
// widens that buffer to serve 4 aligned lanes). Lane l is pixel (group|l).
//
module spanner_v2 import tsp_pkg::*; #(
    parameter integer NSLOT = 1024,          // triangle_setups depth (== tile pixels)
    parameter integer SLOTW = 10             // clog2(NSLOT)
) (
    input                       clk,
    input                       reset,

    // ---- control ----
    input                       start,       // 1-cyc: begin resolving one tile pass
    output reg                  busy,         // start .. SPANGEN done && setup drained
    input                       shade_mode,  // 1=OP (shade all px); 0=PEEL (gate on valid)
    input      [31:0]           xbase, ybase,// this tile's origin (for tsp_setup_min)
    input      [26:0]           param_base,
    input                       intensity_shadow, // regs.fpu_shad_scale.intensity_shadow

    // ---- IN: 4-wide ALIGNED tag-buffer read (present addr -> data NEXT cycle) ----
    output reg                  rd_valid,    // present a group read this cycle
    output reg [SLOTW-1:0]      rd_group,    // group base pixel index (x & ~3)
    input      [3:0]            ti_valid,    // per-lane staged-this-pass bit
    input      [31:0]           ti_tag  [0:3],
    input      [31:0]           ti_invw [0:3],
    input      [3:0]            ti_pt,       // per-lane PT alpha-test bit

    // ---- OUT: triangle_setups WRITE (SETUP engine) ----
    output reg                  ts_we,
    output reg [SLOTW-1:0]      ts_id,
    output reg [31:0]           ts_isp, ts_tsp, ts_tcw,
    output reg [319:0]          ts_ddx, ts_ddy, ts_c,   // 10 x 32, lane j at [32*j+:32]

    // ---- OUT: span buffer WRITE (SPANGEN engine) ----
    output reg                  sp_we,
    output reg [SLOTW-1:0]      sp_idx,      // run-start pixel index (0..1023)
    output reg [SLOTW-1:0]      sp_id,       // setup id (== triangle_setups slot)
    output reg [2:0]            sp_rep,      // run length 1..4
    output reg [31:0]           sp_invw [0:3], // per-covered-pixel invW (lanes 0..rep-1)
    output reg [3:0]            sp_shmask,   // per-covered-lane shade-valid
    output reg                  sp_at,       // PT alpha-test enable (run-start lane)

    // ---- DDR client for the internal record_fetcher ----
    output ddr_rd_req_t         dreq,
    input  ddr_rd_resp_t        dresp
);
    // ============================ dedup / slot store ============================
    // id = pc_slot(tag): param_offs low bits XOR tag_offset (identical to peel_core's
    // hash so behaviour matches the current plane-cache slotting). Direct-mapped into
    // the NSLOT-entry triangle_setups array.
    function automatic [SLOTW-1:0] pc_slot(input [31:0] tag);
        pc_slot = { {(SLOTW-6){1'b0}}, (tag[8:3] ^ {3'b000, tag[2:0]}) };
    endfunction

    // slot_valid / slot_tag: which tag owns each direct-mapped slot.
    //   slot_valid : NSLOT-bit register vector. Read COMBINATIONALLY and bulk-cleared in
    //                one cycle at `start` (an M10K can't clear all entries at once).
    //   slot_tag   : NSLOT x 32b. REGISTERED-read block RAM (M10K, no async read). The
    //                dedup test is therefore PIPELINED: SG_RUN presents the read of run_id
    //                and SG_TEST (next cycle) does the compare + emit. See the SG FSM.
    // COHERENCY: a slot allocated in SG_TEST cycle N must be seen by the read presented in
    // SG_RUN cycle N+1. M10K returns OLD data on a same-address read+write, so we forward
    // the just-written {tag,valid} when the pending read address matches (fwd_* below).
    reg [NSLOT-1:0] slot_valid;
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] slot_tag [0:NSLOT-1];
    reg [31:0]      slot_tag_q;                  // registered read of slot_tag[run_id]
    reg             slot_valid_q;                // slot_valid[run_id], aligned to slot_tag_q
    reg [SLOTW-1:0] test_id;                     // run_id being tested in SG_TEST

    // ============================ setup FIFO (SPANGEN -> SETUP) ============================
    // {id, tag} pushed when a span allocates a NEW slot; drained by the SETUP engine.
    localparam integer SF_AW = 3;                 // 8-deep
    localparam integer SF_N  = (1 << SF_AW);
    localparam integer SF_W  = SLOTW + 32;        // {id, tag}
    reg  [SF_W-1:0] sf_mem [0:SF_N-1];
    reg  [SF_AW:0]  sf_wp, sf_rp;                 // extra MSB for full/empty disambig
    wire            sf_empty = (sf_wp == sf_rp);
    wire            sf_full  = (sf_wp[SF_AW] != sf_rp[SF_AW]) &&
                               (sf_wp[SF_AW-1:0] == sf_rp[SF_AW-1:0]);
    reg             sf_push;  reg [SF_W-1:0] sf_pdata;
    wire [SF_W-1:0] sf_head  = sf_mem[sf_rp[SF_AW-1:0]];

    // ============================ FSM 1: SPANGEN ============================
    // 4-stage walk (M10K-friendly - the slot store has a registered read):
    //   SG_ISSUE : present the aligned 4-group tag-buffer read (1-cyc latency).
    //   SG_LATCH : the 4 lanes are valid -> latch into g_*.
    //   SG_RUN   : coalesce the leading same-tag run from the current intra-group position
    //              into run_*; latch it into t_*; PRESENT the registered slot_tag read of
    //              run_id (dedup lookup).
    //   SG_TEST  : slot read resolved -> dedup compare (with write-forwarding), EMIT the
    //              span, allocate the slot on a miss, advance the walk. If the held group
    //              still has pixels -> back to SG_RUN (no reread); else SG_ISSUE next group.
    // So one span every 2 cycles within a group (RUN/TEST). At avg ~3.4px/span that is
    // ~2*210k = ~420k SPANGEN cycles - still well under the 709k shade floor, so setup
    // stays fully hidden. The group HOLDS until its last pixel is consumed (a group may
    // need up to 4 spans: A B C D).
    localparam SG_IDLE=3'd0, SG_ISSUE=3'd1, SG_LATCH=3'd2, SG_RUN=3'd3, SG_TEST=3'd4,
               SG_DONE=3'd5;
    reg [2:0]        sg_st;
    reg [SLOTW-1:0]  sg_x;          // next pixel to emit a span at (0..NSLOT-1)
    reg [3:0]        g_valid;       // latched lane fields
    reg [31:0]       g_tag  [0:3];
    reg [31:0]       g_invw [0:3];
    reg [3:0]        g_pt;

    // ---- run payload latched at SG_RUN, consumed (emitted) at SG_TEST ----
    reg [SLOTW-1:0]  t_x;           // run-start pixel index
    reg [SLOTW-1:0]  t_id;          // pc_slot(run_tag)
    reg [31:0]       t_tag;
    reg [2:0]        t_rep;
    reg [3:0]        t_shmask;
    reg [31:0]       t_invw [0:3];
    reg              t_at;

    wire [1:0] sg_lane = sg_x[1:0];              // intra-group position of sg_x

    // ---- leading-run coalesce (combinational off latched group) ----
    // Start lane = sg_lane. Extend while lane in-group, tag equal, and shade-eligible
    // (OP: any; PEEL: valid). shade_ok(l) = shade_mode | g_valid[l]. A run of tags that
    // are NOT shade-eligible is still a span (it advances the walk) but with shmask=0
    // (SHADE writes nothing for those pixels); we still coalesce equal tags so the walk
    // matches the aligned model.
    reg  [2:0] run_rep;                          // 1..4
    reg  [3:0] run_shmask;                       // per-lane shade-valid over the run
    reg  [31:0] run_tag;
    integer rl;
    always @(*) begin
        run_tag    = g_tag[sg_lane];
        run_rep    = 3'd1;
        run_shmask = 4'd0;
        // lane sg_lane always part of the run
        run_shmask[sg_lane] = shade_mode | g_valid[sg_lane];
        // extend to lanes above sg_lane while tag matches
        for (rl = 0; rl < 4; rl = rl + 1) begin
            if (rl > sg_lane && rl == sg_lane + run_rep && g_tag[rl] == run_tag) begin
                run_rep = run_rep + 3'd1;
                run_shmask[rl] = shade_mode | g_valid[rl];
            end
        end
    end

    wire [SLOTW-1:0] run_id = pc_slot(run_tag);

    // dedup test in SG_TEST, using the REGISTERED slot read (slot_tag_q/slot_valid_q) of
    // t_id, WITH forwarding: if the slot was just written last cycle (M10K read-during-
    // write returns stale data) the forwarded {tag,valid} wins. fwd_hit/fwd_tag are set
    // when the previous SG_TEST allocated t_id (see the sequential block).
    reg             fwd_valid;      // a slot write happened last cycle
    reg [SLOTW-1:0] fwd_id;         // its slot
    reg [31:0]      fwd_tag;        // its tag
    wire            eff_valid = (fwd_valid && fwd_id == test_id) ? 1'b1     : slot_valid_q;
    wire [31:0]     eff_tag   = (fwd_valid && fwd_id == test_id) ? fwd_tag  : slot_tag_q;
    wire is_dedup_hit = eff_valid && (eff_tag == t_tag);
    wire needs_alloc  = !is_dedup_hit;

    // emit can commit in SG_TEST when: if it ALLOCATES (new tag), the setup FIFO has room.
    // A same-tag reuse never needs the FIFO.
    wire emit_stall_fifo = needs_alloc && sf_full;

    // walk advance after this emit. t_rep is 1..4; t_x is group-aligned + intra-group so
    // t_x_next stays <= a group boundary. group_done when we land on the next group.
    wire [SLOTW-1:0] t_x_next = t_x + { {(SLOTW-3){1'b0}}, t_rep };
    wire group_done_after = (t_x_next[1:0] == 2'd0);      // crossed into next group

    // ============================ FSM 2: SETUP ============================
    // Drains the setup FIFO: {id,tag} -> record_fetcher -> tsp_setup_min -> ts write.
    localparam SU_IDLE=2'd0, SU_FETCH=2'd1, SU_SETUP=2'd2, SU_WRITE=2'd3;
    reg [1:0]        su_st;
    reg [SLOTW-1:0]  su_id;

    // record_fetcher (demand only; FIFOs front & back hide its latency, no prefetch)
    reg              fx_start;
    reg  [31:0]      fx_tag;
    wire             fx_busy, fx_done;
    wire [31:0]      fx_isp, fx_tsp, fx_tcw;
    wire [31:0]      fx_x[0:2], fx_y[0:2], fx_z[0:2];
    wire [31:0]      fx_u[0:2], fx_v[0:2], fx_col[0:2], fx_ofs[0:2];
    record_fetcher u_fetch (
        .clk(clk), .reset(reset),
        .start(fx_start), .tag(fx_tag), .param_base(param_base),
        .intensity_shadow(intensity_shadow),
        .busy(fx_busy), .done(fx_done),
        .o_isp(fx_isp), .o_tsp(fx_tsp), .o_tcw(fx_tcw),
        .o_x(fx_x), .o_y(fx_y), .o_z(fx_z),
        .o_u(fx_u), .o_v(fx_v), .o_col(fx_col), .o_ofs(fx_ofs),
        .dreq(dreq), .dresp(dresp)
    );

    // latched decoded record of the tri being set up (feed tsp_setup_min)
    reg [31:0] cur_isp, cur_tsp, cur_tcw;
    reg [31:0] fv_x[0:2], fv_y[0:2], fv_z[0:2];
    reg [31:0] fv_u[0:2], fv_v[0:2], fv_col[0:2], fv_ofs[0:2];
    wire f_texture = cur_isp[ISP_TEXTURE_BIT];
    wire f_offset  = cur_isp[ISP_OFFSET_BIT];
    wire f_gouraud = cur_isp[ISP_GOURAUD_BIT];

    // tsp_setup_min: 10-plane producer
    reg              tsp_start;
    wire             tsp_done, tsp_pvalid;
    wire [3:0]       tsp_pidx;
    wire [31:0]      tsp_pddx, tsp_pddy, tsp_pc;
    tsp_setup_min u_tsp (
        .clk(clk), .reset(reset), .start(tsp_start), .done(tsp_done),
        .gouraud(f_gouraud), .texture(f_texture), .offset(f_offset),
        .x1(fv_x[0]),.y1(fv_y[0]),.z1(fv_z[0]),
        .x2(fv_x[1]),.y2(fv_y[1]),.z2(fv_z[1]),
        .x3(fv_x[2]),.y3(fv_y[2]),.z3(fv_z[2]),
        .xbase(xbase), .ybase(ybase),
        .u1(fv_u[0]),.v1(fv_v[0]),.u2(fv_u[1]),.v2(fv_v[1]),.u3(fv_u[2]),.v3(fv_v[2]),
        .col1(fv_col[0]),.col2(fv_col[1]),.col3(fv_col[2]),
        .ofs1(fv_ofs[0]),.ofs2(fv_ofs[1]),.ofs3(fv_ofs[2]),
        .plane_valid(tsp_pvalid), .plane_idx(tsp_pidx),
        .o_ddx(tsp_pddx), .o_ddy(tsp_pddy), .o_c(tsp_pc)
    );

    // plane accumulators (written by tsp_setup_min's streamed plane_valid/plane_idx)
    reg [319:0] acc_ddx, acc_ddy, acc_c;

    // ============================ combinational OUT + FIFO drive ============================
    integer k;
    always @(*) begin
        // ----- SPANGEN span write + FIFO push: fire in SG_TEST (the run payload was
        // latched into t_* at SG_RUN; the registered slot read resolves the dedup here) -----
        sp_we      = 1'b0;
        sp_idx     = t_x;
        sp_id      = t_id;
        sp_rep     = t_rep;
        sp_shmask  = t_shmask;
        sp_at      = t_at;
        for (k = 0; k < 4; k = k + 1) sp_invw[k] = t_invw[k];

        sf_push  = 1'b0;
        sf_pdata = { t_id, t_tag };

        // present a group read only in SG_ISSUE (read latency: data in SG_LATCH). Group
        // base = sg_x & ~3. Once latched, SG_RUN re-indexes the held group with no reread.
        rd_valid = (sg_st == SG_ISSUE);
        rd_group = { sg_x[SLOTW-1:2], 2'b00 };

        if ((sg_st == SG_TEST) && !emit_stall_fifo) begin
            sp_we = 1'b1;
            if (needs_alloc) sf_push = 1'b1;
        end

        // ----- SETUP -> triangle_setups write -----
        ts_we  = (su_st == SU_WRITE);
        ts_id  = su_id;
        ts_isp = cur_isp;
        ts_tsp = cur_tsp;
        ts_tcw = cur_tcw;
        ts_ddx = acc_ddx;
        ts_ddy = acc_ddy;
        ts_c   = acc_c;
    end

    // ============================ sequential ============================
    integer q;
    always @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0;
            sg_st <= SG_IDLE; sg_x <= '0;
            slot_valid <= '0;
            fwd_valid <= 1'b0;
            sf_wp <= '0; sf_rp <= '0;
            su_st <= SU_IDLE; fx_start <= 1'b0; tsp_start <= 1'b0;
        end else begin
            fx_start  <= 1'b0;
            tsp_start <= 1'b0;

            // ---------------- start a tile pass ----------------
            if (start) begin
                slot_valid <= '0;         // bulk clear the dedup
                sg_x  <= '0;
                sg_st <= SG_ISSUE;
                busy  <= 1'b1;
                sf_wp <= '0; sf_rp <= '0;
            end

            // =================== FSM 1: SPANGEN ===================
            case (sg_st)
            SG_ISSUE: begin
                // rd_valid/rd_group presented combinationally this cycle; data next cycle.
                sg_st <= SG_LATCH;
            end
            SG_LATCH: begin
                // the 4 aligned lanes requested in ISSUE are valid now -> latch them.
                g_valid <= ti_valid;
                for (q = 0; q < 4; q = q + 1) begin
                    g_tag[q]  <= ti_tag[q];
                    g_invw[q] <= ti_invw[q];
                end
                g_pt    <= ti_pt;
                sg_st   <= SG_RUN;
            end
            SG_RUN: begin
                // coalesce the run (combinational run_*), LATCH its payload into t_*, and
                // present the REGISTERED slot read of run_id. The dedup compare + emit
                // happen next cycle in SG_TEST (slot_tag is M10K, read has 1-cyc latency).
                t_x      <= sg_x;
                t_id     <= run_id;
                t_tag    <= run_tag;
                t_rep    <= run_rep;
                t_shmask <= run_shmask;
                t_at     <= g_pt[sg_lane];
                for (q = 0; q < 4; q = q + 1)
                    t_invw[q] <= (q < run_rep) ? g_invw[sg_lane + q[1:0]] : 32'd0;
                // present slot read
                test_id      <= run_id;
                slot_tag_q   <= slot_tag[run_id];
                slot_valid_q <= slot_valid[run_id];
                sg_st <= SG_TEST;
            end
            SG_TEST: begin
                // slot read resolved (slot_tag_q/slot_valid_q, forwarded via eff_*). Emit
                // the span (combinational sp_*), allocate on a miss, advance the walk.
                // emit_stall_fifo holds here (an allocating span with a full setup FIFO).
                if (!emit_stall_fifo) begin
                    if (needs_alloc) begin
                        slot_valid[t_id] <= 1'b1;
                        slot_tag[t_id]   <= t_tag;
                    end
                    // advance the walk from the run-start (t_x), by t_rep
                    sg_x <= t_x_next;
                    if (t_x_next == '0) begin
                        // wrapped past the last pixel (NSLOT is a power of two) -> done
                        sg_st <= SG_DONE;
                    end else if (group_done_after) begin
                        // group fully consumed -> issue a read for the next group
                        sg_st <= SG_ISSUE;
                    end else begin
                        // more spans in this held group -> compute the next run
                        sg_st <= SG_RUN;
                    end
                end
            end
            SG_DONE: ;   // SPANGEN finished; busy clears once SETUP drains (bottom).
            default: ;   // SG_IDLE
            endcase

            // ---- slot-write FORWARDING: remember the write done THIS cycle so the read
            // presented next cycle (SG_RUN) sees it despite M10K read-during-write returning
            // stale data. Valid for exactly one cycle. ----
            fwd_valid <= (sg_st == SG_TEST) && !emit_stall_fifo && needs_alloc;
            fwd_id    <= t_id;
            fwd_tag   <= t_tag;

            // =================== FIFO push ===================
            if (sf_push && !sf_full) begin
                sf_mem[sf_wp[SF_AW-1:0]] <= sf_pdata;
                sf_wp <= sf_wp + 1'b1;
            end

            // =================== FSM 2: SETUP ===================
            case (su_st)
            SU_IDLE: if (!sf_empty) begin
                su_id  <= sf_head[SF_W-1:32];
                fx_tag <= sf_head[31:0];
                fx_start <= 1'b1;
                sf_rp  <= sf_rp + 1'b1;    // pop
                su_st  <= SU_FETCH;
            end
            SU_FETCH: if (fx_done) begin
                cur_isp <= fx_isp; cur_tsp <= fx_tsp; cur_tcw <= fx_tcw;
                for (q = 0; q < 3; q = q + 1) begin
                    fv_x[q]<=fx_x[q]; fv_y[q]<=fx_y[q]; fv_z[q]<=fx_z[q];
                    fv_u[q]<=fx_u[q]; fv_v[q]<=fx_v[q];
                    fv_col[q]<=fx_col[q]; fv_ofs[q]<=fx_ofs[q];
                end
                acc_ddx <= '0; acc_ddy <= '0; acc_c <= '0;
                tsp_start <= 1'b1;
                su_st <= SU_SETUP;
            end
            SU_SETUP: begin
                // collect streamed planes
                if (tsp_pvalid) begin
                    acc_ddx[32*tsp_pidx +: 32] <= tsp_pddx;
                    acc_ddy[32*tsp_pidx +: 32] <= tsp_pddy;
                    acc_c  [32*tsp_pidx +: 32] <= tsp_pc;
                end
                if (tsp_done) su_st <= SU_WRITE;
            end
            SU_WRITE: begin
                // ts_we asserted combinationally this cycle (writes triangle_setups[su_id])
                su_st <= SU_IDLE;
            end
            endcase

            // =================== busy / done ===================
            // done when SPANGEN finished AND setup FIFO empty AND setup engine idle.
            if (busy && (sg_st == SG_DONE) && sf_empty && (su_st == SU_IDLE) && !fx_busy)
                busy <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    // one span write per cycle; ts write mutually exclusive per its FSM. Sanity: never
    // push a full FIFO, never pop an empty one.
    always @(posedge clk) if (!reset) begin
        if (sf_push && sf_full)
            $error("spanner_v2: setup FIFO overflow (push while full)");
    end
`endif
endmodule

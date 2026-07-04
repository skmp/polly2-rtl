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
    //                dedup test is PIPELINED: COAL presents the read of run_id, EMIT (next
    //                cycle) does the compare + span write. See the SPANGEN pipeline below.
    // COHERENCY: EMIT retires a span every cycle and can WRITE a slot the same cycle COAL
    // presents the next span's read. M10K returns OLD data on a same-address read+write, so
    // the two most-recent emitted allocations are FORWARDED (fwd0/fwd1) into the EMIT
    // compare, covering back-to-back same-slot dedup (see fwd_* below).
    reg [NSLOT-1:0] slot_valid;
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] slot_tag [0:NSLOT-1];
    reg [31:0]      slot_tag_q;                  // registered read of slot_tag[coal id]
    reg             slot_valid_q;                // slot_valid, aligned to slot_tag_q

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

    // ============================ FSM 1: SPANGEN (pipelined, 1 span/cycle) ============================
    // A continuously-advancing 2-stage pipeline (M10K-friendly: slot read is registered):
    //   COAL (this cycle): a group's 4 lanes are held in g_*; coalesce the leading same-tag
    //        run at the current intra-group position sg_x -> a span descriptor run_*.
    //        PRESENT the registered slot_tag read of run_id. Advance sg_x by run_rep. If the
    //        group is exhausted, the group PREFETCH (ahead) supplies the next group's lanes
    //        so COAL keeps producing one descriptor EVERY cycle with no reissue bubble.
    //   EMIT (next cycle): the descriptor produced by COAL last cycle is in t_*; its slot
    //        read has resolved (slot_*_q, forwarded) -> dedup compare, WRITE the span,
    //        allocate on a miss. Retires one span/cycle.
    // Uniform tile (one tag, 4px runs) -> 256 groups x 1 span x 1 cyc + fill/drain ~= 258.
    // Multi-span group (A B C D) -> COAL produces 4 descriptors on 4 consecutive cycles
    // (sg_x steps within the held group, no reissue) -> 4 cyc, still 1 span/cyc.
    //
    // GROUP PREFETCH: the tag buffer read has 1-cyc latency, so we must present the NEXT
    // group's read the cycle BEFORE COAL needs it. gp_* holds the prefetched group; when
    // COAL exhausts the current group it swaps gp_* -> g_* and the prefetch reads group+1.
    reg              sg_active;     // SPANGEN still walking (COAL may produce)
    reg [SLOTW-1:0]  sg_x;          // next pixel to coalesce a span at (0..NSLOT-1)
    reg              g_ready;       // ti_* holds sg_x's group this cycle (read landed)
    // The tag buffer is a registered-read RAM: its output ti_* reflects the address
    // presented LAST cycle, and updates EVERY cycle. So we present rd_group = the group of
    // the pixel COAL coalesces NEXT cycle, continuously; then ti_* is ALWAYS the correct
    // group source for the current sg_x -> COAL coalesces directly off ti_* (no held-group
    // register, no source mux). g_ready gates the 1-cycle fill latency after start/stall.
    reg [SLOTW-1:0]  rd_next_x;     // combinational: pixel whose group we address

    // ---- span descriptor latched at COAL, consumed (emitted) at EMIT ----
    reg              t_valid;       // EMIT stage occupied
    reg [SLOTW-1:0]  t_x;           // run-start pixel index
    reg [SLOTW-1:0]  t_id;          // pc_slot(run_tag)
    reg [31:0]       t_tag;
    reg [2:0]        t_rep;
    reg [3:0]        t_shmask;
    reg [31:0]       t_invw [0:3];
    reg              t_at;

    wire [1:0] sg_lane = sg_x[1:0];              // intra-group position of sg_x

    // ---- leading-run coalesce (combinational off ti_*, the current group source) ----
    // Start lane = sg_lane. Extend while lane in-group, tag equal. shade_ok(l) =
    // shade_mode | ti_valid[l]. A run of not-shade-eligible tags is still a span (advances
    // the walk) but with shmask=0; we coalesce equal tags to match the aligned model.
    reg  [2:0] run_rep;                          // 1..4
    reg  [3:0] run_shmask;                       // per-lane shade-valid over the run
    reg  [31:0] run_tag;
    integer rl;
    always @(*) begin
        run_tag    = ti_tag[sg_lane];
        run_rep    = 3'd1;
        run_shmask = 4'd0;
        run_shmask[sg_lane] = shade_mode | ti_valid[sg_lane];
        for (rl = 0; rl < 4; rl = rl + 1) begin
            if (rl > sg_lane && rl == sg_lane + run_rep && ti_tag[rl] == run_tag) begin
                run_rep = run_rep + 3'd1;
                run_shmask[rl] = shade_mode | ti_valid[rl];
            end
        end
    end

    wire [SLOTW-1:0] run_id = pc_slot(run_tag);

    // dedup test in EMIT, using the REGISTERED slot read (slot_tag_q/slot_valid_q) of
    // t_id, WITH forwarding. In the 1-span/cycle pipeline, EMIT retires a span every cycle
    // and may write the slot store the SAME cycle COAL presents the next span's read (M10K
    // read-during-write returns stale data). So we forward the LAST TWO emitted allocations:
    //   fwd0 = the allocation done LAST cycle (its write is in flight, read returns stale)
    //   fwd1 = the allocation done TWO cycles ago (covers the M10K's write-settle window)
    // Both are checked against t_id; the most recent wins. Uniform tile (same tag every
    // group -> same id) is covered: after the first alloc, every later EMIT sees fwd and
    // dedups (no re-push, no re-setup).
    reg             fwd0_valid, fwd1_valid;
    reg [SLOTW-1:0] fwd0_id,    fwd1_id;
    reg [31:0]      fwd0_tag,   fwd1_tag;
    wire            fwd0_hit = fwd0_valid && (fwd0_id == t_id);
    wire            fwd1_hit = fwd1_valid && (fwd1_id == t_id);
    wire            eff_valid = fwd0_hit ? 1'b1 : (fwd1_hit ? 1'b1 : slot_valid_q);
    wire [31:0]     eff_tag   = fwd0_hit ? fwd0_tag : (fwd1_hit ? fwd1_tag : slot_tag_q);
    wire is_dedup_hit = t_valid && eff_valid && (eff_tag == t_tag);
    wire needs_alloc  = t_valid && !is_dedup_hit;

    // emit can commit when: if it ALLOCATES (new tag), the setup FIFO has room. A same-tag
    // reuse never needs the FIFO. When it can't, the WHOLE pipeline freezes (COAL + EMIT).
    wire emit_stall_fifo = needs_alloc && sf_full;
    wire pipe_stall      = emit_stall_fifo;   // freezes both stages this cycle

    // ---- COAL advance: sg_x steps by run_rep; group exhausted when it crosses the group ----
    wire [SLOTW-1:0] sg_x_next   = sg_x + { {(SLOTW-3){1'b0}}, run_rep };
    wire walk_last              = (sg_x_next == '0);          // wrapped past pixel 1023
    // COAL produces a descriptor this cycle iff walking, the group read has landed
    // (g_ready), and the pipeline isn't frozen.
    wire coal_fires = sg_active && g_ready && !pipe_stall;

    // ============================ SETUP path (streaming, no serial FSM) ============================
    // Three independent stages, each fed continuously, so the record fetch of triangle
    // N+1 OVERLAPS the plane setup of triangle N (they were serial before: ~144 fetch +
    // ~257 setup = ~400 cyc/triangle back-to-back):
    //   FETCH  : pop the setup FIFO into record_fetcher whenever it is free.
    //   pend_* : 1-deep skid holding the decoded record until tsp_setup_min is free
    //            (frees the fetcher to start the next fetch).
    //   SETUP  : latch pend_* into cur_*/fv_* (held stable for the whole run) + start
    //            tsp_setup_min; on tsp_done pulse ts_pend -> ts_we write.
    reg              fetch_busy;    // a fetch is in flight (fx_start..fx_done)
    reg [SLOTW-1:0]  fx_id;         // the in-flight fetch's setup id
    reg              pend_v;        // pend_* holds a decoded record awaiting setup
    reg [SLOTW-1:0]  pend_id;
    reg [31:0]       pend_isp, pend_tsp, pend_tcw;
    reg [31:0]       pend_x[0:2], pend_y[0:2], pend_z[0:2];
    reg [31:0]       pend_u[0:2], pend_v3[0:2], pend_col[0:2], pend_ofs[0:2];
    reg              su_run;        // tsp_setup_min busy (tsp_start..tsp_done)
    reg              ts_pend;       // write triangle_setups this cycle (cycle after tsp_done)
    reg [SLOTW-1:0]  su_id;         // the active setup's id (write target)
`ifndef SYNTHESIS
    integer          su_dbg_cyc;   // +sutrace cycle counter
`endif

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
    tsp_setup_stream u_tsp (
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
        // ----- EMIT: span write + FIFO push. The descriptor produced by COAL last cycle
        // is in t_* (t_valid); its slot read has resolved -> dedup here and write. Held
        // (no write, no advance) when the pipeline is frozen. -----
        sp_we      = t_valid && !pipe_stall;
        sp_idx     = t_x;
        sp_id      = t_id;
        sp_rep     = t_rep;
        sp_shmask  = t_shmask;
        sp_at      = t_at;
        for (k = 0; k < 4; k = k + 1) sp_invw[k] = t_invw[k];

        sf_push  = sp_we && needs_alloc;   // allocate -> push a setup
        sf_pdata = { t_id, t_tag };

        // COAL group read address. A registered-read tag buffer updates its output EVERY
        // cycle from the presented address, so we drive rd_group to the group of the pixel
        // COAL will coalesce NEXT cycle, CONTINUOUSLY (don't rely on the read output
        // persisting across cycles). Next-coalesced pixel = sg_x_next if COAL fires this
        // cycle (advancing), else sg_x (idle/fill/held). rd_valid tracks it while active.
        rd_next_x = coal_fires ? sg_x_next : sg_x;
        rd_valid  = sg_active && !pipe_stall;
        rd_group  = { rd_next_x[SLOTW-1:2], 2'b00 };

        // ----- SETUP -> triangle_setups write -----
        ts_we  = ts_pend;
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
            sg_active <= 1'b0; sg_x <= '0; t_valid <= 1'b0;
            g_ready <= 1'b0;
            slot_valid <= '0;
            fwd0_valid <= 1'b0; fwd1_valid <= 1'b0;
            sf_wp <= '0; sf_rp <= '0;
            fetch_busy <= 1'b0; pend_v <= 1'b0; su_run <= 1'b0; ts_pend <= 1'b0;
            fx_start <= 1'b0; tsp_start <= 1'b0;
        end else begin
            fx_start  <= 1'b0;
            tsp_start <= 1'b0;

            // ---------------- start a tile pass ----------------
            if (start) begin
                slot_valid <= '0;         // bulk clear the dedup
                sg_x  <= '0;
                sg_active <= 1'b1;
                t_valid <= 1'b0;
                g_ready <= 1'b0;          // first COAL waits one fill cycle for the read
                fwd0_valid <= 1'b0; fwd1_valid <= 1'b0;
                busy  <= 1'b1;
                sf_wp <= '0; sf_rp <= '0;
            end

            // =================== FSM 1: SPANGEN pipeline (COAL + EMIT) ===================
            // Whole pipeline freezes on pipe_stall (setup FIFO full on an allocating emit).
            if (!pipe_stall) begin
                // ---------- EMIT: retire the descriptor produced last cycle ----------
                // span write is combinational (sp_*); here just commit the allocation to
                // the slot store and shift the forwarding history.
                if (t_valid && needs_alloc) begin
                    slot_valid[t_id] <= 1'b1;
                    slot_tag[t_id]   <= t_tag;
                end
                // forwarding shift: fwd0 = alloc this cycle, fwd1 = previous fwd0.
                fwd1_valid <= fwd0_valid; fwd1_id <= fwd0_id; fwd1_tag <= fwd0_tag;
                fwd0_valid <= t_valid && needs_alloc;
                fwd0_id    <= t_id;
                fwd0_tag   <= t_tag;

                // ---------- COAL: coalesce one span off ti_* (the current group) ----------
                if (coal_fires) begin
                    t_valid  <= 1'b1;
                    t_x      <= sg_x;
                    t_id     <= run_id;
                    t_tag    <= run_tag;
                    t_rep    <= run_rep;
                    t_shmask <= run_shmask;
                    t_at     <= ti_pt[sg_lane];
                    for (q = 0; q < 4; q = q + 1)
                        t_invw[q] <= (q < run_rep) ? ti_invw[sg_lane + q[1:0]] : 32'd0;
                    // present the slot read for THIS descriptor (resolves next cycle in EMIT)
                    slot_tag_q   <= slot_tag[run_id];
                    slot_valid_q <= slot_valid[run_id];

                    // advance. The read for sg_x_next's group is presented THIS cycle
                    // (rd_group tracks rd_next_x continuously) -> ti_* is correct next cycle.
                    sg_x <= sg_x_next;
                    if (walk_last) sg_active <= 1'b0;
                    // g_ready stays 1 (a valid read was presented this cycle).
                end else begin
                    // fill bubble (post start/stall): no descriptor; the read of sg_x's
                    // group was presented this cycle -> ready next cycle.
                    t_valid <= 1'b0;
                end

                // g_ready: a valid read was presented this cycle (sg_active && !pipe_stall
                // is implied by being in this block); it lands next cycle. Cleared only at
                // start (below) so the first COAL waits one fill cycle.
                if (sg_active) g_ready <= 1'b1;
            end

            // =================== FIFO push ===================
            if (sf_push && !sf_full) begin
                sf_mem[sf_wp[SF_AW-1:0]] <= sf_pdata;
                sf_wp <= sf_wp + 1'b1;
            end

            // =================== SETUP path (streaming stages) ===================
`ifndef SYNTHESIS
            su_dbg_cyc <= start ? 0 : su_dbg_cyc + 1;
            if ($test$plusargs("sutrace")) begin
                if (!fetch_busy && !pend_v && !sf_empty)
                    $display("[SU c%0d] FETCH issue tag=%08x id=%0d", su_dbg_cyc, sf_head[31:0], sf_head[SF_W-1:32]);
                if (fetch_busy && fx_done)      $display("[SU c%0d] FETCH done id=%0d", su_dbg_cyc, fx_id);
                if (!su_run && !ts_pend && (pend_v || fx_done))
                                                $display("[SU c%0d] SETUP start id=%0d", su_dbg_cyc, fx_done ? fx_id : pend_id);
                if (su_run && tsp_done)         $display("[SU c%0d] SETUP done id=%0d", su_dbg_cyc, su_id);
                if (ts_pend)                    $display("[SU c%0d] WRITE id=%0d", su_dbg_cyc, su_id);
            end
`endif
            // ---- FETCH issue: pop the FIFO into the fetcher whenever it is free and the
            // pend skid is empty (the skid frees when setup accepts, so fetch N+1 runs
            // DURING setup N). fetch_busy covers the fx_start..fx_busy visibility gap.
            if (!fetch_busy && !pend_v && !sf_empty) begin
                fx_tag     <= sf_head[31:0];
                fx_id      <= sf_head[SF_W-1:32];
                fx_start   <= 1'b1;
                sf_rp      <= sf_rp + 1'b1;    // pop
                fetch_busy <= 1'b1;
            end

            // ---- FETCH complete -> pend skid (or straight into setup if it is idle) ----
            if (fetch_busy && fx_done) begin
                fetch_busy <= 1'b0;
                pend_v     <= 1'b1;
                pend_id    <= fx_id;
                pend_isp <= fx_isp; pend_tsp <= fx_tsp; pend_tcw <= fx_tcw;
                for (q = 0; q < 3; q = q + 1) begin
                    pend_x[q]<=fx_x[q]; pend_y[q]<=fx_y[q]; pend_z[q]<=fx_z[q];
                    pend_u[q]<=fx_u[q]; pend_v3[q]<=fx_v[q];
                    pend_col[q]<=fx_col[q]; pend_ofs[q]<=fx_ofs[q];
                end
            end

            // ---- SETUP accept: whenever tsp_setup_min is idle (and the previous write
            // retired), latch the pending record into cur_*/fv_* (held stable for the whole
            // run) and start. Bypass: accept straight off fx_done the same cycle. ----
            if (!su_run && !ts_pend && (pend_v || fx_done)) begin
                if (pend_v) begin
                    cur_isp <= pend_isp; cur_tsp <= pend_tsp; cur_tcw <= pend_tcw;
                    for (q = 0; q < 3; q = q + 1) begin
                        fv_x[q]<=pend_x[q]; fv_y[q]<=pend_y[q]; fv_z[q]<=pend_z[q];
                        fv_u[q]<=pend_u[q]; fv_v[q]<=pend_v3[q];
                        fv_col[q]<=pend_col[q]; fv_ofs[q]<=pend_ofs[q];
                    end
                    su_id  <= pend_id;
                    pend_v <= 1'b0;
                end else begin  // fx_done bypass (skid empty, setup idle)
                    cur_isp <= fx_isp; cur_tsp <= fx_tsp; cur_tcw <= fx_tcw;
                    for (q = 0; q < 3; q = q + 1) begin
                        fv_x[q]<=fx_x[q]; fv_y[q]<=fx_y[q]; fv_z[q]<=fx_z[q];
                        fv_u[q]<=fx_u[q]; fv_v[q]<=fx_v[q];
                        fv_col[q]<=fx_col[q]; fv_ofs[q]<=fx_ofs[q];
                    end
                    su_id  <= fx_id;
                    pend_v <= 1'b0;   // consumed in flight, skid stays empty
                end
                acc_ddx <= '0; acc_ddy <= '0; acc_c <= '0;
                tsp_start <= 1'b1;
                su_run <= 1'b1;
            end

            // ---- SETUP run: collect streamed planes; done -> 1-cycle write pulse ----
            if (tsp_pvalid) begin
                acc_ddx[32*tsp_pidx +: 32] <= tsp_pddx;
                acc_ddy[32*tsp_pidx +: 32] <= tsp_pddy;
                acc_c  [32*tsp_pidx +: 32] <= tsp_pc;
            end
            if (su_run && tsp_done) begin
                su_run  <= 1'b0;
                ts_pend <= 1'b1;      // ts_we fires (combinational) next cycle
            end else if (ts_pend) begin
                ts_pend <= 1'b0;
            end

            // =================== busy / done ===================
            // done when SPANGEN drained (not walking, EMIT stage empty) AND the whole
            // setup path is drained (FIFO, fetch, skid, setup run, write pulse).
            if (busy && !start && !sg_active && !t_valid && sf_empty
                && !fetch_busy && !pend_v && !su_run && !ts_pend)
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

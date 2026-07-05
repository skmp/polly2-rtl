// spanner_v2_tb_top - standalone sim harness for spanner_v2.
//
// Wires spanner_v2 to:
//   * a TAG-BUFFER model (ti_mem): 1024 x {valid,tag,invw,pt}, loaded by the C++ TB from
//     a spanner_input_<N>.txt vector. Responds to spanner_v2's 4-wide ALIGNED read port
//     with 1-cycle registered latency (matches taginvw_tile_buffer timing).
//   * sim_ddr_fb: the shared behavioral VRAM + faux DDR read controller, so the internal
//     record_fetcher fetches REAL param records (C++ loads spanner_test_vectors/vram.bin).
//   * result stores: triangle_setups[id] (written by SETUP) and span_out[idx] (written by
//     SPANGEN), both verilator public_flat_rw so the C++ can read them back after busy=0.
//
// Control inputs (start/shade_mode/xbase/ybase/param_base/intensity_shadow) are public so
// the C++ sets them from the vector header and pulses start.
//
module spanner_v2_tb_top import tsp_pkg::*; (
    input clk,
    input reset
);
    localparam integer NSLOT = 1024;

    // ---- control (driven by C++, public) ----
    (* verilator public_flat_rw *) reg        start;
    (* verilator public_flat_rw *) reg        shade_mode;
    (* verilator public_flat_rw *) reg [31:0] xbase, ybase;
    (* verilator public_flat_rw *) reg [26:0] param_base;
    (* verilator public_flat_rw *) reg        intensity_shadow;
    (* verilator public_flat_rw *) wire       busy;

    // ==================== TAG-BUFFER model (ti_mem) ====================
    // one 66-bit word per pixel: {pt, invw[31:0], tag[31:0], valid}. Public so C++ loads it.
    (* verilator public_flat_rw *) reg        tim_valid [0:NSLOT-1];
    (* verilator public_flat_rw *) reg [31:0] tim_tag   [0:NSLOT-1];
    (* verilator public_flat_rw *) reg [31:0] tim_invw  [0:NSLOT-1];
    (* verilator public_flat_rw *) reg        tim_pt    [0:NSLOT-1];

    wire        rd_valid;
    wire [9:0]  rd_group;
    reg  [3:0]  ti_valid;
    reg  [31:0] ti_tag  [0:3];
    reg  [31:0] ti_invw [0:3];
    reg  [3:0]  ti_pt;

    // 1-cycle registered read of the 4 aligned lanes [rd_group .. rd_group+3].
    integer li;
    always @(posedge clk) begin
        for (li = 0; li < 4; li = li + 1) begin
            ti_valid[li] <= tim_valid[rd_group + li[9:0]];
            ti_tag  [li] <= tim_tag  [rd_group + li[9:0]];
            ti_invw [li] <= tim_invw [rd_group + li[9:0]];
            ti_pt   [li] <= tim_pt   [rd_group + li[9:0]];
        end
    end

    // ==================== DUT OUT: triangle_setups + span_out ====================
    wire         ts_we;
    wire [9:0]   ts_id;
    wire [31:0]  ts_isp, ts_tsp, ts_tcw;
    wire [319:0] ts_ddx, ts_ddy, ts_c;

    // triangle_setups store (public). Split flat vectors into per-lane for easy C++ read.
    (* verilator public_flat_rw *) reg        tsg_valid [0:NSLOT-1];  // slot was written
    (* verilator public_flat_rw *) reg [31:0] tsg_isp   [0:NSLOT-1];
    (* verilator public_flat_rw *) reg [31:0] tsg_tsp   [0:NSLOT-1];
    (* verilator public_flat_rw *) reg [31:0] tsg_tcw   [0:NSLOT-1];
    (* verilator public_flat_rw *) reg [319:0] tsg_ddx  [0:NSLOT-1];
    (* verilator public_flat_rw *) reg [319:0] tsg_ddy  [0:NSLOT-1];
    (* verilator public_flat_rw *) reg [319:0] tsg_c    [0:NSLOT-1];
    always @(posedge clk) begin
        if (reset) begin end
        if (ts_we) begin
            tsg_valid[ts_id] <= 1'b1;
            tsg_isp  [ts_id] <= ts_isp;
            tsg_tsp  [ts_id] <= ts_tsp;
            tsg_tcw  [ts_id] <= ts_tcw;
            tsg_ddx  [ts_id] <= ts_ddx;
            tsg_ddy  [ts_id] <= ts_ddy;
            tsg_c    [ts_id] <= ts_c;
        end
    end

    // (the +planecheck refsw2 golden captures the per-id vertex record in C++ directly from
    // the DUT's live fv_* at ts_we; no RTL snapshot needed here.)

    wire         sp_we;
    wire [9:0]   sp_slot;
    wire [9:0]   sp_first, sp_last;
    wire         sp_cnt_z;
    wire [9:0]   sp_start;
    wire [9:0]   sp_id;
    wire [2:0]   sp_rep;
    wire [31:0]  sp_invw [0:3];
    wire         sp_at;

    // span_out store (public), one entry per run-start pixel index.
    (* verilator public_flat_rw *) reg        spo_valid [0:NSLOT-1];  // slot holds a span
    (* verilator public_flat_rw *) reg [9:0]  spo_x     [0:NSLOT-1];  // run-start pixel (sp_idx data)
    (* verilator public_flat_rw *) reg [9:0]  spo_id    [0:NSLOT-1];
    (* verilator public_flat_rw *) reg [2:0]  spo_rep   [0:NSLOT-1];
    (* verilator public_flat_rw *) reg [31:0] spo_invw0 [0:NSLOT-1];
    (* verilator public_flat_rw *) reg [31:0] spo_invw1 [0:NSLOT-1];
    (* verilator public_flat_rw *) reg [31:0] spo_invw2 [0:NSLOT-1];
    (* verilator public_flat_rw *) reg [31:0] spo_invw3 [0:NSLOT-1];
    (* verilator public_flat_rw *) reg        spo_at    [0:NSLOT-1];
`ifndef SYNTHESIS
    // +ddrtrace: log every DDR read request + data-ready window with a cycle stamp, to
    // audit the record_fetcher's burst behaviour.
    integer ddr_cyc;
    always @(posedge clk) begin
        ddr_cyc <= (reset || start) ? 0 : ddr_cyc + 1;
        if ($test$plusargs("ddrtrace")) begin
            if (ddr_req.rd)
                $display("[DDR c%0d] RD addr=%07x burst=%0d", ddr_cyc, ddr_req.addr, ddr_req.burst);
            if (ddr_resp.dready)
                $display("[DDR c%0d]   beat", ddr_cyc);
        end
    end
`endif

    // instrumentation: count emitted spans + cycles the DUT is busy (C++ reads these to
    // separate SPANGEN emit rate from the setup-drain tail).
    (* verilator public_flat_rw *) reg [31:0] setup_runs;   // ts_we pulses (incl re-setups)
    (* verilator public_flat_rw *) reg [31:0] emit_count;
    (* verilator public_flat_rw *) reg [31:0] busy_cycles;
    (* verilator public_flat_rw *) reg [31:0] last_emit_cyc;   // busy_cycles at the last sp_we
    always @(posedge clk) begin
        if (reset || start) begin emit_count <= 0; busy_cycles <= 0; last_emit_cyc <= 0; setup_runs <= 0; end
        else begin
            if (busy) busy_cycles <= busy_cycles + 1;
            if (sp_we) begin emit_count <= emit_count + 1; last_emit_cyc <= busy_cycles; end
            if (ts_we) setup_runs <= setup_runs + 1;
        end
    end
    always @(posedge clk) begin
        if (sp_we) begin                       // DENSE: write at sp_slot, run-start px as data
            spo_valid [sp_slot] <= 1'b1;
            spo_x     [sp_slot] <= sp_start;
            spo_id    [sp_slot] <= sp_id;
            spo_rep   [sp_slot] <= sp_rep;
            spo_invw0 [sp_slot] <= sp_invw[0];
            spo_invw1 [sp_slot] <= sp_invw[1];
            spo_invw2 [sp_slot] <= sp_invw[2];
            spo_invw3 [sp_slot] <= sp_invw[3];
            spo_at    [sp_slot] <= sp_at;
        end
    end

    // ==================== DDR backend ====================
    ddr_rd_req_t  ddr_req;
    ddr_rd_resp_t ddr_resp;
    fb_wr_req_t   fbw_req;
    fb_wr_resp_t  fbw_resp;
    assign fbw_req = '0;   // spanner_v2 never writes the framebuffer

    sim_ddr_fb u_sim (
        .clk(clk), .reset(reset),
        .ddr_req(ddr_req), .ddr_resp(ddr_resp),
        .fbw_req(fbw_req), .fbw_resp(fbw_resp)
    );

    // ==================== DUT ====================
    (* verilator public_flat_rw *) wire tsp_go;
    (* verilator public_flat_rw *) reg  tsp_rd_done;
    spanner_v2 #(.NSLOT(NSLOT), .SLOTW(10)) u_dut (
        .clk(clk), .reset(reset),
        .start(start), .busy(busy), .shade_mode(shade_mode),
        .xbase(xbase), .ybase(ybase), .param_base(param_base),
        .intensity_shadow(intensity_shadow),
        .tsp_go(tsp_go), .tsp_rd_done(tsp_rd_done),
        .rd_valid(rd_valid), .rd_group(rd_group),
        .ti_valid(ti_valid), .ti_tag(ti_tag), .ti_invw(ti_invw), .ti_pt(ti_pt),
        .ts_we(ts_we), .ts_id(ts_id),
        .ts_isp(ts_isp), .ts_tsp(ts_tsp), .ts_tcw(ts_tcw),
        .ts_ddx(ts_ddx), .ts_ddy(ts_ddy), .ts_c(ts_c),
        .sp_we(sp_we), .sp_slot(sp_slot), .sp_first(sp_first), .sp_last(sp_last),
        .sp_cnt_z(sp_cnt_z), .sp_start(sp_start), .sp_id(sp_id), .sp_rep(sp_rep),
        .sp_invw(sp_invw), .sp_at(sp_at), .sp_ready(1'b1),
        .dreq(ddr_req), .dresp(ddr_resp)
    );
endmodule

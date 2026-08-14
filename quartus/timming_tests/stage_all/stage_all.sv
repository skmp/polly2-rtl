//
// stage_all - synthesis/timing harness that wraps the WHOLE tsp_shade_pp pipeline.
// (Formerly tsp_shade_pp_ddr / the shade_pp project.) The whole-pipeline
// counterpart to the per-stage stage_* harnesses in timming_tests/.
//
// Purpose: place-and-route + timing-close tsp_shade_pp in isolation so the fitter
// reports Fmax/area for JUST the shade pipeline (and its two injected texture
// caches), decoupled from the rest of peel_core. Structured like mister_top:
//   * the HPS DDR3 bridge (sysmem_lite) supplies core clk/reset + one Avalon read
//     port (ram1). ram2/vbuf are tied off (no framebuffer write, no vbuf).
//   * the texel path is ONE arbiter client now, so there is no local arbiter copy:
//     tex_fill_engine does the tc/vq/scan muxing inside the texel path (which is the
//     point of that change - keep it local, off the long haul to peel_core's arbiter),
//     and every other client here was tied off anyway. Wiring the single client straight
//     to the DDR master is what the shipping logic looks like.
//   * two real tex_cache_4p_1c caches (data + VQ) plus their tex_fill_engine back the 4
//     corner fetchers, exactly as tex_fetch4_ob wires u_tc4 / u_vq4 / u_fill. This
//     preserves the UV-register -> tex_addr -> M10K-address paths you profile.
//
// To keep the pin count tiny (and stop the fitter optimizing the DUT away):
//   * ALL tsp_shade_pp inputs are driven from a single free-running input register
//     bank (in_reg) that the HPS pokes via wr_en/wr_addr/wr_data. Every input bit
//     therefore has a real register source, so input paths are realistic.
//   * ALL tsp_shade_pp outputs are captured into an output register (out_cap) and
//     then XOR-folded to a SINGLE `digest` pin. Nothing downstream can be pruned:
//     every output bit feeds the digest, so every output path is kept.
//
// This is NOT functionally meaningful - it renders nothing. It exists only to give
// tsp_shade_pp a self-contained fitting context for perf iteration.
//
module stage_all import tsp_pkg::*; #(
    parameter integer IDW = 11
) (
    // ---- HPS reset control (no DDR3 pins: DDR3 is on the HPS) ----
    input             reset_req,
    input             cold_req,
    output            core_clk,
    output            core_reset,

    // ---- input register load (driven by the HPS) ----
    input             wr_en,        // 1: in_reg[wr_addr] <= wr_data
    input      [12:0] wr_addr,
    input      [31:0] wr_data,

    // ---- single folded output pin (keeps every shade output alive) ----
    output reg        digest
);
    // ------------------------------------------------------------------
    // HPS DDR3 bridge (sysmem_lite): core clock/reset + one Avalon read port.
    // ------------------------------------------------------------------
    wire clk_100m, reset_100m;
    assign core_clk   = clk_100m;
    assign core_reset = reset_100m;

    // ram1 : DDR read channel (Avalon)
    wire        r1_clk = clk_100m;
    wire [28:0] r1_addr;
    wire  [7:0] r1_burstcnt;
    wire        r1_waitrequest;
    wire [63:0] r1_readdata;
    wire        r1_readdatavalid;
    wire        r1_read;

    sysmem_lite u_sysmem (
        .reset_core_req    (reset_req),
        .reset_out         (reset_100m),
        .clock             (clk_100m),
        .reset_hps_cold_req(cold_req),
        .reset_hps_warm_req(1'b0),

        // ram1 : reads (texture + VQ fills)
        .ram1_clk          (r1_clk),
        .ram1_address      (r1_addr),
        .ram1_burstcount   (r1_burstcnt),
        .ram1_waitrequest  (r1_waitrequest),
        .ram1_readdata     (r1_readdata),
        .ram1_readdatavalid(r1_readdatavalid),
        .ram1_read         (r1_read),
        .ram1_writedata    (64'd0),
        .ram1_byteenable   (8'hFF),
        .ram1_write        (1'b0),

        // ram2 : unused
        .ram2_clk          (clk_100m),
        .ram2_address      (29'd0),
        .ram2_burstcount   (8'd0),
        .ram2_waitrequest  (),
        .ram2_readdata     (),
        .ram2_readdatavalid(),
        .ram2_read         (1'b0),
        .ram2_writedata    (64'd0),
        .ram2_byteenable   (8'd0),
        .ram2_write        (1'b0),

        // vbuf : unused
        .vbuf_clk          (clk_100m),
        .vbuf_address      (28'd0),
        .vbuf_burstcount   (8'd0),
        .vbuf_waitrequest  (),
        .vbuf_readdata     (),
        .vbuf_readdatavalid(),
        .vbuf_read         (1'b0),
        .vbuf_writedata    (128'd0),
        .vbuf_byteenable   (16'd0),
        .vbuf_write        (1'b0)
    );

    // ==================================================================
    // DDR READ master: arbiter ddr_req/ddr_resp  <->  Avalon ram1. Identical to
    // mister_top's read master (one burst read in flight at a time).
    // ==================================================================
    ddr_rd_req_t  ddr_req;  ddr_rd_resp_t ddr_resp;

    reg        rd_inflight;
    reg [7:0]  rd_left;
    wire       rd_issue = ddr_req.rd && !rd_inflight;
    assign r1_read     = rd_issue;
    assign r1_addr     = ddr_req.addr;
    assign r1_burstcnt = ddr_req.burst;

    assign ddr_resp.busy   = rd_inflight || (rd_issue && r1_waitrequest);
    assign ddr_resp.dout   = r1_readdata;
    assign ddr_resp.dready = r1_readdatavalid;

    always @(posedge clk_100m) begin
        if (reset_100m) begin
            rd_inflight <= 1'b0; rd_left <= 8'd0;
        end else begin
            if (!rd_inflight) begin
                if (rd_issue && !r1_waitrequest) begin
                    rd_inflight <= 1'b1;
                    rd_left     <= ddr_req.burst;
                end
            end else if (r1_readdatavalid) begin
                if (rd_left <= 8'd1) rd_inflight <= 1'b0;
                rd_left <= rd_left - 8'd1;
            end
        end
    end

    // ==================================================================
    // REAL peel_core DDR read arbiter (verbatim). Six clients, priority high->low:
    //   0=tc 1=vq 2=ts 3=pr 4=ol 5=ra.
    // Only tc/vq are live here; ts/pr/ol/ra requests are tied to 0 (below) so the
    // arbiter never grants them, but the arbiter LOGIC is exactly as in peel_core.
    // ==================================================================
    ddr_rd_req_t  ra_dreq, ol_dreq, pr_dreq, ts_dreq;
    ddr_rd_resp_t ra_dresp, ol_dresp, pr_dresp, ts_dresp;
    ddr_rd_req_t  tex_dreq;  ddr_rd_resp_t tex_dresp;
    // ---- texel path: ONE client, wired straight to the DDR master ----
    // The texel path used to present 2-3 clients here and this harness carried a private
    // copy of peel_core's arbiter to mux them. tex_fill_engine now does that muxing INSIDE
    // the texel path (which is the point of the change - keep it local, off the long haul
    // to the arbiter), and every other client in this harness is tied off, so the local
    // arbiter was pure overhead and would have misrepresented the logic under test.
    assign ddr_req = tex_dreq;
    assign tex_dresp = ddr_resp;

    // --- unused clients: no request (arbiter never grants) ---
    assign ra_dreq = '0;
    assign ol_dreq = '0;
    assign pr_dreq = '0;
    assign ts_dreq = '0;

    // (the local arbiter copy is gone with the multi-client texel interface)

    // ==================================================================
    // Two real texture caches backing the 4 corner fetchers (as peel_core does).
    // ==================================================================
    cache_req_t   pp_tc_req [0:3], pp_vq_req [0:3];
    cache_resp_t  pp_tc_resp[0:3], pp_vq_resp[0:3];
    wire         a_tcm_v, a_tcm_ack, a_tcf_req, a_tcf_gnt, a_tcd_done;
    wire [26:0]  a_tcm_line, a_tcf_line;  wire [255:0] a_tcf_data;
    wire         a_vqm_v, a_vqm_ack, a_vqf_req, a_vqf_gnt, a_vqd_done;
    wire [26:0]  a_vqm_line, a_vqf_line;  wire [255:0] a_vqf_data;
    tex_cache_4p_1c u_tc4 (.clk(clk_100m),.reset(reset_100m),.flush(1'b0),
        .creq(pp_tc_req),.cresp(pp_tc_resp),.pf_req(1'b0),.pf_waddr({(4*29){1'b0}}),
        .pf_gnt(),.pf_ack(),.pf_hit(),.pf_busy(),
        .miss_v(a_tcm_v),.miss_line(a_tcm_line),.miss_ack(a_tcm_ack),
        .fill_req(a_tcf_req),.fill_line(a_tcf_line),.fill_data(a_tcf_data),
        .fill_gnt(a_tcf_gnt),.demand_done(a_tcd_done));
    tex_cache_4p_1c u_vq4 (.clk(clk_100m),.reset(reset_100m),.flush(1'b0),
        .creq(pp_vq_req),.cresp(pp_vq_resp),.pf_req(1'b0),.pf_waddr({(4*29){1'b0}}),
        .pf_gnt(),.pf_ack(),.pf_hit(),.pf_busy(),
        .miss_v(a_vqm_v),.miss_line(a_vqm_line),.miss_ack(a_vqm_ack),
        .fill_req(a_vqf_req),.fill_line(a_vqf_line),.fill_data(a_vqf_data),
        .fill_gnt(a_vqf_gnt),.demand_done(a_vqd_done));
    tex_fill_engine u_fill (.clk(clk_100m),.reset(reset_100m),.flush(1'b0),
        .col_miss_v(a_tcm_v),.col_miss_line(a_tcm_line),.col_miss_ack(a_tcm_ack),
        .scan_v(1'b0),.scan_line(27'd0),.scan_ack(),
        .col_fill_req(a_tcf_req),.col_fill_line(a_tcf_line),.col_fill_data(a_tcf_data),
        .col_fill_gnt(a_tcf_gnt),.col_demand_done(a_tcd_done),
        .vq_miss_v(a_vqm_v),.vq_miss_line(a_vqm_line),.vq_miss_ack(a_vqm_ack),
        .vq_fill_req(a_vqf_req),.vq_fill_line(a_vqf_line),.vq_fill_data(a_vqf_data),
        .vq_fill_gnt(a_vqf_gnt),.vq_demand_done(a_vqd_done),
        .dreq(tex_dreq),.dresp(tex_dresp));

    // ==================================================================
    // INPUT REGISTER BANK. The HPS writes 32-bit words at wr_addr; the DUT inputs
    // are slices of this bank so every input bit has a real register source. Layout
    // (word index -> field). 10 planes x 3 (ddx/ddy/c) = 30 words, plus scalars.
    //   0..9   : in_ddx[0..9]
    //   10..19 : in_ddy[0..9]
    //   20..29 : in_c  [0..9]
    //   30     : invw_in
    //   31     : tsp
    //   32     : tcw
    //   33     : { pp_offset, pp_texture, in_valid, text_ctrl[4:0], py[4:0], px[4:0], in_id[IDW-1:0] }
    // ==================================================================
    localparam integer NREG = 34;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk_100m) begin
        if (reset_100m) begin
            for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        end else if (wr_en && wr_addr < NREG) begin
            in_reg[wr_addr] <= wr_data;
        end
    end

    // unpack the bank into DUT inputs
    wire [31:0] w_ddx [0:9];
    wire [31:0] w_ddy [0:9];
    wire [31:0] w_c   [0:9];
    genvar gp;
    generate
      for (gp=0; gp<10; gp=gp+1) begin : unpack_planes
        assign w_ddx[gp] = in_reg[gp];
        assign w_ddy[gp] = in_reg[10+gp];
        assign w_c[gp]   = in_reg[20+gp];
      end
    endgenerate

    wire [31:0] w_invw = in_reg[30];
    wire [31:0] w_tsp  = in_reg[31];
    wire [31:0] w_tcw  = in_reg[32];
    wire [31:0] w_ctl  = in_reg[33];
    wire [IDW-1:0] w_id   = w_ctl[IDW-1:0];
    wire [4:0]     w_px   = w_ctl[15:11];
    wire [4:0]     w_py   = w_ctl[20:16];
    wire [4:0]     w_tc   = w_ctl[25:21];
    wire           w_iv   = w_ctl[26];
    wire           w_ptex = w_ctl[27];
    wire           w_pofs = w_ctl[28];

    // ==================================================================
    // DUT: tsp_shade_pp (the module under test).
    // ==================================================================
    wire           s_out_valid;
    wire [IDW-1:0] s_out_id;
    wire [31:0]    s_out_argb;
    wire [31:0]    s_out_tsp;
    wire           s_stall;

    tsp_shade_pp #(.IDW(IDW)) u_shade (
        .clk(clk_100m), .reset(reset_100m),
        .in_valid(w_iv), .in_id(w_id), .px(w_px), .py(w_py), .invw_in(w_invw),
        .in_ddx(w_ddx), .in_ddy(w_ddy), .in_c(w_c),
        .tsp(w_tsp), .tcw(w_tcw), .text_ctrl(w_tc),
        .pp_texture(w_ptex), .pp_offset(w_pofs),
        .out_valid(s_out_valid), .out_id(s_out_id), .out_argb(s_out_argb),
        .out_tsp(s_out_tsp), .stall(s_stall),
        .tc_req(pp_tc_req), .tc_resp(pp_tc_resp),
        .vq_req(pp_vq_req), .vq_resp(pp_vq_resp));

    // ==================================================================
    // OUTPUT CAPTURE. Stage the RAW shade outputs into registers with NO logic in
    // between - so the DUT-output -> register path is the PURE tsp_shade_pp timing
    // (nothing but the flop's own setup on the far end). The XOR-fold that keeps
    // every bit alive happens ONE CYCLE LATER, off these registers, so its reduce
    // tree never contaminates the measured output paths.
    // ==================================================================
    reg [31:0]    cap_argb;
    reg [31:0]    cap_tsp;
    reg [IDW-1:0] cap_id;
    reg           cap_valid;
    reg           cap_stall;
    always @(posedge clk_100m) begin
        if (reset_100m) begin
            cap_argb <= 32'd0; cap_tsp <= 32'd0; cap_id <= '0;
            cap_valid <= 1'b0; cap_stall <= 1'b0;
        end else begin
            cap_argb  <= s_out_argb;   // raw - no combinational fold here
            cap_tsp   <= s_out_tsp;
            cap_id    <= s_out_id;
            cap_valid <= s_out_valid;
            cap_stall <= s_stall;
        end
    end

    // next cycle: XOR-fold the captured registers down to one `digest` pin so the
    // fitter cannot prune any output bit. This tree is OFF cap_* regs, not the DUT.
    always @(posedge clk_100m) begin
        if (reset_100m) digest <= 1'b0;
        else            digest <= ^{ cap_argb, cap_tsp, cap_id, cap_valid, cap_stall };
    end
endmodule

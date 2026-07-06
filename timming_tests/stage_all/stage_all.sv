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
//   * the REAL peel_core DDR read arbiter is used verbatim (6 clients, priority
//     high->low: tc, vq, ts, pr, ol, ra). Only the two texture clients (tc=0,
//     vq=1) are live; the four unused clients (ts/pr/ol/ra) have their request
//     structs tied to 0 so the arbiter never grants them - but the arbiter logic
//     itself is unchanged, so its timing is representative.
//   * two real tex_cache_4p_1c caches (data + VQ) back the 4 corner fetchers,
//     exactly as peel_core wires u_tc4 / u_vq4. This preserves the
//     UV-register -> tex_addr -> M10K-address paths you profile.
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
    ddr_rd_req_t  tex_dreq [0:1];      // [0]=tc data, [1]=vq codebook
    ddr_rd_resp_t tex_dresp [0:1];

    // --- unused clients: no request (arbiter never grants) ---
    assign ra_dreq = '0;
    assign ol_dreq = '0;
    assign pr_dreq = '0;
    assign ts_dreq = '0;

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
    reg        d_busy; reg [2:0] d_owner;
    reg [7:0]  d_beats;
    reg        d_issued;
    integer di;

    assign ddr_req.rd    = d_busy && !d_issued;
    assign ddr_req.addr  = pa[d_owner];
    assign ddr_req.burst = d_beats;

    always @(posedge clk_100m) begin
        if (reset_100m) begin d_busy <= 1'b0; pend <= 6'd0; d_issued <= 1'b0; end
        else begin
            for (di=0; di<6; di=di+1)
                if (rd_pulse[di]) begin pend[di] <= 1'b1; pa[di] <= ca[di]; pb[di] <= cbv[di]; end
            if (!d_busy) begin
                if (any_pend) begin
                    d_busy   <= 1'b1; d_owner <= d_win;
                    d_beats  <= pb[d_win];
                    d_issued <= 1'b0;
                    pend[d_win] <= (rd_pulse[d_win]);
                end
            end else begin
                if (ddr_req.rd && !ddr_resp.busy) d_issued <= 1'b1;
                if (ddr_resp.dready) begin
                    if (d_beats <= 8'd1) begin d_busy <= 1'b0; d_issued <= 1'b0; end
                    d_beats <= d_beats - 8'd1;
                end
            end
        end
    end
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

    // ==================================================================
    // Two real texture caches backing the 4 corner fetchers (as peel_core does).
    // ==================================================================
    cache_req_t   pp_tc_req [0:3], pp_vq_req [0:3];
    cache_resp_t  pp_tc_resp[0:3], pp_vq_resp[0:3];
    tex_cache_4p_1c u_tc4 (.clk(clk_100m),.reset(reset_100m),
        .creq(pp_tc_req),.cresp(pp_tc_resp),.dreq(tex_dreq[0]),.dresp(tex_dresp[0]));
    tex_cache_4p_1c u_vq4 (.clk(clk_100m),.reset(reset_100m),
        .creq(pp_vq_req),.cresp(pp_vq_resp),.dreq(tex_dreq[1]),.dresp(tex_dresp[1]));

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

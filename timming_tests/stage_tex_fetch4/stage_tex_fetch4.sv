//
// stage_tex_fetch4 - timing harness for tex_fetch4 (4-corner texel fetch: 4 addresses
// in -> 4 texels out; owns the 2 tex_cache_4p_1c caches).
//
// DDR-backed harness (like stage_tex): the HPS sysmem_lite bridge + one Avalon read
// master + the REAL peel_core DDR read arbiter (unused clients tied off) mux tex_fetch4's
// two DDR ports (tc, vq) onto the single DDR read channel. An HPS-writable input bank
// feeds the per-corner byte addresses + offsets + shared decode config; the 4 argb (+
// out_valid/in_ready) are raw-captured and XOR-folded to `digest`.
//
module stage_tex_fetch4 import tsp_pkg::*; (
    input             reset_req,
    input             cold_req,
    output            core_clk,
    output            core_reset,
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    output reg        digest
);
    // ------------------------------------------------------------------
    // HPS DDR3 bridge (sysmem_lite): core clock/reset + one Avalon read port.
    // ------------------------------------------------------------------
    wire clk_100m, reset_100m;
    assign core_clk   = clk_100m;
    assign core_reset = reset_100m;

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
        .ram2_clk          (clk_100m),
        .ram2_address      (29'd0), .ram2_burstcount(8'd0), .ram2_waitrequest(),
        .ram2_readdata(), .ram2_readdatavalid(), .ram2_read(1'b0),
        .ram2_writedata(64'd0), .ram2_byteenable(8'd0), .ram2_write(1'b0),
        .vbuf_clk          (clk_100m),
        .vbuf_address(28'd0), .vbuf_burstcount(8'd0), .vbuf_waitrequest(),
        .vbuf_readdata(), .vbuf_readdatavalid(), .vbuf_read(1'b0),
        .vbuf_writedata(128'd0), .vbuf_byteenable(16'd0), .vbuf_write(1'b0)
    );

    // ---- DDR read master (Avalon ram1) ----
    ddr_rd_req_t  ddr_req;  ddr_rd_resp_t ddr_resp;
    reg        rd_inflight; reg [7:0]  rd_left;
    wire       rd_issue = ddr_req.rd && !rd_inflight;
    assign r1_read = rd_issue; assign r1_addr = ddr_req.addr; assign r1_burstcnt = ddr_req.burst;
    assign ddr_resp.busy   = rd_inflight || (rd_issue && r1_waitrequest);
    assign ddr_resp.dout   = r1_readdata;
    assign ddr_resp.dready = r1_readdatavalid;
    always @(posedge clk_100m) begin
        if (reset_100m) begin rd_inflight <= 1'b0; rd_left <= 8'd0; end
        else begin
            if (!rd_inflight) begin
                if (rd_issue && !r1_waitrequest) begin rd_inflight<=1'b1; rd_left<=ddr_req.burst; end
            end else if (r1_readdatavalid) begin
                if (rd_left <= 8'd1) rd_inflight <= 1'b0;
                rd_left <= rd_left - 8'd1;
            end
        end
    end

    // ---- REAL peel_core DDR read arbiter (verbatim; only tc/vq clients live) ----
    ddr_rd_req_t  ra_dreq, ol_dreq, pr_dreq, ts_dreq;
    ddr_rd_resp_t ra_dresp, ol_dresp, pr_dresp, ts_dresp;
    ddr_rd_req_t  tex_dreq [0:1];
    ddr_rd_resp_t tex_dresp [0:1];
    assign ra_dreq = '0; assign ol_dreq = '0; assign pr_dreq = '0; assign ts_dreq = '0;

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
    reg        d_busy; reg [2:0] d_owner; reg [7:0]  d_beats; reg d_issued;
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
                    d_busy<=1'b1; d_owner<=d_win; d_beats<=pb[d_win]; d_issued<=1'b0;
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
    assign ts_dresp.busy=d_busy||pend[2]; assign pr_dresp.busy=d_busy||pend[3];
    assign ol_dresp.busy=d_busy||pend[4]; assign ra_dresp.busy=d_busy||pend[5];
    assign tex_dresp[0].dout=ddr_resp.dout; assign tex_dresp[1].dout=ddr_resp.dout;
    assign ts_dresp.dout=ddr_resp.dout; assign pr_dresp.dout=ddr_resp.dout;
    assign ol_dresp.dout=ddr_resp.dout; assign ra_dresp.dout=ddr_resp.dout;
    assign tex_dresp[0].dready = ddr_resp.dready && (d_owner==3'd0);
    assign tex_dresp[1].dready = ddr_resp.dready && (d_owner==3'd1);
    assign ts_dresp.dready=ddr_resp.dready&&(d_owner==3'd2);
    assign pr_dresp.dready=ddr_resp.dready&&(d_owner==3'd3);
    assign ol_dresp.dready=ddr_resp.dready&&(d_owner==3'd4);
    assign ra_dresp.dready=ddr_resp.dready&&(d_owner==3'd5);

    // ---- input register bank ----
    //   0..3 : tex_offset[0..3]  (22b each, bytes)
    //   4    : tex_addr[20:0]    (data base, 64-bit-word)
    //   5    : vq_addr[20:0]     (VQ codebook base, 64-bit-word)
    //   6    : { in_valid[2], vq[1], tex[0] }
    localparam integer NREG = 16;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk_100m) begin
        if (reset_100m) for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        else if (wr_en && wr_addr < NREG) in_reg[wr_addr] <= wr_data;
    end
    wire [21:0] tex_offset [0:3];
    genvar gp;
    generate for (gp=0; gp<4; gp=gp+1) begin : unpack
        assign tex_offset[gp] = in_reg[gp][21:0];
    end endgenerate
    wire [20:0] w_texaddr = in_reg[4][20:0];
    wire [20:0] w_vqaddr  = in_reg[5][20:0];
    wire        w_tex     = in_reg[6][0];
    wire        w_vq      = in_reg[6][1];
    wire        w_iv      = in_reg[6][2];

    // ---- DUT: tex_fetch4 (rewrite: raw 64-bit words out) ----
    wire [63:0] texel [0:3];
    wire        tex_ov, tex_ready;
    tex_fetch4_ob u_dut (
        .clk(clk_100m),.reset(reset_100m),
        .in_valid(w_iv),.tex(w_tex),.vq(w_vq),.in_ready(tex_ready),
        .tex_addr(w_texaddr),.vq_addr(w_vqaddr),.tex_offset(tex_offset),
        .out_valid(tex_ov),.texel(texel),
        .ddr_req(tex_dreq),.ddr_resp(tex_dresp));

    // ---- OUTPUT FOLD (no output buffer): tex_fetch4_ob is OUTPUT-BUFFERED (texel/
    //      out_valid come straight off its T2 register), so the harness adds NO capture
    //      register - it XOR-folds the DUT's registered outputs directly into `digest`.
    //      The measured path is the DUT's internal register -> its output pin (the thing
    //      we want to time); the fold into digest is just keep-alive. ----
    always @(posedge clk_100m) begin
        if (reset_100m) digest <= 1'b0;
        else            digest <= ^{ texel[0]^texel[1]^texel[2]^texel[3], tex_ov, tex_ready };
    end
endmodule

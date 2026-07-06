//
// stage_tex_unit - timing harness for tex_unit (the full texture pipeline).
//
// DDR-backed (tex_fetch4_ob owns the caches): HPS sysmem_lite bridge + Avalon read master
// + the REAL peel_core DDR read arbiter (unused clients tied off) mux tex_unit's two DDR
// ports. The harness also provides the 4 INJECTED palette RAMs (one per corner decoder).
// Inputs come from an HPS-writable bank; outputs (argb/id/valid/in_ready) fold to `digest`.
//
module stage_tex_unit import tsp_pkg::*; (
    input             reset_req,
    input             cold_req,
    output            core_clk,
    output            core_reset,
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    output reg        digest
);
    wire clk_100m, reset_100m;
    assign core_clk   = clk_100m;
    assign core_reset = reset_100m;

    wire        r1_clk = clk_100m;
    wire [28:0] r1_addr; wire [7:0] r1_burstcnt; wire r1_waitrequest;
    wire [63:0] r1_readdata; wire r1_readdatavalid; wire r1_read;

    sysmem_lite u_sysmem (
        .reset_core_req(reset_req),.reset_out(reset_100m),.clock(clk_100m),
        .reset_hps_cold_req(cold_req),.reset_hps_warm_req(1'b0),
        .ram1_clk(r1_clk),.ram1_address(r1_addr),.ram1_burstcount(r1_burstcnt),
        .ram1_waitrequest(r1_waitrequest),.ram1_readdata(r1_readdata),
        .ram1_readdatavalid(r1_readdatavalid),.ram1_read(r1_read),
        .ram1_writedata(64'd0),.ram1_byteenable(8'hFF),.ram1_write(1'b0),
        .ram2_clk(clk_100m),.ram2_address(29'd0),.ram2_burstcount(8'd0),.ram2_waitrequest(),
        .ram2_readdata(),.ram2_readdatavalid(),.ram2_read(1'b0),
        .ram2_writedata(64'd0),.ram2_byteenable(8'd0),.ram2_write(1'b0),
        .vbuf_clk(clk_100m),.vbuf_address(28'd0),.vbuf_burstcount(8'd0),.vbuf_waitrequest(),
        .vbuf_readdata(),.vbuf_readdatavalid(),.vbuf_read(1'b0),
        .vbuf_writedata(128'd0),.vbuf_byteenable(16'd0),.vbuf_write(1'b0)
    );

    // ---- DDR read master (Avalon ram1) ----
    ddr_rd_req_t  ddr_req;  ddr_rd_resp_t ddr_resp;
    reg  rd_inflight; reg [7:0] rd_left;
    wire rd_issue = ddr_req.rd && !rd_inflight;
    assign r1_read = rd_issue; assign r1_addr = ddr_req.addr; assign r1_burstcnt = ddr_req.burst;
    assign ddr_resp.busy = rd_inflight || (rd_issue && r1_waitrequest);
    assign ddr_resp.dout = r1_readdata; assign ddr_resp.dready = r1_readdatavalid;
    always @(posedge clk_100m) begin
        if (reset_100m) begin rd_inflight<=1'b0; rd_left<=8'd0; end
        else begin
            if (!rd_inflight) begin
                if (rd_issue && !r1_waitrequest) begin rd_inflight<=1'b1; rd_left<=ddr_req.burst; end
            end else if (r1_readdatavalid) begin
                if (rd_left<=8'd1) rd_inflight<=1'b0; rd_left<=rd_left-8'd1;
            end
        end
    end

    // ---- REAL peel_core DDR read arbiter (only tc/vq live) ----
    ddr_rd_req_t  ra_dreq, ol_dreq, pr_dreq, ts_dreq;
    ddr_rd_resp_t ra_dresp, ol_dresp, pr_dresp, ts_dresp;
    ddr_rd_req_t  tex_dreq [0:1]; ddr_rd_resp_t tex_dresp [0:1];
    assign ra_dreq='0; assign ol_dreq='0; assign pr_dreq='0; assign ts_dreq='0;
    reg  [5:0] pend; reg [28:0] pa [0:5]; reg [7:0] pb [0:5];
    wire [5:0] rd_pulse = {ra_dreq.rd,ol_dreq.rd,pr_dreq.rd,ts_dreq.rd,tex_dreq[1].rd,tex_dreq[0].rd};
    wire [28:0] ca [0:5]; wire [7:0] cbv [0:5];
    assign ca[0]=tex_dreq[0].addr; assign cbv[0]=tex_dreq[0].burst;
    assign ca[1]=tex_dreq[1].addr; assign cbv[1]=tex_dreq[1].burst;
    assign ca[2]=ts_dreq.addr; assign cbv[2]=ts_dreq.burst;
    assign ca[3]=pr_dreq.addr; assign cbv[3]=pr_dreq.burst;
    assign ca[4]=ol_dreq.addr; assign cbv[4]=ol_dreq.burst;
    assign ca[5]=ra_dreq.addr; assign cbv[5]=ra_dreq.burst;
    wire any_pend = |pend;
    wire [2:0] d_win = pend[0]?3'd0:pend[1]?3'd1:pend[2]?3'd2:pend[3]?3'd3:pend[4]?3'd4:3'd5;
    reg d_busy; reg [2:0] d_owner; reg [7:0] d_beats; reg d_issued; integer di;
    assign ddr_req.rd=d_busy&&!d_issued; assign ddr_req.addr=pa[d_owner]; assign ddr_req.burst=d_beats;
    always @(posedge clk_100m) begin
        if (reset_100m) begin d_busy<=1'b0; pend<=6'd0; d_issued<=1'b0; end
        else begin
            for (di=0;di<6;di=di+1) if (rd_pulse[di]) begin pend[di]<=1'b1; pa[di]<=ca[di]; pb[di]<=cbv[di]; end
            if (!d_busy) begin
                if (any_pend) begin d_busy<=1'b1; d_owner<=d_win; d_beats<=pb[d_win]; d_issued<=1'b0; pend[d_win]<=rd_pulse[d_win]; end
            end else begin
                if (ddr_req.rd && !ddr_resp.busy) d_issued<=1'b1;
                if (ddr_resp.dready) begin if (d_beats<=8'd1) begin d_busy<=1'b0; d_issued<=1'b0; end d_beats<=d_beats-8'd1; end
            end
        end
    end
    assign tex_dresp[0].busy=d_busy||pend[0]; assign tex_dresp[1].busy=d_busy||pend[1];
    assign ts_dresp.busy=d_busy||pend[2]; assign pr_dresp.busy=d_busy||pend[3];
    assign ol_dresp.busy=d_busy||pend[4]; assign ra_dresp.busy=d_busy||pend[5];
    assign tex_dresp[0].dout=ddr_resp.dout; assign tex_dresp[1].dout=ddr_resp.dout;
    assign ts_dresp.dout=ddr_resp.dout; assign pr_dresp.dout=ddr_resp.dout;
    assign ol_dresp.dout=ddr_resp.dout; assign ra_dresp.dout=ddr_resp.dout;
    assign tex_dresp[0].dready=ddr_resp.dready&&(d_owner==3'd0);
    assign tex_dresp[1].dready=ddr_resp.dready&&(d_owner==3'd1);
    assign ts_dresp.dready=ddr_resp.dready&&(d_owner==3'd2);
    assign pr_dresp.dready=ddr_resp.dready&&(d_owner==3'd3);
    assign ol_dresp.dready=ddr_resp.dready&&(d_owner==3'd4);
    assign ra_dresp.dready=ddr_resp.dready&&(d_owner==3'd5);

    // ---- 4 injected palette RAMs (1024x32, 1-cycle registered read) ----
    wire [9:0]  pal_addr [0:3];
    reg  [31:0] pal_data [0:3];
    genvar pgi;
    generate for (pgi=0; pgi<4; pgi=pgi+1) begin : pal
        (* ramstyle = "M10K" *) reg [31:0] pram [0:1023];
        integer pj; initial for (pj=0;pj<1024;pj=pj+1) pram[pj]={8'hFF, pj[7:0], pj[9:2], pj[7:0]};
        always @(posedge clk_100m) pal_data[pgi] <= pram[pal_addr[pgi]];
    end endgenerate

    // ---- input register bank ----
    //   0 : u (float)   1 : v (float)   2 : tex_addr_in[20:0]
    //   3 : { igna[24], filter_mode[23:22], text_ctrl[21:17], palsel[16:11], pal_fmt[10:9],
    //         pixfmt[8:6], miplevel[5:2], ... }  (see slices)
    //   3 layout: [2:0]=texu [5:3]=texv [9:6]=miplevel [12:10]=pixfmt [14:13]=pal_fmt
    //             [20:15]=palsel [25:21]=text_ctrl [27:26]=filter_mode
    //   4 : { in_valid[8], id[.. wide], flags... }  layout below
    //   4 layout: [3:0]=clampu/clampv/flipu/flipv [4]=tex [5]=vq [6]=scan [7]=stride_sel
    //             [8]=mipmapped [9]=ignore_texa [10]=in_valid [21:11]=id
    localparam integer NREG = 16;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk_100m) begin
        if (reset_100m) for (ir=0;ir<NREG;ir=ir+1) in_reg[ir]<=32'd0;
        else if (wr_en && wr_addr<NREG) in_reg[wr_addr]<=wr_data;
    end
    wire [31:0] w_u = in_reg[0], w_v = in_reg[1];
    wire [20:0] w_texaddr = in_reg[2][20:0];
    wire [2:0]  w_texu = in_reg[3][2:0], w_texv = in_reg[3][5:3];
    wire [3:0]  w_mip  = in_reg[3][9:6];
    wire [2:0]  w_pixfmt = in_reg[3][12:10];
    wire [1:0]  w_palfmt = in_reg[3][14:13];
    wire [5:0]  w_palsel = in_reg[3][20:15];
    wire [4:0]  w_tctrl  = in_reg[3][25:21];
    wire [1:0]  w_filt   = in_reg[3][27:26];
    wire w_clampu=in_reg[4][0], w_clampv=in_reg[4][1], w_flipu=in_reg[4][2], w_flipv=in_reg[4][3];
    wire w_tex=in_reg[4][4], w_vq=in_reg[4][5], w_scan=in_reg[4][6], w_strd=in_reg[4][7];
    wire w_mm=in_reg[4][8], w_igna=in_reg[4][9], w_iv=in_reg[4][10];
    wire [10:0] w_id = in_reg[4][21:11];

    // ---- DUT ----
    wire        u_ready, u_ov;
    wire [10:0] u_oid;
    wire [31:0] u_argb;
    tex_unit #(.IDW(11)) u_dut (
        .clk(clk_100m),.reset(reset_100m),
        .in_valid(w_iv),.in_id(w_id),.u(w_u),.v(w_v),.texu(w_texu),.texv(w_texv),.miplevel(w_mip),
        .clampu(w_clampu),.clampv(w_clampv),.flipu(w_flipu),.flipv(w_flipv),
        .tex_addr_in(w_texaddr),.tex(w_tex),.vq(w_vq),.scan(w_scan),.stride_sel(w_strd),
        .mipmapped(w_mm),.pixfmt(w_pixfmt),.pal_fmt(w_palfmt),.palsel(w_palsel),
        .text_ctrl(w_tctrl),.filter_mode(w_filt),.ignore_texa(w_igna),
        .in_ready(u_ready),
        .out_valid(u_ov),.out_id(u_oid),.out_argb(u_argb),
        .pal_addr(pal_addr),.pal_data(pal_data),
        .ddr_req(tex_dreq),.ddr_resp(tex_dresp));

    // ---- output fold: tex_unit's outputs (argb/id/valid off tex_filter's registered
    //      output + the id delay line) go straight to digest. ----
    always @(posedge clk_100m) begin
        if (reset_100m) digest <= 1'b0;
        else            digest <= ^{ u_argb, u_oid, u_ov, u_ready };
    end
endmodule

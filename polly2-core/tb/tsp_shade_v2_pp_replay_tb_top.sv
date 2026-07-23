// tsp_shade_v2_pp_replay_tb_top - replay a recorded tsp pixel-input stream through
// tsp_shade_v2_pp over the scene's real VRAM + palette, and expose the output so the
// C++ TB can compare it against the EXPECTED output recorded alongside each input
// (tsp_test_traces.txt, produced by the known-good peel_core's +tsppipedump).
//
// tsp_shade_v2_pp OWNS its two texture caches (data + VQ) inside tex_unit and exposes
// TWO DDR read ports (tc, vq) to the parent. Here each of those two ports gets its own
// behavioral burst DDR reader over the SAME 64-bit VRAM. Palette + pal_fmt come from a
// reg_file loaded with the scene's pvr_regs dump (host writes via wr_*), exactly as
// peel_core wires them. text_ctrl is per-pixel (from the trace).
//
module tsp_shade_v2_pp_replay_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,

    // ---- host register/palette write path (load pvr_regs dump before replay) ----
    input             wr_en,
    input      [12:0]  wr_addr,
    input      [31:0] wr_data,

    // ---- per-pixel inputs (driven from the trace) ----
    input             pp_in_valid,
    input      [10:0] pp_in_id,
    input      [4:0]  px,
    input      [4:0]  py,
    input      [31:0] invw_in,
    input      [31:0] ddx0,ddx1,ddx2,ddx3,ddx4,ddx5,ddx6,ddx7,ddx8,ddx9,
    input      [31:0] ddy0,ddy1,ddy2,ddy3,ddy4,ddy5,ddy6,ddy7,ddy8,ddy9,
    input      [31:0] c0,c1,c2,c3,c4,c5,c6,c7,c8,c9,
    input      [31:0] tsp,
    input      [31:0] tcw,
    input      [4:0]  text_ctrl,
    input             pp_texture,
    input             pp_offset,

    // ---- outputs (compared in C++) ----
    output            pp_stall,
    output            pp_out_valid,
    output     [10:0] pp_out_id,
    output     [31:0] pp_out_argb,
    output     [31:0] pp_out_tsp
);
    // pack the flat plane inputs into arrays
    wire [31:0] a_ddx [0:9]; wire [31:0] a_ddy [0:9]; wire [31:0] a_c [0:9];
    assign a_ddx[0]=ddx0;assign a_ddx[1]=ddx1;assign a_ddx[2]=ddx2;assign a_ddx[3]=ddx3;assign a_ddx[4]=ddx4;
    assign a_ddx[5]=ddx5;assign a_ddx[6]=ddx6;assign a_ddx[7]=ddx7;assign a_ddx[8]=ddx8;assign a_ddx[9]=ddx9;
    assign a_ddy[0]=ddy0;assign a_ddy[1]=ddy1;assign a_ddy[2]=ddy2;assign a_ddy[3]=ddy3;assign a_ddy[4]=ddy4;
    assign a_ddy[5]=ddy5;assign a_ddy[6]=ddy6;assign a_ddy[7]=ddy7;assign a_ddy[8]=ddy8;assign a_ddy[9]=ddy9;
    assign a_c[0]=c0;assign a_c[1]=c1;assign a_c[2]=c2;assign a_c[3]=c3;assign a_c[4]=c4;
    assign a_c[5]=c5;assign a_c[6]=c6;assign a_c[7]=c7;assign a_c[8]=c8;assign a_c[9]=c9;

    // ---- behavioral VRAM shared by both texture-cache DDR ports (64-bit physical view) ----
    (* verilator public_flat_rw *) reg [63:0] vram [0:1048575];

    // BURST DDR read port (latched, 8-cycle latency, `burst` consecutive dready beats).
    // Matches the tex_cache_4p_1c fill contract (same reader as tsp_shade_pp_tb_top).
    `define DDRBURST(NM) \
        ddr_rd_req_t NM``_dreq; ddr_rd_resp_t NM``_dresp; \
        reg NM``_busy; reg [19:0] NM``_word; reg [7:0] NM``_beats, NM``_lat; \
        reg [63:0] NM``_do; reg NM``_dv; reg NM``_pend; reg [28:0] NM``_pa; reg [7:0] NM``_pb; \
        assign NM``_dresp.busy=NM``_busy||NM``_pend; assign NM``_dresp.dout=NM``_do; assign NM``_dresp.dready=NM``_dv; \
        always @(posedge clk) begin \
            NM``_dv<=0; \
            if(reset) begin NM``_busy<=0; NM``_pend<=0; end \
            else begin \
                if(NM``_dreq.rd) begin NM``_pend<=1; NM``_pa<=NM``_dreq.addr; NM``_pb<=NM``_dreq.burst; end \
                if(!NM``_busy) begin \
                    if(NM``_pend) begin NM``_busy<=1; NM``_word<=NM``_pa[19:0]; NM``_beats<=NM``_pb; NM``_lat<=8'd8; NM``_pend<=NM``_dreq.rd; end \
                end else if(NM``_lat!=0) NM``_lat<=NM``_lat-8'd1; \
                else begin NM``_do<=vram[NM``_word]; NM``_dv<=1; NM``_word<=NM``_word+20'd1; if(NM``_beats<=8'd1) NM``_busy<=0; NM``_beats<=NM``_beats-8'd1; end \
            end \
        end

    // v2 exposes ddr_req/ddr_resp as 2-element arrays ([0]=tc data, [1]=vq codebook).
    `DDRBURST(pd) `DDRBURST(pq)
    ddr_rd_req_t  sh_ddr_req  [0:1];
    ddr_rd_resp_t sh_ddr_resp [0:1];
    assign pd_dreq = sh_ddr_req[0];  assign sh_ddr_resp[0] = pd_dresp;
    assign pq_dreq = sh_ddr_req[1];  assign sh_ddr_resp[1] = pq_dresp;

    // ---- reg_file: palette RAM (4 ports) + pal_fmt, loaded from the pvr_regs dump ----
    pvr_regs_t   regs;
    fog_rd_req_t fog_req;  fog_rd_resp_t fog_resp;
    assign fog_req = '0;
    pal_rd_req_t  pal_req  [0:3];
    pal_rd_resp_t pal_resp [0:3];
    reg_file u_regs (
        .clk(clk),.reset(reset),
        .wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),
        .regs(regs),
        .fog_req(fog_req),.fog_resp(fog_resp),
        .pal_req(pal_req),.pal_resp(pal_resp));

    // shader palette ports <-> reg_file palette ports
    wire [9:0]  pp_pal_addr [0:3];
    wire [31:0] pp_pal_data [0:3];
    assign pal_req[0].raddr = pp_pal_addr[0]; assign pal_req[1].raddr = pp_pal_addr[1];
    assign pal_req[2].raddr = pp_pal_addr[2]; assign pal_req[3].raddr = pp_pal_addr[3];
    assign pp_pal_data[0] = pal_resp[0].rdata; assign pp_pal_data[1] = pal_resp[1].rdata;
    assign pp_pal_data[2] = pal_resp[2].rdata; assign pp_pal_data[3] = pal_resp[3].rdata;

    // ---- DUT: tsp_shade_v2_pp (IDW=11, as peel_core instantiates it) ----
    tsp_shade_v2_pp #(.IDW(11)) u_shade (
        .clk(clk),.reset(reset),.flush(1'b0),   // single replay: cold cache from reset, no per-render flush needed
        .in_valid(pp_in_valid),.in_id(pp_in_id),.px(px),.py(py),.invw_in(invw_in),
        .in_ddx(a_ddx),.in_ddy(a_ddy),.in_c(a_c),
        .tsp(tsp),.tcw(tcw),.text_ctrl(text_ctrl),
        .pal_fmt(regs.pal_ram_ctrl[1:0]),
        .pp_texture(pp_texture),.pp_offset(pp_offset),
        .out_valid(pp_out_valid),.out_id(pp_out_id),.out_argb(pp_out_argb),
        .out_tsp(pp_out_tsp),
        .stall(pp_stall),
        .pal_addr(pp_pal_addr),.pal_data(pp_pal_data),
        .ddr_req(sh_ddr_req),.ddr_resp(sh_ddr_resp));
endmodule

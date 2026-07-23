// shade_drop_tb_top - tsp_shade_v2_pp standalone, for the pixel-drop hunt
// (shade_drop_tb.cpp): the C++ side streams tile pixels in, serves the two
// DDR texture ports with adversarial latency/backpressure, and checks the
// pipe is strictly 1-in-1-out in-order (recv_logos loses 7.6% of pixels).
module shade_drop_tb_top import tsp_pkg::*; (
    input  wire        clk,
    input  wire        reset,
    input  wire        flush,

    // ---- pixel issue (planes flattened 10x32) ----
    input  wire         in_valid,
    input  wire [10:0]  in_id,
    input  wire [4:0]   px,
    input  wire [4:0]   py,
    input  wire [31:0]  invw,
    input  wire [319:0] ddx_flat,
    input  wire [319:0] ddy_flat,
    input  wire [319:0] c_flat,
    input  wire [31:0]  tsp,
    input  wire [31:0]  tcw,
    input  wire         pp_texture,
    output wire         stall,

    output wire         out_valid,
    output wire [10:0]  out_id,
    output wire [31:0]  out_argb,

    // ---- DDR read ports, flattened (0 = tc data, 1 = vq codebook) ----
    output wire         rd0,    output wire [28:0] addr0, output wire [7:0] burst0,
    input  wire         busy0,  input  wire [63:0] dout0, input  wire dready0,
    output wire         rd1,    output wire [28:0] addr1, output wire [7:0] burst1,
    input  wire         busy1,  input  wire [63:0] dout1, input  wire dready1
);
    wire [31:0] a_ddx [0:9];
    wire [31:0] a_ddy [0:9];
    wire [31:0] a_c   [0:9];
    genvar gi;
    generate for (gi = 0; gi < 10; gi = gi + 1) begin : unp
        assign a_ddx[gi] = ddx_flat[gi*32 +: 32];
        assign a_ddy[gi] = ddy_flat[gi*32 +: 32];
        assign a_c[gi]   = c_flat[gi*32 +: 32];
    end endgenerate

    // palette model: 1-cycle REGISTERED read per the tex_decode contract
    // ("the injected palette must be a 1-cycle registered read off pal_addr
    // so pal_data aligns to C2"), like reg_file's PAL RAM. Entry value is an
    // invertible function of the address so the C++ side can predict colors:
    //   f(a) = {a, a, a, 2'b11}
    wire [9:0] pal_addr [0:3];
    reg [31:0] pal_data [0:3];
    generate for (gi = 0; gi < 4; gi = gi + 1) begin : pal
        always @(posedge clk)
            pal_data[gi] <= {pal_addr[gi], pal_addr[gi], pal_addr[gi], 2'b11};
    end endgenerate

    ddr_rd_req_t  ddr_req  [0:1];
    ddr_rd_resp_t ddr_resp [0:1];
    assign rd0 = ddr_req[0].rd; assign addr0 = ddr_req[0].addr; assign burst0 = ddr_req[0].burst;
    assign rd1 = ddr_req[1].rd; assign addr1 = ddr_req[1].addr; assign burst1 = ddr_req[1].burst;
    always_comb begin
        ddr_resp[0].busy = busy0; ddr_resp[0].dout = dout0; ddr_resp[0].dready = dready0;
        ddr_resp[1].busy = busy1; ddr_resp[1].dout = dout1; ddr_resp[1].dready = dready1;
    end

    tsp_shade_v2_pp #(.IDW(11)) u_sh (
        .clk(clk), .reset(reset), .flush(flush),
        .in_valid(in_valid), .in_id(in_id), .px(px), .py(py), .invw_in(invw),
        .in_ddx(a_ddx), .in_ddy(a_ddy), .in_c(a_c),
        .tsp(tsp), .tcw(tcw), .text_ctrl(5'd0), .pal_fmt(2'd3),   // 8888 passthrough entries
        .pp_texture(pp_texture), .pp_offset(1'b0),
        .out_valid(out_valid), .out_id(out_id), .out_argb(out_argb), .out_tsp(),
        .stall(stall),
        .pal_addr(pal_addr), .pal_data(pal_data),
        .ddr_req(ddr_req), .ddr_resp(ddr_resp)
    );
endmodule

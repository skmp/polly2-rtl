//
// interp_unit_tb_top - flat-port wrapper around interp_unit for the directed
// latency/handshake test (interp_unit_tb.cpp).
//
// The 10 per-plane operand arrays are presented as flat 320-bit buses so the C++
// side can drive/read them as plain words; the unpack is here.
//
module interp_unit_tb_top (
    input              clk,
    input              reset,
    input              stall,
    input              in_valid,
    input      [319:0] ddx_f,
    input      [319:0] ddy_f,
    input      [319:0] c_f,
    input      [10:0]  px,
    input      [10:0]  py,
    input              half,
    input      [31:0]  w,
    output             out_valid,
    output     [319:0] attr_f
);
    wire [31:0] ddx [0:9];
    wire [31:0] ddy [0:9];
    wire [31:0] c   [0:9];
    wire [31:0] attr[0:9];

    genvar i;
    generate for (i = 0; i < 10; i = i + 1) begin : unpack
        assign ddx[i] = ddx_f[32*i +: 32];
        assign ddy[i] = ddy_f[32*i +: 32];
        assign c[i]   = c_f  [32*i +: 32];
        assign attr_f[32*i +: 32] = attr[i];
    end endgenerate

    interp_unit u_iv (
        .clk(clk), .reset(reset), .stall(stall), .in_valid(in_valid),
        .ddx(ddx), .ddy(ddy), .c(c),
        .px(px), .py(py), .half(half), .w(w),
        .out_valid(out_valid), .attr(attr)
    );
endmodule

// tsp_setup_stream (II=2, spp_ro units) vs tsp_setup_min, same triangle inputs.
// NOT bit-exact by design (stream drops the t15 delta truncation and fuses the c add),
// so the C++ driver compares BOTH against a double-precision reference and requires
// the stream's error to be comparable to min's. Also checks plane set/count/latency.
module tsp_setup_stream_tb_top (
    input             clk,
    input             reset,
    input             start_min,
    input             start_str,

    input             gouraud, texture, offset,
    input      [31:0] x1,y1,z1, x2,y2,z2, x3,y3,z3,
    input      [31:0] xbase, ybase,
    input      [31:0] u1,v1, u2,v2, u3,v3,
    input      [31:0] col1,col2,col3,
    input      [31:0] ofs1,ofs2,ofs3,

    output            done_min, pv_min,
    output [3:0]      pidx_min,
    output [31:0]     ddx_min, ddy_min, c_min,

    output            done_str, pv_str, rdy_str,
    output [3:0]      pidx_str,
    output [31:0]     ddx_str, ddy_str, c_str
);
    tsp_setup_min u_min (
        .clk(clk), .reset(reset), .start(start_min), .done(done_min),
        .gouraud(gouraud), .texture(texture), .offset(offset),
        .x1(x1),.y1(y1),.z1(z1), .x2(x2),.y2(y2),.z2(z2), .x3(x3),.y3(y3),.z3(z3),
        .xbase(xbase), .ybase(ybase),
        .u1(u1),.v1(v1), .u2(u2),.v2(v2), .u3(u3),.v3(v3),
        .col1(col1),.col2(col2),.col3(col3), .ofs1(ofs1),.ofs2(ofs2),.ofs3(ofs3),
        .plane_valid(pv_min), .plane_idx(pidx_min),
        .o_ddx(ddx_min), .o_ddy(ddy_min), .o_c(c_min));

    tsp_setup_stream u_str (
        .clk(clk), .reset(reset), .start(start_str), .rdy(rdy_str), .done(done_str),
        .gouraud(gouraud), .texture(texture), .offset(offset),
        .x1(x1),.y1(y1),.z1(z1), .x2(x2),.y2(y2),.z2(z2), .x3(x3),.y3(y3),.z3(z3),
        .xbase(xbase), .ybase(ybase),
        .u1(u1),.v1(v1), .u2(u2),.v2(v2), .u3(u3),.v3(v3),
        .col1(col1),.col2(col2),.col3(col3), .ofs1(ofs1),.ofs2(ofs2),.ofs3(ofs3),
        .plane_valid(pv_str), .plane_idx(pidx_str),
        .o_ddx(ddx_str), .o_ddy(ddy_str), .o_c(c_str));
endmodule

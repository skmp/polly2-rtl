// TB top: isp_setup_streamed vs isp_setup_min, same triangles, compare outputs.
//
// The C++ TB pushes triangles into the streamed unit (in_valid/in_ready) and, in
// lockstep, runs the SAME triangle through the reference isp_setup_min
// (start/done). It records each unit's plane-set output and checks bit-exact.
//
// Reference path: single-shot. Driver pulses ref_start with the triangle latched;
// ref_done pulses when its planes are ready (held on ref_* outputs).
// DUT path: streaming. Driver holds dut_in_valid + triangle until dut_in_ready;
// dut_out_valid pulses (possibly many cycles later) with that triangle's planes.
//
module isp_setup_streamed_tb_top (
    input             clk,
    input             reset,

    // shared triangle inputs
    input      [31:0] isp_word,
    input      [31:0] in_tag,
    input      [31:0] x1, input [31:0] y1, input [31:0] z1,
    input      [31:0] x2, input [31:0] y2, input [31:0] z2,
    input      [31:0] x3, input [31:0] y3, input [31:0] z3,
    input      [31:0] xbase, input [31:0] ybase,

    // ---- reference (isp_setup_min) ----
    input             ref_start,
    output            ref_done,
    output            ref_cull,
    output     [31:0] ref_dx12, output [31:0] ref_dx23, output [31:0] ref_dx31,
    output     [31:0] ref_dy12, output [31:0] ref_dy23, output [31:0] ref_dy31,
    output     [31:0] ref_c1,   output [31:0] ref_c2,   output [31:0] ref_c3,
    output     [31:0] ref_ddx,  output [31:0] ref_ddy,  output [31:0] ref_cinvw,
    output     [4:0]  ref_bx0,  output [4:0]  ref_bx1,  output [4:0]  ref_by0, output [4:0] ref_by1,

    // ---- DUT (isp_setup_streamed) ----
    input             dut_in_valid,
    output            dut_in_ready,
    input             dut_out_ready,   // driver stalls this to test backpressure
    output            dut_out_valid,
    output     [31:0] dut_out_tag,
    output            dut_cull,
    output     [31:0] dut_dx12, output [31:0] dut_dx23, output [31:0] dut_dx31,
    output     [31:0] dut_dy12, output [31:0] dut_dy23, output [31:0] dut_dy31,
    output     [31:0] dut_c1,   output [31:0] dut_c2,   output [31:0] dut_c3,
    output     [31:0] dut_ddx,  output [31:0] dut_ddy,  output [31:0] dut_cinvw,
    output     [4:0]  dut_bx0,  output [4:0]  dut_bx1,  output [4:0]  dut_by0, output [4:0] dut_by1
);
    // unused ref outputs
    wire        ref_sgn_neg;
    wire [31:0] ref_dx41, ref_dy41, ref_c4;

    isp_setup_min u_ref (
        .clk(clk), .reset(reset), .start(ref_start), .done(ref_done),
        .isp_word(isp_word),
        .x1(x1), .y1(y1), .z1(z1), .x2(x2), .y2(y2), .z2(z2), .x3(x3), .y3(y3), .z3(z3),
        .xbase(xbase), .ybase(ybase),
        .sgn_neg(ref_sgn_neg), .cull(ref_cull),
        .dx12(ref_dx12), .dx23(ref_dx23), .dx31(ref_dx31), .dx41(ref_dx41),
        .dy12(ref_dy12), .dy23(ref_dy23), .dy31(ref_dy31), .dy41(ref_dy41),
        .c1(ref_c1), .c2(ref_c2), .c3(ref_c3), .c4(ref_c4),
        .ddx_invw(ref_ddx), .ddy_invw(ref_ddy), .c_invw(ref_cinvw),
        .bx0(ref_bx0), .bx1(ref_bx1), .by0(ref_by0), .by1(ref_by1)
    );

    // unused DUT outputs
    wire        dut_sgn_neg, dut_busy;
    wire [31:0] dut_out_isp, dut_dx41, dut_dy41, dut_c4;

    isp_setup_streamed u_dut (
        .clk(clk), .reset(reset),
        .in_valid(dut_in_valid), .in_ready(dut_in_ready),
        .isp_word(isp_word), .in_tag(in_tag), .in_pt(1'b0),
        .x1(x1), .y1(y1), .z1(z1), .x2(x2), .y2(y2), .z2(z2), .x3(x3), .y3(y3), .z3(z3),
        .xbase(xbase), .ybase(ybase),
        .busy(dut_busy),
        .out_ready(dut_out_ready),
        .out_valid(dut_out_valid), .out_tag(dut_out_tag), .out_pt(/*unused*/), .out_isp(dut_out_isp),
        .sgn_neg(dut_sgn_neg), .cull(dut_cull),
        .dx12(dut_dx12), .dx23(dut_dx23), .dx31(dut_dx31), .dx41(dut_dx41),
        .dy12(dut_dy12), .dy23(dut_dy23), .dy31(dut_dy31), .dy41(dut_dy41),
        .c1(dut_c1), .c2(dut_c2), .c3(dut_c3), .c4(dut_c4),
        .ddx_invw(dut_ddx), .ddy_invw(dut_ddy), .c_invw(dut_cinvw),
        .bx0(dut_bx0), .bx1(dut_bx1), .by0(dut_by0), .by1(dut_by1)
    );
endmodule

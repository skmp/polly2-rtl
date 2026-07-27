// raster_topleft_tb_top - isp_setup_streamed feeding isp_raster_line, for the
// top-left-bias / exact-edge regression (raster_topleft_tb.cpp): a triangle is
// set up for one tile, its coefficients are captured, and the C++ side sweeps
// the 32x32 tile (plus the corner probe) comparing coverage against a
// refsw2-rule software model. Catches the C=+0 raw-decrement wrap that dropped
// whole tiles whose origin lies exactly on a non-top-left edge.
module raster_topleft_tb_top (
    input  wire        clk,
    input  wire        reset,

    // ---- setup issue (one triangle for one tile) ----
    input  wire        s_valid,
    output wire        s_ready,
    input  wire [31:0] x1, input wire [31:0] y1, input wire [31:0] z1,
    input  wire [31:0] x2, input wire [31:0] y2, input wire [31:0] z2,
    input  wire [31:0] x3, input wire [31:0] y3, input wire [31:0] z3,
    input  wire [31:0] xbase, input wire [31:0] ybase,
    input  wire        s_clear,        // clear s_done before the next triangle
    output reg         s_done,         // sticky: coefficients captured below
    output reg         s_cull,
    output reg  [31:0] c2_dbg,         // captured C2 (the v2->v3 edge constant)

    // ---- raster issue (uses the captured coefficients) ----
    input  wire        r_valid,
    input  wire        r_probe,
    input  wire [4:0]  r_y,
    input  wire [4:0]  r_xb,
    output wire        out_valid,
    output wire [7:0]  inside_mask,
    output wire [4:0]  out_x,
    output wire [4:0]  out_y,
    output wire        probe_valid,
    output wire        probe_reject
);
    wire        so_valid, w_cull;
    wire [31:0] w_dx12,w_dx23,w_dx31,w_dx41;
    wire [31:0] w_dy12,w_dy23,w_dy31,w_dy41;
    wire [31:0] w_c1,w_c2,w_c3,w_c4, w_ddx,w_ddy,w_cw;
    wire [3:0]  w_tl;

    isp_setup_streamed u_setup (
        .clk(clk), .reset(reset),
        .in_valid(s_valid), .in_ready(s_ready),
        .isp_word(32'd0), .in_tag(32'd0), .in_pt(1'b0), .quad(1'b0),
        .x1(x1),.y1(y1),.z1(z1), .x2(x2),.y2(y2),.z2(z2), .x3(x3),.y3(y3),.z3(z3),
        .x4(32'd0),.y4(32'd0),
        .xbase(xbase), .ybase(ybase),
        .busy(), .out_ready(1'b1), .out_valid(so_valid),
        .out_tag(), .out_pt(), .out_isp(), .sgn_neg(), .cull(w_cull),
        .dx12(w_dx12),.dx23(w_dx23),.dx31(w_dx31),.dx41(w_dx41),
        .dy12(w_dy12),.dy23(w_dy23),.dy31(w_dy31),.dy41(w_dy41),
        .c1(w_c1),.c2(w_c2),.c3(w_c3),.c4(w_c4),
        .out_tl(w_tl),
        .ddx_invw(w_ddx),.ddy_invw(w_ddy),.c_invw(w_cw),
        .bx0(),.bx1(),.by0(),.by1()
    );

    reg [31:0] rc1,rc2,rc3,rc4, rdx12,rdx23,rdx31,rdx41;
    reg [31:0] rdy12,rdy23,rdy31,rdy41, rddx,rddy,rcw;
    reg [3:0]  rtl;

    always @(posedge clk) begin
        if (reset || s_clear) s_done <= 1'b0;
        else if (so_valid) begin
            s_done <= 1'b1;
            s_cull <= w_cull;
            c2_dbg <= w_c2;
            rc1<=w_c1; rc2<=w_c2; rc3<=w_c3; rc4<=w_c4;
            rdx12<=w_dx12; rdx23<=w_dx23; rdx31<=w_dx31; rdx41<=w_dx41;
            rdy12<=w_dy12; rdy23<=w_dy23; rdy31<=w_dy31; rdy41<=w_dy41;
            rddx<=w_ddx; rddy<=w_ddy; rcw<=w_cw;
            rtl<=w_tl;
        end
    end

    isp_raster_line #(.LANES(8)) u_ras (
        .clk(clk), .reset(reset),
        .in_valid(r_valid), .y(r_y), .x_base(r_xb),
        .c1(rc1),.c2(rc2),.c3(rc3),.c4(rc4),
        .dx12(rdx12),.dx23(rdx23),.dx31(rdx31),.dx41(rdx41),
        .dy12(rdy12),.dy23(rdy23),.dy31(rdy31),.dy41(rdy41),
        .ddx(rddx),.ddy(rddy),.c_invw(rcw),
        .tl(rtl),
        .probe(r_probe), .probe_reject(probe_reject), .probe_valid(probe_valid),
        .out_valid(out_valid), .inside_mask(inside_mask), .invw_flat(),
        .out_x(out_x), .out_y(out_y)
    );
endmodule

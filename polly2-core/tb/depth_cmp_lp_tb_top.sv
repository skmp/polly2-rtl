// depth_cmp_lp_tb_top - thin wrapper around isp_depth_cmp_lp for depth_cmp_lp_tb.cpp.
// The compare is purely combinational, so the whole resolve LOOP (per-pass fragment
// sweep + PeelBuffers / PT boundary swap) lives on the C++ side; this top just exposes
// the DUT ports so the loop can be driven one fragment at a time, in either direction.
// TWO-LAYER PEEL: the TR side grew slot B (zbB/pbB_sort/validB in, pass_b/disp out);
// the C++ loop models the 2-slot insertion + the walk's B-then-reference advance.
module depth_cmp_lp_tb_top (
    input  wire        pt,
    input  wire [30:0] nw,
    input  wire [31:0] tag,
    input  wire [30:0] zb,
    input  wire [31:0] pb,
    input  wire [30:0] zb2,
    input  wire [23:0] pb2_sort,
    input  wire        valid,
    input  wire [30:0] zbB,
    input  wire [23:0] pbB_sort,
    input  wire        validB,
    output wire        pass,
    output wire        pass_b,
    output wire        disp,
    output wire        more
);
    isp_depth_cmp_lp u_dut (
        .en2(1'b1), .pt(pt), .nw(nw), .tag(tag), .zb(zb), .pb(pb), .zb2(zb2),
        .pb2_sort(pb2_sort), .valid(valid),
        .zbB(zbB), .pbB_sort(pbB_sort), .validB(validB),
        .pass(pass), .pass_b(pass_b), .disp(disp), .more(more));
endmodule

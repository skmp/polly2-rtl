// depth_cmp_lp_tb_top - thin wrapper around isp_depth_cmp_lp for depth_cmp_lp_tb.cpp.
// The compare is purely combinational, so the whole resolve LOOP (per-pass fragment
// sweep + PeelBuffers / PT boundary swap) lives on the C++ side; this top just exposes
// the DUT ports so the loop can be driven one fragment at a time, in either direction.
module depth_cmp_lp_tb_top (
    input  wire        pt,
    input  wire [30:0] nw,
    input  wire [31:0] tag,
    input  wire [30:0] zb,
    input  wire [31:0] pb,
    input  wire [30:0] zb2,
    input  wire [23:0] pb2_sort,
    input  wire        valid,
    output wire        pass,
    output wire        more
);
    isp_depth_cmp_lp u_dut (
        .pt(pt), .nw(nw), .tag(tag), .zb(zb), .pb(pb), .zb2(zb2),
        .pb2_sort(pb2_sort), .valid(valid), .pass(pass), .more(more));
endmodule

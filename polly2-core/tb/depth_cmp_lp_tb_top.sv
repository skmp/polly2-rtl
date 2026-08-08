// depth_cmp_lp_tb_top - thin wrapper around isp_depth_cmp_lp for depth_cmp_lp_tb.cpp.
// The compare is purely combinational, so the whole peel LOOP (per-pass fragment
// sweep + PeelBuffers swap) lives on the C++ side; this top just exposes the DUT
// ports so the loop can be driven one fragment at a time.
module depth_cmp_lp_tb_top (
    input  wire [30:0] nw,
    input  wire [31:0] tag,
    input  wire [30:0] zb,
    input  wire [30:0] zb2,
    input  wire [31:0] pb,
    input  wire [31:0] pb2,
    input  wire        valid,
    output wire        pass,
    output wire        more,
    output wire        o_nw_gt_zb,
    output wire        o_nw_lt_zb2
);
    isp_depth_cmp_lp u_dut (
        .nw(nw), .tag(tag), .zb(zb), .zb2(zb2), .pb(pb), .pb2(pb2), .valid(valid),
        .pass(pass), .more(more),
        .o_nw_gt_zb(o_nw_gt_zb), .o_nw_lt_zb2(o_nw_lt_zb2));
endmodule

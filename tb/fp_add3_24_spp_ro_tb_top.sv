// Bit-exactness harness for fp_add3_24_spp_ro vs the combinational fp_add3_24.
// Latency of the pipelined DUT is 3; the C++ driver delays the ref accordingly.
module fp_add3_24_spp_ro_tb_top (
    input             clk,
    input             reset,
    input             in_valid,
    input      [31:0] a,
    input      [31:0] b,
    input      [31:0] c,
    output            out_valid,
    output     [31:0] y,        // pipelined (registered, latency 3)
    output     [31:0] y_ref     // combinational ref for THIS cycle's inputs
);
    fp_add3_24_spp_ro dut (.clk(clk), .reset(reset), .stall(1'b0), .in_valid(in_valid),
                           .a(a), .b(b), .c(c), .out_valid(out_valid), .y(y));
    fp_add3_24 u_ref (.a(a), .b(b), .c(c), .y(y_ref));
endmodule

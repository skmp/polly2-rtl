// Bit-exactness harness for fp_mul_c9_spp_ro vs the combinational fp_mul_c9.
// Latency of the pipelined DUT is 2; FIFO-ordered compare in the C++ driver.
module fp_mul_c9_spp_ro_tb_top (
    input               clk,
    input               reset,
    input               in_valid,
    input        [31:0] f,
    input        [8:0]  k,
    output              out_valid,
    output       [31:0] y,        // pipelined (registered, latency 2)
    output       [31:0] y_ref     // combinational ref for THIS cycle's inputs
);
    fp_mul_c9_spp_ro dut (.clk(clk), .reset(reset), .stall(1'b0), .in_valid(in_valid),
                          .f(f), .k($signed(k)), .out_valid(out_valid), .y(y));
    fp_mul_c9 u_ref (.f(f), .k($signed(k)), .y(y_ref));
endmodule

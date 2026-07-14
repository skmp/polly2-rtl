// Bit-exactness harness for fp_mul16_spp_ro vs the combinational fp_mul16.
// Each clock: present (a,b) to the pipelined DUT AND to the combinational ref. The
// C++ driver delays the ref by the DUT latency (2) and checks y matches exactly when
// out_valid. Also exposes the combinational y for the SAME (a,b) presented this cycle.
module fp_mul16_spp_ro_tb_top (
    input             clk,
    input             reset,
    input             in_valid,
    input      [31:0] a,
    input      [31:0] b,
    output            out_valid,
    output     [31:0] y,        // pipelined (registered, latency 2)
    output     [31:0] y_ref     // combinational ref for THIS cycle's (a,b)
);
    fp_mul16_spp_ro dut (.clk(clk), .reset(reset), .stall(1'b0), .in_valid(in_valid),
                         .a(a), .b(b), .out_valid(out_valid), .y(y));
    fp_mul16 u_ref (.a(a), .b(b), .y(y_ref));
endmodule

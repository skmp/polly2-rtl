// p2_fp_lzc_tb_top: make fp-lzc (tb/fp/fp_lzc_tb.cpp). H1 at every width the units use (num H1, 2.1, ARCHITECTURE
// 3.11) and the adders' internal ones: 16, 17, 24, 25, 34, 49, 50, 64, 77, 108, 128 bits, each on the low bits of v.
// The DUTs are combinational; their outputs are registered here, so a vector driven before an edge is on the outputs
// after it (latency 1, tb/fp/fp_tb.h Lockstep).
module p2_fp_lzc_tb_top (
  input  logic         clk,
  input  logic         in_v,
  input  logic [127:0] v,
  output logic         out_v,
  output logic [4:0]   n16,
  output logic [4:0]   n17,
  output logic [4:0]   n24,
  output logic [4:0]   n25,
  output logic [5:0]   n34,
  output logic [5:0]   n49,
  output logic [5:0]   n50,
  output logic [6:0]   n64,
  output logic [6:0]   n77,
  output logic [6:0]   n108,
  output logic [7:0]   n128
);
  p2_hw_check u_hw_check ();

  logic [4:0] d16, d17, d24, d25;
  logic [5:0] d34, d49, d50;
  logic [6:0] d64, d77, d108;
  logic [7:0] d128;

  p2_fp_lzc #(.W(16))  u16  (.v(v[15:0]),  .n(d16));
  p2_fp_lzc #(.W(17))  u17  (.v(v[16:0]),  .n(d17));
  p2_fp_lzc #(.W(24))  u24  (.v(v[23:0]),  .n(d24));
  p2_fp_lzc #(.W(25))  u25  (.v(v[24:0]),  .n(d25));
  p2_fp_lzc #(.W(34))  u34  (.v(v[33:0]),  .n(d34));
  p2_fp_lzc #(.W(49))  u49  (.v(v[48:0]),  .n(d49));
  p2_fp_lzc #(.W(50))  u50  (.v(v[49:0]),  .n(d50));
  p2_fp_lzc #(.W(64))  u64  (.v(v[63:0]),  .n(d64));
  p2_fp_lzc #(.W(77))  u77  (.v(v[76:0]),  .n(d77));
  p2_fp_lzc #(.W(108)) u108 (.v(v[107:0]), .n(d108));
  p2_fp_lzc #(.W(128)) u128 (.v(v),        .n(d128));

  always_ff @(posedge clk) begin
    out_v <= in_v;
    n16   <= d16;
    n17   <= d17;
    n24   <= d24;
    n25   <= d25;
    n34   <= d34;
    n49   <= d49;
    n50   <= d50;
    n64   <= d64;
    n77   <= d77;
    n108  <= d108;
    n128  <= d128;
  end
endmodule

// p2_fp_zblock_tb_top: make fp-zblock (tb/fp/fp_zblock_tb.cpp). H12b p2_fp_depth_block, one raster lane: the pixel's
// accumulator t (30 bits) and the tile's gexp, E, nsh, fbk to the stored key. Outputs registered (latency 1,
// tb/fp/fp_tb.h).
module p2_fp_zblock_tb_top
  import p2_pkg::*;
  import p2_fp_pkg::*;
(
  input  logic                       clk,
  input  logic                       in_v,
  input  logic signed [29:0]         t,
  input  logic signed [P2_FP_EW-1:0] gexp,
  input  logic signed [9:0]          e,
  input  logic signed [7:0]          nsh,
  input  logic                       fbk,
  output logic                       out_v,
  output logic [63:0]                key
);
  p2_hw_check u_hw_check ();

  p2_zkey_t k;

  p2_fp_depth_block #(.TW(30)) u_dut (.t(t), .gexp(gexp), .e(e), .nsh(nsh), .fbk(fbk), .key(k));

  always_ff @(posedge clk) begin
    out_v <= in_v;
    key   <= k;
  end
endmodule

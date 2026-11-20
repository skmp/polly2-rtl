// p2_fp_colour_tb_top: make fp-colour (tb/fp/fp_colour_tb.cpp). H15 p2_fp_color_round at both of p2_pp_col's
// clamps, on the same quotient each clock: MAX 255 (offset colours) and MAX 65535 (the base colour, before the
// intensity shadow's scale), SE -8 (refsw_tile.h ColorExp), the divider's 18-bit quotient port. Outputs registered
// (latency 1, tb/fp/fp_tb.h).
module p2_fp_colour_tb_top
  import p2_pkg::*;
  import p2_fp_pkg::*;
(
  input  logic                         clk,
  input  logic                         in_v,
  input  logic                         q_neg,
  input  logic                         q_bad,
  input  logic signed [P2_FP_EW-1:0]   q_exp,
  input  logic [P2_QUOT_MANT_BITS-1:0] q_mant,
  input  logic [7:0]                   fallback,
  output logic                         out_v,
  output logic [15:0]                  c255,
  output logic [15:0]                  c65535
);
  p2_hw_check u_hw_check ();

  logic [15:0] a, b;

  p2_fp_color_round #(.MAX(255), .SE(-8), .QW(P2_QUOT_MANT_BITS)) u_c255 (
    .q_neg(q_neg), .q_bad(q_bad), .q_exp(q_exp), .q_mant(q_mant), .fallback(fallback), .o(a));
  p2_fp_color_round #(.MAX(65535), .SE(-8), .QW(P2_QUOT_MANT_BITS)) u_c65535 (
    .q_neg(q_neg), .q_bad(q_bad), .q_exp(q_exp), .q_mant(q_mant), .fallback(fallback), .o(b));

  always_ff @(posedge clk) begin
    out_v  <= in_v;
    c255   <= a;
    c65535 <= b;
  end
endmodule

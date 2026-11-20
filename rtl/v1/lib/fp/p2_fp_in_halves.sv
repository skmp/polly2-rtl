// p2_fp_in_halves: H4, k / 2 exactly: {k < 0, |k|, -1}, trailing zeros kept (docs/spec/numerics.md H4, 2.5; refcore
// pvr_softfp.h Fp::FromHalves). The sample points: 2 left + HALF_OFFSET[0] and 2 top + HALF_OFFSET[0] (edge),
// 2 left + 1 (depth), 2 (left + SpanStart) + h (TSP), 2 (tile + 16) (TSP grid), 2 biasQuarters, 2, 1.
// KW: the signed width of k; |k| of -2^(KW-1) is 2^(KW-1), which still fits the KW-bit mantissa. Combinational.
module p2_fp_in_halves
  import p2_fp_pkg::*;
#(
  parameter int KW = 16
) (
  input  logic signed [KW-1:0]       k,
  output logic                       o_neg,
  output logic                       o_bad,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [KW-1:0]              o_mant
);
  assign o_neg  = k[KW-1];
  assign o_bad  = 1'b0;
  assign o_exp  = P2_FP_EW'(-1);
  assign o_mant = k[KW-1] ? KW'(0) - k : k;
endmodule

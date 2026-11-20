// p2_fp_in_seen: H4, a TSP coefficient as the evaluator sees it (docs/spec/numerics.md H4; refcore pvr_tsp_plane.h
// PlaneT::Value `seen`, L311-316): the evaluator has no zero and no infinity, it takes the exponent field as a signed
// 8-bit number:
//   bad:   2^-128 with its sign       (field 255 = +128 wraps; uvmeas whuge)
//   zero:  2^-127 with its sign       (field 0; uvmeas wexp: 4875 of 4875 readings)
//   else:  the coefficient
// The result is never bad and never zero (Fp::Pow2 makes a fresh number). MW: the coefficient's bits (16, PlaneHW
// coefBits). Combinational.
module p2_fp_in_seen
  import p2_fp_pkg::*;
#(
  parameter int MW = 16
) (
  input  logic                       i_neg,
  input  logic                       i_bad,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [MW-1:0]              i_mant,
  output logic                       o_neg,
  output logic                       o_bad,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [MW-1:0]              o_mant
);
  assign o_neg  = i_neg;
  assign o_bad  = 1'b0;
  assign o_exp  = i_bad ? P2_FP_EW'(-128) : (i_mant == '0) ? P2_FP_EW'(-127) : i_exp;
  assign o_mant = (i_bad || i_mant == '0) ? MW'(1) : i_mant;
endmodule

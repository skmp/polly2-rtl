// p2_fp_le: H9, a <= b exactly, both finite, a zero of either sign is zero (docs/spec/numerics.md H9, 2.11; refcore
// pvr_softfp.h AtMost). Site: MipSelect's `length` (which of two lengths is the longer, L668) and `best` (L743).
//
//   an = a.neg and a != 0;  bn = b.neg and b != 0
//   an != bn:  an;   an:  |b| <= |a|;   otherwise:  |a| <= |b|
//
// Combinational: one p2_fp_abs_le on swapped operands.
module p2_fp_le
  import p2_fp_pkg::*;
#(
  parameter int MW = 24
) (
  input  logic                       a_neg,
  input  logic                       a_bad,
  input  logic signed [P2_FP_EW-1:0] a_exp,
  input  logic [MW-1:0]              a_mant,
  input  logic                       b_neg,
  input  logic                       b_bad,
  input  logic signed [P2_FP_EW-1:0] b_exp,
  input  logic [MW-1:0]              b_mant,
  output logic                       le
);
  logic an, bn, abs_le;

  assign an = a_neg && a_mant != '0;
  assign bn = b_neg && b_mant != '0;

  // both negative: |b| <= |a|
  p2_fp_abs_le #(.MW(MW)) u_abs (
    .a_exp (an ? b_exp : a_exp), .a_mant(an ? b_mant : a_mant),
    .b_bad (an ? a_bad : b_bad), .b_exp (an ? a_exp : b_exp), .b_mant(an ? a_mant : b_mant),
    .le    (abs_le));

  assign le = (an != bn) ? an : abs_le;
endmodule

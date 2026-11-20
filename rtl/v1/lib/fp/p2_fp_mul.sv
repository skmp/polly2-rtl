// p2_fp_mul: H5, the truncating multiplier (docs/spec/numerics.md H5, 2.7; refcore pvr_softfp.h Mul(a, b, N)).
//
//   neg = a.neg ^ b.neg (a zero product too);  bad = a.bad | b.bad
//   P = a.mant * b.mant, exact (AW + BW bits), at exp a.exp + b.exp;  then cut_N (H2): out.exp = max(L, top - N)
//
// No range rules (H10 wraps it: p2_fp_rng_mul) and no special values: a bad operand has mant 0 and gives a zero
// flagged bad. refsw3 first cuts each operand to 32 bits (L345); every port here has at most 32 bits, so that cut
// cannot act (num 1.4, A4; the testbench asserts it). Instances (num 5.5): 24 x 24 -> 24 at every setup product
// (EdgeHW / DepthHW / PlaneHW productBits, coefBits 24; the constants OneThird 0xAAAAAB 2^-25 and 0x95F612 2^-24);
// 24 x 24 exact (mip numerator class); 16 x 13 exact (TSP run start); 24 x 5 -> 8 and 8 x 8 -> 8 (mip); 8 x 16 -> 24
// exact (fog). Combinational.
module p2_fp_mul
  import p2_fp_pkg::*;
#(
  parameter int AW = 24,
  parameter int BW = 24,
  parameter int N  = 24
) (
  input  logic                       a_neg,
  input  logic                       a_bad,
  input  logic signed [P2_FP_EW-1:0] a_exp,
  input  logic [AW-1:0]              a_mant,
  input  logic                       b_neg,
  input  logic                       b_bad,
  input  logic signed [P2_FP_EW-1:0] b_exp,
  input  logic [BW-1:0]              b_mant,
  output logic                       o_neg,
  output logic                       o_bad,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [N-1:0]               o_mant
);
  localparam int PW = AW + BW;

  logic [PW-1:0]              p;     // the exact product
  logic signed [P2_FP_XW-1:0] l;     // its exponent: a.exp + b.exp
  logic signed [P2_FP_XW-1:0] oe;    // after the cut; the field holds every reference value (num 1.4)

  assign p = PW'(a_mant) * PW'(b_mant);
  assign l = p2_fp_xw(a_exp) + p2_fp_xw(b_exp);

  p2_fp_cut #(.IW(PW), .N(N), .EW(P2_FP_XW)) u_cut (
    .i_neg(a_neg ^ b_neg), .i_bad(a_bad | b_bad), .i_exp(l), .i_mant(p),
    .o_neg(o_neg), .o_bad(o_bad), .o_exp(oe), .o_mant(o_mant));

  assign o_exp = oe[P2_FP_EW-1:0];
endmodule

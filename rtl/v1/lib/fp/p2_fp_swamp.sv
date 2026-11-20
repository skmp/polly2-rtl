// p2_fp_swamp: H7a, the edge unit at 2^128 (docs/spec/numerics.md H7a, 2.6; refcore pvr_isp_edge.h at 6784ea3d /
// 708fb8cd: EdgeWinding L113, EdgeTile::Setup L181 (the `swamp` lambda), L190-191 and L196-197 (the saturation)).
// It replaces revision 1's edge_start_sat (the +-2^132 wide add, gone). A compare and a mux; no wide add.
//
//   SAT = 0, swamp(v):  |v| >= 2^128 (top(v) > 128) ? {v.neg, bad 0, exp 200, mant 1} : v
//                       2^(overflowExp + 72) = +-2^200: beyond the adder's reach of every finite operand (a finite one
//                       has top <= 128 after a swamp, the swamp value top 201), so a sum with it is it; two of one sign
//                       add exactly to {2, 200} (swamped again), two of opposite signs cancel to +0
//   SAT = 1, sat(v):    |v| >= 2^128 ? {v.neg, bad 0, exp 127, mant 1} : v    (+-2^127, EdgeHW::saturateExp)
//
// Sites (isp 7.1, 8.3; num H7a): swamp on every product and sum of EdgeWinding's determinant, on the start's products
// (xb ya, xa yb, swamp(dx) y0, swamp(dy) x0), on c and first, and on dx, dy where they enter the start's products;
// sat on dx, dy for the steps and on the start. The flag goes: refsw3's Fp::Pow2 makes a value that is not bad, so a
// flagged sum (Winding's det of a NaN corner) that reaches 2^128 comes out unflagged, as here.
// Evidence: dreamcast-tests pvr-tests/faredge_cmax (4,800 of 4,800 tiles: the product that counts, 2^128 exactly cut to
// 24 bits, two swamps of one sign cancelling), faredge_k132, faredge_m131 and faredge_cull (the swamped determinant's
// size and sign), hugepos a (the start's 2^127), hugepos_v4, _v5, _v6 (sat on the steps). Combinational.
module p2_fp_swamp
  import p2_hw_pkg::*;
  import p2_fp_pkg::*;
#(
  parameter int MW  = 24,         // mantissa bits in and out
  parameter bit SAT = 1'b0        // 0: swamp to 2^(overflowExp + 72); 1: saturate to 2^saturateExp
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
  // the threshold, |v| >= 2^overflowExp (EdgeHW::overflowExp 128; Fp::atLeastPow2)
  localparam int OE        = P2_ISP_EDGE_OVERFLOW_EXP;
  // the swamp value's exponent: edge.h `Fp::Pow2(OE + 72, v.neg)`
  localparam int SWAMP_EXP = P2_ISP_EDGE_OVERFLOW_EXP + 72;
  // the saturated value's exponent (EdgeHW::saturateExp 127)
  localparam int SAT_EXP   = P2_ISP_EDGE_SATURATE_EXP;
  localparam int REPL_EXP  = SAT ? SAT_EXP : SWAMP_EXP;

  logic ge;     // |v| >= 2^128

  p2_fp_at_least_pow2 #(.MW(MW)) u_ge (.i_exp(i_exp), .i_mant(i_mant), .e(P2_FP_EW'(OE)), .ge(ge));

  assign o_neg  = i_neg;
  assign o_bad  = ge ? 1'b0 : i_bad;
  assign o_exp  = ge ? P2_FP_EW'(REPL_EXP) : i_exp;
  assign o_mant = ge ? MW'(1) : i_mant;
endmodule

// p2_fp_rng_mul: H10 around H5, one product of the setups at W x W -> W, either flavour per issue
// (docs/spec/numerics.md H10, 4.1-4.2, 4.3; ARCHITECTURE 3.4.4: "each with the H10 depth-flavour wrapper switchable
// per issue").
//
//   ranged = 0: the edge unit's Mul(a, b, 24): no range (pvr_isp_edge.h; num 5.1)
//   ranged = 1: the depth setup's `mul` (pvr_isp_depth.h L330-336), the TSP setup's `mul` (pvr_tsp_plane.h L150-162)
//               and MipSelect's `rmul` (L699-710), one rule:
//     a bad operand:  the other a zero (and not bad): a zero, else an infinity; the product's sign either way
//                     (zero times anything is zero, also times an infinity; uvmeas wspec, depthgaps_nanprod)
//     otherwise:      Mul(a, b, 24), then P2_RNG_LIM_PRODUCT: 2^128 or more an infinity, below 2^-126 a zero of its
//                     sign (uvmeas whuge, wtiny; zovf_ps: a product of exactly 2^128)
//
// Combinational.
module p2_fp_rng_mul
  import p2_fp_pkg::*;
#(
  parameter int W = 24
) (
  input  logic                       ranged,
  input  logic                       a_neg,
  input  logic                       a_bad,
  input  logic signed [P2_FP_EW-1:0] a_exp,
  input  logic [W-1:0]               a_mant,
  input  logic                       b_neg,
  input  logic                       b_bad,
  input  logic signed [P2_FP_EW-1:0] b_exp,
  input  logic [W-1:0]               b_mant,
  output logic                       o_neg,
  output logic                       o_bad,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [W-1:0]               o_mant
);
  logic                       m_neg, m_bad, l_neg, l_bad;
  logic signed [P2_FP_EW-1:0] m_exp, l_exp;
  logic [W-1:0]               m_mant, l_mant;
  logic                       other_zero;   // the operand that is not bad is a zero

  p2_fp_mul #(.AW(W), .BW(W), .N(W)) u_mul (
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant),
    .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant),
    .o_neg(m_neg), .o_bad(m_bad), .o_exp(m_exp), .o_mant(m_mant));

  p2_fp_rng_lim #(.MW(W)) u_lim (
    .mode(P2_RNG_LIM_PRODUCT), .i_neg(m_neg), .i_bad(m_bad), .i_exp(m_exp), .i_mant(m_mant),
    .o_neg(l_neg), .o_bad(l_bad), .o_exp(l_exp), .o_mant(l_mant));

  assign other_zero = a_bad ? (!b_bad && b_mant == '0) : (a_mant == '0);

  always_comb begin
    o_neg  = m_neg;
    o_bad  = m_bad;
    o_exp  = m_exp;
    o_mant = m_mant;
    if (ranged) begin
      if (a_bad || b_bad) begin
        o_neg  = a_neg ^ b_neg;
        o_bad  = !other_zero;
        o_exp  = '0;
        o_mant = '0;
      end else begin
        o_neg  = l_neg;
        o_bad  = l_bad;
        o_exp  = l_exp;
        o_mant = l_mant;
      end
    end
  end
endmodule

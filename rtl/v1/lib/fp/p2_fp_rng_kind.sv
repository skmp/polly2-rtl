// p2_fp_rng_kind: H10, the class of the product x * y in MipSelect's ranged arithmetic, `kind`
// (docs/spec/numerics.md H10, 4.2; refcore pvr_tsp_plane.h MipSelect L606-612; mipmeas mix wext, mipdump):
//
//   x or y bad:     a zero (and not bad) among them: ZERO, else INF
//   x or y zero:    ZERO
//   otherwise:      m = Mul(x, y, 24): 2^128 or more INF, below 2^-126 ZERO, else NUMBER
//
// The product Mul(x, y, 24) is an output too: it is the numerator's q1 / q2 (L641), which shares this multiplier
// (num 5.3). Combinational.
module p2_fp_rng_kind
  import p2_fp_pkg::*;
#(
  parameter int W = 24
) (
  input  logic                       a_neg,
  input  logic                       a_bad,
  input  logic signed [P2_FP_EW-1:0] a_exp,
  input  logic [W-1:0]               a_mant,
  input  logic                       b_neg,
  input  logic                       b_bad,
  input  logic signed [P2_FP_EW-1:0] b_exp,
  input  logic [W-1:0]               b_mant,
  output logic [1:0]                 kind,        // P2_KIND_*
  output logic                       o_neg,       // Mul(a, b, W), unranged
  output logic                       o_bad,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [W-1:0]               o_mant
);
  localparam int NW = $clog2(W + 1);

  logic                       az, bz;
  logic [NW-1:0]              n;
  logic signed [P2_FP_XW-1:0] t;          // top of the product
  logic                       above, below;

  p2_fp_mul #(.AW(W), .BW(W), .N(W)) u_mul (
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant),
    .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant),
    .o_neg(o_neg), .o_bad(o_bad), .o_exp(o_exp), .o_mant(o_mant));

  p2_fp_lzc #(.W(W), .NW(NW)) u_bl (.v(o_mant), .n(n));

  // the product against the range (MipSelect `above` / `below`, L602-603)
  assign t     = p2_fp_xw(o_exp) + $signed({{(P2_FP_XW - NW){1'b0}}, n});
  assign above = (o_mant != '0) && (t - P2_FP_XW'(1) > P2_FP_XW'(P2_FP_RNG_HIGH));
  assign below = (o_mant != '0) && (t - P2_FP_XW'(1) < P2_FP_XW'(P2_FP_RNG_LOW));
  assign az    = a_mant == '0;
  assign bz    = b_mant == '0;

  always_comb begin
    if (a_bad || b_bad)
      kind = ((!a_bad && az) || (!b_bad && bz)) ? P2_KIND_ZERO : P2_KIND_INF;
    else if (az || bz)
      kind = P2_KIND_ZERO;
    else if (above)
      kind = P2_KIND_INF;
    else if (below)
      kind = P2_KIND_ZERO;
    else
      kind = P2_KIND_NUMBER;
  end
endmodule

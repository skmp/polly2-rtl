// p2_fp_rng_add: H10 around H6, one addition of the setups in the flavour of its issue (docs/spec/numerics.md H10,
// 4.1-4.2; ARCHITECTURE 3.4.4 step 6, 3.11). Sub(a, b) = add(a, -b): the caller flips b_neg. At refsw3 4f3efe15.
//
//   P2_RNG_ADD_NONE   the edge unit: plain Add(a, b, W, R) (pvr_isp_edge.h; no range: num 5.1)
//   P2_RNG_ADD_DEPTH  the ISP depth setup's `add` (pvr_isp_depth.h addRule(., ., true); subC and addE are the same at
//                     DepthHW zeroRuleCoords = zeroRuleEdges = 1: depth2_zcoord, depth2_zedge):
//                       a bad operand: two of opposite signs +0, else an infinity of the bad one's sign (a's first)
//                       the zero rule: exactly one operand zero and the other, v, in [2^-126, 1.5 * 2^-126) with the
//                         other sign: +0 (depthgaps_zadd 109 of 109, depthgaps_field1 2,000 of 2,000). refsw3 reads
//                         "the bit under v's leading one", which shifts by -1 for a one-bit mantissa (num D2); this is
//                         the value rule |v| < 1.5 * 2^-126 that GCC's result on x86-64 gives there
//                       Add(a, b, W, R), then P2_RNG_LIM_SUM (2^128 checked at every sum: zovf_lim 4,984 of 4,984)
//                       every zero sum +0, -0 + -0 too (depthgaps_zadd: 108 of 109 as -0)
//   P2_RNG_ADD_TSP    the TSP setup's `addTerm(a, b, .)` (pvr_tsp_plane.h PlaneT::Setup, TSP_ZERO 0; the first and the
//                     last addition of a sum of three alike: tsp2_zadd 9,600 of 9,600): as P2_RNG_ADD_DEPTH, but the
//                     zero rule's v is any nonzero value with top - 1 < -127 + zeroReach (2), below the range too, and
//                     the "half" bit is defined for a one-bit mantissa (n >= 2: the value rule, no num D2)
//   P2_RNG_ADD_MIP    MipSelect's `radd` (pvr_tsp_plane.h, with R = 53, GAP G1): the bad rules as above; Add;
//                     P2_RNG_LIM_SUM; no zero rule; a zero sum keeps Add's sign (-0 + -0 = -0)
//
// Combinational.
module p2_fp_rng_add
  import p2_fp_pkg::*;
#(
  parameter int W = 24,
  parameter int R = 25
) (
  input  logic [1:0]                 mode,        // P2_RNG_ADD_*
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
  localparam int NW = $clog2(W + 1);

  logic                       ranged, depth, tsp;
  logic                       az, bz;
  logic [NW-1:0]              na, nb;
  logic signed [P2_FP_XW-1:0] ta, tb;          // tops
  // the zero rule (depth and TSP)
  logic                       zrule, v_small;
  logic                       v_neg, z_neg;
  logic signed [P2_FP_XW-1:0] v_top;
  logic [NW-1:0]              v_n;
  logic [W-1:0]               v_mant, v_just;   // the nonzero operand, and with its leading one at bit W - 1
  // the adder and the check after it
  logic                       s_neg, s_bad, l_neg, l_bad;
  logic signed [P2_FP_EW-1:0] s_exp, l_exp;
  logic [W-1:0]               s_mant, l_mant;

  assign ranged = mode != P2_RNG_ADD_NONE;
  assign depth  = mode == P2_RNG_ADD_DEPTH;
  assign tsp    = mode == P2_RNG_ADD_TSP;

  p2_fp_lzc #(.W(W), .NW(NW)) u_bla (.v(a_mant), .n(na));
  p2_fp_lzc #(.W(W), .NW(NW)) u_blb (.v(b_mant), .n(nb));

  assign az = a_mant == '0;
  assign bz = b_mant == '0;
  assign ta = p2_fp_xw(a_exp) + $signed({{(P2_FP_XW - NW){1'b0}}, na});
  assign tb = p2_fp_xw(b_exp) + $signed({{(P2_FP_XW - NW){1'b0}}, nb});

  // ---- the zero rule: v the nonzero operand, z the zero
  assign v_neg  = az ? b_neg : a_neg;
  assign z_neg  = az ? a_neg : b_neg;
  assign v_top  = az ? tb : ta;
  assign v_n    = az ? nb : na;
  assign v_mant = az ? b_mant : a_mant;
  assign v_just = v_mant << (NW'(W) - v_n);
  // depth: top - 1 == -126; TSP: top - 1 < -127 + zeroReach ("smallest")
  assign v_small = depth ? (v_top == P2_FP_XW'(P2_FP_RNG_LOW + 1))
                         : (v_top - P2_FP_XW'(1) < P2_FP_XW'(-127 + P2_FP_ZERO_REACH));
  // and |v| < 1.5 * 2^(top - 1): the left-justified mantissa below binary 1.1
  assign zrule  = (depth || tsp) && (az != bz) && v_small && (z_neg != v_neg) &&
                  (v_just < {2'b11, {(W - 2){1'b0}}});

  p2_fp_add #(.W(W), .R(R)) u_add (
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant),
    .b_neg(b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant),
    .o_neg(s_neg), .o_bad(s_bad), .o_exp(s_exp), .o_mant(s_mant));

  p2_fp_rng_lim #(.MW(W)) u_lim (
    .mode(P2_RNG_LIM_SUM), .i_neg(s_neg), .i_bad(s_bad), .i_exp(s_exp), .i_mant(s_mant),
    .o_neg(l_neg), .o_bad(l_bad), .o_exp(l_exp), .o_mant(l_mant));

  always_comb begin
    o_neg  = s_neg;
    o_bad  = s_bad;
    o_exp  = s_exp;
    o_mant = s_mant;
    if (ranged) begin
      if (a_bad || b_bad) begin
        // infinities of opposite signs: +0; else the infinity (num 4.1)
        o_neg  = (a_bad && b_bad && a_neg != b_neg) ? 1'b0 : a_bad ? a_neg : b_neg;
        o_bad  = !(a_bad && b_bad && a_neg != b_neg);
        o_exp  = '0;
        o_mant = '0;
      end else if (zrule) begin
        o_neg  = 1'b0;
        o_bad  = 1'b0;
        o_exp  = '0;
        o_mant = '0;
      end else begin
        o_neg  = l_neg;
        o_bad  = l_bad;
        o_exp  = l_exp;
        o_mant = l_mant;
        // the depth and TSP setups: a sum of zero is +0, -0 + -0 too
        if ((depth || tsp) && !l_bad && l_mant == '0) o_neg = 1'b0;
      end
    end
  end
endmodule

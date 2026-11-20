// p2_fp_rng_add: H10 around H6, one addition of the setups in the flavour of its issue (docs/spec/numerics.md H10,
// 4.1-4.2; ARCHITECTURE 3.4.4 step 6, 3.11). Sub(a, b) = add(a, -b): the caller flips b_neg.
//
//   P2_RNG_ADD_NONE   the edge unit: plain Add(a, b, W, R) (pvr_isp_edge.h; no range: num 5.1)
//   P2_RNG_ADD_DEPTH  the ISP depth setup's `add` at 708fb8cd (pvr_isp_depth.h L354-370):
//                       a bad operand: two of opposite signs +0, else an infinity of the bad one's sign (a's first)
//                       the zero rule: exactly one operand zero and the other, v, in [2^-126, 1.5 * 2^-126) with the
//                         other sign: +0 (depthgaps_zadd 109 of 109, depthgaps_field1 2,000 of 2,000). refsw3 reads
//                         "the bit under v's leading one", which shifts by -1 for a one-bit mantissa (num D2); this is
//                         the value rule |v| < 1.5 * 2^-126 that GCC's result on x86-64 gives there
//                       Add(a, b, W, R), then P2_RNG_LIM_SUM (2^128 checked at every sum: zovf_lim 4,984 of 4,984)
//                       every zero sum +0, -0 + -0 too (depthgaps_zadd: 108 of 109 as -0)
//   P2_RNG_ADD_TSP    the TSP setup's `addTerm(a, b, false)` (pvr_tsp_plane.h L163-181), MipSelect's `radd` (L720-730,
//                     with R = 53, GAP G1): the bad rules as above; Add; P2_RNG_LIM_SUM. A zero sum keeps
//                     Add's sign (-0 + -0 = -0)
//   P2_RNG_ADD_TSP3   `addTerm(a, b, true)`, the last addition of a sum of three: as P2_RNG_ADD_TSP, but a zero added to
//                     a value with top - 1 < -125 (zeroReach 2) is added as 2^-127 with the zero's own sign (uvmeas
//                     wtiny1 5 cells, cmeas cwext1 21 cells, cwsum1 2,340,000 of 2,340,000; GAP G2)
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

  logic                       ranged, depth, third;
  logic                       az, bz;
  logic [NW-1:0]              na, nb;
  logic signed [P2_FP_XW-1:0] ta, tb;          // tops
  // the depth zero rule
  logic                       zrule;
  logic                       v_neg, z_neg;
  logic signed [P2_FP_XW-1:0] v_top;
  logic [NW-1:0]              v_n;
  logic [W-1:0]               v_mant, v_just;   // the nonzero operand, and with its leading one at bit W - 1
  // the TSP's last-addition substitution
  logic                       sub_a, sub_b;
  logic                       x_neg, y_neg;
  logic signed [P2_FP_EW-1:0] x_exp, y_exp;
  logic [W-1:0]               x_mant, y_mant;
  // the adder and the check after it
  logic                       s_neg, s_bad, l_neg, l_bad;
  logic signed [P2_FP_EW-1:0] s_exp, l_exp;
  logic [W-1:0]               s_mant, l_mant;

  assign ranged = mode != P2_RNG_ADD_NONE;
  assign depth  = mode == P2_RNG_ADD_DEPTH;
  assign third  = mode == P2_RNG_ADD_TSP3;

  p2_fp_lzc #(.W(W), .NW(NW)) u_bla (.v(a_mant), .n(na));
  p2_fp_lzc #(.W(W), .NW(NW)) u_blb (.v(b_mant), .n(nb));

  assign az = a_mant == '0;
  assign bz = b_mant == '0;
  assign ta = p2_fp_xw(a_exp) + $signed({{(P2_FP_XW - NW){1'b0}}, na});
  assign tb = p2_fp_xw(b_exp) + $signed({{(P2_FP_XW - NW){1'b0}}, nb});

  // ---- the depth zero rule (pvr_isp_depth.h L359-365): v the nonzero operand, z the zero
  assign v_neg  = az ? b_neg : a_neg;
  assign z_neg  = az ? a_neg : b_neg;
  assign v_top  = az ? tb : ta;
  assign v_n    = az ? nb : na;
  assign v_mant = az ? b_mant : a_mant;
  assign v_just = v_mant << (NW'(W) - v_n);
  // top - 1 == -126 and |v| < 1.5 * 2^-126: the left-justified mantissa below binary 1.1
  assign zrule  = depth && (az != bz) && (v_top == P2_FP_XW'(P2_FP_RNG_LOW + 1)) && (z_neg != v_neg) &&
                  (v_just < {2'b11, {(W - 2){1'b0}}});

  // ---- the TSP's last addition (pvr_tsp_plane.h L172-176): "smallest" = nonzero with top - 1 < -127 + zeroReach
  assign sub_b = third && bz && !az && (ta - P2_FP_XW'(1) < P2_FP_XW'(-127 + P2_FP_ZERO_REACH));
  assign sub_a = third && az && !bz && (tb - P2_FP_XW'(1) < P2_FP_XW'(-127 + P2_FP_ZERO_REACH));
  // the zero as 2^-127 with its own sign
  assign x_neg  = a_neg;
  assign x_exp  = sub_a ? P2_FP_EW'(-127) : a_exp;
  assign x_mant = sub_a ? W'(1) : a_mant;
  assign y_neg  = b_neg;
  assign y_exp  = sub_b ? P2_FP_EW'(-127) : b_exp;
  assign y_mant = sub_b ? W'(1) : b_mant;

  p2_fp_add #(.W(W), .R(R)) u_add (
    .a_neg(x_neg), .a_bad(a_bad), .a_exp(x_exp), .a_mant(x_mant),
    .b_neg(y_neg), .b_bad(b_bad), .b_exp(y_exp), .b_mant(y_mant),
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
        // the depth setup: a sum of zero is +0, -0 + -0 too (pvr_isp_depth.h L367-368)
        if (depth && !l_bad && l_mant == '0) o_neg = 1'b0;
      end
    end
  end
endmodule

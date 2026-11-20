// p2_fp_mip_minor: H7c mip_minor_sub, the undivided numerator of MipSelect's minor (docs/spec/numerics.md H7c, 8 A1;
// refcore pvr_tsp_plane.h MipSelect `minor` L642-644 at 708fb8cd):
//
//   Fp n = Sub(q1, q2, 62, 200).cut(24);  n.neg = false;  n.bad = false;
//
// q1, q2 are the 24-bit products Mul(sa1, sb2, 24), Mul(sb1, sa2, 24) or +0 (a product that is a zero by the sums;
// never bad). The output is the magnitude:
//   q1 or q2 zero:                the other one (its own tuple)
//   |q1.exp - q2.exp| > 90:       the operand of the larger top, its own tuple: the smaller takes no borrow (ARTIFACT
//                                 A1, Add case W; Add's reach of 200 returns the same operand and is not built)
//   otherwise:                    cut_24(q1 - q2), exactly: an H6 adder without a reach. Its near path (tops within
//                                 W) is p2_fp_add at reach W + 1; beyond that the smaller operand lies wholly below the
//                                 larger's last kept bit, so (the far path):
//                                   same effective sign:  the larger left-justified to W bits, exp top - W
//                                   opposite:             that minus one unit, or W ones one exponent lower when the
//                                                         larger is a power of two (L - eps)
// Evidence: dreamcast-tests pvr-tests/mipk5 (1991 of 1991 cells: the undivided numerators, each product and their
// difference cut to 24 bits, toward zero), mipk; the window is A1 (no console test tells it apart). Combinational.
module p2_fp_mip_minor
  import p2_fp_pkg::*;
#(
  parameter int W = 24            // product and result mantissa bits (the literal cut(24))
) (
  input  logic                       a_neg,     // q1
  input  logic                       a_bad,
  input  logic signed [P2_FP_EW-1:0] a_exp,
  input  logic [W-1:0]               a_mant,
  input  logic                       b_neg,     // q2 (subtracted)
  input  logic                       b_bad,
  input  logic signed [P2_FP_EW-1:0] b_exp,
  input  logic [W-1:0]               b_mant,
  output logic                       o_neg,     // always 0 (n.neg = false)
  output logic                       o_bad,     // always 0 (n.bad = false)
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [W-1:0]               o_mant
);
  localparam int WIN  = 90;       // pvr_softfp.h Add: `if (sx > 90 || sy > 90)` (case W)
  localparam int NEAR = W;        // tops at most W apart: the exact adder; beyond, the far path
  localparam int NW   = $clog2(W + 1);

  logic [NW-1:0]              na, nb;
  logic signed [P2_FP_XW-1:0] ae, be, ta, tb, gap, de;
  logic                       az, bz, win, far, a_big, eff_sub;
  logic                       n_neg, n_bad;            // the near adder's sign and flag: not read (n.neg, n.bad cleared)
  logic signed [P2_FP_EW-1:0] n_exp;
  logic [W-1:0]               n_mant;
  logic [W-1:0]               xm, xl;                  // the larger operand's mantissa, left-justified
  logic [NW-1:0]              xn;
  logic signed [P2_FP_XW-1:0] xe, xt;
  logic                       xpow2;

  p2_fp_lzc #(.W(W), .NW(NW)) u_bla (.v(a_mant), .n(na));
  p2_fp_lzc #(.W(W), .NW(NW)) u_blb (.v(b_mant), .n(nb));

  // the near path: Sub(q1, q2) exactly, cut to W (H6 at reach W + 1; for tops further apart it returns the larger
  // operand unchanged, which the far path replaces)
  p2_fp_add #(.W(W), .R(NEAR + 1)) u_near (
    .a_neg(a_neg), .a_bad(a_bad), .a_exp(a_exp), .a_mant(a_mant),
    .b_neg(!b_neg), .b_bad(b_bad), .b_exp(b_exp), .b_mant(b_mant),
    .o_neg(n_neg), .o_bad(n_bad), .o_exp(n_exp), .o_mant(n_mant));

  assign az      = a_mant == '0;
  assign bz      = b_mant == '0;
  assign ae      = p2_fp_xw(a_exp);
  assign be      = p2_fp_xw(b_exp);
  assign ta      = ae + P2_FP_XW'(na);
  assign tb      = be + P2_FP_XW'(nb);
  assign gap     = ta - tb;
  assign de      = ae - be;
  assign win     = !az && !bz && ((de > P2_FP_XW'(WIN)) || (de < P2_FP_XW'(0 - WIN)));
  assign far     = !az && !bz && !win && ((gap > P2_FP_XW'(NEAR)) || (gap < P2_FP_XW'(0 - NEAR)));
  assign a_big   = ta > tb;
  // q1 - q2: the magnitudes subtract when the two have the same sign
  assign eff_sub = a_neg == b_neg;
  assign xm      = a_big ? a_mant : b_mant;
  assign xn      = a_big ? na : nb;
  assign xe      = a_big ? ae : be;
  assign xt      = xe + P2_FP_XW'(xn);
  assign xl      = xm << (NW'(W) - xn);
  assign xpow2   = xl == {1'b1, {(W - 1){1'b0}}};

  always_comb begin
    o_neg  = 1'b0;
    o_bad  = 1'b0;
    if (win) begin
      // case W: the larger top, as it is (a tie is impossible: equal tops put the exponents within W)
      o_exp  = a_big ? a_exp : b_exp;
      o_mant = a_big ? a_mant : b_mant;
    end else if (far && !eff_sub) begin
      o_exp  = P2_FP_EW'(xt - P2_FP_XW'(W));
      o_mant = xl;
    end else if (far && xpow2) begin
      // 2^(t-1) - eps: W ones under 2^(t-1)
      o_exp  = P2_FP_EW'(xt - P2_FP_XW'(W + 1));
      o_mant = '1;
    end else if (far) begin
      o_exp  = P2_FP_EW'(xt - P2_FP_XW'(W));
      o_mant = xl - W'(1);
    end else begin
      o_exp  = n_exp;
      o_mant = n_mant;
    end
  end
endmodule

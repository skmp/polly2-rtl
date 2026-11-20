// p2_fp_add: H6, the aligning adder with the drop rule (docs/spec/numerics.md H6, 2.8; refcore pvr_softfp.h
// Add(a, b, N = W, R), guard -1). Sub(a, b) = Add(a, -b): the caller flips b_neg.
//
//   bad = a.bad | b.bad (every case)
//   both zero:       {a.neg & b.neg, 0}                     (num 1.2: negative only if both are)
//   one zero:        the other operand, unchanged            (a bad operand has mant 0: the other's value, flagged)
//   |ta - tb| >= R:  the operand of the larger top, unchanged: the other is DROPPED, no carry and no borrow
//                    (covmeas point 3, uvmeas reach1: EdgeHW / DepthHW / PlaneHW reach 25)
//   otherwise:       the exact signed sum S aligned at L = min(a.exp, b.exp);
//                    S == 0: +0 (an exact cancellation);  else cut_W(|S| at L), neg = S < 0, out.exp = max(L, top - W)
//
// The exact sum spans at most (R - 1) + W + 1 bits (49 for 24/25, 77 for 24/53). refsw3 truncates it to 64 bits before
// the cut to W (reachable for R >= 41); truncations toward zero compose, so the one cut to W here is the same tuple.
// Its window rule (an LSB exponent more than 90 below the other's) needs R >= 61 and is not built (num 2.8 case W;
// the testbench asserts it never acts, A4), nor is the guard (EdgeHW::guard -1) or the cut_32 of the operands (A4).
// Instances: 24/25 in the ISP and TSP setups (isp_alu, tsp_alu), 24/53 in MipSelect's DCalcCtrl-1 sums (GAP G1).
// Combinational: two left-aligners, one (R + W + 1)-bit two's complement adder, a bit-length and a right shift.
module p2_fp_add
  import p2_fp_pkg::*;
#(
  parameter int W = 24,           // operand and result mantissa bits (N = W)
  parameter int R = 25            // the alignment reach
) (
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
  localparam int REACH = R;
  localparam int SW    = R + W;             // the exact sum's magnitude bits
  localparam int NW    = $clog2(W + 1);
  localparam int AMW   = $clog2(SW + 1);    // the aligners' shift amount

`ifndef SYNTHESIS
  // R >= 61 reaches refsw3's window rule (case W), which is not built here
  if (R > 60 || R < 2) begin : g_bad_reach
    $fatal(1, "p2_fp_add: reach %0d is outside 2 .. 60", R);
  end
`endif

  logic [NW-1:0]              na, nb;          // BL of each mantissa
  logic signed [P2_FP_XW-1:0] ae, be;          // the LSB exponents
  logic signed [P2_FP_XW-1:0] ta, tb;          // the tops
  logic signed [P2_FP_XW-1:0] gap;             // ta - tb
  logic signed [P2_FP_XW-1:0] lsb;             // L = min(a.exp, b.exp)
  logic signed [P2_FP_XW-1:0] da, db;          // each operand's shift onto L
  logic [AMW-1:0]             sa, sb;          // the same, clamped (beyond SW the sum is not used: dropped)
  logic [SW-1:0]              ma, mb;          // the aligned magnitudes
  logic signed [SW:0]         zs;              // 0
  logic signed [SW:0]         va, vb, s, ns;   // signed operands, the exact sum S and -S
  logic [SW-1:0]              m;               // |S| (below 2^SW: no overflow)
  logic signed [P2_FP_XW-1:0] se;              // cut_W(|S|): its exponent
  logic [W-1:0]               sm;              // and its mantissa
  logic                       az, bz;

  p2_fp_lzc #(.W(W), .NW(NW)) u_bla (.v(a_mant), .n(na));
  p2_fp_lzc #(.W(W), .NW(NW)) u_blb (.v(b_mant), .n(nb));

  assign az  = a_mant == '0;
  assign bz  = b_mant == '0;
  assign ae  = p2_fp_xw(a_exp);
  assign be  = p2_fp_xw(b_exp);
  assign ta  = ae + $signed({{(P2_FP_XW - NW){1'b0}}, na});
  assign tb  = be + $signed({{(P2_FP_XW - NW){1'b0}}, nb});
  assign gap = ta - tb;
  assign lsb = (ae < be) ? ae : be;
  assign da  = ae - lsb;
  assign db  = be - lsb;
  assign sa  = (da > P2_FP_XW'(SW)) ? AMW'(SW) : da[AMW-1:0];
  assign sb  = (db > P2_FP_XW'(SW)) ? AMW'(SW) : db[AMW-1:0];
  assign ma  = SW'(a_mant) << sa;
  assign mb  = SW'(b_mant) << sb;
  assign zs  = '0;
  assign va  = a_neg ? zs - $signed({1'b0, ma}) : $signed({1'b0, ma});
  assign vb  = b_neg ? zs - $signed({1'b0, mb}) : $signed({1'b0, mb});
  assign s   = va + vb;
  assign ns  = zs - s;
  assign m   = s[SW] ? ns[SW-1:0] : s[SW-1:0];

  p2_fp_cut #(.IW(SW), .N(W), .EW(P2_FP_XW)) u_cut (
    .i_neg(1'b0), .i_bad(1'b0), .i_exp(lsb), .i_mant(m),
    .o_neg(), .o_bad(), .o_exp(se), .o_mant(sm));

  always_comb begin
    o_bad = a_bad | b_bad;
    if (az && bz) begin
      // num 1.2: a sum of two zeros is negative only if both are
      o_neg  = a_neg & b_neg;
      o_exp  = '0;
      o_mant = '0;
    end else if (bz) begin
      o_neg  = a_neg;
      o_exp  = a_exp;
      o_mant = a_mant;
    end else if (az) begin
      o_neg  = b_neg;
      o_exp  = b_exp;
      o_mant = b_mant;
    end else if (gap >= P2_FP_XW'(REACH)) begin
      // b lies wholly beyond the alignment shift: dropped (no borrow; covmeas point 3)
      o_neg  = a_neg;
      o_exp  = a_exp;
      o_mant = a_mant;
    end else if (gap <= P2_FP_XW'(0 - REACH)) begin
      o_neg  = b_neg;
      o_exp  = b_exp;
      o_mant = b_mant;
    end else if (m == '0) begin
      // an exact cancellation is +0 (num 1.2)
      o_neg  = 1'b0;
      o_exp  = '0;
      o_mant = '0;
    end else begin
      o_neg  = s[SW];
      o_exp  = se[P2_FP_EW-1:0];
      o_mant = sm;
    end
  end
endmodule

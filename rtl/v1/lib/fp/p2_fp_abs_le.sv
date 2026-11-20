// p2_fp_abs_le: H9, |a| <= |b| exactly, independent of the representation (docs/spec/numerics.md H9, 2.11; refcore
// pvr_softfp.h AbsAtMost). a finite; b an infinity (bad) is above every finite value; a bad a (mant 0) is a zero.
//
//   b.bad or a.mant == 0:  1
//   b.mant == 0:           0
//   top(a) != top(b):      top(a) < top(b)
//   otherwise:             the left-justified mantissas, a <= b
//
// Sites: CulledBySize (the swamped determinant against |FPU_CULL_VAL|: equal is culled, raster page 4), Perpendicular
// (against FPU_PERP_VAL: equal counts, perpeq 1800 of 1800), and through p2_fp_le MipSelect's longer length.
// Combinational.
module p2_fp_abs_le
  import p2_fp_pkg::*;
#(
  parameter int MW = 24
) (
  input  logic signed [P2_FP_EW-1:0] a_exp,
  input  logic [MW-1:0]              a_mant,
  input  logic                       b_bad,
  input  logic signed [P2_FP_EW-1:0] b_exp,
  input  logic [MW-1:0]              b_mant,
  output logic                       le
);
  localparam int NW = $clog2(MW + 1);

  logic [NW-1:0]              na, nb;
  logic signed [P2_FP_XW-1:0] ta, tb;
  logic [MW-1:0]              ja, jb;     // the mantissas with their leading one at bit MW - 1

  p2_fp_lzc #(.W(MW), .NW(NW)) u_bla (.v(a_mant), .n(na));
  p2_fp_lzc #(.W(MW), .NW(NW)) u_blb (.v(b_mant), .n(nb));

  assign ta = p2_fp_xw(a_exp) + $signed({{(P2_FP_XW - NW){1'b0}}, na});
  assign tb = p2_fp_xw(b_exp) + $signed({{(P2_FP_XW - NW){1'b0}}, nb});
  assign ja = a_mant << (NW'(MW) - na);
  assign jb = b_mant << (NW'(MW) - nb);
  // a's bad flag is not read (refsw3 neither): a bad a has mant 0 at every site and counts as a zero
  assign le = (b_bad || a_mant == '0) ? 1'b1 : (b_mant == '0) ? 1'b0 : (ta != tb) ? (ta < tb) : (ja <= jb);
endmodule

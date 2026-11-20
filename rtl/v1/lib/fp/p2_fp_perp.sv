// p2_fp_perp: H9, whether a triangle of the ranged setup's determinant det is "perpendicular": taken as one of
// determinant zero (docs/spec/numerics.md H9, 2.12; refcore pvr_softfp.h Perpendicular with perpVal =
// FromBits(FPU_PERP_VAL & 0x7fffffff), refsw_lists.cpp RenderCORE L377-378).
//
//   det == 0 and not bad:  0                        (a zero is one already)
//   det.bad:               perpVal.bad              (an infinite FPU_PERP_VAL takes an infinite det: detinf)
//   otherwise:             (perpVal.bad or perpVal != 0) and |det| <= |perpVal|
//
// The register's sign does not count (-1 is 1.0) and every NaN is +infinity (perpval: 136,764 pixels at 2^20, the
// NaNs and -infinity as +infinity; perpeq: a determinant equal to the register counts, 1800 of 1800). Sites: the
// depth setup's det (pvr_isp_depth.h L382), the TSP's (pvr_tsp_plane.h L214). Combinational.
module p2_fp_perp
  import p2_fp_pkg::*;
(
  input  logic                       det_bad,     // (the sign is not an input: only the size counts)
  input  logic signed [P2_FP_EW-1:0] det_exp,
  input  logic [23:0]                det_mant,
  input  logic [31:0]                fpu_perp_val,
  output logic                       perp
);
  logic                       pv_neg, pv_bad, abs_le;
  logic signed [P2_FP_EW-1:0] pv_exp;
  logic [23:0]                pv_mant;

  p2_fp_in_single u_pv (
    .u(fpu_perp_val & 32'h7FFFFFFF), .ranged(1'b0),
    .o_neg(pv_neg), .o_bad(pv_bad), .o_exp(pv_exp), .o_mant(pv_mant));

  p2_fp_abs_le #(.MW(24)) u_le (
    .a_exp(det_exp), .a_mant(det_mant), .b_bad(pv_bad), .b_exp(pv_exp), .b_mant(pv_mant), .le(abs_le));

  assign perp = (det_mant == '0 && !det_bad) ? 1'b0 :
                det_bad                      ? pv_bad :
                                               ((pv_bad || pv_mant != '0) && abs_le);
endmodule

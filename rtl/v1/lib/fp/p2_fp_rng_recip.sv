// p2_fp_rng_recip: H10 around H8, the ranged setups' reciprocal of the determinant (docs/spec/numerics.md H10, 4.2).
// Only "below" is checked after it, never "above" (as in refsw3).
//
//   mip = 0, the TSP (pvr_tsp_plane.h PlaneT::Setup L285-287):
//     det.bad: a zero of det's sign;  else Recip(det, 24), below 2^-126 a zero of its sign (a determinant above 2^126:
//     every coefficient a zero with the sign of its sum times the determinant's; hugepos triangles b, c)
//   mip = 1, MipSelect (L619-621):
//     det.bad: +0;  else Recip(det, 24), below 2^-126 +0.
//     det == 0 (not bad): +0. refsw3 divides by zero there (SIGFPE, num D1; a mipmapped triangle of determinant
//     exactly zero); this is num D1's proposal for the RTL until a console test settles it: as a bad determinant, so
//     that `undivided` is false and the level follows from w alone.
// The TSP never takes a zero determinant here (its flat path, L216). The depth setup's three reciprocals are
// unranged: p2_fp_recip24 itself. Combinational.
module p2_fp_rng_recip
  import p2_fp_pkg::*;
(
  input  logic                       mip,
  input  logic                       i_neg,
  input  logic                       i_bad,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [23:0]                i_mant,
  output logic                       o_neg,
  output logic                       o_bad,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [23:0]                o_mant
);
  logic                       r_neg, r_bad, below;
  logic signed [P2_FP_EW-1:0] r_exp;
  logic [23:0]                r_mant;
  logic [4:0]                 rn;
  logic signed [P2_FP_XW-1:0] rt;        // top of the reciprocal

  p2_fp_recip24 u_recip (
    .i_neg(i_neg), .i_bad(i_bad), .i_exp(i_exp), .i_mant(i_mant),
    .o_neg(r_neg), .o_bad(r_bad), .o_exp(r_exp), .o_mant(r_mant));

  p2_fp_lzc #(.W(24), .NW(5)) u_bl (.v(r_mant), .n(rn));

  assign rt    = p2_fp_xw(r_exp) + $signed({{(P2_FP_XW - 5){1'b0}}, rn});
  assign below = (r_mant != '0) && (rt - P2_FP_XW'(1) < P2_FP_XW'(P2_FP_RNG_LOW));

  always_comb begin
    if (i_bad || (mip && i_mant == '0) || below) begin
      // a zero: of det's sign (TSP), +0 (mip)
      o_neg  = mip ? 1'b0 : r_neg;
      o_bad  = 1'b0;
      o_exp  = '0;
      o_mant = '0;
    end else begin
      o_neg  = r_neg;
      o_bad  = r_bad;
      o_exp  = r_exp;
      o_mant = r_mant;
    end
  end
endmodule

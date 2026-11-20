// p2_fp_rng_lim: H10, the range check after an operation of the ranged setups (docs/spec/numerics.md H10, 4.1-4.2).
// above: a nonzero value of 2^128 or more (top - 1 > 127); below: a nonzero value under 2^-126 (top - 1 < -126).
//
//   P2_RNG_LIM_PRODUCT  above: an infinity of its sign; below: a zero of its sign   (pvr_isp_depth.h `limit(r, false)`
//                       L324-329; PlaneT::Setup `mul` L159-160; MipSelect `rmul` L707-708)
//   P2_RNG_LIM_SUM      above: an infinity of its sign; below: +0                   (`limit(r, true)`; `addTerm`
//                       L178-179; `radd` L727-728: a sum below the range is +0, as an exact cancellation is)
//   P2_RNG_LIM_UNDER    below: the mantissa cleared, sign, flag and exponent kept   (depth `under` L596: A, B, the
//                       tile's start; zspec pages 3-6)
//   P2_RNG_LIM_BELOW    below: +0; above: kept                                       (MipSelect's 1/det L620-621 and
//                       1/det^2 L629-630; sydney_race, sydney_stadium, mipdump)
//
// An infinity is {bad 1, mant 0}, a zero {bad 0, mant 0} (fresh numbers: refsw3's inf() / zero() / Fp()). A value in
// range, and every zero, passes unchanged. Combinational.
module p2_fp_rng_lim
  import p2_fp_pkg::*;
#(
  parameter int MW = 24
) (
  input  logic [1:0]                 mode,        // P2_RNG_LIM_*
  input  logic                       i_neg,
  input  logic                       i_bad,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [MW-1:0]              i_mant,
  output logic                       o_neg,
  output logic                       o_bad,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [MW-1:0]              o_mant
);
  localparam int NW = $clog2(MW + 1);

  logic [NW-1:0]              n;
  logic signed [P2_FP_XW-1:0] t;          // top
  logic                       above, below;

  p2_fp_lzc #(.W(MW), .NW(NW)) u_bl (.v(i_mant), .n(n));

  assign t     = p2_fp_xw(i_exp) + $signed({{(P2_FP_XW - NW){1'b0}}, n});
  assign above = (i_mant != '0) && (t - P2_FP_XW'(1) > P2_FP_XW'(P2_FP_RNG_HIGH));
  assign below = (i_mant != '0) && (t - P2_FP_XW'(1) < P2_FP_XW'(P2_FP_RNG_LOW));

  always_comb begin
    o_neg  = i_neg;
    o_bad  = i_bad;
    o_exp  = i_exp;
    o_mant = i_mant;
    case (mode)
      P2_RNG_LIM_PRODUCT, P2_RNG_LIM_SUM: begin
        if (above) begin                       // an infinity of the value's sign
          o_bad  = 1'b1;
          o_exp  = '0;
          o_mant = '0;
        end else if (below) begin              // a zero: of its sign (a product), +0 (a sum)
          o_neg  = (mode == P2_RNG_LIM_PRODUCT) ? i_neg : 1'b0;
          o_bad  = 1'b0;
          o_exp  = '0;
          o_mant = '0;
        end
      end
      P2_RNG_LIM_UNDER: begin
        if (below) o_mant = '0;
      end
      default: begin                           // P2_RNG_LIM_BELOW
        if (below) begin
          o_neg  = 1'b0;
          o_bad  = 1'b0;
          o_exp  = '0;
          o_mant = '0;
        end
      end
    endcase
  end
endmodule

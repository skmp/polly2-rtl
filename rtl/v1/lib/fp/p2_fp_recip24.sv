// p2_fp_recip24: H8, the setup reciprocal: the exact 1/v truncated to 24 bits, a floor of a floor, never rounded
// (docs/spec/numerics.md H8, 2.9; refcore pvr_softfp.h Recip(v, C<24>): DepthHW / PlaneHW recipBits 24, MipSelect's
// literal 24). recipBits 23 / 25: 206 / 78 zmeas readings wrong; mipk5 / mipdump pin it for the mip numerators.
//
//   dn = mant left-justified to 24 bits, ev = exp - (24 - BL(mant))
//   dn == 2^23:  {neg, bad, 2^23,            -46 - ev}        (1/v exact: a power of two)
//   otherwise:   {neg, bad, floor(2^47 / dn), -47 - ev}        (24 significant bits, bit 23 set)
//
// The value does not depend on the representation (trailing zeros cancel). v == 0 is undefined in refsw3 (an integer
// division by zero, num D1): the result here is whatever the divider gives; p2_fp_rng_recip defines the mip site's.
// The quotient is a restoring division, one bit a step over 24 steps. Combinational.
module p2_fp_recip24
  import p2_fp_pkg::*;
(
  input  logic                       i_neg,
  input  logic                       i_bad,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [23:0]                i_mant,
  output logic                       o_neg,
  output logic                       o_bad,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [23:0]                o_mant
);
  logic [4:0]                 nb;      // BL(mant)
  logic [4:0]                 lsh;     // 24 - BL(mant): the left justification
  logic [23:0]                dn;
  logic signed [P2_FP_XW-1:0] ev;
  logic                       pow2;
  logic [23:0]                q;       // floor(2^47 / dn) for dn > 2^23
  logic [24:0]                rem;

  p2_fp_lzc #(.W(24), .NW(5)) u_bl (.v(i_mant), .n(nb));

  assign lsh  = 5'd24 - nb;
  assign dn   = i_mant << lsh;
  assign ev   = p2_fp_xw(i_exp) - $signed({{(P2_FP_XW - 5){1'b0}}, lsh});
  assign pow2 = dn == 24'h800000;

  // 2^47 / dn: the numerator's bits above 2^23 are 2^47 >> 24 = 2^23 < dn, so the quotient has 24 bits; each step
  // brings down one zero
  always_comb begin
    rem = 25'h0800000;
    q   = '0;
    for (int i = 23; i >= 0; i--) begin
      rem = rem << 1;
      if (rem >= {1'b0, dn}) begin
        rem  = rem - {1'b0, dn};
        q[i] = 1'b1;
      end
    end
  end

  logic signed [P2_FP_XW-1:0] oe;
  assign oe     = (pow2 ? P2_FP_XW'(-46) : P2_FP_XW'(-47)) - ev;
  assign o_neg  = i_neg;
  assign o_bad  = i_bad;
  assign o_exp  = oe[P2_FP_EW-1:0];
  assign o_mant = pow2 ? 24'h800000 : q;
endmodule

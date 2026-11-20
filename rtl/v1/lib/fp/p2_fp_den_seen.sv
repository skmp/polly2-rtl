// p2_fp_den_seen: H13 denominator_seen, what the TSP divider makes of a denominator below zero (docs/spec/numerics.md
// H13; docs/spec/tsp.md 6.2; refcore pvr_tsp_plane.h DenominatorSeen; dreamcast-tests pvr-tests/uvmeas, mix wneg:
// 780,000 of 780,000 readings, 1/w of -2^-6 .. -2^8 and of both signs in one triangle; texfar_m1, texfar_m1q):
//
//   not den.neg, or den == 0:  den, unchanged (Divide maps a zero before it gets here)
//   top(den) < -127:           {+, 0xFFFF, -143}: only -2^-143, the -1-unit plane value (H12a), is below 2^-128; its
//                              mantissa is all ones at the smallest exponent and the leading bit is forced (texfar_m1:
//                              166 of 166 point-sampled readings with this mantissa and no other)
//   otherwise:                 |den| normalized to exactly 16 bits (a right shift truncates: only a 17-bit 2^16, the
//                              plane value after its carry, has more), then the 15 bits under the leading one negated:
//                              m' = 32768 + ((65536 - m) & 32767), and the sign dropped (the quotient has the
//                              numerator's). So -v between two powers of two reads as 3 2^p - v; a power of two as itself.
//
// The operand is a plane value (p2_pval_t: no flag, H12a never makes one; refsw3 copies a flag through and Divide never
// reads it). MW >= 16. Combinational.
module p2_fp_den_seen
  import p2_fp_pkg::*;
#(
  parameter int MW = 17
) (
  input  logic                       i_neg,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [MW-1:0]              i_mant,
  output logic                       o_neg,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [MW-1:0]              o_mant
);
  localparam int NW    = $clog2(MW + 1);
  localparam int TINY  = -127;    // `den.top() < -127`
  localparam int M1EXP = -143;    // `d.exp = -143`

  logic [NW-1:0]              bits;    // BL(mant)
  logic [MW-1:0]              lj;      // mant left-justified to MW bits
  logic [15:0]                m16;     // the 16 bits from the leading one, truncated
  logic [15:0]                neg15;   // 32768 + ((65536 - m16) & 32767)
  logic signed [P2_FP_XW-1:0] top, e16;

`ifndef SYNTHESIS
  if (MW < 16) begin : g_mw
    $fatal(1, "p2_fp_den_seen: MW %0d below the 16 bits the rule reads", MW);
  end
`endif

  p2_fp_lzc #(.W(MW), .NW(NW)) u_bl (.v(i_mant), .n(bits));

  assign lj    = i_mant << (NW'(MW) - bits);
  assign m16   = lj[MW-1 -: 16];
  assign neg15 = {1'b1, 15'(16'd0 - m16)};
  assign top   = p2_fp_xw(i_exp) + P2_FP_XW'(bits);
  assign e16   = top - P2_FP_XW'(16);

  always_comb begin
    if (!i_neg || i_mant == '0) begin
      o_neg  = i_neg;
      o_exp  = i_exp;
      o_mant = i_mant;
    end else if (top < P2_FP_XW'(TINY)) begin
      o_neg  = 1'b0;
      o_exp  = P2_FP_EW'(M1EXP);
      o_mant = MW'(16'hFFFF);
    end else begin
      o_neg  = 1'b0;
      o_exp  = e16[P2_FP_EW-1:0];
      o_mant = MW'(neg15);
    end
  end
endmodule

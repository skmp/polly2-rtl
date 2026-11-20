// p2_isp_zadd: one addition of the depth setup, a + b, or a - b when sub (refcore pvr_isp_depth.h DepthTileT::Setup
// `addRule` L395-411 and its users `add`, `subC`, `addE` L412-414 at refsw3 4f3efe15; num H10 depth flavour,
// isp 6.3, ARCHITECTURE 3.4.4 step 6): a p2_fp_rng_add P2_RNG_ADD_DEPTH at DepthHW sumBits 24 / reach 25 with packed
// ports.
//   a bad operand: two of opposite signs +0, else an infinity of the bad one's sign
//   the zero rule (RULE): a zero added to a number of 2^-126 .. 1.5 2^-126 of the other sign is +0 (depthgaps_zadd
//     109 of 109, depthgaps_field1 2,000 of 2,000); in the coordinate differences (subC, DepthHW::zeroRuleCoords:
//     depth2_zcoord 80 of 80) and the edges and the determinant (addE, DepthHW::zeroRuleEdges: depth2_zedge 65 of
//     65) as in every other addition (0de9776b)
//   Add(a, b, 24, 25), then 2^128 or more an infinity and below 2^-126 +0 (zovf_lim 4,984 of 4,984); a zero sum +0
// RULE = 0 is refsw3's addRule(., ., false), the configuration its generators keep (DepthConfig with a switch at 0, not
// the hardware's): the same addition without the zero rule, i.e. a zero added to any finite number gives that number.
// The units instance it with the DepthHW switch (p2_hw_pkg; p2_hw_check fails elaboration unless it is 1).
// Combinational.
module p2_isp_zadd
  import p2_hw_pkg::*;
  import p2_pkg::*;
  import p2_fp_pkg::*;
#(
  parameter bit RULE = 1'b1
) (
  input  p2_fp24_t a,
  input  p2_fp24_t b,
  input  logic     sub,
  output p2_fp24_t o
);
  p2_fp24_t r;

  p2_fp_rng_add #(.W(P2_ISP_DEPTH_SUM_BITS), .R(P2_ISP_DEPTH_REACH)) u_add (
    .mode(P2_RNG_ADD_DEPTH),
    .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
    .b_neg(b.neg ^ sub), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
    .o_neg(r.neg), .o_bad(r.bad), .o_exp(r.exp), .o_mant(r.mant));

  generate
    if (RULE) begin : g_rule
      assign o = r;
    end else begin : g_norule
      // without the rule a finite zero added to a finite number v is Add's v.cut(24) = v, in range (the operands are
      // the setup's: inputs and limited results, never below 2^-126)
      logic az, bz;
      assign az = !a.bad && a.mant == '0;
      assign bz = !b.bad && b.mant == '0;
      always_comb begin
        o = r;
        if (!a.bad && !b.bad && az != bz) begin
          o     = az ? b : a;
          o.neg = az ? (b.neg ^ sub) : a.neg;
        end
      end
    end
  endgenerate
endmodule

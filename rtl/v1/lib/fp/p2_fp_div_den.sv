// p2_fp_div_den: H13, the denominator half of the TSP divider: the reciprocal of a pixel's 1/w W, shared by every
// quotient of the pixel (docs/spec/numerics.md H13 `divide`; docs/spec/tsp.md 6.2, 6.3; ARCHITECTURE 3.7.7 P2, 3.11:
// one reciprocal and eleven products a pixel; refcore pvr_tsp_plane.h Divide, the lines before the product):
//
//   den == 0:   read as 2^-128, like every number without a leading bit (uvmeas wzero2: 32,784 readings on the line
//               where 1/w is exactly 0; 2^-127 and 2^-129 each get 23,000 fewer)
//   otherwise:  denominator_seen(den) (p2_fp_den_seen: a negative den's 15 bits under the leading one negated)
//   md = its top 16 bits (exact: it has at most 16, or a 17-bit 2^16 whose low bit is 0), ed = top(.)
//   r  = recip_mant(md)  (p2_fp_recip_mant)
//
// Divide clamps md to [32768, 65535]; md always has its bit 15 set, so the clamp never acts (num A4) and is not built.
// Outputs r and ed for p2_fp_div_quot. Combinational.
module p2_fp_div_den
  import p2_fp_pkg::*;
#(
  parameter int MW = 17
) (
  input  logic                       d_neg,
  input  logic signed [P2_FP_EW-1:0] d_exp,
  input  logic [MW-1:0]              d_mant,
  output logic [15:0]                r,        // the reciprocal of md: a fraction of 65536 in [0.5, 1)
  output logic signed [P2_FP_XW-1:0] ed        // top(den) as the divider reads it
);
  localparam int NW    = $clog2(MW + 1);
  localparam int ZEXP  = -128;    // `Fp::Pow2(-128, false)`

  logic                       s_neg;
  logic signed [P2_FP_EW-1:0] s_exp;
  logic [MW-1:0]              s_mant;
  logic [NW-1:0]              bits;
  logic [MW-1:0]              lj;
  logic [15:0]                md;

  p2_fp_den_seen #(.MW(MW)) u_seen (
    .i_neg(d_neg), .i_exp(d_exp), .i_mant(d_mant), .o_neg(s_neg), .o_exp(s_exp), .o_mant(s_mant));
  p2_fp_lzc #(.W(MW), .NW(NW)) u_bl (.v(s_mant), .n(bits));

  // norm16: the top 16 bits from the leading one (a shift right truncates, a shift left fills zeros)
  assign lj = s_mant << (NW'(MW) - bits);

  always_comb begin
    if (d_mant == '0) begin
      md = 16'h8000;                                       // 2^-128: mantissa 1, top -127
      ed = P2_FP_XW'(ZEXP + 1);
    end else begin
      md = lj[MW-1 -: 16];
      ed = p2_fp_xw(s_exp) + P2_FP_XW'(bits);
    end
  end

  p2_fp_recip_mant u_recip (.d(md), .r(r));
endmodule

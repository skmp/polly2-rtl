// p2_fp_cut: H2, the truncating normalizer: keep the N most significant bits of the mantissa, toward zero
// (docs/spec/numerics.md H2, 2.3; refcore pvr_softfp.h Fp::cut).
//
//   n = BL(mant);  n > N: mant >>= n - N, exp += n - N;  otherwise the tuple as it is (not normalized)
//
// neg and bad pass through; a zero stays a zero and nothing else becomes one. The output has at most N bits and is not
// left-justified: out.exp = max(in.exp, top - N) (the representation contract, num 1.3). N in {8, 16, 19, 20, 24}
// at the HW sites (EdgeHW / DepthHW startBits, slopeBits 20, storedBits 19, PlaneHW coefBits 16, mip 8; num 5.5), and
// inside H5 / H6 on the exact product or sum. EW: the exponent width in and out (the field, or wider inside a
// primitive). Combinational.
module p2_fp_cut
  import p2_fp_pkg::*;
#(
  parameter int IW = 24,          // input mantissa bits
  parameter int N  = 24,          // bits kept
  parameter int EW = P2_FP_EW     // exponent bits, in and out
) (
  input  logic                 i_neg,
  input  logic                 i_bad,
  input  logic signed [EW-1:0] i_exp,
  input  logic [IW-1:0]        i_mant,
  output logic                 o_neg,
  output logic                 o_bad,
  output logic signed [EW-1:0] o_exp,
  output logic [N-1:0]         o_mant
);
  assign o_neg = i_neg;
  assign o_bad = i_bad;

  generate
    if (IW <= N) begin : g_pass
      // never more than N bits: the tuple as it is
      assign o_exp  = i_exp;
      assign o_mant = N'(i_mant);
    end else begin : g_cut
      localparam int NW = $clog2(IW + 1);
      logic [NW-1:0] n;           // BL(mant)
      logic [NW-1:0] sh;          // the bits dropped: n - N when n > N
      p2_fp_lzc #(.W(IW), .NW(NW)) u_bl (.v(i_mant), .n(n));
      assign sh     = (n > NW'(N)) ? n - NW'(N) : '0;
      assign o_mant = N'(i_mant >> sh);
      assign o_exp  = i_exp + $signed({{(EW - NW){1'b0}}, sh});
    end
  endgenerate
endmodule

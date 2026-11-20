// p2_fp_value_norm: H12a tsp_value_norm, the plane value back to a float (docs/spec/numerics.md H12a; refcore
// pvr_tsp_plane.h PlaneT::Value L377-397 at 708fb8cd, PlaneHW range 1, valueBits 16, valueFixed 0):
//
//   k == 0:   +0                                      (Divide: a zero numerator)
//   k == -1:  {neg 1, mant 1, exp -143}               "every bit set, no leading one": -2^-143 [uvmeas wzero1; texfar_m1]
//   else:     16 bits from the leading one, toward MINUS infinity (a negative that loses bits goes one unit up in
//             size; the mantissa may become 2^16), exp = unit + the bits dropped [uvmeas point 3, the valueFixed table]
//             then the exponent floor: top - 1 below -128 is lifted to -128, the mantissa kept (the value changes)
//             [uvmeas wtiny: 37 readings where U/w passes through zero]
//
// k is the evaluator's integer in units of 2^unit; KW = 27 bits hold every reachable k (num H11: |k| < 2^25; the
// testbench asserts it). The output is p2_pval_t's fields: neg, mant[16:0] (2^16 only after the carry), exp. A pixel's
// eleven plane values go through one each (pp_plane). Combinational.
module p2_fp_value_norm
  import p2_hw_pkg::*;
  import p2_fp_pkg::*;
#(
  parameter int KW = 27
) (
  input  logic signed [KW-1:0]       k,
  input  logic signed [P2_FP_EW-1:0] unit,
  output logic                       o_neg,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [16:0]                o_mant
);
  localparam int VB    = P2_TSP_PLANE_VALUE_BITS;     // PlaneHW::valueBits: 16
  localparam int FLOOR = -128;                        // `if (cfg.range && v.top() - 1 < -128)`
  localparam int M1EXP = -143;                        // `Fp::Pow2(-143, true)`
  localparam int NW    = $clog2(KW + 1);
  localparam int VB1   = VB + 1;                      // the mantissa after the carry: 17 bits

  logic                       neg;
  logic [KW-1:0]              m;            // |k|
  logic [NW-1:0]              n;            // BL(|k|)
  logic [NW-1:0]              drop;
  logic                       lost;
  logic [VB:0]                mr;           // |k| >> drop, plus one for a negative that lost bits: <= 2^16
  logic [4:0]                 nr;           // BL(mr)
  logic signed [P2_FP_XW-1:0] e, t1;        // the exponent, and top - 1

`ifndef SYNTHESIS
  if (VB != 16) begin : g_vb
    $fatal(1, "p2_fp_value_norm: built for 16 value bits (PlaneHW::valueBits %0d)", VB);
  end
`endif

  p2_fp_lzc #(.W(KW), .NW(NW)) u_bl (.v(m), .n(n));
  p2_fp_lzc #(.W(VB + 1), .NW(5)) u_blr (.v(mr), .n(nr));

  assign neg  = k[KW-1];
  assign m    = neg ? KW'(0) - KW'(k) : KW'(k);
  assign drop = (n > NW'(VB)) ? n - NW'(VB) : '0;
  assign lost = (m & ((KW'(1) << drop) - KW'(1))) != '0;
  assign mr   = VB1'(m >> drop) + VB1'(neg && lost);    // toward minus infinity: the size up
  assign e    = p2_fp_xw(unit) + P2_FP_XW'(drop);
  assign t1   = e + P2_FP_XW'(nr) - P2_FP_XW'(1);

  always_comb begin
    if (k == '0) begin
      o_neg  = 1'b0;
      o_exp  = '0;
      o_mant = '0;
    end else if (k == '1) begin
      o_neg  = 1'b1;
      o_exp  = P2_FP_EW'(M1EXP);
      o_mant = 17'd1;
    end else begin
      o_neg  = neg;
      o_mant = mr;
      o_exp  = (t1 < P2_FP_XW'(FLOOR)) ? P2_FP_EW'(e + (P2_FP_XW'(FLOOR) - t1)) : P2_FP_EW'(e);
    end
  end
endmodule

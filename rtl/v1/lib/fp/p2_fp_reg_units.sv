// p2_fp_reg_units: H11, the overflow register's integers (docs/spec/numerics.md H11 "depth REG r0, fa, fb"; refcore
// pvr_isp_depth.h DepthTileT::Setup at 708fb8cd, ovf 2). The register counts in units of 2^102 (2^25 units: one step of
// 2^127), two's complement with its sign at 2^131 (DepthTileT::RegDepth wraps it to 30 bits), so only the low bits of
// either number count.
//
//   step = 0, r0 (L476-483): the register's start from the plane's start first0 (ranged):
//              bad:  +-2^25 (one step with its sign; the NaN payload does not count)        [nantr_pos, depthgaps_phase]
//              else: cut to the start's 20 bits, then toward zero onto 2^102, sign and magnitude  [depthgaps_rcut,
//                    depthgaps_rstart, nantr_fin]
//   step = 1, fa / fb (the `rstep` lambda, L433-444): a slope that did not overflow, from its product with the
//              reciprocal (i = Mul(v0, invS, coefBits), H5): cut to the slopes' 20 bits, toward zero onto 2^102, the
//              magnitude modulo 2^30, then the sign                                                 [zovf_creg, zovf_ab,
//              zovf_slope, zovf_wrap]
//
// o_r is the low 31 bits (two's complement) of refsw3's int64: fa / fb exactly (|fa| < 2^30); r0 exactly for every ranged
// first0 (|r0| <= 2^26), and in any case its low 31 bits, which is all the wrapped register reads. refsw3's r0 clamps
// (`sh < 40`, `-sh < 64`) give the same low bits and are not built (A4). Combinational.
module p2_fp_reg_units
  import p2_hw_pkg::*;
  import p2_fp_pkg::*;
(
  input  logic                       i_neg,
  input  logic                       i_bad,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [23:0]                i_mant,
  input  logic                       step,       // 0: r0 from first0; 1: fa / fb from Mul(v0, invS, 24)
  output logic signed [30:0]         o_r
);
  localparam int GRID  = 102;                         // the register's unit, 2^102 (L436, L480: `- 102`)
  localparam int SBITS = P2_ISP_DEPTH_START_BITS;     // r0: first0.cut(cfg.startBits)
  localparam int DBITS = P2_ISP_DEPTH_SLOPE_BITS;     // fa, fb: .cut(cfg.slopeBits)
  localparam int MODW  = 30;                          // fa, fb: `& ((uint64_t(1) << 30) - 1)`
  localparam int STEP1 = 25;                          // r0 of a bad start: `int64_t(1) << 25`

  logic [4:0]                 n;
  logic [4:0]                 drop;
  logic [19:0]                m20;      // cut_20(v) (startBits = slopeBits = 20)
  logic signed [P2_FP_XW-1:0] e20;
  logic signed [P2_FP_XW-1:0] sh;       // e20 - 102
  logic [5:0]                 sl;       // a left shift that leaves something in the low 31 bits (0 .. 30)
  logic [6:0]                 sr;       // a right shift (0 .. 64)
  logic [30:0]                mag;      // the magnitude's low 31 bits
  logic [30:0]                r;

  p2_fp_lzc #(.W(24), .NW(5)) u_bl (.v(i_mant), .n(n));

`ifndef SYNTHESIS
  if (SBITS != 20 || DBITS != 20) begin : g_bits
    $fatal(1, "p2_fp_reg_units: built for 20-bit starts and slopes (DepthHW startBits %0d, slopeBits %0d)", SBITS, DBITS);
  end
`endif

  assign drop = (n > 5'd20) ? n - 5'd20 : '0;
  assign m20  = 20'(i_mant >> drop);
  assign e20  = p2_fp_xw(i_exp) + P2_FP_XW'(drop);
  assign sh   = e20 - P2_FP_XW'(GRID);
  assign sl   = (sh <= 0) ? '0 : (sh > P2_FP_XW'(30)) ? 6'd31 : 6'(sh);
  assign sr   = (sh >= 0) ? '0 : (sh < P2_FP_XW'(-64)) ? 7'd64 : 7'(P2_FP_XW'(0) - sh);

  always_comb begin
    if (sh >= 0)
      mag = (sl > 6'd30) ? '0 : 31'(51'(m20) << sl);
    else
      mag = (sr >= 7'd20) ? '0 : 31'(20'(m20 >> sr));        // toward zero, either sign (a cutBelow(102) for fa, fb)
    if (step)
      mag = {1'b0, mag[MODW-1:0]};                         // the magnitude modulo 2^30, then the sign
    r = i_neg ? 31'd0 - mag : mag;
    if (!step && i_bad)
      r = i_neg ? 31'd0 - (31'd1 << STEP1) : 31'd1 << STEP1;
    if (i_mant == '0 && !(!step && i_bad))
      r = '0;
    o_r = $signed(r);
  end
endmodule

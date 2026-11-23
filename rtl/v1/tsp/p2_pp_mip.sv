// p2_pp_mip: the pixel pipe's P3 mipmap level (PLAN M10; ARCHITECTURE 3.7.7 P3; tsp 8.2, 8.3 at refsw3 4f3efe15:
// pvr_tsp_plane.h MipSelect from `Fp one` on, refsw_tile.cpp PixelFlush_tsp's mipChoose). D = K w^2 in 8-bit floats; K8
// is the entry's (p2_tsp_setup, M9), w the divider's reciprocal of the point's 1/w (p2_pp_div's o_q[0]):
//
//   w8 = cut8(|w|)                                            the sign of w dropped
//   ww = cut8(w8 x w8);  top(ww) - 1 > 127: the exponent lowered to 127, the mantissa kept     [mipmeas wext]
//   d  = cut8(K8 x ww);  L = floor(log2 d), M = d's top 8 bits (128 .. 255)
//   dz (the determinant zero, refsw3 dzForce): L = 2^16, past the last level              [tsp2_mipdz, tsp2_mipdz2]
//   L < 0: level 0, k 0;  else level L, f = M - 128, k = f == 127 ? 256 : 2 f              (k: of 256, the next level's share)
//   [mipmeas: the cut of w x w to 8 bits is the fingerprint: MIP_ARITH 1..6 miss 10,212 .. 2,286,280 values; with 1/w
//   exactly 1.0, w = 0.FF, w^2 = 0.FE]  Two 8 x 8 multipliers and a leading-one search (p2_fp_cut, p2_fp_mul, p2_fp_lzc).
// mipChoose (only for a textured volume whose TCW is mipmapped; else level 0, k 0):
//   a SupSample point: L == 0 ? k = 0 : L - 1 (one level finer)               [supsample2: every mipmapped page]
//   level = L + (FilterMode == 3), at most 3 + TexU (the 1x1 level)           [trimin: 180 of 180]
//   a raster texture (TCW ScanOrder, not a palette format): level 0, k as it is   [mip page 17]
// Output registered with the P3 register (p2_pp_col's enable). o_rl / o_rk: MipSelect's level and k before mipChoose
// (taps, for the testbench's comparison with MipSelect itself).
module p2_pp_mip
  import p2_pkg::*;
  import p2_fp_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic                         clk,
  input  logic                         stall,
  input  logic                         i_v,
  input  p2_pp_ctl_t                   i_ctl,
  input  p2_quot_t                     i_w,        // Divide(1.0, W)
  output logic [3:0]                   o_level,
  output logic [8:0]                   o_k,
  output logic signed [17:0]           o_rl,
  output logic [8:0]                   o_rk
);
  // w8 = cut8(|w|)
  logic                       w8_neg, w8_bad;
  logic signed [P2_FP_EW-1:0] w8_exp;
  logic [7:0]                 w8_mant;
  p2_fp_cut #(.IW(P2_QUOT_MANT_BITS), .N(8)) u_w8 (.i_neg(1'b0), .i_bad(1'b0), .i_exp(i_w.exp), .i_mant(i_w.mant),
    .o_neg(w8_neg), .o_bad(w8_bad), .o_exp(w8_exp), .o_mant(w8_mant));
  // ww = cut8(w8 x w8), its exponent at most 127 as top - 1
  logic                       w2_neg, w2_bad;
  logic signed [P2_FP_EW-1:0] w2_exp, ww_exp;
  logic [7:0]                 w2_mant;
  logic [3:0]                 w2_bl;
  p2_fp_mul #(.AW(8), .BW(8), .N(8)) u_ww (
    .a_neg(1'b0), .a_bad(1'b0), .a_exp(w8_exp), .a_mant(w8_mant),
    .b_neg(1'b0), .b_bad(1'b0), .b_exp(w8_exp), .b_mant(w8_mant),
    .o_neg(w2_neg), .o_bad(w2_bad), .o_exp(w2_exp), .o_mant(w2_mant));
  p2_fp_lzc #(.W(8), .NW(4)) u_wbl (.v(w2_mant), .n(w2_bl));
  always_comb begin
    logic signed [P2_FP_XW-1:0] t1;
    t1 = p2_fp_xw(w2_exp) + P2_FP_XW'(w2_bl) - P2_FP_XW'(1);
    ww_exp = w2_exp;
    if (w2_mant != '0 && t1 > P2_FP_XW'(127))
      ww_exp = P2_FP_EW'(P2_FP_XW'(128) - P2_FP_XW'(w2_bl));
  end
  // d = cut8(K8 x ww)
  logic                       d_neg, d_bad;
  logic signed [P2_FP_EW-1:0] d_exp;
  logic [7:0]                 d_mant;
  logic [3:0]                 d_bl;
  p2_fp_mul #(.AW(8), .BW(8), .N(8)) u_d (
    .a_neg(1'b0), .a_bad(1'b0), .a_exp(i_ctl.k.k8.exp), .a_mant(i_ctl.k.k8.mant),
    .b_neg(1'b0), .b_bad(1'b0), .b_exp(ww_exp), .b_mant(w2_mant),
    .o_neg(d_neg), .o_bad(d_bad), .o_exp(d_exp), .o_mant(d_mant));
  p2_fp_lzc #(.W(8), .NW(4)) u_dbl (.v(d_mant), .n(d_bl));

  // MipSelect's level and k
  logic signed [17:0] rl;
  logic [8:0]         rk;
  always_comb begin
    logic signed [P2_FP_XW-1:0] l;
    logic [7:0]                 m;
    logic [6:0]                 f;
    l  = p2_fp_xw(d_exp) + P2_FP_XW'(d_bl) - P2_FP_XW'(1);
    m  = d_mant << (4'd8 - d_bl);
    f  = m[6:0];                                       // M - 128
    rl = i_ctl.k.dz ? 18'sd65536 : 18'(l);
    rk = (f == 7'd127) ? 9'd256 : {1'b0, f, 1'b0};
    if (rl < 0) begin
      rl = '0;
      rk = '0;
    end
  end
  // mipChoose
  logic [3:0] level;
  logic [8:0] kk;
  always_comb begin
    logic signed [17:0] lv;
    logic        en, raster;
    logic [3:0]  last;
    en     = i_ctl.hdr.isp[25] && i_ctl.hdr.tcw[31];                     // Texture, TCW MipMapped
    raster = i_ctl.hdr.tcw[26] && i_ctl.hdr.tcw[29:27] != 3'd5 && i_ctl.hdr.tcw[29:27] != 3'd6;   // TcwRaster
    last   = 4'd3 + 4'(i_ctl.hdr.tsp[5:3]);                              // 3 + TexU
    lv     = rl;
    kk     = rk;
    if (i_ctl.super_) begin
      if (lv == 0) kk = '0;
      else lv = lv - 18'sd1;
    end
    lv = lv + ((i_ctl.hdr.tsp[14:13] == 2'd3) ? 18'sd1 : 18'sd0);       // FilterMode 3: trilinear pass B
    level = (lv > $signed({14'd0, last})) ? last : 4'(lv);
    if (raster) level = '0;
    if (!en) begin
      level = '0;
      kk    = '0;
    end
  end

  always_ff @(posedge clk)
    if (i_v && !stall) begin
      o_level <= level;
      o_k     <= kk;
      o_rl    <= rl;
      o_rk    <= rk;
    end
endmodule

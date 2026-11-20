// p2_fp_depth_block: H12b depth_block_to_fp, a block-form depth pixel to its stored key (docs/spec/numerics.md H12b,
// H14 e; refcore pvr_isp_depth.h DepthTileT::At L732-751 and NegWord L663-669 at 708fb8cd; ARCHITECTURE 2.4 BLOCK).
//
// The pixel's value is t 2^(gexp - 1): t = S + (2i + h) DX + (2j + h) DY, the raster's 30-bit accumulator in half units
// of G = 2^gexp (p2_isp_raster steps it; isp 9.4a: |t| < 2^29). refsw3 holds the same value on its own grid 2^unit
// (unit <= gexp: every refsw3 value is a multiple of G), t_ref = t 2^(gexp - unit), so:
//   t >= 0:  v = {t, gexp - 1} cut to 19 bits (DepthHW::storedBits); 2^128 and up (top - 1 >= 128): big(v), above
//            every float word [depthgaps_bigpos]; below: from_fp(v), the float word [zmeas, zblock, precision].
//            refsw3's truncation of t_ref to 64 significant bits never acts (A2: t_ref < 2^54); t = 0 is key 0
//   t < 0:   neg(E, M), M = floor(t / 2^nsh), nsh = E - 15 - gexp (= refsw3's t_ref >> (E - 15 - unit)); a left shift
//            when nsh < 0. M saturates at -2^30, where neg's key stops moving (|M| reaches 2^43 at pixels a triangle
//            does not cover; ARCHITECTURE 0.1) [depthgaps_negladder, depthgaps_search, depthgaps_negconv, perpmean_neg*]
//            fbk: refsw3 NegWord's shift sh = E - 15 - unit is outside 0 .. 120 (only when the start was cut to zero,
//            unit = gexp, and nsh < 0): its fallback word 0x80000000 | (E + 126) << 23, "not reached" by its comment
//            but reached by At at pixels outside the triangle (A5; the setup decides fbk once a tile)
//
// One instance per raster lane. Combinational.
module p2_fp_depth_block
  import p2_hw_pkg::*;
  import p2_pkg::*;
  import p2_fp_pkg::*;
#(
  parameter int TW = 30           // the accumulator t, signed
) (
  input  logic signed [TW-1:0]       t,
  input  logic signed [P2_FP_EW-1:0] gexp,      // G = 2^gexp: t's unit is 2^(gexp - 1)
  input  logic signed [9:0]          e,         // E, the clamped block exponent (-122 .. 128)
  input  logic signed [7:0]          nsh,       // E - 15 - gexp
  input  logic                       fbk,       // NegWord's fallback word (refsw3 sh outside 0 .. 120)
  output p2_zkey_t                   key
);
  localparam int SB  = P2_ISP_DEPTH_STORED_BITS;   // DepthHW::storedBits: 19
  localparam int NW  = $clog2(TW + 1);
  localparam int TW32 = TW + 32;                    // t << -nsh, up to 31 places
  // neg's M below -2^30 keys as -2^30
  localparam logic signed [TW+31:0] MLOW = TW32'(-64'sd1073741824);

  logic [TW-1:0]              mag;      // t >= 0: t itself
  logic [NW-1:0]              n, drop;
  p2_fp20_t                   s;        // cut_19(t 2^(gexp - 1))
  logic signed [P2_FP_XW-1:0] stop;     // top(s)
  logic signed [TW+31:0]      wide;     // t << -nsh
  logic signed [30:0]         m;        // M, saturated at -2^30
  logic [5:0]                 ls;       // -nsh, when below 32

  p2_fp_lzc #(.W(TW), .NW(NW)) u_bl (.v(mag), .n(n));

  assign mag    = t[TW-1] ? '0 : TW'(t);
  assign drop   = (n > NW'(SB)) ? n - NW'(SB) : '0;
  assign stop   = p2_fp_xw(gexp) - P2_FP_XW'(1) + P2_FP_XW'(n);
  assign ls     = (nsh < -8'sd31) ? 6'd32 : 6'(8'sd0 - nsh);
  assign wide   = TW32'(t) <<< ls;

  always_comb begin
    s.neg  = 1'b0;
    s.bad  = 1'b0;
    s.mant = P2_FP20_MANT_BITS'(mag >> drop);
    s.exp  = P2_FP_EW'(p2_fp_xw(gexp) - P2_FP_XW'(1) + P2_FP_XW'(drop));
    if (nsh >= 8'sd0) begin
      m = 31'(TW'(t >>> nsh));                               // floor: an arithmetic shift
    end else if (ls > 6'd31 || wide < MLOW) begin
      m = $signed({1'b1, 30'd0});                         // -2^30
    end else begin
      m = 31'(wide);
    end
    if (!t[TW-1]) begin
      if (mag != '0 && stop - P2_FP_XW'(1) >= P2_FP_XW'(128))
        key = p2_zword_pkg::big(s);
      else
        key = p2_zword_pkg::from_fp(s);
    end else if (fbk) begin
      key = p2_zword_pkg::bits({1'b1, 8'(e + 10'sd126), 23'd0});
    end else begin
      key = p2_zword_pkg::neg(e, m);
    end
  end
endmodule

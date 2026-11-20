// p2_isp_depth_lane: one depth lane of p2_isp_raster, the stored key of one pixel from its lane value (refcore
// pvr_isp_depth.h DepthTileT::At L822-852, NegWord L740, RegDepth L799 at refsw3 4f3efe15; isp 9.6; ARCHITECTURE
// 3.4.5 depth lanes):
//   BLOCK:  v = t = S + 2i DX + 2j DY in half units of G = 2^gexp (|t| < 2^29: isp 9.4a): p2_fp_depth_block (num H12b):
//           t >= 0 cut to 19 bits at 2^(gexp - 1), big from 2^128, else from_fp; t < 0 neg(E, floor(t / 2^nsh)), a
//           left shift for nsh < 0, or NegWord's fallback word with fbw [zmeas, zblock, depthgaps_bigpos, _negladder,
//           _negconv, depth2_biggrid, depth2_denorm]
//   REG:    v = r = r0 + (sa i + sb j) 2^25 + i fa + j fb mod 2^30: p2_zword_pkg::regdepth [zword, depthgaps_mm,
//           nantr_fin, nantr_fin2, nantr_wreg, depth2_regmix, depth2_regbelow]
//   CONST:  the tile's key
// The value is the start at the tile's first sample point plus whole steps (h = 0 in the hardware since 0de9776b), so
// a lane does not depend on HALF_OFFSET. Combinational.
module p2_isp_depth_lane
  import p2_pkg::*;
(
  input  p2_zregime_t                     regime,
  input  logic signed [P2_ZT_T_BITS-1:0]  v,
  input  logic signed [9:0]               gexp,
  input  logic signed [8:0]               e,
  input  logic signed [P2_ZT_NSH_BITS-1:0] nsh,
  input  logic                            fbw,
  input  p2_zkey_t                        key_c,
  output p2_zkey_t                        key
);
  p2_zkey_t kb;
  p2_fp_depth_block #(.TW(P2_ZT_T_BITS)) u_blk (.t(v), .gexp(gexp), .e({e[8], e}), .nsh({{(8 - P2_ZT_NSH_BITS){nsh[P2_ZT_NSH_BITS-1]}}, nsh}),
    .fbk(fbw), .key(kb));

  always_comb begin
    case (regime)
      P2_Z_BLOCK: key = kb;
      P2_Z_REG:   key = p2_zword_pkg::regdepth({{(32 - P2_ZT_T_BITS){v[P2_ZT_T_BITS-1]}}, v});
      default:    key = key_c;
    endcase
  end
endmodule

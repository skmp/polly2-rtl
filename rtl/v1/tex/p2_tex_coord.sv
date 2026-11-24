// p2_tex_coord: the pixel pipe's P3 texture coordinates (PLAN M11; ARCHITECTURE 3.7.7 P3, 3.8; tsp 9.1 at refsw3
// 4f3efe15: refsw_tile.cpp TextureFilter's TexCoordFixed calls, num H11). The two coordinates in 1/256 texel at the
// texture's full size, from the divider's quotients U, V (p2_pp_div), registered with the P3 register (p2_pp_col's
// enable); the half texel, the level's shift and the clamp below zero are P4's (p2_tex_addr), which has the level:
//
//   tu = TexCoordFixed(U, 3 + TexU + 8)                       both kinds: the full width (sizeU = 8 << TexU; a mipmapped
//                                                             texture's coordinates are made at the full size)
//   tv = TexCoordFixed(V, 3 + TexV + 8)                       not mipmapped (sizeV = 8 << TexV), or mipmapped declared
//                                                             taller or square (d = TexU - TexV <= 0)
//   tv = TexCoordFixed(V, 3 + TexU + 8)                       mipmapped declared shorter (d > 0): V at the full height,
//                                                             then less the half texel of the declared height (P4)
//   [sample "declared", texfar_mipv, texfar_decl, tsp2_tall; coordfix: rounded down in two's complement; texfar*: the
//   sign and the low 26 bits far out] (p2_fp_tex_coord, H11)
// "Mipmapped" is the TCW's MipMapped bit on a texture that is not raster (refsw_tile.cpp TcwRaster: ScanOrder, not a
// palette format; mip page 17).
module p2_tex_coord
  import p2_pkg::*;
  import p2_fp_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic                 clk,
  input  logic                 stall,
  input  logic                 i_v,
  input  p2_pp_ctl_t           i_ctl,
  input  p2_quot_t             i_qu,
  input  p2_quot_t             i_qv,
  output logic signed [31:0]   o_tu,
  output logic signed [31:0]   o_tv
);
  logic       pal, raster, mip, dpos;
  logic [2:0] texu, texv;
  logic [4:0] su, sv;
  assign texu   = i_ctl.hdr.tsp[5:3];
  assign texv   = i_ctl.hdr.tsp[2:0];
  assign pal    = i_ctl.hdr.tcw[29:27] == P2_PIX_PAL4 || i_ctl.hdr.tcw[29:27] == P2_PIX_PAL8;
  assign raster = i_ctl.hdr.tcw[26] && !pal;                          // TcwRaster
  assign mip    = i_ctl.hdr.tcw[31] && !raster;
  assign dpos   = texu > texv;
  assign su     = 5'd11 + 5'(texu);
  assign sv     = 5'd11 + ((mip && dpos) ? 5'(texu) : 5'(texv));

  logic signed [31:0] tu, tv;
  p2_fp_tex_coord #(.MW(P2_QUOT_MANT_BITS)) u_u (.u_neg(i_qu.neg), .u_bad(1'b0), .u_exp(i_qu.exp), .u_mant(i_qu.mant),
    .shift(su), .o_coord(tu));
  p2_fp_tex_coord #(.MW(P2_QUOT_MANT_BITS)) u_v (.u_neg(i_qv.neg), .u_bad(1'b0), .u_exp(i_qv.exp), .u_mant(i_qv.mant),
    .shift(sv), .o_coord(tv));

  always_ff @(posedge clk)
    if (i_v && !stall) begin
      o_tu <= tu;
      o_tv <= tv;
    end
endmodule

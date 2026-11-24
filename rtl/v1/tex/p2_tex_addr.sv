// p2_tex_addr: the pixel pipe's P4, texel addresses (PLAN M11; ARCHITECTURE 3.8; tsp 9.1-9.4 at refsw3 4f3efe15:
// refsw_tile.cpp TextureFilter (from the half texel to the four fetches), ClampFlip, TexStride, TexAddressGen,
// TexOffsetGen, MipPoint, fBitsPerPixel, VQIndexAddress; TexUtils.h twop). From the P3 register's coordinates (tu, tv:
// p2_tex_coord) and mipChoose's level, four taps in TextureFilter's order, each a 64-bit word address:
//
//   half texel  -128 (1/256 texel) when HALF_OFFSET[2] and the filter is bilinear; a point sample is taken at the pixel
//               centre [sample]. The dispatch's filter: FilterMode >= 2 on a TCW without MipMapped is point [shenmue_intro:
//               a trilinear pass on a texture without mipmaps samples a single texel]
//   not mipmapped  ui = tu + h, vi = tv + h; sizes 8 << TexU, 8 << TexV
//   mipmapped   (MipMapped on a texture that is not raster: TcwRaster) square of 8 << TexU at level 0:
//               ui = (tu + h) >> L;  d = TexU - TexV;  vi = (d > 0 ? CoordKeep(tv + h 2^d) : (tv + h) >> -d) >> L
//               [sa_slow1-3: the half texel at the full size; sample "declared", texfar_decl, texfar_mipv, tsp2_tall]
//   ClampU / ClampV: a coordinate below 0 is 0 [bumpclamp]
//   taps        (ui >> 8) + {1, 0, 1, 0}, (vi >> 8) + {1, 1, 0, 0}: 00, 01, 10, 11 (tap 3, the point sample); each
//               through ClampFlip (clamp / flip / wrap at the size; a strided texture never flips [sample "stride 32"])
//   weights     (ui & 255) >> 3, (vi & 255) >> 3: 5 bits [sample page 2]
//   offset      twiddled (not raster): MipPoint[3 + TexU - L] (mipmapped) + twop: v bit i at 2i and u bit i at 2i + 1
//               up to the smaller size, the larger one's higher bits after (TexCache.cpp twiddle_slow); raster: u + stride v,
//               stride TEXT_CONTROL[4:0] x 32 with StrideSel, else 8 << TexU
//   address     the offset in bytes (offset x fBitsPerPixel / 16: 16-bit texels 2, palette 8 1, palette 4 1/2; VQ indices
//               1/4, 1/8, 1/16) from TexAddr << 3, in the 64-bit word view (& 0x7FFFF8)
//   VQ          the index byte at ((start + offset) ^ (TEXT_CONTROL[12:8] << 19)) + 2048, ^ 1 with TEXT_CONTROL[16]
//               [texctl_bank, texctl_bankbase, texctl_bankmip, texctl_addr, texctl page 1]; the code book at
//               start & 0x7FFFF8 (P5 adds index x 8)
// A YUV texture's 1x1 level is read as 565 (TextureFetch) [tsp 10]. Registered (the P4 register), with the point.
module p2_tex_addr
  import p2_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic          clk,
  input  logic          rst,
  input  logic          stall,
  input  logic [31:0]   text_control,     // TEXT_CONTROL
  input  logic          half_tex,         // HALF_OFFSET[2] (texure_pixel_half_offset)
  input  logic          i_v,
  input  p2_pp_pt_t     i_pt,
  output logic          o_v,
  output p2_pp_pt_t     o_pt,
  output p2_tex_req_t   o_req
);
  p2_pp_ctl_t c;
  assign c = i_pt.ctl;

  logic       tex, pal, raster, mip, vq, strided, filt, fyuv1;
  logic [2:0] fmt, texu, texv;
  logic [1:0] fm;
  logic [3:0] lvl, nu, nv;
  assign texu    = c.hdr.tsp[5:3];
  assign texv    = c.hdr.tsp[2:0];
  assign fmt     = c.hdr.tcw[29:27];
  assign fm      = c.hdr.tsp[14:13];
  assign tex     = !c.null_ && c.hdr.isp[25];                             // ISP_TSP Texture
  assign pal     = fmt == P2_PIX_PAL4 || fmt == P2_PIX_PAL8;
  assign raster  = c.hdr.tcw[26] && !pal;                                 // TcwRaster
  assign mip     = c.hdr.tcw[31] && !raster;
  assign vq      = c.hdr.tcw[30] && !raster;
  assign strided = c.hdr.tcw[25] && c.hdr.tcw[26] && !pal;
  assign filt    = (fm >= 2'd2 && !c.hdr.tcw[31]) ? 1'b0 : (fm != 2'd0);
  assign lvl     = i_pt.level;
  assign nu      = mip ? (4'd3 + 4'(texu) - lvl) : (4'd3 + 4'(texu));
  assign nv      = mip ? (4'd3 + 4'(texu) - lvl) : (4'd3 + 4'(texv));
  assign fyuv1   = fmt == P2_PIX_YUV && lvl == 4'd3 + 4'(texu);

  // ---------------------------------------------------------------------------------------------- the coordinates
  logic signed [31:0] hp, ui, vi;
  always_comb begin
    logic signed [32:0] s;
    logic signed [31:0] v0;
    logic signed [3:0]  d;
    hp = (half_tex && filt) ? -32'sd128 : 32'sd0;
    d  = $signed({1'b0, texu}) - $signed({1'b0, texv});
    s  = '0;
    v0 = '0;
    vi = '0;
    if (!mip) begin
      ui = i_pt.tu + hp;
      vi = i_pt.tv + hp;
    end else begin
      ui = (i_pt.tu + hp) >>> lvl;
      if (d > 0) begin
        // CoordKeep(tv + h 2^d): inside +-2^30 itself, beyond the sign and the low 26 bits
        s = 33'(i_pt.tv) + (33'(hp) <<< d);
        if (s >= 33'sd1073741824)
          v0 = 32'sd1073741824 + $signed({6'd0, s[25:0]});
        else if (s < -33'sd1073741824)
          v0 = -32'sd1073741824 + $signed({6'd0, s[25:0]});
        else
          v0 = 32'(s);
      end else
        v0 = (i_pt.tv + hp) >>> (4'd0 - 4'(d));
      vi = v0 >>> lvl;
    end
    if (c.hdr.tsp[16] && ui < 0) ui = '0;                                // ClampU
    if (c.hdr.tsp[15] && vi < 0) vi = '0;                                // ClampV
  end

  // ClampFlip<clamp, flip> at size 2^n; the result is below the size (at most 1023)
  function automatic logic [9:0] clamp_flip(input logic signed [31:0] co, input logic [3:0] n, input logic clamp,
                                            input logic flip);
    logic [31:0] sz, m;
    sz = 32'd1 << n;
    if (clamp) begin
      if (co < 0) m = '0;
      else if ($unsigned(co) >= sz) m = sz - 32'd1;
      else m = $unsigned(co);
    end else if (flip) begin
      m = $unsigned(co) & ((sz << 1) - 32'd1);
      if ((m & sz) != '0) m = m ^ ((sz << 1) - 32'd1);
    end else
      m = $unsigned(co) & (sz - 32'd1);
    return m[9:0];
  endfunction

  // twop: v bit i at 2i, u bit i at 2i + 1 while both have bits (nv, nu), then the larger size's bits on top
  function automatic logic [19:0] twiddle(input logic [9:0] u, input logic [9:0] v, input logic [3:0] tnu,
                                          input logic [3:0] tnv);
    logic [19:0] r;
    r = '0;
    // (OR: a bit past a coordinate's size is 0, and its place may be the other coordinate's)
    for (int i = 0; i < 10; i++) begin
      if (4'(i) < tnv) r = r | (20'(u[i]) << (2 * i + 1));
      else r = r | (20'(u[i]) << (32'(tnv) + i));
      if (4'(i) < tnu) r = r | (20'(v[i]) << (2 * i));
      else r = r | (20'(v[i]) << (32'(tnu) + i));
    end
    return r;
  endfunction

  // MipPoint[k]: where the level of size 2^k starts, in texels (refsw_tile.cpp MipPoint)
  function automatic logic [19:0] mip_point(input logic [3:0] k);
    case (k)
      4'd0:    return 20'h00003;
      4'd1:    return 20'h00004;
      4'd2:    return 20'h00008;
      4'd3:    return 20'h00018;
      4'd4:    return 20'h00058;
      4'd5:    return 20'h00158;
      4'd6:    return 20'h00558;
      4'd7:    return 20'h01558;
      4'd8:    return 20'h05558;
      4'd9:    return 20'h15558;
      default: return 20'h55558;
    endcase
  endfunction

  // ---------------------------------------------------------------------------------------------- the taps
  p2_tex_req_t req;
  always_comb begin
    logic signed [31:0] cu0, cv0, cu1, cv1;
    logic [9:0]  tu_[4], tv_[4];
    logic [10:0] stride;
    logic [21:0] off;
    logic [21:0] boff;
    logic [24:0] start, b;
    logic [25:0] ia;
    cu0 = ui >>> 8;
    cv0 = vi >>> 8;
    cu1 = cu0 + 32'sd1;
    cv1 = cv0 + 32'sd1;
    stride = strided ? {1'b0, text_control[4:0], 5'd0} : (11'd8 << texu);
    start  = {1'b0, c.hdr.tcw[20:0], 3'd0};
    req       = '0;
    req.need  = tex ? (filt ? 4'b1111 : 4'b1000) : 4'b0000;
    req.vq    = vq;
    req.ub    = ui[7:3];
    req.vb    = vi[7:3];
    req.fmt   = fyuv1 ? P2_PIX_565 : fmt;
    req.twid  = !raster;
    req.filt  = filt;
    req.strided = strided;
    req.cbase = start[22:3];
    for (int t = 0; t < 4; t++) begin
      tu_[t] = clamp_flip((t == 0 || t == 2) ? cu1 : cu0, nu, c.hdr.tsp[16], c.hdr.tsp[18] && !strided);
      tv_[t] = clamp_flip((t < 2) ? cv1 : cv0, nv, c.hdr.tsp[15], c.hdr.tsp[17] && !strided);
      if (raster)
        off = 22'(tu_[t]) + 22'(stride) * 22'(tv_[t]);
      else
        off = (mip ? 22'(mip_point(nu)) : 22'd0) + 22'(twiddle(tu_[t], tv_[t], nu, nv));
      // the offset in bytes: offset x fBitsPerPixel / 16
      if (vq)
        boff = (fmt == P2_PIX_PAL4) ? (off >> 4) : (fmt == P2_PIX_PAL8) ? (off >> 3) : (off >> 2);
      else
        boff = (fmt == P2_PIX_PAL4) ? (off >> 1) : (fmt == P2_PIX_PAL8) ? off : (off << 1);
      b  = start + 25'(boff);
      ia = ({1'b0, b} ^ {2'b0, text_control[12:8], 19'd0}) + 26'd2048;
      if (text_control[16]) ia[0] = !ia[0];
      req.waddr[t] = vq ? ia[22:3] : b[22:3];
      req.ibyte[t] = ia[2:0];
      req.toff[t]  = off[3:0];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) o_v <= 1'b0;
    else if (!stall) o_v <= i_v;
    if (i_v && !stall) begin
      o_pt  <= i_pt;
      o_req <= req;
    end
  end
endmodule

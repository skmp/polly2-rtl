// p2_tex_decode: the pixel pipe's P6 texel decode (PLAN M11; ARCHITECTURE 3.8; tsp 9.5, 9.6, 10 at refsw3 4f3efe15:
// refsw_tile.cpp TextureFetch from the fetched word on, DecodeTextel, GetExpandFormat, ExpandToARGB8888; TexUtils.h
// EXPAND4/5/6, ARGB*_32, YUV422; TextureFilter's strided widening). Combinational: the four taps' 64-bit words (P5
// register) to four ARGB8888 texels for p2_tex_filter:
//
//   (TEXT_CONTROL[17]'s byte swap is P5's: p2_tex_cache gives the words swapped, the VQ index bytes read as they are)
//   select      16-bit formats (1555, 565, 4444, bump, reserved 7): unit offset & 3; palette 8: byte offset & 7; palette
//               4: nibble offset & 15
//   palette     PALETTE_RAM[PalSelect x 16 | nibble] (4 bpp), PALETTE_RAM[(PalSelect / 16) x 256 | byte] (8 bpp), read
//               now (p2_tex_pal) and expanded by PAL_RAM_CTRL[1:0]
//   YUV422      Y of the texel's unit (its high byte), U from the texel at the even x of the pair, V from the odd one;
//               twiddled the pair is two units apart (x is index bit 1), raster next to each other [yuvbil: paired by x,
//               not by memory order]; the conversion x 11/8 as x + x/4 + x/8, arithmetic shifts [texfmt pages 1, 2]
//   expand      1555 / 565 / 4444 by bit replication [texfmt]; bump map, YUV and format 7 raw (8888 shuffle)
//   strided     with a bilinear filter, 565 / 1555 / 4444 (and 7) widened by shifting only: the low bits 0 [texfmt
//               "stride 32, bilinear"]
module p2_tex_decode
  import p2_pkg::*;
  import p2_tsp_pkg::*;
(
  input  p2_tex_req_t       req,
  input  logic [31:0]       tcw,
  input  logic [1:0]        pal_mode,         // PAL_RAM_CTRL[1:0]
  input  logic [3:0][63:0]  word,
  output logic [3:0][9:0]   pal_idx,
  input  logic [3:0][31:0]  pal_data,
  output logic [3:0][31:0]  texel
);
  function automatic logic [7:0] e5(input logic [4:0] v); return {v, v[4:2]}; endfunction
  function automatic logic [7:0] e6(input logic [5:0] v); return {v, v[5:4]}; endfunction
  function automatic logic [7:0] e4(input logic [3:0] v); return {v, v}; endfunction
  // ExpandToARGB8888: mode 0 1555, 1 565, 2 4444, 3 the word as it is
  function automatic logic [31:0] expand(input logic [31:0] w, input logic [1:0] mode);
    case (mode)
      2'd0:    return {w[15] ? 8'hFF : 8'h00, e5(w[14:10]), e5(w[9:5]), e5(w[4:0])};
      2'd1:    return {8'hFF, e5(w[15:11]), e6(w[10:5]), e5(w[4:0])};
      2'd2:    return {e4(w[15:12]), e4(w[11:8]), e4(w[7:4]), e4(w[3:0])};
      default: return w;
    endcase
  endfunction
  function automatic logic [7:0] clamp255(input logic signed [11:0] v);
    if (v < 0) return 8'd0;
    if (v > 12'sd255) return 8'd255;
    return v[7:0];
  endfunction
  // YUV422(Y, U, V)
  function automatic logic [31:0] yuv(input logic [7:0] y, input logic [7:0] u, input logic [7:0] v);
    logic signed [11:0] yu, yv, tu, tv, r, g, b;
    yu = $signed({4'd0, u}) - 12'sd128;
    yv = $signed({4'd0, v}) - 12'sd128;
    tu = yu + (yu >>> 2) + (yu >>> 3);
    tv = yv + (yv >>> 2) + (yv >>> 3);
    r  = $signed({4'd0, y}) + tv;
    g  = $signed({4'd0, y}) - (tu >>> 2) - (tv >>> 1);
    b  = $signed({4'd0, y}) + tu + (tu >>> 2);
    return {8'hFF, clamp255(r), clamp255(g), clamp255(b)};
  endfunction

  logic [5:0] pal_sel;
  logic [2:0] tfmt;
  logic       widen;
  assign pal_sel = tcw[26:21];
  assign tfmt    = tcw[29:27];
  assign widen   = req.strided && req.filt && tfmt != P2_PIX_YUV && tfmt != P2_PIX_BUMP;

  // the palette index first (its RAM read is in this stage)
  logic [3:0][63:0] sw;
  always_comb
    for (int t = 0; t < 4; t++) begin
      sw[t] = word[t];
      pal_idx[t] = (req.fmt == P2_PIX_PAL4) ? {pal_sel, sw[t][4 * req.toff[t] +: 4]}
                                            : {pal_sel[5:4], sw[t][8 * req.toff[t][2:0] +: 8]};
    end

  always_comb
    for (int t = 0; t < 4; t++) begin
      logic [63:0] m;
      logic [15:0] u16;
      logic [1:0]  self, pu, pv;
      logic [31:0] x;
      m    = sw[t];
      u16  = m[16 * req.toff[t][1:0] +: 16];
      self = req.toff[t][1:0];
      pu   = req.twid ? {1'b0, self[0]} : {self[1], 1'b0};
      pv   = req.twid ? {1'b1, self[0]} : {self[1], 1'b1};
      case (req.fmt)
        P2_PIX_PAL4, P2_PIX_PAL8: x = expand(pal_data[t], pal_mode);
        P2_PIX_YUV:  x = yuv(m[16 * self + 8 +: 8], m[16 * pu +: 8], m[16 * pv +: 8]);
        P2_PIX_BUMP, P2_PIX_RSVD: x = {16'd0, u16};
        default:     x = expand({16'd0, u16}, req.fmt[1:0]);
      endcase
      if (widen) begin
        x[7:0]   = x[7:0] & ((tfmt == P2_PIX_4444) ? 8'hF0 : 8'hF8);
        x[15:8]  = x[15:8] & ((tfmt == P2_PIX_4444) ? 8'hF0 : (tfmt == P2_PIX_565) ? 8'hFC : 8'hF8);
        x[23:16] = x[23:16] & ((tfmt == P2_PIX_4444) ? 8'hF0 : 8'hF8);
        if (tfmt == P2_PIX_4444) x[31:24] = x[31:24] & 8'hF0;
      end
      texel[t] = x;
    end
endmodule

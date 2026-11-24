// p2_pp_shade: the pixel pipe's P7 shade (PLAN M11; ARCHITECTURE 3.7.7 P7; tsp 12, 13, 14 at refsw3 4f3efe15:
// refsw_tile.cpp PixelFlush_tsp's `shade` and `bumpLight` lambdas and its offs / offsKept lines, ColorCombiner,
// BumpMapper, BlendMul). From the P6 register (the point, its base and offset colours, the texel):
//
//   offs        the pixel's offset colour: with Texture and Offset the interpolated one (InterpolateOffs, P3), for a bump
//               map the light; otherwise the kept one, offsKept
//   offsKept    ONE register in this stage, read and loaded in pixel order (the TSP's order, tsp 3.4): a point of a
//               volume with Texture and Offset loads its light (the third vertex's offset colour as sent, the entry's
//               fallback bytes, scaled for an intensity shadow); kept across tiles, renders and the core's soft resets
//               (zero at power-on, `rst`) [offspersist: 293 of 299 cells and more on every page; bumplight]
//   bump map    (Texture, the volume's TCW format 4) BumpMapper on the texel's R (low byte) and S (high byte) under the
//               light K1 = A, K2 = R, K3 = G, Q = B of offs:
//                 a = |R - Q|, x = a & 63 (quadrants 0, 2) or 63 - x (1, 3), t3 = (((K3 COS[S]) >> 8) COS[4x]) >> 8,
//                 I = K1 + ((K2 SIN[S]) >> 8) +- t3 (- in quadrants 1, 2), clamped 0 .. 255   [bumpfn]
//               its result (255, 255, 255, I) takes the texel's place in the combiner, Offset not added [bump]
//   combiner    Texture off: the base colour. ShadInstr 0 decal: the texel; 1 modulate: rgb (t b) >> 8, alpha t; 2 decal
//               alpha: rgb ((t tb) >> 8) + ((b (256 - tb)) >> 8), tb = t.a with 255 as 256, alpha b; 3 modulate alpha:
//               rgb (t b) >> 8, alpha min((t.a' b.a') >> 8, 255) with 255 as 256 on either side [env, env page 1];
//               then with Offset the offset colour's rgb added, saturated
//   fog alpha   for P8's vertex fog: offs' alpha, 0 for a bump map [bumplight page 5]
// The SIN / COS tables are p2_rom_bm_sin / p2_rom_bm_cos (one SIN, two COS). Registered (the P7 register).
module p2_pp_shade
  import p2_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic          clk,
  input  logic          rst,
  input  logic          stall,
  input  logic          i_v,
  input  p2_pp_pt_t     i_pt,
  input  logic [31:0]   i_tex,
  output logic          o_v,
  output p2_pp_pt_t     o_pt,
  output logic [31:0]   o_col,
  output logic [7:0]    o_fa,         // the vertex fog's alpha (FogUnit's offs_a)
  // offsKept: the register and a load port for the testbench (the state a capture starts from)
  output logic [31:0]   offs_kept,
  input  logic          ok_we,
  input  logic [31:0]   ok_wdata
);
  p2_pp_ctl_t c;
  assign c = i_pt.ctl;

  logic        texture, offset, bump;
  logic [1:0]  si;
  logic [31:0] light, offs;
  assign texture = c.hdr.isp[25];
  assign offset  = c.hdr.isp[24];
  assign si      = c.hdr.tsp[7:6];
  assign bump    = texture && c.hdr.tcw[29:27] == P2_PIX_BUMP;
  assign light   = c.hdr.ofs_fb;
  assign offs    = (texture && offset) ? (bump ? light : i_pt.offs) : offs_kept;

  // ---------------------------------------------------------------------------------------------- BumpMapper
  logic [7:0] sin_s, cos_s, cos_x;
  logic [7:0] bm_r, bm_s, bm_q;
  logic [8:0] bm_a;
  logic [7:0] bm_xi;
  assign bm_r  = i_tex[7:0];
  assign bm_s  = i_tex[15:8];
  assign bm_q  = offs[7:0];
  assign bm_a  = (bm_r >= bm_q) ? ({1'b0, bm_r} - {1'b0, bm_q}) : ({1'b0, bm_q} - {1'b0, bm_r});
  assign bm_xi = {(bm_a[6] ? (6'd63 - bm_a[5:0]) : bm_a[5:0]), 2'b00};    // 4 x, x mirrored in quadrants 1, 3
  p2_rom_bm_sin u_sin (.i(bm_s), .v(sin_s));
  p2_rom_bm_cos u_cos (.i(bm_s), .v(cos_s));
  p2_rom_bm_cos u_cx (.i(bm_xi), .v(cos_x));
  logic [31:0] bm;
  always_comb begin
    logic [15:0]        p2, p3, t3p;
    logic signed [10:0] ii;
    p2  = 16'(offs[23:16]) * 16'(sin_s);             // K2 SIN[S]
    p3  = 16'(offs[15:8]) * 16'(cos_s);              // K3 COS[S]
    t3p = 16'(p3[15:8]) * 16'(cos_x);
    ii  = $signed({3'd0, offs[31:24]}) + $signed({3'd0, p2[15:8]});
    if (bm_a[7:6] == 2'd1 || bm_a[7:6] == 2'd2) ii = ii - $signed({3'd0, t3p[15:8]});
    else ii = ii + $signed({3'd0, t3p[15:8]});
    bm = {(ii < 0) ? 8'd0 : (ii > 11'sd255) ? 8'd255 : ii[7:0], 24'hFFFFFF};
  end

  // ---------------------------------------------------------------------------------------------- ColorCombiner
  function automatic logic [8:0] bmul(input logic [7:0] x);   // BlendMul(x, false): 255 counts as 256
    return {1'b0, x} + ((x == 8'hFF) ? 9'd1 : 9'd0);
  endfunction
  logic [31:0] col;
  always_comb begin
    logic [31:0] b, t;
    logic [8:0]  tb, cb;
    logic [17:0] am;
    b   = i_pt.base;
    t   = bump ? bm : i_tex;
    col = b;
    if (texture) begin
      tb = bmul(t[31:24]);
      cb = 9'd256 - tb;
      for (int ch = 0; ch < 3; ch++) begin
        logic [15:0] m;
        logic [16:0] t1, t2;
        m  = 16'(t[8 * ch +: 8]) * 16'(b[8 * ch +: 8]);
        t1 = 17'(t[8 * ch +: 8]) * 17'(tb);
        t2 = 17'(b[8 * ch +: 8]) * 17'(cb);
        case (si)
          2'd0:    col[8 * ch +: 8] = t[8 * ch +: 8];
          2'd2:    col[8 * ch +: 8] = t1[15:8] + t2[15:8];
          default: col[8 * ch +: 8] = m[15:8];
        endcase
      end
      am = 18'(bmul(t[31:24])) * 18'(bmul(b[31:24]));
      case (si)
        2'd0, 2'd1: col[31:24] = t[31:24];
        2'd2:       col[31:24] = b[31:24];
        default:    col[31:24] = (am[17:8] > 10'd255) ? 8'd255 : am[15:8];
      endcase
      if (offset && !bump)
        for (int ch = 0; ch < 3; ch++) begin
          logic [8:0] s;
          s = {1'b0, col[8 * ch +: 8]} + {1'b0, offs[8 * ch +: 8]};
          col[8 * ch +: 8] = s[8] ? 8'd255 : s[7:0];
        end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) o_v <= 1'b0;
    else if (!stall) o_v <= i_v;
    if (i_v && !stall) begin
      o_pt  <= i_pt;
      o_col <= col;
      o_fa  <= bump ? 8'd0 : offs[31:24];
    end
    // offsKept: zero at power-on (rst; refsw3's static starts at 0, offspersist: "about zero after the console was
    // switched on"), then never cleared: it outlives tiles, renders and the core's soft resets (offspersist)
    if (rst)
      offs_kept <= '0;
    else if (ok_we)
      offs_kept <= ok_wdata;
    else if (i_v && !stall && !c.null_ && texture && offset)
      offs_kept <= light;
  end
endmodule

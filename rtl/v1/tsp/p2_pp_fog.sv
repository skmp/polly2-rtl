// p2_pp_fog: the pixel pipe's P8 colour clamp, fog and trilinear fade (PLAN M11; ARCHITECTURE 3.7.7 P8; tsp 15, 16 at
// refsw3 4f3efe15: refsw_tile.cpp FogUnit, LookupFogTable (FOG_VARIANT 0: FOG_K(a) = a, pinned by
// tools/check_ref_switches.sh), PixelFlush_tsp's `fade` lambda). From the P7 register (the shaded colour, the vertex fog's
// alpha, the point's 1/w and trilinear k):
//
//   clamp       ColorClamp: each channel min(c, FOG_CLAMP_MAX), then max(., FOG_CLAMP_MIN)
//   table fog   FogCtrl 00 (mode 1) and 11 (mode 2): fogW = FOG_DENSITY's mantissa (bits 15:8, the units bit 7) x the
//               TSP's own 1/w (the plane's value, 16 bits: exact in 24 bits) x 2^(exponent bits 7:0 - 7), clamped to
//               1 .. 256 - 2^-16; a 1/w below zero, zero, or a zero density counts as below 1 [fog, tspw, slivers_dzspec];
//               index ((exponent + 1) & 7) << 4 | the fraction's top 4 bits, blend the next 8 bits f:
//               fog alpha = (FOG_TABLE[index][7:0] f + FOG_TABLE[index][15:8] (256 - f)) >> 8
//               mode 1: rgb = (c (256 - a) + FOG_COL_RAM a) >> 8; mode 2: rgb = FOG_COL_RAM, alpha = fog alpha
//   vertex fog  FogCtrl 01 with Offset: rgb = (c (256 - a) + FOG_COL_VERT a) >> 8, a the offset colour's alpha as it is
//               (P7's o_fa; 0 for a bump map) [sc_ingame: 12,242 of 12,242 pixels]
//   fade        Texture, FilterMode 2 / 3 on a TCW with MipMapped: each channel (alpha too) (c w) >> 8, w = 256 - k
//               (pass A) or k (pass B) [supsample2 page 21, trifade; mip "565 without mipmaps": no fade]
// FOG_TABLE is read here, at shading time: its 128 entries are this unit's RAM (16 bits each: the two bytes a lookup
// reads), written through the register port (p2_regs' in M12, the testbench's in M11), read asynchronously in P8.
// Registered (the P8 register).
module p2_pp_fog
  import p2_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic          clk,
  input  logic          rst,
  input  logic          stall,
  input  logic [31:0]   fog_col_ram,      // FOG_COL_RAM
  input  logic [31:0]   fog_col_vert,     // FOG_COL_VERT
  input  logic [15:0]   fog_density,      // FOG_DENSITY
  input  logic [31:0]   fog_clamp_max,    // FOG_CLAMP_MAX
  input  logic [31:0]   fog_clamp_min,    // FOG_CLAMP_MIN
  input  logic          ft_we,            // FOG_TABLE 0x200 + 4 idx
  input  logic [6:0]    ft_idx,
  input  logic [15:0]   ft_wdata,
  input  logic          i_v,
  input  p2_pp_pt_t     i_pt,
  input  logic [31:0]   i_col,
  input  logic [7:0]    i_fa,
  output logic          o_v,
  output p2_pp_pt_t     o_pt,
  output logic [31:0]   o_col
);
  logic [15:0] ftab [128];
  always_ff @(posedge clk)
    if (ft_we) ftab[ft_idx] <= ft_wdata;

  p2_pp_ctl_t c;
  assign c = i_pt.ctl;

  // ---------------------------------------------------------------------------------------------- LookupFogTable
  logic [7:0] fog_alpha;
  logic [6:0] fidx;
  always_comb begin
    logic [24:0]                m;
    logic [4:0]                 n;
    logic signed [12:0]         e, e23;
    logic [22:0]                frac;
    logic [7:0]                 bf;
    logic [16:0]                fa;
    m    = 25'(fog_density[15:8]) * 25'(i_pt.w.mant);
    n    = '0;
    for (int i = 0; i < 25; i++)
      if (m[i]) n = 5'(i + 1);
    e    = 13'($signed(i_pt.w.exp)) + 13'($signed(fog_density[7:0])) - 13'sd7 - (13'sd24 - 13'(n));
    m    = m << (5'd24 - n);
    e23  = e + 13'sd23;
    if (i_pt.w.neg || i_pt.w.mant == '0 || fog_density[15:8] == 8'd0 || e23 < 0) begin
      frac = '0;                                               // below 1: 1
      e23  = '0;
    end else if (e23 > 13'sd7) begin
      frac = 23'h7FFFFF;                                       // 256 and above: 256 - 2^-16 (M = 2^24 - 1 at E = -16)
      e23  = 13'sd7;
    end else
      frac = m[22:0];
    fidx = {e23[2:0], frac[22:19]};
    bf   = frac[18:11];
    fa   = 17'(ftab[fidx][7:0]) * 17'(bf) + 17'(ftab[fidx][15:8]) * (17'd256 - 17'(bf));
    fog_alpha = fa[15:8];
  end

  // the trilinear fade of a colour (each channel, alpha too)
  function automatic logic [31:0] fade(input logic [31:0] cc, input p2_pp_ctl_t cx, input logic [8:0] k);
    logic [31:0] r;
    logic [1:0]  fm;
    logic [8:0]  w;
    r  = cc;
    fm = cx.hdr.tsp[14:13];
    w  = (fm == 2'd2) ? (9'd256 - k) : k;
    if (cx.hdr.isp[25] && fm >= 2'd2 && cx.hdr.tcw[31])
      for (int ch = 0; ch < 4; ch++) begin
        logic [16:0] s;
        s = 17'(cc[8 * ch +: 8]) * 17'(w);
        r[8 * ch +: 8] = s[15:8];
      end
    return r;
  endfunction

  // the clamp and the fog, then the fade of the finished colour
  logic [31:0] fg_in, fg_out, col;
  assign fg_in  = i_col;
  assign col    = fade(fg_out, c, i_pt.k);
  always_comb begin
    fg_out = fg_in;
    if (c.hdr.tsp[21])                                                  // ColorClamp
      for (int ch = 0; ch < 4; ch++) begin
        if (fg_out[8 * ch +: 8] > fog_clamp_max[8 * ch +: 8]) fg_out[8 * ch +: 8] = fog_clamp_max[8 * ch +: 8];
        if (fg_out[8 * ch +: 8] < fog_clamp_min[8 * ch +: 8]) fg_out[8 * ch +: 8] = fog_clamp_min[8 * ch +: 8];
      end
    case (c.hdr.tsp[23:22])                                             // FogCtrl
      2'b00:
        for (int ch = 0; ch < 3; ch++) begin
          logic [16:0] s;
          s = 17'(fg_out[8 * ch +: 8]) * (17'd256 - 17'(fog_alpha)) + 17'(fog_col_ram[8 * ch +: 8]) * 17'(fog_alpha);
          fg_out[8 * ch +: 8] = s[15:8];
        end
      2'b11: begin
        fg_out[23:0]  = fog_col_ram[23:0];
        fg_out[31:24] = fog_alpha;
      end
      2'b01:
        if (c.hdr.isp[24])                                              // pp_Offset
          for (int ch = 0; ch < 3; ch++) begin
            logic [16:0] s;
            s = 17'(fg_out[8 * ch +: 8]) * (17'd256 - 17'(i_fa)) + 17'(fog_col_vert[8 * ch +: 8]) * 17'(i_fa);
            fg_out[8 * ch +: 8] = s[15:8];
          end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) o_v <= 1'b0;
    else if (!stall) o_v <= i_v;
    if (i_v && !stall) begin
      o_pt  <= i_pt;
      o_col <= col;
    end
  end
endmodule

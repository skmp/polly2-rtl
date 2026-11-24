// p2_wout_put: one framebuffer pixel to video memory (PLAN M12; ARCHITECTURE 3.10; tsp 17.3, 17.4): refcore
// refsw_lists.cpp RenderCORE's `put` lambda at refsw3 4f3efe15 (tb/ref/ref_copies.h core-put), then the VRAM writer (C5).
//
//   clip     X outside FB_X_CLIP.min .. max or Y outside FB_Y_CLIP.min .. max (framebuffer coordinates, both ends in): no
//            write [fbclip]
//   strip    FB_R_CTRL[22] (fb_strip_buf_en): stripLines = 16 * FB_R_CTRL[21:16]; 0 lines: no write; the strip number
//            only grows, a line at or below the next strip's first moves it on (one strip a clock: the pixel waits),
//            line = Y - strip * stripLines, below 0 no write; FB_W_SOF2 for an odd strip, FB_W_SOF1 for an even one
//            [sof2sweep]; without strips line = Y and FB_W_SOF1 [sof2probe, sof2field, scalermeas]
//   address  dst = base + line * FB_W_LINESTRIDE.stride * 8 + X * bpp (32-bit wrap), bpp 2 (pack modes 0-3), 3 (4), 4 (5-7)
//   dither   FB_W_CTRL[3]: ditherAdd[Y & 3][X & 3] (the measured table [fbpack; fb555, fb565]) >> (bits - 4) added before
//            a channel is cut to `bits` bits, saturating
//   pack     0 0555 KRGB (bit 15 = fb_kval[7]); 1 565; 2 4444 (alpha dithered too); 3 1555 (bit 15 = a >= fb_alpha_threshold);
//            4 888 packed (three bytes); 5 0888 KRGB (top byte fb_kval); 6 8888; 7 is invalid (refsw3 verify()s; here as 6, GAP)
//   memory   render to texture (FB_W_SOF1[24]: whatever the strip's base) writes the bytes at dst & VRAM_MASK in the 64-bit
//            order; otherwise through pvr_map32 (the 32-bit area: half dst[22], word dst[21:2], byte dst[1:0]). As
//            refsw3 stores them: a 16- or 32-bit pixel is its bytes at map(dst) + 0, 1 (, 2, 3) in the physical order
//            (an unaligned one runs on into the next physical word), the packed 888 pixel each byte at map(dst + i).
//            A pixel's bytes fall in at most two physical words: one or two C5 requests.
//   writer   consecutive pixels' bytes in one physical word are merged into one request with byte enables (a 16-bit
//            framebuffer: two pixels a word); a word is written when the next pixel's bytes go elsewhere or no pixel
//            follows. C5 is a 32-bit-view client: the physical word {w, h} at address {h, w, 2'b00}.
// [M tim 3.11: 1045 / 1105 / 1357 clk a tile at 16 / 24 / 32 bpp, also fully clipped, dither changes nothing; one word a
// clock, the per-line cost from the VRAM model's row change, VR_ROW (T9)]
module p2_wout_put
  import p2_regs_pkg::*;
(
  input  logic         clk,
  input  logic         rst,
  input  logic         flush,           // a render's start: the strip number back to 0
  input  logic [31:0]  fb_w_ctrl,
  input  logic [31:0]  fb_w_linestride,
  input  logic [31:0]  fb_w_sof1,
  input  logic [31:0]  fb_w_sof2,
  input  logic [31:0]  fb_x_clip,
  input  logic [31:0]  fb_y_clip,
  input  logic [31:0]  fb_r_ctrl,
  // the pixel
  input  logic         i_v,
  output logic         i_rdy,
  input  logic [11:0]  i_x,
  input  logic [11:0]  i_y,
  input  logic [31:0]  i_px,             // B, G, R, A (byte 0 blue)
  output logic         idle,
  // C5
  output logic         m_v,
  input  logic         m_rdy,
  output logic [23:0]  m_addr,
  output logic [3:0]   m_be,
  output logic [31:0]  m_wdata
);
  p2_fb_w_ctrl_t ctl;
  p2_fb_x_clip_t xc;
  p2_fb_y_clip_t yc;
  assign ctl = p2_fb_w_ctrl_t'(fb_w_ctrl);
  assign xc  = p2_fb_x_clip_t'(fb_x_clip);
  assign yc  = p2_fb_y_clip_t'(fb_y_clip);

  // ---------------------------------------------------------------------------------------------- P1: the pixel
  logic        s_v;
  logic [11:0] s_x, s_y;
  logic [31:0] s_px;
  logic        s_done;                  // P1's pixel leaves this clock
  assign i_rdy = !s_v || s_done;
  assign idle  = !s_v && !p_v;

  // the strip counter
  logic        sbuf;
  logic [10:0] slines;
  logic [15:0] strip, stop, sbase;      // strip, (strip + 1) * stripLines, strip * stripLines
  assign sbuf   = fb_r_ctrl[22];
  assign slines = {1'b0, fb_r_ctrl[21:16], 4'd0};
  assign sbase  = stop - 16'(slines);
  logic        sgrow;                   // the pixel's Y is past the strip: the strip moves on first (a clipped pixel
                                        // returns before the strip is looked at: put's order)
  assign sgrow  = s_v && !cdrop && sbuf && slines != '0 && 16'(s_y) >= stop;

  // ---------------------------------------------------------------------------------------------- the pixel's bytes
  logic        drop;
  logic [31:0] base, dst, line;
  logic [2:0]  bpp;
  logic [2:0]  pm;
  logic [3:0]  add;
  logic [7:0]  b8, g8, r8, a8, b5, g5, r5, g6, b4, g4, r4, a4;
  logic        cdrop;                 // outside the pixel clip
  logic [31:0] pix;
  logic [22:0] pa [4];                  // each byte's physical address
  logic [2:0]  nb;
  function automatic logic [7:0] cut(input logic [7:0] v, input logic [3:0] addv, input int bits);
    logic [8:0] q;
    logic [8:0] top;
    q   = (9'(v) + (9'(addv) >> (bits - 4))) >> (8 - bits);
    top = 9'((1 << bits) - 1);
    return (q > top) ? top[7:0] : q[7:0];
  endfunction
  function automatic logic [22:0] phys(input logic [31:0] a, input logic rtt);
    return rtt ? a[22:0] : {a[21:2], a[22], a[1:0]};     // dst & VRAM_MASK, pvr_map32
  endfunction
  always_comb begin
    // the measured dither table (RenderCORE ditherAdd)
    logic [3:0] dt [16];
    logic       rtt;
    dt = '{4'd5, 4'd13, 4'd7, 4'd15, 4'd9, 4'd1, 4'd11, 4'd3, 4'd6, 4'd14, 4'd4, 4'd12, 4'd10, 4'd2, 4'd8, 4'd0};
    pm   = ctl.fb_packmode;
    bpp  = pm <= 3'd3 ? 3'd2 : (pm == 3'd4 ? 3'd3 : 3'd4);
    rtt  = fb_w_sof1[24];
    cdrop = s_x < 12'(xc.min) || s_x > 12'(xc.max) || s_y < 12'(yc.min) || s_y > 12'(yc.max);
    drop  = cdrop;
    base = fb_w_sof1;
    line = 32'(s_y);
    if (sbuf) begin
      if (slines == '0 || 16'(s_y) < sbase)
        drop = 1'b1;
      line = 32'(16'(16'(s_y) - sbase));
      base = strip[0] ? fb_w_sof2 : fb_w_sof1;
    end
    dst = base + line * 32'(fb_w_linestride[8:0]) * 32'd8 + 32'(s_x) * 32'(bpp);
    add = ctl.fb_dither ? dt[{s_y[1:0], s_x[1:0]}] : 4'd0;
    b8  = s_px[7:0];
    g8  = s_px[15:8];
    r8  = s_px[23:16];
    a8  = s_px[31:24];
    b5 = cut(b8, add, 5);
    g5 = cut(g8, add, 5);
    r5 = cut(r8, add, 5);
    g6 = cut(g8, add, 6);
    b4 = cut(b8, add, 4);
    g4 = cut(g8, add, 4);
    r4 = cut(r8, add, 4);
    a4 = cut(a8, add, 4);
    case (pm)
      3'd0:    pix = {16'd0, ctl.fb_kval[7], r5[4:0], g5[4:0], b5[4:0]};
      3'd1:    pix = {16'd0, r5[4:0], g6[5:0], b5[4:0]};
      3'd2:    pix = {16'd0, a4[3:0], r4[3:0], g4[3:0], b4[3:0]};
      3'd3:    pix = {16'd0, a8 >= ctl.fb_alpha_threshold, r5[4:0], g5[4:0], b5[4:0]};
      3'd4:    pix = {8'd0, r8, g8, b8};
      3'd5:    pix = {ctl.fb_kval, r8, g8, b8};
      default: pix = {a8, r8, g8, b8};
    endcase
    nb = bpp;
    for (int i = 0; i < 4; i++)
      if (bpp == 3'd3) pa[i] = phys(dst + 32'(i), rtt);
      else             pa[i] = phys(dst, rtt) + 23'(i);
  end

  // the two groups: the bytes in the first byte's physical word, the rest (all in one other word)
  logic [20:0] wa, wb;
  logic [3:0]  bea, beb;
  logic [31:0] da, db;
  always_comb begin
    wa  = pa[0][22:2];
    wb  = wa;
    bea = '0;
    beb = '0;
    da  = '0;
    db  = '0;
    for (int i = 0; i < 4; i++)
      if (3'(i) < nb) begin
        if (pa[i][22:2] == wa) begin
          bea[pa[i][1:0]]          = 1'b1;
          da[8 * pa[i][1:0] +: 8]  = pix[8 * i +: 8];
        end else begin
          wb                       = pa[i][22:2];
          beb[pa[i][1:0]]          = 1'b1;
          db[8 * pa[i][1:0] +: 8]  = pix[8 * i +: 8];
        end
      end
  end

  // ---------------------------------------------------------------------------------------------- the groups out
  // P1 hands its groups to the writer one a clock: the first, then (if any) the second
  logic        g_second;               // the first group has gone
  logic        g_v, g_rdy;
  logic [20:0] g_w;
  logic [3:0]  g_be;
  logic [31:0] g_d;
  assign g_v    = s_v && !sgrow && !drop;
  assign g_w    = g_second ? wb : wa;
  assign g_be   = g_second ? beb : bea;
  assign g_d    = g_second ? db : da;
  assign s_done = s_v && !sgrow && (drop || (g_rdy && (g_second || beb == '0)));

  always_ff @(posedge clk) begin
    if (rst) begin
      s_v      <= 1'b0;
      g_second <= 1'b0;
    end else begin
      if (i_v && i_rdy) begin
        s_v  <= 1'b1;
        s_x  <= i_x;
        s_y  <= i_y;
        s_px <= i_px;
      end else if (s_done)
        s_v <= 1'b0;
      if (s_done)
        g_second <= 1'b0;
      else if (g_v && g_rdy)
        g_second <= 1'b1;
    end
  end
  always_ff @(posedge clk)
    if (rst || flush) begin
      strip <= '0;
      stop  <= 16'(slines);
    end else if (sgrow) begin
      strip <= strip + 16'd1;
      stop  <= stop + 16'(slines);
    end

  // ---------------------------------------------------------------------------------------------- the writer
  logic        p_v, merge;
  logic [20:0] p_w;
  logic [3:0]  p_be;
  logic [31:0] p_d;
  assign merge   = p_v && g_v && g_w == p_w;
  assign m_v     = p_v && !merge;
  assign m_addr  = {1'b0, p_w[0], p_w[20:1], 2'b00};
  assign m_be    = p_be;
  assign m_wdata = p_d;
  assign g_rdy   = merge || !p_v || m_rdy;
  always_ff @(posedge clk) begin
    if (rst)
      p_v <= 1'b0;
    else if (merge) begin
      p_be <= p_be | g_be;
      for (int b = 0; b < 4; b++)
        if (g_be[b]) p_d[8 * b +: 8] <= g_d[8 * b +: 8];
    end else if (!p_v || m_rdy) begin
      p_v  <= g_v;
      p_w  <= g_w;
      p_be <= g_be;
      p_d  <= g_d;
    end
  end
endmodule

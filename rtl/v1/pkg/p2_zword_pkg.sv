// p2_zword_pkg: H14, every function that makes or reads a stored-depth key (p2_zkey_t), named after refsw3 (refcore
// pvr_isp_depth.h StoredDepth L110-279 and DepthTileT::RegDepth L700 at 708fb8cd, and the background block of
// refsw_lists.cpp RenderCORE L637-653); the one boundary the stored-depth format lives behind (ARCHITECTURE 2.1, 3.11
// H14; docs/spec/numerics.md H14 a-i).
//
// A stored depth is a 64-bit signed ORDER KEY (StoredDepth::k): the IEEE single word's order, 32 bits finer. Every depth
// compare of the ISP compares keys (isp 9.7). refsw3's 32-bit `bits` is for logs and probes only; the testbench turns a
// key back into it with tb/common/zkey.h. The key has four forms:
//   bits(w)                      key32(w) in the high half, 0 in the low one: a float word
//   between(w, off)              key32(w) in the high half, off (1 .. 2^32 - 1) in the low one: after w, before the next
//                                word of the ISP's order (a negative depth outside its block's top binade; Big)
//
// Every function is combinational and synthesizable (a few bit-length encoders, shifts and adds); the raster's lanes
// instance from_fp, big, neg and regdepth (p2_isp_raster, through p2_fp_depth_block), the setup flat and saturated, the
// pixel unit compares keys as signed 64-bit integers, the ISP controller bgkey. The names are short and common (neg, big,
// bits): call them package-qualified, p2_zword_pkg::neg(e, m), rather than through a wildcard import.
package p2_zword_pkg;
  import p2_pkg::*;

  // ---------------------------------------------------------------------------------------------------------------
  // helpers (not refsw3 names)
  // ---------------------------------------------------------------------------------------------------------------
  // the bit length of v, 0 for 0 (pvr_bits.h BitLength; the H1 rule as a function, for the narrow operands here)
  function automatic logic [5:0] zw_bl32(input logic [31:0] v);
    logic [5:0] n;
    n = '0;
    for (int k = 0; k < 32; k++)
      if (v[k]) n = 6'(k + 1);
    return n;
  endfunction

  // a sign and an exponent field above an empty fraction: the word sign | field << 23
  function automatic logic [31:0] zw_word(input logic s, input logic [7:0] field);
    return {s, field, 23'd0};
  endfunction

  // ---------------------------------------------------------------------------------------------------------------
  // a. key32, bits, between (StoredDepth::Key32 L116, Bits L122, Between L124; zsign, bgspec, bgneg, bgneg2)
  // ---------------------------------------------------------------------------------------------------------------
  // the word read as a signed 32-bit key, a negative word's fraction bits inverted, so that two negative depths order
  // by exponent first and within one exponent as the float (-2 > -1 > -1.5); 0x80000000 (-0) is 0, +0's key
  // (dreamcast-tests pvr-tests/zsign: every pair of 20 depths from -2^100 to 2^100, Greater and Less)
  function automatic logic signed [31:0] key32(input logic [31:0] w);
    if (w == 32'h8000_0000)
      return '0;
    return $signed(w ^ (w[31] ? 32'h007F_FFFF : 32'h0));
  endfunction

  // the key of the word w: key32(w) << 32
  function automatic p2_zkey_t bits(input logic [31:0] w);
    return {key32(w), 32'd0};
  endfunction

  // between the word w and the next one in the ISP's order, at off (1 .. 2^32 - 1): (key32(w) << 32) + off; the low
  // half is empty in key32(w) << 32, so the sum is a concatenation (no carry)
  function automatic p2_zkey_t between(input logic [31:0] w, input logic [31:0] off);
    return {key32(w), off};
  endfunction

  // ---------------------------------------------------------------------------------------------------------------
  // c. saturated (StoredDepth::Saturated L235): +-2^127, the depth of a polygon whose plane overflows; ties with a
  // background of +-2^127, above one of 1.5 2^126, below one of 1.5 2^127 (pvr-tests/bgbig, bgspec, zsign page 15)
  // ---------------------------------------------------------------------------------------------------------------
  function automatic p2_zkey_t saturated(input logic sign);
    return bits({sign, 31'h7F00_0000});
  endfunction

  // ---------------------------------------------------------------------------------------------------------------
  // b. from_fp (StoredDepth::FromFp L239): v as an IEEE single word: to nearest, ties to even, on the denormal grid
  // (2^-149) below 2^-126; saturated from 2^128 and for a bad v. v has at most 19 bits at every site (cut_19 of a
  // pixel's value, DepthHW::storedBits; a flat plane's start); the port takes 20 (p2_fp20_t, at most 20 bits are exact
  // here too). With at most 24 bits the 24-bit window above the leading one never cuts, so the rounding acts only below
  // 2^-125, on the denormal grid (GAP G6: the denormals' order among each other; depthgaps_edges: 2^-128, 2^-127 above
  // 0 and below 2^-126)
  // ---------------------------------------------------------------------------------------------------------------
  function automatic p2_zkey_t from_fp(input p2_fp20_t v);
    logic [5:0]         n2;             // the bit length after the rounding
    logic signed [11:0] e;              // the exponent of m's bit 0
    logic signed [11:0] d;              // the bits rounded away: -149 - exp
    logic signed [11:0] t2;             // top after the rounding
    logic [20:0]        m;              // the mantissa, one bit of carry room
    logic [20:0]        rest, half;
    logic [22:0]        mj;             // the 23 bits under m's leading one (m left-justified to 24 bits)
    logic [31:0]        w;
    if (v.bad)
      return saturated(v.neg);
    if (v.mant == '0)
      return '0;                        // bits(sign): +-0 have key 0
    e = 12'(v.exp);
    m = 21'(v.mant);
    if (e < -12'sd149) begin
      d = -12'sd149 - e;
      if (d > 12'sd21) begin
        m = '0;                         // far below half a step (refsw3: d > 63 or a rest under half): zero
      end else begin
        half = 21'd1 << (d - 12'sd1);
        rest = m & ((21'd1 << d) - 21'd1);
        m    = m >> d;
        if (rest > half || (rest == half && m[0]))
          m = m + 21'd1;
      end
      e = -12'sd149;
    end
    if (m == '0)
      return '0;
    n2 = zw_bl32(32'(m));
    t2 = e + 12'(n2);
    if (t2 > 12'sd128)
      return saturated(v.neg);
    if (t2 <= -12'sd126) begin
      // a denormal word: the mantissa at 2^-149 (e + 149 = 0 .. 22 here, the word below 2^23)
      w = {v.neg, 31'(32'(m) << (e + 12'sd149))};
      return bits(w);
    end
    mj = 23'(24'(m) << (6'd24 - n2));
    w  = {v.neg, 8'(t2 + 12'sd126), mj};
    return bits(w);
  endfunction

  // ---------------------------------------------------------------------------------------------------------------
  // d. big (StoredDepth::Big L224): a depth above zero of 2^128 or more (top(v) >= 129), at most 19 bits here (20 in
  // the port): above every float word, ordered as a float of its bits whose exponent field goes on past 254
  // (pvr-tests/depthgaps_bigpos, depthgaps_bigord; GAP G6: 19 bits fit, any cut of about 13 to 23 does).
  // between(0x7F800000, ((field - 255) << 23 | frac) + 1), field = top(v) + 126, frac the 23 bits under v's leading one.
  // field - 255 = top - 129 stays below 2^9 for every exponent the 10-bit field holds (top <= 531), so the offset fits
  // 32 bits and the +1 does not carry out of them.
  // ---------------------------------------------------------------------------------------------------------------
  function automatic p2_zkey_t big(input p2_fp20_t v);
    logic [5:0]         n;
    logic [8:0]         fm;             // field - 255 = top - 129 (0 .. 402)
    logic [22:0]        mj;             // frac
    logic [31:0]        off;
    n   = zw_bl32(32'(v.mant));
    mj  = 23'(24'(v.mant) << (6'd24 - n));
    fm  = 9'(12'(v.exp) + 12'(n) - 12'sd129);
    off = {fm, mj} + 32'd1;
    return between(32'h7F80_0000, off);
  endfunction

  // ---------------------------------------------------------------------------------------------------------------
  // e. neg (StoredDepth::Neg L160): a depth below zero of block exponent e (-122 .. 128) and value m 2^(e - 16), m < 0
  // (the value rounded down, its size up: the callers' job). The callers keep m at -2^30 or above: from m = -2^30 down
  // the key no longer moves (the offset below the window saturates at 2^31).
  //   -2^16 <= m <= -2^15   the window, the block's top binade: the float word of the value, 16 significant bits (a
  //                         multiple of 0x100 in the word); the window's bottom (2^e) the fraction 0x7FFFE0, no carry
  //                         into the exponent (pvr-tests/perpmean_bg, perpmean_neg, perpmean_negstore, depthgaps_neggrid)
  //   m > -2^15             above the window: after every word of field e + 126, at m + 2^15
  //   m < -2^16             below it: after every word of field e + 125, at 2^31 + (m + 2^30) (depthgaps_negladder,
  //                         depthgaps_search, depthgaps_negconv, depthgaps_ties, depthgaps_uwmat, depthgaps_final G)
  // ---------------------------------------------------------------------------------------------------------------
  function automatic p2_zkey_t neg(input logic signed [9:0] e, input logic signed [30:0] m);
    logic [7:0]         f1, f0;         // the exponent fields e + 126 and e + 125
    logic signed [30:0] mm;             // -m
    logic [31:0]        frac;
    f1 = 8'(e + 10'sd126);
    f0 = 8'(e + 10'sd125);
    mm = 31'sd0 - m;
    if (m >= -31'sd65536 && m <= -31'sd32768) begin
      frac = (m == -31'sd65536) ? 32'h007F_FFE0 : (32'(mm) - 32'd32768) << 8;
      return bits(zw_word(1'b1, f1) | frac);
    end
    if (m > -31'sd32768)
      return between(zw_word(1'b1, f1), 32'(m + 31'sd32768));
    // m >= -2^30 (the callers saturate it): m + 2^30 is 0 .. 2^30 - 2^16
    return between(zw_word(1'b1, f0), 32'h8000_0000 + 32'(32'(m) + 32'sd1073741824));
  endfunction

  // ---------------------------------------------------------------------------------------------------------------
  // f. flat (StoredDepth::Flat(v, startBits 20, storedBits 19) L180): a flat depth as the depth unit stores one (a plane
  // with no slopes, a determinant-zero mean: its block's exponent is v's own); pvr-tests/perpmean_*, depthgaps_detneg,
  // depthgaps_tinymean.
  //   bad: saturated(v.neg);  zero: key 0;  above zero: from_fp(cut_19(v))
  //   below zero: s = cut_20(v), E = clamp(top(s), -122, 128), neg(E, -ceil(|s| / 2^(E - 16))) (the size rounded up)
  // The magnitude saturates at 2^30, where neg's key stops moving (|s| / 2^(E - 16) reaches it only when E is clamped
  // at 128, top(s) >= 142: no ranged mean does).
  // ---------------------------------------------------------------------------------------------------------------
  function automatic p2_zkey_t flat(input p2_fp24_t v);
    logic [5:0]         n;
    logic [5:0]         drop;
    p2_fp20_t           c19;            // cut_19(v)
    logic [19:0]        sm;             // cut_20(v): mantissa
    logic signed [11:0] se;             // and exponent
    logic signed [11:0] ts, E;
    logic signed [11:0] sh;             // E - 16 - s.exp
    logic [5:0]         k;
    logic [50:0]        wide;
    logic [30:0]        mag;            // 1 .. 2^30
    logic signed [30:0] mneg;           // -mag
    if (v.bad)
      return saturated(v.neg);
    if (v.mant == '0)
      return '0;
    n = zw_bl32(32'(v.mant));
    if (!v.neg) begin
      drop      = (n > 6'd19) ? n - 6'd19 : '0;
      c19.neg   = 1'b0;
      c19.bad   = 1'b0;
      c19.exp   = 10'(12'(v.exp) + 12'(drop));
      c19.mant  = 20'(v.mant >> drop);
      return from_fp(c19);
    end
    drop = (n > 6'd20) ? n - 6'd20 : '0;
    sm   = 20'(v.mant >> drop);
    se   = 12'(v.exp) + 12'(drop);
    ts   = se + 12'(zw_bl32(32'(sm)));
    E    = (ts < -12'sd122) ? -12'sd122 : (ts > 12'sd128) ? 12'sd128 : ts;
    sh   = E - 12'sd16 - se;
    if (sh <= 12'sd0) begin
      // M = -(|s| 2^-sh): exact; saturated at 2^30
      if (sh < -12'sd30) begin
        mag = 31'h4000_0000;
      end else begin
        k    = 6'(12'sd0 - sh);
        wide = 51'(sm) << k;
        mag  = (wide >= 51'h4000_0000) ? 31'h4000_0000 : 31'(wide);
      end
    end else if (sh > 12'sd20) begin
      mag = 31'd1;                      // |s| < 2^20 <= 2^sh: rounded up to one step
    end else begin
      mag = 31'(20'(sm >> sh)) + 31'(((sm & ((20'd1 << sh) - 20'd1)) != '0) ? 1 : 0);
    end
    mneg = 31'(32'sd0 - $signed({1'b0, mag}));
    return neg(10'(E), mneg);
  endfunction

  // ---------------------------------------------------------------------------------------------------------------
  // g. regdepth (DepthTileT::RegDepth L700): the depth of an overflowing plane's register r, in units of 2^102, two's
  // complement with its sign at 2^131 (it wraps every 32 steps of 2^127, a step being 2^25 units): only r's low 30 bits
  // count, and the port takes 32 (the register's sum in any width of 30 bits or more; refsw3 wraps its 64-bit r here).
  // pvr-tests/zword (every whole step, background probes), depthgaps_mm (their order), nantr_fin, nantr_fin2,
  // nantr_wreg (between whole steps).
  //   0: key 0;  above zero below 2^128 (r < 2^26): r itself cut to 19 bits; from 2^128: big(cut_19(r 2^102))
  //   -2^131 (r = -2^29): the lowest word, 0x807FFFFF
  //   below zero otherwise: u = r + 2^29, 2^p its leading one: neg(p + 100, floor((u 2^(28 - p) - 2^29) / 2^10))
  // ---------------------------------------------------------------------------------------------------------------
  function automatic p2_zkey_t regdepth(input logic [31:0] r);
    logic signed [29:0] rw;             // the register, wrapped
    logic [28:0]        u;
    logic [5:0]         n;
    logic [5:0]         p;
    logic [17:0]        mr;             // positive r < 2^26: the 18 bits under its leading one (19 significant)
    p2_fp20_t           c19;
    logic signed [31:0] t;              // u 2^(28 - p) - 2^29: -2^28 .. -1
    rw = $signed(r[29:0]);
    if (rw == '0)
      return '0;
    if (!rw[29]) begin
      n = zw_bl32(32'(rw));
      if (rw >= 30'sd67108864) begin
        // r 2^102 from 2^128 on: cut to 19 bits (n is 27 .. 29), then above every word
        c19.neg  = 1'b0;
        c19.bad  = 1'b0;
        c19.exp  = 10'(10'sd102 + 10'(n) - 10'sd19);
        c19.mant = 20'(rw[28:0] >> (n - 6'd19));
        return big(c19);
      end
      p  = n - 6'd1;
      // the word (p + 229) << 23 | (r's 24 bits from its leading one & 0x7FFFE0): 19 significant bits
      mr = 18'(((p <= 6'd23) ? 29'(rw[28:0]) << (6'd23 - p) : 29'(rw[28:0]) >> (p - 6'd23)) >> 5);
      return bits({1'b0, 8'(8'(p) + 8'd229), mr, 5'd0});
    end
    u = rw[28:0];                       // r + 2^29 (r in -2^29 .. -1)
    if (u == '0)
      return bits(32'h807F_FFFF);
    n = zw_bl32(32'(u));
    p = n - 6'd1;
    t = $signed({3'b0, u} << (6'd28 - p)) - 32'sd536870912;
    return neg(10'(p) + 10'sd100, 31'(t >>> 10));
  endfunction

  // ---------------------------------------------------------------------------------------------------------------
  // h. bgkey: the background's key from ISP_BACKGND_D (refsw_lists.cpp RenderCORE, the bgZ block L637-653; bgdepth,
  // bgtie, bgspec, bgbig, bgneg, bgneg2, depthgaps_bglow, _bglow2, _bglow3, depthgaps_bgpin, depthgaps_ties)
  //   above zero (bit 31 clear): the word with the fraction bits under 2^-20 (130 - field) cut, at least the low 5;
  //                              nothing left below 2^-20 (field 107); field 255 is 254, the fraction kept
  //   below zero: as the depth unit stores a flat plane of that depth whose block exponent is at least 6:
  //                              E = max(field - 126, 6) (field 255 as 254), its 20 bits on the grid 2^(E - 26) toward
  //                              zero, then M = that over 2^(E - 16) rounded down (the size up): neg(E, M); 0 when
  //                              nothing is left on the grid (below 2^-20)
  // ---------------------------------------------------------------------------------------------------------------
  function automatic p2_zkey_t bgkey(input logic [31:0] bg);
    logic [7:0]         field;
    logic [7:0]         f;
    logic signed [9:0]  E;
    logic [19:0]        m20;            // the depth is m20 2^(f - 146)
    logic signed [9:0]  sh;             // f - 120 - E: in units of 2^(E - 26)
    logic [26:0]        t;
    logic [16:0]        q;              // (t + 1023) >> 10
    logic [7:0]         cut;
    logic [31:0]        w;
    field = bg[30:23];
    if (bg[31]) begin
      f   = (field == 8'd255) ? 8'd254 : field;
      E   = (f >= 8'd132) ? 10'(f) - 10'sd126 : 10'sd6;
      m20 = {1'b1, bg[22:4]};
      sh  = 10'(f) - 10'sd120 - E;
      if (f < 8'd107)
        t = '0;
      else if (sh >= 10'sd0)
        t = 27'(m20) << sh;
      else
        t = 27'(m20) >> (10'sd0 - sh);
      if (t == '0)
        return '0;
      q = 17'((28'(t) + 28'd1023) >> 10);
      return neg(E, 31'sd0 - 31'(q));
    end
    cut = (field >= 8'd125) ? 8'd5 : 8'd130 - field;
    w   = (cut > 8'd23) ? 32'd0 : bg & ~((32'd1 << cut) - 32'd1);
    if (field == 8'd255)
      w = w - 32'h0080_0000;
    return bits(w);
  endfunction

endpackage

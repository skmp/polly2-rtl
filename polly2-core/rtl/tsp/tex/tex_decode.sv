//
// tex_decode - decode one texel from a 64-bit memory word to a single 32-bit value,
// per refsw DecodeTextel. 2-cycle pipeline; the palette RAM is INJECTED (addr out /
// data in), 1-cycle M10K read.
//
//   template<PixelFmt> u32 DecodeTextel(PalSelect, u64 memtel, u32 offset):
//     1555/565/4444/BumpMap/Reserved : return memtel_16[offset & 3]   (RAW 16-bit)
//     YUV422                         : y = memtel8[2*(offset&3)+1] (own lane, both
//                                      layouts); chroma depends on layout:
//                                        twiddled: u=memtel8[2*(offset&1)]
//                                                  v=memtel8[2*(offset&1)+4]
//                                        planar:   u=memtel8[2*(offset&2)]
//                                                  v=memtel8[2*(offset&2)+2]
//                                      (twiddled 64b word = 2x2 quad, per-16b-texel
//                                       twiddle: [U|Y00][U'|Y01][V|Y10][V'|Y11];
//                                       planar = raster UYVY pairs)
//     Pal4  : local = (memtel >> (offset&15)*4) & 15 ; idx = PalSelect*16 | local
//     Pal8  : local = memtel_8[offset&7]            ; idx = (PalSelect/16)*256 | local
//   PixelFmt: 0=1555 1=565 2=4444 3=YUV 4=Bump 5=Pal4 6=Pal8 7=Reserved
//   PalSelect: 6 bits.  offset: 4 bits.
//
// PIPELINE (3 cycles). The YUV422 conversion is split so no stage carries both the muls
// AND the clamp/select: C2 does the muls + the G-channel two-product sum; C3 clamps,
// packs and selects. (C2's yu*11+yv*22 -> /32 -> subtract -> clamp -> select was the
// ~limiter as one cycle; the clamp/select moves to C3.)
//   C1 (comb off inputs)  : 16b lane mux ; YUV byte selects + yu/yv = (u/v)-128 ;
//                           palette index -> pal_addr  -> [REG]
//   [REG] drives pal_addr; the external M10K reads it -> pal_data lands at C2 (1cyc).
//   C2 (comb off C1 regs) : YUV muls / adds / divides -> pre-clamp yR/yG/yB ; carry
//                           pal_data/w16/pixfmt -> [REG]
//   C3 (comb off C2 regs) : clamp + pack + format select -> [REG] argb
//
// Latency = 3. in_valid -> out_valid. No stall: this unit sits on the BACK half of the
// pipeline (fetch output -> decode -> filter), which drains unconditionally on valid -
// a stall upstream appears here only as a bubble (in_valid=0), never a freeze. The
// injected palette must be a 1-cycle registered read off pal_addr so pal_data aligns to C2.
//
module tex_decode (
    input             clk,
    input             reset,
    input             in_valid,
    input      [2:0]  pixfmt,       // TCW.PixelFmt (0..7)
    input      [1:0]  pal_fmt,      // palette-entry format: 0=1555 1=565 2=4444 3=8888
    input             scan_order,   // ExpandToARGB8888 pad: 1=zero-pad, 0=MSB-repeat
    input             twiddled,     // vq | ~scan_e (tex_base_addr): YUV chroma-lane layout
    input      [5:0]  palsel,       // TCW.PalSelect
    input      [63:0] memtel,       // 64-bit memory word covering this texel
    input      [3:0]  offset,       // texel offset (sub-word / nibble / byte select)

    // injected palette RAM: pal_addr driven COMBINATIONALLY from C1 so the
    // external M10K's own address register IS the C1->C2 stage; pal_data is
    // then THIS pixel's entry during C2 and s2_pal captures it aligned. (It
    // was registered here first, making pal_data land one pixel LATE - every
    // paletted pixel got its predecessor's entry: invisible on smooth
    // palettes, but tile-column lines at stall boundaries, recv_logos.)
    output     [9:0]  pal_addr,
    input      [31:0] pal_data,

    output            out_valid,
    output     [31:0] argb
);
    // ============================================================================
    // C1 combinational (off module inputs): cheap selects/subs + palette index.
    // ============================================================================
    // raw 16bpp lane (offset & 3)
    wire [1:0]  l16 = offset[1:0];
    wire [15:0] w16_c = (l16==2'd0) ? memtel[15:0]
                      : (l16==2'd1) ? memtel[31:16]
                      : (l16==2'd2) ? memtel[47:32]
                                    : memtel[63:48];

    // palette index (Pal4/Pal8). idx = 10 bits.
    wire [5:0]  nib_sel = {offset[3:0], 2'd0};        // (offset&15)*4, 0..60
    wire [3:0]  pal4_local = memtel[ nib_sel +: 4 ];
    wire [7:0]  pal8_local = memtel[ {offset[2:0], 3'd0} +: 8 ];
    wire [9:0]  idx4 = { palsel[5:0], pal4_local };   // PalSelect*16 | local
    wire [9:0]  idx8 = { palsel[5:4], pal8_local };   // (PalSelect/16)*256 | local
    wire [9:0]  pal_addr_c = (pixfmt==3'd5) ? idx4 : idx8;

    // YUV byte selects + yu/yv + the CONSTANT MULTIPLIES. yu/yv are cheap subtracts and
    // the *11/*22/*110 are shift-and-add trees (constant, no real multiplier) - done in
    // C1 (off the early yu/yv) and registered, so C2 only does the adds/divides. This
    // splits the G channel's yu*11+yv*22 (two muls in C1, the sum in C2).
    // multstyle="logic" forces the products into fabric (NO DSP blocks).
    // Y is the texel's own 16-bit lane high byte in both layouts (= w16_c). Chroma:
    // twiddled quad [U|Y00][U'|Y01][V|Y10][V'|Y11] -> offset[0] (y parity) picks the
    // row's U/V lanes; planar raster UYVY -> offset[1] picks which 32-bit pair.
    wire [7:0]  yv_y_c  = w16_c[15:8];
    wire [7:0]  yuv_u8 = twiddled ? (offset[0] ? memtel[23:16] : memtel[7:0])
                                  : (offset[1] ? memtel[39:32] : memtel[7:0]);
    wire [7:0]  yuv_v8 = twiddled ? (offset[0] ? memtel[55:48] : memtel[39:32])
                                  : (offset[1] ? memtel[55:48] : memtel[23:16]);
    wire signed [9:0] yu_c = $signed({2'b0, yuv_u8}) - 10'sd128;   // u-128
    wire signed [9:0] yv_c = $signed({2'b0, yuv_v8}) - 10'sd128;   // v-128
    (* multstyle = "logic" *) wire signed [17:0] m_yu11_c  = yu_c * 18'sd11;
    (* multstyle = "logic" *) wire signed [17:0] m_yv11_c  = yv_c * 18'sd11;
    (* multstyle = "logic" *) wire signed [17:0] m_yv22_c  = yv_c * 18'sd22;
    (* multstyle = "logic" *) wire signed [17:0] m_yu110_c = yu_c * 18'sd110;

    // ============================================================================
    // C1 -> C2 REGISTER (also drives pal_addr for the 1-cycle palette read).
    // ============================================================================
    reg               v1;
    reg [2:0]         s1_pixfmt;
    reg [1:0]         s1_palfmt;
    reg               s1_scan;
    reg [15:0]        s1_w16;
    reg [7:0]         s1_y;
    reg signed [17:0] s1_yu11, s1_yv11, s1_yv22, s1_yu110;   // registered products
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else begin
            v1        <= in_valid;
            s1_pixfmt <= pixfmt;
            s1_palfmt <= pal_fmt; s1_scan <= scan_order;
            s1_w16    <= w16_c;
            s1_y      <= yv_y_c;
            s1_yu11   <= m_yu11_c;  s1_yv11 <= m_yv11_c;
            s1_yv22   <= m_yv22_c;  s1_yu110<= m_yu110_c;
        end
    end
    // combinational: the external palette M10K registers this address, so its
    // registered read output lands during C2, pixel-aligned with the s1_* regs
    assign pal_addr = pal_addr_c;

    // ============================================================================
    // C2 combinational (off C1 regs): YUV adds/divides -> pre-clamp yR/yG/yB (products
    // came from C1). refsw YUV422: R=Y+Yv*11/8 ; G=Y-(Yu*11+Yv*22)/32 ; B=Y+Yu*110/64.
    // pal_data landed this cycle -> carry to C3.
    // ============================================================================
    // NOTE: keep `/` (truncate toward zero), NOT >>> (floors) - they differ for negative
    // values and the reference uses C division. `/const-pow2` synthesizes as a cheap
    // shift + sign correction (no DSP).
    wire signed [17:0] g_sum = s1_yu11 + s1_yv22;
    wire signed [15:0] yR_c = $signed({8'b0, s1_y}) + 16'(s1_yv11 / 18'sd8);
    wire signed [15:0] yG_c = $signed({8'b0, s1_y}) - 16'(g_sum   / 18'sd32);
    wire signed [15:0] yB_c = $signed({8'b0, s1_y}) + 16'(s1_yu110 / 18'sd64);

    reg               v2;
    reg [2:0]         s2_pixfmt;
    reg [1:0]         s2_palfmt;
    reg               s2_scan;
    reg [15:0]        s2_w16;
    reg [31:0]        s2_pal;                 // pal_data carried (landed at C2)
    reg signed [15:0] s2_yR, s2_yG, s2_yB;    // pre-clamp YUV->RGB
    always @(posedge clk) begin
        if (reset) v2 <= 1'b0;
        else begin
            v2        <= v1;
            s2_pixfmt <= s1_pixfmt;
            s2_palfmt <= s1_palfmt; s2_scan <= s1_scan;
            s2_w16    <= s1_w16;
            s2_pal    <= pal_data;
            s2_yR <= yR_c; s2_yG <= yG_c; s2_yB <= yB_c;
        end
    end

    // ============================================================================
    // C3 combinational (off C2 regs): YUV clamp/pack ; 16b->ARGB8888 expand ; select.
    // ============================================================================
    function [7:0] clamp8(input signed [15:0] v);
        clamp8 = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0]; endfunction

    // ---- shared 16b -> ARGB8888 expander. `fmt`: 0=1555 1=565 2=4444 3=8888(passthru16).
    //      scan=1 -> zero-pad the low bits ; scan=0 -> MSB-repeat (full-scale -> 0xFF). ----
    //   channel expand helpers: take the field's high bits, fill low bits per scan.
    function [7:0] ex5(input [4:0] c, input scan);   // 5-bit -> 8-bit
        ex5 = scan ? {c, 3'b0} : {c, c[4:2]}; endfunction
    function [7:0] ex6(input [5:0] c, input scan);   // 6-bit -> 8-bit
        ex6 = scan ? {c, 2'b0} : {c, c[5:4]}; endfunction
    function [7:0] ex4(input [3:0] c, input scan);   // 4-bit -> 8-bit
        ex4 = scan ? {c, 4'b0} : {c, c}; endfunction

    function [31:0] expand16(input [15:0] w, input [1:0] fmt, input scan);
        begin
            case (fmt)
              2'd0: expand16 = { (w[15] ? 8'hFF : 8'h00),     // 1555 A
                                 ex5(w[14:10], scan),          // R
                                 ex5(w[9:5],   scan),          // G
                                 ex5(w[4:0],   scan) };        // B
              2'd1: expand16 = { 8'hFF,                        // 565 (no A)
                                 ex5(w[15:11], scan),          // R
                                 ex6(w[10:5],  scan),          // G
                                 ex5(w[4:0],   scan) };        // B
              2'd2: expand16 = { ex4(w[15:12], scan),          // 4444 A
                                 ex4(w[11:8],  scan),          // R
                                 ex4(w[7:4],   scan),          // G
                                 ex4(w[3:0],   scan) };        // B
              default: expand16 = {16'd0, w};                  // 3=8888 low16 passthrough
            endcase
        end
    endfunction

    wire [31:0] argb_yuv    = {8'hFF, clamp8(s2_yR), clamp8(s2_yG), clamp8(s2_yB)};
    wire [31:0] argb_direct = expand16(s2_w16,       s2_pixfmt[1:0], s2_scan);
    // pal_fmt 3 = ARGB8888 palette: the 32-bit entry IS the texel (no expand)
    wire [31:0] argb_pal    = (s2_palfmt == 2'd3) ? s2_pal
                            : expand16(s2_pal[15:0], s2_palfmt, s2_scan);

    // select: 3=YUV ; 4=Bump/7=Reserved -> raw passthrough {0,w16} ; 5/6=palette (pal_fmt
    // expand) ; 0/1/2=direct 16b expand (pixfmt).
    wire [31:0] argb_sel =
          (s2_pixfmt==3'd3)                    ? argb_yuv
        : (s2_pixfmt==3'd4 || s2_pixfmt==3'd7) ? {16'd0, s2_w16}   // bump/reserved: passthru
        : (s2_pixfmt==3'd5 || s2_pixfmt==3'd6) ? argb_pal
                                               : argb_direct;

    reg        v3;
    reg [31:0] r_argb;
    always @(posedge clk) begin
        if (reset) v3 <= 1'b0;
        else begin
            v3     <= v2;
            r_argb <= argb_sel;
        end
    end
    assign out_valid = v3;
    assign argb      = r_argb;
endmodule

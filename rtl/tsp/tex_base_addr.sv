//
// tex_base_addr - per-pixel SHARED texture addressing front-end (part 1 of 3).
//
// Computes everything that depends ONLY on the texture config (decoded TCW/TSP fields),
// NOT on the bilinear corner (u,v) - so it runs ONCE per pixel. Feeds:
//   tex_addroffsgen_ib : u_log2/v_log2/stride/twiddled  (4 corner texel offsets)
//   the glue           : mip_add/fbpp_shr               (offset -> byte offset)
//   tex_fetch4_ob      : tex_addr/vq_addr               (word bases)
//   tex_decode         : pixfmt/pal_fmt/scan            (format decode)
//
// NOTE on mip: the mip base offset (mip_add, in TEXELS) is emitted for the glue to add to
// each corner's texel offset BEFORE the fbpp byte-scale. It CANNOT be folded into the word
// base, because ((corner+mip)<<1)>>fbpp_shr != ((corner<<1)>>shr)+((mip<<1)>>shr) when the
// shift drops carry bits (verified). So tex_addr is a PURE base; mip stays in texel space.
//
// Inputs are DECODED NAMED PARAMS (no raw tcw/tsp bit-slicing here).
//
// COMBINATIONAL (no registers): the wrapping unit owns the register that captures these
// shared values before they fan out.
//
module tex_base_addr (
    input  [20:0] tex_addr_in,  // TCW.TexAddr (64-bit-word base)
    input         vq,           // TCW.VQ_Comp
    input         scan,         // TCW.ScanOrder
    input         stride_sel,   // TCW.StrideSel
    input         mipmapped,    // TCW.MipMapped
    input  [2:0]  pixfmt,       // TCW.PixelFmt (0..7)
    input  [1:0]  pal_fmt,      // palette-entry format (forwarded to tex_decode)
    input  [5:0]  palsel,       // TCW.PalSelect (forwarded to tex_fetch/decode)
    input  [2:0]  texu,         // TSP.TexU
    input  [2:0]  texv,         // TSP.TexV
    input  [3:0]  miplevel,     // selected mip level (0 = base)
    input  [4:0]  text_ctrl,    // TEXT_CONTROL&31 (stride unit)

    // ---- to tex_addroffsgen_ib (twiddle sizes as EXPONENTS + stride) ----
    output [3:0]  u_log2,       // log2(U size) = clamp(3+TexU-Mip, 0..10)
    output [3:0]  v_log2,       // log2(V size) = clamp(3+TexV-Mip[or square], 0..10)
    output [10:0] stride,       // linear stride (row pitch), 1..1024
    output        twiddled,     // 1 = Morton path, 0 = linear

    // ---- to the glue (offset -> byte offset scaling) ----
    output [23:0] mip_add,      // mip base offset in TEXELS (0 if !mipmapped); added to the
                                //   corner texel offset BEFORE the fbpp byte-scale
    output [2:0]  fbpp_shr,     // byte scale: byte_off = (texel_off<<1) >> fbpp_shr

    // ---- to tex_fetch4_ob (word bases) ----
    output [20:0] tex_addr,     // data/index region word base (= TexAddr, +256 words if VQ)
    output [20:0] vq_addr,      // VQ codebook word base (= TexAddr)

    // ---- to tex_decode (format config) ----
    output        o_scan,       // raw TCW.ScanOrder
    output        o_vq,
    output [2:0]  o_pixfmt,
    output [1:0]  o_pal_fmt,
    output [5:0]  o_palsel
);
    wire is_pal   = (pixfmt==3'd5) || (pixfmt==3'd6);
    wire scan_e   = scan       & ~is_pal;
    wire strd_e   = stride_sel & ~is_pal;

    // fbpp byte scale (refsw): byte_off = off*fbpp/16 == (off<<1) >> fbpp_shr.
    wire [2:0] log2rv = (pixfmt==3'd6) ? 3'd3 : (pixfmt==3'd5) ? 3'd2 : 3'd4;
    assign fbpp_shr = vq ? (3'd7 - log2rv) : (3'd4 - log2rv);

    // ---- twiddle sizes as log2 exponents (0..10) ----
    // size = (8<<Tex) >> mip -> log2 = 3 + Tex - mip, clamped to [0,10]. When mipmapped,
    // both dims use the square (TexU) size. Signed intermediate to clamp the low end.
    function [3:0] size_log2(input [2:0] tex, input [3:0] mip);
        reg signed [5:0] e;
        begin
            e = $signed({3'b0, tex}) + 6'sd3 - $signed({2'b0, mip});
            size_log2 = (e < 0) ? 4'd0 : (e > 10) ? 4'd10 : e[3:0];
        end
    endfunction
    assign u_log2 = size_log2(texu, miplevel);
    assign v_log2 = size_log2(mipmapped ? texu : texv, miplevel);

    // ---- stride (linear path row pitch) ----
    wire [12:0] size_mip = (13'd8 << texu) >> miplevel;   // (8<<TexU)>>mip
    wire [12:0] stride13 = (strd_e && scan_e) ? ({8'd0, text_ctrl} << 5) : size_mip;
    assign stride = stride13[10:0];

    // ---- mip base offset in TEXELS (refsw TexOffsetGen: MipPoint[3+TexU-Mip]) ----
    wire [3:0] mip_idx = 4'(3) + {1'b0,texu} - miplevel;   // 0..10
    reg [19:0] mip_off;
    always @(*) begin
        case (mip_idx)
            4'd0:  mip_off = 20'h00003;  4'd1:  mip_off = 20'h00004;
            4'd2:  mip_off = 20'h00008;  4'd3:  mip_off = 20'h00018;
            4'd4:  mip_off = 20'h00058;  4'd5:  mip_off = 20'h00158;
            4'd6:  mip_off = 20'h00558;  4'd7:  mip_off = 20'h01558;
            4'd8:  mip_off = 20'h05558;  4'd9:  mip_off = 20'h15558;
            default: mip_off = 20'h55558;
        endcase
    end
    assign mip_add  = mipmapped ? {4'd0, mip_off} : 24'd0;

    assign twiddled = vq | ~scan_e;

    // ---- word bases (PURE; no mip fold - see the NOTE above) ----
    // VQ data/index region is +2048 bytes = +256 64-bit words.
    assign tex_addr = tex_addr_in + (vq ? 21'd256 : 21'd0);
    assign vq_addr  = tex_addr_in;

    // ---- decode config forwarded downstream ----
    assign o_scan   = scan;
    assign o_vq     = vq;
    assign o_pixfmt = pixfmt;
    assign o_pal_fmt= pal_fmt;
    assign o_palsel = palsel;
endmodule

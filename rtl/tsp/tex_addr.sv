//
// tex_addr - texture texel address generation. Supports mip level selection
// (miplevel input; 0 = base level, matching the old behaviour). Computes the
// byte address in DDR3 for texel (u,v), per refsw TexAddressGen + TexOffsetGen +
// TexStride + fBitsPerPixel, with MipLevel folded in:
//   mip_offset = MipPoint[3 + TexU - MipLevel]   (refsw TexOffsetGen)
//   size       = (8 << TexU) >> MipLevel          (twiddle + stride)
//
//   base = TexAddr<<3  (+ 256*4*2 when VQ)
//   twiddled (VQ or !ScanOrder): offset = twop(u,v,TexU,TexV) = bit-interleave
//   linear:                      offset = u + stride*v
//   stride = (StrideSel&&ScanOrder) ? (TEXT_CONTROL&31)*32 : (8<<TexU)
//   fbpp   = 16 (16bpp) / 8 (pal8) / 4 (pal4); VQ: 8*2/(64/rv)
//   byte address of the 64-bit word = base + offset*fbpp/16   (units per refsw)
//
// twop(x,y): interleave y,x bits (Morton), y first, running until both size
// counters (halved each step) reach 0 - handles non-square by stopping the
// exhausted dimension. Computed combinationally (no LUT).
//
module tex_addr (
    input  [20:0] tcw_addr,     // TCW.TexAddr
    input         vq,           // TCW.VQ_Comp
    input         scan,         // TCW.ScanOrder
    input         stride_sel,   // TCW.StrideSel
    input         mipmapped,    // TCW.MipMapped
    input  [2:0]  pixfmt,       // TCW.PixelFmt
    input  [2:0]  texu,         // TSP.TexU
    input  [2:0]  texv,         // TSP.TexV
    input  [3:0]  miplevel,     // selected mip level (0 = base; 0..TexU+3)
    input  [4:0]  text_ctrl,    // TEXT_CONTROL&31 (stride unit)
    input  [10:0] u,            // texel u (0..1023)
    input  [10:0] v,            // texel v

    output [28:0] byte_addr,    // DDR3 byte address of the covering 64-bit word
    output [2:0]  fbpp_shr,     // byte-offset RIGHT-shift of (off<<1); see below
    output [19:0] offset        // linear texel offset (for sub-word lane select)
);
    // pal formats force ScanOrder/StrideSel to 0 (refsw)
    wire is_pal   = (pixfmt==3'd5) || (pixfmt==3'd6);
    wire scan_e   = scan       & ~is_pal;
    wire strd_e   = stride_sel & ~is_pal;

    // Byte-offset scale as an UNSIGNED SHIFT AMOUNT instead of a bits-per-pixel value.
    // refsw's byte offset is off*fbpp/16 with fbpp = (vq ? rv/4 : rv*2), rv in
    // {4,8,16} - always a power of two, so off*fbpp/16 == off << (log2(fbpp) - 4).
    // That exponent ranges -4..+1; to keep it a NON-NEGATIVE (sign-free) shift we
    // pre-scale off by 2 and always shift RIGHT: off*fbpp/16 == (off<<1) >> fbpp_shr,
    // with fbpp_shr = 5 - log2(fbpp), which is 0..5 for every format:
    //   pixfmt: 16bpp rv=16, pal8 rv=8, pal4 rv=4;  log2(rv) = 4/3/2.
    //   non-VQ: log2(fbpp)=log2(rv)+1 -> fbpp_shr = 4-log2(rv) -> {16bpp:0, pal8:1, pal4:2}
    //   VQ    : log2(fbpp)=log2(rv)-2 -> fbpp_shr = 7-log2(rv) -> {16bpp:3, pal8:4, pal4:5}
    wire [2:0] log2rv = (pixfmt==3'd6) ? 3'd3 : (pixfmt==3'd5) ? 3'd2 : 3'd4;
    assign fbpp_shr = vq ? (3'd7 - log2rv) : (3'd4 - log2rv);

    // mip-adjusted texture size: (8<<TexU) >> MipLevel (refsw TexStride/sizeU).
    wire [12:0] size_mip = (13'd8 << texu) >> miplevel;

    // stride
    wire [12:0] stride = (strd_e && scan_e) ? ({8'd0, text_ctrl} << 5)   // *32
                                            : size_mip;

    // ---- twiddle (bit interleave) ----
    // twop: for i-th step take y bit then x bit while that dim's size>1.
    // size_x = 8<<texu, size_y = 8<<texv. We interleave up to 11 bits each.
    // Twiddle sizes. refsw's mipmapped path twiddles with (TexU-MipLevel) for BOTH
    // dims (square mip levels): twop(u,v,TexU-Mip,TexU-Mip). The non-mip path keeps
    // the rectangular (TexU,TexV) sizes. mip_sx/mip_sy pick per mipmapped.
    reg  [21:0] tw;
    integer bx, by, sh;
    reg [10:0] xr, yr;
    integer sx, sy;
    integer sx0, sy0;
    always @(*) begin
        tw = 0; sh = 0;
        xr = u; yr = v;
        // mipmapped: square (8<<TexU)>>Mip on both dims; else (8<<TexU),(8<<TexV)
        sx0 = mipmapped ? ((8 << texu) >> miplevel) : (8 << texu);
        sy0 = mipmapped ? ((8 << texu) >> miplevel) : (8 << texv);
        sx = sx0 >> 1;    // x_sz>>=1
        sy = sy0 >> 1;    // y_sz>>=1
        // up to 11 interleave iterations (max 1024)
        for (integer it = 0; it < 11; it = it + 1) begin
            if (sy != 0) begin
                tw[sh] = yr[0]; yr = yr >> 1; sy = sy >> 1; sh = sh + 1;
            end
            if (sx != 0) begin
                tw[sh] = xr[0]; xr = xr >> 1; sx = sx >> 1; sh = sh + 1;
            end
        end
    end

    // mip offset (refsw TexOffsetGen): mip_offset = MipPoint[3 + TexU - MipLevel]
    // (texels to skip the coarser mip levels). MipPoint[0..10] from refsw_tile.cpp:
    //   [0]=0x3 [1]=0x4 [2]=0x8 [3]=0x18 [4]=0x58 [5]=0x158 [6]=0x558
    //   [7]=0x1558 [8]=0x5558 [9]=0x15558 [10]=0x55558
    wire [3:0] mip_idx = 4'(3) + {1'b0,texu} - miplevel;   // 0..10
    reg [19:0] mip_off;
    always @(*) begin
        case (mip_idx)
            4'd0:  mip_off = 20'h00003;   // MipPoint[0]
            4'd1:  mip_off = 20'h00004;   // MipPoint[1]
            4'd2:  mip_off = 20'h00008;   // MipPoint[2]
            4'd3:  mip_off = 20'h00018;   // MipPoint[3]
            4'd4:  mip_off = 20'h00058;   // MipPoint[4]
            4'd5:  mip_off = 20'h00158;   // MipPoint[5]
            4'd6:  mip_off = 20'h00558;   // MipPoint[6]
            4'd7:  mip_off = 20'h01558;   // MipPoint[7]
            4'd8:  mip_off = 20'h05558;   // MipPoint[8]
            4'd9:  mip_off = 20'h15558;   // MipPoint[9]
            default: mip_off = 20'h55558; // MipPoint[10]
        endcase
    end
    wire [23:0] mip_add = mipmapped ? {4'd0, mip_off} : 24'd0;

    wire        twiddled = vq | ~scan_e;
    wire [19:0] lin_off  = u + stride * v;
    // FULL-WIDTH texel offset (24b): twiddle/linear + mip base. For tu7 mipmapped
    // the mip base (0x55558) + twiddle can exceed 20 bits, so byte_addr must use
    // this full value (the 20-bit `offset` port only feeds low-bit lane select).
    wire [23:0] off_full = {4'd0, (twiddled ? tw[19:0] : lin_off)} + mip_add;
    assign offset = off_full[19:0];

    // base address (bytes)
    wire [28:0] base = ({8'd0, tcw_addr} << 3) + (vq ? 29'd2048 : 29'd0); // 256*4*2

    // Full (UNMASKED) byte address = base + (offset*fbpp/16), matching refsw's
    // emu_vram index. fbpp is a power of two, so this is a pure shift; encoded
    // sign-free as (off<<1) >> fbpp_shr (see fbpp_shr above). Consumers derive the
    // 64-bit word (byte_addr>>3) and the byte-within-word (byte_addr[2:0]) - the
    // latter is needed to pick the VQ index byte / sub-word lane, so it must NOT be
    // masked away here.
    wire [40:0] byte_off = ({17'd0, off_full} << 1) >> fbpp_shr;
    assign byte_addr = base + byte_off[28:0];
endmodule

//
// tex_addr_pp - PIPELINED variant of tex_addr (texture texel address generation).
//
// Same math as tex_addr (see that file for the refsw derivation): mip size/offset,
// stride, Morton twiddle, byte-address scale. The combinational tex_addr is a huge
// cone (11-iter twiddle interleave + a 13x11 stride multiply + a 41-bit variable
// byte-shift + a 29-bit add) that made tex_unit close at ~25 MHz. This splits it so
// it clocks past 120 MHz. The combinational tex_addr stays for other users; this one
// is for the streamed tex_unit fetch path.
//
// CONVENTION: this module does NOT register its inputs or its output. It has 2 internal
// registers; the first computation reads module inputs combinationally and the final
// byte-shift/add is combinational, driving byte_addr/offset/fbpp_shr directly. The
// WRAPPING module registers the inputs and the outputs. Effective latency = 2 internal
// registers + the wrapper's output register.
//
//   A1 [REG] : size_mip, stride, fbpp_shr, mip_off ; stride*v (13x11 mul) -> lin_off ;
//              twiddle operands (u,v, square/rect sizes) ; base ; mip_add ; flags
//   A2 [REG] : 11-iteration Morton twiddle -> tw ; off_full = (twiddle?tw:lin)+mip base
//   A3 (comb): byte_off = (off_full<<1)>>fbpp_shr ; byte_addr = base + byte_off ; offset
//
// HOLD (backpressure): the fetch path can stall on a cache miss-fill, so this takes a
// `stall` input (fp_rcp_fast convention): stall=1 freezes both internal registers.
// in_valid -> out_valid.
//
module tex_addr_pp (
    input             clk,
    input             reset,
    input             stall,
    input             in_valid,
    input  [20:0] tcw_addr,
    input         vq,
    input         scan,
    input         stride_sel,
    input         mipmapped,
    input  [2:0]  pixfmt,
    input  [2:0]  texu,
    input  [2:0]  texv,
    input  [3:0]  miplevel,
    input  [4:0]  text_ctrl,
    input  [10:0] u,
    input  [10:0] v,

    output            out_valid,
    output [28:0] byte_addr,
    output [2:0]  fbpp_shr,
    output [19:0] offset
);
    // ---- combinational off inputs (A1 front) ----
    wire is_pal   = (pixfmt==3'd5) || (pixfmt==3'd6);
    wire scan_e   = scan       & ~is_pal;
    wire strd_e   = stride_sel & ~is_pal;

    wire [2:0] log2rv = (pixfmt==3'd6) ? 3'd3 : (pixfmt==3'd5) ? 3'd2 : 3'd4;
    wire [2:0] fbpp_shr_c = vq ? (3'd7 - log2rv) : (3'd4 - log2rv);

    wire [12:0] size_mip = (13'd8 << texu) >> miplevel;
    wire [12:0] stride   = (strd_e && scan_e) ? ({8'd0, text_ctrl} << 5) : size_mip;
    wire [19:0] lin_off_c = u + stride * v;             // the 13x11 multiply

    wire [3:0] mip_idx = 4'(3) + {1'b0,texu} - miplevel;   // 0..10
    reg [19:0] mip_off_c;
    always @(*) begin
        case (mip_idx)
            4'd0:  mip_off_c = 20'h00003;  4'd1:  mip_off_c = 20'h00004;
            4'd2:  mip_off_c = 20'h00008;  4'd3:  mip_off_c = 20'h00018;
            4'd4:  mip_off_c = 20'h00058;  4'd5:  mip_off_c = 20'h00158;
            4'd6:  mip_off_c = 20'h00558;  4'd7:  mip_off_c = 20'h01558;
            4'd8:  mip_off_c = 20'h05558;  4'd9:  mip_off_c = 20'h15558;
            default: mip_off_c = 20'h55558;
        endcase
    end
    wire [23:0] mip_add_c  = mipmapped ? {4'd0, mip_off_c} : 24'd0;
    wire        twiddled_c = vq | ~scan_e;
    wire [28:0] base_c     = ({8'd0, tcw_addr} << 3) + (vq ? 29'd2048 : 29'd0);
    // square (mipmapped) vs rectangular twiddle sizes
    wire [11:0] sx0_c = mipmapped ? ((12'd8 << texu) >> miplevel) : (12'd8 << texu);
    wire [11:0] sy0_c = mipmapped ? ((12'd8 << texu) >> miplevel) : (12'd8 << texv);

    // ================= A1 REGISTER ================================================
    reg               v1;
    reg        [19:0] a1_lin, a1_mipoff;    // lin_off ; mip_add (as 20b, hi 4 are 0)
    reg               a1_mipmapped, a1_twiddled;
    reg        [10:0] a1_u, a1_v;
    reg        [11:0] a1_sx0, a1_sy0;
    reg        [28:0] a1_base;
    reg        [2:0]  a1_fbpp_shr;
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else if (!stall) begin
            v1           <= in_valid;
            a1_lin       <= lin_off_c;
            a1_mipoff    <= mip_off_c;
            a1_mipmapped <= mipmapped;
            a1_twiddled  <= twiddled_c;
            a1_u         <= u; a1_v <= v;
            a1_sx0       <= sx0_c; a1_sy0 <= sy0_c;
            a1_base      <= base_c;
            a1_fbpp_shr  <= fbpp_shr_c;
        end
    end

    // ---- combinational: 11-iteration Morton twiddle (off A1 regs) ----
    reg  [21:0] tw;
    integer sh; reg [10:0] xr, yr; integer sx, sy;
    always @(*) begin
        tw = 0; sh = 0; xr = a1_u; yr = a1_v;
        sx = a1_sx0 >> 1; sy = a1_sy0 >> 1;
        for (integer it = 0; it < 11; it = it + 1) begin
            if (sy != 0) begin tw[sh] = yr[0]; yr = yr >> 1; sy = sy >> 1; sh = sh + 1; end
            if (sx != 0) begin tw[sh] = xr[0]; xr = xr >> 1; sx = sx >> 1; sh = sh + 1; end
        end
    end
    wire [23:0] mip_add_a1 = a1_mipmapped ? {4'd0, a1_mipoff} : 24'd0;
    wire [23:0] off_full_c = {4'd0, (a1_twiddled ? tw[19:0] : a1_lin)} + mip_add_a1;

    // ================= A2 REGISTER ================================================
    reg               v2;
    reg        [23:0] a2_off_full;
    reg        [28:0] a2_base;
    reg        [2:0]  a2_fbpp_shr;
    always @(posedge clk) begin
        if (reset) v2 <= 1'b0;
        else if (!stall) begin
            v2          <= v1;
            a2_off_full <= off_full_c;
            a2_base     <= a1_base;
            a2_fbpp_shr <= a1_fbpp_shr;
        end
    end

    // ================= A3 COMBINATIONAL : byte-shift + add =======================
    wire [40:0] byte_off = ({17'd0, a2_off_full} << 1) >> a2_fbpp_shr;
    assign byte_addr = a2_base + byte_off[28:0];
    assign offset    = a2_off_full[19:0];
    assign fbpp_shr  = a2_fbpp_shr;
    assign out_valid = v2;
endmodule

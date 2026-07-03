//
// color_combiner - refsw ColorCombiner (texenv), combinational + testable.
// Combines base, textel, offset per ShadInstr. No bump. Offset is added
// (saturating) to rgb when pp_offset. Colours are packed {A,R,G,B} bytes.
//
//   ShadInstr 0: rv = textel
//   ShadInstr 1: rv.rgb = textel.rgb * u8_256(base.rgb)/256 ; rv.a = textel.a
//   ShadInstr 2: rv.rgb = mix(base.rgb, textel.rgb, textel.a) ; rv.a = base.a
//   ShadInstr 3: rv = textel * u8_256(base)/256  (all 4)
//   +offset: rv.rgb = min(rv.rgb + offset.rgb, 255)
//   !pp_texture: rv = base
//
module color_combiner (
    input             pp_texture,
    input             pp_offset,
    input      [1:0]  shadinstr,
    input      [31:0] base,      // {A,R,G,B}
    input      [31:0] textel,
    input      [31:0] offset,
    output     [31:0] col
);
    // channel accessors (i: 0=B[7:0] 1=G[15:8] 2=R[23:16] 3=A[31:24])
    function [7:0] ch(input [31:0] c, input [1:0] i);
        ch = c[8*i +: 8]; endfunction
    function [7:0] sat_add(input [7:0] a, input [7:0] b);
        reg [8:0] s; begin s = {1'b0,a}+{1'b0,b}; sat_add = s[8]?8'hFF:s[7:0]; end endfunction

    // Per-channel combine: ONE signed multiply, delta form (no 8->9 weight).
    //   out = sub + ((mA - sub) * w8) >> 8   with raw 8-bit weight w8 (0..255).
    //   si1/si3 (modulate): mA=textel, sub=0,    w8=base.ch    -> t*bw/256
    //   si2 (mix/lerp):     mA=textel, sub=base,  w8=textel.a   -> base+(t-b)*ta/256
    //   si0 (replace): bypass -> textel
    // Raw >>8 (not *256/256): the far end is approached as sub+(mA-sub)*255/256,
    // ~1 LSB short of exact mA - standard 8-bit modulate.
    function [7:0] comb_ch(input [1:0] i);
        reg [7:0]  t,b, sub, mA, w8;
        reg signed [9:0]  d; reg signed [17:0] m; reg signed [10:0] r;
        begin
            t = ch(textel,i); b = ch(base,i);
            case (shadinstr)
              2'd2: begin mA=t; sub=(i==2'd3)? t : b; w8=ch(textel,2'd3); end // mix
              default: begin mA=t; sub=8'd0; w8=b; end                        // modulate
            endcase
            d = $signed({2'b0,mA}) - $signed({2'b0,sub});
            m = d * $signed({1'b0,w8});          // signed multiply (raw 8-bit weight)
            r = $signed({3'b0,sub}) + $signed(m >>> 8);
            r = (r<0) ? 11'sd0 : (r>255) ? 11'sd255 : r;
            case (shadinstr)
              2'd0: comb_ch = t;                          // replace
              2'd1: comb_ch = (i==2'd3) ? t : r[7:0];     // modulate rgb, a=tex
              2'd2: comb_ch = (i==2'd3) ? b : r[7:0];     // mix, a=base
              2'd3: comb_ch = r[7:0];                     // modulate all
            endcase
        end
    endfunction

    wire [7:0] cB = comb_ch(2'd0), cG = comb_ch(2'd1), cR = comb_ch(2'd2), cA = comb_ch(2'd3);
    // offset add to rgb only
    wire [7:0] oB = pp_offset ? sat_add(cB, ch(offset,2'd0)) : cB;
    wire [7:0] oG = pp_offset ? sat_add(cG, ch(offset,2'd1)) : cG;
    wire [7:0] oR = pp_offset ? sat_add(cR, ch(offset,2'd2)) : cR;

    wire [31:0] tex_col = {cA, oR, oG, oB};
    assign col = pp_texture ? tex_col : base;
endmodule

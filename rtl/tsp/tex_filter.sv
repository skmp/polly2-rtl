//
// tex_filter - refsw TextureFilter blend, combinational + testable.
// Point (filter 0) -> t11. Bilinear (filter 1) -> weighted blend of 4 texels.
//
// DSP-folded bilinear via SEPARABLE lerps, written as 2-product sum-of-products
//   lerp(p,q,w) = (p*(256-w) + q*w) >> 8      // a*b + c*d  -> one DSP SOP slot
// (algebraically identical to p+((q-p)*w)>>8 since nw=256-w exactly, but the
//  a*b+c*d shape maps to the DSP's 9x9 sum-of-products mode: two 8x9 products
//  packed into one block, so 2 lerps fit where 2 independent muls needed 1 DSP
//  each). Both operands are <=9 bits (texel 8b, weight 0..256 = 9b) -> 9x9 SOP.
// Rows: a=lerp(t01,t00,ub) [v+1], b=lerp(t11,t10,ub) [v+0], out=lerp(b,a,vb).
// Weights: ub=u8_256(ui&255) in [0,256], vb=(vi&255) in [0,255]; the >>8 divides
// by 256. This matches refsw within the reduced-precision (<=~1 LSB) budget.
// Corners: t00=(u+1,v+1) t01=(u+0,v+1) t10=(u+1,v+0) t11=(u+0,v+0).
// If ignore_texa: out.a = 255.
//
module tex_filter (
    input             filter,       // 0=point, 1=bilinear
    input             ignore_texa,
    input      [7:0]  ufrac,        // ui & 255
    input      [7:0]  vfrac,        // vi & 255
    input      [31:0] t00,t01,t10,t11,
    output     [31:0] textel
);
    function [7:0] ch(input [31:0] c, input [1:0] i); ch = c[8*i +: 8]; endfunction

    // Folded lerp:  p + ((q-p) * u8_256(w8)) >> 8   with w8 raw 8-bit (0..255).
    // u8_256(w8) = w8 + w8[7] would be a 9-bit UNSIGNED weight (=256 at w8=255),
    // which as a signed operand needs 10 bits and will NOT fit the DSP 9x9 mode
    // (9-bit signed). So split the *256/256 scaling into a mul by the raw 8-bit
    // w8 plus a conditional add of the multiplicand when w8[7] is set:
    //   d*u8_256(w8) = d*w8 + (w8[7] ? d : 0)
    // Now the multiply is (q-p)[9-bit signed] * w8[8-bit unsigned -> 9-bit
    // signed], i.e. a genuine 9x9 signed multiply, and the +d is a cheap adder.
    // Bit-exact to refsw (which uses the same v+v>>7 = *256/256 scaling).
    // scale256: apply the u8_256 top-bit boost (u weight uses 0..256 in refsw).
    // The v weight uses raw vfrac (0..255), so scale256=0 for it.
    function [7:0] lerp(input [7:0] p, input [7:0] q, input [7:0] w8, input scale256);
        reg signed [9:0]  d;          // q-p in [-255,255]
        reg signed [17:0] m;          // d*w8 (+d) : 9x9 signed
        reg signed [10:0] r;
        begin
            d = $signed({2'b0,q}) - $signed({2'b0,p});
            m = d * $signed({1'b0,w8});               // 9x9 signed mul
            if (scale256 && w8[7]) m = m + d;         // + d*w8[7] == *256/256 top bit
            r = $signed({3'b0,p}) + $signed(m >>> 8);
            lerp = (r < 0) ? 8'd0 : (r > 255) ? 8'd255 : r[7:0];
        end
    endfunction

    function [7:0] blend(input [1:0] i);
        reg [7:0] a,b;
        begin
            a = lerp(ch(t01,i), ch(t00,i), ufrac, 1'b1);   // v+1 row, along u (u8_256)
            b = lerp(ch(t11,i), ch(t10,i), ufrac, 1'b1);   // v+0 row, along u (u8_256)
            blend = lerp(b, a, vfrac, 1'b0);               // along v (raw vfrac)
        end
    endfunction

    wire [7:0] bB = blend(2'd0), bG = blend(2'd1), bR = blend(2'd2), bA = blend(2'd3);
    wire [31:0] bilin = {bA,bR,bG,bB};
    wire [31:0] pre   = filter ? bilin : t11;
    assign textel = ignore_texa ? {8'hFF, pre[23:0]} : pre;
endmodule

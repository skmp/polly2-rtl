//
// tex_filter - refsw TextureFilter blend, combinational + testable.
// Point (filter 0) -> t11. Bilinear (filter 1) -> separable weighted blend.
//
// Delta-form lerp (ONE multiply per lerp, no 9-bit weight machinery):
//   lerp(p,q,w) = p + ((q-p) * w) >> 8      w = raw 8-bit weight (0..255)
// The multiply is (q-p)[9-bit signed] * w[8-bit unsigned] -> one signed product;
// the >>8 divides by 256. No u8_256 (0..256) weight and no conditional +d - the
// far endpoint is approached as p + (q-p)*255/256 (standard 8-bit bilinear,
// <=~1 LSB short of exact q).
// ufrac/vfrac are the FRACTIONS of the base sample: w=0 stays at the u+0/v+0
// corner, w->255 approaches u+1/v+1. Since lerp(p,q,w) weights toward q, the
// u+0 corner must be p and the u+1 corner q:
//   Rows: a=lerp(t01,t00,uf) [v+1], b=lerp(t11,t10,uf) [v+0], out=lerp(b,a,vf).
//   Corners: t00=(u+1,v+1) t01=(u+0,v+1) t10=(u+1,v+0) t11=(u+0,v+0).
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

    // lerp = p + ((q-p)*w) >> 8 : one signed 9x8 multiply + a subtract + an add.
    function [7:0] lerp(input [7:0] p, input [7:0] q, input [7:0] w8);
        reg signed [9:0]  d;          // q-p in [-255,255]
        reg signed [17:0] m;          // d*w8
        reg signed [10:0] r;
        begin
            d = $signed({2'b0,q}) - $signed({2'b0,p});
            m = d * $signed({1'b0,w8});               // signed multiply
            r = $signed({3'b0,p}) + $signed(m >>> 8);
            lerp = (r < 0) ? 8'd0 : (r > 255) ? 8'd255 : r[7:0];
        end
    endfunction

    function [7:0] blend(input [1:0] i);
        reg [7:0] a,b;
        begin
            a = lerp(ch(t01,i), ch(t00,i), ufrac);   // v+1 row, along u (p=u+0 -> q=u+1)
            b = lerp(ch(t11,i), ch(t10,i), ufrac);   // v+0 row, along u (p=u+0 -> q=u+1)
            blend = lerp(b, a, vfrac);               // along v  (p=v+0 -> q=v+1)
        end
    endfunction

    wire [7:0] bB = blend(2'd0), bG = blend(2'd1), bR = blend(2'd2), bA = blend(2'd3);
    wire [31:0] bilin = {bA,bR,bG,bB};
    wire [31:0] pre   = filter ? bilin : t11;
    assign textel = ignore_texa ? {8'hFF, pre[23:0]} : pre;
endmodule

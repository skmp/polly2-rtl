//
// f2u8 - float32 -> unsigned 8-bit (0..255), combinational.
//
// ROUND-TO-NEAREST conversion (DaZ, clamp):
//   negative or |v| < 1.0   -> 0        (see the NOTE below - unchanged)
//   v >= 256.0               -> 255
//   else  round(v)           (0..255)
//
// WHY ROUNDING, NOT TRUNCATION. The interpolated colour channels arrive from
// (ddx*x + ddy*y + c)*W through a chain of truncating FP units, so a channel whose
// exact value is an integer lands a HAIR BELOW it - 254.99... for a vertex alpha of
// 255. Truncating then costs a whole unit. That is invisible in colour, but it is
// decisive for PUNCH-THROUGH: the alpha test compares against PT_ALPHA_REF, which is
// 0xFF in jgr_car, so every fragment of an opaque primitive failed 254 >= 255 and the
// car body rendered as see-through holes. Rounding makes an exact-integer channel
// convert exactly, which is what the value MEANS.
//
// NOTE the |v| < 1.0 case still returns 0 rather than rounding 0.5..1.0 up to 1. That
// is deliberately left alone: the bug being fixed is at the top of the range, and
// changing the bottom would shift every dark colour in every scene for no evidence.
// If full round-to-nearest is ever wanted, that is the one remaining asymmetry.
//
// COST: ONE variable shifter, not two. Take the mantissa with one EXTRA bit -
// {1'b1, f[22:14]} = 1.f scaled by 2^9 - so shifting right by sh = 135-exp leaves the
// integer part in [9:1] and the rounding GUARD bit in [0]. Rounding is then an
// increment plus a FIXED >>1, which is wiring. (The obvious form, adding 1<<(sh-1)
// before a >>sh, needs a second barrel shifter just to build the addend; the two are
// arithmetically identical - see the derivation below.)
//   floor((m + 2^(s-1)) / 2^s)  ==  floor((floor(m / 2^(s-1)) + 1) / 2)
// for all m,s>=1: write m = q*2^(s-1) + r with r < 2^(s-1); the left side is
// floor((q+1)/2 + r/2^s) and r/2^s < 1/2, so it never crosses the next integer.
// Using f[14] as the guard also makes the result strictly more accurate than the
// 8-bit-mantissa form it replaces.
//
// Used by tsp_shade / tsp_shade_pp to pack interpolated 0..255 colour channels.
//
module f2u8 (
    input  [31:0] f,
    output [7:0]  u
);
    wire [7:0] sh  = 8'd135 - f[30:23];        // 1..8 for exp 127..134
    wire [9:0] g   = {1'b1, f[22:14]} >> sh;   // integer in [9:1], guard bit in [0]
    wire [9:0] ivr = (g + 10'd1) >> 1;         // round-half-up; the >>1 is free

    assign u = (f[31] || f[30:23] < 8'd127) ? 8'd0
             : (f[30:23] >= 8'd135)          ? 8'd255
             : (ivr > 10'd255)               ? 8'd255   // 255.5.. rounds up -> clamp
                                             : ivr[7:0];
endmodule

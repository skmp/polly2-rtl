//
// isp_raster_line - evaluate a LANES-pixel span of a scanline in a single clock
// (combinational), for opaque render mode.
//
// For tile-local pixel (x,y), x,y in 0..31 (pixel-center ignored, integer
// coords used directly), per refsw:
//    Xhs_n(x) = Cn + DXn*y - DYn*x        (n = 12,23,31,41)
//    inside   = Xhs12>=0 && Xhs23>=0 && Xhs31>=0 && Xhs41>=0
//    invW(x)  = c_invw + ddx*x + ddy*y
//
// This evaluates LANES consecutive pixels x = x_base .. x_base+LANES-1. With
// LANES=32 it does a whole line per clock; with a smaller LANES the caller
// sweeps x_base across the line in TILE_W/LANES chunks (fewer parallel
// depth-test comparators / interpolators). Set LANES back to 32 to restore the
// full-line-per-clock behaviour.
//
// Numerics per spec: DX/DY/ddx/ddy and Cn/c_invw are the reduced setup format;
// the *pixel-index* products use the fast 16-bit x 5-bit multiplier (fp_mul_i5)
// since x,y are 5-bit; sums use the higher-precision fp_add24, packed to fp32.
//
module isp_raster_line #(
    parameter integer LANES = 8         // pixels evaluated in parallel per clock
) (
    input      [4:0]  y,                // current line (0..31)
    input      [4:0]  x_base,           // first pixel of this span (0,8,16,24..)

    input      [31:0] c1,c2,c3,c4,
    input      [31:0] dx12,dx23,dx31,dx41,
    input      [31:0] dy12,dy23,dy31,dy41,
    input      [31:0] ddx,ddy,c_invw,

    output     [LANES-1:0]    inside_mask, // bit i = pixel (x_base+i) is inside
    output     [32*LANES-1:0] invw_flat    // packed invW, lane i = [32*i +: 32]
);
    function fpos_or_zero(input [31:0] f); // f >= 0 : sign bit clear (incl +0)
        fpos_or_zero = ~f[31]; endfunction

    // ---- per-line base: ebase_n = Cn + DXn*y ; wbase = c_invw + ddy*y ----
    wire [31:0] dx12y,dx23y,dx31y,dx41y, ddyy;
    fp_mul_i5 m_dx12y(.f(dx12),.k(y),.y(dx12y));
    fp_mul_i5 m_dx23y(.f(dx23),.k(y),.y(dx23y));
    fp_mul_i5 m_dx31y(.f(dx31),.k(y),.y(dx31y));
    fp_mul_i5 m_dx41y(.f(dx41),.k(y),.y(dx41y));
    fp_mul_i5 m_ddyy (.f(ddy), .k(y),.y(ddyy));

    wire [31:0] eb1,eb2,eb3,eb4, wbase;
    fp_add24 a_eb1(.a(c1),.b_in(dx12y),.sub(1'b0),.y(eb1));
    fp_add24 a_eb2(.a(c2),.b_in(dx23y),.sub(1'b0),.y(eb2));
    fp_add24 a_eb3(.a(c3),.b_in(dx31y),.sub(1'b0),.y(eb3));
    fp_add24 a_eb4(.a(c4),.b_in(dx41y),.sub(1'b0),.y(eb4));
    fp_add24 a_wb (.a(c_invw),.b_in(ddyy),.sub(1'b0),.y(wbase));

    genvar gi;
    generate
      for (gi = 0; gi < LANES; gi = gi + 1) begin : px
        wire [4:0] x = x_base + gi[4:0];      // absolute tile-local column
        // Xhs_n(x) = ebase_n - DYn*x
        wire [31:0] dy12x,dy23x,dy31x,dy41x, ddxx;
        fp_mul_i5 mdy12(.f(dy12),.k(x),.y(dy12x));
        fp_mul_i5 mdy23(.f(dy23),.k(x),.y(dy23x));
        fp_mul_i5 mdy31(.f(dy31),.k(x),.y(dy31x));
        fp_mul_i5 mdy41(.f(dy41),.k(x),.y(dy41x));
        fp_mul_i5 mddx (.f(ddx), .k(x),.y(ddxx));

        wire [31:0] xh1,xh2,xh3,xh4;
        fp_add24 axh1(.a(eb1),.b_in(dy12x),.sub(1'b1),.y(xh1));
        fp_add24 axh2(.a(eb2),.b_in(dy23x),.sub(1'b1),.y(xh2));
        fp_add24 axh3(.a(eb3),.b_in(dy31x),.sub(1'b1),.y(xh3));
        fp_add24 axh4(.a(eb4),.b_in(dy41x),.sub(1'b1),.y(xh4));

        assign inside_mask[gi] = fpos_or_zero(xh1) & fpos_or_zero(xh2)
                               & fpos_or_zero(xh3) & fpos_or_zero(xh4);

        // invW(x) = wbase + ddx*x
        fp_add24 aiw(.a(wbase),.b_in(ddxx),.sub(1'b0),.y(invw_flat[32*gi +: 32]));
      end
    endgenerate
endmodule

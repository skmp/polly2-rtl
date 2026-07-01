//
// isp_raster_line - evaluate a LANES-pixel span of a scanline, PIPELINED, for
// opaque render mode. Registers between every FP sub-level (mul, add-align,
// add-normalize) so the max path is ~one FP sub-op and the design closes timing.
//
// For tile-local pixel (x,y), x,y in 0..31 (pixel-center ignored):
//    Xhs_n(x) = Cn + DXn*y - DYn*x        (n = 12,23,31,41)
//    inside   = Xhs12>=0 && Xhs23>=0 && Xhs31>=0 && Xhs41>=0
//    invW(x)  = c_invw + ddx*x + ddy*y
//
// Pipeline (in_valid -> out_valid after LAT cycles):
//   s1  : DXn*y, ddy*y                          (fp_mul_i5)
//   s2a : ebase/wbase align (Cn + DXn*y)        (fp_add24_s1)
//   s2b : ebase/wbase normalize                 (fp_add24_s2)
//   s3  : DYn*x, ddx*x                           (fp_mul_i5)
//   s4a : Xhs/invW align (ebase - DY*x)         (fp_add24_s1)
//   s4b : Xhs/invW normalize -> inside, invW    (fp_add24_s2)
//
// Numerics per spec: pixel-index products use the fast 16x5 multiplier; sums use
// fp_add24 (split align|normalize here for timing).
//
module isp_raster_line #(
    parameter integer LANES = 8
) (
    input             clk,
    input             reset,
    input             in_valid,
    input      [4:0]  y,
    input      [4:0]  x_base,

    input      [31:0] c1,c2,c3,c4,
    input      [31:0] dx12,dx23,dx31,dx41,
    input      [31:0] dy12,dy23,dy31,dy41,
    input      [31:0] ddx,ddy,c_invw,

    output reg               out_valid,
    output reg [LANES-1:0]    inside_mask,
    output reg [32*LANES-1:0] invw_flat
);
    localparam integer LAT = 6;

    function fpos_or_zero(input [31:0] f); fpos_or_zero = ~f[31]; endfunction

    reg [LAT-1:0] vpipe;
    always @(posedge clk) begin
        if (reset) vpipe <= '0;
        else       vpipe <= {vpipe[LAT-2:0], in_valid};
    end

    // carry x_base to stage 3 (line base stages don't need it)
    reg [4:0] xb1, xb2a, xb2b;
    always @(posedge clk) begin xb1<=x_base; xb2a<=xb1; xb2b<=xb2a; end

    // ---- s1: DXn*y, ddy*y ----
    wire [31:0] dx12y_c,dx23y_c,dx31y_c,dx41y_c, ddyy_c;
    fp_mul_i5 m_dx12y(.f(dx12),.k(y),.y(dx12y_c));
    fp_mul_i5 m_dx23y(.f(dx23),.k(y),.y(dx23y_c));
    fp_mul_i5 m_dx31y(.f(dx31),.k(y),.y(dx31y_c));
    fp_mul_i5 m_dx41y(.f(dx41),.k(y),.y(dx41y_c));
    fp_mul_i5 m_ddyy (.f(ddy), .k(y),.y(ddyy_c));
    reg [31:0] dx12y,dx23y,dx31y,dx41y, ddyy;
    reg [31:0] c1_1,c2_1,c3_1,c4_1,cinvw_1;
    always @(posedge clk) begin
        dx12y<=dx12y_c; dx23y<=dx23y_c; dx31y<=dx31y_c; dx41y<=dx41y_c; ddyy<=ddyy_c;
        c1_1<=c1; c2_1<=c2; c3_1<=c3; c4_1<=c4; cinvw_1<=c_invw;
    end

    // ---- s2a: base align (Cn + DXn*y ; c_invw + ddy*y) ----
    wire [24:0] eb1s,eb2s,eb3s,eb4s, wbs; wire [7:0] eb1e,eb2e,eb3e,eb4e,wbe;
    wire eb1g,eb2g,eb3g,eb4g,wbg;
    fp_add24_s1 e1a(.a(c1_1),.b_in(dx12y),.sub(1'b0),.sum(eb1s),.e_big(eb1e),.s_big(eb1g));
    fp_add24_s1 e2a(.a(c2_1),.b_in(dx23y),.sub(1'b0),.sum(eb2s),.e_big(eb2e),.s_big(eb2g));
    fp_add24_s1 e3a(.a(c3_1),.b_in(dx31y),.sub(1'b0),.sum(eb3s),.e_big(eb3e),.s_big(eb3g));
    fp_add24_s1 e4a(.a(c4_1),.b_in(dx41y),.sub(1'b0),.sum(eb4s),.e_big(eb4e),.s_big(eb4g));
    fp_add24_s1 wba(.a(cinvw_1),.b_in(ddyy),.sub(1'b0),.sum(wbs),.e_big(wbe),.s_big(wbg));
    reg [24:0] eb1s_r,eb2s_r,eb3s_r,eb4s_r,wbs_r; reg [7:0] eb1e_r,eb2e_r,eb3e_r,eb4e_r,wbe_r;
    reg eb1g_r,eb2g_r,eb3g_r,eb4g_r,wbg_r;
    reg [31:0] dy12_2,dy23_2,dy31_2,dy41_2,ddx_2;
    always @(posedge clk) begin
        eb1s_r<=eb1s;eb2s_r<=eb2s;eb3s_r<=eb3s;eb4s_r<=eb4s;wbs_r<=wbs;
        eb1e_r<=eb1e;eb2e_r<=eb2e;eb3e_r<=eb3e;eb4e_r<=eb4e;wbe_r<=wbe;
        eb1g_r<=eb1g;eb2g_r<=eb2g;eb3g_r<=eb3g;eb4g_r<=eb4g;wbg_r<=wbg;
        dy12_2<=dy12;dy23_2<=dy23;dy31_2<=dy31;dy41_2<=dy41;ddx_2<=ddx;
    end

    // ---- s2b: base normalize -> eb1..eb4, wbase ----
    wire [31:0] eb1_c,eb2_c,eb3_c,eb4_c,wbase_c;
    fp_add24_s2 e1b(.sum(eb1s_r),.e_big(eb1e_r),.s_big(eb1g_r),.y(eb1_c));
    fp_add24_s2 e2b(.sum(eb2s_r),.e_big(eb2e_r),.s_big(eb2g_r),.y(eb2_c));
    fp_add24_s2 e3b(.sum(eb3s_r),.e_big(eb3e_r),.s_big(eb3g_r),.y(eb3_c));
    fp_add24_s2 e4b(.sum(eb4s_r),.e_big(eb4e_r),.s_big(eb4g_r),.y(eb4_c));
    fp_add24_s2 wbb(.sum(wbs_r),.e_big(wbe_r),.s_big(wbg_r),.y(wbase_c));
    reg [31:0] eb1,eb2,eb3,eb4,wbase;
    reg [31:0] dy12_3,dy23_3,dy31_3,dy41_3,ddx_3;
    always @(posedge clk) begin
        eb1<=eb1_c;eb2<=eb2_c;eb3<=eb3_c;eb4<=eb4_c;wbase<=wbase_c;
        dy12_3<=dy12_2;dy23_3<=dy23_2;dy31_3<=dy31_2;dy41_3<=dy41_2;ddx_3<=ddx_2;
    end

    genvar gi;
    generate
      for (gi = 0; gi < LANES; gi = gi + 1) begin : px
        wire [4:0] x = xb2b + gi[4:0];       // absolute column at stage 3
        // ---- s3: DYn*x, ddx*x ----
        wire [31:0] dy12x_c,dy23x_c,dy31x_c,dy41x_c, ddxx_c;
        fp_mul_i5 mdy12(.f(dy12_3),.k(x),.y(dy12x_c));
        fp_mul_i5 mdy23(.f(dy23_3),.k(x),.y(dy23x_c));
        fp_mul_i5 mdy31(.f(dy31_3),.k(x),.y(dy31x_c));
        fp_mul_i5 mdy41(.f(dy41_3),.k(x),.y(dy41x_c));
        fp_mul_i5 mddx (.f(ddx_3), .k(x),.y(ddxx_c));
        reg [31:0] dy12x,dy23x,dy31x,dy41x, ddxx;
        reg [31:0] eb1_3,eb2_3,eb3_3,eb4_3,wbase_3;
        always @(posedge clk) begin
            dy12x<=dy12x_c;dy23x<=dy23x_c;dy31x<=dy31x_c;dy41x<=dy41x_c;ddxx<=ddxx_c;
            eb1_3<=eb1;eb2_3<=eb2;eb3_3<=eb3;eb4_3<=eb4;wbase_3<=wbase;
        end

        // ---- s4a: Xhs/invW align ----
        wire [24:0] h1s,h2s,h3s,h4s,ws; wire [7:0] h1e,h2e,h3e,h4e,we;
        wire h1g,h2g,h3g,h4g,wg;
        fp_add24_s1 x1a(.a(eb1_3),.b_in(dy12x),.sub(1'b1),.sum(h1s),.e_big(h1e),.s_big(h1g));
        fp_add24_s1 x2a(.a(eb2_3),.b_in(dy23x),.sub(1'b1),.sum(h2s),.e_big(h2e),.s_big(h2g));
        fp_add24_s1 x3a(.a(eb3_3),.b_in(dy31x),.sub(1'b1),.sum(h3s),.e_big(h3e),.s_big(h3g));
        fp_add24_s1 x4a(.a(eb4_3),.b_in(dy41x),.sub(1'b1),.sum(h4s),.e_big(h4e),.s_big(h4g));
        fp_add24_s1 iwa(.a(wbase_3),.b_in(ddxx),.sub(1'b0),.sum(ws),.e_big(we),.s_big(wg));
        reg [24:0] h1s_r,h2s_r,h3s_r,h4s_r,ws_r; reg [7:0] h1e_r,h2e_r,h3e_r,h4e_r,we_r;
        reg h1g_r,h2g_r,h3g_r,h4g_r,wg_r;
        always @(posedge clk) begin
            h1s_r<=h1s;h2s_r<=h2s;h3s_r<=h3s;h4s_r<=h4s;ws_r<=ws;
            h1e_r<=h1e;h2e_r<=h2e;h3e_r<=h3e;h4e_r<=h4e;we_r<=we;
            h1g_r<=h1g;h2g_r<=h2g;h3g_r<=h3g;h4g_r<=h4g;wg_r<=wg;
        end

        // ---- s4b: Xhs/invW normalize -> outputs ----
        wire [31:0] xh1,xh2,xh3,xh4, iw;
        fp_add24_s2 x1b(.sum(h1s_r),.e_big(h1e_r),.s_big(h1g_r),.y(xh1));
        fp_add24_s2 x2b(.sum(h2s_r),.e_big(h2e_r),.s_big(h2g_r),.y(xh2));
        fp_add24_s2 x3b(.sum(h3s_r),.e_big(h3e_r),.s_big(h3g_r),.y(xh3));
        fp_add24_s2 x4b(.sum(h4s_r),.e_big(h4e_r),.s_big(h4g_r),.y(xh4));
        fp_add24_s2 iwb(.sum(ws_r),.e_big(we_r),.s_big(wg_r),.y(iw));
        always @(posedge clk) begin
            inside_mask[gi] <= fpos_or_zero(xh1) & fpos_or_zero(xh2)
                             & fpos_or_zero(xh3) & fpos_or_zero(xh4);
            invw_flat[32*gi +: 32] <= iw;
        end
      end
    endgenerate

    always @(posedge clk) out_valid <= vpipe[LAT-1];
endmodule

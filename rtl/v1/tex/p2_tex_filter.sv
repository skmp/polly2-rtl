// p2_tex_filter: the pixel pipe's P6 filter (PLAN M11; ARCHITECTURE 3.8; tsp 11 at refsw3 4f3efe15: refsw_tile.cpp
// TextureFilter from the four fetched texels on). The four decoded texels (p2_tex_decode, taps 00, 01, 10, 11) to the
// point's texel, registered (the P6 register) with the point:
//
//   point        tap 11 (u, v) [sample]
//   bilinear     two steps, each truncated: along u within each row, then between the rows, 5-bit weights
//                  row0 = (t11 (32 - ub) + t10 ub) >> 5,  row1 = (t01 (32 - ub) + t00 ub) >> 5
//                  c    = (row0 (32 - vb) + row1 vb) >> 5                 [sample page 1: 52,224 of 52,224; one sum of
//                                                                          four gets 38,523]
//   bump map     (the TCW's format) the low byte, the angle R, round the circle by the shorter way in the same two steps:
//                from the end the other is at most half a turn above, (distance x w) >> 5, w the weight when the start
//                is the first texel, 31 - weight when it is the second [bumpbil; bumpclamp]
//   IgnoreTexA   alpha 255
// A trilinear pass is bilinear here (the fade is P8's); FilterMode >= 2 without MipMapped is point (p2_tex_addr's filt).
module p2_tex_filter
  import p2_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic              clk,
  input  logic              rst,
  input  logic              stall,
  input  logic              i_v,
  input  p2_pp_pt_t         i_pt,
  input  p2_tex_req_t       i_req,
  input  logic [3:0][31:0]  texel,
  output logic              o_v,
  output p2_pp_pt_t         o_pt,
  output logic [31:0]       o_tex
);
  function automatic logic [7:0] circular(input logic [7:0] first, input logic [7:0] second, input logic [4:0] weight);
    logic [7:0]  hi, lo, apart, start;
    logic [8:0]  distance;
    logic [4:0]  w;
    logic [13:0] p;
    hi    = (first > second) ? first : second;
    lo    = (first > second) ? second : first;
    apart = hi - lo;
    start = (apart < 8'd128) ? lo : hi;
    distance  = (apart < 8'd128) ? {1'b0, apart} : (9'd256 - {1'b0, apart});
    w     = (start == first) ? weight : (5'd31 - weight);
    p     = 14'(distance) * 14'(w);
    return start + p[12:5];
  endfunction

  logic [31:0] tx;
  always_comb begin
    logic [4:0] ub, vb;
    logic [5:0] nub, nvb;
    logic [13:0] r0, r1, o;
    r0  = '0;
    r1  = '0;
    o   = '0;
    ub  = i_req.ub;
    vb  = i_req.vb;
    nub = 6'd32 - {1'b0, ub};
    nvb = 6'd32 - {1'b0, vb};
    tx  = texel[3];
    if (!i_req.filt)
      tx = texel[3];
    else begin
      for (int c = 0; c < 4; c++) begin
        r0 = (14'(texel[3][8 * c +: 8]) * 14'(nub) + 14'(texel[2][8 * c +: 8]) * 14'(ub)) >> 5;
        r1 = (14'(texel[1][8 * c +: 8]) * 14'(nub) + 14'(texel[0][8 * c +: 8]) * 14'(ub)) >> 5;
        o  = (r0 * 14'(nvb) + r1 * 14'(vb)) >> 5;
        tx[8 * c +: 8] = o[7:0];
      end
      if (i_pt.ctl.hdr.tcw[29:27] == P2_PIX_BUMP)
        tx[7:0] = circular(circular(texel[3][7:0], texel[2][7:0], ub), circular(texel[1][7:0], texel[0][7:0], ub), vb);
    end
    if (i_pt.ctl.hdr.tsp[19]) tx[31:24] = 8'hFF;                         // IgnoreTexA
  end

  always_ff @(posedge clk) begin
    if (rst) o_v <= 1'b0;
    else if (!stall) o_v <= i_v;
    if (i_v && !stall) begin
      o_pt  <= i_pt;
      o_tex <= tx;
    end
  end
endmodule

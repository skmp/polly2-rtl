// p2_fp_color_round: H15 color_round, an interpolated colour from its quotient (docs/spec/numerics.md H15; refcore
// pvr_tsp_plane.h ColorRounded(q, scaleExp, max, fallback) at refsw_tile.h IPs3::Rounded; dreamcast-tests
// pvr-tests/cmeas: 2,340,000 of 2,340,000 readings, "the 8 bit color is floor(v + 0.5)"; shade: 80,256 of 80,256;
// huge: a console still draws a polygon with a depth of 0, infinity or NaN at the pixel in its colour):
//
//   q.bad:             fallback (the attribute itself: the last vertex's colour byte)
//   q < 0 or q == 0:   0
//   top(q) - SE > 30:  MAX
//   twice = floor(q 2^(1 - SE))                     exact when the shift is left; q's top - SE <= 30 bounds it by 2^31
//   twice > 2 MAX:     MAX
//   otherwise:         (twice + 1) >> 1             floor(v + 1/2): to nearest, half way up
//
// SE is the attribute's scale, refsw_tile.h ColorExp -8 (a colour enters the planes as c 2^-8: SingleBits). MAX is 255
// (offset colours) or 65535 (a base colour, which the intensity shadow scales before it is clamped: refsw_tile.cpp
// InterpolateBase); p2_pp_col has both. refsw3's last `v > max ? max : v` never acts once twice <= 2 MAX (then
// v <= MAX), so it is not built. A quotient from p2_fp_div is never flagged (q_bad = 0 there): fallback is reachable
// only from a caller with a flagged quotient. Combinational.
module p2_fp_color_round
  import p2_fp_pkg::*;
#(
  parameter int MAX = 255,
  parameter int SE  = -8,
  parameter int QW  = 18
) (
  input  logic                       q_neg,
  input  logic                       q_bad,
  input  logic signed [P2_FP_EW-1:0] q_exp,
  input  logic [QW-1:0]              q_mant,
  input  logic [7:0]                 fallback,
  output logic [15:0]                o
);
  localparam int NW   = $clog2(QW + 1);
  localparam int TOPM = 30;              // `q.top() - scaleExp > 30`
  localparam int TW   = 31;              // twice < 2^31 below that
  localparam int WW   = QW + TW;         // q's mantissa above TW zeros: one right shift gives every twice

  logic [NW-1:0]              bits;
  logic signed [P2_FP_XW-1:0] tsc;       // top(q) - SE
  logic signed [P2_FP_XW-1:0] rs;        // TW - (exp - SE + 1): the right shift of {mant, TW zeros}
  logic [WW-1:0]              w;
  logic [TW-1:0]              twice;
  logic [TW-1:0]              v;

`ifndef SYNTHESIS
  if (MAX < 1 || MAX > 65535) begin : g_max
    $fatal(1, "p2_fp_color_round: MAX %0d does not fit the 16-bit output", MAX);
  end
`endif

  p2_fp_lzc #(.W(QW), .NW(NW)) u_bl (.v(q_mant), .n(bits));

  assign tsc = p2_fp_xw(q_exp) + P2_FP_XW'(bits) - P2_FP_XW'(SE);
  // e + 1 = exp - SE + 1 <= TW - bits when tsc <= TOPM, so rs >= 1; rs at least WW leaves nothing
  assign rs  = P2_FP_XW'(TW) - (p2_fp_xw(q_exp) - P2_FP_XW'(SE) + P2_FP_XW'(1));
  assign w   = (rs >= P2_FP_XW'(WW)) ? '0 : ({q_mant, {TW{1'b0}}} >> rs[$clog2(WW+1)-1:0]);
  assign twice = w[TW-1:0];
  assign v     = (twice + TW'(1)) >> 1;

  always_comb begin
    if (q_bad)
      o = {8'd0, fallback};
    else if (q_neg || q_mant == '0)
      o = '0;
    else if (tsc > P2_FP_XW'(TOPM))
      o = 16'(MAX);
    else if (twice > TW'(2 * MAX))
      o = 16'(MAX);
    else
      o = v[15:0];
  end
endmodule

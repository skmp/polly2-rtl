// p2_fp_tex_coord: H11, a texture coordinate in 1/256 texel from the divider's quotient (docs/spec/numerics.md H11
// "TexCoordFixed", tsp 9.1; refcore refsw_tile.cpp TexCoordFixed L1276 and CoordKeep L1264 at 708fb8cd):
//
//   bad or zero:            0
//   top(u) + shift <= 31:   f = floor(u 2^shift), two's complement, below zero too (a negative with a fraction one
//                           further from zero); then CoordKeep(f): inside +-2^30 itself, beyond the sign and the low 26
//                           bits (2^30 + low26, or -2^30 + low26 of the two's complement)
//   beyond (2^30 and more): an integer: its low 26 bits (two's complement for a negative one): 2^30 + low26, or
//                           -2^30 + ((2^26 - low26) mod 2^26)
//
// Evidence: dreamcast-tests pvr-tests/coordfix (every weight step from -4 to +4 texels and at up to 2^17 texels, clamp
// and flip: rounded down, not toward zero), sample, uvmeas; texfar_edge, texfar, texfar_quot, texfar_m1q (2^128 and
// beyond: no overflow to texel 0, the sign and the low bits), texfar_bits (the low bits of tops 2^9 .. 2^36). shift is
// log2(size) + 8 or 3 + TexU / TexV + 8 at the sites (11 .. 18). The quotient (p2_quot_t) has at most 18 bits; a 2^17
// mantissa after the divider's carry included. Combinational.
module p2_fp_tex_coord
  import p2_fp_pkg::*;
#(
  parameter int MW = 18           // the quotient's mantissa bits (num H13: q in [2^15, 2^17])
) (
  input  logic                       u_neg,
  input  logic                       u_bad,
  input  logic signed [P2_FP_EW-1:0] u_exp,
  input  logic [MW-1:0]              u_mant,
  input  logic [4:0]                 shift,
  output logic signed [31:0]         o_coord
);
  localparam int NW = $clog2(MW + 1);

  logic [NW-1:0]              n;
  logic signed [P2_FP_XW-1:0] e, top, ne;
  logic [5:0]                 sl;          // a left shift: 0 .. 31 (top <= 31), or up to 26 for the low bits
  logic [6:0]                 sr;          // a right shift: 0 .. 64
  logic [31:0]                f;           // the magnitude, toward zero (< 2^31 when top <= 31)
  logic                       lost;
  logic signed [32:0]         fs;          // floor(u 2^shift), signed
  logic [25:0]                low;         // the integer's low 26 bits

  p2_fp_lzc #(.W(MW), .NW(NW)) u_bl (.v(u_mant), .n(n));

  assign e   = p2_fp_xw(u_exp) + P2_FP_XW'(shift);
  assign top = e + P2_FP_XW'(n);
  assign ne  = P2_FP_XW'(0) - e;
  assign sl  = (e <= 0) ? '0 : (e > P2_FP_XW'(31)) ? 6'd32 : 6'(e);
  assign sr  = (e >= 0) ? '0 : (ne > P2_FP_XW'(64)) ? 7'd64 : 7'(ne);
  assign f    = (e >= 0) ? ((sl > 6'd31) ? '0 : 32'(63'(u_mant) << sl))
                         : ((sr >= 7'(MW)) ? '0 : 32'(MW'(u_mant >> sr)));
  assign lost = (e >= 0) ? 1'b0 : ((sr >= 7'(MW)) ? (u_mant != '0) : ((u_mant & ((MW'(1) << sr) - MW'(1))) != '0));
  // below zero a value with a fraction goes one further from zero (rounded down in two's complement)
  assign fs   = u_neg ? $signed(33'd0 - 33'(f) - 33'(lost)) : $signed(33'(f));
  assign low  = (sl >= 6'd26) ? '0 : 26'(63'(u_mant) << sl);

  always_comb begin
    if (u_bad || u_mant == '0)
      o_coord = '0;
    else if (top <= P2_FP_XW'(31)) begin
      // CoordKeep(f)
      if (fs >= 33'sd1073741824)
        o_coord = 32'sd1073741824 + $signed({6'd0, fs[25:0]});
      else if (fs < -33'sd1073741824)
        o_coord = -32'sd1073741824 + $signed({6'd0, fs[25:0]});
      else
        o_coord = 32'(fs);
    end else if (!u_neg)
      o_coord = 32'sd1073741824 + $signed({6'd0, low});
    else
      o_coord = -32'sd1073741824 + $signed({6'd0, 26'd0 - low});
  end
endmodule

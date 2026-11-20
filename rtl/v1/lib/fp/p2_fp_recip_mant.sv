// p2_fp_recip_mant: H13 recip_mant, the TSP divider's 16-bit reciprocal of a 16-bit mantissa (docs/spec/numerics.md
// H13; docs/spec/tsp.md 6.1; refcore pvr_tsp_plane.h RecipTable::Mantissa; dreamcast-tests pvr-tests/uvmeas, mix
// recipscan: all 32768 values of D, 14 runs):
//
//   D in [32768, 65535] (D / 65536 in [0.5, 1));  i = D[14:6] (= (D >> 6) - 512),  f = D[5:0]
//   r = (64 t[i] - 1 - n[i] f) >> 7          r in [32768, 65535]: r / 65536 is about 32768 / D
//
// t[i], n[i] from p2_fp_recip_rom (GENERATED from the header's string and formula). r(32768) = 65535: 1 / 1.0 reads as
// 0.FFFF, which is why an attribute over 1/w = 1 arrives one unit of its 16th bit low (uvmeas; sample). The arithmetic
// is a 9 x 6 multiplier, a subtract and a shift. Combinational. D below 32768 is outside the domain (p2_fp_div_den
// gives a normalized mantissa); its result is whatever the arithmetic gives.
module p2_fp_recip_mant (
  input  logic [15:0] d,
  output logic [15:0] r
);
  logic [16:0] t17;        // t[i] - 65536
  logic [8:0]  n;          // n[i], 65 .. 256
  logic [17:0] t;          // t[i], 65601 .. 131072
  logic [23:0] t64;        // 64 t[i] - 1 < 2^23
  logic [14:0] nf;         // n[i] f <= 256 x 63
  logic [23:0] x;          // 64 t[i] - 1 - n[i] f, in [2^22, 2^23)

  p2_fp_recip_rom u_rom (.i(d[14:6]), .t(t17), .n(n));

  assign t   = {1'b0, t17} + 18'd65536;
  assign t64 = {t, 6'd0} - 24'd1;
  assign nf  = n * {3'd0, d[5:0]};
  assign x   = t64 - {9'd0, nf};
  assign r   = x[22:7];
endmodule

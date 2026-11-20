// p2_fp_in_colour: H4, an 8-bit colour channel c as the TSP setup takes it: the bits of the IEEE single c * 2^-8
// (docs/spec/numerics.md H4, 2.5; refcore pvr_softfp.h SingleBits(c, -8), refsw_tile.h ColorExp L90). The setup reads
// the word back with FromSingle(., 1) (p2_fp_in_single), so a colour enters the planes as exactly c 2^-8
// (cmeas cwext1: 2,333,331 of 2,340,000 with 2^-8 against 1,688,587 with 2^-7 and 2,124,860 with 2^-9).
//
//   c == 0:  0x00000000
//   else:    (BL(c) - 8 - 1 + 127) << 23 | (c << (24 - BL(c))) & 0x7fffff
//
// Combinational.
module p2_fp_in_colour (
  input  logic [7:0]  c,
  output logic [31:0] w
);
  logic [3:0]  n;          // BL(c), 1 .. 8
  logic [22:0] frac;       // the bits under c's leading one, as a single's fraction field

  p2_fp_lzc #(.W(8), .NW(4)) u_bl (.v(c), .n(n));

  assign frac = 23'({c, 16'h0000} << (4'd8 - n));
  // the exponent field: BL(c) - 9 + 127 = BL(c) + 118, 119 .. 126
  assign w    = (c == 8'h00) ? 32'h0 : {1'b0, 8'd118 + {4'h0, n}, frac};
endmodule

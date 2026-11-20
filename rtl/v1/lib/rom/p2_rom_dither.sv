// GENERATED: do not edit. tools/gen/gen_table_roms.cpp from refcore (nulldc3 refsw3/refcore) refsw_lists.cpp,
// the entries of `static const int ditherAdd[4][4] = {` read from the text. Regenerate: make roms; check: make roms-check.
//
// p2_rom_dither: what the write-out adds to a channel before it cuts it to 4 bits, ditherAdd[Y & 3][X & 3]
// (rows are y); half of it for 5 bits, a quarter for 6 (docs/spec/tsp.md 17.3; refcore refsw_lists.cpp
// RenderCORE `put`; dreamcast-tests pvr-tests/fbpack: every entry pinned, lower bound = upper bound; fb555,
// fb565). Combinational (a case ROM).
module p2_rom_dither (
  input  logic [1:0] y,     // Y & 3: the framebuffer line
  input  logic [1:0] x,     // X & 3: the framebuffer column
  output logic [3:0] v
);
  always_comb begin
    case ({y, x})
      4'd0:  v = 4'd5;    // y 0, x 0
      4'd1:  v = 4'd13;   // y 0, x 1
      4'd2:  v = 4'd7;    // y 0, x 2
      4'd3:  v = 4'd15;   // y 0, x 3
      4'd4:  v = 4'd9;    // y 1, x 0
      4'd5:  v = 4'd1;    // y 1, x 1
      4'd6:  v = 4'd11;   // y 1, x 2
      4'd7:  v = 4'd3;    // y 1, x 3
      4'd8:  v = 4'd6;    // y 2, x 0
      4'd9:  v = 4'd14;   // y 2, x 1
      4'd10: v = 4'd4;    // y 2, x 2
      4'd11: v = 4'd12;   // y 2, x 3
      4'd12: v = 4'd10;   // y 3, x 0
      4'd13: v = 4'd2;    // y 3, x 1
      4'd14: v = 4'd8;    // y 3, x 2
      4'd15: v = 4'd0;    // y 3, x 3
      default: v = '0;   // every index is above (a complete case)
    endcase
  end
endmodule

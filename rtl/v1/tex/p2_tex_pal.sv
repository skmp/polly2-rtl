// p2_tex_pal: the palette RAM, PALETTE_RAM 0x1000 - 0x1FFC (PLAN M11; ARCHITECTURE 3.8 p2_tex_decode "palette index and
// PALETTE_RAM read at shading time"; refsw_tile.cpp DecodeTextel reads PALETTE_RAM[idx] when it shades the texel
// [tsp 10; palette entries written between renders take effect at the next render]). 1024 entries of 32 bits, written
// through the register port (p2_regs' in M12, the testbench's in M11), read by p2_tex_decode for the four taps of a point
// in one clock: four read ports, asynchronous (the P6 stage reads them in its clock).
// [Die: the long palette SRAM of region 10 is one macro; four reads a clock is this design's (bilinear's four taps), and a
// 32-bit (8888) entry's measured extra clock is GAP T8; ARCHITECTURE 3.12.]
module p2_tex_pal (
  input  logic              clk,
  input  logic              we,
  input  logic [9:0]        widx,
  input  logic [31:0]       wdata,
  input  logic [3:0][9:0]   ridx,
  output logic [3:0][31:0]  rdata
);
  logic [31:0] mem [1024];
  always_ff @(posedge clk)
    if (we) mem[widx] <= wdata;
  always_comb
    for (int i = 0; i < 4; i++)
      rdata[i] = mem[ridx[i]];
endmodule

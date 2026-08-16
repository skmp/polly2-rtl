//
// tile_ram - a 32x32 tile buffer as NBANKS independent SIMPLE-DUAL-PORT M10K
// RAMs, so a whole NBANKS-pixel span of a scanline can be READ and (a different
// span) WRITTEN in the SAME clock while still mapping to block RAM (not
// registers). This is what lets the streaming rasterizer sustain NBANKS
// pixels/clock: stage-A reads chunk N while stage-B writes chunk N-1.
//
// Addressing for tile-local pixel (x,y), x,y in 0..31:
//   bank = x[BW-1:0]                     (NBANKS = 2**BW, default 8)
//   addr = {y[4:0], x[4:BW]}             (DEPTH = 1024/NBANKS entries)
// In an NBANKS-wide chunk with x_base a multiple of NBANKS, the NBANKS lanes
// span x_base..x_base+NBANKS-1, whose low BW bits are 0..NBANKS-1 (distinct bank
// each) and whose high bits x[4:BW] are identical (one address/bank).
//
// Per bank per cycle: an independent READ (raddr -> rdata next cycle) AND an
// independent WRITE (waddr/wdata when we). Simple-dual-port M10K. Read-during-
// write to the SAME address returns OLD data (read-first); callers that need the
// just-written value must forward it (the raster consumer does, for the rare
// same-word back-to-back chunk).
//
// COPIES > 1 stacks that many INDEPENDENT tile images in the same banks, selected
// by the TOP bits of the address: addr = {copy, y[4:0], x[4:BW]}. Because each bank
// is simple-dual-port, one copy can be written while a DIFFERENT copy is read in the
// same cycle - which is what lets the ISP->TSP handoff buffer live in ONE tile_ram
// instead of one instance per ping-pong half (see taginvw_tile_buffer).
//
module tile_ram #(
    parameter integer WIDTH  = 56,
    parameter integer NBANKS = 8,
    parameter integer COPIES = 1                // power-of-two tile images per bank
) (
    input                         clk,
    // WRITE port (lane i drives bank i)
    input      [NBANKS-1:0]       we,          // write-enable per bank
    input      [$clog2(COPIES*1024/NBANKS)*NBANKS-1:0] waddr,  // AW-bit write addr/bank
    input      [WIDTH*NBANKS-1:0] wdata,       // write data per bank (packed)
    // READ port (lane i drives bank i)
    input      [$clog2(COPIES*1024/NBANKS)*NBANKS-1:0] raddr,  // AW-bit read addr/bank
    output reg [WIDTH*NBANKS-1:0] rdata        // read data per bank (packed, 1-cyc)
);
    localparam integer DEPTH = COPIES * 1024 / NBANKS;  // 128 for 8 banks x1 copy
    localparam integer AW    = $clog2(COPIES * 1024 / NBANKS);  // 7 for 8 banks x1

    genvar b;
    generate
      for (b = 0; b < NBANKS; b = b + 1) begin : bank
        (* ramstyle = "M10K, no_rw_check" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
        wire [AW-1:0]    wa = waddr[AW*b +: AW];
        wire [AW-1:0]    ra = raddr[AW*b +: AW];
        wire [WIDTH-1:0] wd = wdata[WIDTH*b +: WIDTH];
        always @(posedge clk) begin
            if (we[b]) mem[wa] <= wd;
            rdata[WIDTH*b +: WIDTH] <= mem[ra];   // registered read (read-first)
        end
      end
    endgenerate
endmodule

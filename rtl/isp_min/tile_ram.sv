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
module tile_ram #(
    parameter integer WIDTH  = 56,
    parameter integer NBANKS = 8
) (
    input                         clk,
    // WRITE port (lane i drives bank i)
    input      [NBANKS-1:0]       we,          // write-enable per bank
    input      [7*NBANKS-1:0]     waddr,       // 7-bit write addr per bank (packed)
    input      [WIDTH*NBANKS-1:0] wdata,       // write data per bank (packed)
    // READ port (lane i drives bank i)
    input      [7*NBANKS-1:0]     raddr,       // 7-bit read addr per bank (packed)
    output reg [WIDTH*NBANKS-1:0] rdata        // read data per bank (packed, 1-cyc)
);
    localparam integer DEPTH = 1024 / NBANKS;  // 128 for 8 banks
    localparam integer AW    = 7;              // clog2(128)

    genvar b;
    generate
      for (b = 0; b < NBANKS; b = b + 1) begin : bank
        (* ramstyle = "M10K, no_rw_check" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
        wire [AW-1:0]    wa = waddr[7*b +: AW];
        wire [AW-1:0]    ra = raddr[7*b +: AW];
        wire [WIDTH-1:0] wd = wdata[WIDTH*b +: WIDTH];
        always @(posedge clk) begin
            if (we[b]) mem[wa] <= wd;
            rdata[WIDTH*b +: WIDTH] <= mem[ra];   // registered read (read-first)
        end
      end
    endgenerate
endmodule

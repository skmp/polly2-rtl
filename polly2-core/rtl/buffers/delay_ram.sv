//
// delay_ram - a fixed-latency delay line ("shift register") backed by an M10K
// block RAM instead of a chain of registers. Presents the SAME timing as a
// DELAY-deep register shift register: data written when `en` is high appears at
// `dout` exactly DELAY enabled clocks later. Frozen when `en` is low (global
// pipeline stall), so it composes with a clock-enabled pipeline.
//
// Why RAM instead of flops: for wide payloads carried through a multi-cycle
// alignment delay (e.g. the fp_rcp_fast latency realignment in tsp_shade_pp,
// which delays 960+ bits by 3), a register chain costs DELAY*WIDTH flops in ALM
// fabric. A single simple-dual-port M10K holds the same data in block RAM and
// frees the fabric.
//
// Implementation: a circular buffer. A write pointer advances each enabled clock
// and stores `din`; the read address trails it by DELAY. The M10K read is itself
// registered (1 cycle), so to land dout on the DELAY-th enabled clock we present
// read address (wptr - (DELAY-1)) combinationally and let the RAM's own read
// register supply the final cycle. Read-during-write to the same word cannot
// occur here because DELAY>=1 keeps read and write addresses distinct.
//
// CAVEAT ON DEPTH: block RAM is only a win when DELAY is deep enough to amortize
// the addressing overhead and when Quartus actually infers an M10K. Very shallow
// delays (DELAY<=2) are better left as flops - the fitter may keep them in
// registers regardless of the ramstyle hint. This module is intended for the
// wide, DELAY>=3 alignment lines.
//
// STYLE: MLAB, NOT M10K. These lines are WIDE and SHALLOW - the three instances in
// tsp_shade_v2_pp are 320 bits x 8 deep, i.e. 2,560 bits each. An M10K gives at most
// 40 bits of port width, so 320 bits forces EIGHT blocks (81,920 bits) to hold 2,560 -
// 3.1% utilisation, 24 blocks across the three. In MLABs (32x20, ~10 ALMs each) the
// same line is ceil(320/20) = 16 cells ~ 160 ALMs. The original "RAM frees the fabric"
// trade was written when M10K was plentiful; with block RAM at 92% and ALMs at 81% it
// points the other way. Still far cheaper than flops (DELAY*WIDTH = 2,560 per line).
//
module delay_ram #(
    parameter integer WIDTH = 32,
    parameter integer DELAY = 3,           // >= 1
    parameter         STYLE = "MLAB, no_rw_check"
) (
    input                    clk,
    input                    reset,
    input                    en,           // pipeline clock-enable (advance when high)
    input      [WIDTH-1:0]   din,
    output     [WIDTH-1:0]   dout
);
    // Round the ring buffer up to a power of two so the pointer wraps for free.
    // Need at least DELAY+1 slots so the read address never aliases the write.
    localparam integer NEED  = DELAY + 1;
    localparam integer AW    = (NEED <= 1) ? 1 : $clog2(NEED);
    localparam integer DEPTH = 1 << AW;

    (* ramstyle = STYLE *) reg [WIDTH-1:0] mem [0:DEPTH-1];

    reg  [AW-1:0] wptr;                    // next write slot
    // read address trails by DELAY-1; the RAM's registered read adds the last
    // cycle. Wraps modulo DEPTH (AW-bit) for free.
    wire [AW-1:0] raddr = wptr - AW'(DELAY-1);

    always @(posedge clk) begin
        if (reset) begin
            wptr <= '0;
        end else if (en) begin
            mem[wptr] <= din;
            wptr      <= wptr + 1'b1;
        end
    end

    // registered read, clock-enabled so it freezes with the rest of the pipe
    reg [WIDTH-1:0] rd_q;
    always @(posedge clk)
        if (en) rd_q <= mem[raddr];
    assign dout = rd_q;
endmodule

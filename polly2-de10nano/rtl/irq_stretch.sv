// irq_stretch.sv - stretch the rising edge of a done line (1-clk pulse or
// level) into a CYCLES-long active-high pulse for an edge-triggered
// interrupt consumer that samples asynchronously. On the Cyclone V
// f2h -> GIC path a 1-clk pulse at clk_sys could fall between GIC samples;
// ~64 cycles cannot.
//
// A rising edge of `in` during an ongoing stretch reloads the counter: the
// line stays high and the consumer sees a single edge (events coalesce).
// An edge after the stretch has drained starts a fresh pulse.
//
// `rst` kills an ongoing pulse and swallows edges while asserted, and the
// edge detector keeps tracking `in` through it - so a core being reset
// (whose state machines may glitch the done line) and a done held high
// across the reset release can't raise a spurious interrupt.

module irq_stretch
#(
	parameter CYCLES = 64          // pulse length, in clk cycles
)
(
	input  wire clk,
	input  wire rst,               // clear pulse + ignore edges while high
	input  wire in,                // level or pulse; rising edge triggers
	output wire irq                // high for CYCLES clocks after the edge
);

// no size casts (Quartus Standard 17.0)
/* verilator lint_off WIDTHTRUNC */
localparam [$clog2(CYCLES+1)-1:0] LOAD = CYCLES;
/* verilator lint_on WIDTHTRUNC */

reg [$clog2(CYCLES+1)-1:0] cnt = 0;
reg in_q = 1'b0;

always @(posedge clk) begin
	in_q <= in;                    // tracks through rst: no edge on release
	if (rst)             cnt <= 0;
	else if (in & ~in_q) cnt <= LOAD;
	else if (cnt != 0)   cnt <= cnt - 1'b1;
end

assign irq = (cnt != 0);

endmodule

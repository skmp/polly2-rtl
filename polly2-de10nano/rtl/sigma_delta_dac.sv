// First-order pulse-density DAC.  din is unsigned offset-binary; the MSB
// of the accumulator is the one-bit stream filtered by the analog board.
module sigma_delta_dac
#(
	parameter BITS = 16
)
(
	input  wire            clk,
	input  wire [BITS-1:0] din,
	output wire            dout
);
	reg [BITS:0] acc = {(BITS+1){1'b0}};
	wire [BITS:0] sum = {1'b0, acc[BITS-1:0]} + {1'b0, din};
	always @(posedge clk) acc <= sum;
	assign dout = acc[BITS];
endmodule

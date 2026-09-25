//----------------------------------------------------------
// Engineer: (c)2022 Walter Puccio
//
// Create Date:    2022
// Module Name:    Delta Sigma DAC - 3:rd order 16bit input
//   dac 0---/\/\/---+--------||---0 audio
//            1k5    |        10uF
//                  === 4.7nF
//                   |
//                  GND
//
// Clock rate => 4MHz will give clean 16bit audio
//----------------------------------------------------------
module sigma_delta_dac #(
    parameter int BSIZE = 15                   // DAC input bits (-1)
)(
    input  logic                     clk,
    input  logic signed [BSIZE:0]    din,      // two's complement input
    output logic                     dout      // 1 bit delta sigma output
);

    // Internal accumulators
    logic signed [BSIZE+4:0] SD1;
    logic signed [BSIZE+6:0] SD2;
    logic signed [BSIZE+7:0] SD3;

    // Feedback terms
    logic signed [BSIZE+4:0] FB1;
    logic signed [BSIZE+6:0] FB2;
    logic signed [BSIZE+7:0] FB3;

    // -------------------------------------------------------------------------
    // Feedback generation (combinational)
    // -------------------------------------------------------------------------
    always_comb begin
        if (SD3[BSIZE+7] == 1'b0) begin
            // Same as VHDL: negative feedback values
            FB1 = - (2  <<< BSIZE);
            FB2 = - (11 <<< BSIZE);
            FB3 = - (25 <<< BSIZE);
        end else begin
            // Same as VHDL: positive feedback values
            FB1 = + (2  <<< BSIZE);
            FB2 = + (11 <<< BSIZE);
            FB3 = + (25 <<< BSIZE);
        end
    end

    // -------------------------------------------------------------------------
    // Main ΔΣ loop
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
			// SD1 update
			SD1 <= SD1 + FB1 + $signed(din) - $signed(SD2[BSIZE+6:10]);

			// SD2 update
			SD2 <= SD2 + FB2 + $signed(SD1);

			// SD3 update
			SD3 <= SD3 + FB3 + $signed(SD2);

			// Output bit
			dout <= ~SD3[BSIZE+7];
    end

endmodule

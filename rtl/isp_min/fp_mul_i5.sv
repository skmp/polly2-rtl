//
// fp_mul_i5 - cheap float32 * small-integer multiply, y = f * k, k in 0..31.
//
// The rasterizer only ever multiplies the setup coefficients (DX/DY/ddx/ddy) by
// a tile-local pixel index x or y, which is a 5-bit integer (0..31). So instead
// of a full float*float multiply we do a 16-bit-mantissa * 5-bit-integer
// product: sig(1.15) * k(5b) -> 21 bits, then normalize (k<=31 -> <=5 bit
// growth) and adjust the exponent. Much cheaper than fp_mul16.
//
// Non-IEEE, matching the rest of the setup datapath: DaZ input, no inf/NaN,
// truncate, k==0 -> +0. Combinational.
//
module fp_mul_i5 (
    input  [31:0] f,
    input  [4:0]  k,
    output [31:0] y
);
    wire        sf = f[31];
    wire [7:0]  ef = f[30:23];
    wire        f_zero = (ef == 8'd0);          // DaZ
    wire        k_zero = (k == 5'd0);

    // 16-bit significand (1 hidden + 15) times 5-bit k -> up to 21 bits.
    wire [15:0] sig = {1'b1, f[22:8]};
    wire [20:0] prod = sig * {11'd0, k};         // 16 x 5 -> 21 bits

    // Normalize. sig has its leading 1 at bit15; multiplying by k in [1,31] adds
    // 0..5 bits, so the leading one is at bit 15..20 - only 6 possibilities.
    // Flatten the leading-one search + shift into a small priority mux (no
    // barrel shifter / general LZ loop): for a leading one at bit p, the 15
    // fraction bits are prod[p-1 -: 15] and the exponent gains (p-15).
    reg  [14:0] frac15;
    reg  [2:0]  sh;                              // 0..5
    always @(*) begin
        casez (prod[20:15])
            6'b1?????: begin frac15 = prod[19:5]; sh = 3'd5; end  // leading @20
            6'b01????: begin frac15 = prod[18:4]; sh = 3'd4; end  // @19
            6'b001???: begin frac15 = prod[17:3]; sh = 3'd3; end  // @18
            6'b0001??: begin frac15 = prod[16:2]; sh = 3'd2; end  // @17
            6'b00001?: begin frac15 = prod[15:1]; sh = 3'd1; end  // @16
            default:   begin frac15 = prod[14:0]; sh = 3'd0; end  // @15
        endcase
    end
    wire [22:0] mant = {frac15, 8'b0};           // 15 real frac bits, padded
    wire signed [10:0] e = $signed({3'b0, ef}) + $signed({8'b0, sh});

    wire is_zero  = f_zero | k_zero;
    wire overflow = (e >= 255);

    assign y = is_zero  ? {sf, 31'd0}
             : overflow ? {sf, 8'hFE, 23'h7FFFFF}
                        : {sf, e[7:0], mant};
endmodule

//
// fp_mul_c9 - cheap "colour * z" multiply for TSP setup.
//   y = f * k,  where f is a float (z, or a partial), k is a 9-bit SIGNED
//   integer (a vertex colour/offset channel, 0..255, sign for headroom).
//
// Per spec: 9-bit-signed * 16-bit-mantissa -> 16-bit-mantissa. Much cheaper
// than a float*float multiply: sig(1.15) * |k|(9b) -> 24 bits, normalize
// (|k|<=255 -> up to 8 extra bits), adjust exponent, apply sign.
//
// Non-IEEE, matching the datapath: DaZ input, no inf/NaN, truncate, k==0 -> +0.
// Combinational.
//
module fp_mul_c9 (
    input  [31:0] f,
    input  signed [8:0] k,      // 9-bit signed colour value
    output [31:0] y
);
    wire        sf = f[31];
    wire [7:0]  ef = f[30:23];
    wire        f_zero = (ef == 8'd0);          // DaZ
    wire        k_zero = (k == 9'sd0);
    wire        ksign  = k[8];
    wire [8:0]  kabs   = ksign ? (~k + 9'sd1) : k;   // |k|, 0..256

    // 16-bit significand * 9-bit magnitude -> up to 25 bits.
    wire [15:0] sig  = {1'b1, f[22:8]};
    wire [24:0] prod = sig * {16'd0, kabs};      // 16 x 9 -> 25 bits

    // leading one is between bit15 (k==1) and bit23 (k up to 256 -> bit24).
    reg  [4:0] msb;
    integer i;
    always @(*) begin
        msb = 5'd15;
        for (i = 15; i <= 24; i = i + 1)
            if (prod[i]) msb = i[4:0];
    end

    wire [5:0]  sh   = msb - 5'd15;              // 0..9
    wire [24:0] norm = prod >> sh;               // leading one -> bit15
    wire [22:0] mant = {norm[14:0], 8'b0};       // 15 real frac bits, padded

    wire signed [10:0] e = $signed({3'b0, ef}) + $signed({5'b0, sh});
    wire res_sign = sf ^ ksign;

    wire is_zero  = f_zero | k_zero;
    wire overflow = (e >= 255);

    assign y = is_zero  ? {res_sign, 31'd0}
             : overflow ? {res_sign, 8'hFE, 23'h7FFFFF}
                        : {res_sign, e[7:0], mant};
endmodule

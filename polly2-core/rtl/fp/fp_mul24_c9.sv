//
// fp_mul24_c9 - FULL-mantissa "colour * z" multiply for TSP setup.
//   y = f * k,  where f is a float (z, or a partial), k is a 9-bit SIGNED
//   integer (a vertex colour/offset channel, 0..255, sign for headroom).
//
// fp_mul_c9 with the 16-bit significand truncation removed: sig(1.23) * |k|(9b)
// -> 33 bits, normalize (|k| <= 256 -> up to 9 extra bits), adjust exponent,
// apply sign. The result keeps ALL 23 fractional bits (truncate below), where
// fp_mul_c9 kept only 15 and zero-padded.
//
// Non-IEEE, matching the datapath: DaZ input, no inf/NaN, truncate, k==0 -> +0.
// No underflow is possible (|k| >= 1 -> e = ef + sh >= ef >= 1). Combinational.
//
module fp_mul24_c9 (
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

    // full significand * 9-bit magnitude -> up to 33 bits.
    wire [23:0] sig  = {1'b1, f[22:0]};
    wire [32:0] prod = sig * {24'd0, kabs};      // 24 x 9 -> 33 bits

    // leading one is between bit23 (k==1) and bit32 (k==256).
    reg  [5:0] msb;
    integer i;
    always @(*) begin
        msb = 6'd23;
        for (i = 23; i <= 32; i = i + 1)
            if (prod[i]) msb = i[5:0];
    end

    wire [5:0]  sh   = msb - 6'd23;              // 0..9
    wire [32:0] norm = prod >> sh;               // leading one -> bit23
    wire [22:0] mant = norm[22:0];               // full 23 frac bits (truncate)

    wire signed [10:0] e = $signed({3'b0, ef}) + $signed({5'b0, sh});
    wire res_sign = sf ^ ksign;

    wire is_zero  = f_zero | k_zero;
    wire overflow = (e >= 255);

    assign y = is_zero  ? {res_sign, 31'd0}
             : overflow ? {res_sign, 8'hFE, 23'h7FFFFF}
                        : {res_sign, e[7:0], mant};
endmodule

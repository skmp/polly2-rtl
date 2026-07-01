//
// fp_mul16 - cheap, non-IEEE float32 multiply for the ISP setup datapath.
//
// Storage format is standard float32 {sign, 8b exp, 23b mant}, but the
// arithmetic is deliberately reduced:
//   - operands' mantissas are truncated to 16 bits (1 hidden + 15 stored) so
//     the core multiply is 16x16 -> 32, mapping to a SINGLE DSP (18x18) or
//     even logic. This is the "16-bit mantissa multiplicands" spec.
//   - DaZ: a zero biased-exponent operand is flushed to zero.
//   - No inf/NaN handling. No rounding (truncate). Overflow saturates the
//     exponent to 0xFE (max finite-ish), underflow flushes to signed zero.
//
// Combinational; the setup datapath registers the result.
//
module fp_mul16 (
    input  [31:0] a,
    input  [31:0] b,
    output [31:0] y
);
    wire        sa = a[31];
    wire        sb = b[31];
    wire [7:0]  ea = a[30:23];
    wire [7:0]  eb = b[30:23];

    wire a_zero = (ea == 8'd0);   // DaZ: subnormal/zero -> 0
    wire b_zero = (eb == 8'd0);

    // 16-bit significands: hidden 1 + top 15 mantissa bits (truncate the rest).
    wire [15:0] sig_a = {1'b1, a[22:8]};
    wire [15:0] sig_b = {1'b1, b[22:8]};

    wire res_sign = sa ^ sb;

    // 16x16 -> 32 product. Leading 1 lands at bit 30 (if <2) or bit 31 (if >=2).
    wire [31:0] prod = sig_a * sig_b;

    // exponent: ea + eb - bias
    wire signed [10:0] e_sum = $signed({3'b0, ea}) + $signed({3'b0, eb}) - 11'sd127;

    // product in [1,4): bit31 set means >=2 -> shift right 1, exp+1
    wire top = prod[31];
    // take 23 mantissa bits below the leading one (truncate, no rounding).
    // if top: leading 1 at bit31 -> mant = prod[30:8]
    // else  : leading 1 at bit30 -> mant = prod[29:7]
    wire [22:0] mant   = top ? prod[30:8] : prod[29:7];
    wire signed [10:0] e_adj = top ? (e_sum + 11'sd1) : e_sum;

    wire is_zero   = a_zero | b_zero;
    wire underflow = (e_adj <= 0);
    wire overflow  = (e_adj >= 255);

    assign y = is_zero   ? {res_sign, 31'd0}
             : underflow ? {res_sign, 31'd0}
             : overflow  ? {res_sign, 8'hFE, 23'h7FFFFF}   // saturate finite
                         : {res_sign, e_adj[7:0], mant};
endmodule

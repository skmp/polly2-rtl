//
// fp_mul24 - FULL-mantissa (1.23) non-IEEE float32 multiply for the setup datapaths.
//
// fp_mul16 with the significand truncation removed: full hidden-1 + 23-bit
// mantissas, 24x24 -> 48 product, result truncated back to 23 mantissa bits.
// On the Cyclone V target a 24x24 still fits ONE DSP block (27x27-native), so
// the "16-bit multiplicands" economy of fp_mul16 buys nothing there.
//   - DaZ: a zero biased-exponent operand is flushed to zero.
//   - No inf/NaN handling. No rounding (truncate). Overflow saturates the
//     exponent to 0xFE (max finite-ish), underflow flushes to signed zero.
//   - fp_mul16's x1.0 EXACT-PASSTHROUGH special case is GONE as dedicated logic
//     because at full precision it holds NATURALLY: |1.0|'s significand is
//     exactly 2^23, so prod = sig_other << 23 lands in [2^46,2^47) (top=0) and
//     the truncated mantissa is the other operand's mantissa unchanged, with
//     e_adj = e_other (which can neither overflow nor underflow for in-contract
//     non-inf/NaN inputs).
//
// Combinational; the setup datapath registers the result.
//
module fp_mul24 (
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

    // full significands: hidden 1 + all 23 mantissa bits.
    wire [23:0] sig_a = {1'b1, a[22:0]};
    wire [23:0] sig_b = {1'b1, b[22:0]};

    wire res_sign = sa ^ sb;

    // 24x24 -> 48 product. Leading 1 lands at bit 46 (if <2) or bit 47 (if >=2).
    wire [47:0] prod = sig_a * sig_b;

    // exponent: ea + eb - bias
    wire signed [10:0] e_sum = $signed({3'b0, ea}) + $signed({3'b0, eb}) - 11'sd127;

    // product in [1,4): bit47 set means >=2 -> shift right 1, exp+1
    wire top = prod[47];
    // take 23 mantissa bits below the leading one (truncate, no rounding).
    // if top: leading 1 at bit47 -> mant = prod[46:24]
    // else  : leading 1 at bit46 -> mant = prod[45:23]
    wire [22:0] mant   = top ? prod[46:24] : prod[45:23];
    wire signed [10:0] e_adj = top ? (e_sum + 11'sd1) : e_sum;

    wire is_zero   = a_zero | b_zero;
    wire underflow = (e_adj <= 0);
    wire overflow  = (e_adj >= 255);

    assign y = is_zero   ? {res_sign, 31'd0}
             : underflow ? {res_sign, 31'd0}
             : overflow  ? {res_sign, 8'hFE, 23'h7FFFFF}   // saturate finite
                         : {res_sign, e_adj[7:0], mant};
endmodule

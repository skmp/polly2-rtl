//
// fp_add3_24 - bespoke 3-input non-IEEE float32 adder: y = a + b + c.
//
// Folds what used to be two dependent fp_add24 stages (i2: prx+pry, i3: +c) into
// ONE alignment + ONE normalization. All three operands are aligned to the largest
// exponent, summed as signed sign-magnitude significands, then normalized/packed
// once. This removes an intermediate round/normalize (slightly more accurate) and,
// pipelined, saves an interpolator substage.
//
// Same reduced-precision conventions as fp_add24:
//   - DaZ: a zero biased-exponent operand contributes 0.
//   - No inf/NaN. Truncate (no rounding). Overflow saturates, underflow flushes.
//   - sign-magnitude significands, single guard of extra integer headroom.
//
// Precision note vs chaining two fp_add24: aligning all three to the common max
// exponent then summing is at least as good as (a+b) rounded, then +c; the single
// normalize avoids one intermediate truncation.
//
// Split into s1 (align+sum) / s2 (normalize+pack) so callers can pipeline; the
// combinational whole (fp_add3_24) chains them for a 1-cycle fat step.
//
// ---- stage 1: align three operands to the max exponent, signed sum ----
module fp_add3_24_s1 (
    input  [31:0] a,
    input  [31:0] b,
    input  [31:0] c,
    output signed [27:0] ssum,   // signed pre-normalize sum (2's comp)
    output        [7:0]  e_max   // common (largest) exponent operands aligned to
);
    // decode: DaZ (biased-exp 0 -> significand 0 so it adds nothing)
    wire sa = a[31], sb = b[31], sc = c[31];
    wire [7:0] ea = a[30:23], eb = b[30:23], ec = c[30:23];
    wire za = (ea == 8'd0), zb = (eb == 8'd0), zc = (ec == 8'd0);

    wire [23:0] sig_a = za ? 24'd0 : {1'b1, a[22:0]};
    wire [23:0] sig_b = zb ? 24'd0 : {1'b1, b[22:0]};
    wire [23:0] sig_c = zc ? 24'd0 : {1'b1, c[22:0]};
    // effective exponents (flushed operands treated as the min so they never win max)
    wire [7:0]  exa = za ? 8'd0 : ea;
    wire [7:0]  exb = zb ? 8'd0 : eb;
    wire [7:0]  exc = zc ? 8'd0 : ec;

    // max exponent of the three
    wire [7:0] e_ab  = (exa >= exb) ? exa : exb;
    assign     e_max = (e_ab >= exc) ? e_ab : exc;

    // align each significand right by (e_max - its exp); >=24 shifts to 0
    wire [7:0] sha = e_max - exa;
    wire [7:0] shb = e_max - exb;
    wire [7:0] shc = e_max - exc;
    wire [23:0] al_a = (sha >= 8'd24) ? 24'd0 : (sig_a >> sha);
    wire [23:0] al_b = (shb >= 8'd24) ? 24'd0 : (sig_b >> shb);
    wire [23:0] al_c = (shc >= 8'd24) ? 24'd0 : (sig_c >> shc);

    // signed contributions (sign-magnitude -> 2's complement). 28 bits: 24 mag +
    // sign + headroom for summing three (up to ~3x -> +2 integer bits).
    wire signed [27:0] va = sa ? -$signed({4'b0, al_a}) : $signed({4'b0, al_a});
    wire signed [27:0] vb = sb ? -$signed({4'b0, al_b}) : $signed({4'b0, al_b});
    wire signed [27:0] vc = sc ? -$signed({4'b0, al_c}) : $signed({4'b0, al_c});
    assign ssum = va + vb + vc;
endmodule

// ---- stage 2: sign/abs, normalize (leading-zero), pack ----
module fp_add3_24_s2 (
    input  signed [27:0] ssum,
    input         [7:0]  e_max,
    output        [31:0] y
);
    wire        s_res = ssum[27];                 // result sign
    wire [26:0] mag   = s_res ? (~ssum[26:0] + 27'd1) : ssum[26:0];  // |sum|, 27b

    // The aligned significands have their leading 1 at bit 23. Summing three can
    // carry up to bit 25 (3 * ~2^24 < 2^26). Normalize: find the leading 1 in mag
    // and set the exponent = e_max + (leadingbit - 23).
    reg  [23:0] norm_sig;
    reg  signed [10:0] e_norm;
    integer i; reg found;
    always @(*) begin
        norm_sig = 24'd0;
        e_norm   = $signed({3'b0, e_max});
        found    = 1'b0;
        // check high headroom bits first (carry-outs above bit 23), then bit 23,
        // then leading-zero search downward for cancellation.
        if (mag[26]) begin
            norm_sig = mag[26:3];                 // take 24 bits below leading 1
            e_norm   = $signed({3'b0, e_max}) + 11'sd3;
            found    = 1'b1;
        end else if (mag[25]) begin
            norm_sig = mag[25:2];
            e_norm   = $signed({3'b0, e_max}) + 11'sd2;
            found    = 1'b1;
        end else if (mag[24]) begin
            norm_sig = mag[24:1];
            e_norm   = $signed({3'b0, e_max}) + 11'sd1;
            found    = 1'b1;
        end else if (mag[23]) begin
            norm_sig = mag[23:0];
            e_norm   = $signed({3'b0, e_max});
            found    = 1'b1;
        end else begin
            // cancellation: leading 1 below bit 23 -> shift left, lower exponent
            for (i = 1; i < 24; i = i + 1)
                if (!found && mag[23-i]) begin
                    norm_sig = mag[23:0] << i;
                    e_norm   = $signed({3'b0, e_max}) - i;
                    found    = 1'b1;
                end
        end
    end

    wire res_zero  = (mag == 27'd0);
    wire underflow = (e_norm <= 0);
    wire overflow  = (e_norm >= 255);
    assign y = res_zero  ? 32'd0
             : underflow ? {s_res, 31'd0}
             : overflow  ? {s_res, 8'hFE, 23'h7FFFFF}
                         : {s_res, e_norm[7:0], norm_sig[22:0]};
endmodule

// ---- combinational whole (1-cycle fat step: a + b + c) ----
module fp_add3_24 (
    input  [31:0] a,
    input  [31:0] b,
    input  [31:0] c,
    output [31:0] y
);
    wire signed [27:0] ssum; wire [7:0] e_max;
    fp_add3_24_s1 s1 (.a(a), .b(b), .c(c), .ssum(ssum), .e_max(e_max));
    fp_add3_24_s2 s2 (.ssum(ssum), .e_max(e_max), .y(y));
endmodule

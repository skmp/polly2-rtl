//
// fp_add24 - cheap, non-IEEE float32 add/sub for the setup datapath.
// Split into two combinational halves so callers can pipeline it:
//   fp_add24_s1 : sign-fix, DaZ, order, exp-diff, align-shift, add/sub -> {sum,e_big,s_big}
//   fp_add24_s2 : normalize (leading-zero) + pack -> y
// fp_add24 is the combinational whole (s1 -> s2) for callers that don't pipeline.
//
// Non-IEEE: DaZ, no inf/NaN, truncate, overflow saturates / underflow flushes.
//
// ---- stage 1: align + add/sub ----
module fp_add24_s1 (
    input  [31:0] a,
    input  [31:0] b_in,
    input         sub,
    output [24:0] sum,      // pre-normalize significand sum (bit24 = carry)
    output [7:0]  e_big,    // exponent of the larger operand
    output        s_big     // sign of the result (larger operand's sign)
);
    wire [31:0] b = sub ? {~b_in[31], b_in[30:0]} : b_in;
    wire       sa = a[31],  sb = b[31];
    wire [7:0] ea = a[30:23], eb = b[30:23];

    wire [23:0] sig_a = {(ea != 8'd0), a[22:0]};
    wire [23:0] sig_b = {(eb != 8'd0), b[22:0]};
    wire [7:0]  exa   = (ea == 8'd0) ? 8'd1 : ea;
    wire [7:0]  exb   = (eb == 8'd0) ? 8'd1 : eb;

    wire        a_ge  = (exa > exb) || ((exa == exb) && (sig_a >= sig_b));
    wire [23:0] sig_big = a_ge ? sig_a : sig_b;
    wire [23:0] sig_sml = a_ge ? sig_b : sig_a;
    wire        s_sml   = a_ge ? sb : sa;
    wire [7:0]  e_sml_e = a_ge ? exb : exa;
    wire [7:0]  shamt   = e_big - e_sml_e;

    assign e_big = a_ge ? exa : exb;
    assign s_big = a_ge ? sa : sb;

    wire [23:0] sml_sh = (shamt >= 8'd24) ? 24'd0 : (sig_sml >> shamt);
    wire same_sign = (s_big == s_sml);
    assign sum = same_sign ? ({1'b0, sig_big} + {1'b0, sml_sh})
                           : ({1'b0, sig_big} - {1'b0, sml_sh});
endmodule

// ---- stage 2: normalize + pack ----
module fp_add24_s2 (
    input  [24:0] sum,
    input  [7:0]  e_big,
    input         s_big,
    output [31:0] y
);
    reg  [23:0] norm_sig;
    reg  signed [10:0] e_norm;
    integer i; reg found;
    always @(*) begin
        found = 1'b0;
        if (sum[24]) begin
            norm_sig = sum[24:1];
            e_norm   = $signed({3'b0, e_big}) + 11'sd1;
        end else if (sum[23]) begin
            norm_sig = sum[23:0];
            e_norm   = $signed({3'b0, e_big});
        end else begin
            norm_sig = sum[23:0];
            e_norm   = $signed({3'b0, e_big});
            for (i = 1; i < 24; i = i + 1)
                if (!found && sum[23-i]) begin
                    norm_sig = sum[23:0] << i;
                    e_norm   = $signed({3'b0, e_big}) - i;
                    found    = 1'b1;
                end
        end
    end
    wire res_zero  = (sum == 25'd0);
    wire underflow = (e_norm <= 0);
    wire overflow  = (e_norm >= 255);
    assign y = res_zero  ? 32'd0
             : underflow ? {s_big, 31'd0}
             : overflow  ? {s_big, 8'hFE, 23'h7FFFFF}
                         : {s_big, e_norm[7:0], norm_sig[22:0]};
endmodule

// ---- combinational whole (for non-pipelined callers) ----
module fp_add24 (
    input  [31:0] a,
    input  [31:0] b_in,
    input         sub,
    output [31:0] y
);
    wire [24:0] sum; wire [7:0] e_big; wire s_big;
    fp_add24_s1 s1 (.a(a), .b_in(b_in), .sub(sub), .sum(sum), .e_big(e_big), .s_big(s_big));
    fp_add24_s2 s2 (.sum(sum), .e_big(e_big), .s_big(s_big), .y(y));
endmodule

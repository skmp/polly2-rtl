//
// fp_add24 - cheap, non-IEEE float32 add/sub for the ISP setup datapath.
//
// Standard float32 storage. ~24-bit significand path (1 hidden + 23 stored,
// no extra guard/round/sticky) - the "~24-bit mantissa for the addition / A
// factor" spec. Reduced arithmetic:
//   - DaZ: zero biased-exponent operand treated as zero.
//   - No inf/NaN. No rounding (truncate after the shift/normalize).
//   - Overflow saturates exponent; underflow flushes to signed zero.
//
// Combinational; the setup datapath registers the result.
//
module fp_add24 (
    input  [31:0] a,
    input  [31:0] b_in,
    input         sub,       // when 1, compute a - b_in
    output [31:0] y
);
    wire [31:0] b = sub ? {~b_in[31], b_in[30:0]} : b_in;

    wire       sa = a[31];
    wire       sb = b[31];
    wire [7:0] ea = a[30:23];
    wire [7:0] eb = b[30:23];

    // DaZ significands (hidden bit 0 when exp==0 -> value 0)
    wire [23:0] sig_a = {(ea != 8'd0), a[22:0]};
    wire [23:0] sig_b = {(eb != 8'd0), b[22:0]};
    wire [7:0]  exa   = (ea == 8'd0) ? 8'd1 : ea;
    wire [7:0]  exb   = (eb == 8'd0) ? 8'd1 : eb;

    // order by magnitude
    wire        a_ge  = (exa > exb) || ((exa == exb) && (sig_a >= sig_b));
    wire [7:0]  e_big = a_ge ? exa : exb;
    wire        s_big = a_ge ? sa : sb;
    wire        s_sml = a_ge ? sb : sa;
    wire [23:0] sig_big = a_ge ? sig_a : sig_b;
    wire [23:0] sig_sml = a_ge ? sig_b : sig_a;

    wire [7:0]  e_sml_e = a_ge ? exb : exa;
    wire [7:0]  shamt   = e_big - e_sml_e;

    // shift smaller right (truncate, no sticky)
    wire [23:0] sml_sh = (shamt >= 8'd24) ? 24'd0 : (sig_sml >> shamt);

    wire same_sign = (s_big == s_sml);
    wire [24:0] sum = same_sign ? ({1'b0, sig_big} + {1'b0, sml_sh})
                                : ({1'b0, sig_big} - {1'b0, sml_sh});

    // normalize. sum has at most bit24 (carry on add) down to all-zero.
    // find leading-one position for the subtract case; add case only needs 1 step.
    reg  [23:0] norm_sig;
    reg  signed [10:0] e_norm;
    integer i;
    reg found;
    always @(*) begin
        found = 1'b0;
        if (sum[24]) begin
            // carry out: shift right 1, exp+1 (add case)
            norm_sig = sum[24:1];
            e_norm   = $signed({3'b0, e_big}) + 11'sd1;
        end else if (sum[23]) begin
            norm_sig = sum[23:0];
            e_norm   = $signed({3'b0, e_big});
        end else begin
            // subtract produced a leading-zero result: left-normalize.
            norm_sig = sum[23:0];
            e_norm   = $signed({3'b0, e_big});
            found = 1'b0;
            for (i = 1; i < 24; i = i + 1) begin
                if (!found && sum[23-i]) begin
                    norm_sig = sum[23:0] << i;
                    e_norm   = $signed({3'b0, e_big}) - i;
                    found    = 1'b1;
                end
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

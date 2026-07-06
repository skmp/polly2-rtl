//
// fp_mul16_pp - PIPELINED variant of fp_mul16: y = a * b.
//
// Same reduced-precision math as fp_mul16 (16-bit-mantissa float multiply, non-IEEE:
// DaZ, no inf/NaN, truncate, overflow saturates, underflow flushes), split so it
// clocks past 120 MHz. The combinational fp_mul16 stays for the other (setup/raster)
// users; this one is for the streamed interp_unit (i3).
//
// CONVENTION: this module does NOT register its inputs or its output. The single
// internal register holds the multiply product; the normalize/pack after it is
// COMBINATIONAL, driving y/out_valid directly. The WRAPPING module registers the
// inputs and the output.
//
//   (comb) prod = sig_a(16) * sig_b(16)   -- off module inputs
//   [REG]  s1_prod + e_sum/sign/zero
//   (comb) normalize (top-bit -> mant/exp) + under/overflow + pack -> y ; out_valid = v1
//
// HOLD (backpressure): lives in tsp_shade_pp's `en`-gated front. Takes `stall`
// (fp_rcp_fast convention): stall=1 freezes the internal register. in_valid ->
// out_valid.
//
// The 16x16 product is DSP-eligible (no multstyle override).
//
module fp_mul16_pp (
    input             clk,
    input             reset,
    input             stall,
    input             in_valid,
    input      [31:0] a,
    input      [31:0] b,
    output            out_valid,
    output     [31:0] y
);
    // ---- combinational front of S1: decode + product ----
    wire        sa = a[31], sb = b[31];
    wire [7:0]  ea = a[30:23], eb = b[30:23];
    wire        a_zero = (ea == 8'd0);   // DaZ
    wire        b_zero = (eb == 8'd0);

    wire [15:0] sig_a = {1'b1, a[22:8]};
    wire [15:0] sig_b = {1'b1, b[22:8]};
    wire [31:0] prod_c = sig_a * sig_b;                  // 16x16 -> 32
    wire signed [10:0] e_sum_c = $signed({3'b0, ea}) + $signed({3'b0, eb}) - 11'sd127;

    // ================= internal REGISTER : product + carried decode ===============
    reg               v1;
    reg        [31:0] s1_prod;
    reg signed [10:0] s1_esum;
    reg               s1_sign, s1_zero;
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else if (!stall) begin
            v1      <= in_valid;
            s1_prod <= prod_c;
            s1_esum <= e_sum_c;
            s1_sign <= sa ^ sb;
            s1_zero <= a_zero | b_zero;
        end
    end

    // ================= COMBINATIONAL : normalize + pack ==========================
    // product in [1,4): bit31 set means >=2 -> shift right 1, exp+1. Take 23 mantissa
    // bits below the leading one (truncate).
    wire        top    = s1_prod[31];
    wire [22:0] mant   = top ? s1_prod[30:8] : s1_prod[29:7];
    wire signed [10:0] e_adj = top ? (s1_esum + 11'sd1) : s1_esum;
    wire underflow = (e_adj <= 0);
    wire overflow  = (e_adj >= 255);

    assign y = s1_zero   ? {s1_sign, 31'd0}
             : underflow ? {s1_sign, 31'd0}
             : overflow  ? {s1_sign, 8'hFE, 23'h7FFFFF}
                         : {s1_sign, e_adj[7:0], mant};
    assign out_valid = v1;
endmodule

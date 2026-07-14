//
// fp_mul16_spp_ro - STREAMING PIPELINED, REGISTERED-OUTPUT variant of fp_mul16.
//
// Same reduced-precision math as the combinational fp_mul16 (16-bit-mantissa non-IEEE
// multiply: DaZ, no inf/NaN, truncate, overflow saturates, underflow flushes, and the
// exact +/-1.0 passthrough that keeps a *1.0 operand full-precision) - but split into a
// 2-clock streaming pipeline whose OUTPUT is registered, so a driver just presents
// inputs and reads y two clocks later with no combinational tail hanging off y.
//
// This is BIT-EXACT to fp_mul16 for the same (a,b): identical decode, product slice,
// and special-case mux, only clocked. (The older fp_mul16_pp is a DIFFERENT contract -
// one internal register, combinational I/O, and it DROPPED the +1.0 passthrough - so it
// is neither registered-output nor bit-exact. This module is the clean replacement.)
//
// CONVENTION (matches fp_rcp_fast / this file's streaming units):
//   ports (clk, reset, stall, in_valid, a, b, out_valid, y).
//   in_valid @N  ->  out_valid @N+2, y @N+2 (both registered).
//   stall=1 freezes every stage (hold). one result/clock throughput when !stall.
//
// Pipeline:
//   (comb, off inputs) decode + 16x16 product + special flags
//   [S1 REG] product(32) + e_sum(11s) + sign + zero + a_one/b_one + pass operands
//   (comb)   normalize/pack from S1 regs
//   [S2 REG] y  <- packed result ; out_valid <- v1
//
module fp_mul16_spp_ro (
    input             clk,
    input             reset,
    input             stall,
    input             in_valid,
    input      [31:0] a,
    input      [31:0] b,
    output reg        out_valid,
    output reg [31:0] y
);
    // ---- combinational front (off module inputs), same as fp_mul16 ----
    wire        sa = a[31], sb = b[31];
    wire [7:0]  ea = a[30:23], eb = b[30:23];
    wire        a_zero = (ea == 8'd0);      // DaZ
    wire        b_zero = (eb == 8'd0);

    // exact +1.0 passthrough: |operand| == 1.0 (exp 127, mant 0).
    wire a_one = (a[30:0] == 31'h3F800000);
    wire b_one = (b[30:0] == 31'h3F800000);

    // 16-bit significands: hidden 1 + top 15 mantissa bits (truncate the rest).
    wire [15:0] sig_a = {1'b1, a[22:8]};
    wire [15:0] sig_b = {1'b1, b[22:8]};

    wire        res_sign_c = sa ^ sb;
    wire [31:0] prod_c     = sig_a * sig_b;   // 16x16 -> 32
    wire signed [10:0] e_sum_c = $signed({3'b0, ea}) + $signed({3'b0, eb}) - 11'sd127;

    // ================= S1 REGISTER: product + carried decode =================
    reg               v1;
    reg        [31:0] s1_prod;
    reg signed [10:0] s1_esum;
    reg               s1_sign, s1_zero, s1_a1, s1_b1;
    reg        [30:0] s1_amag, s1_bmag;       // |a|,|b| for the passthrough paths
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else if (!stall) begin
            v1      <= in_valid;
            s1_prod <= prod_c;
            s1_esum <= e_sum_c;
            s1_sign <= res_sign_c;
            s1_zero <= a_zero | b_zero;
            s1_a1   <= a_one;
            s1_b1   <= b_one;
            s1_amag <= a[30:0];
            s1_bmag <= b[30:0];
        end
    end

    // ================= combinational normalize + pack from S1 ================
    wire        top   = s1_prod[31];
    wire [22:0] mant  = top ? s1_prod[30:8] : s1_prod[29:7];
    wire signed [10:0] e_adj = top ? (s1_esum + 11'sd1) : s1_esum;
    wire underflow = (e_adj <= 0);
    wire overflow  = (e_adj >= 255);

    // pass the OTHER operand through untruncated when this one is exactly |1.0|.
    wire [31:0] pass_b = {s1_sign, s1_bmag};   // a==1.0 -> y = +/- b
    wire [31:0] pass_a = {s1_sign, s1_amag};   // b==1.0 -> y = +/- a

    wire [31:0] y_c = s1_zero   ? {s1_sign, 31'd0}
                    : s1_a1     ? pass_b
                    : s1_b1     ? pass_a
                    : underflow ? {s1_sign, 31'd0}
                    : overflow  ? {s1_sign, 8'hFE, 23'h7FFFFF}
                                : {s1_sign, e_adj[7:0], mant};

    // ================= S2 REGISTER: the module's registered output ==========
    always @(posedge clk) begin
        if (reset) out_valid <= 1'b0;
        else if (!stall) begin
            out_valid <= v1;
            y         <= y_c;
        end
    end
endmodule

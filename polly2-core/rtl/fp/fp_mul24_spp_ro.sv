//
// fp_mul24_spp_ro - STREAMING PIPELINED, REGISTERED-OUTPUT variant of fp_mul24.
//
// FULL-mantissa (1.23) drop-in replacement for fp_mul16_spp_ro: same non-IEEE
// contract (DaZ, no inf/NaN, truncate, overflow saturates, underflow flushes) but
// the significands are NOT truncated - 24x24 -> 48 product, result truncated back
// to 23 mantissa bits. Same port list and 2-clock latency, so the
// isp_setup_streamed / tsp_setup_stream schedules are unchanged (L=2).
//
// fp_mul16_spp_ro's +/-1.0 exact-passthrough special case is GONE: at full
// precision a *1.0 multiply is exact through the NORMAL path (see the fp_mul24
// header), so the two 31-bit compares and the 2x31-bit operand-carry registers
// are simply not spent. S1 is NARROWER than fp_mul16_spp_ro's despite the wider
// product (61 vs 109 flops).
//
// BIT-EXACT to the combinational fp_mul24 for the same (a,b), only clocked.
//
// CONVENTION (matches the other *_spp_ro units):
//   ports (clk, reset, stall, in_valid, a, b, out_valid, y).
//   in_valid @N  ->  out_valid @N+2, y @N+2 (both registered).
//   stall=1 freezes every stage (hold). one result/clock throughput when !stall.
//
// Pipeline:
//   (comb, off inputs) decode + 24x24 product + zero flags
//   [S1 REG] product(48) + e_sum(11s) + sign + zero
//   (comb)   normalize/pack from S1 regs
//   [S2 REG] y  <- packed result ; out_valid <- v1
//
module fp_mul24_spp_ro (
    input             clk,
    input             reset,
    input             stall,
    input             in_valid,
    input      [31:0] a,
    input      [31:0] b,
    output reg        out_valid,
    output reg [31:0] y
);
    // ---- combinational front (off module inputs), same as fp_mul24 ----
    wire        sa = a[31], sb = b[31];
    wire [7:0]  ea = a[30:23], eb = b[30:23];
    wire        a_zero = (ea == 8'd0);      // DaZ
    wire        b_zero = (eb == 8'd0);

    // full significands: hidden 1 + all 23 mantissa bits.
    wire [23:0] sig_a = {1'b1, a[22:0]};
    wire [23:0] sig_b = {1'b1, b[22:0]};

    wire        res_sign_c = sa ^ sb;
    wire [47:0] prod_c     = sig_a * sig_b;   // 24x24 -> 48
    wire signed [10:0] e_sum_c = $signed({3'b0, ea}) + $signed({3'b0, eb}) - 11'sd127;

    // ================= S1 REGISTER: product + carried decode =================
    reg               v1;
    reg        [47:0] s1_prod;
    reg signed [10:0] s1_esum;
    reg               s1_sign, s1_zero;
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else if (!stall) begin
            v1      <= in_valid;
            s1_prod <= prod_c;
            s1_esum <= e_sum_c;
            s1_sign <= res_sign_c;
            s1_zero <= a_zero | b_zero;
        end
    end

    // ================= combinational normalize + pack from S1 ================
    wire        top   = s1_prod[47];
    wire [22:0] mant  = top ? s1_prod[46:24] : s1_prod[45:23];
    wire signed [10:0] e_adj = top ? (s1_esum + 11'sd1) : s1_esum;
    wire underflow = (e_adj <= 0);
    wire overflow  = (e_adj >= 255);

    wire [31:0] y_c = s1_zero   ? {s1_sign, 31'd0}
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

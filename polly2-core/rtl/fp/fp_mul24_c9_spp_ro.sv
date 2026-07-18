//
// fp_mul24_c9_spp_ro - STREAMING PIPELINED, REGISTERED-OUTPUT variant of fp_mul24_c9.
//   y = f * k, f float32 (full 1.23 significand), k 9-bit SIGNED colour/offset channel.
//
// FULL-mantissa drop-in replacement for fp_mul_c9_spp_ro (same ports, same 2-clock
// latency): the significand is not truncated to 16 bits and the result keeps all
// 23 fractional bits. Latency stays matched to fp_mul24_spp_ro - the two sit side
// by side as the per-vertex attribute "prime" units in tsp_setup_stream, and a
// uniform 2-clock prime keeps that schedule kind-agnostic (uv vs colour planes).
//
// BIT-EXACT to the combinational fp_mul24_c9 for the same (f, k), only clocked.
//
// CONVENTION (matches the other *_spp_ro units):
//   ports (clk, reset, stall, in_valid, f, k, out_valid, y).
//   in_valid @N -> out_valid @N+2, y @N+2 (both registered).
//   stall=1 freezes every stage. one result/clock throughput when !stall.
//
// Pipeline:
//   (comb, off inputs) decode + |k| + 24x9 product + msb(|k|) (9-bit priority - cheap)
//   [S1 REG] prod(33) + mk(4) + ef + sign + zero flags
//   (comb)   normalize + pack. The product's leading 1 is at mk+23 or mk+24 (sig is in
//            [2^23,2^24), |k| in [2^mk,2^(mk+1)) -> prod in [2^(mk+23),2^(mk+25))), so
//            S2 tests ONE product bit instead of running a 10-way priority scan over
//            the 33-bit product (same Fmax fix as fp_mul_c9_spp_ro).
//   [S2 REG] y ; out_valid
//
module fp_mul24_c9_spp_ro (
    input               clk,
    input               reset,
    input               stall,
    input               in_valid,
    input        [31:0] f,
    input  signed [8:0] k,      // 9-bit signed colour value
    output reg          out_valid,
    output reg   [31:0] y
);
    // ---- combinational front (off module inputs), same as fp_mul24_c9 ----
    wire        sf = f[31];
    wire [7:0]  ef = f[30:23];
    wire        f_zero = (ef == 8'd0);               // DaZ
    wire        k_zero = (k == 9'sd0);
    wire        ksign  = k[8];
    wire [8:0]  kabs   = ksign ? (~k + 9'sd1) : k;   // |k|, 0..256

    wire [23:0] sig    = {1'b1, f[22:0]};
    wire [32:0] prod_c = sig * {24'd0, kabs};        // 24 x 9 -> 33 bits

    // msb(|k|): 9-bit priority encode (0..8), computed in parallel with the product.
    reg [3:0] mk_c;
    integer ki;
    always @(*) begin
        mk_c = 4'd0;
        for (ki = 0; ki <= 8; ki = ki + 1)
            if (kabs[ki]) mk_c = ki[3:0];
    end

    // ================= S1 REGISTER: product + carried decode =================
    reg        v1;
    reg [32:0] s1_prod;
    reg [3:0]  s1_mk;
    reg [7:0]  s1_ef;
    reg        s1_sign, s1_zero;
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else if (!stall) begin
            v1      <= in_valid;
            s1_prod <= prod_c;
            s1_mk   <= mk_c;
            s1_ef   <= ef;
            s1_sign <= sf ^ ksign;
            s1_zero <= f_zero | k_zero;
        end
    end

    // ================= combinational normalize + pack from S1 ================
    // leading one is at mk+23 or mk+24; one bit test picks which (see header).
    wire [5:0]  hi_bit = {2'b0, s1_mk} + 6'd24;      // candidate upper position
    wire        top    = s1_prod[hi_bit];            // set -> msb = mk+24
    wire [5:0]  sh     = {2'b0, s1_mk} + (top ? 6'd1 : 6'd0);   // 0..9
    wire [32:0] norm   = s1_prod >> sh;              // leading one -> bit23
    wire [22:0] mant   = norm[22:0];                 // full 23 frac bits (truncate)

    wire signed [10:0] e = $signed({3'b0, s1_ef}) + $signed({5'b0, sh});
    wire overflow = (e >= 255);

    wire [31:0] y_c = s1_zero   ? {s1_sign, 31'd0}
                    : overflow  ? {s1_sign, 8'hFE, 23'h7FFFFF}
                                : {s1_sign, e[7:0], mant};

    // ================= S2 REGISTER: the module's registered output ==========
    always @(posedge clk) begin
        if (reset) out_valid <= 1'b0;
        else if (!stall) begin
            out_valid <= v1;
            y         <= y_c;
        end
    end
endmodule

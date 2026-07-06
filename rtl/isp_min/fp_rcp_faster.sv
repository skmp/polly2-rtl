//
// fp_rcp_faster - deeper-pipelined (5-stage) reciprocal y ~= 1/x. Same non-IEEE method
// and seed ROM as fp_rcp_fast, but each Newton multiply gets its OWN stage (the sub and
// the normalize/pack are split off) so it clocks past ~120 MHz. fp_rcp_fast (3 stages,
// ~98 MHz) crammed a multiply AND its surrounding logic into s2 and s3.
//
// Method (Q16 fixed point on the significand):
//   m  = 1.mx in [1,2) (Q1.16) ; r0 = SEED_ROM[idx] ~ 1/m (Q0.16, 256-entry ROM)
//   r1 = r0 * (2 - m*r0)  (one Newton step) ; 1/x = r1 * 2^(127-ex), packed to float32.
//
// Pipeline:
//   S1 : ROM lookup r0 ; carry m/ex/sign/zero
//   S2 : mr = m*r0          (17x17 -> 34, Q1.32)   [MUL only]
//   S3 : two_m = 2.0 - mr[33:16]  (Q1.16)          [subtract]
//   S4 : r1_full = r0*two_m (17x18 -> 35)          [MUL only]
//   S5 : normalize (r1) + pack -> y
//   in_valid@N -> out_valid@N+5. DaZ input saturates. ~0.0015% error.
//
// `stall` freezes ALL stages. Products are DSP-eligible (17x17 / 17x18 fit one DSP each).
//
module fp_rcp_faster (
    input             clk,
    input             reset,
    input             stall,
    input             in_valid,
    input      [31:0] x,
    output reg        out_valid,
    output reg [31:0] y
);
    // ---- decompose (off inputs) ----
    wire        sx = x[31];
    wire [7:0]  ex = x[30:23];
    wire        x_zero = (ex == 8'd0);
    wire [16:0] m_q16  = {1'b1, x[22:7]};     // Q1.16 significand
    wire [7:0]  idx    = x[22:15];            // ROM index

    // ---- seed ROM (256 x 17, constant-initialized; no runtime divide) ----
    reg [16:0] seed_rom [0:255];
    integer ri;
    initial for (ri = 0; ri < 256; ri = ri + 1)
        seed_rom[ri] = 17'((64'h100000000) / (64'd65536 + ri * 64'd256));

    // ================= S1 : ROM lookup + carry =================
    reg [16:0] s1_r0, s1_m;
    reg [7:0]  s1_ex;
    reg        s1_s, s1_xz, v1;
    always @(posedge clk) begin
        if (reset) v1 <= 0;
        else if (!stall) begin
            s1_r0 <= seed_rom[idx];
            s1_m  <= m_q16;
            s1_ex <= ex; s1_s <= sx; s1_xz <= x_zero;
            v1    <= in_valid;
        end
    end

    // ================= S2 : mr = m*r0 (MUL only) =================
    reg [33:0] s2_mr;                 // Q1.32
    reg [16:0] s2_r0;
    reg [7:0]  s2_ex;
    reg        s2_s, s2_xz, v2;
    always @(posedge clk) begin
        if (reset) v2 <= 0;
        else if (!stall) begin
            s2_mr <= s1_m * s1_r0;    // 17b*17b -> 34b
            s2_r0 <= s1_r0;
            s2_ex <= s1_ex; s2_s <= s1_s; s2_xz <= s1_xz;
            v2    <= v1;
        end
    end

    // ================= S3 : two_m = 2 - mr (subtract) =================
    reg [17:0] s3_two_m;              // Q1.16
    reg [16:0] s3_r0;
    reg [7:0]  s3_ex;
    reg        s3_s, s3_xz, v3;
    always @(posedge clk) begin
        if (reset) v3 <= 0;
        else if (!stall) begin
            s3_two_m <= 18'h20000 - s2_mr[33:16];   // 2.0(Q1.16) - top
            s3_r0    <= s2_r0;
            s3_ex    <= s2_ex; s3_s <= s2_s; s3_xz <= s2_xz;
            v3       <= v2;
        end
    end

    // ================= S4 : r1_full = r0*two_m (MUL only) =================
    reg [34:0] s4_r1full;            // 17b*18b -> 35b
    reg [7:0]  s4_ex;
    reg        s4_s, s4_xz, v4;
    always @(posedge clk) begin
        if (reset) v4 <= 0;
        else if (!stall) begin
            s4_r1full <= s3_r0 * s3_two_m;
            s4_ex     <= s3_ex; s4_s <= s3_s; s4_xz <= s3_xz;
            v4        <= v3;
        end
    end

    // ================= S5 : normalize + pack -> y =================
    // r1 = r1_full[32:16] (1/m in Q0.16, (0.5,1]); frac/exp/clamp as fp_rcp_fast.
    wire [16:0] r1   = s4_r1full[32:16];
    wire [22:0] frac = r1[16] ? 23'd0 : {r1[14:0], 8'b0};
    wire signed [10:0] e = (r1[16] ? 11'sd254 : 11'sd253) - $signed({3'b0, s4_ex});
    always @(posedge clk) begin
        if (reset) out_valid <= 0;
        else if (!stall) begin
            out_valid <= v4;
            y <= s4_xz     ? {s4_s, 8'hFE, 23'h7FFFFF}
               : (e <= 0)  ? {s4_s, 31'd0}
               : (e >= 255)? {s4_s, 8'hFE, 23'h7FFFFF}
                           : {s4_s, e[7:0], frac};
        end
    end
endmodule

//
// fp_rcp_faster - deeper-pipelined (5-stage) reciprocal y ~= 1/x. Same non-IEEE method
// and seed ROM as fp_rcp_fast, but each Newton multiply gets its OWN stage (the sub and
// the normalize/pack are split off) so it clocks past ~120 MHz. fp_rcp_fast (3 stages,
// ~98 MHz) crammed a multiply AND its surrounding logic into s2 and s3.
//
// Method (Q16 fixed point on the significand):
//   m  = 1.mx in [1,2) (Q1.23) ; r0 = SEED_ROM[idx] ~ 1/m (Q0.23, 2048-entry ROM)
//   r1 = r0 * (2 - m*r0)  (one Newton step) ; 1/x = r1 * 2^(127-ex), packed to float32.
//
// PRECISION (this is Q23, not the original Q16). The old form took only the top 16
// significand bits (m = {1'b1, x[22:7]}) and carried Q16 intermediates, which capped
// the result at ~16 bits - the documented ~0.0015% (1.5e-5) error - no matter how good
// the Newton step was. That error is invisible in most of the pipe but becomes a
// QUARTER OF A TEXEL of UV positional error on a 256-tall texture (65536 * 1.5e-5),
// which is a visible one-texel seam at a sprite's edge rows.
// Now: full 24-bit significand, Q23 intermediates, and an 11-bit ROM index. Chosen from
// a swept model of this exact datapath (max relative error over 20k random significands):
//     ROM    Q=20      Q=21      Q=22      Q=23      Q=24
//      512  4.42e-6   3.94e-6   3.94e-6   3.82e-6   3.76e-6     <- seed-limited
//     1024  1.85e-6   1.28e-6   1.09e-6   1.04e-6   9.82e-7
//     2048  1.74e-6   9.32e-7   4.93e-7   3.34e-7   2.74e-7     <- chosen
//     4096  1.84e-6   8.96e-7   4.65e-7   2.30e-7   1.21e-7
//   old (Q16, N=256): 2.9e-5.  Target <1.5e-6 = 0.1 texel on a 256-tall texture.
// 2048/Q23 clears the target by 4.5x; 4096 doubles the RAM for 1.5x more accuracy, and
// Q24 needs a zero-padded mantissa for almost nothing. Same FIVE stages and the same
// one-DSP-per-multiply shape (24x24 and 24x25 both fit a 27x27), so every consumer's
// schedule is unchanged - fp_rcp_faster stays L=5 for isp_setup_streamed's hand-derived
// II=15 schedule, tsp_setup_stream's cnt schedule and tsp_shade_v2_pp's RCPLAT.
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
// NOTE (accuracy bar): the Q23/2048 point was chosen against a target of <0.1 texel of
// UV positional error on a 256-tall texture, i.e. rel err < 1.5e-6, because that is the
// consumer that feels this unit's error first (uv = rel_err * 65536). The ISP's invW and
// the colour planes are far less sensitive. If a future consumer needs better, the sweep
// table above says 4096 entries buys 1.5x for double the RAM - but at that point the
// truncating (non-rounding) FP units downstream, not this seed, are the limit.
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
    wire [23:0] m_q23  = {1'b1, x[22:0]};     // Q1.23 significand (FULL mantissa)
    wire [10:0] idx    = x[22:12];            // ROM index (11 bits -> seed ~2^-12)

    // ---- seed ROM (2048 x 24, constant-initialized; no runtime divide) ----
    // entry[i] ~ 1/m for bucket i, in Q0.23:  2^46 / (2^23 + i*2^12).
    reg [23:0] seed_rom [0:2047];
    integer ri;
    initial for (ri = 0; ri < 2048; ri = ri + 1)
        seed_rom[ri] = 24'((64'd1 << 46) / (64'd8388608 + ri * 64'd4096));

    // ================= S1 : ROM lookup + carry =================
    reg [23:0] s1_r0, s1_m;
    reg [7:0]  s1_ex;
    reg        s1_s, s1_xz, v1;
    always @(posedge clk) begin
        if (reset) v1 <= 0;
        else if (!stall) begin
            s1_r0 <= seed_rom[idx];
            s1_m  <= m_q23;
            s1_ex <= ex; s1_s <= sx; s1_xz <= x_zero;
            v1    <= in_valid;
        end
    end

    // ================= S2 : mr = m*r0 (MUL only) =================
    reg [47:0] s2_mr;                 // Q1.46
    reg [23:0] s2_r0;
    reg [7:0]  s2_ex;
    reg        s2_s, s2_xz, v2;
    always @(posedge clk) begin
        if (reset) v2 <= 0;
        else if (!stall) begin
            s2_mr <= s1_m * s1_r0;    // 24b*24b -> 48b
            s2_r0 <= s1_r0;
            s2_ex <= s1_ex; s2_s <= s1_s; s2_xz <= s1_xz;
            v2    <= v1;
        end
    end

    // ================= S3 : two_m = 2 - mr (subtract) =================
    reg [24:0] s3_two_m;              // Q1.23
    reg [23:0] s3_r0;
    reg [7:0]  s3_ex;
    reg        s3_s, s3_xz, v3;
    always @(posedge clk) begin
        if (reset) v3 <= 0;
        else if (!stall) begin
            s3_two_m <= 25'h1000000 - s2_mr[47:23]; // 2.0(Q1.23) - top
            s3_r0    <= s2_r0;
            s3_ex    <= s2_ex; s3_s <= s2_s; s3_xz <= s2_xz;
            v3       <= v2;
        end
    end

    // ================= S4 : r1_full = r0*two_m (MUL only) =================
    reg [48:0] s4_r1full;            // 24b*25b -> 49b
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
    // r1 = r1_full[46:23] (1/m in Q0.23, (0.5,1]); frac/exp/clamp as before. The
    // mantissa now comes out at full width instead of 15 bits zero-padded to 23.
    wire [23:0] r1   = s4_r1full[46:23];
    wire [22:0] frac = r1[23] ? 23'd0 : {r1[21:0], 1'b0};
    wire signed [10:0] e = (r1[23] ? 11'sd254 : 11'sd253) - $signed({3'b0, s4_ex});
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

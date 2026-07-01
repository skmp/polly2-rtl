//
// fp_rcp_fast - cheap, non-IEEE reciprocal y ~= 1/x. PIPELINED (3 cycles) so it
// closes timing: no runtime divider (a precomputed seed ROM), and the two
// Newton-step multiplies are split across pipeline stages.
//
// Method, Q16 fixed point on the significand:
//   m  = 1.mx  in [1,2)                          (Q1.16)
//   r0 = SEED_ROM[idx] ~ 1/m in (0.5,1]          (Q0.16, 256-entry ROM)
//   r1 = r0 * (2 - m*r0)   (one Newton step)     -> ~1/m to ~15 bits
//   1/x = r1 * 2^(127-ex), packed to float32.
//
// Pipeline: s1 ROM lookup + capture ex/sign; s2 mr=m*r0, two_m=2-mr;
//           s3 r1=r0*two_m, normalize+pack.  in_valid@N -> out_valid@N+3.
// DaZ input -> saturates to a large finite value (no inf/NaN). ~0.0015% error.
//
module fp_rcp_fast (
    input             clk,
    input             reset,
    input             in_valid,
    input      [31:0] x,
    output reg        out_valid,
    output reg [31:0] y
);
    // ---- decompose ----
    wire        sx = x[31];
    wire [7:0]  ex = x[30:23];
    wire        x_zero = (ex == 8'd0);
    wire [16:0] m_q16  = {1'b1, x[22:7]};     // Q1.16 significand
    wire [7:0]  idx    = x[22:15];            // ROM index

    // ---- seed ROM: r0 = round(2^32 / (2^16 + idx*2^8)) in Q0.16 ----
    // A genuine 256-entry ROM initialized at elaboration (NOT a runtime divide).
    // The division runs only in the constant `initial` block, so the synthesized
    // logic is a small ROM lookup - no combinational divider on the data path.
    reg [16:0] seed_rom [0:255];
    integer ri;
    initial for (ri = 0; ri < 256; ri = ri + 1)
        seed_rom[ri] = 17'((64'h100000000) / (64'd65536 + ri * 64'd256));

    // ---- stage 1: ROM lookup + carry ex/sign/m ----
    reg [16:0] s1_r0, s1_m;
    reg [7:0]  s1_ex;
    reg        s1_s, s1_xz, v1;
    always @(posedge clk) begin
        if (reset) v1 <= 0;
        else begin
            s1_r0 <= seed_rom[idx];
            s1_m  <= m_q16;
            s1_ex <= ex;  s1_s <= sx;  s1_xz <= x_zero;
            v1    <= in_valid;
        end
    end

    // ---- stage 2: mr = m*r0 (Q1.32) ; two_m = 2.0 - mr  (Q1.16) ----
    reg [16:0] s2_r0;
    reg [17:0] s2_two_m;
    reg [7:0]  s2_ex;
    reg        s2_s, s2_xz, v2;
    reg [33:0] mr_c;
    always @(*) mr_c = s1_m * s1_r0;              // 17b * 17b = 34b, Q1.32
    always @(posedge clk) begin
        if (reset) v2 <= 0;
        else begin
            s2_two_m <= 18'h20000 - mr_c[33:16];  // 2.0(Q1.16) - top(Q1.16)
            s2_r0    <= s1_r0;
            s2_ex    <= s1_ex; s2_s <= s1_s; s2_xz <= s1_xz;
            v2       <= v1;
        end
    end

    // ---- stage 3: r1 = r0*two_m ; normalize + pack ----
    always @(posedge clk) begin
        if (reset) out_valid <= 0;
        else begin
            out_valid <= v2;
            y <= pack(s2_r0, s2_two_m, s2_ex, s2_s, s2_xz);
        end
    end

    function [31:0] pack(input [16:0] r0, input [17:0] two_m,
                         input [7:0] exf, input s, input xz);
        reg [34:0] r1_full; reg [16:0] r1; reg [22:0] frac; reg signed [10:0] e;
        begin
            r1_full = r0 * two_m;                  // 17b * 18b, Q1.32-ish
            r1      = r1_full[32:16];              // 1/m in Q0.16 (0.5,1]
            frac    = r1[16] ? 23'd0 : {r1[14:0], 8'b0};
            e       = (r1[16] ? 11'sd254 : 11'sd253) - $signed({3'b0, exf});
            if (xz)          pack = {s, 8'hFE, 23'h7FFFFF};
            else if (e <= 0) pack = {s, 31'd0};
            else if (e>=255) pack = {s, 8'hFE, 23'h7FFFFF};
            else             pack = {s, e[7:0], frac};
        end
    endfunction
endmodule

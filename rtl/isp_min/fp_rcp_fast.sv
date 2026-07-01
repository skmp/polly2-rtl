//
// fp_rcp_fast - cheap, low-latency, non-IEEE reciprocal y ~= 1/x.
//
// Used once per triangle for inv_tri_area; must be short (hard ~14-cycle setup
// budget). Method, all in Q16 fixed point on the significand:
//   m  = 1.mx  in [1,2)                          (Q1.16, value 65536..131071)
//   r0 = LUT(1/m) in (0.5,1]                      (Q0.16, value 32768..65536)
//   r1 = r0 * (2 - m*r0)   (one Newton step)     -> ~1/m to ~15 bits
//   1/x = r1 * 2^(127-ex);  r1 in (0.5,1] -> pack as 1.f * 2^(exp) with
//         exp = 253 - ex after the <<1 normalize of r1 into [1,2).
//
// DaZ input -> saturates to a large finite value (no inf/NaN).
// Latency: 1 cycle (seed+NR+pack are combinational; result registered once).
// in_valid in cycle N -> out_valid & y in cycle N+1. Accuracy ~0.0015% (16-bit).
//
module fp_rcp_fast (
    input             clk,
    input             reset,
    input             in_valid,
    input      [31:0] x,
    output reg        out_valid,
    output reg [31:0] y
);
    wire        sx = x[31];
    wire [7:0]  ex = x[30:23];
    wire        x_zero = (ex == 8'd0);

    // m in Q1.16: 1.mx using top 16 mantissa bits -> value in [65536, 131072)
    wire [16:0] m_q16 = {1'b1, x[22:7]};   // 17 bits, top bit = integer 1

    // seed LUT: r0 = round(2^32 / m) >> 16  == round(2^16 / (m/2^16))
    //         = round(65536 * 65536 / m_q16)  in Q0.16 (32768..65536]
    wire [7:0]  idx = x[22:15];
    reg  [16:0] r0_q16;
    always @(*) begin
        // 1/(1.idx) in Q0.16: 2^32 / (2^16 + idx*2^8)
        r0_q16 = 17'(64'h100000000 / (64'd65536 + {8'd0, idx} * 64'd256));
    end

    // 1-cycle latency: seed LUT + Newton step + pack are all combinational;
    // register the result once. in_valid in cycle N -> out_valid in cycle N+1.
    always @(posedge clk) begin
        if (reset) begin out_valid <= 0; end
        else begin
            out_valid <= in_valid;
            y <= nr_pack(m_q16, r0_q16, ex, sx, x_zero);
        end
    end

    // Newton refine + pack (pure comb, evaluated in stage 1).
    function [31:0] nr_pack(
        input [16:0] m,     // Q1.16 in [1,2)
        input [16:0] r0,    // Q0.16 in (0.5,1]
        input [7:0]  exf,
        input        s, input xz);
        reg [33:0] mr;       // m*r0  : Q1.16 * Q0.16 = Q1.32 (~1.0)
        reg [17:0] two_m;    // (2 - m*r0) in Q1.16  (~1.0)
        reg [34:0] r1_full;  // r0 * two_m : Q0.16 * Q1.16 = Q1.32
        reg [16:0] r1;       // 1/m in Q0.16 (0.5,1]
        reg [22:0] frac;
        reg signed [10:0] e;
        begin
            mr    = m * r0;                       // Q1.32, value ~ 1.0<<32
            // 2.0 in Q1.16 = 18'h20000; subtract top 18 bits of mr (Q1.16).
            two_m = 18'h20000 - mr[33:16];        // Q1.16, ~1.0
            r1_full = r0 * two_m;                  // Q0.16 * Q1.16 = Q1.32
            r1    = r1_full[32:16];                // back to Q0.16, in (0.5,1]

            // r1 in (0.5,1] Q0.16: bit15 is the 0.5 place. Normalizing to
            // [1,2) means <<1, so the new integer (hidden) bit is r1[15] and
            // the fraction is r1[14:0]. If r1 == 1.0 exactly (bit16 set) the
            // value is 2^0 with zero fraction.
            frac = r1[16] ? 23'd0 : {r1[14:0], 8'b0};
            e    = (r1[16] ? 11'sd254 : 11'sd253) - $signed({3'b0, exf});

            if (xz)            nr_pack = {s, 8'hFE, 23'h7FFFFF};
            else if (e <= 0)   nr_pack = {s, 31'd0};
            else if (e >= 255) nr_pack = {s, 8'hFE, 23'h7FFFFF};
            else               nr_pack = {s, e[7:0], frac};
        end
    endfunction
endmodule

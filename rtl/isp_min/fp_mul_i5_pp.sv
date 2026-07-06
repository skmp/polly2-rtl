//
// fp_mul_i5_pp - PIPELINED variant of fp_mul_i5: y = f * k, k in 0..31.
//
// Same reduced-precision math as fp_mul_i5 (16-bit-mantissa float * 5-bit integer,
// non-IEEE: DaZ, no inf/NaN, truncate, k==0 -> +0), split so it clocks past 120 MHz.
// The combinational fp_mul_i5 stays for the other (setup/raster) users; this one is
// for the streamed interp_unit.
//
// CONVENTION: this module does NOT register its inputs or its output. The single
// internal register holds the multiply product; the normalize/pack after it is
// COMBINATIONAL, driving y/out_valid directly. The WRAPPING module registers the
// inputs (holds them stable while in_valid) and the output. Effective latency = 1
// internal register + the wrapper's output register.
//
//   (comb) prod = sig(16) * k(5)          -- off module inputs
//   [REG]  s1_prod + sign/exp/zero
//   (comb) normalize (leading-1 priority) + pack -> y ; out_valid = v1
//
// HOLD (backpressure): lives in tsp_shade_pp's `en`-gated front (a texture-cache miss
// freezes RCP..UV via one clock-enable). Takes `stall` (fp_rcp_fast convention):
// stall=1 freezes the internal register. in_valid -> out_valid.
//
// The 16x5 product is DSP-eligible (no multstyle override).
//
module fp_mul_i5_pp (
    input             clk,
    input             reset,
    input             stall,
    input             in_valid,
    input      [31:0] f,
    input      [4:0]  k,
    output            out_valid,
    output     [31:0] y
);
    // ---- combinational off inputs: decode + product ----
    wire        sf = f[31];
    wire [7:0]  ef = f[30:23];
    wire        f_zero = (ef == 8'd0);          // DaZ
    wire        k_zero = (k == 5'd0);

    wire [15:0] sig = {1'b1, f[22:8]};          // 16-bit significand
    wire [20:0] prod_c = sig * {11'd0, k};      // 16 x 5 -> 21 bits

    // ================= internal REGISTER : product + carried decode ===============
    reg               v1;
    reg        [20:0] s1_prod;
    reg        [7:0]  s1_ef;
    reg               s1_sf, s1_zero;
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else if (!stall) begin
            v1      <= in_valid;
            s1_prod <= prod_c;
            s1_ef   <= ef;
            s1_sf   <= sf;
            s1_zero <= f_zero | k_zero;
        end
    end

    // ================= COMBINATIONAL : normalize (priority) + pack ================
    // sig's leading 1 is at bit15; k in [1,31] adds 0..5 bits -> leading one at
    // bit 15..20 (6 cases). For a leading one at bit p, the 15 fraction bits are
    // prod[p-1 -: 15] and the exponent gains (p-15).
    reg  [14:0] frac15;
    reg  [2:0]  sh;                             // 0..5
    always @(*) begin
        casez (s1_prod[20:15])
            6'b1?????: begin frac15 = s1_prod[19:5]; sh = 3'd5; end  // leading @20
            6'b01????: begin frac15 = s1_prod[18:4]; sh = 3'd4; end  // @19
            6'b001???: begin frac15 = s1_prod[17:3]; sh = 3'd3; end  // @18
            6'b0001??: begin frac15 = s1_prod[16:2]; sh = 3'd2; end  // @17
            6'b00001?: begin frac15 = s1_prod[15:1]; sh = 3'd1; end  // @16
            default:   begin frac15 = s1_prod[14:0]; sh = 3'd0; end  // @15
        endcase
    end
    wire [22:0] mant = {frac15, 8'b0};
    wire signed [10:0] e = $signed({3'b0, s1_ef}) + $signed({8'b0, sh});
    wire overflow = (e >= 255);

    assign y = s1_zero   ? {s1_sf, 31'd0}
             : overflow  ? {s1_sf, 8'hFE, 23'h7FFFFF}
                         : {s1_sf, e[7:0], mant};
    assign out_valid = v1;
endmodule

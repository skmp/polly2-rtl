//
// fp_add3_24_pp - PIPELINED 3-input non-IEEE float add: y = a + b + c.
//
// Same reduced-precision math as fp_add3_24 (align all three to the max exponent,
// signed sign-magnitude sum, single normalize/pack; DaZ, no inf/NaN, truncate,
// overflow saturates, underflow flushes). The combinational fp_add3_24 was the interp
// i2 critical path (~35 MHz); this splits its align/sum/normalize chain across clocked
// stages so it clocks past 120 MHz. The combinational fp_add3_24 stays for other
// users; this one is for the streamed interp_unit.
//
// CONVENTION: this module does NOT register its inputs or its output. It has 4 internal
// registers (S1..S4); the final normalize/pack after S4 is COMBINATIONAL, driving
// y/out_valid directly. The WRAPPING module registers the inputs and the output.
//
//   S1 : decode (DaZ) ; max exponent ; per-operand shift amounts (e_max - exp)  [REG]
//   S2 : align each significand right by its shift amount (3x barrel shift)      [REG]
//   S3 : sign-convert to 2's complement ; 28-bit 3-way signed sum -> ssum        [REG]
//   S4 : abs (|ssum|) ; find leading-1 position lz (priority encode)             [REG]
//   (comb) normalize shift (mag by lz) ; exp adjust (e_max+lz-23) ; over/underflow ;
//          pack -> y ; out_valid = v4
// (The old 1-stage normalize was the ~83 MHz limiter: abs + a 24-deep leading-1 search
// + variable shift + pack in one clock. Split at the leading-1 position.)
//
// HOLD (backpressure): lives in tsp_shade_pp's `en`-gated front. Takes `stall`
// (fp_rcp_fast convention): stall=1 freezes ALL internal registers. in_valid ->
// out_valid.
//
module fp_add3_24_pp (
    input             clk,
    input             reset,
    input             stall,
    input             in_valid,
    input      [31:0] a,
    input      [31:0] b,
    input      [31:0] c,
    output            out_valid,
    output     [31:0] y
);
    // ---- combinational front of S1: decode + max-exp + shift amounts ----
    wire sa = a[31], sb = b[31], sc = c[31];
    wire [7:0] ea = a[30:23], eb = b[30:23], ec = c[30:23];
    wire za = (ea == 8'd0), zb = (eb == 8'd0), zc = (ec == 8'd0);   // DaZ

    wire [23:0] sig_a_c = za ? 24'd0 : {1'b1, a[22:0]};
    wire [23:0] sig_b_c = zb ? 24'd0 : {1'b1, b[22:0]};
    wire [23:0] sig_c_c = zc ? 24'd0 : {1'b1, c[22:0]};
    wire [7:0]  exa = za ? 8'd0 : ea;
    wire [7:0]  exb = zb ? 8'd0 : eb;
    wire [7:0]  exc = zc ? 8'd0 : ec;
    wire [7:0]  e_ab   = (exa >= exb) ? exa : exb;
    wire [7:0]  e_max_c = (e_ab >= exc) ? e_ab : exc;

    // ================= STAGE 1 : decode + max-exp + shift amounts =================
    reg               v1;
    reg        [23:0] s1_sa, s1_sb, s1_sc;      // significands
    reg               s1_sga, s1_sgb, s1_sgc;   // signs
    reg        [7:0]  s1_sha, s1_shb, s1_shc;   // align shift amounts (e_max - exp)
    reg        [7:0]  s1_emax;
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else if (!stall) begin
            v1     <= in_valid;
            s1_sa  <= sig_a_c; s1_sb <= sig_b_c; s1_sc <= sig_c_c;
            s1_sga <= sa;      s1_sgb <= sb;     s1_sgc <= sc;
            s1_sha <= e_max_c - exa;
            s1_shb <= e_max_c - exb;
            s1_shc <= e_max_c - exc;
            s1_emax<= e_max_c;
        end
    end

    // ================= STAGE 2 : align (3x barrel shift) ==========================
    reg               v2;
    reg        [23:0] s2_al_a, s2_al_b, s2_al_c;
    reg               s2_sga, s2_sgb, s2_sgc;
    reg        [7:0]  s2_emax;
    always @(posedge clk) begin
        if (reset) v2 <= 1'b0;
        else if (!stall) begin
            v2      <= v1;
            s2_al_a <= (s1_sha >= 8'd24) ? 24'd0 : (s1_sa >> s1_sha);
            s2_al_b <= (s1_shb >= 8'd24) ? 24'd0 : (s1_sb >> s1_shb);
            s2_al_c <= (s1_shc >= 8'd24) ? 24'd0 : (s1_sc >> s1_shc);
            s2_sga  <= s1_sga; s2_sgb <= s1_sgb; s2_sgc <= s1_sgc;
            s2_emax <= s1_emax;
        end
    end

    // ================= STAGE 3 : sign-convert + 3-way signed sum =================
    reg               v3;
    reg signed [27:0] s3_ssum;
    reg        [7:0]  s3_emax;
    // signed contributions (sign-magnitude -> 2's complement), 28b headroom.
    wire signed [27:0] va = s2_sga ? -$signed({4'b0, s2_al_a}) : $signed({4'b0, s2_al_a});
    wire signed [27:0] vb = s2_sgb ? -$signed({4'b0, s2_al_b}) : $signed({4'b0, s2_al_b});
    wire signed [27:0] vc = s2_sgc ? -$signed({4'b0, s2_al_c}) : $signed({4'b0, s2_al_c});
    always @(posedge clk) begin
        if (reset) v3 <= 1'b0;
        else if (!stall) begin
            v3      <= v2;
            s3_ssum <= va + vb + vc;
            s3_emax <= s2_emax;
        end
    end

    // ================= STAGE 4 : abs + find leading-1 position ====================
    // mag = |ssum| (27b). Priority-encode the leading-1 index `lz` in 0..26 (0 = no
    // bit set / zero result). The heavy variable SHIFT and exponent adjust are deferred
    // to S5; here we only produce mag + the position.
    wire        s_res_c = s3_ssum[27];
    wire [26:0] mag_c   = s_res_c ? (~s3_ssum[26:0] + 27'd1) : s3_ssum[26:0];
    reg  [4:0]  lz_c;                    // leading-1 bit index (0..26); 0 if mag==0
    integer j; reg lfound;
    always @(*) begin
        lz_c = 5'd0; lfound = 1'b0;
        for (j = 26; j >= 0; j = j - 1)
            if (!lfound && mag_c[j]) begin lz_c = j[4:0]; lfound = 1'b1; end
    end

    reg               v4;
    reg        [26:0] s4_mag;
    reg        [4:0]  s4_lz;
    reg               s4_sign, s4_zero;
    reg        [7:0]  s4_emax;
    always @(posedge clk) begin
        if (reset) v4 <= 1'b0;
        else if (!stall) begin
            v4      <= v3;
            s4_mag  <= mag_c;
            s4_lz   <= lz_c;
            s4_sign <= s_res_c;
            s4_zero <= (mag_c == 27'd0);
            s4_emax <= s3_emax;
        end
    end

    // ================= COMBINATIONAL : normalize shift + exp-adjust + pack ========
    // The leading 1 is at bit s4_lz; the reference significand position is bit 23.
    //   norm_sig (24b, leading 1 at bit 23) = mag aligned so bit s4_lz -> bit 23
    //   e_norm = e_max + (s4_lz - 23)
    // Realized as a single variable shift on the 27b mag, then take bits [23:0].
    wire signed [5:0]  shamt = $signed({1'b0, s4_lz}) - 6'sd23;   // + = left-of-23
    wire [26:0] aligned = (shamt >= 0) ? (s4_mag >> shamt[4:0])   // lead above 23: down
                                       : (s4_mag << (-shamt));     // lead below 23: up
    wire [23:0] norm_sig = aligned[23:0];
    wire signed [10:0] e_norm = $signed({3'b0, s4_emax}) + $signed({{5{shamt[5]}}, shamt});
    wire underflow = (e_norm <= 0);
    wire overflow  = (e_norm >= 255);

    assign y = s4_zero    ? 32'd0
             : underflow  ? {s4_sign, 31'd0}
             : overflow   ? {s4_sign, 8'hFE, 23'h7FFFFF}
                          : {s4_sign, e_norm[7:0], norm_sig[22:0]};
    assign out_valid = v4;
endmodule

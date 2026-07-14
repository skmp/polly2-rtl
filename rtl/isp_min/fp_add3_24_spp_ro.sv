//
// fp_add3_24_spp_ro - STREAMING PIPELINED, REGISTERED-OUTPUT variant of fp_add3_24.
//
// Same fused 3-input non-IEEE add (y = a + b + c: align all three to the max exponent,
// signed sign-magnitude sum, single normalize/truncate) as the combinational
// fp_add3_24, and BIT-EXACT to it for the same (a,b,c) - but split into a 4-clock
// streaming pipeline whose OUTPUT is registered.
//
// This is a 4-STAGE unit (was 3): the S1 align was the Fmax limiter (~66 MHz standalone
// on Cyclone V) because the 3-way path does max-of-3 exponents -> THREE 24-bit variable
// shifts -> a 28-bit 3-way signed add all in one stage. That is split into two:
//   S1a : decode + max-of-3 exponent + the three shift AMOUNTS (sha/shb/shc). Register
//         the raw significands, signs, shift amounts, and e_max.
//   S1b : apply the three variable shifts + signed 3-way sum -> ssum.  (NEW stage)
//   S2  : sign/abs + leading-1 SEARCH only (priority -> shift select / amount).
//   S3  : apply the shift + exponent adjust + pack -> registered y.
//
// CONVENTION (matches fp_rcp_fast / the streaming units):
//   ports (clk, reset, stall, in_valid, a, b, c, out_valid, y).
//   in_valid @N -> out_valid @N+4, y @N+4 (registered). stall=1 freezes all stages.
//   one result/clock throughput when !stall.
//
module fp_add3_24_spp_ro (
    input             clk,
    input             reset,
    input             stall,
    input             in_valid,
    input      [31:0] a,
    input      [31:0] b,
    input      [31:0] c,
    output reg        out_valid,
    output reg [31:0] y
);
    // ======================================================================
    // S1a combinational: decode (DaZ) + max-of-3 exponent + the three shift amounts.
    // No shifting/adding here - just the exponent-compare tree.
    // ======================================================================
    wire sa = a[31], sb = b[31], sc = c[31];
    wire [7:0] ea = a[30:23], eb = b[30:23], ec = c[30:23];
    wire za = (ea == 8'd0), zb = (eb == 8'd0), zc = (ec == 8'd0);

    wire [23:0] sig_a_c = za ? 24'd0 : {1'b1, a[22:0]};
    wire [23:0] sig_b_c = zb ? 24'd0 : {1'b1, b[22:0]};
    wire [23:0] sig_c_c = zc ? 24'd0 : {1'b1, c[22:0]};
    wire [7:0]  exa = za ? 8'd0 : ea;
    wire [7:0]  exb = zb ? 8'd0 : eb;
    wire [7:0]  exc = zc ? 8'd0 : ec;

    wire [7:0] e_ab    = (exa >= exb) ? exa : exb;
    wire [7:0] e_max_c = (e_ab >= exc) ? e_ab : exc;

    wire [7:0] sha_c = e_max_c - exa;
    wire [7:0] shb_c = e_max_c - exb;
    wire [7:0] shc_c = e_max_c - exc;

    // ---- S1a registers ----
    reg               v1a;
    reg [23:0]        s1a_siga, s1a_sigb, s1a_sigc;
    reg               s1a_sa, s1a_sb, s1a_sc;
    reg [7:0]         s1a_sha, s1a_shb, s1a_shc;
    reg [7:0]         s1a_emax;
    always @(posedge clk) begin
        if (reset) v1a <= 1'b0;
        else if (!stall) begin
            v1a      <= in_valid;
            s1a_siga <= sig_a_c; s1a_sigb <= sig_b_c; s1a_sigc <= sig_c_c;
            s1a_sa   <= sa;      s1a_sb   <= sb;      s1a_sc   <= sc;
            s1a_sha  <= sha_c;   s1a_shb  <= shb_c;   s1a_shc  <= shc_c;
            s1a_emax <= e_max_c;
        end
    end

    // ======================================================================
    // S1b combinational: apply the three variable shifts + signed 3-way sum.
    // ======================================================================
    wire [23:0] al_a = (s1a_sha >= 8'd24) ? 24'd0 : (s1a_siga >> s1a_sha);
    wire [23:0] al_b = (s1a_shb >= 8'd24) ? 24'd0 : (s1a_sigb >> s1a_shb);
    wire [23:0] al_c = (s1a_shc >= 8'd24) ? 24'd0 : (s1a_sigc >> s1a_shc);

    wire signed [27:0] va = s1a_sa ? -$signed({4'b0, al_a}) : $signed({4'b0, al_a});
    wire signed [27:0] vb = s1a_sb ? -$signed({4'b0, al_b}) : $signed({4'b0, al_b});
    wire signed [27:0] vc = s1a_sc ? -$signed({4'b0, al_c}) : $signed({4'b0, al_c});
    wire signed [27:0] ssum_c = va + vb + vc;

    // ---- S1b registers ----
    reg               v1;
    reg signed [27:0] s1_ssum;
    reg [7:0]         s1_emax;
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else if (!stall) begin
            v1      <= v1a;
            s1_ssum <= ssum_c;
            s1_emax <= s1a_emax;
        end
    end

    // ======================================================================
    // S2 combinational: sign/abs + leading-1 SEARCH ONLY (no shifting here). The
    // aligned significands' leading 1 sits at bit 23; summing three can carry up to
    // bit 26. Classify the magnitude into a shift select + (for cancellation) a
    // leading-zero count, leaving the actual shift for S3.
    //   sh_sel : 0=bit26 (>>3,+3) 1=bit25(>>2,+2) 2=bit24(>>1,+1) 3=bit23(no shift)
    //            4=cancel (<<lz, -lz)
    // ======================================================================
    wire        s_res_c = s1_ssum[27];
    wire [26:0] mag_c   = s_res_c ? (~s1_ssum[26:0] + 27'd1) : s1_ssum[26:0];

    reg  [2:0] sh_sel_c;
    reg  [4:0] lz_c;
    integer si; reg found_c;
    always @(*) begin
        found_c = 1'b0;
        if      (mag_c[26]) begin sh_sel_c = 3'd0; lz_c = 5'd0; end
        else if (mag_c[25]) begin sh_sel_c = 3'd1; lz_c = 5'd0; end
        else if (mag_c[24]) begin sh_sel_c = 3'd2; lz_c = 5'd0; end
        else if (mag_c[23]) begin sh_sel_c = 3'd3; lz_c = 5'd0; end
        else begin
            sh_sel_c = 3'd4; lz_c = 5'd0;
            for (si = 1; si < 24; si = si + 1)
                if (!found_c && mag_c[23-si]) begin
                    lz_c = si[4:0]; found_c = 1'b1;
                end
        end
    end
    wire res_zero_c = (mag_c == 27'd0);

    // ---- S2 registers ----
    reg        v2;
    reg [26:0] s2_mag;
    reg [7:0]  s2_emax;
    reg        s2_sres, s2_zero;
    reg [2:0]  s2_sel;
    reg [4:0]  s2_lz;
    always @(posedge clk) begin
        if (reset) v2 <= 1'b0;
        else if (!stall) begin
            v2      <= v1;
            s2_mag  <= mag_c;
            s2_emax <= s1_emax;
            s2_sres <= s_res_c;
            s2_zero <= res_zero_c;
            s2_sel  <= sh_sel_c;
            s2_lz   <= lz_c;
        end
    end

    // ======================================================================
    // S3 combinational: apply the shift + exponent adjust + pack.
    // ======================================================================
    reg  [23:0] norm_sig;
    reg  signed [10:0] e_norm;
    always @(*) begin
        case (s2_sel)
            3'd0: begin norm_sig = s2_mag[26:3]; e_norm = $signed({3'b0, s2_emax}) + 11'sd3; end
            3'd1: begin norm_sig = s2_mag[25:2]; e_norm = $signed({3'b0, s2_emax}) + 11'sd2; end
            3'd2: begin norm_sig = s2_mag[24:1]; e_norm = $signed({3'b0, s2_emax}) + 11'sd1; end
            3'd3: begin norm_sig = s2_mag[23:0]; e_norm = $signed({3'b0, s2_emax});          end
            default: begin
                norm_sig = s2_mag[23:0] << s2_lz;
                e_norm   = $signed({3'b0, s2_emax}) - $signed({6'd0, s2_lz});
            end
        endcase
    end
    wire underflow = (e_norm <= 0);
    wire overflow  = (e_norm >= 255);
    wire [31:0] y_c = s2_zero   ? 32'd0
                    : underflow ? {s2_sres, 31'd0}
                    : overflow  ? {s2_sres, 8'hFE, 23'h7FFFFF}
                                : {s2_sres, e_norm[7:0], norm_sig[22:0]};

    // ---- S3 register: the module's registered output ----
    always @(posedge clk) begin
        if (reset) out_valid <= 1'b0;
        else if (!stall) begin
            out_valid <= v2;
            y         <= y_c;
        end
    end
endmodule

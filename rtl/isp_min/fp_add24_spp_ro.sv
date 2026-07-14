//
// fp_add24_spp_ro - STREAMING PIPELINED, REGISTERED-OUTPUT variant of fp_add24.
//
// Same reduced-precision non-IEEE add/sub as the combinational fp_add24 (DaZ, no
// inf/NaN, truncate, overflow saturates, underflow flushes) and BIT-EXACT to it for the
// same (a, b_in, sub) - but split into a 4-clock streaming pipeline whose OUTPUT is
// registered.
//
// This is a 4-STAGE unit (was 3): even with the align-to-max restructure (no magnitude
// compare/swap) the single-stage exp-max -> shift-amount -> barrel shift -> signed add
// chain measured ~85 MHz standalone on Cyclone V, so - like fp_add3_24_spp_ro - the
// align is split in two:
//   S1a : decode (sub sign-fix, DaZ) + max exponent + the two shift AMOUNTS. Register
//         the raw significands, signs, shift amounts, and e_max.
//   S1b : apply the two variable shifts + conditional-negate 26b SIGNED sum. (NEW)
//   S2  : sign/abs + leading-1 SEARCH only (priority encode -> shift select / amount).
//   S3  : apply the shift + exponent adjust + pack -> registered y.
// Bit-exact: the larger operand shifts by 0 (lossless), the smaller truncates exactly
// as fp_add24's single-shift did; |ssum| == big - small_shifted, sign(ssum) == sign of
// the larger-magnitude operand, and the exact-cancellation case packs +0 both ways.
//
// CONVENTION (matches fp_rcp_fast / the streaming units):
//   ports (clk, reset, stall, in_valid, a, b_in, sub, out_valid, y).
//   in_valid @N -> out_valid @N+4, y @N+4 (registered). stall=1 freezes all stages.
//   one result/clock throughput when !stall.
//
module fp_add24_spp_ro (
    input             clk,
    input             reset,
    input             stall,
    input             in_valid,
    input      [31:0] a,
    input      [31:0] b_in,
    input             sub,
    output reg        out_valid,
    output reg [31:0] y
);
    // ======================================================================
    // S1a combinational: decode + max exponent + the two shift amounts. No
    // shifting/adding here - just the (shallow) exponent-compare tree.
    // ======================================================================
    wire [31:0] b = sub ? {~b_in[31], b_in[30:0]} : b_in;
    wire       sa = a[31],  sb = b[31];
    wire [7:0] ea = a[30:23], eb = b[30:23];

    // same decode as fp_add24: denormal keeps its mantissa with hidden bit 0,
    // exponent clamped to 1.
    wire [23:0] sig_a_c = {(ea != 8'd0), a[22:0]};
    wire [23:0] sig_b_c = {(eb != 8'd0), b[22:0]};
    wire [7:0]  exa   = (ea == 8'd0) ? 8'd1 : ea;
    wire [7:0]  exb   = (eb == 8'd0) ? 8'd1 : eb;

    wire [7:0] e_max_c = (exa >= exb) ? exa : exb;
    wire [7:0] sha_c = e_max_c - exa;
    wire [7:0] shb_c = e_max_c - exb;

    // ---- S1a registers ----
    reg        v1a;
    reg [23:0] s1a_siga, s1a_sigb;
    reg        s1a_sa, s1a_sb;
    reg [7:0]  s1a_sha, s1a_shb;
    reg [7:0]  s1a_emax;
    always @(posedge clk) begin
        if (reset) v1a <= 1'b0;
        else if (!stall) begin
            v1a      <= in_valid;
            s1a_siga <= sig_a_c;  s1a_sigb <= sig_b_c;
            s1a_sa   <= sa;       s1a_sb   <= sb;
            s1a_sha  <= sha_c;    s1a_shb  <= shb_c;
            s1a_emax <= e_max_c;
        end
    end

    // ======================================================================
    // S1b combinational: apply the two variable shifts + signed sum. The larger
    // operand shifts by 0 (lossless); the smaller truncates exactly as fp_add24.
    // ======================================================================
    wire [23:0] al_a = (s1a_sha >= 8'd24) ? 24'd0 : (s1a_siga >> s1a_sha);
    wire [23:0] al_b = (s1a_shb >= 8'd24) ? 24'd0 : (s1a_sigb >> s1a_shb);

    // signed contributions: 26 bits = 24 mag + sign + 1 headroom (sum of two).
    wire signed [25:0] va = s1a_sa ? -$signed({2'b0, al_a}) : $signed({2'b0, al_a});
    wire signed [25:0] vb = s1a_sb ? -$signed({2'b0, al_b}) : $signed({2'b0, al_b});
    wire signed [25:0] ssum_c = va + vb;

    // ---- S1b registers ----
    reg               v1;
    reg signed [25:0] s1_ssum;
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
    // S2 combinational: sign/abs + leading-1 SEARCH ONLY (no shifting here).
    // mag is 25 bits: bit24 = carry (same-sign add overflow), bit23 = already
    // normal, below = cancellation left-shift by `lz`.
    //   sh_sel : 0 = carry (mag[24]) -> shift right 1, exp+1
    //            1 = normal (mag[23]) -> no shift
    //            2 = cancel           -> left shift by `lz` (1..23), exp-lz
    // ======================================================================
    wire        s_res_c = s1_ssum[25];
    wire [24:0] mag_c   = s_res_c ? (~s1_ssum[24:0] + 25'd1) : s1_ssum[24:0];

    reg  [1:0] sh_sel_c;
    reg  [4:0] lz_c;
    integer si; reg found_c;
    always @(*) begin
        found_c = 1'b0;
        if (mag_c[24]) begin
            sh_sel_c = 2'd0; lz_c = 5'd0;
        end else if (mag_c[23]) begin
            sh_sel_c = 2'd1; lz_c = 5'd0;
        end else begin
            sh_sel_c = 2'd2; lz_c = 5'd0;
            for (si = 1; si < 24; si = si + 1)
                if (!found_c && mag_c[23-si]) begin
                    lz_c = si[4:0]; found_c = 1'b1;
                end
        end
    end
    wire s1_zero_c = (mag_c == 25'd0);

    // ---- S2 registers ----
    reg        v2;
    reg [24:0] s2_mag;
    reg [7:0]  s2_ebig;
    reg        s2_sbig, s2_zero;
    reg [1:0]  s2_sel;
    reg [4:0]  s2_lz;
    always @(posedge clk) begin
        if (reset) v2 <= 1'b0;
        else if (!stall) begin
            v2      <= v1;
            s2_mag  <= mag_c;
            s2_ebig <= s1_emax;
            s2_sbig <= s_res_c;
            s2_zero <= s1_zero_c;
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
            2'd0: begin norm_sig = s2_mag[24:1];      e_norm = $signed({3'b0, s2_ebig}) + 11'sd1; end
            2'd1: begin norm_sig = s2_mag[23:0];      e_norm = $signed({3'b0, s2_ebig});          end
            default: begin
                norm_sig = s2_mag[23:0] << s2_lz;
                e_norm   = $signed({3'b0, s2_ebig}) - $signed({6'd0, s2_lz});
            end
        endcase
    end
    wire underflow = (e_norm <= 0);
    wire overflow  = (e_norm >= 255);
    wire [31:0] y_c = s2_zero   ? 32'd0
                    : underflow ? {s2_sbig, 31'd0}
                    : overflow  ? {s2_sbig, 8'hFE, 23'h7FFFFF}
                                : {s2_sbig, e_norm[7:0], norm_sig[22:0]};

    // ---- S3 register: the module's registered output ----
    always @(posedge clk) begin
        if (reset) out_valid <= 1'b0;
        else if (!stall) begin
            out_valid <= v2;
            y         <= y_c;
        end
    end
endmodule

//
// tsp_blend - refsw2 BlendingUnit (alpha blend at the very end of the TSP pipe).
//
// Mirrors BlendingUnit<> + BlendCoefs<> in refsw2/refsw_tile.cpp. PIPELINED,
// latency 1: measured standalone, the full comb chain (alpha-test clamp ->
// coefficient select -> 8x8 mult pair -> sum -> clamp) only makes ~78 MHz on
// Cyclone V - nowhere near the 112.5 MHz clk_sys slot. Split per stage:
//   S1 (comb off inputs -> REGISTERED): alpha-test clamp + per-channel
//      coefficient SELECT (the cheap mux tree). Registers the clamped src, the
//      dst and both coefficient vectors.
//   S2 (comb off the S1 registers -> `out`): the 8 8x8 MULTIPLIES, the
//      two-product sums, >>8 and the CLAMP to 255. The caller registers `out`
//      (peel_core: the per-half cb3_* result registers of the blend RMW).
// So inputs are sampled on one clk edge and out/at_pass describe those inputs
// during the NEXT cycle. No enable/valid: the caller tracks validity (it
// already pipelines ids alongside) and inputs may change every cycle.
//
// Colors are packed ARGB (matches the rest of the TSP path / color_combiner):
//   bits [31:24]=A, [23:16]=R, [15:8]=G, [7:0]=B.
//
// refsw:
//   src_blend = BlendCoefs<SrcInstr,false>(src,dst)
//   dst_blend = BlendCoefs<DstInstr,true >(src,dst)
//   out.c = min( (src.c*src_blend.c + dst.c*dst_blend.c) >> 8, 255 )
// Raw 8-bit coefficients, >>8 (no 8->9 *256/256 scaling); ~1 LSB low vs refsw.
//
// SrcSelect/DstSelect (secondary accumulation buffer) are NOT modelled here (we
// keep a single accumulation buffer); they are passed through for completeness
// but treated as selecting the single dst buffer.
//
// AlphaTest (punch-through) is applied when `alpha_test` is set: per refsw2 BlendingUnit,
// col.a is clamped to 0 (src.a < PT_ALPHA_REF, at_pass=0) or 255 (>= ref) BEFORE the blend,
// so the SRC_ALPHA coefficient of a PT fragment is all-or-nothing. This must ONLY be enabled
// for PUNCH-THROUGH fragments - refsw2 passes pp_AlphaTest=1 solely for RM_PUNCHTHROUGH.
// Enabling it on a translucent fragment zeroes low-alpha layers -> faint translucent.
//
// multstyle="logic": keep the 8 8x8 coefficient multiplies in ALMs instead of
// DSP blocks - the DSP pool sits ~87% full and the DSP-column detour costs more
// routing than the soft mults cost ALMs.
(* multstyle = "logic" *)
module tsp_blend (
    input             clk,
    input      [31:0] src,        // shaded source color (ARGB)
    input      [31:0] dst,        // destination / accumulation color (ARGB)
    input      [2:0]  src_instr,  // TSP.SrcInstr
    input      [2:0]  dst_instr,  // TSP.DstInstr
    input             alpha_test, // punch-through alpha test enable
    input      [7:0]  alpha_ref,  // PT_ALPHA_REF
    output     [31:0] out,        // blended color to store (1 cycle after inputs)
    output            at_pass     // alpha-test pass (always 1 when !alpha_test)
);
    // ======================= S1 (comb): clamp + coefficient select =======================
    // --- unpack ARGB ---
    wire [7:0] s_a = src[31:24], s_r = src[23:16], s_g = src[15:8], s_b = src[7:0];
    wire [7:0] d_a = dst[31:24], d_r = dst[23:16], d_g = dst[15:8], d_b = dst[7:0];

    // punch-through alpha test: clamp src alpha to 0/255 and report pass/fail
    reg [7:0] c_a;   // src alpha after alpha-test clamp
    reg       c_pass;
    always @* begin
        c_pass = 1'b1;
        c_a    = s_a;
        if (alpha_test) begin
            if (s_a < alpha_ref) begin c_a = 8'd0;   c_pass = 1'b0; end
            else                 begin c_a = 8'd255;                end
        end
    end

    // effective src color after alpha-test clamp
    wire [7:0] cs_a = c_a, cs_r = s_r, cs_g = s_g, cs_b = s_b;

    // BlendCoefs: select the per-channel coefficient for one instruction.
    //  instr>>1 : 0 zero, 1 other-color, 2 src-alpha, 3 dst-alpha
    //  instr&1  : invert (255 - coef)
    //  srcOther : selects src vs dst for the "other color" case
    //             (dst_blend uses srcOther=true -> src; src_blend uses false -> dst)
    function [31:0] blend_coefs(input [2:0] instr, input srcOther,
                                input [7:0] a_a, input [7:0] a_r, input [7:0] a_g, input [7:0] a_b, // src
                                input [7:0] b_a, input [7:0] b_r, input [7:0] b_g, input [7:0] b_b);// dst
        reg [7:0] ca, cr, cg, cb;
        begin
            case (instr[2:1])
                2'd0: begin ca=8'd0; cr=8'd0; cg=8'd0; cb=8'd0; end         // zero
                2'd1: begin                                                  // other color
                    if (srcOther) begin ca=a_a; cr=a_r; cg=a_g; cb=a_b; end
                    else          begin ca=b_a; cr=b_r; cg=b_g; cb=b_b; end
                end
                2'd2: begin ca=a_a; cr=a_a; cg=a_a; cb=a_a; end             // src alpha
                2'd3: begin ca=b_a; cr=b_a; cg=b_a; cb=b_a; end             // dst alpha
            endcase
            if (instr[0]) begin
                ca=8'd255-ca; cr=8'd255-cr; cg=8'd255-cg; cb=8'd255-cb;
            end
            blend_coefs = {ca, cr, cg, cb};
        end
    endfunction

    wire [31:0] sc = blend_coefs(src_instr, 1'b0,
                                 cs_a,cs_r,cs_g,cs_b, d_a,d_r,d_g,d_b);
    wire [31:0] dc = blend_coefs(dst_instr, 1'b1,
                                 cs_a,cs_r,cs_g,cs_b, d_a,d_r,d_g,d_b);

    // ---- S1 registers: clamped src, dst, both coefficient vectors, at flag ----
    reg [31:0] s1_cs, s1_d, s1_sc, s1_dc;
    reg        s1_at_pass;
    always @(posedge clk) begin
        s1_cs      <= {cs_a, cs_r, cs_g, cs_b};
        s1_d       <= {d_a,  d_r,  d_g,  d_b};
        s1_sc      <= sc;
        s1_dc      <= dc;
        s1_at_pass <= c_pass;
    end

    // ======================= S2 (comb off S1 regs): multiply + clamp =====================
    // per-channel: min( (src*scoef + dst*dcoef) >> 8, 255 ), raw 8-bit coefs
    // (no 8->9 to256 scaling; >>8 divides by 256). The two coefficients are
    // independent per blend mode, so this stays a genuine two-product sum.
    function [7:0] mix(input [7:0] sv, input [7:0] scoef, input [7:0] dv, input [7:0] dcoef);
        reg [16:0] acc;
        begin
            acc = sv * scoef + dv * dcoef;   // 8x8 + 8x8, max 255*255*2 = 130050
            acc = acc >> 8;
            mix = (acc > 17'd255) ? 8'd255 : acc[7:0];
        end
    endfunction

    assign out = { mix(s1_cs[31:24], s1_sc[31:24], s1_d[31:24], s1_dc[31:24]),
                   mix(s1_cs[23:16], s1_sc[23:16], s1_d[23:16], s1_dc[23:16]),
                   mix(s1_cs[15:8],  s1_sc[15:8],  s1_d[15:8],  s1_dc[15:8]),
                   mix(s1_cs[7:0],   s1_sc[7:0],   s1_d[7:0],   s1_dc[7:0]) };
    assign at_pass = s1_at_pass;
endmodule

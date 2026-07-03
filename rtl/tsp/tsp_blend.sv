//
// tsp_blend - refsw2 BlendingUnit (alpha blend at the very end of the TSP pipe).
//
// Mirrors BlendingUnit<> + BlendCoefs<> in refsw2/refsw_tile.cpp. Combinational:
// takes the shaded source color `src` (combiner output), the current destination
// `dst` (accumulation buffer pixel), and the tag's TSP blend controls, and
// produces the blended color to store back.
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
// AlphaTest (punch-through) is applied when `alpha_test` is set: if src.a <
// alpha_ref, the fragment is killed (blend is a no-op, out=dst) and `at_pass`=0.
//
module tsp_blend (
    input      [31:0] src,        // shaded source color (ARGB)
    input      [31:0] dst,        // destination / accumulation color (ARGB)
    input      [2:0]  src_instr,  // TSP.SrcInstr
    input      [2:0]  dst_instr,  // TSP.DstInstr
    input             alpha_test, // punch-through alpha test enable
    input      [7:0]  alpha_ref,  // PT_ALPHA_REF
    output reg [31:0] out,        // blended color to store
    output reg        at_pass     // alpha-test pass (always 1 when !alpha_test)
);
    // --- unpack ARGB ---
    wire [7:0] s_a = src[31:24], s_r = src[23:16], s_g = src[15:8], s_b = src[7:0];
    wire [7:0] d_a = dst[31:24], d_r = dst[23:16], d_g = dst[15:8], d_b = dst[7:0];

    // punch-through alpha test: clamp src alpha to 0/255 and report pass/fail
    reg [7:0] c_a;   // src alpha after alpha-test clamp
    always @* begin
        at_pass = 1'b1;
        c_a     = s_a;
        if (alpha_test) begin
            if (s_a < alpha_ref) begin c_a = 8'd0;   at_pass = 1'b0; end
            else                 begin c_a = 8'd255;                 end
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

    always @* begin
        out = { mix(cs_a, sc[31:24], d_a, dc[31:24]),
                mix(cs_r, sc[23:16], d_r, dc[23:16]),
                mix(cs_g, sc[15:8],  d_g, dc[15:8]),
                mix(cs_b, sc[7:0],   d_b, dc[7:0]) };
    end
endmodule

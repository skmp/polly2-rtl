//
// color_combiner - refsw ColorCombiner (texenv). STREAMED 3-stage pipeline.
// Combines base, textel, offset per ShadInstr. No bump. Offset is added
// (saturating) to rgb when pp_offset. Colours are packed {A,R,G,B} bytes.
//
//   ShadInstr 0: rv = textel
//   ShadInstr 1: rv.rgb = textel.rgb * u8_256(base.rgb)/256 ; rv.a = textel.a
//   ShadInstr 2: rv.rgb = mix(base.rgb, textel.rgb, textel.a) ; rv.a = base.a
//   ShadInstr 3: rv = textel * u8_256(base)/256  (all 4)
//   +offset: rv.rgb = min(rv.rgb + offset.rgb, 255)
//   !pp_texture: rv = base
//
// --------------------------------------------------------------------------------
// PIPELINE (per channel; the 4 ARGB channels run in parallel). The per-channel
// combine is the same delta-form lerp as tex_filter: mux -> sub -> 9x8 MULTIPLY ->
// shift+add -> clamp -> mode mux, then a saturating offset add + final muxes. In
// LOGIC-ONLY mode the multiply is the long pole, so it gets its OWN stage:
//   S1 : operand select (shadinstr mux -> sub/mA/w8) ; d = mA - sub   (mux + sub)
//   S2 : m = d*w8   (raw product, multstyle="logic" -> NO DSP)        (multiply ONLY)
//   S3 : r = sub + m>>8 ; clamp ; shadinstr output mux -> cB/cG/cR/cA ;
//        offset sat_add (pp_offset) ; pp_texture mux -> col
//
// This module does NOT buffer inputs or output: S1 samples module inputs directly
// (caller holds them stable while in_valid), `col` drives off the S3 register. The
// caller registers the output. in_valid -> out_valid (no stall: the COMB back-half
// of tsp_shade_pp advances on valid, decoupled from the front's clock-enable).
// --------------------------------------------------------------------------------
// multstyle="logic" at module scope: force EVERY multiply in color_combiner into LUT
// fabric, never a DSP block (belt-and-suspenders with the per-reg attribute on s2_m).
(* multstyle = "logic" *)
module color_combiner (
    input             clk,
    input             reset,
    input             in_valid,
    input             pp_texture,
    input             pp_offset,
    input      [1:0]  shadinstr,
    input      [31:0] base,      // {A,R,G,B}
    input      [31:0] textel,
    input      [31:0] offset,
    output            out_valid,
    output reg [31:0] col
);
    function [7:0] ch(input [31:0] c, input [1:0] i); ch = c[8*i +: 8]; endfunction
    function [7:0] sat_add(input [7:0] a, input [7:0] b);
        reg [8:0] s; begin s = {1'b0,a}+{1'b0,b}; sat_add = s[8]?8'hFF:s[7:0]; end endfunction

    // =============== STAGE 1 : operand select + delta subtract =======================
    // Per channel select sub/mA/w8 by shadinstr, then d = mA - sub. Carry the values
    // stage 3 needs for the mode-dependent output mux (t=textel ch, b=base ch, sub) +
    // the control/offset/texture bits.
    //   si2 (mix): mA=t, sub=(a-ch? t : b), w8=textel.a
    //   else (modulate): mA=t, sub=0, w8=b
    reg               v1;
    reg signed [9:0]  s1_d   [0:3];    // mA - sub in [-255,255]
    reg        [7:0]  s1_sub [0:3];    // the sub endpoint (for r = sub + ...)
    reg        [7:0]  s1_w8  [0:3];    // raw 8-bit weight
    reg        [7:0]  s1_t   [0:3];    // textel channel (for output mux)
    reg        [7:0]  s1_b   [0:3];    // base channel   (for output mux)
    reg        [1:0]  s1_shad;
    reg               s1_ptx, s1_pof;
    reg        [31:0] s1_base, s1_offset;
    integer i1; reg [1:0] c1; reg [7:0] t1, b1, sub1, mA1, w81;
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else begin
            v1 <= in_valid;
            for (i1=0; i1<4; i1=i1+1) begin
                c1 = i1[1:0];
                t1 = ch(textel,c1); b1 = ch(base,c1);
                case (shadinstr)
                  2'd2: begin mA1=t1; sub1=(c1==2'd3)? t1 : b1; w81=ch(textel,2'd3); end // mix
                  default: begin mA1=t1; sub1=8'd0; w81=b1; end                          // modulate
                endcase
                s1_d[i1]   <= $signed({2'b0,mA1}) - $signed({2'b0,sub1});
                s1_sub[i1] <= sub1;
                s1_w8[i1]  <= w81;
                s1_t[i1]   <= t1;
                s1_b[i1]   <= b1;
            end
            s1_shad   <= shadinstr;
            s1_ptx    <= pp_texture;
            s1_pof    <= pp_offset;
            s1_base   <= base;
            s1_offset <= offset;
        end
    end

    // ======================= STAGE 2 : MULTIPLY (raw product) ========================
    // m = d * w8. multstyle="logic" -> NO DSP slices. Carry sub/t/b + control.
    reg               v2;
    (* multstyle = "logic" *) reg signed [17:0] s2_m [0:3];  // 10b signed * 9b signed
    reg        [7:0]  s2_sub [0:3], s2_t [0:3], s2_b [0:3];
    reg        [1:0]  s2_shad;
    reg               s2_ptx, s2_pof;
    reg        [31:0] s2_base, s2_offset;
    integer i2; reg signed [8:0] w8_s;
    always @(posedge clk) begin
        if (reset) v2 <= 1'b0;
        else begin
            v2 <= v1;
            for (i2=0; i2<4; i2=i2+1) begin
                w8_s      = $signed({1'b0, s1_w8[i2]});
                s2_m[i2]  <= s1_d[i2] * w8_s;
                s2_sub[i2]<= s1_sub[i2];
                s2_t[i2]  <= s1_t[i2];
                s2_b[i2]  <= s1_b[i2];
            end
            s2_shad   <= s1_shad;
            s2_ptx    <= s1_ptx;
            s2_pof    <= s1_pof;
            s2_base   <= s1_base;
            s2_offset <= s1_offset;
        end
    end

    // ========== STAGE 3 : shift+add+clamp, mode mux, offset add, final mux ===========
    // r = clamp(sub + m>>8) ; shadinstr output mux -> per-ch c ; offset sat_add (rgb,
    // pp_offset) ; pp_texture mux -> col.
    function [7:0] rclamp(input signed [10:0] r);
        rclamp = (r < 0) ? 8'd0 : (r > 255) ? 8'd255 : r[7:0];
    endfunction
    reg v3;
    integer i3;
    reg [7:0] rr, cc [0:3];
    always @(posedge clk) begin
        if (reset) v3 <= 1'b0;
        else begin
            v3 <= v2;
            for (i3=0; i3<4; i3=i3+1) begin
                rr = rclamp($signed({3'b0, s2_sub[i3]}) + $signed(s2_m[i3] >>> 8));
                case (s2_shad)
                  2'd0:    cc[i3] = s2_t[i3];                       // replace
                  2'd1:    cc[i3] = (i3==3) ? s2_t[i3] : rr;        // modulate rgb, a=tex
                  2'd2:    cc[i3] = (i3==3) ? s2_b[i3] : rr;        // mix, a=base
                  default: cc[i3] = rr;                            // 2'd3: modulate all
                endcase
            end
            // offset add to rgb only (channels 0..2); alpha (3) untouched.
            begin : finish
                reg [7:0] oB,oG,oR;
                reg [31:0] tex_col;
                oB = s2_pof ? sat_add(cc[0], ch(s2_offset,2'd0)) : cc[0];
                oG = s2_pof ? sat_add(cc[1], ch(s2_offset,2'd1)) : cc[1];
                oR = s2_pof ? sat_add(cc[2], ch(s2_offset,2'd2)) : cc[2];
                tex_col = {cc[3], oR, oG, oB};
                col <= s2_ptx ? tex_col : s2_base;
            end
        end
    end

    assign out_valid = v3;
endmodule

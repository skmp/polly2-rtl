//
// tex_filter - refsw TextureFilter blend, STREAMED 6-stage pipeline (1 texel/clk).
// Point (filter 0) -> t11. Bilinear (filter 1) -> separable weighted blend.
//
// Delta-form lerp (ONE multiply per lerp, no 9-bit weight machinery):
//   lerp(p,q,w) = p + ((q-p) * w) >> 8      w = raw 8-bit weight (0..255)
// The multiply is (q-p)[10-bit signed] * w[9-bit signed] -> one signed product;
// the >>8 divides by 256. The far endpoint is approached as p + (q-p)*255/256
// (standard 8-bit bilinear, <=~1 LSB short of exact q).
// ufrac/vfrac are the FRACTIONS of the base sample: w=0 stays at the u+0/v+0
// corner, w->255 approaches u+1/v+1. Since lerp(p,q,w) weights toward q, the
// u+0 corner must be p and the u+1 corner q:
//   Rows: a=lerp(t01,t00,uf) [v+1], b=lerp(t11,t10,uf) [v+0], out=lerp(b,a,vf).
//   Corners: t00=(u+1,v+1) t01=(u+0,v+1) t10=(u+1,v+0) t11=(u+0,v+0).
// If ignore_texa: out.a = 255.
//
// --------------------------------------------------------------------------------
// PIPELINE (per channel; the 4 ARGB channels run in parallel). The blend is two
// lerps in series (row lerp feeds the column lerp), each lerp = sub -> mul -> shift
// +add -> clamp. In LOGIC-ONLY mode (multstyle="logic", NO DSP), the 9x8 multiply is
// a LUT tree - the single longest operator - so it gets its OWN stage, with the sub
// before it and the shift/add/clamp after it in SEPARATE stages. This mirrors the
// internal registering a DSP block would provide for free.
//   S1 : row sub    d_a = t00-t01 ; d_b = t10-t11               (subtracts)
//   S2 : row MUL    pa = d_a*uf ; pb = d_b*uf   (raw products)  (multiply ONLY)
//   S3 : row finish a = clamp(t01 + pa>>8) ; b = clamp(t11 + pb>>8)  (shift+add+clamp)
//   S4 : col sub    dv = b - a                                  (subtract)
//   S5 : col MUL    mv = dv*vf                 (raw product)    (multiply ONLY)
//   S6 : col finish o = clamp(a + mv>>8) ; pack ; filter/ignore_texa mux -> textel
//
// This module does NOT buffer its inputs or its output: S1 samples the module inputs
// directly (the caller holds them stable while in_valid), and `textel` is driven
// straight off the S6 stage register. The wrapping module registers the output.
// `in_valid` propagates to `out_valid` through the 6 stages.
// --------------------------------------------------------------------------------
module tex_filter (
    input             clk,
    input             reset,
    input             in_valid,
    input             filter,       // 0=point, 1=bilinear
    input             ignore_texa,
    input      [7:0]  ufrac,        // ui & 255
    input      [7:0]  vfrac,        // vi & 255
    input      [31:0] t00,t01,t10,t11,
    output            out_valid,
    output     [31:0] textel
);
    function [7:0] ch(input [31:0] c, input [1:0] i); ch = c[8*i +: 8]; endfunction
    function [7:0] lclamp(input signed [10:0] r);
        lclamp = (r < 0) ? 8'd0 : (r > 255) ? 8'd255 : r[7:0];
    endfunction

    // ============================ STAGE 1 : row subtracts ============================
    // For each channel compute the two row deltas (q-p). p = u+0 corner, q = u+1.
    //   row v+1: p=t01, q=t00   ->  d_a = t00 - t01
    //   row v+0: p=t11, q=t10   ->  d_b = t10 - t11
    // Carry the p endpoints (t01,t11), weights and control down the pipe.
    reg               v1;
    reg signed [9:0]  s1_da [0:3], s1_db [0:3];   // q-p in [-255,255]
    reg        [7:0]  s1_pa [0:3], s1_pb [0:3];   // p endpoints (t01, t11) per ch
    reg        [7:0]  s1_uf, s1_vf;
    reg               s1_filter, s1_ignta;
    reg        [31:0] s1_t11;                      // full t11 for the point (filter=0) path
    integer i1; reg [1:0] c1;
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else begin
            v1 <= in_valid;
            for (i1=0; i1<4; i1=i1+1) begin
                c1 = i1[1:0];
                s1_da[i1] <= $signed({2'b0, ch(t00,c1)}) - $signed({2'b0, ch(t01,c1)});
                s1_db[i1] <= $signed({2'b0, ch(t10,c1)}) - $signed({2'b0, ch(t11,c1)});
                s1_pa[i1] <= ch(t01,c1);
                s1_pb[i1] <= ch(t11,c1);
            end
            s1_uf     <= ufrac;
            s1_vf     <= vfrac;
            s1_filter <= filter;
            s1_ignta  <= ignore_texa;
            s1_t11    <= t11;
        end
    end

    // ============================ STAGE 2 : row MULTIPLIES ===========================
    // Raw products only - the LUT multiply gets its own stage. pa = d_a*uf, pb = d_b*uf.
    // Carry the p endpoints + weights + control. multstyle="logic" -> NO DSP slices.
    reg               v2;
    (* multstyle = "logic" *) reg signed [18:0] s2_pa [0:3], s2_pb [0:3];  // 10b*9b
    reg        [7:0]  s2_qa [0:3], s2_qb [0:3];   // p endpoints carried (t01, t11)
    reg        [7:0]  s2_vf;
    reg               s2_filter, s2_ignta;
    reg        [31:0] s2_t11;
    integer i2; reg signed [8:0] uf_s;
    always @(posedge clk) begin
        if (reset) v2 <= 1'b0;
        else begin
            v2 <= v1;
            uf_s = $signed({1'b0, s1_uf});
            for (i2=0; i2<4; i2=i2+1) begin
                s2_pa[i2] <= s1_da[i2] * uf_s;
                s2_pb[i2] <= s1_db[i2] * uf_s;
                s2_qa[i2] <= s1_pa[i2];
                s2_qb[i2] <= s1_pb[i2];
            end
            s2_vf     <= s1_vf;
            s2_filter <= s1_filter;
            s2_ignta  <= s1_ignta;
            s2_t11    <= s1_t11;
        end
    end

    // ============================ STAGE 3 : row FINISH ===============================
    // a = clamp(p + (pa>>8)) ; b = clamp(p + (pb>>8)). Shift + add + clamp (no mul).
    reg               v3;
    reg        [7:0]  s3_a [0:3], s3_b [0:3];
    reg        [7:0]  s3_vf;
    reg               s3_filter, s3_ignta;
    reg        [31:0] s3_t11;
    integer i3;
    always @(posedge clk) begin
        if (reset) v3 <= 1'b0;
        else begin
            v3 <= v2;
            for (i3=0; i3<4; i3=i3+1) begin
                s3_a[i3] <= lclamp($signed({3'b0, s2_qa[i3]}) + $signed(s2_pa[i3] >>> 8));
                s3_b[i3] <= lclamp($signed({3'b0, s2_qb[i3]}) + $signed(s2_pb[i3] >>> 8));
            end
            s3_vf     <= s2_vf;
            s3_filter <= s2_filter;
            s3_ignta  <= s2_ignta;
            s3_t11    <= s2_t11;
        end
    end

    // ============================ STAGE 4 : column sub ===============================
    // dv = b - a. Carry a (the column-lerp p endpoint) + weight + control.
    reg               v4;
    reg signed [9:0]  s4_dv [0:3];      // b-a in [-255,255]
    reg        [7:0]  s4_a  [0:3];      // column-lerp p endpoint (= a)
    reg        [7:0]  s4_vf;
    reg               s4_filter, s4_ignta;
    reg        [31:0] s4_t11;
    integer i4;
    always @(posedge clk) begin
        if (reset) v4 <= 1'b0;
        else begin
            v4 <= v3;
            for (i4=0; i4<4; i4=i4+1) begin
                s4_dv[i4] <= $signed({2'b0, s3_b[i4]}) - $signed({2'b0, s3_a[i4]});
                s4_a[i4]  <= s3_a[i4];
            end
            s4_vf     <= s3_vf;
            s4_filter <= s3_filter;
            s4_ignta  <= s3_ignta;
            s4_t11    <= s3_t11;
        end
    end

    // ============================ STAGE 5 : column MULTIPLY ==========================
    // Raw product only: mv = dv*vf. multstyle="logic" -> NO DSP. Carry a + control.
    reg               v5;
    (* multstyle = "logic" *) reg signed [18:0] s5_mv [0:3];  // dv*vf
    reg        [7:0]  s5_a [0:3];
    reg               s5_filter, s5_ignta;
    reg        [31:0] s5_t11;
    integer i5; reg signed [8:0] vf_s;
    always @(posedge clk) begin
        if (reset) v5 <= 1'b0;
        else begin
            v5 <= v4;
            vf_s = $signed({1'b0, s4_vf});
            for (i5=0; i5<4; i5=i5+1) begin
                s5_mv[i5] <= s4_dv[i5] * vf_s;
                s5_a[i5]  <= s4_a[i5];
            end
            s5_filter <= s4_filter;
            s5_ignta  <= s4_ignta;
            s5_t11    <= s4_t11;
        end
    end

    // ============= STAGE 6 : column FINISH + pack + mux (textel out) =================
    // o = clamp(a + (mv>>8)). Assemble bilinear ARGB; select point (t11) if !filter;
    // force alpha 0xFF if ignore_texa. `textel` is this stage register (no extra buf).
    reg               v6;
    reg        [31:0] s6_textel;
    integer i6;
    reg        [7:0]  o [0:3];
    always @(posedge clk) begin
        if (reset) v6 <= 1'b0;
        else begin
            v6 <= v5;
            for (i6=0; i6<4; i6=i6+1)
                o[i6] = lclamp($signed({3'b0, s5_a[i6]}) + $signed(s5_mv[i6] >>> 8));
            // o[3]=A o[2]=R o[1]=G o[0]=B  -> {A,R,G,B}
            begin : pack
                reg [31:0] bilin, pre;
                bilin = {o[3], o[2], o[1], o[0]};
                pre   = s5_filter ? bilin : s5_t11;
                s6_textel <= s5_ignta ? {8'hFF, pre[23:0]} : pre;
            end
        end
    end

    assign out_valid = v6;
    assign textel    = s6_textel;
endmodule

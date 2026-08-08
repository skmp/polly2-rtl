//
// fog_blend - refsw2 FogUnit(): colour CLAMP + fog blend at the end of the TSP pipe.
//
//   if (ColorClamp)  col.c = min(max(col.c, FOG_CLAMP_MIN.c), FOG_CLAMP_MAX.c)   (all 4)
//   FogCtrl 00 (LUT)        : col.rgb = mix(col.rgb, FOG_COL_RAM.rgb,  fog_alpha)
//   FogCtrl 11 (LUT mode 2) : col.rgb = FOG_COL_RAM.rgb ; col.a = fog_alpha
//   FogCtrl 01 (per vertex) : if (Offset) col.rgb = mix(col.rgb, FOG_COL_VERT.rgb, offs.a)
//   FogCtrl 10 (no fog)     : unchanged
//
// RAW 8-BIT WEIGHTS, >>8 - the imperfect *255/256 rounding tsp_blend already uses, NOT
// refsw2's to_u8_256() rescale, so a full-fog pixel lands ~1 LSB low (254, not 255).
//
// TODO: none of this has been tested against real hardware - see the TODO block in
// fog_lut.sv for what a HW capture would settle (the rounding convention above, and
// whether LUT mode 2 replaces the BASE colour before the combiner rather than the
// final colour as it does here).
//
// ONE MULTIPLY PER CHANNEL. With raw weights a and 255-a the mix folds to a delta form
//     c' = (c*255 + (f - c) * a) >> 8
// where c*255 is a shift-subtract ((c<<8) - c), not a multiply - so the only real
// multiplier is the 9x8 delta*weight, three of them (rgb; alpha is never fogged).
//
// PIPELINE (3 stages, all added BEHIND color_combiner so no existing stage grows):
//   S1 : colour clamp; mode decode; d = fogcol - col ; c255 = (col<<8) - col
//   S2 : m = d * a          (multstyle=logic -> ALMs, the DSP pool is ~full)
//   S3 : c' = (c255 + m) >>> 8 ; mode output mux
//
// Colours are packed ARGB ([31:24]=A, [23:16]=R, [15:8]=G, [7:0]=B) like the rest of
// the TSP path; FOG_COL_RAM / FOG_COL_VERT / FOG_CLAMP_* use the same layout (they are
// PVR Color words), so every channel is a plain byte lane.
//
// in_valid -> out_valid after 3 clocks. No stall: like color_combiner, the COMB back
// half of the shader advances on valid.
//
(* multstyle = "logic" *)
module fog_blend (
    input             clk,
    input             reset,
    input             in_valid,
    input      [31:0] col,            // colour combiner result (ARGB)
    input      [7:0]  fog_alpha,      // LUT fog alpha for this pixel (fog_lut)
    input      [7:0]  offs_a,         // interpolated offset alpha (per-vertex fog)
    input      [1:0]  fog_ctrl,       // TSP.FogCtrl [23:22]
    input             color_clamp,    // TSP.ColorClamp [21]
    input             pp_offset,      // ISP.Offset (per-vertex fog is gated on it)
    input      [31:0] fog_col_ram,    // FOG_COL_RAM
    input      [31:0] fog_col_vert,   // FOG_COL_VERT
    input      [31:0] fog_clamp_max,  // FOG_CLAMP_MAX
    input      [31:0] fog_clamp_min,  // FOG_CLAMP_MIN
    output            out_valid,
    output reg [31:0] out_col
);
    function [7:0] ch(input [31:0] c, input [1:0] i); ch = c[8*i +: 8]; endfunction

    // ============ S1: colour clamp + mode decode + delta / weight ==================
    // Mode decode (refsw2 FogUnit's switch):
    //   lut   = FogCtrl 00 or 11 -> weight is the table alpha, colour is FOG_COL_RAM
    //   vert  = FogCtrl 01 && Offset -> weight is offs.a, colour is FOG_COL_VERT
    //   mode2 = FogCtrl 11 -> rgb REPLACED by FOG_COL_RAM, alpha := fog_alpha
    wire        s1_lut   = (fog_ctrl == 2'b00) || (fog_ctrl == 2'b11);
    wire        s1_vert  = (fog_ctrl == 2'b01) && pp_offset;
    wire        s1_mode2 = (fog_ctrl == 2'b11);
    wire [7:0]  s1_a     = s1_vert ? offs_a : fog_alpha;
    wire [31:0] s1_fcol  = s1_vert ? fog_col_vert : fog_col_ram;

    reg               v1;
    reg        [31:0] s1_col;                 // clamped colour
    reg signed [9:0]  s1_d    [0:2];          // fogcol.c - col.c   (rgb only)
    reg        [15:0] s1_c255 [0:2];          // col.c * 255        (rgb only)
    reg        [7:0]  s1_w;                   // raw 8-bit weight
    reg        [7:0]  s1_alpha;               // alpha for LUT mode 2
    reg        [23:0] s1_ram;                 // FOG_COL_RAM rgb (mode 2 replace)
    reg               s1_blend, s1_m2;
    integer i1; reg [7:0] cc1, cl1;
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else begin
            v1 <= in_valid;
            for (i1 = 0; i1 < 4; i1 = i1 + 1) begin
                cc1 = ch(col, i1[1:0]);
                if (color_clamp) begin
                    cl1 = (cc1 > ch(fog_clamp_max, i1[1:0])) ? ch(fog_clamp_max, i1[1:0]) : cc1;
                    cl1 = (cl1 < ch(fog_clamp_min, i1[1:0])) ? ch(fog_clamp_min, i1[1:0]) : cl1;
                end else cl1 = cc1;
                s1_col[8*i1 +: 8] <= cl1;
                if (i1 < 3) begin
                    s1_d[i1]    <= $signed({2'b0, ch(s1_fcol, i1[1:0])}) - $signed({2'b0, cl1});
                    s1_c255[i1] <= {cl1, 8'd0} - {8'd0, cl1};      // cl1 * 255
                end
            end
            s1_w     <= s1_a;
            s1_alpha <= fog_alpha;
            s1_ram   <= fog_col_ram[23:0];
            s1_blend <= s1_lut || s1_vert;
            s1_m2    <= s1_mode2;
        end
    end

    // ============ S2: the three multiplies =========================================
    reg               v2;
    reg signed [17:0] s2_m    [0:2];
    reg        [15:0] s2_c255 [0:2];
    reg        [31:0] s2_col;
    reg        [7:0]  s2_alpha;
    reg        [23:0] s2_ram;
    reg               s2_blend, s2_m2;
    integer i2;
    always @(posedge clk) begin
        if (reset) v2 <= 1'b0;
        else begin
            v2 <= v1;
            for (i2 = 0; i2 < 3; i2 = i2 + 1) begin
                s2_m[i2]    <= s1_d[i2] * $signed({1'b0, s1_w});
                s2_c255[i2] <= s1_c255[i2];
            end
            s2_col   <= s1_col;
            s2_alpha <= s1_alpha;
            s2_ram   <= s1_ram;
            s2_blend <= s1_blend;
            s2_m2    <= s1_m2;
        end
    end

    // ============ S3: (c255 + m) >>> 8, output mux =================================
    // c*255 + (f-c)*a is a convex combination scaled by 255, so the sum is in
    // [0, 65025] and the shifted result in [0,254] - no clamp needed.
    reg v3;
    integer i3; reg [7:0] rgb [0:2]; reg signed [18:0] sum3;
    always @(posedge clk) begin
        if (reset) v3 <= 1'b0;
        else begin
            v3 <= v2;
            for (i3 = 0; i3 < 3; i3 = i3 + 1) begin
                sum3     = $signed({3'b0, s2_c255[i3]}) + {{1{s2_m[i3][17]}}, s2_m[i3]};
                rgb[i3]  = 8'(sum3 >>> 8);
            end
            if (s2_m2)          out_col <= {s2_alpha, s2_ram};
            else if (s2_blend)  out_col <= {s2_col[31:24], rgb[2], rgb[1], rgb[0]};
            else                out_col <= s2_col;
        end
    end

    assign out_valid = v3;
endmodule

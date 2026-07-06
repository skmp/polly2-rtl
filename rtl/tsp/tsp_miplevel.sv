//
// tsp_miplevel - exponent-domain mip level (LOD) selection. STREAMED 2-stage pipeline.
//
// Approximates refsw2's faux-mip calc (refsw_tile.cpp PixelFlush_tsp):
//   ddx  = U.ddx + V.ddx ;  ddy = U.ddy + V.ddy      (interpolation plane deltas)
//   dMip = min(|ddx|,|ddy|) * W * sizeU * MipMapD/4  ;  sizeU = 8 << TexU
//   MipLevel = 0; while (dMip > 1.5 && MipLevel < 11) { MipLevel++; dMip /= 2; }
//
// Done purely in the float exponent domain (cheap: adds/subtract, no float
// multiply, no divide loop):
//   log2(dMip) ~= (e_min - 127) + (e_W - 127) + log2(sizeU) + log2(MipMapD/4)
//     e_min = min(exp(ddx), exp(ddy))    (exp of a float f = f[30:23])
//     exp(ddx=U.ddx+V.ddx) ~= max(exp(U.ddx), exp(V.ddx))   (sum ~ larger term)
//     log2(sizeU)     = 3 + TexU
//     log2(MipMapD/4) ~= msb_index(MipMapD) - 2
//   MipLevel = clamp( round(log2(dMip)), 0, TexU+3 )   (0..11 overall)
//
// This is within ~+/-1 level of refsw near boundaries. miplevel is 0 when not
// mipmapped or when the LOD is <= 0.
//
// --------------------------------------------------------------------------------
// PIPELINE. The combinational path is a serial cascade: max(exp) -> min(exp) (two
// dependent compares) -> a 6-operand `lod` add -> two signed clamp compares -> mux.
// Split after the min/max reduction so the compare cascade and the add+clamp are in
// separate stages:
//   S1 : exponent extracts ; eX=max,eY=max ; eMin=min ; pick mMin ; mmd_log2 (casez)
//   S2 : lod = eMin+eW+texu+mmd_log2+mMin+mW-254 ; clamp -> miplevel
//
// HOLD (backpressure): lives inside tsp_shade_pp's `en`-gated front (a texture-cache
// miss freezes the whole front via one clock-enable). Takes `stall` (same convention
// as fp_rcp_fast): stall=1 freezes all internal stage registers. in_valid->out_valid.
//
// No input/output buffering: S1 samples module inputs directly (caller holds them
// stable while in_valid && !stall); miplevel is driven off the S2 register.
// --------------------------------------------------------------------------------
module tsp_miplevel (
    input             clk,
    input             reset,
    input             stall,        // 1 = freeze all stages (front-pipe hold)
    input             in_valid,
    input      [31:0] ddxU, ddxV,   // U/V interpolation-plane ddx
    input      [31:0] ddyU, ddyV,   // U/V interpolation-plane ddy
    input      [31:0] w,            // 1/invW (perspective W)
    input      [2:0]  texu,         // TSP.TexU
    input      [3:0]  mipmapd,      // TSP.MipMapD
    input             mipmapped,    // TCW.MipMapped
    output            out_valid,
    output reg [3:0]  miplevel
);
    // biased exponents + top mantissa bit (the fractional log2 term the exponent-only
    // estimate drops; recovers the ~1-2 level underestimate of a floor()-only LOD).
    wire [7:0] eXu = ddxU[30:23], eXv = ddxV[30:23];
    wire [7:0] eYu = ddyU[30:23], eYv = ddyV[30:23];
    wire mXu = ddxU[22], mXv = ddxV[22];
    wire mYu = ddyU[22], mYv = ddyV[22];

    // exp(ddx) ~ max of the two summed terms; pick that term's mantissa bit too.
    wire [7:0] eX = (eXu >= eXv) ? eXu : eXv;   wire mX = (eXu >= eXv) ? mXu : mXv;
    wire [7:0] eY = (eYu >= eYv) ? eYu : eYv;   wire mY = (eYu >= eYv) ? mYu : mYv;
    // min(|ddx|,|ddy|): the smaller-exponent axis; carry its mantissa bit.
    wire [7:0] eMin = (eX <= eY) ? eX : eY;     wire mMin = (eX <= eY) ? mX : mY;

    // log2(MipMapD): index of the most-significant set bit (0 if MipMapD==0).
    reg [2:0] mmd_log2_c;
    always @* begin
        casez (mipmapd)
            4'b1???: mmd_log2_c = 3'd3;
            4'b01??: mmd_log2_c = 3'd2;
            4'b001?: mmd_log2_c = 3'd1;
            default: mmd_log2_c = 3'd0;   // 0001 or 0000
        endcase
    end

    // ============ STAGE 1 : min/max exponent reduction + mmd_log2 ====================
    reg               v1;
    reg        [7:0]  s1_eMin, s1_eW;
    reg               s1_mMin, s1_mW;
    reg        [2:0]  s1_mmd_log2;
    reg        [2:0]  s1_texu;
    reg               s1_mipmapped;
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else if (!stall) begin
            v1          <= in_valid;
            s1_eMin     <= eMin;
            s1_mMin     <= mMin;
            s1_eW       <= w[30:23];
            s1_mW       <= w[22];
            s1_mmd_log2 <= mmd_log2_c;
            s1_texu     <= texu;
            s1_mipmapped<= mipmapped;
        end
    end

    // ================= STAGE 2 : lod accumulate + clamp -> miplevel ===================
    // log2(dMip): (eMin-127)+(eW-127)+(3+TexU)+(mmd_log2-2)+mMin+mW
    //           = eMin + eW + TexU + mmd_log2 + mMin + mW - 253, biased -1 more (-254)
    //             to select one lower (sharper) mip level.
    wire signed [11:0] lod =
          $signed({4'd0, s1_eMin})
        + $signed({4'd0, s1_eW})
        + $signed({9'd0, s1_texu})
        + $signed({9'd0, s1_mmd_log2})
        + $signed({11'd0, s1_mMin})
        + $signed({11'd0, s1_mW})
        - 12'sd254;
    wire [3:0] lvl_max = 4'(3) + {1'b0, s1_texu};   // TexU+3 (max 10)
    reg v2;
    always @(posedge clk) begin
        if (reset) v2 <= 1'b0;
        else if (!stall) begin
            v2 <= v1;
            if (!s1_mipmapped)                        miplevel <= 4'd0;
            else if (lod <= 0)                        miplevel <= 4'd0;
            else if (lod >= $signed({8'd0, lvl_max})) miplevel <= lvl_max;
            else                                      miplevel <= lod[3:0];
        end
    end

    assign out_valid = v2;
endmodule

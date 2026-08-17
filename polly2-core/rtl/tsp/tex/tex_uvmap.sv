//
// tex_uvmap - convert interpolated (float) u,v to fixed texel coords and the
// four bilinear corner integer coords (ClampFlip'd). STREAMED 3-stage pipeline.
//
// refsw: sizeU=8<<TexU, sizeV=8<<TexV (no mipmap here).
//   ui = u*sizeU*256 (+halfpixel) ; vi = v*sizeV*256 (+halfpixel)
//   halfpixel = half_texel ? -128 : 0   (-0.5 texel exactly; refsw2 uses -127)
//   base texel = (ui>>8, vi>>8); corners: (+1,+1)(+0,+1)(+1,+0)(+0,+0)
//   each corner ClampFlip(coord,size). fractions ufrac=ui&255, vfrac=vi&255.
//
// ui = u * 2^(11+TexU) since sizeU*256 = 2^(11+TexU). So ui is u reinterpreted
// with the binary point shifted - a float->fixed extraction, no multiplier.
//
// --------------------------------------------------------------------------------
// PIPELINE. float->fixed (to_fixed) is a SERIAL chain that a naive one-stage split
// left fused (Fmax stuck): shift = tex+11-mip (add) -> p = e-150+shift (dependent
// add) -> 56-bit VARIABLE BARREL SHIFT -> 27-bit two's-complement NEGATE. We break
// that chain so each heavy piece stands alone, and DEFER the negate off the shift's
// tail into a stage with only cheap ops:
//   S1 : shift amount   p_u = e_u-150+(texu+11-mip) ; p_v = ...   (the two adders)
//        carry sig (1.m), sign bit, zero flag, sizeU/V, clamp/flip controls
//   S2 : barrel shift   |ui| = sig << p / sig >> -p   (MAGNITUDE only, no negate)
//   S3 : apply sign + >>8 + corners + 8x clampflip -> the 8 corner outputs. The
//        negate/>>8/+1 and the clampflip fan-out fit one clock (S1+S2 must stay
//        split - fusing them drops to ~105 MHz; this tail has slack at >120).
//
// HOLD (backpressure): lives inside tsp_shade_pp's `en`-gated front, where a texture-
// cache miss freezes the WHOLE front together via one clock-enable. Takes a `stall`
// input (identical convention to fp_rcp_fast): stall=1 freezes ALL internal stage
// registers, keeping this sub-pipeline in lockstep. `in_valid` -> `out_valid`.
//
// No input/output buffering: S1 samples module inputs directly (caller holds them
// stable while in_valid && !stall); corner outputs drive straight off the S4 regs.
// --------------------------------------------------------------------------------
// TODO: VERIFY THE TEXEL SAMPLING AGAINST REAL HARDWARE. Two things in this file are
// deliberate divergences from refsw2, both justified by rendered artifacts and by the
// texel-centre reading of HALF_OFFSET (see tex_unit's note), neither by silicon:
//
//   * the half-texel bias is -128, EXACTLY half a texel (256 = 1.0). refsw2 uses -127,
//     which lands 1/256 short and leaves frac=1 on every texel of a 1:1 sprite forever.
//     -128 is what makes frac come out 0, which is the point of the setting. If a HW
//     capture ever shows a systematic 1/256 bias, refsw2's constant is the right one.
//
//   * the float->fixed step ROUNDS UP by 1/64 LSB (EPS below) instead of truncating.
//     This is a workaround for OUR arithmetic, not a model of the hardware: the
//     interpolation chain lands a hair below an exact 8.8 boundary and plain truncation
//     then costs a WHOLE texel. If the interpolation is ever made exact at the boundary
//     (the reciprocal was the dominant term and is now ~3.3e-7), this epsilon should be
//     re-measured and probably removed rather than left in as folklore.
//     The +uvx/+uvy probe in tsp_shade_v2_pp reports the remainder that sizes it.
//
module tex_uvmap (
    input             clk,
    input             reset,
    input             stall,        // 1 = freeze all stages (front-pipe hold)
    input             in_valid,
    input      [31:0] u,            // float
    input      [31:0] v,            // float
    input      [2:0]  texu,
    input      [2:0]  texv,
    input      [3:0]  miplevel,     // mip level (0 = base); size = (8<<TexU)>>mip
    input             clampu, clampv, flipu, flipv,
    // HALF-TEXEL OFFSET (HALF_OFFSET.texure_pixel_half_offset). Applied to the 8.8
    // fixed texel coordinate, so it shifts BOTH the corner selection and the bilinear
    // fractions - which is the point: it moves the sample toward the texel CENTRE.
    // The bias is -128, i.e. EXACTLY half a texel (256 = 1.0 texel). refsw2 uses -127,
    // which lands 1/256 of a texel short and biases every filtered sample slightly
    // toward the lower texel; this design does not copy that off-by-one. Expect a
    // 1-LSB-scale difference against refsw2 captures because of it.
    input             half_texel,

    output            out_valid,
    output reg [10:0] c00u, output reg [10:0] c00v,   // (u+1,v+1)
    output reg [10:0] c01u, output reg [10:0] c01v,   // (u+0,v+1)
    output reg [10:0] c10u, output reg [10:0] c10v,   // (u+1,v+0)
    output reg [10:0] c11u, output reg [10:0] c11v,   // (u+0,v+0)
    output reg [7:0]  ufrac, output reg [7:0]  vfrac
);
    // mip-adjusted shift: sizeU*256 = 2^(11 + TexU - MipLevel).
    wire [4:0] shift_u = ({2'b0,texu} + 5'd11) - {1'b0,miplevel};
    wire [4:0] shift_v = ({2'b0,texv} + 5'd11) - {1'b0,miplevel};
    wire [10:0] sizeU_c = (11'd8 << texu) >> miplevel;
    wire [10:0] sizeV_c = (11'd8 << texv) >> miplevel;

    // ================= STAGE 1 : shift amount p (two dependent adders) ================
    // p = (e-127-23) + shift = e - 150 + shift. Carry sig=1.m, sign, zero flag.
    // p in ~[-150..+40]; keep it signed 10b. Denormal/zero (e==0) -> mag forced 0.
    reg               v1;
    reg signed [9:0]  s1_pu, s1_pv;         // shift amounts
    reg        [23:0] s1_sigu, s1_sigv;     // 1.m mantissas
    reg               s1_su, s1_sv;         // sign bits (f[31])
    reg               s1_half;            // half-texel offset select, riding the pipe
    reg               s1_zu, s1_zv;         // operand-is-zero (e==0 -> result 0)
    reg        [10:0] s1_sizeU, s1_sizeV;
    reg               s1_clampu,s1_clampv,s1_flipu,s1_flipv;
    always @(posedge clk) begin
        if (reset) v1 <= 1'b0;
        else if (!stall) begin
            v1     <= in_valid;
            s1_pu  <= ($signed({2'b0,u[30:23]}) - 10'sd150) + $signed({5'b0,shift_u});
            s1_pv  <= ($signed({2'b0,v[30:23]}) - 10'sd150) + $signed({5'b0,shift_v});
            s1_sigu<= {1'b1, u[22:0]};
            s1_sigv<= {1'b1, v[22:0]};
            s1_su  <= u[31];  s1_sv <= v[31];
            s1_half<= half_texel;
            s1_zu  <= (u[30:23]==8'd0);
            s1_zv  <= (v[30:23]==8'd0);
            s1_sizeU<= sizeU_c; s1_sizeV<= sizeV_c;
            s1_clampu<= clampu; s1_clampv<= clampv;
            s1_flipu <= flipu;  s1_flipv <= flipv;
        end
    end

    // ================= STAGE 2 : barrel shift (MAGNITUDE only) ========================
    // |ui| = sig << p (p>=0) or sig >> -p (p<0), Q19.8. No negate here - the sign is
    // deferred to S3. sig is 24b at bit .23; shifting by p lands the value in Q19.8.
    // Produces Q19.14 - SIX guard bits beyond the Q19.8 the corner/frac outputs need,
    // so S3 can nudge a value that sits a hair below an integer boundary without
    // disturbing one that legitimately sits mid-texel. See the S3 note.
    function [32:0] barrel(input [23:0] sig, input signed [9:0] p, input zero);
        reg [55:0] wide; reg signed [9:0] p1;
        begin
            if (zero) barrel = 33'd0;
            else begin
                p1   = p + 10'sd6;                  // keep six guard bits
                wide = {32'd0, sig};
                if (p1 >= 0) wide = wide << p1[5:0];
                else         wide = wide >> (-p1);
                barrel = wide[32:0];
            end
        end
    endfunction
    reg               v2;
    reg        [32:0] s2_magu, s2_magv;     // |ui|, |vi| in Q19.14 (unsigned magnitude)
    reg               s2_su, s2_sv;
    reg               s2_half;
    reg        [10:0] s2_sizeU, s2_sizeV;
    reg               s2_clampu,s2_clampv,s2_flipu,s2_flipv;
    always @(posedge clk) begin
        if (reset) v2 <= 1'b0;
        else if (!stall) begin
            v2      <= v1;
            s2_magu <= barrel(s1_sigu, s1_pu, s1_zu);
            s2_magv <= barrel(s1_sigv, s1_pv, s1_zv);
            s2_su   <= s1_su; s2_sv <= s1_sv;
            s2_half <= s1_half;
            s2_sizeU<= s1_sizeU; s2_sizeV<= s1_sizeV;
            s2_clampu<= s1_clampu; s2_clampv<= s1_clampv;
            s2_flipu <= s1_flipu;  s2_flipv <= s1_flipv;
        end
    end

    // ===== STAGE 3 : apply sign + >>8 + corners + 8x clampflip -> outputs ============
    // ui = sign ? -mag : mag (two's comp) ; uint = ui>>>8 ; u0/u1/v0/v1 corners ;
    // then 8x ClampFlip straight into the output registers. All combinational off the
    // registered s2_mag/sign; the negate/>>8/+1 and clampflip fan-out share this clock.
    // SNAP-UP, not round-to-nearest. With HALF_OFFSET active the exact answer sits ON an
    // integer 8.8 boundary by construction (the -128 texel bias cancels the +0.5 pixel
    // centre, so a 1:1 sprite wants frac=0 on every pixel), and the interpolation chain
    // (truncating multiplies + a truncating 3-input add) lands a hair BELOW it. Plain
    // truncation then costs a WHOLE texel - texel -1 wrapping at a sprite's last row,
    // seen as a one-pixel line.
    // The correction is sized from measurement, not guessed: the observed shortfall is
    // ~0.007 LSB (remainder 0.993), while genuine mid-texel samples sit 0.24-0.32 away
    // from the boundary. EPS = 1/64 LSB catches any remainder >= 63/64 and leaves
    // everything else untouched - ~45x margin below the nearest legitimate value.
    // Round-to-nearest (+1/2 LSB) was tried first and is far too blunt: it would also
    // shove every value past the midpoint into the next texel.
    // NOTE a deliberate divergence from refsw2, which truncates - it computes in host
    // floats that land exactly, so it never sees the shortfall.
    localparam [32:0] EPS = 33'd1;                 // 1/64 LSB, with 6 guard bits
    // THE THREE ADDS ABOVE ARE ONE ADD. Written literally - `(mag+EPS)>>6`, then the
    // sign negate, then `+ half_bias` - this synthesised to three CASCADED adders
    // (Add13 -> Add15 -> Add17) in front of the clampflip compare, and stage 3 was the
    // worst path in the texture unit (-5.033 ns at 143 MHz, 7 logic levels). All three
    // collapse because two of them add a CONSTANT:
    //
    //   (mag + 1) >> 6  ==  mag[32:6] + (&mag[5:0])      - the +1 only ever carries
    //                                                      out of the low 6 bits
    //   -(m + c)        ==  ~m + (1 - c)  ==  ~m + !c    - for c in {0,1}
    //
    // so  ui = (su ? ~m6 : m6) + K,  K = (su ? !eps_c : eps_c) + (half ? -128 : 0),
    // and K is ONE OF FOUR CONSTANTS selected by two bits - a mux, not an adder.
    // Bit-exact with the original, including the 27-bit wrap: everything below is the
    // same value mod 2^27, and `magu8` was already reinterpreted as signed 27-bit.
    wire [26:0] m6u   = s2_magu[32:6];
    wire [26:0] m6v   = s2_magv[32:6];
    wire        epscu = &s2_magu[5:0];             // EPS carries into bit 6
    wire        epscv = &s2_magv[5:0];
    wire [26:0] m6su  = s2_su ? ~m6u : m6u;        // conditional invert = negate less cin
    wire [26:0] m6sv  = s2_sv ? ~m6v : m6v;
    wire        cinu  = s2_su ? ~epscu : epscu;    // the negate's +1, less the EPS carry
    wire        cinv  = s2_sv ? ~epscv : epscv;
    // K: -0.5 texel exactly (half_bias) merged with the carry-in. Four constants.
    wire signed [26:0] ku = s2_half ? (cinu ? -27'sd127 : -27'sd128)
                                    : (cinu ?  27'sd1   :  27'sd0);
    wire signed [26:0] kv = s2_half ? (cinv ? -27'sd127 : -27'sd128)
                                    : (cinv ?  27'sd1   :  27'sd0);
    wire signed [26:0] ui = $signed(m6su) + ku;
    wire signed [26:0] vi = $signed(m6sv) + kv;
    wire signed [18:0] uint = ui >>> 8;      // arith (floors toward -inf, matching refsw)
    wire signed [18:0] vint = vi >>> 8;
    wire signed [20:0] cu0 = 21'(signed'(uint));
    wire signed [20:0] cu1 = 21'(signed'(uint)) + 21'sd1;
    wire signed [20:0] cv0 = 21'(signed'(vint));
    wire signed [20:0] cv1 = 21'(signed'(vint)) + 21'sd1;

    // ClampFlip(coord, size): clamp / flip(mirror) / wrap
    function [10:0] clampflip(input clamp, input flip, input signed [20:0] coord, input [10:0] size);
        reg signed [20:0] c;
        begin
            if (clamp) begin
                if (coord < 0)               clampflip = 11'd0;
                else if (coord >= size)      clampflip = size - 11'd1;
                else                         clampflip = coord[10:0];
            end else if (flip) begin
                c = coord & ((size<<1)-1);
                if (c & size) c = c ^ ((size<<1)-1);
                clampflip = c[10:0];
            end else begin
                clampflip = coord & (size-11'd1);   // wrap
            end
        end
    endfunction
    reg v3;
    always @(posedge clk) begin
        if (reset) v3 <= 1'b0;
        else if (!stall) begin
            v3    <= v2;
            ufrac <= ui[7:0];        // fraction (positive even for negative ui)
            vfrac <= vi[7:0];
            c00u  <= clampflip(s2_clampu,s2_flipu,cu1,s2_sizeU);
            c00v  <= clampflip(s2_clampv,s2_flipv,cv1,s2_sizeV);
            c01u  <= clampflip(s2_clampu,s2_flipu,cu0,s2_sizeU);
            c01v  <= clampflip(s2_clampv,s2_flipv,cv1,s2_sizeV);
            c10u  <= clampflip(s2_clampu,s2_flipu,cu1,s2_sizeU);
            c10v  <= clampflip(s2_clampv,s2_flipv,cv0,s2_sizeV);
            c11u  <= clampflip(s2_clampu,s2_flipu,cu0,s2_sizeU);
            c11v  <= clampflip(s2_clampv,s2_flipv,cv0,s2_sizeV);
        end
    end

    assign out_valid = v3;
endmodule

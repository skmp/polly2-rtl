//
// tex_uvmap - convert interpolated (float) u,v to fixed texel coords and the
// four bilinear corner integer coords (ClampFlip'd). STREAMED 3-stage pipeline.
//
// refsw: sizeU=8<<TexU, sizeV=8<<TexV (no mipmap here).
//   ui = u*sizeU*256 (+halfpixel, 0 here) ; vi = v*sizeV*256
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
    function [26:0] barrel(input [23:0] sig, input signed [9:0] p, input zero);
        reg [55:0] wide;
        begin
            if (zero) barrel = 27'd0;
            else begin
                wide = {32'd0, sig};
                if (p >= 0) wide = wide << p[5:0];
                else        wide = wide >> (-p);
                barrel = wide[26:0];
            end
        end
    endfunction
    reg               v2;
    reg        [26:0] s2_magu, s2_magv;     // |ui|, |vi| in Q19.8 (unsigned magnitude)
    reg               s2_su, s2_sv;
    reg        [10:0] s2_sizeU, s2_sizeV;
    reg               s2_clampu,s2_clampv,s2_flipu,s2_flipv;
    always @(posedge clk) begin
        if (reset) v2 <= 1'b0;
        else if (!stall) begin
            v2      <= v1;
            s2_magu <= barrel(s1_sigu, s1_pu, s1_zu);
            s2_magv <= barrel(s1_sigv, s1_pv, s1_zv);
            s2_su   <= s1_su; s2_sv <= s1_sv;
            s2_sizeU<= s1_sizeU; s2_sizeV<= s1_sizeV;
            s2_clampu<= s1_clampu; s2_clampv<= s1_clampv;
            s2_flipu <= s1_flipu;  s2_flipv <= s1_flipv;
        end
    end

    // ===== STAGE 3 : apply sign + >>8 + corners + 8x clampflip -> outputs ============
    // ui = sign ? -mag : mag (two's comp) ; uint = ui>>>8 ; u0/u1/v0/v1 corners ;
    // then 8x ClampFlip straight into the output registers. All combinational off the
    // registered s2_mag/sign; the negate/>>8/+1 and clampflip fan-out share this clock.
    wire signed [26:0] ui = s2_su ? -$signed(s2_magu) : $signed(s2_magu);
    wire signed [26:0] vi = s2_sv ? -$signed(s2_magv) : $signed(s2_magv);
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

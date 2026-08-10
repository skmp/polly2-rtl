//
// interp_unit - the tsp_shade_pp INTERP block as a standalone streamed unit, built
// from the PIPELINED FP units (coord_f32 + fp_mul16_spp_ro / fp_add3_24_pp / fp_mul16_pp).
// (File stage_interp.sv; the timing-harness TOP is a separate module `stage_interp`
// in timming_tests/stage_interp/ that instantiates this.)
//
// ABSOLUTE-COORD REWORK: px/py are 11-bit ABSOLUTE screen coordinates (0..2047) and
// reach the multipliers as FLOATS from coord_f32, which also folds in the +0.5 pixel
// centre per HALF_OFFSET.tsp_pixel_half_offset. The planes are anchored at the screen
// origin to match (tsp_setup_stream no longer subtracts the tile origin), and the
// products are float*float (fp_mul16_spp_ro) rather than float*5-bit-int.
//
// Per plane (x10, parallel):
//   i1 : prx = ddx*px , pry = ddy*py            (fp_mul16_spp_ro, registered out)
//   i2 : sum = prx + pry + c                     (fp_add3_24_pp)
//   i3 : attr = sum * W                          (fp_mul16_pp)
//
// CONVENTION: the FP units do NOT register their own inputs/outputs (combinational in
// and out around their internal stages). So THIS wrapper owns the register at every
// boundary: it registers the FP unit results (i1->i2 and i2->i3 boundaries + the final
// attr) and holds the module inputs. Per-unit internal register counts:
//   coord_f32 + fp_mul16_spp_ro : 1 + 2, registered out -> NO wrapper reg = 3 cyc
//   fp_add3_24_pp : 4 internal  -> +1 wrapper reg = 5 cyc
//   fp_mul24_spp_ro: 2 cyc, registered out -> NO wrapper reg = 2 cyc
// Total INTERP latency = 3 + 5 + 2 = 10 cycles (was 9: the coordinate conversion).
//
// DATAFLOW / ALIGNMENT. The pipes chain by valid. The carried operands are delay-
// matched to the pipe they feed:
//   c : consumed by i2 (at the i1-result register) -> delay c by i1's latency (2).
//   W : consumed by i3 (at the i2-result register) -> delay W by i1+i2 latency (7).
// The delay lines are plain flop chains gated by !stall.
//
// HOLD (backpressure): INTERP lives in tsp_shade_pp's `en`-gated front. `stall`=1
// freezes EVERYTHING (FP-unit internal regs + the boundary regs + c/W delay lines).
// in_valid -> out_valid. No input/output buffering at the module edge beyond the
// boundary regs the wrapper owns (caller holds inputs stable while in_valid && !stall).
//
// See isp_raster_line: the c/W alignment chains here are the same uniform-depth shape
// that Quartus turns into M10K-backed altshift_taps, which belongs nowhere on a
// datapath between pipeline stages.
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
module interp_unit (
    input             clk,
    input             reset,
    input             stall,               // 1 = freeze everything (front-pipe hold)
    input             in_valid,
    input      [31:0] ddx [0:9],
    input      [31:0] ddy [0:9],
    input      [31:0] c   [0:9],
    input      [10:0] px,                   // ABSOLUTE screen x (tile base | offset)
    input      [10:0] py,                   // ABSOLUTE screen y
    input             half,                 // pixel-centre select (+0.5)
    input      [31:0] w,                    // 1/invW (i3 multiplicand)
    output            out_valid,
    output     [31:0] attr [0:9]      // driven by i3's registered unit output
);
    localparam integer LAT_I1 = 3;          // coord_f32 (1) + fp_mul16_spp_ro (2, reg out)
    localparam integer LAT_I2 = 5;          // fp_add3_24_pp (4 internal) + boundary reg
    localparam integer CDLY   = LAT_I1;         // delay for c  (into i2) = 2
    localparam integer WDLY   = LAT_I1 + LAT_I2; // delay for W (into i3) = 7

    genvar gi;
    integer d, ds;

    // ---- c delay line: c[k] delayed by CDLY, per plane. c_dl[k][CDLY-1] is aligned. ----
    reg [31:0] c_dl [0:9][0:CDLY-1];
    always @(posedge clk) begin
        if (!stall) for (d=0; d<10; d=d+1) begin
            c_dl[d][0] <= c[d];
            for (ds=1; ds<CDLY; ds=ds+1) c_dl[d][ds] <= c_dl[d][ds-1];
        end
    end

    // ---- W delay line: single word delayed by WDLY ----
    reg [31:0] w_dl [0:WDLY-1];
    always @(posedge clk) begin
        if (!stall) begin
            w_dl[0] <= w;
            for (d=1; d<WDLY; d=d+1) w_dl[d] <= w_dl[d-1];
        end
    end
    wire [31:0] w_aligned = w_dl[WDLY-1];

    // per-plane combinational FP-unit outputs + boundary registers
    wire [31:0] prx_c [0:9], pry_c [0:9];   // i1 combinational products
    wire        i1_ov_c [0:9];
    wire [31:0] prx_r [0:9], pry_r [0:9];   // i1 result (already registered by the unit)
    wire        i1_v;                       // LIVE unit out_valid (see below)

    wire [31:0] sum_c [0:9];                 // i2 combinational sum
    wire        i2_ov_c [0:9];
    reg  [31:0] sum_r [0:9];                 // i2 boundary REGISTER
    reg         i2_v;

    assign i1_v = i1_ov_c[0];

    wire [31:0] attr_c [0:9];                // i3 combinational product
    wire        i3_ov_c [0:9];

    // ---- coordinate -> float (1 cyc). Shared by all 10 planes. ----
    wire [31:0] pxf, pyf;
    coord_f32 u_cx (.clk(clk),.en(~stall),.coord(px),.half(half),.f(pxf));
    coord_f32 u_cy (.clk(clk),.en(~stall),.coord(py),.half(half),.f(pyf));
    // ddx/ddy must meet their converted coordinate: delay by the conversion latency.
    reg [31:0] ddx_c [0:9], ddy_c [0:9];
    reg        conv_v;
    always @(posedge clk) begin
        if (reset) conv_v <= 1'b0;
        else if (!stall) begin
            conv_v <= in_valid;
            for (d=0; d<10; d=d+1) begin ddx_c[d] <= ddx[d]; ddy_c[d] <= ddy[d]; end
        end
    end

    generate
      for (gi=0; gi<10; gi=gi+1) begin : plane
        // i1: two products. fp_mul16_spp_ro is REGISTERED-OUTPUT (2 clk), so unlike the
        // old comb-out fp_mul_i5_pp it needs no wrapper boundary register - prx_r/pry_r
        // below are fed directly from it (kept as the i2 operand source so the rest of
        // the wrapper's structure is unchanged).
        // PRECISION SPLIT. Planes 0/1 are U/V and feed tex_uvmap's float->fixed step,
        // which TRUNCATES to 8.8. A 1:1 sprite puts the exact answer ON an integer
        // boundary (ui_raw = 128 for the first column), so a result a fraction low
        // truncates to 127 and the sample drops a WHOLE texel to -1/frac 255 - the
        // one-pixel shift. fp_mul16's 16-bit significands are not enough to land that
        // exactly at absolute screen coordinates, so U/V take the full-mantissa unit.
        // Planes 2..9 are colour/offset and end up as 8 bits through f2u8, where the
        // truncation is invisible - they keep fp_mul16 and stay out of the DSPs
        // (4 DSP-eligible multiplies here instead of 20).
        if (gi < 2) begin : g_uv
            fp_mul24_spp_ro u_mx (.clk(clk),.reset(reset),.stall(stall),.in_valid(conv_v),
                .a(ddx_c[gi]),.b(pxf),.out_valid(i1_ov_c[gi]),.y(prx_c[gi]));
            fp_mul24_spp_ro u_my (.clk(clk),.reset(reset),.stall(stall),.in_valid(conv_v),
                .a(ddy_c[gi]),.b(pyf),.out_valid(),.y(pry_c[gi]));
        end else begin : g_col
            fp_mul16_spp_ro u_mx (.clk(clk),.reset(reset),.stall(stall),.in_valid(conv_v),
                .a(ddx_c[gi]),.b(pxf),.out_valid(i1_ov_c[gi]),.y(prx_c[gi]));
            fp_mul16_spp_ro u_my (.clk(clk),.reset(reset),.stall(stall),.in_valid(conv_v),
                .a(ddy_c[gi]),.b(pyf),.out_valid(),.y(pry_c[gi]));
        end

        assign prx_r[gi] = prx_c[gi];
        assign pry_r[gi] = pry_c[gi];
        // i2: prx_r + pry_r + c(aligned). Fed from the i1 registered unit output.
        fp_add3_24_pp u_add (.clk(clk),.reset(reset),.stall(stall),.in_valid(i1_v),
            .a(prx_r[gi]),.b(pry_r[gi]),.c(c_dl[gi][CDLY-1]),
            .out_valid(i2_ov_c[gi]),.y(sum_c[gi]));

        // i3: sum_r * W(aligned). Fed from the i2 boundary register.
        // FULL MANTISSA, all planes. The U/V planes feed tex_uvmap's TRUNCATING
        // float->fixed step, where a 1:1 sprite puts the exact answer ON an 8.8 integer
        // boundary - landing a fraction low costs a WHOLE texel (vi_raw 18303 vs 18304
        // -> texel 70 instead of 71, a one-pixel shift). fp_mul16 here was enough for U
        // (tiny, ~0.004) but not for V (~0.56), where the same relative truncation is a
        // much larger absolute error. Registered-output, so unlike fp_mul16_pp it needs
        // NO wrapper register - the 2-cycle total, and INTERPLAT, are unchanged.
        fp_mul24_spp_ro u_mul (.clk(clk),.reset(reset),.stall(stall),.in_valid(i2_v),
            .a(sum_r[gi]),.b(w_aligned),.out_valid(i3_ov_c[gi]),.y(attr_c[gi]));
        assign attr[gi] = attr_c[gi];
      end
    endgenerate

    // ---- boundary registers (wrapper-owned; the FP units are comb in/out) ----
    always @(posedge clk) begin
        if (reset) begin i2_v <= 1'b0; end
        else if (!stall) begin
            // (i1 needs no boundary register: fp_mul16_spp_ro is registered-output, so
            //  its result and out_valid are already co-aligned - see LAT_I1.)
            // i2 result -> boundary reg (feeds i3)
            for (d=0; d<10; d=d+1) sum_r[d] <= sum_c[d];
            i2_v <= i2_ov_c[0];
        end
    end

    // out_valid is i3's own registered valid - attr is the unit's registered output, so
    // the two are already co-aligned (no wrapper register to account for).
    assign out_valid = i3_ov_c[0];
endmodule

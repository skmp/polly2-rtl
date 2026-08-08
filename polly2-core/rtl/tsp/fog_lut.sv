//
// fog_lut - refsw2 LookupFogTable(): per-pixel fog alpha from 1/W, PIPELINED.
//
//   fogW  = fog_den * invW                       (fog_den = FOG_DENSITY as f32)
//   fogW  = clamp(fogW, 1.0f, 255.999985f)
//   index = ((exp(fogW)+1) & 7) << 4 | mant(fogW)[22:19]        (0..127)
//   bf    = mant(fogW)[18:11]                                   (0..255)
//   alpha = (E.b0 * bf + E.b1 * (255-bf)) >> 8                  (E = FOG_TABLE[index])
//
// RAW 8-BIT WEIGHTS, >>8 - the same imperfect *255/256 rounding tsp_blend uses, NOT
// refsw2's to_u8_256() 0..255 -> 0..256 rescale. Results run up to ~1 LSB low (a full
// blend of 255 lands on 254); that is the house convention and it keeps the weight 8
// bits wide.
//
// ONE MULTIPLY for the table blend. With raw weights bf and 255-bf the two-term blend
// folds to a delta form:
//     alpha = (b1*255 + (b0 - b1) * bf) >> 8
// so reg_file PRECOMPUTES the {base255 = b1*255, delta = b0-b1} pair AT FOG-TABLE WRITE
// TIME and the per-pixel path is a single 9x8 multiply + add - no second multiply, no
// per-pixel *255, no weight inverse. FOG_DENSITY is likewise pre-normalized to f32 by
// reg_file (it is stored as a {mantissa,exponent} byte pair), so this stage needs no
// unpack either.
//
// DEVIATION from refsw2, deliberate: refsw2 feeds the fog unit `1/W` where `W` was
// itself computed as `1/invW`, i.e. a round-trip through two reciprocals of the
// interpolated depth. Real PVR2 fogs off the interpolated 1/W directly, and so does
// this unit (`invw` is the per-pixel depth straight out of the tag/depth buffer). The
// two agree to within the reciprocal pair's rounding, far below the blend factor's
// resolution.
//
// TODO: VALIDATE THE WHOLE FOG PATH AGAINST REAL HARDWARE. Nothing here has been
// compared to a DC yet - it is checked against refsw2's model only (see `make fog`),
// and that is software, not silicon. The specific points where a HW capture would
// settle something:
//   * the *255/256 raw-weight rounding (this file and fog_blend) vs refsw2's
//     to_u8_256 rescale - a deliberate ~1 LSB house convention. Which one matches HW?
//   * fogging off the interpolated 1/W directly vs refsw2's 1/(1/invW) round-trip
//     (see the DEVIATION note above).
//   * LUT MODE 2 (FogCtrl 11): it is described elsewhere as replacing the BASE
//     COLOUR (alpha = fog coefficient, RGB = fog colour), i.e. BEFORE the texture
//     combine; refsw2 - and fog_blend - replace the FINAL colour after it. The two
//     agree for the intended use (untextured filter polygons) and differ for a
//     textured mode-2 polygon, which is exactly what a HW test should draw.
//   * the clamp rails (1.0 / 255.999985) and the table-index field split at the
//     exponent boundaries, where an off-by-one in ((e+1)&7) would only show on a
//     narrow depth range.
//
// PIPELINE (7 stages; each stage exists to keep the shade clock off the critical path
// - the multiply, the RAM read and the final add are all on their own):
//   M1,M2 : fogW = fog_den * invw                        (fp_mul16_spp_ro, 2 clk)
//   S3    : clamp + field extract -> index, bf; index drives fog_req
//   S4    : FOG_TABLE read in flight (reg_file registers it at the end of this cycle)
//   S5    : capture the entry {base255, delta}
//   S6    : m = delta * bf        (9x8 signed, multstyle="logic" reg -> no DSP)
//   S7    : alpha = (base255 + m) >>> 8
//
// `stall` freezes every stage. The table read address is a stage register, so while
// stalled the RAM re-reads the same word and its output holds - no capture hazard.
//
(* multstyle = "logic" *)
module fog_lut import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             stall,
    input             in_valid,
    input      [31:0] invw,        // per-pixel 1/W (non-negative, sign-stripped depth)
    input      [31:0] fog_den,     // FOG_DENSITY pre-normalized to f32 (reg_file)

    // FOG_TABLE read port (reg_file M10K; registered read, precomputed base/delta)
    output fog_rd_req_t  fog_req,
    input  fog_rd_resp_t fog_resp,

    output reg        out_valid,
    output reg [7:0]  fog_alpha
);
    localparam [30:0] FW_MIN = 31'h3F800000;   // 1.0f
    localparam [30:0] FW_MAX = 31'h437FFFFF;   // 255.999985f rounded to f32 (255.99998474)

    // ---- M1/M2: fogW = fog_den * invw --------------------------------------------
    // fp_mul16 (16-bit significands), not fp_mul24: only 12 mantissa bits of the
    // product are ever consumed (4 for the table index, 8 for the blend factor), and
    // fog_den carries at most 8 significant bits by construction - so its 15-bit
    // truncation here is EXACT, and invW's costs <2^-15 relative, an eighth of a blend
    // factor LSB. The extra precision of a 24x24 buys literally nothing downstream.
    wire        mv;
    wire [31:0] fw;
    fp_mul16_spp_ro u_mul (
        .clk(clk),.reset(reset),.stall(stall),.in_valid(in_valid),
        .a(fog_den),.b(invw),.out_valid(mv),.y(fw));

    // ---- S3: clamp to [1.0, 255.999985] + field extract ---------------------------
    // Non-negative floats order exactly as their bit patterns, so the clamp is two
    // integer compares on the magnitude. A negative product cannot occur in contract
    // (invW >= 0, fog_den >= 0) but is folded into the low clamp anyway, matching the
    // reference's max(fogW, 1.0f).
    wire [30:0] mag  = fw[30:0];
    wire        lo   = fw[31] || (mag < FW_MIN);
    wire [30:0] fwc  = lo ? FW_MIN : (mag > FW_MAX) ? FW_MAX : mag;
    wire [7:0]  fw_e = fwc[30:23];
    wire [22:0] fw_m = fwc[22:0];
    wire [6:0]  s3_index_c = {fw_e[2:0] + 3'd1, fw_m[22:19]};   // ((e+1)&7)<<4 | m[22:19]
    wire [7:0]  s3_bf_c    = fw_m[18:11];

    reg        v3;  reg [6:0] s3_index;  reg [7:0] s3_bf;
    always @(posedge clk) begin
        if (reset) v3 <= 1'b0;
        else if (!stall) begin
            v3       <= mv;
            s3_index <= s3_index_c;
            s3_bf    <= s3_bf_c;
        end
    end
    assign fog_req.raddr = s3_index;

    // ---- S4: the FOG_TABLE read is IN FLIGHT --------------------------------------
    // fog_req.raddr is the S3 register, so the address is on the RAM during this cycle
    // and reg_file's own read register captures it at the END of it: the entry is only
    // readable at S5. S4 carries the blend factor across that read latency.
    reg        v4;  reg [7:0] s4_bf;
    always @(posedge clk) begin
        if (reset) v4 <= 1'b0;
        else if (!stall) begin
            v4    <= v3;
            s4_bf <= s3_bf;
        end
    end

    // ---- S5: capture the table entry ----------------------------------------------
    reg        v5;  reg [15:0] s5_base255;  reg [8:0] s5_delta;  reg [7:0] s5_bf;
    always @(posedge clk) begin
        if (reset) v5 <= 1'b0;
        else if (!stall) begin
            v5         <= v4;
            s5_base255 <= fog_resp.base255;
            s5_delta   <= fog_resp.delta;
            s5_bf      <= s4_bf;
        end
    end

    // ---- S6: the ONE multiply -----------------------------------------------------
    reg        v6;  reg signed [17:0] s6_m;  reg [15:0] s6_base255;
    always @(posedge clk) begin
        if (reset) v6 <= 1'b0;
        else if (!stall) begin
            v6         <= v5;
            s6_m       <= $signed(s5_delta) * $signed({1'b0, s5_bf});   // delta is 2's complement
            s6_base255 <= s5_base255;
        end
    end

    // ---- S7: alpha = (base255 + m) >>> 8 ------------------------------------------
    // b1*255 + (b0-b1)*bf is a convex combination scaled by 255, so the sum is in
    // [0, 65025] and the shifted result in [0,254] - no clamp needed.
    wire signed [18:0] s7_sum = $signed({3'b0, s6_base255}) + {{1{s6_m[17]}}, s6_m};
    always @(posedge clk) begin
        if (reset) out_valid <= 1'b0;
        else if (!stall) begin
            out_valid <= v6;
            fog_alpha <= 8'(s7_sum >>> 8);
        end
    end
endmodule

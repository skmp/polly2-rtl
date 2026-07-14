//
// timming_isp_raster_line - standalone synthesis/timing harness that wraps the WHOLE
// isp_raster_line unit (the LANES-pixel pipelined span evaluator: 5+LANES fp_mul_i5
// lanes, split fp_add24_s1/s2 adders, corner-probe witness muxes). Sibling to the
// other timming_* projects: a self-contained place-and-route + timing-close context
// so the fitter reports Fmax/area for JUST this unit, decoupled from peel_core.
//
// LANES=4 to match the peel_core instantiation (RAS_LANES=4).
//
// isp_raster_line is a plain clk/reset unit (no DDR, no caches), so this uses a
// plain clocked top (a real top-level `clk` pin, no sysmem bridge).
//
// Pattern (identical to the other timing harnesses):
//   * ALL inputs are driven from a free-running input register bank (in_reg) the HPS
//     pokes via wr_en/wr_addr/wr_data, so every input bit has a real register source
//     and the fitter cannot fold the DUT away against constant inputs.
//   * ALL outputs are captured into RAW registers with NO logic in between (pure
//     unit timing), then XOR-folded to a SINGLE `digest` pin one cycle LATER (fold
//     tree off the capture regs, never in the measured output paths).
//
// Build: cd timming_tests/timming_isp_raster_line && quartus_sh --flow compile timming_isp_raster_line
// Fmax:  output_files/timming_isp_raster_line.sta.rpt
//
module timming_isp_raster_line (
    input             clk,
    input             reset,

    // ---- input register load (driven by the HPS) ----
    input             wr_en,        // 1: in_reg[wr_addr] <= wr_data
    input      [12:0] wr_addr,
    input      [31:0] wr_data,

    // ---- single folded output pin (keeps every output bit alive) ----
    output reg        digest
);
    localparam integer LANES = 4;   // match peel_core RAS_LANES

    // ---- input register bank ----
    //   0..3   : c1,c2,c3,c4
    //   4..7   : dx12,dx23,dx31,dx41
    //   8..11  : dy12,dy23,dy31,dy41
    //   12..14 : ddx, ddy, c_invw
    //   15     : { ..., probe@11, in_valid@10, x_base@9:5, y@4:0 }   (control bits)
    localparam integer NREG = 16;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk) begin
        if (reset) begin
            for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        end else if (wr_en && wr_addr < NREG) begin
            in_reg[wr_addr] <= wr_data;
        end
    end

    wire [31:0] w_ctl      = in_reg[15];
    wire [4:0]  w_y        = w_ctl[4:0];
    wire [4:0]  w_x_base   = w_ctl[9:5];
    wire        w_in_valid = w_ctl[10];
    wire        w_probe    = w_ctl[11];

    // ---- DUT ----
    wire                   s_probe_reject, s_probe_valid, s_out_valid;
    wire [LANES-1:0]       s_inside_mask;
    wire [32*LANES-1:0]    s_invw_flat;
    wire [4:0]             s_out_x, s_out_y;

    isp_raster_line #(.LANES(LANES)) u_line (
        .clk(clk), .reset(reset),
        .in_valid(w_in_valid),
        .y(w_y), .x_base(w_x_base),
        .c1(in_reg[0]), .c2(in_reg[1]), .c3(in_reg[2]), .c4(in_reg[3]),
        .dx12(in_reg[4]), .dx23(in_reg[5]), .dx31(in_reg[6]), .dx41(in_reg[7]),
        .dy12(in_reg[8]), .dy23(in_reg[9]), .dy31(in_reg[10]), .dy41(in_reg[11]),
        .ddx(in_reg[12]), .ddy(in_reg[13]), .c_invw(in_reg[14]),
        .probe(w_probe),
        .probe_reject(s_probe_reject), .probe_valid(s_probe_valid),
        .out_valid(s_out_valid),
        .inside_mask(s_inside_mask), .invw_flat(s_invw_flat),
        .out_x(s_out_x), .out_y(s_out_y));

    // ---- RAW capture (no logic before the flops -> pure unit timing) ----
    reg [32*LANES-1:0] cap_invw;
    reg [LANES-1:0]    cap_mask;
    reg [12:0]         cap_misc;
    always @(posedge clk) begin
        if (reset) begin cap_invw <= '0; cap_mask <= '0; cap_misc <= '0; end
        else begin
            cap_invw <= s_invw_flat;
            cap_mask <= s_inside_mask;
            cap_misc <= {s_out_x, s_out_y, s_probe_reject, s_probe_valid, s_out_valid};
        end
    end

    // ---- next cycle: XOR-fold to one pin (off cap_*, not the DUT) ----
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^{ cap_invw, cap_mask, cap_misc };
    end
endmodule

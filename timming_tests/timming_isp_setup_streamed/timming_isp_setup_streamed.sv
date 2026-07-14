//
// timming_isp_setup_streamed - standalone synthesis/timing harness that wraps the
// WHOLE isp_setup_streamed unit (the 4-way interleaved ISP setup: 4 mac16 lanes +
// fp_rcp_fast + pipelined bbox). Sibling to timming_tsp_setup_stream: a
// self-contained place-and-route + timing-close context so the fitter reports
// Fmax/area for JUST this unit, decoupled from peel_core.
//
// isp_setup_streamed is a plain clk/reset unit (no DDR, no caches), so this uses a
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
// Build: cd timming_tests/timming_isp_setup_streamed && quartus_sh --flow compile timming_isp_setup_streamed
// Fmax:  output_files/timming_isp_setup_streamed.sta.rpt
//
module timming_isp_setup_streamed (
    input             clk,
    input             reset,

    // ---- input register load (driven by the HPS) ----
    input             wr_en,        // 1: in_reg[wr_addr] <= wr_data
    input      [12:0] wr_addr,
    input      [31:0] wr_data,

    // ---- single folded output pin (keeps every output bit alive) ----
    output reg        digest
);
    // ---- input register bank ----
    //   0..8  : x1,y1,z1, x2,y2,z2, x3,y3,z3
    //   9..10 : xbase, ybase
    //   11    : isp_word
    //   12    : in_tag
    //   13    : { ..., quad@3, out_ready@2, in_pt@1, in_valid@0 }   (control bits)
    //   14..15: x4, y4    (quad 4th vertex; refsw2 never reads v4's Z -> no z4)
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

    wire [31:0] w_ctl       = in_reg[13];
    wire        w_in_valid  = w_ctl[0];
    wire        w_in_pt     = w_ctl[1];
    wire        w_out_ready = w_ctl[2];
    wire        w_quad      = w_ctl[3];

    // ---- DUT ----
    wire        s_in_ready, s_busy, s_out_valid, s_out_pt, s_sgn_neg, s_cull;
    wire [31:0] s_out_tag, s_out_isp;
    wire [31:0] s_dx12, s_dx23, s_dx31, s_dx41;
    wire [31:0] s_dy12, s_dy23, s_dy31, s_dy41;
    wire [31:0] s_c1, s_c2, s_c3, s_c4;
    wire [31:0] s_ddx_invw, s_ddy_invw, s_c_invw;
    wire [4:0]  s_bx0, s_bx1, s_by0, s_by1;

    isp_setup_streamed u_setup (
        .clk(clk), .reset(reset),
        .in_valid(w_in_valid), .in_ready(s_in_ready),
        .isp_word(in_reg[11]), .in_tag(in_reg[12]), .in_pt(w_in_pt), .quad(w_quad),
        .x1(in_reg[0]), .y1(in_reg[1]), .z1(in_reg[2]),
        .x2(in_reg[3]), .y2(in_reg[4]), .z2(in_reg[5]),
        .x3(in_reg[6]), .y3(in_reg[7]), .z3(in_reg[8]),
        .x4(in_reg[14]), .y4(in_reg[15]),
        .xbase(in_reg[9]), .ybase(in_reg[10]),
        .busy(s_busy),
        .out_ready(w_out_ready),
        .out_valid(s_out_valid), .out_tag(s_out_tag), .out_pt(s_out_pt),
        .out_isp(s_out_isp), .sgn_neg(s_sgn_neg), .cull(s_cull),
        .dx12(s_dx12), .dx23(s_dx23), .dx31(s_dx31), .dx41(s_dx41),
        .dy12(s_dy12), .dy23(s_dy23), .dy31(s_dy31), .dy41(s_dy41),
        .c1(s_c1), .c2(s_c2), .c3(s_c3), .c4(s_c4),
        .ddx_invw(s_ddx_invw), .ddy_invw(s_ddy_invw), .c_invw(s_c_invw),
        .bx0(s_bx0), .bx1(s_bx1), .by0(s_by0), .by1(s_by1));

    // ---- RAW capture (no logic before the flops -> pure unit timing) ----
    reg [31:0] cap_w [0:18];   // 19 x 32-bit outputs
    reg [19:0] cap_b;          // bbox (4x5) + flag bits
    always @(posedge clk) begin
        if (reset) begin
            for (ir=0; ir<19; ir=ir+1) cap_w[ir] <= 32'd0;
            cap_b <= 20'd0;
        end else begin
            cap_w[0]  <= s_out_tag;  cap_w[1]  <= s_out_isp;
            cap_w[2]  <= s_dx12;     cap_w[3]  <= s_dx23;
            cap_w[4]  <= s_dx31;     cap_w[5]  <= s_dx41;
            cap_w[6]  <= s_dy12;     cap_w[7]  <= s_dy23;
            cap_w[8]  <= s_dy31;     cap_w[9]  <= s_dy41;
            cap_w[10] <= s_c1;       cap_w[11] <= s_c2;
            cap_w[12] <= s_c3;       cap_w[13] <= s_c4;
            cap_w[14] <= s_ddx_invw; cap_w[15] <= s_ddy_invw;
            cap_w[16] <= s_c_invw;
            cap_w[17] <= {26'd0, s_in_ready, s_busy, s_out_valid, s_out_pt, s_sgn_neg, s_cull};
            cap_w[18] <= 32'd0;
            cap_b     <= {s_bx0, s_bx1, s_by0, s_by1};
        end
    end

    // ---- next cycle: XOR-fold to one pin (off cap_*, not the DUT) ----
    reg [18:0] fold1;
    always @(posedge clk) begin
        if (reset) begin fold1 <= '0; digest <= 1'b0; end
        else begin
            for (ir=0; ir<19; ir=ir+1) fold1[ir] <= ^cap_w[ir];
            digest <= (^fold1) ^ (^cap_b);
        end
    end
endmodule

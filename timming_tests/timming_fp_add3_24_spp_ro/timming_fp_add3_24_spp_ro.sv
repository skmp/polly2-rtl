//
// timming_fp_add3_24_spp_ro - standalone synthesis/timing harness for the WHOLE
// fp_add3_24_spp_ro unit (the 3-clock streaming registered-output 3-way adder).
// Sibling to timming_tsp_setup_stream et al: an isolated place-and-route + timing-close
// context so the fitter reports Fmax/area for JUST this unit, decoupled from
// tsp_setup_stream (where its S1 3-way align cloud is the residual critical path).
//
// fp_add3_24_spp_ro is a plain clk/reset streaming unit (no DDR), so this uses a plain
// clocked top with a real top-level `clk` pin.
//
// Pattern (identical to the other timing harnesses):
//   * ALL inputs are driven from a single free-running input register bank (in_reg)
//     the HPS pokes via wr_en/wr_addr/wr_data, so every input bit has a real register
//     source and input paths are realistic - and the fitter cannot fold the DUT away.
//   * The RAW unit output is captured with NO logic in between (pure unit timing), then
//     XOR-folded to a SINGLE `digest` pin one cycle LATER (fold tree off the capture
//     reg, never in the measured output path).
//
// This isolates the unit's OWN reg-to-reg paths (S1 align, S2 leading-1 search, S3
// shift+pack) with realistic register sources on both ends. Note: in the real
// tsp_setup_stream the S1 inputs come through an operand mux/hold - that mux is NOT
// modeled here, so this harness measures the unit's intrinsic Fmax (the floor), which
// is the number that says whether the unit itself needs a deeper split.
//
// Build: cd timming_tests/timming_fp_add3_24_spp_ro && quartus_sh --flow compile timming_fp_add3_24_spp_ro
// Fmax:  output_files/timming_fp_add3_24_spp_ro.sta.rpt
//
module timming_fp_add3_24_spp_ro (
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
    //   0 : a
    //   1 : b
    //   2 : c
    //   3 : { ..., in_valid }   (control)
    localparam integer NREG = 4;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk) begin
        if (reset) begin
            for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        end else if (wr_en && wr_addr < NREG) begin
            in_reg[wr_addr] <= wr_data;
        end
    end

    wire        w_iv = in_reg[3][0];

    // ---- DUT ----
    wire        s_out_valid;
    wire [31:0] s_y;
    fp_add3_24_spp_ro u_dut (
        .clk(clk), .reset(reset), .stall(1'b0), .in_valid(w_iv),
        .a(in_reg[0]), .b(in_reg[1]), .c(in_reg[2]),
        .out_valid(s_out_valid), .y(s_y));

    // ---- RAW capture (no logic before the flop -> pure unit timing) ----
    reg [31:0] cap_y;
    reg        cap_v;
    always @(posedge clk) begin
        if (reset) begin cap_y <= 32'd0; cap_v <= 1'b0; end
        else       begin cap_y <= s_y;   cap_v <= s_out_valid; end
    end

    // ---- next cycle: XOR-fold to one pin (off cap_*, not the DUT) ----
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^{ cap_y, cap_v };
    end
endmodule

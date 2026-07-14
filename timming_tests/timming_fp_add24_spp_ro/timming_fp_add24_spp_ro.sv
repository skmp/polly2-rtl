//
// timming_fp_add24_spp_ro - standalone synthesis/timing harness for the WHOLE
// fp_add24_spp_ro unit (3-clock streaming registered-output 2-way adder, align-to-max
// S1). Sibling to timming_fp_add3_24_spp_ro: isolates the unit's OWN reg-to-reg paths
// (S1 align+signed-sum, S2 abs+leading-1 search, S3 shift+pack) with realistic register
// sources on both ends, so the STA reports its intrinsic Fmax - the floor under the
// tsp_setup_stream `-> s1_sum` violation family.
//
// Pattern (identical to the other timing harnesses): HPS-writable input register bank
// -> DUT -> RAW registered capture -> XOR-fold to a single `digest` pin one cycle later.
//
// Build: cd timming_tests/timming_fp_add24_spp_ro && quartus_sh --flow compile timming_fp_add24_spp_ro
// Fmax:  output_files/timming_fp_add24_spp_ro.sta.rpt
//
module timming_fp_add24_spp_ro (
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
    //   1 : b_in
    //   2 : { ..., sub, in_valid }   (control)
    localparam integer NREG = 3;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk) begin
        if (reset) begin
            for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        end else if (wr_en && wr_addr < NREG) begin
            in_reg[wr_addr] <= wr_data;
        end
    end

    wire w_iv  = in_reg[2][0];
    wire w_sub = in_reg[2][1];

    // ---- DUT ----
    wire        s_out_valid;
    wire [31:0] s_y;
    fp_add24_spp_ro u_dut (
        .clk(clk), .reset(reset), .stall(1'b0), .in_valid(w_iv),
        .a(in_reg[0]), .b_in(in_reg[1]), .sub(w_sub),
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

//
// timing_tsp_blend - timing harness for tsp_blend (the shared blend unit at the
// end of the TSP pipe, multstyle="logic" so its 8 8x8 coefficient multiplies
// stay in ALMs).
//
// tsp_blend is PIPELINED (latency 1): S1 = alpha-test clamp + coefficient
// select, registered inside the DUT; S2 = 8x8 mult pair + sum + clamp, comb off
// the S1 registers. The harness measures both hops:
//   in_reg bank -> S1 registers   (the peel_core stage-CB select cone)
//   S1 registers -> capture reg   (the stage-CC multiply+clamp cone)
// The input bank stands in for the CB operands (every DUT input is a register
// slice), and the RAW capture register stands in for the per-half cb3_* result
// registers (no logic between the DUT outputs and the flop). The XOR-fold to
// `digest` runs off the capture register one cycle later, out of the measured
// paths.
//
// Input-bank map:
//   0 : src (ARGB)
//   1 : dst (ARGB)
//   2 : { alpha_ref[14:7], alpha_test[6], dst_instr[5:3], src_instr[2:0] }
//
// Build: cd timming_tests/timing_tsp_blend && quartus_sh --flow compile timing_tsp_blend
// Fmax:  output_files/timing_tsp_blend.sta.rpt
//
module timing_tsp_blend (
    input             clk,
    input             reset,
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    output reg        digest
);
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

    wire [31:0] w_src   = in_reg[0];
    wire [31:0] w_dst   = in_reg[1];
    wire [2:0]  w_sinst = in_reg[2][2:0];
    wire [2:0]  w_dinst = in_reg[2][5:3];
    wire        w_at    = in_reg[2][6];
    wire [7:0]  w_aref  = in_reg[2][14:7];

    // ---- DUT (combinational) ----
    wire [31:0] b_out;
    wire        b_at;
    tsp_blend u_dut (
        .clk       (clk),
        .src       (w_src),
        .dst       (w_dst),
        .src_instr (w_sinst),
        .dst_instr (w_dinst),
        .alpha_test(w_at),
        .alpha_ref (w_aref),
        .out       (b_out),
        .at_pass   (b_at));

    // ---- RAW capture (no logic before the flops -> pure unit timing) ----
    reg [32:0] cap;
    always @(posedge clk) begin
        if (reset) cap <= '0;
        else       cap <= {b_at, b_out};
    end

    // ---- next cycle: XOR-fold to one pin (off cap, not the DUT) ----
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^cap;
    end
endmodule

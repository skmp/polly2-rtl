//
// stage_tex_addroffsgen_ib - timing harness for tex_addroffsgen_ib (the 4-corner relative
// offset generator: shared part1by1 M10K ROM + size tail, OR 2-mul linear, muxed).
//
// tex_addroffsgen_ib is now PIPELINED (one internal ROM-read register). The harness owns
// the input buffer (the in_reg bank) and the output buffer (raw_cap): it drives the
// DUT's clk/reset/stall/in_valid, captures the DUT's output vector VERBATIM, then
// XOR-folds to `digest`. The measured internal path is the ROM-read + comb-out tail.
//
// Input-bank map:
//   0 : { in_valid[29], stall[28], twiddled[27], stride[26:16], v_log2[7:4], u_log2[3:0] }
//   1 : { v0[19:10], u0[9:0] }
//   2 : { v1[19:10], u1[9:0] }
//
module stage_tex_addroffsgen_ib (
    input             clk,
    input             reset,
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    output reg        digest
);
    localparam integer NREG = 8;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk) begin
        if (reset) begin
            for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        end else if (wr_en && wr_addr < NREG) begin
            in_reg[wr_addr] <= wr_data;
        end
    end

    wire [3:0]  u_log2   = in_reg[0][3:0];
    wire [3:0]  v_log2   = in_reg[0][7:4];
    wire [10:0] stride   = in_reg[0][26:16];
    wire        twiddled = in_reg[0][27];
    wire        st       = in_reg[0][28];
    wire        iv       = in_reg[0][29];
    wire [9:0] u0 = in_reg[1][9:0];
    wire [9:0] v0 = in_reg[1][19:10];
    wire [9:0] u1 = in_reg[2][9:0];
    wire [9:0] v1 = in_reg[2][19:10];

    wire [20:0] offset [0:3];
    wire        tw_o, ov;
    tex_addroffsgen_ib u_dut (
        .clk(clk),.reset(reset),.stall(st),.in_valid(iv),
        .u_log2(u_log2),.v_log2(v_log2),.stride(stride),.twiddled(twiddled),
        .u0(u0),.u1(u1),.v0(v0),.v1(v1),
        .out_valid(ov),.offset(offset),.twiddled_o(tw_o));

    // ---- RAW capture: register the DUT's whole output verbatim (no logic before the
    //      flop) -> the measured internal path (ROM-read -> comb-out tail). 4 offset(21)
    //      + twiddled_o(1) + out_valid(1) = 86 bits. ----
    reg [85:0] raw_cap;
    always @(posedge clk) begin
        if (reset) raw_cap <= '0;
        else raw_cap <= { offset[0], offset[1], offset[2], offset[3], tw_o, ov };
    end

    // ---- next cycle: XOR-fold the REGISTERED vector to `digest` (off raw_cap, not DUT).
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^raw_cap;
    end
endmodule

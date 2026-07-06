//
// stage_i3 - per-stage timing harness for tsp_shade_pp.
// STAGE INTERP i3: fp_mul16_pp (pipelined 2-stage sum * W, 1 instance).
//
// Pattern: HPS-writable input reg bank -> stage (combinational) -> RAW registered
// output vector (PURE stage timing, no logic before the flop) -> XOR-fold the
// REGISTERED vector to `digest` the NEXT cycle (fold tree off the register).
//
module stage_i3 import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    output reg        digest
);
    // ---- input register bank (every stage input has a real register source) ----
    localparam integer NREG = 64;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk) begin
        if (reset) begin
            for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        end else if (wr_en && wr_addr < NREG) begin
            in_reg[wr_addr] <= wr_data;
        end
    end

    wire [31:0] a; wire ov;

    fp_mul16_pp m (.clk(clk),.reset(reset),.stall(in_reg[34][0]),.in_valid(in_reg[34][1]),
        .a(in_reg[0]),.b(in_reg[32]),.out_valid(ov),.y(a));

    // ---- RAW capture: register the stage's whole output vector with NO logic in
    //      between, so this flop's setup path IS the pure stage delay. ----
    reg [32:0] raw_cap;
    always @(posedge clk) begin
        if (reset) raw_cap <= '0;
        else       raw_cap <= { ov, a };
    end

    // ---- next cycle: XOR-fold the REGISTERED vector to one `digest` pin (keeps every
    //      output bit alive; this reduce tree is off raw_cap, not the stage). ----
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^raw_cap;
    end
endmodule

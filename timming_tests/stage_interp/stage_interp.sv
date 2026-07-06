//
// stage_interp - per-stage timing harness for tsp_shade_pp's INTERP block
// (i1 fp_mul_i5 x2 -> i2 fp_add3_24 -> i3 fp_mul16, 10 planes).
//
// Pattern: HPS-writable input reg bank -> stage_interp (clk/reset/stall/in_valid->
// out_valid) -> RAW registered output vector -> XOR-fold to `digest` next cycle.
//
// Input-bank map (32 words used):
//   0..9   : ddx[0..9]
//   10..19 : ddy[0..9]
//   20..29 : c  [0..9]
//   30     : w
//   31     : { in_valid[9], stall[8], py[9:5]->[9:5]? , px } -> see slices below
//            [4:0]=px  [9:5]=py  [16]=in_valid  [17]=stall
//
module stage_interp (
    input             clk,
    input             reset,
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    output reg        digest
);
    localparam integer NREG = 32;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk) begin
        if (reset) begin
            for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        end else if (wr_en && wr_addr < NREG) begin
            in_reg[wr_addr] <= wr_data;
        end
    end

    // unpack the bank into the array inputs
    wire [31:0] ddx [0:9], ddy [0:9], c [0:9];
    genvar gp;
    generate for (gp=0; gp<10; gp=gp+1) begin : unpack
        assign ddx[gp] = in_reg[gp];
        assign ddy[gp] = in_reg[10+gp];
        assign c[gp]   = in_reg[20+gp];
    end endgenerate
    wire [4:0] px = in_reg[31][4:0];
    wire [4:0] py = in_reg[31][9:5];
    wire       iv = in_reg[31][16];
    wire       st = in_reg[31][17];

    wire [31:0] attr [0:9];
    wire        ov;
    interp_unit u_dut (
        .clk(clk),.reset(reset),.stall(st),.in_valid(iv),
        .ddx(ddx),.ddy(ddy),.c(c),.px(px),.py(py),.w(in_reg[30]),
        .out_valid(ov),.attr(attr));

    // ---- RAW capture: fold the 10 attr words + out_valid into a 32-bit running xor
    //      register. The xor of the 10 words is combinational off the DUT's registered
    //      attr outputs; it does not add to the DUT's internal critical path (which is
    //      i1..i3), it only keeps every output bit alive. ----
    reg [31:0] raw_cap;
    always @(posedge clk) begin
        if (reset) raw_cap <= '0;
        else raw_cap <= attr[0]^attr[1]^attr[2]^attr[3]^attr[4]
                       ^attr[5]^attr[6]^attr[7]^attr[8]^attr[9]
                       ^ {31'd0, ov};
    end
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^raw_cap;
    end
endmodule

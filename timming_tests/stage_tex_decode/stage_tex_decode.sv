//
// stage_tex_decode - timing harness for tex_decode (pipelined texel format decode with
// injected palette RAM; output-buffered).
//
// Plain-clock harness (no DDR). The harness owns:
//   * the input buffer (in_reg bank) feeding pixfmt/palsel/memtel/offset/in_valid,
//   * the INJECTED palette RAM (1024x32, registered read on pal_addr -> pal_data aligned
//     to the DUT's S1->S2 register),
//   * the output fold: since tex_decode is OUTPUT-BUFFERED (argb/out_valid off its S2
//     register), the harness adds NO capture register - it XOR-folds the DUT's registered
//     outputs directly into `digest`.
//
// Input-bank map:
//   0 : memtel[31:0]
//   1 : memtel[63:32]
//   2 : { in_valid[14], stall[13], offset[12:9], palsel[8:3], pixfmt[2:0] }
//
module stage_tex_decode (
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

    wire [63:0] memtel  = { in_reg[1], in_reg[0] };
    wire [2:0]  pixfmt  = in_reg[2][2:0];
    wire [5:0]  palsel  = in_reg[2][8:3];
    wire [3:0]  offset  = in_reg[2][12:9];
    wire        st      = in_reg[2][13];
    wire        iv      = in_reg[2][14];
    wire [1:0]  pal_fmt = in_reg[2][16:15];
    wire        scan_o  = in_reg[2][17];

    // ---- injected palette RAM (1024 x 32, registered read; feeds pal_data at S2) ----
    (* ramstyle = "M10K" *) reg [31:0] pal_ram [0:1023];
    integer pi;
    initial for (pi=0; pi<1024; pi=pi+1) pal_ram[pi] = {8'hFF, pi[7:0], pi[9:2], pi[7:0]};
    wire [9:0]  pal_addr;
    reg  [31:0] pal_data;
    always @(posedge clk) if (!st) pal_data <= pal_ram[pal_addr];

    // ---- DUT ----
    wire [31:0] argb;
    wire        ov;
    tex_decode u_dut (
        .clk(clk),.reset(reset),.stall(st),.in_valid(iv),
        .pixfmt(pixfmt),.pal_fmt(pal_fmt),.scan_order(scan_o),
        .palsel(palsel),.memtel(memtel),.offset(offset),
        .pal_addr(pal_addr),.pal_data(pal_data),
        .out_valid(ov),.argb(argb));

    // ---- OUTPUT FOLD (no output buffer; DUT is output-buffered): XOR-fold argb+ov
    //      directly into digest. Measured path = DUT internal reg -> output pin. ----
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^{ argb, ov };
    end
endmodule

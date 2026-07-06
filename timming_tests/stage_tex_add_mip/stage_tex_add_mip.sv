//
// stage_tex_add_mip - timing harness for tex_add_mip (the glue: 4 corner texel offsets
// + mip_add + fbpp_shr -> 4 byte offsets; combinational).
//
// Harness owns the input buffer (in_reg bank) and output buffer (raw_cap): registers the
// inputs, feeds tex_add_mip (combinational), registers its output vector verbatim, folds
// to `digest`.
//
// Input-bank map:
//   0..3 : texel_offset[0..3][20:0]
//   4    : mip_add[23:0]
//   5    : fbpp_shr[2:0]
//
module stage_tex_add_mip (
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

    wire [20:0] texel_offset [0:3];
    genvar gp;
    generate for (gp=0; gp<4; gp=gp+1) begin : unpack
        assign texel_offset[gp] = in_reg[gp][20:0];
    end endgenerate
    wire [23:0] mip_add  = in_reg[4][23:0];
    wire [2:0]  fbpp_shr = in_reg[5][2:0];

    wire [21:0] byte_offset [0:3];
    tex_add_mip u_dut (
        .texel_offset(texel_offset),.mip_add(mip_add),.fbpp_shr(fbpp_shr),
        .byte_offset(byte_offset));

    // ---- RAW capture: register the 4 byte offsets (88 bits) verbatim (no logic before
    //      the flop) -> pure combinational tex_add_mip delay. ----
    reg [87:0] raw_cap;
    always @(posedge clk) begin
        if (reset) raw_cap <= '0;
        else raw_cap <= { byte_offset[0], byte_offset[1], byte_offset[2], byte_offset[3] };
    end
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^raw_cap;
    end
endmodule

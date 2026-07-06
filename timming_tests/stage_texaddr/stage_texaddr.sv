//
// stage_texaddr - per-stage timing harness for tex_addr_pp (the pipelined texture
// address generator). Times JUST the address-gen cone in isolation - the ~40 ns
// combinational tex_addr was the tex_unit bottleneck (~25 MHz); this confirms the
// pipelined tex_addr_pp clears 120 before we rework tex_fetch_pp's T0 protocol.
//
// Pattern: HPS-writable input reg bank -> tex_addr_pp (clk/reset/stall/in_valid->
// out_valid) -> RAW registered output vector -> XOR-fold to `digest` next cycle.
//
// Input-bank map:
//   0 : tcw   (tcw_addr=[20:0], strd=[25], scan=[26], pixfmt=[29:27], vq=[30], mip=[31])
//   1 : { text_ctrl[4:0], miplevel[8:5], texv[11:9], texu[14:12] }
//   2 : { v[10:0], u[10:0] }   (u=[10:0], v=[21:11])
//   3 : { stall[1], in_valid[0] }
//
module stage_texaddr (
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

    wire [31:0] tcw = in_reg[0];
    wire [4:0]  text_ctrl = in_reg[1][4:0];
    wire [3:0]  miplevel  = in_reg[1][8:5];
    wire [2:0]  texv      = in_reg[1][11:9];
    wire [2:0]  texu      = in_reg[1][14:12];
    wire [10:0] u = in_reg[2][10:0];
    wire [10:0] v = in_reg[2][21:11];
    wire        iv = in_reg[3][0];
    wire        st = in_reg[3][1];

    wire [28:0] byte_addr; wire [2:0] fbpp_shr; wire [19:0] offset; wire ov;
    tex_addr_pp u_dut (
        .clk(clk),.reset(reset),.stall(st),.in_valid(iv),
        .tcw_addr(tcw[20:0]),.vq(tcw[30]),.scan(tcw[26]),.stride_sel(tcw[25]),
        .mipmapped(tcw[31]),.pixfmt(tcw[29:27]),
        .texu(texu),.texv(texv),.miplevel(miplevel),.text_ctrl(text_ctrl),
        .u(u),.v(v),
        .out_valid(ov),.byte_addr(byte_addr),.fbpp_shr(fbpp_shr),.offset(offset));

    // ---- RAW capture: byte_addr(29) + offset(20) + fbpp_shr(3) + ov(1) = 53 bits,
    //      no logic between the DUT (combinational A3 output) and this flop. ----
    reg [52:0] raw_cap;
    always @(posedge clk) begin
        if (reset) raw_cap <= '0;
        else       raw_cap <= { byte_addr, offset, fbpp_shr, ov };
    end
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^raw_cap;
    end
endmodule

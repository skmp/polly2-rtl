//
// stage_uv - per-stage timing harness for tsp_shade_pp.
// STAGE UV: tex_uvmap (streamed 3-stage) + 8x f2u8.
//
// Pattern: HPS-writable input reg bank -> stage (combinational) -> RAW registered
// output vector (PURE stage timing, no logic before the flop) -> XOR-fold the
// REGISTERED vector to `digest` the NEXT cycle (fold tree off the register).
//
module stage_uv import tsp_pkg::*; (
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

    wire [10:0] c00u,c00v,c01u,c01v,c10u,c10v,c11u,c11v; wire [7:0] uf,vf;
    wire uvv; wire [7:0] u8 [2:9]; genvar gi;

    tex_uvmap u_uv (
        .clk(clk),.reset(reset),.stall(in_reg[3][8]),.in_valid(in_reg[3][9]),
        .u(in_reg[0]),.v(in_reg[1]),.texu(in_reg[2][5:3]),.texv(in_reg[2][2:0]),
        .miplevel(in_reg[3][3:0]),
        .clampu(in_reg[2][16]),.clampv(in_reg[2][15]),.flipu(in_reg[2][18]),.flipv(in_reg[2][17]),
        .out_valid(uvv),
        .c00u(c00u),.c00v(c00v),.c01u(c01u),.c01v(c01v),
        .c10u(c10u),.c10v(c10v),.c11u(c11u),.c11v(c11v),.ufrac(uf),.vfrac(vf));
    generate for (gi=2; gi<=9; gi=gi+1) begin : cvt
        f2u8 u_c (.f(in_reg[10+gi]),.u(u8[gi]));
    end endgenerate

    // ---- RAW capture: register the stage's whole output vector with NO logic in
    //      between, so this flop's setup path IS the pure stage delay. ----
    reg [168:0] raw_cap;
    always @(posedge clk) begin
        if (reset) raw_cap <= '0;
        else       raw_cap <= { uvv, c00u,c00v,c01u,c01v,c10u,c10v,c11u,c11v, uf, vf,
               u8[2],u8[3],u8[4],u8[5],u8[6],u8[7],u8[8],u8[9] };
    end

    // ---- next cycle: XOR-fold the REGISTERED vector to one `digest` pin (keeps every
    //      output bit alive; this reduce tree is off raw_cap, not the stage). ----
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^raw_cap;
    end
endmodule

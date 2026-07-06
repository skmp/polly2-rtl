//
// stage_tex_base_addr - timing harness for tex_base_addr (per-pixel shared texture
// addressing front-end; combinational).
//
// The harness owns the input buffer (in_reg bank) and the output buffer (raw_cap): it
// registers the decoded config inputs, feeds tex_base_addr (combinational), registers its
// whole output vector VERBATIM (no logic before the flop -> pure module delay), then
// XOR-folds to `digest`.
//
// Input-bank map:
//   0 : tex_addr_in[20:0]
//   1 : { pal_fmt[26:25], palsel[24:19], text_ctrl[18:14], miplevel[13:10], texv[9:7],
//         texu[6:4], pixfmt[3:1]... } -- see slices below
//   1 layout: [2:0]=pixfmt [5:3]=texu [8:6]=texv [12:9]=miplevel [17:13]=text_ctrl
//             [23:18]=palsel [25:24]=pal_fmt
//   2 : { mipmapped[3], stride_sel[2], scan[1], vq[0] }
//
module stage_tex_base_addr (
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

    wire [20:0] tex_addr_in = in_reg[0][20:0];
    wire [2:0]  pixfmt    = in_reg[1][2:0];
    wire [2:0]  texu      = in_reg[1][5:3];
    wire [2:0]  texv      = in_reg[1][8:6];
    wire [3:0]  miplevel  = in_reg[1][12:9];
    wire [4:0]  text_ctrl = in_reg[1][17:13];
    wire [5:0]  palsel    = in_reg[1][23:18];
    wire [1:0]  pal_fmt   = in_reg[1][25:24];
    wire        vq         = in_reg[2][0];
    wire        scan       = in_reg[2][1];
    wire        stride_sel = in_reg[2][2];
    wire        mipmapped  = in_reg[2][3];

    // ---- DUT ----
    wire [3:0]  u_log2, v_log2;
    wire [10:0] stride;
    wire        twiddled;
    wire [23:0] mip_add;
    wire [2:0]  fbpp_shr;
    wire [20:0] tex_addr, vq_addr;
    wire        o_scan, o_vq;
    wire [2:0]  o_pixfmt;
    wire [1:0]  o_pal_fmt;
    wire [5:0]  o_palsel;
    tex_base_addr u_dut (
        .tex_addr_in(tex_addr_in),.vq(vq),.scan(scan),.stride_sel(stride_sel),
        .mipmapped(mipmapped),.pixfmt(pixfmt),.pal_fmt(pal_fmt),.palsel(palsel),
        .texu(texu),.texv(texv),.miplevel(miplevel),.text_ctrl(text_ctrl),
        .u_log2(u_log2),.v_log2(v_log2),.stride(stride),.twiddled(twiddled),
        .mip_add(mip_add),.fbpp_shr(fbpp_shr),.tex_addr(tex_addr),.vq_addr(vq_addr),
        .o_scan(o_scan),.o_vq(o_vq),.o_pixfmt(o_pixfmt),.o_pal_fmt(o_pal_fmt),.o_palsel(o_palsel));

    // ---- RAW capture: register the DUT's whole output vector VERBATIM (no logic before
    //      the flop) -> pure combinational tex_base_addr delay. 102 bits total. ----
    reg [101:0] raw_cap;
    always @(posedge clk) begin
        if (reset) raw_cap <= '0;
        else raw_cap <= { u_log2, v_log2, stride, twiddled, mip_add, fbpp_shr,
                          tex_addr, vq_addr, o_scan, o_vq, o_pixfmt, o_pal_fmt, o_palsel };
    end
    // XOR-fold the REGISTERED vector to `digest` (off raw_cap, not the DUT).
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^raw_cap;
    end
endmodule

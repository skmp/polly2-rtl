// fog_tb_top - standalone harness for the FOG unit: reg_file (write-time precompute
// of the FOG_TABLE entries + FOG_DENSITY) -> fog_lut (1/W -> fog alpha) -> fog_blend
// (colour clamp + fog blend).
//
// The two halves are exercised together so the WRITE-TIME precompute is part of what
// is under test: the tb writes raw {b1,b0} table words and a raw {mant,exp} density
// through reg_file's normal host write path, exactly as a guest would.
//
// fog_lut is fed with stall=0 (the shade front's stall behaviour is covered by the
// full-pipe tbs); back-to-back issue every cycle is what this checks.
module fog_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,

    // host register/table write port (13-bit PVR byte offset)
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,

    // fog_lut input
    input             lut_valid,
    input      [31:0] invw,
    output            lut_ov,
    output     [7:0]  lut_alpha,

    // fog_blend input (driven independently of the LUT so every mode/clamp combo can
    // be swept without having to also produce a matching 1/W)
    input             bl_valid,
    input      [31:0] bl_col,
    input      [7:0]  bl_fog_alpha,
    input      [7:0]  bl_offs_a,
    input      [1:0]  bl_fog_ctrl,
    input             bl_color_clamp,
    input             bl_pp_offset,
    output            bl_ov,
    output     [31:0] bl_col_out
);
    pvr_regs_t   regs;
    fog_rd_req_t fog_req; fog_rd_resp_t fog_resp;
    pal_rd_req_t pal_req [0:3]; pal_rd_resp_t pal_resp [0:3];
    wire [31:0]  fog_den_f32;
    genvar g;
    generate for (g=0; g<4; g=g+1) begin : palt assign pal_req[g] = '0; end endgenerate

    reg_file u_rf (
        .clk(clk),.reset(reset),.wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),
        .regs(regs),.fog_req(fog_req),.fog_resp(fog_resp),.fog_den_f32(fog_den_f32),
        .pal_req(pal_req),.pal_resp(pal_resp));

    fog_lut u_lut (
        .clk(clk),.reset(reset),.stall(1'b0),.in_valid(lut_valid),
        .invw(invw),.fog_den(fog_den_f32),
        .fog_req(fog_req),.fog_resp(fog_resp),
        .out_valid(lut_ov),.fog_alpha(lut_alpha));

    fog_blend u_bl (
        .clk(clk),.reset(reset),.in_valid(bl_valid),
        .col(bl_col),.fog_alpha(bl_fog_alpha),.offs_a(bl_offs_a),
        .fog_ctrl(bl_fog_ctrl),.color_clamp(bl_color_clamp),.pp_offset(bl_pp_offset),
        .fog_col_ram(regs.fog_col_ram),.fog_col_vert(regs.fog_col_vert),
        .fog_clamp_max(regs.fog_clamp_max),.fog_clamp_min(regs.fog_clamp_min),
        .out_valid(bl_ov),.out_col(bl_col_out));
endmodule

// TB top: reg_file. Exposes the write path, a few named struct fields (raw +
// a bitfield-decoded example), and the FOG/PAL read ports flat for the C++ TB.
module reg_file_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,

    // a few scalar regs read back (raw 32-bit views of struct fields)
    output     [31:0] o_param_base,
    output     [31:0] o_region_base,
    output     [31:0] o_isp_backgnd_t,     // raw
    // bitfield-decoded fields of ISP_BACKGND_T
    output     [20:0] o_ispt_param_offs,
    output     [2:0]  o_ispt_skip,
    output            o_ispt_shadow,

    // FOG / PAL read ports
    input      [6:0]  fog_raddr,
    output     [31:0] fog_rdata,
    input      [9:0]  pal_raddr,
    output     [31:0] pal_rdata
);
    pvr_regs_t    regs;
    fog_rd_req_t  fog_req;  fog_rd_resp_t fog_resp;
    pal_rd_req_t  pal_req;  pal_rd_resp_t pal_resp;
    assign fog_req.raddr = fog_raddr;
    assign pal_req.raddr = pal_raddr;
    assign fog_rdata = fog_resp.rdata;
    assign pal_rdata = pal_resp.rdata;

    reg_file u_rf (
        .clk(clk),.reset(reset),.wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),
        .regs(regs),
        .fog_req(fog_req),.fog_resp(fog_resp),.pal_req(pal_req),.pal_resp(pal_resp));

    assign o_param_base      = regs.param_base;
    assign o_region_base     = regs.region_base;
    assign o_isp_backgnd_t   = regs.isp_backgnd_t;             // packed struct -> 32b
    assign o_ispt_param_offs = regs.isp_backgnd_t.param_offs_in_words;
    assign o_ispt_skip       = regs.isp_backgnd_t.skip;
    assign o_ispt_shadow     = regs.isp_backgnd_t.shadow;
endmodule

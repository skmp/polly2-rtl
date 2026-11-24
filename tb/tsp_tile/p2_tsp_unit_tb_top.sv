// p2_tsp_unit_tb_top: make tsp-tile's unit sections (tb/tsp_tile/tsp_unit_tb.cpp, PLAN M11 "unit sections for
// p2_tex_filter and p2_pp_shade"). Two harnesses on one clock, each with its own flat ports:
//
//   texture  (a_*)  a point's TSP / TCW words, mipChoose's level and the quotients U, V into a P3 register with
//                   p2_tex_coord, then P4 p2_tex_addr, P5 p2_tex_cache (C4 on p2_mem, the VRAM model), P6 p2_tex_decode +
//                   p2_tex_pal + p2_tex_filter: the texel (against p2ref::texture_filter)
//   shade    (b_*)  a point after P6 (its control, base and offset colours, 1/w, trilinear k and texel) into a P6 register,
//                   then P7 p2_pp_shade, P8 p2_pp_fog, P9 p2_pp_ss, P10 p2_pp_blend with p2_tbuf: each stage's colour
//                   (taps) and the tile-buffer write (against the copies of bumpLight / shade / fade / the SupSample
//                   average and p2ref::combiner / bump / fog / blend)
// Each harness has its own stall: its unit's own (tex_stall; fb_block) and the testbench's hold.
module p2_tsp_unit_tb_top
  import p2_regs_pkg::*;
  import p2_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic                              clk,
  input  logic                              rst,
  input  logic                              flush,
  // ---- shared registers
  input  logic [31:0]                       text_control,
  input  logic [31:0]                       pal_ram_ctrl,
  input  logic [31:0]                       half_offset,
  input  logic [31:0]                       fog_col_ram,
  input  logic [31:0]                       fog_col_vert,
  input  logic [31:0]                       fog_density,
  input  logic [31:0]                       fog_clamp_max,
  input  logic [31:0]                       fog_clamp_min,
  input  logic [31:0]                       pt_alpha_ref,
  input  logic                              pal_we,
  input  logic [9:0]                        pal_widx,
  input  logic [31:0]                       pal_wdata,
  input  logic                              ft_we,
  input  logic [6:0]                        ft_idx,
  input  logic [15:0]                       ft_wdata,
  // ---- texture harness
  input  logic                              a_v,
  output logic                              a_rdy,
  input  logic [31:0]                       a_tsp,
  input  logic [31:0]                       a_tcw,
  input  logic [3:0]                        a_level,
  input  logic                              a_uneg,
  input  logic [9:0]                        a_uexp,
  input  logic [17:0]                       a_umant,
  input  logic                              a_vneg,
  input  logic [9:0]                        a_vexp,
  input  logic [17:0]                       a_vmant,
  input  logic [15:0]                       a_tag,
  output logic                              a_o_v,         // a texel leaves P6
  output logic [15:0]                       a_o_tag,
  output logic [31:0]                       a_o_tex,
  input  logic                              a_hold,
  output logic                              a_t_miss,
  output logic                              a_t_stall,
  // ---- shade harness
  input  logic                              b_v,
  output logic                              b_rdy,
  input  logic                              b_null,
  input  logic                              b_eop,
  input  logic                              b_eoe,
  input  logic                              b_last,
  input  logic [2:0]                        b_rm,
  input  logic [4:0]                        b_x,
  input  logic [4:0]                        b_y,
  input  logic                              b_ro,
  input  logic                              b_atest,
  input  logic                              b_super,
  input  logic                              b_hx,
  input  logic                              b_hy,
  input  logic [31:0]                       b_isp,
  input  logic [31:0]                       b_tsp,
  input  logic [31:0]                       b_tcw,
  input  logic [31:0]                       b_ofs_fb,
  input  logic [31:0]                       b_base,
  input  logic [31:0]                       b_offs,
  input  logic                              b_wneg,
  input  logic [9:0]                        b_wexp,
  input  logic [16:0]                       b_wmant,
  input  logic [8:0]                        b_k,
  input  logic [31:0]                       b_tex,
  input  logic [15:0]                       b_tag,
  input  logic                              b_hold,
  input  logic                              ok_we,
  input  logic [31:0]                       ok_wdata,
  output logic [31:0]                       offs_kept,
  output logic                              b_p7_v,        // a point leaves P7, P8, P9 (its colour), P10
  output logic [15:0]                       b_p7_tag,
  output logic [31:0]                       b_p7_col,
  output logic [7:0]                        b_p7_fa,
  output logic                              b_p8_v,
  output logic [15:0]                       b_p8_tag,
  output logic [31:0]                       b_p8_col,
  output logic                              b_p9_v,
  output logic [15:0]                       b_p9_tag,
  output logic [31:0]                       b_p9_col,
  output logic                              b_p10_v,
  output logic [15:0]                       b_p10_tag,
  output logic                              b_at,
  output logic                              b_stuck,
  output logic                              wr_en,
  output logic                              wr_b2,
  output logic [9:0]                        wr_idx,
  output logic [31:0]                       wr_data,
  output logic                              fb_v,
  input  logic                              fb_rdy,
  output logic                              fb_kind,
  output logic [9:0]                        fb_idx,
  output logic                              fb_fail,
  output logic                              fb_ro,
  input  logic                              dbg_we,
  input  logic                              dbg_b2,
  input  logic [9:0]                        dbg_idx,
  input  logic [31:0]                       dbg_wdata,
  // ---- VRAM
  output logic [1:0]                        vh_req_v,
  input  logic [1:0]                        vh_req_rdy,
  output logic [1:0]                        vh_req_we,
  output logic [19:0]                       vh_req_idx [2],
  output logic [3:0]                        vh_req_be [2],
  output logic [31:0]                       vh_req_wdata [2],
  output logic [2:0]                        vh_req_src [2],
  input  logic [1:0]                        vh_rsp_v,
  input  logic [31:0]                       vh_rsp_data [2],
  input  logic [2:0]                        vh_rsp_src [2]
);
  // the testbench's tag rides in the point's control (its x, y, n: unused by these stages in harness A; in B the tag field)
  // ---------------------------------------------------------------------------------------------- texture harness
  logic        a_stall, tex_stall, a3_v, a4_v, a5_v, a6_v;
  p2_pp_ctl_t  a_ctl;
  p2_pp_pt_t   a3_pt, a4_pt, a5_pt, a6_pt;
  p2_quot_t    a_qu, a_qv;
  p2_tex_req_t a4_req, a5_req;
  logic [3:0][63:0] a5_word;
  logic [3:0][9:0]  a_pidx;
  logic [3:0][31:0] a_pdata, a_texel;
  logic [3:0]       a3_level;
  logic signed [31:0] a3_tu, a3_tv;
  assign a_stall = tex_stall || (a6_v && a_hold);
  assign a_rdy   = !a_stall;
  always_comb begin
    a_ctl          = '0;
    a_ctl.hdr.isp  = 32'h0200_0000;          // Texture
    a_ctl.hdr.tsp  = a_tsp;
    a_ctl.hdr.tcw  = a_tcw;
    a_ctl.tag      = p2_tag_t'({16'd0, a_tag});
    a_qu.neg  = a_uneg;  a_qu.exp = a_uexp;  a_qu.mant = a_umant;
    a_qv.neg  = a_vneg;  a_qv.exp = a_vexp;  a_qv.mant = a_vmant;
  end
  always_ff @(posedge clk) begin
    if (rst) a3_v <= 1'b0;
    else if (!a_stall) a3_v <= a_v;
    if (a_v && !a_stall) begin
      a3_level <= a_level;
      a3_pt    <= '0;
      a3_pt.ctl <= a_ctl;
    end
  end
  p2_tex_coord u_coord (.clk, .stall(a_stall), .i_v(a_v), .i_ctl(a_ctl), .i_qu(a_qu), .i_qv(a_qv), .o_tu(a3_tu), .o_tv(a3_tv));
  p2_pp_pt_t a3_full;
  always_comb begin
    a3_full       = a3_pt;
    a3_full.level = a3_level;
    a3_full.tu    = a3_tu;
    a3_full.tv    = a3_tv;
  end
  logic        m4_v, m4_rrdy;
  logic [23:0] m4_addr;
  localparam int NC = 6;
  logic [NC-1:0]        c_v, c_rdy, c_we, c_w64, c_rv, c_rrdy;
  logic [NC-1:0][23:0]  c_addr;
  logic [NC-1:0][7:0]   c_be;
  logic [NC-1:0][63:0]  c_wdata, c_rdata;
  p2_tex_addr u_addr (.clk, .rst, .stall(a_stall), .text_control, .half_tex(half_offset[2]), .i_v(a3_v), .i_pt(a3_full),
    .o_v(a4_v), .o_pt(a4_pt), .o_req(a4_req));
  p2_tex_cache u_cache (.clk, .rst, .flush, .stall(a_stall), .swap16(text_control[17]), .i_v(a4_v), .i_pt(a4_pt), .i_req(a4_req), .tex_stall,
    .o_v(a5_v), .o_pt(a5_pt), .o_req(a5_req), .o_word(a5_word),
    .m_v(m4_v), .m_rdy(c_rdy[P2_C_TEX]), .m_addr(m4_addr), .m_rv(c_rv[P2_C_TEX]), .m_rrdy(m4_rrdy),
    .m_rdata(c_rdata[P2_C_TEX]), .t_fill(), .t_miss(a_t_miss));
  p2_tex_pal u_pal (.clk, .we(pal_we), .widx(pal_widx), .wdata(pal_wdata), .ridx(a_pidx), .rdata(a_pdata));
  p2_tex_decode u_decode (.req(a5_req), .tcw(a5_pt.ctl.hdr.tcw), .pal_mode(pal_ram_ctrl[1:0]),
    .word(a5_word), .pal_idx(a_pidx), .pal_data(a_pdata), .texel(a_texel));
  logic [31:0] a6_tex;
  p2_tex_filter u_filter (.clk, .rst, .stall(a_stall), .i_v(a5_v), .i_pt(a5_pt), .i_req(a5_req), .texel(a_texel),
    .o_v(a6_v), .o_pt(a6_pt), .o_tex(a6_tex));
  assign a_o_v     = a6_v && !a_stall;
  assign a_o_tag   = a6_pt.ctl.tag[15:0];
  assign a_o_tex   = a6_tex;
  assign a_t_stall = tex_stall;
  always_comb begin
    c_v    = '0;
    c_addr = '0;
    c_rrdy = '1;
    c_we   = '0;
    c_w64  = '0;
    c_be   = '1;
    c_wdata = '0;
    c_v[P2_C_TEX]    = m4_v;
    c_addr[P2_C_TEX] = m4_addr;
    c_rrdy[P2_C_TEX] = m4_rrdy;
    c_w64[P2_C_TEX]  = 1'b1;
  end
  logic [1:0][19:0] vidx;
  logic [1:0][3:0]  vbe;
  logic [1:0][31:0] vwd, vrd;
  logic [1:0][2:0]  vsrc, vrsrc;
  p2_mem #(.NC(NC)) u_mem (.clk(clk), .rst(rst), .c_v(c_v), .c_rdy(c_rdy), .c_we(c_we), .c_w64(c_w64), .c_addr(c_addr),
    .c_be(c_be), .c_wdata(c_wdata), .c_rv(c_rv), .c_rrdy(c_rrdy), .c_rdata(c_rdata), .vh_req_v(vh_req_v),
    .vh_req_rdy(vh_req_rdy), .vh_req_we(vh_req_we), .vh_req_idx(vidx), .vh_req_be(vbe), .vh_req_wdata(vwd),
    .vh_req_src(vsrc), .vh_rsp_v(vh_rsp_v), .vh_rsp_data(vrd), .vh_rsp_src(vrsrc));
  always_comb
    for (int h = 0; h < 2; h++) begin
      vh_req_idx[h]   = vidx[h];
      vh_req_be[h]    = vbe[h];
      vh_req_wdata[h] = vwd[h];
      vh_req_src[h]   = vsrc[h];
      vrd[h]          = vh_rsp_data[h];
      vrsrc[h]        = vh_rsp_src[h];
    end

  // ---------------------------------------------------------------------------------------------- shade harness
  logic        b_stall, fb_block, b6_v, b7_v, b8_v, b9_v, p10_out;
  p2_pp_pt_t   b_pt, b6_pt, b7_pt, b8_pt, b9_pt;
  logic [31:0] b6_tex, b7_col, b8_col, b9_col;
  logic [7:0]  b7_fa;
  p2_pp_ctl_t  b10_ctl;
  assign b_stall = fb_block || b_hold;
  assign b_rdy   = !b_stall;
  always_comb begin
    b_pt                 = '0;
    b_pt.ctl.null_       = b_null;
    b_pt.ctl.eop         = b_eop;
    b_pt.ctl.eoe         = b_eoe;
    b_pt.ctl.last        = b_last;
    b_pt.ctl.pxlast      = !b_super || (b_hx && b_hy);
    b_pt.ctl.tag         = p2_tag_t'({16'd0, b_tag});
    b_pt.ctl.rm          = p2_rm_t'(b_rm);
    b_pt.ctl.x           = b_x;
    b_pt.ctl.y           = b_y;
    b_pt.ctl.ro          = b_ro;
    b_pt.ctl.atest       = b_atest;
    b_pt.ctl.super_      = b_super;
    b_pt.ctl.hx          = b_hx;
    b_pt.ctl.hy          = b_hy;
    b_pt.ctl.hdr.isp     = b_isp;
    b_pt.ctl.hdr.tsp     = b_tsp;
    b_pt.ctl.hdr.tcw     = b_tcw;
    b_pt.ctl.hdr.ofs_fb  = b_ofs_fb;
    b_pt.base            = b_base;
    b_pt.offs            = b_offs;
    b_pt.w.neg           = b_wneg;
    b_pt.w.exp           = b_wexp;
    b_pt.w.mant          = b_wmant;
    b_pt.k               = b_k;
  end
  always_ff @(posedge clk) begin
    if (rst) b6_v <= 1'b0;
    else if (!b_stall) b6_v <= b_v;
    if (b_v && !b_stall) begin
      b6_pt  <= b_pt;
      b6_tex <= b_tex;
    end
  end
  p2_pp_shade u_shade (.clk, .rst, .stall(b_stall), .i_v(b6_v), .i_pt(b6_pt), .i_tex(b6_tex),
    .o_v(b7_v), .o_pt(b7_pt), .o_col(b7_col), .o_fa(b7_fa), .offs_kept, .ok_we, .ok_wdata);
  p2_pp_fog u_fog (.clk, .rst, .stall(b_stall), .fog_col_ram, .fog_col_vert, .fog_density(fog_density[15:0]), .fog_clamp_max,
    .fog_clamp_min, .ft_we, .ft_idx, .ft_wdata, .i_v(b7_v), .i_pt(b7_pt), .i_col(b7_col), .i_fa(b7_fa),
    .o_v(b8_v), .o_pt(b8_pt), .o_col(b8_col));
  p2_pp_ss u_ss (.clk, .stall(b_stall), .i_v(b8_v), .i_pt(b8_pt), .i_col(b8_col), .o_v(b9_v), .o_pt(b9_pt), .o_col(b9_col));
  logic                   tb_rd_en, tb_rd_b2;
  logic [P2_PIX_BITS-1:0] tb_rd_idx;
  p2_fb_t                 fbm;
  assign fb_kind = fbm.kind;
  assign fb_idx  = fbm.idx;
  assign fb_fail = fbm.fail;
  assign fb_ro   = fbm.ro;
  logic [31:0]            tb_rd_b1_data, tb_rd_b2_data;
  p2_pp_blend u_blend (.clk, .rst, .stall(b_stall), .pt_alpha_ref, .i_v(b9_v), .i_pt(b9_pt), .i_col(b9_col),
    .rd_en(tb_rd_en), .rd_idx(tb_rd_idx), .rd_b2(tb_rd_b2), .rd_b1_data(tb_rd_b1_data), .rd_b2_data(tb_rd_b2_data),
    .wr_en, .wr_b2, .wr_idx, .wr_data, .fb_v, .fb_rdy, .fb(fbm), .fb_block, .drain_done(), .rel_v(), .rel_need(), .rel_idx(),
    .t_out(p10_out), .t_ctl(b10_ctl), .t_stuck(b_stuck), .t_at(b_at));
  p2_tbuf u_tbuf (.clk, .rst, .swap(1'b0), .sel(),
    .rd_en(tb_rd_en), .rd_idx(tb_rd_idx), .rd_b2(tb_rd_b2), .rd_b1_data(tb_rd_b1_data), .rd_b2_data(tb_rd_b2_data),
    .wr_en, .wr_b2, .wr_idx, .wr_data, .wo_re(1'b0), .wo_idx('0), .wo_gnt(), .wo_data(),
    .dbg_we, .dbg_b2, .dbg_idx, .dbg_wdata, .dbg_b1(), .dbg_b2_data());
  assign b_p7_v    = b6_v && !b_stall;
  assign b_p7_tag  = b6_pt.ctl.tag[15:0];
  assign b_p7_col  = b7_col;
  assign b_p7_fa   = b7_fa;
  assign b_p8_v    = b7_v && !b_stall;
  assign b_p8_tag  = b7_pt.ctl.tag[15:0];
  assign b_p8_col  = b8_col;
  assign b_p9_v    = b9_v && !b_stall;
  assign b_p9_tag  = b9_pt.ctl.tag[15:0];
  assign b_p9_col  = b9_col;
  assign b_p10_v   = p10_out;
  assign b_p10_tag = b10_ctl.tag[15:0];
endmodule

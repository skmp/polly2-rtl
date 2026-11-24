// p2_tsp_pp: the TSP's pixel pipe, P0 - P11 (PLAN M10, M11; ARCHITECTURE 3.7.7, 3.8). One point a clock through fixed
// stages with one global stall; the units and the stage each registers:
//
//   P0  p2_pp_issue    points from p2_pxq's head; the pass drain
//   P1  p2_pp_plane    the planes' values
//   P2  p2_pp_div      the reciprocal and the quotients
//   P3  p2_pp_col      colours, + p2_pp_mip (the level), p2_tex_coord (TexCoordFixed)
//   P4  p2_tex_addr    four taps' addresses
//   P5  p2_tex_cache   the texture cache (C4), the gather; tex_stall
//   P6  p2_tex_decode, p2_tex_filter (+ p2_tex_pal, the palette RAM)
//   P7  p2_pp_shade    bump map, combiner, offsKept
//   P8  p2_pp_fog      colour clamp, fog (FOG_TABLE), the trilinear fade
//   P9  p2_pp_ss       SupSample's average, into p2_pp_blend's P9 register (the tile buffers read)
//   P10 p2_pp_blend    stuck alpha, alpha test, blend, the write (p2_tbuf, outside), the P10 forward
//   P11 p2_pp_blend    the feedback to the ISP
//
// The global stall: P5's tex_stall (a tap not in, VQ's index phase), P11's queue full (fb_block), `ext_stall` (the
// testbench's back-pressure) and, M12, the buffer-2 interlock (dlock: a DstSelect point in P10 while the write-out is
// busy). The stages before P10 also hold for `hold9` (P10 a bubble: an eoe point in P10, or the tile buffers' controller's
// action pending, `tb_hold`; p2_pp_blend). The pass drain ends, and a run's store entries are released,
// when a point leaves P10 (M11; P3 in M10). The P3 taps (p3_*) are the M10 testbench's view of the pipe's values.
module p2_tsp_pp
  import p2_regs_pkg::*;
  import p2_pkg::*;
  import p2_tsp_pkg::*;
  import p2_tsp_prog_pkg::*;
(
  input  logic                               clk,
  input  logic                               rst,
  input  logic                               flush,
  // the render's registers
  input  logic [31:0]                        text_control,
  input  logic [1:0]                         pal_ram_ctrl,
  input  logic                               half_tex,         // HALF_OFFSET[2]
  input  logic [31:0]                        fog_col_ram,
  input  logic [31:0]                        fog_col_vert,
  input  logic [15:0]                        fog_density,
  input  logic [31:0]                        fog_clamp_max,
  input  logic [31:0]                        fog_clamp_min,
  input  logic [31:0]                        pt_alpha_ref,
  // the register port's RAMs: PALETTE_RAM, FOG_TABLE
  input  logic                               pal_we,
  input  logic [9:0]                         pal_widx,
  input  logic [31:0]                        pal_wdata,
  input  logic                               ft_we,
  input  logic [6:0]                         ft_idx,
  input  logic [15:0]                        ft_wdata,
  // offsKept's load port (the testbench)
  input  logic                               ok_we,
  input  logic [31:0]                        ok_wdata,
  output logic [31:0]                        offs_kept,
  // p2_pxq's head
  input  logic                               q_v,
  output logic                               q_rdy,
  input  p2_tsp_rdesc_t                      q_d,
  output logic                               cred_ret,
  // C4
  output logic                               m_v,
  input  logic                               m_rdy,
  output logic [23:0]                        m_addr,
  input  logic                               m_rv,
  output logic                               m_rrdy,
  input  logic [63:0]                        m_rdata,
  // p2_tbuf
  output logic                               tb_rd_en,
  output logic [P2_PIX_BITS-1:0]             tb_rd_idx,
  output logic                               tb_rd_b2,
  input  logic [31:0]                        tb_rd_b1_data,
  input  logic [31:0]                        tb_rd_b2_data,
  output logic                               tb_wr_en,
  output logic                               tb_wr_b2,
  output logic [P2_PIX_BITS-1:0]             tb_wr_idx,
  output logic [31:0]                        tb_wr_data,
  // the feedback to the ISP
  output logic                               fb_v,
  input  logic                               fb_rdy,
  output p2_fb_t                             fb,
  // the store's pins
  output logic                               rel_v,
  output logic [1:0]                         rel_need,
  output logic [1:0][P2_TSP_SIDX_BITS-1:0]   rel_idx,
  input  logic                               ext_stall,
  input  logic                               tb_hold,          // p2_tbuf_ctl: an entry's action is pending
  input  logic                               wo_busy,          // p2_wout is busy (the buffer-2 interlock)
  output logic                               stall,
  // P3's point (the M10 testbench's view)
  output logic                               p3_v,
  output logic                               p3_take,
  output p2_pp_ctl_t                         p3_ctl,
  output p2_pval_t [P2_TSP_NPL-1:0]          p3_val,
  output p2_quot_t [P2_TSP_NPL-1:0]          p3_q,
  output logic [31:0]                        p3_base,
  output logic [31:0]                        p3_offs,
  output logic [3:0]                         p3_level,
  output logic [8:0]                         p3_k,
  output logic signed [17:0]                 p3_rl,
  output logic [8:0]                         p3_rk,
  // taps
  output logic                               t_p7,             // a point leaves P7 (offsKept after it: offs_kept)
  output p2_pp_ctl_t                         t_p7_ctl,
  output logic                               t_p10,            // a point leaves P10
  output p2_pp_ctl_t                         t_p10_ctl,
  output logic                               t_stuck,
  output logic                               t_at,
  output logic                               t_drain,
  output logic                               t_p0,
  output logic                               t_tex_stall,
  output logic                               t_fill,
  output logic                               t_miss,
  output logic                               t_fb_block
);
  logic tex_stall, fb_block, drain_done, dlock, p10_eoe, hold9, stall_up;
  assign stall       = tex_stall || fb_block || ext_stall || dlock;
  assign hold9       = p10_eoe || tb_hold;
  assign stall_up    = stall || hold9;           // P0 - P9
  assign t_tex_stall = tex_stall;
  assign t_fb_block  = fb_block;

  // ---------------------------------------------------------------------------------------------- P0 - P3 (M10)
  logic                               p0_v, p0_first, p1_v, p2_v;
  p2_pp_ctl_t                         p0_ctl, p1_ctl, p2_ctl;
  p2_tsp_pev_t [1:0][P2_TSP_NPL-1:0]  run_pl;
  p2_pval_t [P2_TSP_NPL-1:0]          p1_val, p2_val;
  p2_quot_t [P2_TSP_NPL-1:0]          p2_q;
  p2_pp_issue u_issue (.clk, .rst, .stall(stall_up), .q_v, .q_rdy, .q_d, .cred_ret, .p_v(p0_v), .p_ctl(p0_ctl), .p_first(p0_first),
    .run_pl, .drain_done, .t_drain);
  p2_pp_plane u_plane (.clk, .rst, .stall(stall_up), .p_v(p0_v), .p_ctl(p0_ctl), .p_first(p0_first), .run_pl,
    .o_v(p1_v), .o_ctl(p1_ctl), .o_val(p1_val));
  p2_pp_div u_div (.clk, .rst, .stall(stall_up), .i_v(p1_v), .i_ctl(p1_ctl), .i_val(p1_val),
    .o_v(p2_v), .o_ctl(p2_ctl), .o_val(p2_val), .o_q(p2_q));
  p2_pp_col u_col (.clk, .rst, .stall(stall_up), .i_v(p2_v), .i_ctl(p2_ctl), .i_val(p2_val), .i_q(p2_q),
    .o_v(p3_v), .o_ctl(p3_ctl), .o_val(p3_val), .o_q(p3_q), .o_base(p3_base), .o_offs(p3_offs));
  p2_pp_mip u_mip (.clk, .stall(stall_up), .i_v(p2_v), .i_ctl(p2_ctl), .i_w(p2_q[0]), .o_level(p3_level), .o_k(p3_k), .o_rl(p3_rl),
    .o_rk(p3_rk));
  logic signed [31:0] p3_tu, p3_tv;
  p2_tex_coord u_coord (.clk, .stall(stall_up), .i_v(p2_v), .i_ctl(p2_ctl), .i_qu(p2_q[P2_TSP_PL_U]), .i_qv(p2_q[P2_TSP_PL_V]),
    .o_tu(p3_tu), .o_tv(p3_tv));
  assign t_p0    = p0_v && !stall_up;
  assign p3_take = p3_v && !stall_up;

  p2_pp_pt_t p3_pt;
  always_comb begin
    p3_pt       = '0;
    p3_pt.ctl   = p3_ctl;
    p3_pt.base  = p3_base;
    p3_pt.offs  = p3_offs;
    p3_pt.w     = p3_val[P2_TSP_PL_W];
    p3_pt.level = p3_level;
    p3_pt.k     = p3_k;
    p3_pt.tu    = p3_tu;
    p3_pt.tv    = p3_tv;
  end

  // ---------------------------------------------------------------------------------------------- P4 - P6: texture
  logic             p4_v, p5_v, p6_v;
  p2_pp_pt_t        p4_pt, p5_pt, p6_pt;
  p2_tex_req_t      p4_req, p5_req;
  logic [3:0][63:0] p5_word;
  logic [31:0]      p6_tex;
  p2_tex_addr u_addr (.clk, .rst, .stall(stall_up), .text_control, .half_tex, .i_v(p3_v), .i_pt(p3_pt),
    .o_v(p4_v), .o_pt(p4_pt), .o_req(p4_req));
  p2_tex_cache u_cache (.clk, .rst, .flush, .stall(stall_up), .swap16(text_control[17]), .i_v(p4_v), .i_pt(p4_pt), .i_req(p4_req), .tex_stall,
    .o_v(p5_v), .o_pt(p5_pt), .o_req(p5_req), .o_word(p5_word),
    .m_v, .m_rdy, .m_addr, .m_rv, .m_rrdy, .m_rdata, .t_fill, .t_miss);
  logic [3:0][9:0]  pal_idx;
  logic [3:0][31:0] pal_data, texel;
  p2_tex_pal u_pal (.clk, .we(pal_we), .widx(pal_widx), .wdata(pal_wdata), .ridx(pal_idx), .rdata(pal_data));
  p2_tex_decode u_decode (.req(p5_req), .tcw(p5_pt.ctl.hdr.tcw), .pal_mode(pal_ram_ctrl),
    .word(p5_word), .pal_idx, .pal_data, .texel);
  p2_tex_filter u_filter (.clk, .rst, .stall(stall_up), .i_v(p5_v), .i_pt(p5_pt), .i_req(p5_req), .texel,
    .o_v(p6_v), .o_pt(p6_pt), .o_tex(p6_tex));

  // ---------------------------------------------------------------------------------------------- P7 - P11
  logic        p7_v, p8_v, p9_v;
  p2_pp_pt_t   p7_pt, p8_pt, p9_pt;
  logic [31:0] p7_col, p8_col, p9_col;
  logic [7:0]  p7_fa;
  p2_pp_shade u_shade (.clk, .rst, .stall(stall_up), .i_v(p6_v), .i_pt(p6_pt), .i_tex(p6_tex),
    .o_v(p7_v), .o_pt(p7_pt), .o_col(p7_col), .o_fa(p7_fa), .offs_kept, .ok_we, .ok_wdata);
  p2_pp_fog u_fog (.clk, .rst, .stall(stall_up), .fog_col_ram, .fog_col_vert, .fog_density, .fog_clamp_max, .fog_clamp_min,
    .ft_we, .ft_idx, .ft_wdata, .i_v(p7_v), .i_pt(p7_pt), .i_col(p7_col), .i_fa(p7_fa),
    .o_v(p8_v), .o_pt(p8_pt), .o_col(p8_col));
  p2_pp_ss u_ss (.clk, .stall(stall_up), .i_v(p8_v), .i_pt(p8_pt), .i_col(p8_col), .o_v(p9_v), .o_pt(p9_pt), .o_col(p9_col));
  p2_pp_blend u_blend (.clk, .rst, .stall, .pt_alpha_ref, .hold9, .wo_busy, .p10_eoe, .dlock, .i_v(p9_v), .i_pt(p9_pt), .i_col(p9_col),
    .rd_en(tb_rd_en), .rd_idx(tb_rd_idx), .rd_b2(tb_rd_b2), .rd_b1_data(tb_rd_b1_data), .rd_b2_data(tb_rd_b2_data),
    .wr_en(tb_wr_en), .wr_b2(tb_wr_b2), .wr_idx(tb_wr_idx), .wr_data(tb_wr_data),
    .fb_v, .fb_rdy, .fb, .fb_block, .drain_done, .rel_v, .rel_need, .rel_idx,
    .t_out(t_p10), .t_ctl(t_p10_ctl), .t_stuck, .t_at);

  // P6's point leaving P7 (offsKept after it)
  assign t_p7     = p6_v && !stall_up;
  assign t_p7_ctl = p6_pt.ctl;
endmodule

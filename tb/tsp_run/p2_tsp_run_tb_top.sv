// p2_tsp_run_tb_top: make tsp-run (tb/tsp_run/tsp_run_tb.cpp, PLAN M10). The TSP from the sorter's items to the pixel
// pipe's P3, wired as ARCHITECTURE 1.1 / 3.7 draws it, with flat ports for the testbench:
//
//   the sorter's items ──► p2_tsp_store ──► SRQ head ──► p2_tsp_rstart ──► p2_pxq ──► p2_pp_issue (P0) ──► p2_pp_plane (P1)
//      entry records ───────────────────────────────────┘    │  ▲ rw (row read)            ▲ credits         │
//                          │ jobs        ▲ writes            │  │                         │                 ▼
//                          ▼             │          hold, rs ▼  │                         │       p2_pp_div (P2)
//                      p2_tsp_pfetch ──► p2_tsp_setup ◄─ p2_tsp_alu (run start first)     │                 │
//                          │ C3                                                           │                 ▼
//                          ▼                                                    drain ◄── p2_pp_col + p2_pp_mip (P3) ──► out
//                      p2_mem ──► the VRAM model                                    rel (pins) ◄──┘
//
// The testbench drives the registers, the items (with random gaps) and the entries' records, takes P3's points with
// random back-pressure (the pipe's external stall) and compares every point with refsw3. Since M11 the pipe goes on to
// P10 (p2_tsp_pp, with the texture cache on C4 and the tile buffers): the pins of a run go at its last point's exit from
// P10, and the pass drain ends there; the testbench still reads every point at P3 (o_take).
module p2_tsp_run_tb_top
  import p2_regs_pkg::*;
  import p2_pkg::*;
  import p2_tsp_pkg::*;
  import p2_tsp_prog_pkg::*;
(
  input  logic                              clk,
  input  logic                              rst,
  input  logic                              flush,
  // ---- the render's registers
  input  logic [31:0]                       param_base,
  input  logic [31:0]                       fpu_shad_scale,
  input  logic [31:0]                       fpu_perp_val,
  input  logic                              half,
  // ---- the sorter's items
  input  logic                              in_v,
  output logic                              in_rdy,
  input  logic                              in_null,
  input  logic [31:0]                       in_tag,
  input  logic [4:0]                        in_y,
  input  logic [4:0]                        in_x,
  input  logic [4:0]                        in_lenm1,
  input  logic [2:0]                        in_rm,
  input  logic [31:0]                       in_vmask,
  input  logic [31:0]                       in_pmask,
  input  logic                              in_eop,
  input  logic                              in_eoe,
  input  logic                              in_nd,
  // ---- the entries' records
  input  logic                              er_v,
  output logic                              er_rdy,
  input  logic [5:0]                        er_tilex,
  input  logic [5:0]                        er_tiley,
  // ---- P3's points
  output logic                              o_v,
  input  logic                              o_rdy,
  output logic                              o_take,
  output logic                              o_null,
  output logic                              o_eop,
  output logic                              o_eoe,
  output logic                              o_last,
  output logic [31:0]                       o_tag,
  output logic [2:0]                        o_rm,
  output logic [5:0]                        o_tilex,
  output logic [5:0]                        o_tiley,
  output logic [4:0]                        o_x,
  output logic [4:0]                        o_y,
  output logic [4:0]                        o_n,
  output logic                              o_vsel,
  output logic                              o_ro,
  output logic                              o_atest,
  output logic                              o_super,
  output logic                              o_hx,
  output logic                              o_hy,
  output logic [3:0]                        o_cls,
  output logic [31:0]                       o_isp,
  output logic [31:0]                       o_tsp,
  output logic [31:0]                       o_tcw,
  output logic [10:0]                       o_vneg,
  output logic [9:0]                        o_vexp [11],
  output logic [16:0]                       o_vmant [11],
  output logic [10:0]                       o_qneg,
  output logic [9:0]                        o_qexp [11],
  output logic [17:0]                       o_qmant [11],
  output logic [31:0]                       o_base,
  output logic [31:0]                       o_offs,
  output logic [3:0]                        o_level,
  output logic [8:0]                        o_k,
  output logic [17:0]                       o_rl,
  output logic [8:0]                        o_rk,
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
  input  logic [2:0]                        vh_rsp_src [2],
  // ---- taps (statistics)
  output logic                              t_rs_busy,
  output logic                              t_rs_reload,
  output logic                              t_rs_mul,
  output logic                              t_setup_idle,
  output logic                              t_fetch_idle,
  output logic                              t_drain,
  output logic [5:0]                        t_pxq_runs,
  output logic [8:0]                        t_pxq_pix,
  output logic [4:0]                        t_pinned,
  output logic [5:0]                        t_srq,
  output logic                              t_job,
  output logic                              t_p0
);
  p2_rs_t in_item;
  always_comb begin
    in_item        = '0;
    in_item.null_  = in_null;
    in_item.tag    = p2_tag_t'(in_tag);
    in_item.y      = in_y;
    in_item.x      = in_x;
    in_item.lenm1  = in_lenm1;
    in_item.rm     = p2_rm_t'(in_rm);
    in_item.vmask  = in_vmask;
    in_item.pmask  = in_pmask;
    in_item.eop    = in_eop;
    in_item.eoe    = in_eoe;
  end

  // ---------------------------------------------------------------------------------------------- the store
  logic                  jb_v, jb_rdy;
  p2_tsp_job_t           jb;
  logic                  sh_v, sp_v, sk_v, done;
  logic [3:0]            sh_idx, sp_idx, sk_idx, done_idx, sp_plane;
  p2_tsp_hdr_t           sh_w, rw_hdr;
  p2_tsp_plane_t         sp_w;
  p2_tsp_k_t             sk_w, rw_k;
  p2_tsp_plane_t [3:0]   rw_plane;
  logic                  hd_v, hd_rdy, hd_nd;
  p2_rs_t                hd_item;
  logic [1:0]            hd_need;
  logic [1:0][3:0]       hd_idx;
  logic                  rel_v;
  logic [1:0]            rel_need;
  logic [1:0][3:0]       rel_idx;
  logic                  rw_v;
  logic [3:0]            rw_idx;
  logic [1:0]            rw_row;
  p2_tsp_store u_store (
    .clk, .rst, .flush,
    .in_v, .in_rdy, .in_item, .in_nd,
    .out_v(hd_v), .out_rdy(hd_rdy), .out_item(hd_item), .out_nd(hd_nd), .out_need(hd_need), .out_idx(hd_idx),
    .rel_v, .rel_need, .rel_idx,
    .jb_v, .jb_rdy, .jb,
    .sh_v, .sh_idx, .sh_w, .sp_v, .sp_idx, .sp_plane, .sp_w, .sk_v, .sk_idx, .sk_w, .done, .done_idx,
    .rd_v(1'b0), .rd_idx('0), .rd_word('0), .rd_hdr(), .rd_k(), .rd_plane(),
    .rw_v, .rw_idx, .rw_row, .rw_hdr, .rw_k, .rw_plane,
    .t_srq, .t_pinned, .t_la_wait(), .t_job, .t_hit());

  // ---------------------------------------------------------------------------------------------- fetch (C3), setup, ALU
  localparam int NC = 6;
  logic [NC-1:0]        c_v, c_rdy, c_we, c_w64, c_rv, c_rrdy;
  logic [NC-1:0][23:0]  c_addr;
  logic [NC-1:0][7:0]   c_be;
  logic [NC-1:0][63:0]  c_wdata, c_rdata;
  logic                 m3_v, m3_rrdy;
  logic [23:0]          m3_addr;
  logic                 pr_v, pr_rdy;
  p2_tsp_prim_t         pr;
  p2_tsp_pfetch u_pfetch (
    .clk, .rst, .jb_v, .jb_rdy, .jb, .param_base, .shad_intensity(fpu_shad_scale[8]),
    .pr_v, .pr_rdy, .pr, .idle(t_fetch_idle),
    .m_v(m3_v), .m_rdy(c_rdy[P2_C_TSP_PFETCH]), .m_addr(m3_addr), .m_rv(c_rv[P2_C_TSP_PFETCH]), .m_rrdy(m3_rrdy),
    .m_rdata(c_rdata[P2_C_TSP_PFETCH][31:0]));
  logic                       hold;
  p2_fp16_t [P2_TSP_NM-1:0]   rs_a;
  logic [P2_TSP_NM-1:0][12:0] rs_b;
  p2_tsp_rsp_t [P2_TSP_NM-1:0] rs_p;
  p2_tsp_setup u_setup (
    .clk, .rst, .pr_v, .pr_rdy, .pr, .fpu_shad_scale, .fpu_perp_val, .hold, .rs_a, .rs_b, .rs_p,
    .sh_v, .sh_idx, .sh_w, .sp_v, .sp_idx, .sp_plane, .sp_w, .sk_v, .sk_idx, .sk_w, .done, .done_idx,
    .idle(t_setup_idle), .t_issue(), .t_cls(), .t_pc(), .t_uw(), .t_wv(), .t_wrd());
  always_comb begin
    c_v     = '0;
    c_addr  = '0;
    c_rrdy  = '1;
    c_v[P2_C_TSP_PFETCH]    = m3_v;
    c_addr[P2_C_TSP_PFETCH] = m3_addr;
    c_rrdy[P2_C_TSP_PFETCH] = m3_rrdy;
    c_v[P2_C_TEX]           = m4_v;
    c_addr[P2_C_TEX]        = m4_addr;
    c_rrdy[P2_C_TEX]        = m4_rrdy;
    c_we    = '0;
    c_w64   = '0;
    c_w64[P2_C_TEX] = 1'b1;
    c_be    = '1;
    c_wdata = '0;
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

  // ---------------------------------------------------------------------------------------------- run start, the queue
  logic          rd_v, rd_rdy;
  p2_tsp_rdesc_t rd_d;
  p2_tsp_rstart u_rstart (
    .clk, .rst, .flush, .half,
    .er_v, .er_rdy, .er_tilex, .er_tiley,
    .in_v(hd_v), .in_rdy(hd_rdy), .in_item(hd_item), .in_need(hd_need), .in_idx(hd_idx),
    .rw_v, .rw_idx, .rw_row, .rw_hdr, .rw_k, .rw_plane,
    .hold, .rs_a, .rs_b, .rs_p,
    .o_v(rd_v), .o_rdy(rd_rdy), .o_d(rd_d),
    .t_busy(t_rs_busy), .t_reload(t_rs_reload), .t_mul(t_rs_mul));
  logic          q_v, q_rdy, cred_ret;
  p2_tsp_rdesc_t q_d;
  p2_pxq u_pxq (.clk, .rst, .i_v(rd_v), .i_rdy(rd_rdy), .i_d(rd_d), .o_v(q_v), .o_rdy(q_rdy), .o_d(q_d), .cred_ret,
    .t_runs(t_pxq_runs), .t_pix(t_pxq_pix));

  // ---------------------------------------------------------------------------------------------- the pixel pipe, P0 - P11
  // (M11: the whole pipe, p2_tsp_pp, with the tile buffers and C4; the testbench reads P3's points: o_take is a point
  // leaving P3, its back-pressure the pipe's external stall, so that every point leaves P3 as in M10)
  p2_pp_ctl_t                         p3_ctl;
  p2_pval_t [P2_TSP_NPL-1:0]          p3_val;
  p2_quot_t [P2_TSP_NPL-1:0]          p3_q;
  logic                               p3_v, ext_stall;
  logic                               m4_v, m4_rrdy;
  logic [23:0]                        m4_addr;
  logic                               tb_rd_en, tb_rd_b2, tb_wr_en, tb_wr_b2;
  logic [P2_PIX_BITS-1:0]             tb_rd_idx, tb_wr_idx;
  logic [31:0]                        tb_rd_b1_data, tb_rd_b2_data, tb_wr_data;
  assign ext_stall = p3_v && !o_rdy;
  p2_tsp_pp u_pp (
    .clk, .rst, .flush,
    .text_control('0), .pal_ram_ctrl('0), .half_tex(1'b0), .fog_col_ram('0), .fog_col_vert('0), .fog_density('0),
    .fog_clamp_max('0), .fog_clamp_min('0), .pt_alpha_ref('0),
    .pal_we(1'b0), .pal_widx('0), .pal_wdata('0), .ft_we(1'b0), .ft_idx('0), .ft_wdata('0),
    .ok_we(1'b0), .ok_wdata('0), .offs_kept(),
    .q_v, .q_rdy, .q_d, .cred_ret,
    .m_v(m4_v), .m_rdy(c_rdy[P2_C_TEX]), .m_addr(m4_addr), .m_rv(c_rv[P2_C_TEX]), .m_rrdy(m4_rrdy),
    .m_rdata(c_rdata[P2_C_TEX]),
    .tb_rd_en, .tb_rd_idx, .tb_rd_b2, .tb_rd_b1_data, .tb_rd_b2_data, .tb_wr_en, .tb_wr_b2, .tb_wr_idx, .tb_wr_data,
    .fb_v(), .fb_rdy(1'b1), .fb(),
    .rel_v, .rel_need, .rel_idx, .ext_stall, .stall(),
    .p3_v, .p3_take(o_take), .p3_ctl, .p3_val, .p3_q, .p3_base(o_base), .p3_offs(o_offs), .p3_level(o_level), .p3_k(o_k),
    .p3_rl(o_rl), .p3_rk(o_rk),
    .t_p7(), .t_p7_ctl(), .t_p10(), .t_p10_ctl(), .t_stuck(), .t_at(), .t_drain, .t_p0, .t_tex_stall(), .t_fill(),
    .t_miss(), .t_fb_block());
  p2_tbuf u_tbuf (.clk, .rst, .swap(1'b0), .sel(),
    .rd_en(tb_rd_en), .rd_idx(tb_rd_idx), .rd_b2(tb_rd_b2), .rd_b1_data(tb_rd_b1_data), .rd_b2_data(tb_rd_b2_data),
    .wr_en(tb_wr_en), .wr_b2(tb_wr_b2), .wr_idx(tb_wr_idx), .wr_data(tb_wr_data),
    .wo_re(1'b0), .wo_idx('0), .wo_gnt(), .wo_data(),
    .dbg_we(1'b0), .dbg_b2(1'b0), .dbg_idx('0), .dbg_wdata('0), .dbg_b1(), .dbg_b2_data());

  assign o_v     = p3_v;
  assign o_null  = p3_ctl.null_;
  assign o_eop   = p3_ctl.eop;
  assign o_eoe   = p3_ctl.eoe;
  assign o_last  = p3_ctl.last;
  assign o_tag   = p3_ctl.tag;
  assign o_rm    = p3_ctl.rm;
  assign o_tilex = p3_ctl.tilex;
  assign o_tiley = p3_ctl.tiley;
  assign o_x     = p3_ctl.x;
  assign o_y     = p3_ctl.y;
  assign o_n     = p3_ctl.n;
  assign o_vsel  = p3_ctl.vsel;
  assign o_ro    = p3_ctl.ro;
  assign o_atest = p3_ctl.atest;
  assign o_super = p3_ctl.super_;
  assign o_hx    = p3_ctl.hx;
  assign o_hy    = p3_ctl.hy;
  assign o_cls   = p3_ctl.hdr.cls;
  assign o_isp   = p3_ctl.hdr.isp;
  assign o_tsp   = p3_ctl.hdr.tsp;
  assign o_tcw   = p3_ctl.hdr.tcw;
  always_comb
    for (int p = 0; p < P2_TSP_NPL; p++) begin
      o_vneg[p]  = p3_val[p].neg;
      o_vexp[p]  = p3_val[p].exp;
      o_vmant[p] = p3_val[p].mant;
      o_qneg[p]  = p3_q[p].neg;
      o_qexp[p]  = p3_q[p].exp;
      o_qmant[p] = p3_q[p].mant;
    end
endmodule

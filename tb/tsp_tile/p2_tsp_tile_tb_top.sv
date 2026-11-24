// p2_tsp_tile_tb_top: make tsp-tile (tb/tsp_tile/tsp_tile_tb.cpp, PLAN M11, 1.3 "TSP tile testbench"). The TSP side of the
// core from the sorter's items to the tile buffers, wired as ARCHITECTURE 1.1 / 3.7 draws it: the store, fetch (C3),
// setup and ALU (M9), run start and the pixel queue (M10), the pixel pipe P0 - P11 (p2_tsp_pp: M10's P0 - P3, M11's
// texture on C4, shade, fog, SupSample, blend and feedback) and the tile buffers (p2_tbuf), p2_mem with the VRAM model.
// M12: the tile buffers' controller (p2_tbuf_ctl: the actions on eoe, the buffer-2 interlock) and the write-out (p2_wout,
// C5) are in, as in p2_core: the entries' records go into p2_entq with their eoe items (as p2_isp_cut pushes them) and the
// controller pops each as its eoe point leaves P10; the testbench no longer swaps the buffers (the tap t_swap says when the
// controller does). The testbench loads / reads the buffers through p2_tbuf's debug port. It feeds the runs of every
// SHADE pass of every entry, the entries' tiles (er_*, run start's) and records, the registers (PALETTE_RAM and FOG_TABLE
// through their write ports), takes the punch-through feedback with random back-pressure, may hold the pipe
// (`ext_stall`), and checks every tile-buffer write (the tap `wr_*`), every feedback message, offsKept after each pass
// (as the pass's eop point leaves P7), the stuck alpha (as it leaves P10) and every write-out read of buffer 2 (wo_*).
module p2_tsp_tile_tb_top
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
  input  logic [31:0]                       half_offset,
  input  logic [31:0]                       text_control,
  input  logic [31:0]                       pal_ram_ctrl,
  input  logic [31:0]                       fog_col_ram,
  input  logic [31:0]                       fog_col_vert,
  input  logic [31:0]                       fog_density,
  input  logic [31:0]                       fog_clamp_max,
  input  logic [31:0]                       fog_clamp_min,
  input  logic [31:0]                       pt_alpha_ref,
  input  logic [31:0]                       fb_w_ctrl,
  input  logic [31:0]                       fb_w_linestride,
  input  logic [31:0]                       fb_w_sof1,
  input  logic [31:0]                       fb_w_sof2,
  input  logic [31:0]                       fb_x_clip,
  input  logic [31:0]                       fb_y_clip,
  input  logic [31:0]                       fb_r_ctrl,
  input  logic [31:0]                       scaler_ctl,
  input  logic [31:0]                       y_coeff,
  input  logic                              pal_we,
  input  logic [9:0]                        pal_widx,
  input  logic [31:0]                       pal_wdata,
  input  logic                              ft_we,
  input  logic [6:0]                        ft_idx,
  input  logic [15:0]                       ft_wdata,
  input  logic                              ok_we,
  input  logic [31:0]                       ok_wdata,
  output logic [31:0]                       offs_kept,
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
  // the item's entry record (p2_entq's push with the eoe item)
  input  logic [5:0]                        in_rec_tilex,
  input  logic [5:0]                        in_rec_tiley,
  input  logic                              in_rec_z_keep,
  input  logic                              in_rec_no_writeout,
  input  logic                              in_rec_last,
  input  logic                              in_rec_shaded_any,
  // ---- the entries' records
  input  logic                              er_v,
  output logic                              er_rdy,
  input  logic [5:0]                        er_tilex,
  input  logic [5:0]                        er_tiley,
  // ---- the feedback to the ISP
  output logic                              fb_v,
  input  logic                              fb_rdy,
  output logic                              fb_kind,
  output logic [9:0]                        fb_idx,
  output logic                              fb_fail,
  output logic                              fb_ro,
  input  logic                              ext_stall,
  // ---- the tile buffers: the write tap, the controller's swap, the debug port, the write-out's read
  output logic                              wr_en,
  output logic                              wr_b2,
  output logic [9:0]                        wr_idx,
  output logic [31:0]                       wr_data,
  output logic                              t_swap,
  output logic                              sel,
  output logic                              t_idle,         // the controller has nothing pending, the write-out is idle
  output logic                              ev_tsp,
  input  logic                              dbg_we,
  input  logic                              dbg_b2,
  input  logic [9:0]                        dbg_idx,
  input  logic [31:0]                       dbg_wdata,
  output logic [31:0]                       dbg_b1,
  output logic [31:0]                       dbg_b2_data,
  output logic                              wo_re,
  output logic [9:0]                        wo_idx,
  output logic                              wo_gnt,
  output logic [31:0]                       wo_data,
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
  // ---- taps
  output logic                              t_p7,           // a point leaves P7: its flags, offs_kept after it
  output logic                              t_p7_eop,
  output logic                              t_p7_null,
  output logic                              t_p10,          // a point leaves P10
  output logic                              t_p10_eop,
  output logic                              t_p10_eoe,
  output logic                              t_p10_null,
  output logic                              t_p10_last,
  output logic [2:0]                        t_p10_rm,
  output logic [9:0]                        t_p10_idx,
  output logic                              t_p10_ro,
  output logic                              t_stuck,
  output logic                              t_at,
  output logic                              t_stall,
  output logic                              t_tex_stall,
  output logic                              t_fill,
  output logic                              t_miss,
  output logic                              t_fb_block,
  output logic                              t_drain,
  output logic                              t_p0,
  output logic                              t_rs_busy,
  output logic                              t_setup_idle,
  output logic                              t_fetch_idle,
  output logic [5:0]                        t_pxq_runs,
  output logic [4:0]                        t_pinned,
  output logic [5:0]                        t_srq
);
  p2_rs_t in_item;
  logic   st_in_rdy, eqi_rdy;
  assign in_rdy = st_in_rdy && (!in_eoe || eqi_rdy);
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
    .in_v(in_v && (!in_eoe || eqi_rdy)), .in_rdy(st_in_rdy), .in_item, .in_nd,
    .out_v(hd_v), .out_rdy(hd_rdy), .out_item(hd_item), .out_nd(hd_nd), .out_need(hd_need), .out_idx(hd_idx),
    .rel_v, .rel_need, .rel_idx,
    .jb_v, .jb_rdy, .jb,
    .sh_v, .sh_idx, .sh_w, .sp_v, .sp_idx, .sp_plane, .sp_w, .sk_v, .sk_idx, .sk_w, .done, .done_idx,
    .rd_v(1'b0), .rd_idx('0), .rd_word('0), .rd_hdr(), .rd_k(), .rd_plane(),
    .rw_v, .rw_idx, .rw_row, .rw_hdr, .rw_k, .rw_plane,
    .t_srq, .t_pinned, .t_la_wait(), .t_job(), .t_hit());

  // ---------------------------------------------------------------------------------------------- fetch (C3), setup, ALU
  localparam int NC = 6;
  logic [NC-1:0]        c_v, c_rdy, c_we, c_w64, c_rv, c_rrdy;
  logic [NC-1:0][23:0]  c_addr;
  logic [NC-1:0][7:0]   c_be;
  logic [NC-1:0][63:0]  c_wdata, c_rdata;
  logic                 m3_v, m3_rrdy, m5_v;
  logic [23:0]          m3_addr, m5_addr;
  logic [3:0]           m5_be;
  logic [31:0]          m5_wdata;
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
    c_v[P2_C_WOUT]          = m5_v;
    c_addr[P2_C_WOUT]       = m5_addr;
    c_we    = '0;
    c_we[P2_C_WOUT] = 1'b1;
    c_w64   = '0;
    c_w64[P2_C_TEX] = 1'b1;
    c_be    = '1;
    c_be[P2_C_WOUT] = {4'd0, m5_be};
    c_wdata = '0;
    c_wdata[P2_C_WOUT] = {32'd0, m5_wdata};
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
    .clk, .rst, .flush, .half(half_offset[1]),
    .er_v, .er_rdy, .er_tilex, .er_tiley,
    .in_v(hd_v), .in_rdy(hd_rdy), .in_item(hd_item), .in_need(hd_need), .in_idx(hd_idx),
    .rw_v, .rw_idx, .rw_row, .rw_hdr, .rw_k, .rw_plane,
    .hold, .rs_a, .rs_b, .rs_p,
    .o_v(rd_v), .o_rdy(rd_rdy), .o_d(rd_d),
    .t_busy(t_rs_busy), .t_reload(), .t_mul());
  logic          q_v, q_rdy, cred_ret;
  p2_tsp_rdesc_t q_d;
  p2_pxq u_pxq (.clk, .rst, .i_v(rd_v), .i_rdy(rd_rdy), .i_d(rd_d), .o_v(q_v), .o_rdy(q_rdy), .o_d(q_d), .cred_ret,
    .t_runs(t_pxq_runs), .t_pix());

  // ---------------------------------------------------------------------------------------------- the pixel pipe, P0 - P11
  logic                               m4_v, m4_rrdy;
  logic [23:0]                        m4_addr;
  logic                               tb_rd_en, tb_rd_b2;
  logic [P2_PIX_BITS-1:0]             tb_rd_idx;
  logic [31:0]                        tb_rd_b1_data, tb_rd_b2_data;
  p2_fb_t                             fbm;
  p2_pp_ctl_t                         p7c, p10c;
  p2_tsp_pp u_pp (
    .clk, .rst, .flush,
    .text_control, .pal_ram_ctrl(pal_ram_ctrl[1:0]), .half_tex(half_offset[2]), .fog_col_ram, .fog_col_vert,
    .fog_density(fog_density[15:0]), .fog_clamp_max, .fog_clamp_min, .pt_alpha_ref,
    .pal_we, .pal_widx, .pal_wdata, .ft_we, .ft_idx, .ft_wdata, .ok_we, .ok_wdata, .offs_kept,
    .q_v, .q_rdy, .q_d, .cred_ret,
    .m_v(m4_v), .m_rdy(c_rdy[P2_C_TEX]), .m_addr(m4_addr), .m_rv(c_rv[P2_C_TEX]), .m_rrdy(m4_rrdy),
    .m_rdata(c_rdata[P2_C_TEX]),
    .tb_rd_en, .tb_rd_idx, .tb_rd_b2, .tb_rd_b1_data, .tb_rd_b2_data, .tb_wr_en(wr_en), .tb_wr_b2(wr_b2),
    .tb_wr_idx(wr_idx), .tb_wr_data(wr_data),
    .fb_v, .fb_rdy, .fb(fbm),
    .rel_v, .rel_need, .rel_idx, .ext_stall, .tb_hold, .wo_busy, .stall(t_stall),
    .p3_v(), .p3_take(), .p3_ctl(), .p3_val(), .p3_q(), .p3_base(), .p3_offs(), .p3_level(), .p3_k(), .p3_rl(), .p3_rk(),
    .t_p7, .t_p7_ctl(p7c), .t_p10, .t_p10_ctl(p10c), .t_stuck, .t_at, .t_drain, .t_p0, .t_tex_stall, .t_fill,
    .t_miss, .t_fb_block);
  // the controller, the write-out (as in p2_core)
  logic       tb_hold, wo_busy, wo_start, wo_eof, wo_rd_done, eqo_v, eqo_rdy, ctl_idle;
  logic [5:0] wo_tx, wo_ty;
  p2_entrec_t eqi_d, eqo_d;
  always_comb begin
    eqi_d             = '0;
    eqi_d.tilex       = in_rec_tilex;
    eqi_d.tiley       = in_rec_tiley;
    eqi_d.z_keep      = in_rec_z_keep;
    eqi_d.no_writeout = in_rec_no_writeout;
    eqi_d.last        = in_rec_last;
    eqi_d.shaded_any  = in_rec_shaded_any;
  end
  p2_isp_entq u_entq (.clk, .rst, .in_v(in_v && in_eoe && st_in_rdy), .in_rdy(eqi_rdy), .in_d(eqi_d), .out_v(eqo_v),
    .out_rdy(eqo_rdy), .out_d(eqo_d));
  p2_tbuf_ctl u_tctl (.clk, .rst, .flush, .p10_eoe(t_p10 && p10c.eoe), .eq_v(eqo_v), .eq_rdy(eqo_rdy), .eq(eqo_d),
    .swap(t_swap), .hold(tb_hold), .wo_start, .wo_tx, .wo_ty, .wo_eof, .wo_busy, .wo_rd_done, .ev_tsp, .ev_vid(),
    .idle(ctl_idle));
  p2_wout u_wout (.clk, .rst, .flush, .fb_w_ctrl, .fb_w_linestride, .fb_w_sof1, .fb_w_sof2, .fb_x_clip, .fb_y_clip,
    .fb_r_ctrl, .scaler_ctl, .y_coeff, .start(wo_start), .tx(wo_tx), .ty(wo_ty), .eof(wo_eof), .busy(wo_busy),
    .rd_done(wo_rd_done), .rd_re(wo_re), .rd_idx(wo_idx), .rd_gnt(wo_gnt), .rd_data(wo_data),
    .m_v(m5_v), .m_rdy(c_rdy[P2_C_WOUT]), .m_addr(m5_addr), .m_be(m5_be), .m_wdata(m5_wdata));
  assign t_idle = ctl_idle && !wo_busy;
  p2_tbuf u_tbuf (.clk, .rst, .swap(t_swap), .sel,
    .rd_en(tb_rd_en), .rd_idx(tb_rd_idx), .rd_b2(tb_rd_b2), .rd_b1_data(tb_rd_b1_data), .rd_b2_data(tb_rd_b2_data),
    .wr_en, .wr_b2, .wr_idx, .wr_data,
    .wo_re, .wo_idx, .wo_gnt, .wo_data,
    .dbg_we, .dbg_b2, .dbg_idx, .dbg_wdata, .dbg_b1, .dbg_b2_data);
  assign fb_kind    = fbm.kind;
  assign fb_idx     = fbm.idx;
  assign fb_fail    = fbm.fail;
  assign fb_ro      = fbm.ro;
  assign t_p7_eop   = p7c.eop;
  assign t_p7_null  = p7c.null_;
  assign t_p10_eop  = p10c.eop;
  assign t_p10_eoe  = p10c.eoe;
  assign t_p10_null = p10c.null_;
  assign t_p10_last = p10c.last;
  assign t_p10_rm   = p10c.rm;
  assign t_p10_idx  = {p10c.y, p10c.x};
  assign t_p10_ro   = p10c.ro;
endmodule

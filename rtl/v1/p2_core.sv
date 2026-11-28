// p2_core: the CORE, region array to framebuffer, on one register port and two VRAM half ports (PLAN M12; ARCHITECTURE
// 1.1, 1.2, 1.3). The units as ARCHITECTURE 1.1 draws them:
//
//   reg port ─► p2_regs ─ live registers, PALETTE_RAM / FOG_TABLE writes, start ─► every unit
//   p2_seq (C0) ─► ISP: p2_isp_ctl ─► p2_isp_olw (C1) ─► p2_isp_pfetch (C2) ─► p2_isp_setup ─► p2_isp_ptc ─┐
//                       │                         p2_isp_pcache (fill / replay) ───────────── mux ◄──┘
//                       │                                                                    ▼
//                       └─ p2_isp_buf ◄─ p2_isp_pix ◄─ p2_isp_raster;  p2_isp_cut ─► run stream ─► p2_runq ─► p2_sort ─┐
//                          p2_isp_fb ◄─ feedback ◄──────────────────────────────────────────────────────────────┐      │
//   TSP: p2_tsp_store (SRQ, look-ahead) ◄───────────────────────────────────────────────────────────────────────┼──────┘
//        p2_tsp_pfetch (C3) ─► p2_tsp_setup / p2_tsp_alu ─► store;  p2_tsp_rstart ─► p2_pxq ─► p2_tsp_pp (P0 - P11, C4)
//        ─► p2_tbuf (the two tile buffers) ◄─ p2_tbuf_ctl (actions on eoe) ─► p2_wout (C5)
//   p2_mem: the clients C0 .. C5 onto the two VRAM halves
//
// The entry records: p2_isp_cut pushes an entry's record into p2_entq with its eoe item; p2_tbuf_ctl pops it when that
// item leaves P10. Run start needs the entry's tile before its first item (p2_tsp_rstart's er_*), long before the eoe
// item is cut (an entry may have more runs than the run queue holds), so the tile goes by a second queue of ENT_N records
// (`tileq`, p2_isp_entq), pushed when the cutter accepts the entry's first command (ctl issues an entry's commands in
// order, its last one SHADE with `last` or END); a full tileq holds that command.
//
// A render: STARTRENDER's `start` restarts p2_seq at REGION_BASE and empties the per-render state (`flush`: the TSP store,
// run start, the texture cache, the tile buffers' controller, the write-out's stream and strip number). Nothing else is
// reset by a render: the ISP's buffers, the tile buffers, which is buffer 1 and offsKept carry over (ARCHITECTURE 1.4).
// ev_isp: the run queue accepted the last entry's eoe item; ev_tsp, ev_vid: p2_tbuf_ctl. soft_rst (SOFTRESET bit 1) is
// decoded by p2_regs; which state it clears is GAP (F11; ARCHITECTURE 1.3 item 5): M12 wires it to nothing (p2-offline,
// like refsw3-offline, never sends it to the core).
module p2_core
  import p2_pkg::*;
  import p2_regs_pkg::*;
  import p2_tsp_pkg::*;
  import p2_tsp_prog_pkg::*;
#(
  parameter int P2_HS = 0
) (
  input  logic                                         clk,
  input  logic                                         rst,           // power-on, synchronous, active high

  // register port: a write takes effect at the next edge; a read returns its data one clock later
  input  logic                                         reg_wr,
  input  logic                                         reg_rd,
  input  logic [12:2]                                  reg_addr,      // word index in the 8 KB block (0x000-0x1FFC)
  input  logic [31:0]                                  reg_wdata,
  output logic [31:0]                                  reg_rdata,

  // VRAM halves h = 0, 1: valid/ready per request; read responses in request order per half, any latency
  output logic [P2_VRAM_HALVES-1:0]                        vh_req_v,
  input  logic [P2_VRAM_HALVES-1:0]                        vh_req_rdy,
  output logic [P2_VRAM_HALVES-1:0]                        vh_req_we,
  output logic [P2_VRAM_HALVES-1:0][P2_VRAM_IDX_BITS-1:0]  vh_req_idx,    // 32-bit word index within the half
  output logic [P2_VRAM_HALVES-1:0][3:0]                   vh_req_be,
  output logic [P2_VRAM_HALVES-1:0][31:0]                  vh_req_wdata,
  output logic [P2_VRAM_HALVES-1:0][P2_VRAM_SRC_BITS-1:0]  vh_req_src,    // client id (P2_C_*)
  input  logic [P2_VRAM_HALVES-1:0]                        vh_rsp_v,
  input  logic [P2_VRAM_HALVES-1:0][31:0]                  vh_rsp_data,
  input  logic [P2_VRAM_HALVES-1:0][P2_VRAM_SRC_BITS-1:0]  vh_rsp_src,

  // end-of-render events, 1-clock pulses: SB_ISTNRM bits 1 (ISP), 2 (TSP), 0 (video); SB_ISTERR bit 0
  output logic                                         ev_isp,
  output logic                                         ev_tsp,
  output logic                                         ev_vid,
  output logic                                         ev_isp_ovf     // tied 0 unless P2_ISTERR = 1 (PLAN D11)
);

  // the elaboration checks on p2_hw_pkg's MODE switches and the shared formats' widths
  p2_hw_check u_hw_check ();

  // ---------------------------------------------------------------------------------------------- p2_regs
  logic        start, soft_rst, pal_we, ft_we;
  logic [9:0]  pal_widx;
  logic [31:0] pal_wdata;
  logic [6:0]  ft_idx;
  logic [15:0] ft_wdata;
  logic [31:0] param_base, region_base, span_sort_cfg, fb_r_ctrl, fb_w_ctrl, fb_w_linestride, fb_w_sof1, fb_w_sof2,
               fb_x_clip, fb_y_clip, fpu_shad_scale, fpu_cull_val, fpu_param_cfg, half_offset, fpu_perp_val,
               isp_backgnd_d, isp_backgnd_t, isp_feed_cfg, fog_col_ram, fog_col_vert, fog_density, fog_clamp_max,
               fog_clamp_min, text_control, scaler_ctl, pal_ram_ctrl, y_coeff, pt_alpha_ref;
  p2_regs u_regs (.clk, .rst, .reg_wr, .reg_rd, .reg_addr, .reg_wdata, .reg_rdata, .start, .soft_rst,
    .pal_we, .pal_widx, .pal_wdata, .ft_we, .ft_idx, .ft_wdata,
    .param_base, .region_base, .span_sort_cfg, .fb_r_ctrl, .fb_w_ctrl, .fb_w_linestride, .fb_w_sof1, .fb_w_sof2,
    .fb_x_clip, .fb_y_clip, .fpu_shad_scale, .fpu_cull_val, .fpu_param_cfg, .half_offset, .fpu_perp_val,
    .isp_backgnd_d, .isp_backgnd_t, .isp_feed_cfg, .fog_col_ram, .fog_col_vert, .fog_density, .fog_clamp_max,
    .fog_clamp_min, .text_control, .scaler_ctl, .pal_ram_ctrl, .y_coeff, .pt_alpha_ref);
  logic flush;
  assign flush = start;

  // ---------------------------------------------------------------------------------------------- p2_mem
  localparam int NC = 6;
  logic [NC-1:0]        c_v, c_rdy, c_we, c_w64, c_rv, c_rrdy;
  logic [NC-1:0][23:0]  c_addr;
  logic [NC-1:0][7:0]   c_be;
  logic [NC-1:0][63:0]  c_wdata, c_rdata;
  logic        m0_v, m0_rrdy, m1_v, m1_rrdy, m2_v, m2_rrdy, m3_v, m3_rrdy, m4_v, m4_rrdy, m5_v;
  logic [23:0] m0_addr, m1_addr, m2_addr, m3_addr, m4_addr, m5_addr;
  logic [3:0]  m5_be;
  logic [31:0] m5_wdata;
  always_comb begin
    c_v     = {m5_v, m4_v, m3_v, m2_v, m1_v, m0_v};
    c_addr  = {m5_addr, m4_addr, m3_addr, m2_addr, m1_addr, m0_addr};
    c_rrdy  = {1'b1, m4_rrdy, m3_rrdy, m2_rrdy, m1_rrdy, m0_rrdy};
    c_we    = '0;
    c_we[P2_C_WOUT]    = 1'b1;
    c_w64   = '0;
    c_w64[P2_C_TEX]    = 1'b1;
    c_be    = '1;
    c_be[P2_C_WOUT]    = {4'd0, m5_be};
    c_wdata = '0;
    c_wdata[P2_C_WOUT] = {32'd0, m5_wdata};
  end
  p2_mem #(.NC(NC)) u_mem (.clk, .rst, .c_v, .c_rdy, .c_we, .c_w64, .c_addr, .c_be, .c_wdata, .c_rv, .c_rrdy, .c_rdata,
    .vh_req_v, .vh_req_rdy, .vh_req_we, .vh_req_idx, .vh_req_be, .vh_req_wdata, .vh_req_src, .vh_rsp_v, .vh_rsp_data,
    .vh_rsp_src);

  // ---------------------------------------------------------------------------------------------- p2_seq (C0)
  logic      ent_v, ent_rdy, seq_busy;
  p2_entry_t ent;
  p2_seq u_seq (.clk, .rst, .start, .region_base, .fpu_param_cfg, .isp_feed_cfg, .ent_v, .ent_rdy, .ent, .busy(seq_busy),
    .m_v(m0_v), .m_rdy(c_rdy[P2_C_SEQ]), .m_addr(m0_addr), .m_rv(c_rv[P2_C_SEQ]), .m_rrdy(m0_rrdy),
    .m_rdata(c_rdata[P2_C_SEQ][31:0]));

  // ---------------------------------------------------------------------------------------------- ISP: ctl
  logic        sw_v, sw_busy;
  p2_sweep_t   sw_op;
  p2_zkey_t    sw_key;
  logic [31:0] sw_tag;
  logic        walk_v, walk_scan, has_prim, front_idle, back_idle, ho_take, ho_block, more, more_clr;
  logic [23:0] walk_addr;
  p2_rm_t      walk_rm;
  logic [5:0]  tilex, tiley;
  logic        pt, pt_en, pt_restart, pt_set_cur, pt_fw_clr, pt_fw, pt_hold, pt_more_chunks;
  logic [15:0] pt_cur, pt_at;
  logic        pc_reset, pc_tr, pc_fill_en, pc_ovf, rp_start, rp_busy, src_rp;
  logic        cmd_v, cmd_rdy, cut_rdy, cmd_end, cmd_opinpt, cmd_last, cut_idle;
  p2_rm_t      cmd_rm;
  p2_entrec_t  cmd_rec;
  logic        pass_done, anyfail, ent_done;
  logic        ctl_busy;               // statistics (the timing tap, +occlog)
  p2_isp_ctl u_ctl (.clk, .rst, .ent_v, .ent_rdy, .ent, .bg_tag(isp_backgnd_t), .bg_depth(isp_backgnd_d),
    .sw_v, .sw_op, .sw_key, .sw_tag, .sw_busy, .walk_v, .walk_addr, .walk_scan, .walk_rm, .tilex, .tiley,
    .has_prim, .front_idle, .back_idle, .ho_take, .ho_block, .more, .more_clr, .pt, .pt_en, .pt_restart, .pt_set_cur,
    .pt_cur, .pt_fw_clr, .pt_fw, .pt_hold, .pt_more_chunks, .pc_reset, .pc_tr, .pc_fill_en, .pc_ovf, .rp_start,
    .rp_busy, .src_rp, .cmd_v, .cmd_rdy, .cmd_end, .cmd_rm, .cmd_opinpt, .cmd_last, .cmd_rec, .cut_idle, .pass_done,
    .anyfail, .halt_en(1'b0), .resume(1'b0), .halted(), .halt_phase(), .busy(ctl_busy), .ent_done, .st_chunks(), .st_passes(),
    .st_trpasses(), .st_ptshades());

  // ---------------------------------------------------------------------------------------------- ISP: front (C1, C2)
  logic        ob_v, ob_rdy, olw_idle;
  p2_isp_obj_t ob;
  p2_isp_olw u_olw (.clk, .rst, .cmd_v(walk_v), .cmd_addr(walk_addr), .cmd_scan(walk_scan), .idle(olw_idle),
    .has_prim, .ob_v, .ob_rdy, .ob, .m_v(m1_v), .m_rdy(c_rdy[P2_C_OLW]), .m_addr(m1_addr), .m_rv(c_rv[P2_C_OLW]),
    .m_rrdy(m1_rrdy), .m_rdata(c_rdata[P2_C_OLW][31:0]));
  logic    asm_v, asm_rdy, pf_idle;
  p2_asm_t asm_o;
  p2_isp_pfetch u_ipfetch (.clk, .rst, .ob_v, .ob_rdy, .ob, .rm(walk_rm), .tilex, .tiley, .param_base,
    .shad_intensity(fpu_shad_scale[8]), .asm_v, .asm_rdy, .asm_o, .idle(pf_idle), .m_v(m2_v),
    .m_rdy(c_rdy[P2_C_ISP_PFETCH]), .m_addr(m2_addr), .m_rv(c_rv[P2_C_ISP_PFETCH]), .m_rrdy(m2_rrdy),
    .m_rdata(c_rdata[P2_C_ISP_PFETCH][31:0]));
  logic      su_v, su_rdy, su_idle, pc_v, pc_culled, pc_quad, pc_desc;
  p2_rdesc_t su_d;
  p2_isp_setup u_isetup (.clk, .rst, .asm_v, .asm_rdy, .asm_i(asm_o), .fpu_cull_val, .fpu_perp_val,
    .half(half_offset[0]), .rd_v(su_v), .rd_rdy(su_rdy), .rd(su_d), .pc_v, .pc_culled, .pc_quad, .pc_desc,
    .idle(su_idle), .t_issue(), .t_cls(), .t_pc(), .t_uw(), .t_wv(), .t_wrd());
  logic o_v, o_rdy;
  p2_isp_ptc u_ptc (.clk, .rst, .chunk_size(isp_feed_cfg[13:4]), .pt, .en(pt_en), .restart(pt_restart),
    .set_cur(pt_set_cur), .cur_in(pt_cur), .fw_set(pt && pc_fill_en && pc_ovf), .fw_clr(pt_fw_clr), .fw(pt_fw),
    .hold(pt_hold), .more_chunks(pt_more_chunks), .chunk_at(pt_at), .pc_v, .pc_culled, .pc_quad, .pc_desc,
    .rd_v(su_v), .rd_rdy(su_rdy), .o_v, .o_rdy);
  logic      rp_v, rp_rdy, ra_rdy, rd_v;
  p2_rdesc_t rp, rd;
  p2_isp_pcache u_pcache (.clk, .rst, .reset(pc_reset), .tr(pc_tr), .tr_size(isp_feed_cfg[23:14]),
    .fill_en(pc_fill_en), .fill_v(ho_take), .fill_d(su_d), .ovf(pc_ovf), .rp_start, .rp_v, .rp_rdy, .rp, .rp_busy);
  assign rd_v    = src_rp ? rp_v : (o_v && !ho_block);
  assign rd      = src_rp ? rp : su_d;
  assign rp_rdy  = src_rp && ra_rdy;
  assign o_rdy   = !src_rp && !ho_block && ra_rdy;
  assign ho_take = o_v && o_rdy;

  // ---------------------------------------------------------------------------------------------- ISP: back
  logic                   row_v, out_rdy, row_last, ra_idle, row_zwdis;
  logic [4:0]             row_j;
  logic [31:0]            in_mask;
  p2_zkey_t [P2_TILE-1:0] zk;
  p2_tag_t                row_tag;
  p2_rm_t                 row_rm;
  logic [2:0]             row_dm;
  p2_sum_op_t             row_sum;
  p2_isp_raster u_raster (.clk, .rst, .rd_v, .rd_rdy(ra_rdy), .rd, .row_v, .out_rdy, .row_j, .in_mask, .zk, .row_last,
    .row_tag, .row_rm, .row_depth_mode(row_dm), .row_zwdis, .row_sum_op(row_sum), .idle(ra_idle));
  logic                     f_re, w_v, w_swe, px_idle;
  logic [4:0]               f_row, n_row, w_row;
  p2_zkey_t [P2_TILE-1:0]   f_depth, f_depth_b, f_depth_c, w_depth, c_depth, cs_data;
  logic [P2_TILE-1:0][31:0] f_tag, f_tag_b, f_reftag_c, w_tag, c_tag;
  logic [P2_TILE-1:0][2:0]  n_stencil, w_stencil;
  logic [P2_TILE-1:0]       n_valid, n_rendered, n_rlp, w_dwe, w_twe, w_vwe, w_valid, bar_ok;
  p2_isp_pix u_pix (.clk, .rst, .row_v, .out_rdy, .row_j, .in_mask, .zk, .row_tag, .row_rm, .row_depth_mode(row_dm),
    .row_zwdis, .row_sum_op(row_sum), .bar_ok, .more_clr, .more, .f_re, .f_row, .f_depth, .f_tag, .f_depth_b, .f_tag_b,
    .f_depth_c, .f_reftag_c, .n_row, .n_stencil, .n_valid, .n_rendered, .n_rlp, .w_v, .w_row, .w_dwe, .w_twe, .w_depth,
    .w_tag, .w_swe, .w_stencil, .w_vwe, .w_valid, .idle(px_idle));

  logic                            c_re, cv_we, cs_we, rs_v, rs_rdy, eqi_v, eqi_rdy, cut_ev;
  logic [4:0]                      c_row, cv_row, cs_row;
  logic [P2_TILE-1:0]              cv_lane, cs_lane;
  logic [P2_TILE-1:0][P2_TILE-1:0] k_valid, k_st0, k_rendered;
  p2_rs_t                          rs;
  p2_entrec_t                      eqi;
  // the tile queue: an entry's tile when the cutter takes its first command
  logic       tq_first, tq_in_v, tq_in_rdy, tq_v, tq_rdy;
  p2_entrec_t tq_d;
  assign tq_in_v = cmd_v && cut_rdy && tq_first;
  assign cmd_rdy = cut_rdy && (!tq_first || tq_in_rdy);
  always_ff @(posedge clk)
    if (rst) tq_first <= 1'b1;
    else if (cmd_v && cmd_rdy) tq_first <= cmd_end || cmd_last;
  p2_isp_cut u_cut (.clk, .rst, .cmd_v(cmd_v && (!tq_first || tq_in_rdy)), .cmd_rdy(cut_rdy), .cmd_end, .cmd_rm,
    .cmd_opinpt, .cmd_last, .cmd_rec, .idle(cut_idle), .c_re, .c_row, .c_depth, .c_tag, .k_valid, .k_st0, .k_rendered,
    .cv_we, .cv_row, .cv_lane, .cs_we, .cs_row, .cs_lane, .cs_data, .bar_ok, .rs_v, .rs_rdy, .rs, .eq_v(eqi_v),
    .eq_rdy(eqi_rdy), .eq(eqi), .ev_isp(cut_ev));
  assign ev_isp = cut_ev && eqi.last;
  p2_isp_entq u_tileq (.clk, .rst, .in_v(tq_in_v), .in_rdy(tq_in_rdy), .in_d(cmd_rec), .out_v(tq_v), .out_rdy(tq_rdy),
    .out_d(tq_d));

  logic                    fb_re, fbw_v, fbw_pass, fb_idle, fbk_v, fbk_rdy;
  logic [4:0]              fb_row, fbw_row;
  logic [P2_TILE-1:0]      fbw_lane;
  p2_zkey_t                fbw_depth;
  logic [31:0]             fbw_tag;
  p2_fb_t                  fbm;
  p2_isp_fb u_fb (.clk, .rst, .fb_v(fbk_v), .fb_rdy(fbk_rdy), .fb(fbm), .fb_re, .fb_row, .f_depth, .f_tag, .fbw_v,
    .fbw_row, .fbw_lane, .fbw_pass, .fbw_depth, .fbw_tag, .pass_done, .anyfail, .idle(fb_idle));

  p2_isp_buf u_buf (.clk, .rst, .f_re, .f_row, .f_depth, .f_tag, .f_depth_b, .f_tag_b, .f_depth_c, .f_reftag_c, .n_row,
    .n_stencil, .n_valid, .n_rendered, .n_rlp, .c_re, .c_row, .c_depth, .c_tag, .k_valid, .k_st0, .k_rendered, .w_v,
    .w_row, .w_dwe, .w_twe, .w_depth, .w_tag, .w_swe, .w_stencil, .w_vwe, .w_valid, .cv_we, .cv_row, .cv_lane, .cs_we,
    .cs_row, .cs_lane, .cs_data, .fb_re, .fb_row, .fbw_v, .fbw_row, .fbw_lane, .fbw_pass, .fbw_depth, .fbw_tag, .sw_v,
    .sw_op, .sw_key, .sw_tag, .sw_busy, .bar_ok, .dbg_row('0), .dbg_depth(), .dbg_tag(), .dbg_depth_b(), .dbg_tag_b(),
    .dbg_depth_c(), .dbg_reftag_c(), .dbg_optag(), .dbg_restag(), .dbg_rsd(), .dbg_stencil(), .dbg_valid(),
    .dbg_rendered(), .dbg_rcur(), .dbg_rlp(), .dbg_ever(), .dbg_we(1'b0), .dbg_wdepth('0), .dbg_wtag('0),
    .dbg_wdepth_b('0), .dbg_wtag_b('0), .dbg_wdepth_c('0), .dbg_wreftag_c('0), .dbg_woptag('0), .dbg_wrestag('0),
    .dbg_wrsd('0), .dbg_wstencil('0), .dbg_wvalid('0), .dbg_wrendered('0), .dbg_wrcur('0), .dbg_wrlp('0),
    .dbg_wever('0));
  assign front_idle = olw_idle && pf_idle && su_idle;
  assign back_idle  = ra_idle && px_idle && fb_idle;

  // ---------------------------------------------------------------------------------------------- the run queue, the sorter
  logic       q_v, q_rdy, so_v, so_rdy, so_nd;
  p2_rs_t     q_d, so_d;
  logic [$clog2(300 + 1)-1:0] runq_occ;   // statistics (the timing tap, +occlog); p2_runq's RUNQ_N 300
  p2_runq u_runq (.clk, .rst, .in_v(rs_v), .in_rdy(rs_rdy), .in_d(rs), .out_v(q_v), .out_rdy(q_rdy), .out_d(q_d),
    .occ(runq_occ));
  p2_sort u_sort (.clk, .rst, .cfg_on(span_sort_cfg[0]), .cfg_offs(span_sort_cfg[8]), .in_v(q_v), .in_rdy(q_rdy),
    .in_d(q_d), .out_v(so_v), .out_rdy(so_rdy), .out_d(so_d), .out_new_drain(so_nd), .t_full(), .t_wait(), .t_end());
  logic       eq_v, eq_rdy;
  p2_entrec_t eq_d;
  p2_isp_entq u_entq (.clk, .rst, .in_v(eqi_v), .in_rdy(eqi_rdy), .in_d(eqi), .out_v(eq_v), .out_rdy(eq_rdy),
    .out_d(eq_d));

  // ---------------------------------------------------------------------------------------------- TSP: store, fetch, setup
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
  p2_tsp_store u_store (.clk, .rst, .flush, .in_v(so_v), .in_rdy(so_rdy), .in_item(so_d), .in_nd(so_nd),
    .out_v(hd_v), .out_rdy(hd_rdy), .out_item(hd_item), .out_nd(hd_nd), .out_need(hd_need), .out_idx(hd_idx),
    .rel_v, .rel_need, .rel_idx, .jb_v, .jb_rdy, .jb,
    .sh_v, .sh_idx, .sh_w, .sp_v, .sp_idx, .sp_plane, .sp_w, .sk_v, .sk_idx, .sk_w, .done, .done_idx,
    .rd_v(1'b0), .rd_idx('0), .rd_word('0), .rd_hdr(), .rd_k(), .rd_plane(),
    .rw_v, .rw_idx, .rw_row, .rw_hdr, .rw_k, .rw_plane,
    .t_srq(), .t_pinned(), .t_la_wait(), .t_job(), .t_hit());
  logic         pr_v, pr_rdy;
  p2_tsp_prim_t pr;
  logic         tpf_idle, tsu_idle, rst_busy;      // statistics (the timing tap, +occlog)
  p2_tsp_pfetch u_tpfetch (.clk, .rst, .jb_v, .jb_rdy, .jb, .param_base, .shad_intensity(fpu_shad_scale[8]),
    .pr_v, .pr_rdy, .pr, .idle(tpf_idle), .m_v(m3_v), .m_rdy(c_rdy[P2_C_TSP_PFETCH]), .m_addr(m3_addr),
    .m_rv(c_rv[P2_C_TSP_PFETCH]), .m_rrdy(m3_rrdy), .m_rdata(c_rdata[P2_C_TSP_PFETCH][31:0]));
  logic                        hold;
  p2_fp16_t [P2_TSP_NM-1:0]    rs_a;
  logic [P2_TSP_NM-1:0][12:0]  rs_b;
  p2_tsp_rsp_t [P2_TSP_NM-1:0] rs_p;
  p2_tsp_setup u_tsetup (.clk, .rst, .pr_v, .pr_rdy, .pr, .fpu_shad_scale, .fpu_perp_val, .hold, .rs_a, .rs_b, .rs_p,
    .sh_v, .sh_idx, .sh_w, .sp_v, .sp_idx, .sp_plane, .sp_w, .sk_v, .sk_idx, .sk_w, .done, .done_idx,
    .idle(tsu_idle), .t_issue(), .t_cls(), .t_pc(), .t_uw(), .t_wv(), .t_wrd());

  // ---------------------------------------------------------------------------------------------- TSP: run start, queue, pipe
  logic          rd2_v, rd2_rdy;
  p2_tsp_rdesc_t rd2_d;
  p2_tsp_rstart u_rstart (.clk, .rst, .flush, .half(half_offset[1]), .er_v(tq_v), .er_rdy(tq_rdy),
    .er_tilex(tq_d.tilex), .er_tiley(tq_d.tiley), .in_v(hd_v), .in_rdy(hd_rdy), .in_item(hd_item), .in_need(hd_need),
    .in_idx(hd_idx), .rw_v, .rw_idx, .rw_row, .rw_hdr, .rw_k, .rw_plane, .hold, .rs_a, .rs_b, .rs_p,
    .o_v(rd2_v), .o_rdy(rd2_rdy), .o_d(rd2_d), .t_busy(rst_busy), .t_reload(), .t_mul());
  logic          pq_v, pq_rdy, cred_ret;
  p2_tsp_rdesc_t pq_d;
  logic [5:0]    pxq_runs;             // statistics (the timing tap, +occlog)
  logic [8:0]    pxq_pix;
  p2_pxq u_pxq (.clk, .rst, .i_v(rd2_v), .i_rdy(rd2_rdy), .i_d(rd2_d), .o_v(pq_v), .o_rdy(pq_rdy), .o_d(pq_d), .cred_ret,
    .t_runs(pxq_runs), .t_pix(pxq_pix));

  logic                   tb_rd_en, tb_rd_b2, tb_wr_en, tb_wr_b2, tb_hold, tb_swap, wo_busy, t_p10;
  logic [P2_PIX_BITS-1:0] tb_rd_idx, tb_wr_idx;
  logic [31:0]            tb_rd_b1_data, tb_rd_b2_data, tb_wr_data;
  p2_pp_ctl_t             p10c;
  logic                   pp_stall, pp_tstall, pp_fill, pp_miss;   // statistics (the timing tap, +occlog)
  p2_tsp_pp u_pp (.clk, .rst, .flush, .text_control, .pal_ram_ctrl(pal_ram_ctrl[1:0]), .half_tex(half_offset[2]),
    .fog_col_ram, .fog_col_vert, .fog_density(fog_density[15:0]), .fog_clamp_max, .fog_clamp_min, .pt_alpha_ref,
    .pal_we, .pal_widx, .pal_wdata, .ft_we, .ft_idx, .ft_wdata, .ok_we(1'b0), .ok_wdata('0), .offs_kept(),
    .q_v(pq_v), .q_rdy(pq_rdy), .q_d(pq_d), .cred_ret,
    .m_v(m4_v), .m_rdy(c_rdy[P2_C_TEX]), .m_addr(m4_addr), .m_rv(c_rv[P2_C_TEX]), .m_rrdy(m4_rrdy),
    .m_rdata(c_rdata[P2_C_TEX]),
    .tb_rd_en, .tb_rd_idx, .tb_rd_b2, .tb_rd_b1_data, .tb_rd_b2_data, .tb_wr_en, .tb_wr_b2, .tb_wr_idx, .tb_wr_data,
    .fb_v(fbk_v), .fb_rdy(fbk_rdy), .fb(fbm), .rel_v, .rel_need, .rel_idx, .ext_stall(1'b0), .tb_hold, .wo_busy,
    .stall(pp_stall),
    .p3_v(), .p3_take(), .p3_ctl(), .p3_val(), .p3_q(), .p3_base(), .p3_offs(), .p3_level(), .p3_k(), .p3_rl(),
    .p3_rk(), .t_p7(), .t_p7_ctl(), .t_p10, .t_p10_ctl(p10c), .t_stuck(), .t_at(), .t_drain(), .t_p0(),
    .t_tex_stall(pp_tstall), .t_fill(pp_fill), .t_miss(pp_miss), .t_fb_block());

  // ---------------------------------------------------------------------------------------------- the tile buffers, write-out
  logic        wo_re, wo_gnt, wo_start, wo_eof, wo_rd_done;
  logic [9:0]  wo_idx;
  logic [31:0] wo_data;
  logic [5:0]  wo_tx, wo_ty;
  logic        tctl_idle;              // statistics (the timing tap, +occlog)
  p2_tbuf u_tbuf (.clk, .rst, .swap(tb_swap), .sel(),
    .rd_en(tb_rd_en), .rd_idx(tb_rd_idx), .rd_b2(tb_rd_b2), .rd_b1_data(tb_rd_b1_data), .rd_b2_data(tb_rd_b2_data),
    .wr_en(tb_wr_en), .wr_b2(tb_wr_b2), .wr_idx(tb_wr_idx), .wr_data(tb_wr_data),
    .wo_re, .wo_idx, .wo_gnt, .wo_data,
    .dbg_we(1'b0), .dbg_b2(1'b0), .dbg_idx('0), .dbg_wdata('0), .dbg_b1(), .dbg_b2_data());
  p2_tbuf_ctl #(.P2_HS(P2_HS)) u_tctl (.clk, .rst, .flush, .p10_eoe(t_p10 && p10c.eoe), .eq_v, .eq_rdy, .eq(eq_d),
    .swap(tb_swap), .hold(tb_hold), .wo_start, .wo_tx, .wo_ty, .wo_eof, .wo_busy, .wo_rd_done, .ev_tsp, .ev_vid,
    .idle(tctl_idle));
  p2_wout u_wout (.clk, .rst, .flush, .fb_w_ctrl, .fb_w_linestride, .fb_w_sof1, .fb_w_sof2, .fb_x_clip, .fb_y_clip,
    .fb_r_ctrl, .scaler_ctl, .y_coeff, .start(wo_start), .tx(wo_tx), .ty(wo_ty), .eof(wo_eof), .busy(wo_busy),
    .rd_done(wo_rd_done), .rd_re(wo_re), .rd_idx(wo_idx), .rd_gnt(wo_gnt), .rd_data(wo_data),
    .m_v(m5_v), .m_rdy(c_rdy[P2_C_WOUT]), .m_addr(m5_addr), .m_be(m5_be), .m_wdata(m5_wdata));

  assign ev_isp_ovf = 1'b0;

`ifndef SYNTHESIS
  // ---------------------------------------------------------------------------------------------- the depth tap (sim)
  // PLAN M13, 1.4 / conventions 7.4.3 (fit/zdump_data): with +ztap=<file>, each entry's tile depths as the ISP leaves
  // them (depthA's 64-bit keys, p2_zkey_t) when its ISP work is over (ctl's ent_done: the sweeps, walks and pass
  // feedback of the entry are complete, the next entry's CLEAR not started), a line "ZTAP <tilex> <tiley>" and the 32 x
  // 32 keys row by row. A shadow of p2_isp_buf's depthA write port (every writer goes through it), so that the tap reads
  // nothing of the buffer's ports and changes no clock. tools/gate/ztap_cmp.cpp converts the keys to refsw3's bits
  // (tb/common/zkey.h).
  int         zt_fd = 0;
  string      zt_fn;
  p2_zkey_t   zt_sh [P2_TILE][P2_TILE];
  initial if ($value$plusargs("ztap=%s", zt_fn)) zt_fd = $fopen(zt_fn, "w");
  always_ff @(posedge clk)
    if (zt_fd != 0) begin
      if (u_buf.da_we)
        for (int i = 0; i < P2_TILE; i++)
          if (u_buf.da_ln[i])
            zt_sh[u_buf.da_row][i] <= u_buf.da_wd[i];
      if (ent_done) begin
        $fwrite(zt_fd, "ZTAP %0d %0d\n", tilex, tiley);
        for (int r = 0; r < P2_TILE; r++) begin
          for (int i = 0; i < P2_TILE; i++)
            $fwrite(zt_fd, "%016x%s", zt_sh[r][i], i == P2_TILE - 1 ? "\n" : " ");
        end
        $fflush(zt_fd);
      end
    end

  // ---------------------------------------------------------------------------------------------- the timing tap (sim)
  // PLAN MT0, 1.5 / conventions 7.6: with +p2timing (p2-offline's P2_TIMING=1), one line a render on stderr when ev_isp,
  // ev_tsp and ev_vid have all fired, just before p2-offline's "p2: render" line:
  //   p2: timing isp <c> tsp <c> vid <c> ent <n> obj <n> obj0 <c> prim <n> ho <n> cull <n> rdesc <n> runs <n>
  //              null <n> cut0 <c> cut1 <c> cutbusy <n> qisp <n> qmax <n> sorted <n> jobs <n> setups <n> rstart <n>
  //              pxq <n> px <n> px0 <c> px1 <c> tex <n> miss <n> fill <n> wo <n> wo0 <c> wow <n> wow0 <c> wow1 <c>
  // <c>: a clock counted as p2-offline's isp / tsp / video (the STARTRENDER write is clock 0; `start` is clock 1), -1 when
  // it did not happen; <n>: a count over the render. What each counts (a handshake or a pulse of the signal named):
  //   ent ent_v&&ent_rdy (region array entries), obj ob_v&&ob_rdy (objects out of p2_isp_olw; obj0 the first), prim
  //   asm_v&&asm_rdy (primitives assembled), ho ho_take (set-up primitives to the raster; replays not counted), cull
  //   pc_v&&pc_culled, rdesc rd_v&&ra_rdy (descriptors into the raster, replays counted), runs / null rs_v&&rs_rdy
  //   (run items cut / null eoe items; cut0 / cut1 the first and last run), cutbusy clocks p2_isp_cut not idle, qisp the
  //   run queue's places taken at ev_isp, qmax its most, sorted so_v&&so_rdy, jobs jb_v&&jb_rdy (TSP parameter fetches),
  //   setups `done` (primitives set up), rstart rd2_v&&rd2_rdy (runs started), pxq pq_v&&pq_rdy (runs into the pipe), px
  //   t_p10 (points leaving P10; px0 / px1 the first and the last), tex VRAM texture requests granted, miss / fill the
  //   texture cache's misses / clocks filling, wo wo_start (tiles written out; wo0 the first), wow VRAM write-out words
  //   granted (wow0 / wow1 the first and the last).
  // It reads p2_core's wires only and changes no clock.
  bit     tm_en = 1'b0;
  bit     tm_run = 1'b0;
  longint tm_c, tm_isp, tm_tsp, tm_vid, tm_obj0, tm_cut0, tm_cut1, tm_px0, tm_px1, tm_wo0, tm_wow0, tm_wow1;
  longint tm_ent, tm_obj, tm_prim, tm_ho, tm_cull, tm_rdesc, tm_runs, tm_null, tm_cutbusy, tm_qisp, tm_qmax, tm_sorted,
          tm_jobs, tm_setups, tm_rstart, tm_pxq, tm_px, tm_tex, tm_miss, tm_fill, tm_wo, tm_wow;
  initial tm_en = $test$plusargs("p2timing");
  always @(posedge clk)
    if (tm_en && !rst) begin
      if (start) begin
        tm_run = 1'b1;
        tm_c = 1;
        {tm_isp, tm_tsp, tm_vid, tm_obj0, tm_cut0, tm_cut1, tm_px0, tm_px1, tm_wo0, tm_wow0, tm_wow1} = {11{64'(-1)}};
        {tm_ent, tm_obj, tm_prim, tm_ho, tm_cull, tm_rdesc, tm_runs, tm_null, tm_cutbusy, tm_qisp, tm_qmax, tm_sorted,
         tm_jobs, tm_setups, tm_rstart, tm_pxq, tm_px, tm_tex, tm_miss, tm_fill, tm_wo, tm_wow} = '0;
      end else if (tm_run)
        tm_c = tm_c + 1;
      if (tm_run) begin
        if (ent_v && ent_rdy) tm_ent++;
        if (ob_v && ob_rdy) begin
          if (tm_obj == 0) tm_obj0 = tm_c;
          tm_obj++;
        end
        if (asm_v && asm_rdy) tm_prim++;
        if (ho_take) tm_ho++;
        if (pc_v && pc_culled) tm_cull++;
        if (rd_v && ra_rdy) tm_rdesc++;
        if (rs_v && rs_rdy) begin
          if (rs.null_) tm_null++;
          else begin
            if (tm_runs == 0) tm_cut0 = tm_c;
            tm_cut1 = tm_c;
            tm_runs++;
          end
        end
        if (!cut_idle) tm_cutbusy++;
        if (64'(runq_occ) > tm_qmax) tm_qmax = 64'(runq_occ);
        if (so_v && so_rdy) tm_sorted++;
        if (jb_v && jb_rdy) tm_jobs++;
        if (done) tm_setups++;
        if (rd2_v && rd2_rdy) tm_rstart++;
        if (pq_v && pq_rdy) tm_pxq++;
        if (t_p10) begin
          if (tm_px == 0) tm_px0 = tm_c;
          tm_px1 = tm_c;
          tm_px++;
        end
        if (m4_v && c_rdy[P2_C_TEX]) tm_tex++;
        if (pp_miss) tm_miss++;
        if (pp_fill) tm_fill++;
        if (wo_start) begin
          if (tm_wo == 0) tm_wo0 = tm_c;
          tm_wo++;
        end
        if (m5_v && c_rdy[P2_C_WOUT]) begin
          if (tm_wow == 0) tm_wow0 = tm_c;
          tm_wow1 = tm_c;
          tm_wow++;
        end
        if (ev_isp && tm_isp < 0) begin
          tm_isp  = tm_c;
          tm_qisp = 64'(runq_occ);
        end
        if (ev_tsp && tm_tsp < 0) tm_tsp = tm_c;
        if (ev_vid && tm_vid < 0) tm_vid = tm_c;
        if (tm_isp >= 0 && tm_tsp >= 0 && tm_vid >= 0) begin
          $fwrite(32'h8000_0002, "p2: timing isp %0d tsp %0d vid %0d ent %0d obj %0d obj0 %0d prim %0d ho %0d cull %0d",
                  tm_isp, tm_tsp, tm_vid, tm_ent, tm_obj, tm_obj0, tm_prim, tm_ho, tm_cull);
          $fwrite(32'h8000_0002, " rdesc %0d runs %0d null %0d cut0 %0d cut1 %0d cutbusy %0d qisp %0d qmax %0d sorted %0d",
                  tm_rdesc, tm_runs, tm_null, tm_cut0, tm_cut1, tm_cutbusy, tm_qisp, tm_qmax, tm_sorted);
          $fwrite(32'h8000_0002, " jobs %0d setups %0d rstart %0d pxq %0d px %0d px0 %0d px1 %0d tex %0d miss %0d fill %0d",
                  tm_jobs, tm_setups, tm_rstart, tm_pxq, tm_px, tm_px0, tm_px1, tm_tex, tm_miss, tm_fill);
          $fwrite(32'h8000_0002, " wo %0d wo0 %0d wow %0d wow0 %0d wow1 %0d\n", tm_wo, tm_wo0, tm_wow, tm_wow0, tm_wow1);
          tm_run = 1'b0;
        end
      end
    end

  // ---------------------------------------------------------------------------------------------- +occlog (sim)
  // conventions 7.5: the per-clock occupancy trace in polly2-rtl-lite's POLLY2OCC 1 format (tools/occview): with
  // +occlog[=file] (default occ.log), a line "@<clock> <hex> [v<i>=<n> ...]" whenever a unit's 2-bit state or a value
  // changes, the clock counted from the core's reset; "R <clock>" at each render's `start`, "D <clock>" when its ev_isp,
  // ev_tsp and ev_vid have all fired; "X <track> <clock> <len> <addr>" for each episode of an event track, written when
  // it ends (not in clock order). A unit's state: 0 waiting for input, 1 busy, 2 blocked on its output (its valid held
  // against a ready low). Each unit's from its own handshakes and idle / busy outputs:
  //   SEQ  seq_busy / ent_v&&!ent_rdy        CTL  ctl_busy / cmd_v&&!cmd_rdy     OLW  !olw_idle / ob_v&&!ob_rdy
  //   IPF  !pf_idle / asm_v&&!asm_rdy        ISU  !su_idle / su_v&&!su_rdy       PCACHE rp_busy / rp_v&&!rp_rdy
  //   RAST !ra_idle / row_v&&!out_rdy        PIX  !px_idle                       IFB  !fb_idle
  //   CUT  !cut_idle / rs_v&&!rs_rdy         RUNQ q_v / !rs_rdy (full)           SORT q_v||so_v / so_v&&!so_rdy
  //   STORE so_v||hd_v||jb_v / hd_v&&!hd_rdy  TPF !tpf_idle / pr_v&&!pr_rdy      TSU  !tsu_idle
  //   RSTART rst_busy||hd_v / rd2_v&&!rd2_rdy PXQ pq_v / !rd2_rdy (full)         PP   pq_v||t_p10 / pp_stall
  //   TBUF !tctl_idle / tb_hold              WOUT wo_busy / m5_v&&!m5_rdy        MEM  any client's request / one held
  //   TEXSTALL pp_tstall                     PTC  pt / o_v&&!o_rdy               IBUF any port of p2_isp_buf or sw_busy
  //   TILEQ tq_v / !tq_in_rdy (full)         ENTQ eq_v / !eqi_rdy (full)         REGS reg_wr||reg_rd
  // IBUF (the tile depth / tag RAMs) and REGS have no output handshake, so they are never 2: IBUF's row barrier
  // (bar_ok) shows as PIX / CUT waiting. PTC is busy through the punch-through phase, 2 while its hand-off is held.
  // Values: v0 ISP tile x, v1 tile y, v2 run queue places, v3 pixel queue pixels, v4 its runs, v5 write-out tile x, v6
  // tile y, v7 entries taken, v8 tile queue records, v9 entry queue records (both p2_isp_entq's ENT_N 32, counted here
  // from their handshakes), v10 register writes. Event track 0 TEX$FILL (pp_fill: the texture cache filling), stall.
  localparam int OCC_NU = 27, OCC_NV = 11;
  int     occ_fd = 0;
  string  occ_fn;
  longint occ_cyc = 0;
  bit     occ_first = 1'b1, occ_live = 1'b0, occ_fi, occ_ft, occ_fv;
  logic [2*OCC_NU-1:0] occ_vec, occ_prev;
  int     occ_val [OCC_NV], occ_pv [OCC_NV];
  int     occ_ents = 0, occ_tqn = 0, occ_eqn = 0, occ_wrs = 0;
  bit     occ_ev_op = 1'b0;
  longint occ_ev_c0;
  function automatic logic [1:0] occ_st(input logic busy, input logic blk);
    return blk ? 2'd2 : busy ? 2'd1 : 2'd0;
  endfunction
  always_comb begin
    occ_vec = '0;
    occ_vec[2*0  +: 2] = occ_st(seq_busy, ent_v && !ent_rdy);
    occ_vec[2*1  +: 2] = occ_st(ctl_busy, cmd_v && !cmd_rdy);
    occ_vec[2*2  +: 2] = occ_st(!olw_idle, ob_v && !ob_rdy);
    occ_vec[2*3  +: 2] = occ_st(!pf_idle, asm_v && !asm_rdy);
    occ_vec[2*4  +: 2] = occ_st(!su_idle, su_v && !su_rdy);
    occ_vec[2*5  +: 2] = occ_st(rp_busy, rp_v && !rp_rdy);
    occ_vec[2*6  +: 2] = occ_st(!ra_idle, row_v && !out_rdy);
    occ_vec[2*7  +: 2] = occ_st(!px_idle, 1'b0);
    occ_vec[2*8  +: 2] = occ_st(!fb_idle, 1'b0);
    occ_vec[2*9  +: 2] = occ_st(!cut_idle, rs_v && !rs_rdy);
    occ_vec[2*10 +: 2] = occ_st(q_v, !rs_rdy);
    occ_vec[2*11 +: 2] = occ_st(q_v || so_v, so_v && !so_rdy);
    occ_vec[2*12 +: 2] = occ_st(so_v || hd_v || jb_v, hd_v && !hd_rdy);
    occ_vec[2*13 +: 2] = occ_st(!tpf_idle, pr_v && !pr_rdy);
    occ_vec[2*14 +: 2] = occ_st(!tsu_idle, 1'b0);
    occ_vec[2*15 +: 2] = occ_st(rst_busy || hd_v, rd2_v && !rd2_rdy);
    occ_vec[2*16 +: 2] = occ_st(pq_v, !rd2_rdy);
    occ_vec[2*17 +: 2] = occ_st(pq_v || t_p10, pp_stall);
    occ_vec[2*18 +: 2] = occ_st(!tctl_idle, tb_hold);
    occ_vec[2*19 +: 2] = occ_st(wo_busy, m5_v && !c_rdy[P2_C_WOUT]);
    occ_vec[2*20 +: 2] = occ_st(c_v != '0, (c_v & ~c_rdy) != '0);
    occ_vec[2*21 +: 2] = occ_st(pp_tstall, 1'b0);
    occ_vec[2*22 +: 2] = occ_st(pt, o_v && !o_rdy);
    occ_vec[2*23 +: 2] = occ_st(f_re || c_re || fb_re || w_v || cv_we || cs_we || fbw_v || sw_busy, 1'b0);
    occ_vec[2*24 +: 2] = occ_st(tq_v, !tq_in_rdy);
    occ_vec[2*25 +: 2] = occ_st(eq_v, !eqi_rdy);
    occ_vec[2*26 +: 2] = occ_st(reg_wr || reg_rd, 1'b0);
  end
  always_comb begin
    occ_val[0] = int'(tilex);
    occ_val[1] = int'(tiley);
    occ_val[2] = int'(runq_occ);
    occ_val[3] = int'(pxq_pix);
    occ_val[4] = int'(pxq_runs);
    occ_val[5] = int'(wo_tx);
    occ_val[6] = int'(wo_ty);
    occ_val[7] = occ_ents;
    occ_val[8] = occ_tqn;
    occ_val[9] = occ_eqn;
    occ_val[10] = occ_wrs;
  end
  initial begin
    if ($value$plusargs("occlog=%s", occ_fn)) occ_fd = $fopen(occ_fn, "w");
    else if ($test$plusargs("occlog")) occ_fd = $fopen("occ.log", "w");
    if (occ_fd != 0) begin
      $fwrite(occ_fd, "POLLY2OCC 1\n");
      $fwrite(occ_fd, "U 0 SEQ\nU 1 CTL\nU 2 OLW\nU 3 IPF\nU 4 ISU\nU 5 PCACHE\nU 6 RAST\nU 7 PIX\nU 8 IFB\nU 9 CUT\n");
      $fwrite(occ_fd, "U 10 RUNQ\nU 11 SORT\nU 12 STORE\nU 13 TPF\nU 14 TSU\nU 15 RSTART\nU 16 PXQ\nU 17 PP\nU 18 TBUF\n");
      $fwrite(occ_fd, "U 19 WOUT\nU 20 MEM\nU 21 TEXSTALL\nU 22 PTC\nU 23 IBUF\nU 24 TILEQ\nU 25 ENTQ\nU 26 REGS\n");
      $fwrite(occ_fd, "V 0 isp_tx\nV 1 isp_ty\nV 2 runq_n\nV 3 pxq_pix\nV 4 pxq_runs\nV 5 wo_tx\nV 6 wo_ty\nV 7 entries\n");
      $fwrite(occ_fd, "V 8 tileq_n\nV 9 entq_n\nV 10 reg_wrs\n");
      $fwrite(occ_fd, "F 10 2 300\nF 16 3 %0d\nF 24 8 32\nF 25 9 32\n", P2_PXQ_PIX);
      $fwrite(occ_fd, "T 0 TEX$FILL stall\n");
    end
  end
  always @(posedge clk)
    if (occ_fd != 0) begin
      occ_cyc++;
      if (rst) {occ_tqn, occ_eqn} = '0;
      else begin
        occ_tqn += int'(tq_in_v && tq_in_rdy) - int'(tq_v && tq_rdy);
        occ_eqn += int'(eqi_v && eqi_rdy) - int'(eq_v && eq_rdy);
      end
      if (!rst) begin
        if (start) begin
          $fwrite(occ_fd, "R %0d\n", occ_cyc);
          occ_live = 1'b1;
          {occ_fi, occ_ft, occ_fv} = '0;
        end
        if (ent_v && ent_rdy) occ_ents++;
        if (reg_wr) occ_wrs++;
        if (occ_first || occ_vec != occ_prev || occ_val != occ_pv) begin
          $fwrite(occ_fd, "@%0d %h", occ_cyc, occ_vec);
          for (int i = 0; i < OCC_NV; i++)
            if (occ_first || occ_val[i] != occ_pv[i])
              $fwrite(occ_fd, " v%0d=%0d", i, occ_val[i]);
          $fwrite(occ_fd, "\n");
          occ_prev  = occ_vec;
          occ_pv    = occ_val;
          occ_first = 1'b0;
        end
        if (occ_ev_op && !pp_fill) begin
          $fwrite(occ_fd, "X 0 %0d %0d 0\n", occ_ev_c0, occ_cyc - occ_ev_c0);
          occ_ev_op = 1'b0;
        end
        if (!occ_ev_op && pp_fill) begin
          occ_ev_op = 1'b1;
          occ_ev_c0 = occ_cyc;
        end
        if (occ_live) begin
          if (ev_isp) occ_fi = 1'b1;
          if (ev_tsp) occ_ft = 1'b1;
          if (ev_vid) occ_fv = 1'b1;
          if (occ_fi && occ_ft && occ_fv) begin
            $fwrite(occ_fd, "D %0d\n", occ_cyc);
            $fflush(occ_fd);
            occ_live = 1'b0;
          end
        end
      end
    end
  final
    if (occ_fd != 0) begin
      if (occ_ev_op) $fwrite(occ_fd, "X 0 %0d %0d 0\n", occ_ev_c0, occ_cyc - occ_ev_c0);
      $fclose(occ_fd);
    end
`endif
endmodule

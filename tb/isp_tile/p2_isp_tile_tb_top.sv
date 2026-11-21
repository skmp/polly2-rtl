// p2_isp_tile_tb_top: make isp-tile (tb/isp_tile/isp_tile_tb.cpp, PLAN M6, M7, 1.3 "ISP tile testbench"). The ISP wired
// as ARCHITECTURE 1.1 draws it, with flat ports for the testbench:
//
//   entry ──► p2_isp_ctl ──► p2_isp_olw ──► p2_isp_pfetch ──► p2_isp_setup ──► hand-off ──► p2_isp_ptc ─┐
//                 │ sweeps        │ C1            │ C2                                          (PRESORT block)│
//                 │               ▼               ▼                          p2_isp_pcache (fill / replay) ──► mux ──► p2_isp_raster
//                 ▼           p2_mem ──► the two VRAM halves (the testbench's VRAM model)                          │ rows
//             p2_isp_buf ◄── p2_isp_pix (R0 / R1 / R2; the row barrier) ◄──────────────────────────────────────────┘
//                 ▲  ▲ C port, flip-flops, side effects
//                 │  └── p2_isp_cut ──► the run stream (rs_*), p2_isp_entq (eq_*)        [the TSP: the testbench]
//                 └───── p2_isp_fb ◄── the punch-through feedback (fb_*)
//
// The other p2_mem clients (C0, C3, C4, C5) are tied off until their units land. The testbench drives the render's
// registers, feeds entries, resumes the phase halts, pops the run stream and p2_entq, answers the punch-through passes,
// and reads and writes p2_isp_buf's rows through its debug port.
module p2_isp_tile_tb_top
  import p2_pkg::*;
  import p2_regs_pkg::*;
(
  input  logic                              clk,
  input  logic                              rst,
  // ---- entries
  input  logic                              ent_v,
  output logic                              ent_rdy,
  input  logic [5:0]                        e_tilex,
  input  logic [5:0]                        e_tiley,
  input  logic                              e_no_writeout,
  input  logic                              e_pre_sort,
  input  logic                              e_z_keep,
  input  logic                              e_last,
  input  logic [21:0]                       e_ptr [P2_LISTS],
  input  logic [P2_LISTS-1:0]               e_empty,
  input  logic [15:0]                       e_idx,
  // ---- the render's registers
  input  logic [31:0]                       param_base,
  input  logic [31:0]                       fpu_shad_scale,
  input  logic [31:0]                       fpu_cull_val,
  input  logic [31:0]                       fpu_perp_val,
  input  logic [31:0]                       half_offset,
  input  logic [31:0]                       bg_tag,
  input  logic [31:0]                       bg_depth,
  input  logic [31:0]                       isp_feed_cfg,
  // ---- phase halt
  input  logic                              halt_en,
  input  logic                              resume,
  output logic                              halted,
  output logic [4:0]                        halt_phase,
  output logic                              busy,
  output logic                              ent_done,
  output logic [15:0]                       st_chunks,
  output logic [15:0]                       st_passes,
  output logic [15:0]                       st_trpasses,
  output logic [15:0]                       st_ptshades,
  output logic                              cut_idle,
  // ---- the run stream (p2_rs_t) and p2_entq
  output logic                              rs_v,
  input  logic                              rs_rdy,
  output logic                              rs_null,
  output logic [31:0]                       rs_tag,
  output logic [4:0]                        rs_y,
  output logic [4:0]                        rs_x,
  output logic [4:0]                        rs_lenm1,
  output logic [2:0]                        rs_rm,
  output logic [6:0]                        rs_epoch,
  output logic [31:0]                       rs_vmask,
  output logic [31:0]                       rs_pmask,
  output logic                              rs_eop,
  output logic                              rs_eoe,
  output logic                              eq_v,
  input  logic                              eq_rdy,
  output logic [5:0]                        eq_tilex,
  output logic [5:0]                        eq_tiley,
  output logic                              eq_z_keep,
  output logic                              eq_no_writeout,
  output logic                              eq_last,
  output logic                              eq_shaded_any,
  // ---- the punch-through feedback (p2_fb_t)
  input  logic                              fb_v,
  output logic                              fb_rdy,
  input  logic                              fb_kind,
  input  logic [9:0]                        fb_idx,
  input  logic                              fb_fail,
  input  logic                              fb_ro,
  // ---- the VRAM halves
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
  // ---- p2_isp_buf's debug port
  input  logic [4:0]                        dbg_row,
  output logic [63:0]                       dbg_depth [32],
  output logic [31:0]                       dbg_tag [32],
  output logic [63:0]                       dbg_depth_b [32],
  output logic [31:0]                       dbg_tag_b [32],
  output logic [63:0]                       dbg_depth_c [32],
  output logic [31:0]                       dbg_reftag_c [32],
  output logic [31:0]                       dbg_optag [32],
  output logic [31:0]                       dbg_restag [32],
  output logic [63:0]                       dbg_rsd [32],
  output logic [2:0]                        dbg_stencil [32],
  output logic [31:0]                       dbg_valid,
  output logic [31:0]                       dbg_rendered,
  output logic [31:0]                       dbg_rcur,
  output logic [31:0]                       dbg_rlp,
  output logic [31:0]                       dbg_ever,
  input  logic                              dbg_we,
  input  logic [63:0]                       dbg_wdepth [32],
  input  logic [31:0]                       dbg_wtag [32],
  input  logic [63:0]                       dbg_wdepth_b [32],
  input  logic [31:0]                       dbg_wtag_b [32],
  input  logic [63:0]                       dbg_wdepth_c [32],
  input  logic [31:0]                       dbg_wreftag_c [32],
  input  logic [31:0]                       dbg_woptag [32],
  input  logic [31:0]                       dbg_wrestag [32],
  input  logic [63:0]                       dbg_wrsd [32],
  input  logic [2:0]                        dbg_wstencil [32],
  input  logic [31:0]                       dbg_wvalid,
  input  logic [31:0]                       dbg_wrendered,
  input  logic [31:0]                       dbg_wrcur,
  input  logic [31:0]                       dbg_wrlp,
  input  logic [31:0]                       dbg_wever,
  // ---- taps: a primitive accepted by setup, a descriptor taken by the raster, a row into pix, a MODIFIER row one
  // clock after a MODIFIER row of the same row number (never: p2_isp_pix's stencil has no bypass from R2)
  output logic                              t_asm,
  output logic                              t_desc,
  output logic                              t_row,
  output logic                              t_mrow,
  // ---- more taps: a raster row held by the row barrier; pcache overflowed (this clock); ptc in full-walk mode; a
  // replayed descriptor taken; a descriptor held by ptc; a descriptor dropped by ptc
  output logic                              t_bar,
  output logic                              t_ovf,
  output logic                              t_fw,
  output logic                              t_rp,
  output logic                              t_hold,
  output logic                              t_drop,
  // a punch-through or sort row in R1 with a pixel whose `valid` comes from R2's write of the same row (p2_isp_pix's
  // bypass: without it the row would read 0)
  output logic                              t_vby
);
  // ---------------------------------------------------------------------------------------------- the entry
  p2_entry_t ent;
  always_comb begin
    ent             = '0;
    ent.tilex       = e_tilex;
    ent.tiley       = e_tiley;
    ent.no_writeout = e_no_writeout;
    ent.pre_sort    = e_pre_sort;
    ent.z_keep      = e_z_keep;
    ent.last        = e_last;
    for (int l = 0; l < P2_LISTS; l++)
      ent.ptr[l] = e_ptr[l];
    ent.empty       = e_empty;
    ent.idx         = e_idx;
  end

  // ---------------------------------------------------------------------------------------------- ctl
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
  logic        cmd_v, cmd_rdy, cmd_end, cmd_opinpt, cmd_last;
  p2_rm_t      cmd_rm;
  p2_entrec_t  cmd_rec;
  logic        pass_done, anyfail;
  p2_isp_ctl u_ctl (.clk(clk), .rst(rst), .ent_v(ent_v), .ent_rdy(ent_rdy), .ent(ent), .bg_tag(bg_tag),
    .bg_depth(bg_depth), .sw_v(sw_v), .sw_op(sw_op), .sw_key(sw_key), .sw_tag(sw_tag), .sw_busy(sw_busy),
    .walk_v(walk_v), .walk_addr(walk_addr), .walk_scan(walk_scan), .walk_rm(walk_rm), .tilex(tilex), .tiley(tiley),
    .has_prim(has_prim), .front_idle(front_idle), .back_idle(back_idle), .ho_take(ho_take), .ho_block(ho_block),
    .more(more), .more_clr(more_clr), .pt(pt), .pt_en(pt_en), .pt_restart(pt_restart), .pt_set_cur(pt_set_cur),
    .pt_cur(pt_cur), .pt_fw_clr(pt_fw_clr), .pt_fw(pt_fw), .pt_hold(pt_hold), .pt_more_chunks(pt_more_chunks),
    .pc_reset(pc_reset), .pc_tr(pc_tr), .pc_fill_en(pc_fill_en), .pc_ovf(pc_ovf), .rp_start(rp_start),
    .rp_busy(rp_busy), .src_rp(src_rp), .cmd_v(cmd_v), .cmd_rdy(cmd_rdy), .cmd_end(cmd_end), .cmd_rm(cmd_rm),
    .cmd_opinpt(cmd_opinpt), .cmd_last(cmd_last), .cmd_rec(cmd_rec), .cut_idle(cut_idle), .pass_done(pass_done),
    .anyfail(anyfail), .halt_en(halt_en), .resume(resume), .halted(halted), .halt_phase(halt_phase), .busy(busy),
    .ent_done(ent_done), .st_chunks(st_chunks), .st_passes(st_passes), .st_trpasses(st_trpasses), .st_ptshades(st_ptshades));

  // ---------------------------------------------------------------------------------------------- p2_mem
  localparam int NC = 6;
  logic [NC-1:0]        c_v, c_rdy, c_we, c_w64, c_rv, c_rrdy;
  logic [NC-1:0][23:0]  c_addr;
  logic [NC-1:0][7:0]   c_be;
  logic [NC-1:0][63:0]  c_wdata, c_rdata;

  logic        m1_v, m1_rrdy, m2_v, m2_rrdy;
  logic [23:0] m1_addr, m2_addr;

  // ---------------------------------------------------------------------------------------------- olw (C1)
  logic        ob_v, ob_rdy, olw_idle;
  p2_isp_obj_t ob;
  p2_isp_olw u_olw (.clk(clk), .rst(rst), .cmd_v(walk_v), .cmd_addr(walk_addr), .cmd_scan(walk_scan),
    .idle(olw_idle), .has_prim(has_prim), .ob_v(ob_v),
    .ob_rdy(ob_rdy), .ob(ob), .m_v(m1_v), .m_rdy(c_rdy[P2_C_OLW]), .m_addr(m1_addr), .m_rv(c_rv[P2_C_OLW]),
    .m_rrdy(m1_rrdy), .m_rdata(c_rdata[P2_C_OLW][31:0]));

  // ---------------------------------------------------------------------------------------------- pfetch (C2)
  logic    asm_v, asm_rdy, pf_idle;
  p2_asm_t asm_o;
  p2_isp_pfetch u_pfetch (.clk(clk), .rst(rst), .ob_v(ob_v), .ob_rdy(ob_rdy), .ob(ob), .rm(walk_rm), .tilex(tilex),
    .tiley(tiley), .param_base(param_base), .shad_intensity(fpu_shad_scale[8]), .asm_v(asm_v), .asm_rdy(asm_rdy),
    .asm_o(asm_o), .idle(pf_idle), .m_v(m2_v), .m_rdy(c_rdy[P2_C_ISP_PFETCH]), .m_addr(m2_addr),
    .m_rv(c_rv[P2_C_ISP_PFETCH]), .m_rrdy(m2_rrdy), .m_rdata(c_rdata[P2_C_ISP_PFETCH][31:0]));

  // C1, C2; the clients without a unit yet are tied off
  always_comb begin
    c_v                    = '0;
    c_addr                 = '0;
    c_rrdy                 = '1;
    c_v[P2_C_OLW]          = m1_v;
    c_addr[P2_C_OLW]       = m1_addr;
    c_rrdy[P2_C_OLW]       = m1_rrdy;
    c_v[P2_C_ISP_PFETCH]    = m2_v;
    c_addr[P2_C_ISP_PFETCH] = m2_addr;
    c_rrdy[P2_C_ISP_PFETCH] = m2_rrdy;
    c_we    = '0;
    c_w64   = '0;
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

  // ---------------------------------------------------------------------------------------------- setup
  logic      su_v, su_rdy, su_idle, pc_v, pc_culled, pc_quad, pc_desc;
  p2_rdesc_t su_d;
  p2_isp_setup u_setup (.clk(clk), .rst(rst), .asm_v(asm_v), .asm_rdy(asm_rdy), .asm_i(asm_o),
    .fpu_cull_val(fpu_cull_val), .fpu_perp_val(fpu_perp_val), .half(half_offset[0]), .rd_v(su_v), .rd_rdy(su_rdy),
    .rd(su_d), .pc_v(pc_v), .pc_culled(pc_culled), .pc_quad(pc_quad), .pc_desc(pc_desc), .idle(su_idle), .t_issue(),
    .t_cls(), .t_pc(), .t_uw(), .t_wv(), .t_wrd());

  // ---------------------------------------------------------------------------------------------- ptc, pcache, the mux
  logic o_v, o_rdy;
  p2_isp_ptc u_ptc (.clk(clk), .rst(rst), .chunk_size(isp_feed_cfg[13:4]), .pt(pt), .en(pt_en), .restart(pt_restart),
    .set_cur(pt_set_cur), .cur_in(pt_cur), .fw_set(pt && pc_fill_en && pc_ovf), .fw_clr(pt_fw_clr), .fw(pt_fw), .hold(pt_hold),
    .more_chunks(pt_more_chunks), .chunk_at(pt_at), .pc_v(pc_v), .pc_culled(pc_culled), .pc_quad(pc_quad),
    .pc_desc(pc_desc), .rd_v(su_v), .rd_rdy(su_rdy), .o_v(o_v), .o_rdy(o_rdy));

  logic      rp_v, rp_rdy, ra_rdy, rd_v;
  p2_rdesc_t rp, rd;
  p2_isp_pcache u_pcache (.clk(clk), .rst(rst), .reset(pc_reset), .tr(pc_tr), .tr_size(isp_feed_cfg[23:14]),
    .fill_en(pc_fill_en), .fill_v(ho_take), .fill_d(su_d), .ovf(pc_ovf), .rp_start(rp_start), .rp_v(rp_v),
    .rp_rdy(rp_rdy), .rp(rp), .rp_busy(rp_busy));

  // the raster's input: pcache's replay, or the setup side (held in TR_PRESORT until the primitive before is shaded)
  assign rd_v    = src_rp ? rp_v : (o_v && !ho_block);
  assign rd      = src_rp ? rp : su_d;
  assign rp_rdy  = src_rp && ra_rdy;
  assign o_rdy   = !src_rp && !ho_block && ra_rdy;
  assign ho_take = o_v && o_rdy;

  // ---------------------------------------------------------------------------------------------- the raster
  logic                   row_v, out_rdy, row_last, ra_idle, row_zwdis;
  logic [4:0]             row_j;
  logic [31:0]            in_mask;
  p2_zkey_t [P2_TILE-1:0] zk;
  p2_tag_t                row_tag;
  p2_rm_t                 row_rm;
  logic [2:0]             row_dm;
  p2_sum_op_t             row_sum;
  p2_isp_raster u_raster (.clk(clk), .rst(rst), .rd_v(rd_v), .rd_rdy(ra_rdy), .rd(rd), .row_v(row_v), .out_rdy(out_rdy),
    .row_j(row_j), .in_mask(in_mask), .zk(zk), .row_last(row_last), .row_tag(row_tag), .row_rm(row_rm),
    .row_depth_mode(row_dm), .row_zwdis(row_zwdis), .row_sum_op(row_sum), .idle(ra_idle));

  // ---------------------------------------------------------------------------------------------- pix, buf, cut, fb
  logic                     f_re, w_v, w_swe, px_idle;
  logic [4:0]               f_row, n_row, w_row;
  p2_zkey_t [P2_TILE-1:0]   f_depth, f_depth_b, f_depth_c, w_depth, c_depth, cs_data;
  logic [P2_TILE-1:0][31:0] f_tag, f_tag_b, f_reftag_c, w_tag, c_tag;
  logic [P2_TILE-1:0][2:0]  n_stencil, w_stencil;
  logic [P2_TILE-1:0]       n_valid, n_rendered, n_rlp, w_dwe, w_twe, w_vwe, w_valid, bar_ok;
  p2_isp_pix u_pix (.clk(clk), .rst(rst), .row_v(row_v), .out_rdy(out_rdy), .row_j(row_j), .in_mask(in_mask), .zk(zk),
    .row_tag(row_tag), .row_rm(row_rm), .row_depth_mode(row_dm), .row_zwdis(row_zwdis), .row_sum_op(row_sum),
    .bar_ok(bar_ok), .more_clr(more_clr), .more(more), .f_re(f_re), .f_row(f_row), .f_depth(f_depth), .f_tag(f_tag),
    .f_depth_b(f_depth_b), .f_tag_b(f_tag_b), .f_depth_c(f_depth_c), .f_reftag_c(f_reftag_c), .n_row(n_row),
    .n_stencil(n_stencil), .n_valid(n_valid), .n_rendered(n_rendered), .n_rlp(n_rlp), .w_v(w_v), .w_row(w_row),
    .w_dwe(w_dwe), .w_twe(w_twe), .w_depth(w_depth), .w_tag(w_tag), .w_swe(w_swe), .w_stencil(w_stencil),
    .w_vwe(w_vwe), .w_valid(w_valid), .idle(px_idle));

  // the cutter
  logic                              c_re, cv_we, cs_we;
  logic [4:0]                        c_row, cv_row, cs_row;
  logic [P2_TILE-1:0]                cv_lane, cs_lane;
  logic [P2_TILE-1:0][P2_TILE-1:0]   k_valid, k_st0, k_rendered;
  p2_rs_t                            rs;
  logic                              eqi_v, eqi_rdy;
  p2_entrec_t                        eqi, eqo;
  p2_isp_cut u_cut (.clk(clk), .rst(rst), .cmd_v(cmd_v), .cmd_rdy(cmd_rdy), .cmd_end(cmd_end), .cmd_rm(cmd_rm),
    .cmd_opinpt(cmd_opinpt), .cmd_last(cmd_last), .cmd_rec(cmd_rec), .idle(cut_idle), .c_re(c_re), .c_row(c_row),
    .c_depth(c_depth), .c_tag(c_tag), .k_valid(k_valid), .k_st0(k_st0), .k_rendered(k_rendered), .cv_we(cv_we),
    .cv_row(cv_row), .cv_lane(cv_lane), .cs_we(cs_we), .cs_row(cs_row), .cs_lane(cs_lane), .cs_data(cs_data),
    .bar_ok(bar_ok), .rs_v(rs_v), .rs_rdy(rs_rdy), .rs(rs), .eq_v(eqi_v), .eq_rdy(eqi_rdy), .eq(eqi), .ev_isp());
  p2_isp_entq u_entq (.clk(clk), .rst(rst), .in_v(eqi_v), .in_rdy(eqi_rdy), .in_d(eqi), .out_v(eq_v), .out_rdy(eq_rdy),
    .out_d(eqo));
  assign rs_null  = rs.null_;
  assign rs_tag   = rs.tag;
  assign rs_y     = rs.y;
  assign rs_x     = rs.x;
  assign rs_lenm1 = rs.lenm1;
  assign rs_rm    = rs.rm;
  assign rs_epoch = rs.epoch;
  assign rs_vmask = rs.vmask;
  assign rs_pmask = rs.pmask;
  assign rs_eop   = rs.eop;
  assign rs_eoe   = rs.eoe;
  assign eq_tilex       = eqo.tilex;
  assign eq_tiley       = eqo.tiley;
  assign eq_z_keep      = eqo.z_keep;
  assign eq_no_writeout = eqo.no_writeout;
  assign eq_last        = eqo.last;
  assign eq_shaded_any  = eqo.shaded_any;

  // the feedback
  logic                    fb_re, fbw_v, fbw_pass, fb_idle;
  logic [4:0]              fb_row, fbw_row;
  logic [P2_TILE-1:0]      fbw_lane;
  p2_zkey_t                fbw_depth;
  logic [31:0]             fbw_tag;
  p2_fb_t                  fbm;
  always_comb begin
    fbm      = '0;
    fbm.kind = p2_fb_kind_t'(fb_kind);
    fbm.idx  = fb_idx;
    fbm.fail = fb_fail;
    fbm.ro   = fb_ro;
  end
  p2_isp_fb u_fb (.clk(clk), .rst(rst), .fb_v(fb_v), .fb_rdy(fb_rdy), .fb(fbm), .fb_re(fb_re), .fb_row(fb_row),
    .f_depth(f_depth), .f_tag(f_tag), .fbw_v(fbw_v), .fbw_row(fbw_row), .fbw_lane(fbw_lane), .fbw_pass(fbw_pass),
    .fbw_depth(fbw_depth), .fbw_tag(fbw_tag), .pass_done(pass_done), .anyfail(anyfail), .idle(fb_idle));

  // the buffer
  p2_zkey_t [P2_TILE-1:0]   bdd, bdb, bdc, bdr, bwd, bwb, bwc, bwr;
  logic [P2_TILE-1:0][31:0] bdt, bdtb, bdrt, bdo, bdrs, bwt, bwtb, bwrt, bwo, bwrs;
  logic [P2_TILE-1:0][2:0]  bds, bws;
  p2_isp_buf u_buf (.clk(clk), .rst(rst), .f_re(f_re), .f_row(f_row), .f_depth(f_depth), .f_tag(f_tag),
    .f_depth_b(f_depth_b), .f_tag_b(f_tag_b), .f_depth_c(f_depth_c), .f_reftag_c(f_reftag_c), .n_row(n_row),
    .n_stencil(n_stencil), .n_valid(n_valid), .n_rendered(n_rendered), .n_rlp(n_rlp), .c_re(c_re), .c_row(c_row),
    .c_depth(c_depth), .c_tag(c_tag), .k_valid(k_valid), .k_st0(k_st0), .k_rendered(k_rendered), .w_v(w_v),
    .w_row(w_row), .w_dwe(w_dwe), .w_twe(w_twe), .w_depth(w_depth), .w_tag(w_tag), .w_swe(w_swe),
    .w_stencil(w_stencil), .w_vwe(w_vwe), .w_valid(w_valid), .cv_we(cv_we), .cv_row(cv_row), .cv_lane(cv_lane),
    .cs_we(cs_we), .cs_row(cs_row), .cs_lane(cs_lane), .cs_data(cs_data), .fb_re(fb_re), .fb_row(fb_row),
    .fbw_v(fbw_v), .fbw_row(fbw_row), .fbw_lane(fbw_lane), .fbw_pass(fbw_pass), .fbw_depth(fbw_depth),
    .fbw_tag(fbw_tag), .sw_v(sw_v), .sw_op(sw_op), .sw_key(sw_key), .sw_tag(sw_tag), .sw_busy(sw_busy),
    .bar_ok(bar_ok), .dbg_row(dbg_row), .dbg_depth(bdd), .dbg_tag(bdt), .dbg_depth_b(bdb), .dbg_tag_b(bdtb),
    .dbg_depth_c(bdc), .dbg_reftag_c(bdrt), .dbg_optag(bdo), .dbg_restag(bdrs), .dbg_rsd(bdr), .dbg_stencil(bds),
    .dbg_valid(dbg_valid), .dbg_rendered(dbg_rendered), .dbg_rcur(dbg_rcur), .dbg_rlp(dbg_rlp), .dbg_ever(dbg_ever),
    .dbg_we(dbg_we), .dbg_wdepth(bwd), .dbg_wtag(bwt), .dbg_wdepth_b(bwb), .dbg_wtag_b(bwtb), .dbg_wdepth_c(bwc),
    .dbg_wreftag_c(bwrt), .dbg_woptag(bwo), .dbg_wrestag(bwrs), .dbg_wrsd(bwr), .dbg_wstencil(bws),
    .dbg_wvalid(dbg_wvalid), .dbg_wrendered(dbg_wrendered), .dbg_wrcur(dbg_wrcur), .dbg_wrlp(dbg_wrlp),
    .dbg_wever(dbg_wever));
  always_comb
    for (int i = 0; i < P2_TILE; i++) begin
      dbg_depth[i]    = bdd[i];
      dbg_tag[i]      = bdt[i];
      dbg_depth_b[i]  = bdb[i];
      dbg_tag_b[i]    = bdtb[i];
      dbg_depth_c[i]  = bdc[i];
      dbg_reftag_c[i] = bdrt[i];
      dbg_optag[i]    = bdo[i];
      dbg_restag[i]   = bdrs[i];
      dbg_rsd[i]      = bdr[i];
      dbg_stencil[i]  = bds[i];
      bwd[i]  = dbg_wdepth[i];
      bwt[i]  = dbg_wtag[i];
      bwb[i]  = dbg_wdepth_b[i];
      bwtb[i] = dbg_wtag_b[i];
      bwc[i]  = dbg_wdepth_c[i];
      bwrt[i] = dbg_wreftag_c[i];
      bwo[i]  = dbg_woptag[i];
      bwrs[i] = dbg_wrestag[i];
      bwr[i]  = dbg_wrsd[i];
      bws[i]  = dbg_wstencil[i];
    end

  assign front_idle = olw_idle && pf_idle && su_idle;
  assign back_idle  = ra_idle && px_idle && fb_idle;

  assign t_asm  = asm_v && asm_rdy;
  assign t_desc = rd_v && ra_rdy;
  assign t_row  = row_v && out_rdy;
  assign t_bar  = row_v && !out_rdy;
  assign t_ovf  = pc_ovf;
  assign t_fw   = pt_fw;
  assign t_rp   = rp_v && rp_rdy;
  assign t_hold = pt_hold;
  assign t_drop = su_v && su_rdy && !o_v;
  assign t_vby  = u_pix.r1_v && u_pix.by2 && (u_pix.r2_vwe & u_pix.r1_m & ~u_pix.n_valid) != '0 && u_pix.r1_rm inside {P2_RM_PUNCHTHROUGH_PASS0,
                  P2_RM_PUNCHTHROUGH_PASSN, P2_RM_TRANSLUCENT_AUTOSORT};
  // pix takes a row a clock when the barrier lets it: consecutive rows into R0 are R1 and R2 a clock later
  logic       m_prev;
  logic [4:0] m_prev_j;
  always_ff @(posedge clk) begin
    m_prev   <= !rst && row_v && out_rdy && row_rm == P2_RM_MODIFIER;
    m_prev_j <= row_j;
  end
  assign t_mrow = row_v && out_rdy && row_rm == P2_RM_MODIFIER && m_prev && m_prev_j == row_j;
endmodule

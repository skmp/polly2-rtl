// p2_isp_tile_tb_top: make isp-tile-op (tb/isp_tile/isp_tile_tb.cpp, PLAN M6, 1.3 "ISP tile testbench"). The ISP of M6
// wired as ARCHITECTURE 1.1 draws it, with flat ports for the testbench:
//
//   entry ──► p2_isp_ctl ──► p2_isp_olw ──► p2_isp_pfetch ──► p2_isp_setup ──► (1-deep hand-off) ──► p2_isp_raster
//                 │ sweeps        │ C1            │ C2                                                     │ rows
//                 ▼               ▼               ▼                                                        ▼
//             p2_isp_buf ◄────────┼───────────────┼──────────────────────────── p2_isp_pix (R0 / R1 / R2) ◄┘
//                                 └─────► p2_mem ◄┘ ──► the two VRAM halves (the testbench's VRAM model)
//
// The other p2_mem clients (C0, C3, C4, C5) are tied off until their units land. The testbench drives the render's
// registers, feeds entries, resumes the phase halts, and reads and writes p2_isp_buf's rows through its debug port.
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
  // ---- phase halt
  input  logic                              halt_en,
  input  logic                              resume,
  output logic                              halted,
  output logic [4:0]                        halt_phase,
  output logic                              busy,
  output logic                              ent_done,
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
  output logic [2:0]                        dbg_stencil [32],
  output logic [31:0]                       dbg_valid,
  input  logic                              dbg_we,
  input  logic [63:0]                       dbg_wdepth [32],
  input  logic [31:0]                       dbg_wtag [32],
  input  logic [2:0]                        dbg_wstencil [32],
  input  logic [31:0]                       dbg_wvalid,
  // ---- taps: a primitive accepted by setup, a descriptor taken by the raster, a row into pix, a MODIFIER row one
  // clock after a MODIFIER row of the same row number (never: p2_isp_pix's stencil has no bypass from R2)
  output logic                              t_asm,
  output logic                              t_desc,
  output logic                              t_row,
  output logic                              t_mrow
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
  logic        walk_v, walk_idle;
  logic [23:0] walk_addr;
  p2_rm_t      walk_rm;
  logic [5:0]  tilex, tiley;
  p2_isp_ctl u_ctl (.clk(clk), .rst(rst), .ent_v(ent_v), .ent_rdy(ent_rdy), .ent(ent), .bg_tag(bg_tag),
    .bg_depth(bg_depth), .sw_v(sw_v), .sw_op(sw_op), .sw_key(sw_key), .sw_tag(sw_tag), .sw_busy(sw_busy),
    .walk_v(walk_v), .walk_addr(walk_addr), .walk_rm(walk_rm), .tilex(tilex), .tiley(tiley), .walk_idle(walk_idle),
    .halt_en(halt_en), .resume(resume), .halted(halted), .halt_phase(halt_phase), .busy(busy), .ent_done(ent_done));

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
  p2_isp_olw u_olw (.clk(clk), .rst(rst), .cmd_v(walk_v), .cmd_addr(walk_addr), .idle(olw_idle), .ob_v(ob_v),
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

  // ---------------------------------------------------------------------------------------------- setup, raster
  logic      rd_v, rd_rdy, su_idle;
  p2_rdesc_t rd;
  p2_isp_setup u_setup (.clk(clk), .rst(rst), .asm_v(asm_v), .asm_rdy(asm_rdy), .asm_i(asm_o),
    .fpu_cull_val(fpu_cull_val), .fpu_perp_val(fpu_perp_val), .half(half_offset[0]), .rd_v(rd_v), .rd_rdy(rd_rdy),
    .rd(rd), .pc_v(), .pc_culled(), .pc_quad(), .idle(su_idle), .t_issue(), .t_cls(), .t_pc(), .t_uw(), .t_wv(),
    .t_wrd());

  logic                   row_v, out_rdy, row_last, ra_idle, row_zwdis;
  logic [4:0]             row_j;
  logic [31:0]            in_mask;
  p2_zkey_t [P2_TILE-1:0] zk;
  p2_tag_t                row_tag;
  p2_rm_t                 row_rm;
  logic [2:0]             row_dm;
  p2_sum_op_t             row_sum;
  p2_isp_raster u_raster (.clk(clk), .rst(rst), .rd_v(rd_v), .rd_rdy(rd_rdy), .rd(rd), .row_v(row_v), .out_rdy(out_rdy),
    .row_j(row_j), .in_mask(in_mask), .zk(zk), .row_last(row_last), .row_tag(row_tag), .row_rm(row_rm),
    .row_depth_mode(row_dm), .row_zwdis(row_zwdis), .row_sum_op(row_sum), .idle(ra_idle));

  // ---------------------------------------------------------------------------------------------- pix, buf
  logic                     f_re, w_v, w_swe, px_idle;
  logic [4:0]               f_row, n_row, w_row;
  p2_zkey_t [P2_TILE-1:0]   f_depth, w_depth, c_depth, bdd, bwd;
  logic [P2_TILE-1:0][31:0] f_tag, w_tag, c_tag, bdt, bwt;
  logic [P2_TILE-1:0][2:0]  n_stencil, w_stencil, bds, bws;
  logic [P2_TILE-1:0]       n_valid, w_dwe, w_twe, w_vwe, w_valid;
  p2_isp_pix u_pix (.clk(clk), .rst(rst), .row_v(row_v), .out_rdy(out_rdy), .row_j(row_j), .in_mask(in_mask), .zk(zk),
    .row_tag(row_tag), .row_rm(row_rm), .row_depth_mode(row_dm), .row_zwdis(row_zwdis), .row_sum_op(row_sum),
    .f_re(f_re), .f_row(f_row), .f_depth(f_depth), .f_tag(f_tag), .n_row(n_row), .n_stencil(n_stencil),
    .n_valid(n_valid), .w_v(w_v), .w_row(w_row), .w_dwe(w_dwe), .w_twe(w_twe), .w_depth(w_depth), .w_tag(w_tag),
    .w_swe(w_swe), .w_stencil(w_stencil), .w_vwe(w_vwe), .w_valid(w_valid), .idle(px_idle));

  p2_isp_buf u_buf (.clk(clk), .rst(rst), .f_re(f_re), .f_row(f_row), .f_depth(f_depth), .f_tag(f_tag), .n_row(n_row),
    .n_stencil(n_stencil), .n_valid(n_valid), .c_re(1'b0), .c_row('0), .c_depth(c_depth), .c_tag(c_tag), .w_v(w_v),
    .w_row(w_row), .w_dwe(w_dwe), .w_twe(w_twe), .w_depth(w_depth), .w_tag(w_tag), .w_swe(w_swe),
    .w_stencil(w_stencil), .w_vwe(w_vwe), .w_valid(w_valid), .sw_v(sw_v), .sw_op(sw_op), .sw_key(sw_key),
    .sw_tag(sw_tag), .sw_busy(sw_busy), .dbg_row(dbg_row), .dbg_depth(bdd), .dbg_tag(bdt), .dbg_stencil(bds),
    .dbg_valid(dbg_valid), .dbg_we(dbg_we), .dbg_wdepth(bwd), .dbg_wtag(bwt), .dbg_wstencil(bws),
    .dbg_wvalid(dbg_wvalid));
  always_comb
    for (int i = 0; i < P2_TILE; i++) begin
      dbg_depth[i]   = bdd[i];
      dbg_tag[i]     = bdt[i];
      dbg_stencil[i] = bds[i];
      bwd[i]         = dbg_wdepth[i];
      bwt[i]         = dbg_wtag[i];
      bws[i]         = dbg_wstencil[i];
    end

  assign walk_idle = olw_idle && pf_idle && su_idle && ra_idle && px_idle;

  assign t_asm  = asm_v && asm_rdy;
  assign t_desc = rd_v && rd_rdy;
  assign t_row  = row_v;
  // pix takes a row a clock (out_rdy = 1): consecutive rows of the raster's register are R1 and R2 a clock later
  logic       m_prev;
  logic [4:0] m_prev_j;
  always_ff @(posedge clk) begin
    m_prev   <= !rst && row_v && row_rm == P2_RM_MODIFIER;
    m_prev_j <= row_j;
  end
  assign t_mrow = row_v && row_rm == P2_RM_MODIFIER && m_prev && m_prev_j == row_j;
endmodule

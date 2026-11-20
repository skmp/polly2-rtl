// p2_isp_setup_tb_top: make isp-setup (tb/isp_setup/isp_setup_tb.cpp, PLAN M4). Flat ports around p2_isp_setup and
// p2_isp_raster joined by the setup's 1-deep hand-off, as the ISP has them:
//   - the asm stream in (valid / ready), the render's registers;
//   - the rows out (valid / ready): the inside mask and the 32 keys, the descriptor's fields beside them;
//   - taps: the descriptor as the raster takes it (every p2_rdesc_t field), the ptc strobe, and the program trace (the
//     step, the micro-word issued, the ALU's register writes of each clock).
module p2_isp_setup_tb_top
  import p2_pkg::*;
  import p2_regs_pkg::*;
  import p2_isp_prog_pkg::*;
(
  input  logic                              clk,
  input  logic                              rst,
  // ---- asm
  input  logic                              asm_v,
  output logic                              asm_rdy,
  input  logic [31:0]                       a_isp,
  input  logic [31:0]                       a_tag,
  input  logic [2:0]                        a_rm,
  input  logic                              a_quad,
  input  logic [31:0]                       a_x [4],
  input  logic [31:0]                       a_y [4],
  input  logic [31:0]                       a_z [3],
  input  logic [5:0]                        a_tilex,
  input  logic [5:0]                        a_tiley,
  input  logic [31:0]                       fpu_cull_val,
  input  logic [31:0]                       fpu_perp_val,
  input  logic                              half,
  // ---- rows
  output logic                              row_v,
  input  logic                              out_rdy,
  output logic [P2_TILE_LOG2-1:0]           row_j,
  output logic [31:0]                       in_mask,
  output logic [63:0]                       zk [32],
  output logic                              row_last,
  output logic [31:0]                       row_tag,
  output logic [2:0]                        row_rm,
  output logic [2:0]                        row_dm,
  output logic                              row_zwdis,
  output logic [1:0]                        row_sum_op,
  // ---- the descriptor at the raster's take
  output logic                              d_take,
  output logic [31:0]                       d_tag,
  output logic [2:0]                        d_rm,
  output logic [2:0]                        d_dm,
  output logic                              d_zwdis,
  output logic                              d_quad,
  output logic [1:0]                        d_sum_op,
  output logic                              d_kill,
  output logic                              d_const_v [4],
  output logic                              d_const_in [4],
  output logic [P2_EDGE_T0_BITS-1:0]        d_t0 [4],
  output logic [P2_EDGE_STEP_BITS-1:0]      d_tx [4],
  output logic [P2_EDGE_STEP_BITS-1:0]      d_ty [4],
  output logic [P2_EDGE_ZSH_BITS-1:0]       d_zsh [4],
  output logic                              d_big [4],
  output logic [P2_EDGE_FAR_BITS-1:0]       d_far32 [4],
  output logic [P2_TILE_LOG2-1:0]           d_jf,
  output logic [P2_TILE_LOG2-1:0]           d_jl,
  output logic                              d_rows_v,
  output logic [1:0]                        d_regime,
  output logic [63:0]                       d_key,
  output logic [P2_ZT_REG_BITS-1:0]         d_r0,
  output logic [1:0]                        d_sa,
  output logic [1:0]                        d_sb,
  output logic [30:0]                       d_fa,
  output logic [30:0]                       d_fb,
  output logic [P2_ZT_S_BITS-1:0]           d_S,
  output logic [P2_ZT_STEP_BITS-1:0]        d_DX,
  output logic [P2_ZT_STEP_BITS-1:0]        d_DY,
  output logic [9:0]                        d_gexp,
  output logic [8:0]                        d_E,
  output logic [P2_ZT_NSH_BITS-1:0]         d_nsh,
  output logic                              d_fbw,
  // ---- ptc
  output logic                              pc_v,
  output logic                              pc_culled,
  output logic                              pc_quad,
  // ---- the program trace
  output logic                              t_issue,
  output logic [1:0]                        t_cls,
  output logic [P2_ISP_PC_BITS-1:0]         t_pc,
  output logic                              t_m_v [P2_ISP_NM],
  output logic [1:0]                        t_m_op [P2_ISP_NM],
  output logic                              t_m_swa [P2_ISP_NM],
  output logic [P2_ISP_RW-1:0]              t_m_ra [P2_ISP_NM],
  output logic [P2_ISP_RW-1:0]              t_m_rb [P2_ISP_NM],
  output logic [P2_ISP_RW-1:0]              t_m_rd [P2_ISP_NM],
  output logic                              t_a_v [P2_ISP_NA],
  output logic [1:0]                        t_a_op [P2_ISP_NA],
  output logic                              t_a_sub [P2_ISP_NA],
  output logic [1:0]                        t_a_post [P2_ISP_NA],
  output logic [P2_ISP_RW-1:0]              t_a_ra [P2_ISP_NA],
  output logic [P2_ISP_RW-1:0]              t_a_rb [P2_ISP_NA],
  output logic [P2_ISP_RW-1:0]              t_a_rd [P2_ISP_NA],
  output logic                              t_r_v,
  output logic [P2_ISP_RW-1:0]              t_r_ra,
  output logic [P2_ISP_RW-1:0]              t_r_rd,
  output logic                              t_wv [P2_ISP_NM + P2_ISP_NA + 1],
  output logic [P2_ISP_RW-1:0]              t_wrd [P2_ISP_NM + P2_ISP_NA + 1]
);
  p2_asm_t asm_i;
  always_comb begin
    asm_i       = '0;
    asm_i.isp   = a_isp;
    asm_i.tag   = p2_tag_t'(a_tag);
    asm_i.rm    = p2_rm_t'(a_rm);
    asm_i.quad  = a_quad;
    for (int q = 0; q < 4; q++) begin
      asm_i.x[q] = a_x[q];
      asm_i.y[q] = a_y[q];
    end
    for (int q = 0; q < 3; q++)
      asm_i.z[q] = a_z[q];
    asm_i.tilex = a_tilex;
    asm_i.tiley = a_tiley;
  end

  logic      rd_v, rd_rdy;
  p2_rdesc_t rd;
  p2_isp_uword_t                                       uw;
  logic [P2_ISP_NM+P2_ISP_NA:0]                        wv;
  logic [P2_ISP_NM+P2_ISP_NA:0][P2_ISP_RW-1:0]         wrd;
  p2_isp_setup u_setup (.clk(clk), .rst(rst), .asm_v(asm_v), .asm_rdy(asm_rdy), .asm_i(asm_i),
    .fpu_cull_val(fpu_cull_val), .fpu_perp_val(fpu_perp_val), .half(half), .rd_v(rd_v), .rd_rdy(rd_rdy), .rd(rd),
    .pc_v(pc_v), .pc_culled(pc_culled), .pc_quad(pc_quad), .t_issue(t_issue), .t_cls(t_cls), .t_pc(t_pc), .t_uw(uw),
    .t_wv(wv), .t_wrd(wrd));

  p2_zkey_t [P2_TILE-1:0] zkp;
  p2_tag_t                rtag;
  p2_rm_t                 rrm;
  p2_sum_op_t             rsum;
  p2_isp_raster u_raster (.clk(clk), .rst(rst), .rd_v(rd_v), .rd_rdy(rd_rdy), .rd(rd), .row_v(row_v), .out_rdy(out_rdy),
    .row_j(row_j), .in_mask(in_mask), .zk(zkp), .row_last(row_last), .row_tag(rtag), .row_rm(rrm),
    .row_depth_mode(row_dm), .row_zwdis(row_zwdis), .row_sum_op(rsum));
  assign row_tag    = rtag;
  assign row_rm     = rrm;
  assign row_sum_op = rsum;

  always_comb begin
    for (int q = 0; q < P2_TILE; q++)
      zk[q] = zkp[q];
    d_take   = rd_v && rd_rdy;
    d_tag    = rd.tag;
    d_rm     = rd.rm;
    d_dm     = rd.depth_mode;
    d_zwdis  = rd.zwdis;
    d_quad   = rd.quad;
    d_sum_op = rd.sum_op;
    d_kill   = rd.kill;
    for (int q = 0; q < 4; q++) begin
      d_const_v[q]  = rd.edges[q].const_v;
      d_const_in[q] = rd.edges[q].const_in;
      d_t0[q]       = rd.edges[q].t0;
      d_tx[q]       = rd.edges[q].tx;
      d_ty[q]       = rd.edges[q].ty;
      d_zsh[q]      = rd.edges[q].zsh;
      d_big[q]      = rd.edges[q].big;
      d_far32[q]    = rd.edges[q].far32;
    end
    d_jf     = rd.jf;
    d_jl     = rd.jl;
    d_rows_v = rd.rows_v;
    d_regime = rd.z.regime;
    d_key    = rd.z.key;
    d_r0     = rd.z.r0;
    d_sa     = rd.z.sa;
    d_sb     = rd.z.sb;
    d_fa     = rd.z.fa;
    d_fb     = rd.z.fb;
    d_S      = rd.z.S;
    d_DX     = rd.z.DX;
    d_DY     = rd.z.DY;
    d_gexp   = rd.z.gexp;
    d_E      = rd.z.E;
    d_nsh    = rd.z.nsh;
    d_fbw    = rd.z.fbw;
    for (int q = 0; q < P2_ISP_NM; q++) begin
      t_m_v[q]   = uw.m[q].v;
      t_m_op[q]  = uw.m[q].op;
      t_m_swa[q] = uw.m[q].swa;
      t_m_ra[q]  = uw.m[q].ra;
      t_m_rb[q]  = uw.m[q].rb;
      t_m_rd[q]  = uw.m[q].rd;
    end
    for (int q = 0; q < P2_ISP_NA; q++) begin
      t_a_v[q]    = uw.a[q].v;
      t_a_op[q]   = uw.a[q].op;
      t_a_sub[q]  = uw.a[q].sub;
      t_a_post[q] = uw.a[q].post;
      t_a_ra[q]   = uw.a[q].ra;
      t_a_rb[q]   = uw.a[q].rb;
      t_a_rd[q]   = uw.a[q].rd;
    end
    t_r_v  = uw.r.v;
    t_r_ra = uw.r.ra;
    t_r_rd = uw.r.rd;
    for (int q = 0; q <= P2_ISP_NM + P2_ISP_NA; q++) begin
      t_wv[q]  = wv[q];
      t_wrd[q] = wrd[q];
    end
  end
endmodule

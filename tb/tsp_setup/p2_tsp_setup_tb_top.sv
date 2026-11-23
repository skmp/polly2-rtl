// p2_tsp_setup_tb_top: make tsp-setup (tb/tsp_setup/tsp_setup_tb.cpp, PLAN M9). The TSP's set-up side wired as
// ARCHITECTURE 1.1 / 3.7 draws it, with flat ports for the testbench:
//
//   the sorter's items ──► p2_tsp_store (SRQ, look-ahead, entries, pins) ──► the SRQ's head  [run start: the testbench]
//                              │ jobs                     ▲ writes   └── read port            [reads every word, compares,
//                              ▼                          │                                    releases the pins later]
//                          p2_tsp_pfetch ──► p2_tsp_setup ┘ ◄── p2_tsp_alu (hold: run start's use of the ALU)
//                              │ C3
//                              ▼
//                          p2_mem ──► the two VRAM halves (the testbench's VRAM model)
//
// p2_mem's other clients are tied off. The testbench drives the render's registers, pushes the items, holds the ALU on
// random clocks (as run start will), pops the head, reads the entries through the read port and releases their pins
// after a random delay (as the pixel pipe's last store read will).
module p2_tsp_setup_tb_top
  import p2_pkg::*;
  import p2_regs_pkg::*;
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
  // ---- the sorter's items
  input  logic                              in_v,
  output logic                              in_rdy,
  input  logic                              in_null,
  input  logic [31:0]                       in_tag,
  input  logic [4:0]                        in_y,
  input  logic [4:0]                        in_x,
  input  logic [4:0]                        in_lenm1,
  input  logic [2:0]                        in_rm,
  input  logic [6:0]                        in_epoch,
  input  logic [31:0]                       in_vmask,
  input  logic [31:0]                       in_pmask,
  input  logic                              in_eop,
  input  logic                              in_eoe,
  input  logic                              in_nd,
  // ---- the SRQ's head
  output logic                              out_v,
  input  logic                              out_rdy,
  output logic                              out_null,
  output logic [31:0]                       out_tag,
  output logic [4:0]                        out_x,
  output logic [4:0]                        out_lenm1,
  output logic [31:0]                       out_vmask,
  output logic                              out_nd,
  output logic [1:0]                        out_need,
  output logic [3:0]                        out_idx0,
  output logic [3:0]                        out_idx1,
  input  logic                              rel_v,
  input  logic [1:0]                        rel_need,
  input  logic [3:0]                        rel_idx0,
  input  logic [3:0]                        rel_idx1,
  input  logic                              hold,
  // ---- the read port
  input  logic                              rd_v,
  input  logic [3:0]                        rd_idx,
  input  logic [3:0]                        rd_word,
  output logic [31:0]                       rh_isp,
  output logic [31:0]                       rh_tsp,
  output logic [31:0]                       rh_tcw,
  output logic [31:0]                       rh_colfb,
  output logic [31:0]                       rh_ofsfb,
  output logic [3:0]                        rh_cls,
  output logic                              rk_neg,
  output logic                              rk_bad,
  output logic [9:0]                        rk_exp,
  output logic [7:0]                        rk_mant,
  output logic                              rk_dz,
  output logic [2:0]                        rp_neg,       // A, B, C
  output logic [2:0]                        rp_bad,
  output logic [9:0]                        rp_exp [3],
  output logic [15:0]                       rp_mant [3],
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
  output logic                              t_issue,
  output logic [3:0]                        t_cls,
  output logic [5:0]                        t_pc,
  output logic                              t_accept,     // a job's accept in p2_tsp_setup
  output logic                              t_done,
  output logic                              t_job,
  output logic                              t_hit,
  output logic                              t_la_wait,
  output logic [4:0]                        t_pinned,
  output logic [5:0]                        t_srq,
  output logic                              t_fetch_idle,
  output logic                              t_setup_idle
);
  p2_rs_t in_item, out_item;
  always_comb begin
    in_item        = '0;
    in_item.null_  = in_null;
    in_item.tag    = p2_tag_t'(in_tag);
    in_item.y      = in_y;
    in_item.x      = in_x;
    in_item.lenm1  = in_lenm1;
    in_item.rm     = p2_rm_t'(in_rm);
    in_item.epoch  = in_epoch;
    in_item.vmask  = in_vmask;
    in_item.pmask  = in_pmask;
    in_item.eop    = in_eop;
    in_item.eoe    = in_eoe;
  end
  assign out_null  = out_item.null_;
  assign out_tag   = out_item.tag;
  assign out_x     = out_item.x;
  assign out_lenm1 = out_item.lenm1;
  assign out_vmask = out_item.vmask;

  // ---------------------------------------------------------------------------------------------- the store
  logic                  jb_v, jb_rdy;
  p2_tsp_job_t           jb;
  logic                  sh_v, sp_v, sk_v, done;
  logic [3:0]            sh_idx, sp_idx, sk_idx, done_idx, sp_plane;
  p2_tsp_hdr_t           sh_w, rd_hdr;
  p2_tsp_plane_t         sp_w, rd_plane;
  p2_tsp_k_t             sk_w, rd_k;
  logic [1:0][3:0]       oidx;
  p2_tsp_store u_store (
    .clk, .rst, .flush,
    .in_v, .in_rdy, .in_item, .in_nd,
    .out_v, .out_rdy, .out_item, .out_nd, .out_need, .out_idx(oidx),
    .rel_v, .rel_need, .rel_idx({rel_idx1, rel_idx0}),
    .jb_v, .jb_rdy, .jb,
    .sh_v, .sh_idx, .sh_w, .sp_v, .sp_idx, .sp_plane, .sp_w, .sk_v, .sk_idx, .sk_w, .done, .done_idx,
    .rd_v, .rd_idx, .rd_word, .rd_hdr, .rd_k, .rd_plane,
    .rw_v(1'b0), .rw_idx('0), .rw_row('0), .rw_hdr(), .rw_k(), .rw_plane(),     // run start's row read (M10)
    .t_srq, .t_pinned, .t_la_wait, .t_job, .t_hit);
  assign out_idx0 = oidx[0];
  assign out_idx1 = oidx[1];

  assign rh_isp   = rd_hdr.isp;
  assign rh_tsp   = rd_hdr.tsp;
  assign rh_tcw   = rd_hdr.tcw;
  assign rh_colfb = rd_hdr.col_fb;
  assign rh_ofsfb = rd_hdr.ofs_fb;
  assign rh_cls   = rd_hdr.cls;
  assign rk_neg   = rd_k.k8.neg;
  assign rk_bad   = rd_k.k8.bad;
  assign rk_exp   = rd_k.k8.exp;
  assign rk_mant  = rd_k.k8.mant;
  assign rk_dz    = rd_k.dz;
  always_comb begin
    rp_neg = {rd_plane.c.neg, rd_plane.b.neg, rd_plane.a.neg};
    rp_bad = {rd_plane.c.bad, rd_plane.b.bad, rd_plane.a.bad};
    rp_exp[0] = rd_plane.a.exp;   rp_mant[0] = rd_plane.a.mant;
    rp_exp[1] = rd_plane.b.exp;   rp_mant[1] = rd_plane.b.mant;
    rp_exp[2] = rd_plane.c.exp;   rp_mant[2] = rd_plane.c.mant;
  end

  // ---------------------------------------------------------------------------------------------- fetch (C3), setup
  localparam int NC = 6;
  logic [NC-1:0]        c_v, c_rdy, c_we, c_w64, c_rv, c_rrdy;
  logic [NC-1:0][23:0]  c_addr;
  logic [NC-1:0][7:0]   c_be;
  logic [NC-1:0][63:0]  c_wdata, c_rdata;
  logic                 m3_v, m3_rrdy;
  logic [23:0]          m3_addr;

  logic         pr_v, pr_rdy;
  p2_tsp_prim_t pr;
  p2_tsp_pfetch u_pfetch (
    .clk, .rst, .jb_v, .jb_rdy, .jb, .param_base, .shad_intensity(fpu_shad_scale[8]),
    .pr_v, .pr_rdy, .pr, .idle(t_fetch_idle),
    .m_v(m3_v), .m_rdy(c_rdy[P2_C_TSP_PFETCH]), .m_addr(m3_addr), .m_rv(c_rv[P2_C_TSP_PFETCH]), .m_rrdy(m3_rrdy),
    .m_rdata(c_rdata[P2_C_TSP_PFETCH][31:0]));

  p2_tsp_uword_t uw_tap;
  logic [P2_TSP_PC_BITS-1:0] pc_tap;
  p2_tsp_setup u_setup (
    .clk, .rst, .pr_v, .pr_rdy, .pr, .fpu_shad_scale, .fpu_perp_val, .hold, .rs_a('0), .rs_b('0), .rs_p(),
    .sh_v, .sh_idx, .sh_w, .sp_v, .sp_idx, .sp_plane, .sp_w, .sk_v, .sk_idx, .sk_w, .done, .done_idx,
    .idle(t_setup_idle), .t_issue, .t_cls, .t_pc(pc_tap), .t_uw(uw_tap), .t_wv(), .t_wrd());
  assign t_pc     = 6'(pc_tap);
  assign t_accept = sh_v;
  assign t_done   = done;

  always_comb begin
    c_v     = '0;
    c_addr  = '0;
    c_rrdy  = '1;
    c_v[P2_C_TSP_PFETCH]    = m3_v;
    c_addr[P2_C_TSP_PFETCH] = m3_addr;
    c_rrdy[P2_C_TSP_PFETCH] = m3_rrdy;
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
endmodule

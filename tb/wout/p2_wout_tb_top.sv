// p2_wout_tb_top: make wout (tb/wout/wout_tb.cpp, PLAN M12 "make wout"): the tile buffers (p2_tbuf), their controller
// (p2_tbuf_ctl) and the write-out (p2_wout, p2_wout_put) on C5 of p2_mem, with the VRAM model, as p2_core has them. The
// testbench is the pixel pipe: it writes each entry's tile into buffer 1 through p2_tbuf's debug port (once the
// controller's action before has been done: `hold` low, as P10 waits for it), pushes the entry's record into p2_entq and
// sends its eoe point (`p10_eoe`); it steals the secondary port at random (P10's reads of buffer 2, `p10_re`).
module p2_wout_tb_top
  import p2_pkg::*;
  import p2_regs_pkg::*;
(
  input  logic         clk,
  input  logic         rst,
  input  logic         flush,
  input  logic [31:0]  fb_w_ctrl,
  input  logic [31:0]  fb_w_linestride,
  input  logic [31:0]  fb_w_sof1,
  input  logic [31:0]  fb_w_sof2,
  input  logic [31:0]  fb_x_clip,
  input  logic [31:0]  fb_y_clip,
  input  logic [31:0]  fb_r_ctrl,
  input  logic [31:0]  scaler_ctl,
  input  logic [31:0]  y_coeff,
  // the entry records (p2_entq) and the eoe points
  input  logic         eq_push,
  output logic         eq_full,
  input  logic [5:0]   eq_tilex,
  input  logic [5:0]   eq_tiley,
  input  logic         eq_z_keep,
  input  logic         eq_no_writeout,
  input  logic         eq_last,
  input  logic         eq_shaded_any,
  input  logic         p10_eoe,
  // P10's reads of buffer 2 (the secondary port's other user)
  input  logic         p10_re,
  input  logic [9:0]   p10_idx,
  // the buffers' debug port
  input  logic         dbg_we,
  input  logic         dbg_b2,
  input  logic [9:0]   dbg_idx,
  input  logic [31:0]  dbg_wdata,
  output logic [31:0]  dbg_b1,
  output logic [31:0]  dbg_b2_data,
  // taps
  output logic         hold,
  output logic         swap,
  output logic         sel,
  output logic         wo_busy,
  output logic         wo_start,
  output logic         ev_tsp,
  output logic         ev_vid,
  output logic         ctl_idle,
  // VRAM
  output logic [1:0]   vh_req_v,
  input  logic [1:0]   vh_req_rdy,
  output logic [1:0]   vh_req_we,
  output logic [19:0]  vh_req_idx [2],
  output logic [3:0]   vh_req_be [2],
  output logic [31:0]  vh_req_wdata [2],
  output logic [2:0]   vh_req_src [2],
  input  logic [1:0]   vh_rsp_v,
  input  logic [31:0]  vh_rsp_data [2],
  input  logic [2:0]   vh_rsp_src [2]
);
  p2_entrec_t eqi, eqo;
  logic       eq_rdy_i, eqo_v, eqo_rdy;
  always_comb begin
    eqi             = '0;
    eqi.tilex       = eq_tilex;
    eqi.tiley       = eq_tiley;
    eqi.z_keep      = eq_z_keep;
    eqi.no_writeout = eq_no_writeout;
    eqi.last        = eq_last;
    eqi.shaded_any  = eq_shaded_any;
  end
  p2_isp_entq u_entq (.clk, .rst, .in_v(eq_push), .in_rdy(eq_rdy_i), .in_d(eqi), .out_v(eqo_v), .out_rdy(eqo_rdy),
    .out_d(eqo));
  assign eq_full = !eq_rdy_i;

  logic        wo_eof, wo_rd_done, wo_re, wo_gnt;
  logic [5:0]  wo_tx, wo_ty;
  logic [9:0]  wo_idx;
  logic [31:0] wo_data;
  p2_tbuf_ctl u_tctl (.clk, .rst, .flush, .p10_eoe, .eq_v(eqo_v), .eq_rdy(eqo_rdy), .eq(eqo), .swap, .hold, .wo_start,
    .wo_tx, .wo_ty, .wo_eof, .wo_busy, .wo_rd_done, .ev_tsp, .ev_vid, .idle(ctl_idle));

  logic        m5_v;
  logic [23:0] m5_addr;
  logic [3:0]  m5_be;
  logic [31:0] m5_wdata;
  p2_wout u_wout (.clk, .rst, .flush, .fb_w_ctrl, .fb_w_linestride, .fb_w_sof1, .fb_w_sof2, .fb_x_clip, .fb_y_clip,
    .fb_r_ctrl, .scaler_ctl, .y_coeff, .start(wo_start), .tx(wo_tx), .ty(wo_ty), .eof(wo_eof), .busy(wo_busy),
    .rd_done(wo_rd_done), .rd_re(wo_re), .rd_idx(wo_idx), .rd_gnt(wo_gnt), .rd_data(wo_data),
    .m_v(m5_v), .m_rdy(c_rdy[P2_C_WOUT]), .m_addr(m5_addr), .m_be(m5_be), .m_wdata(m5_wdata));

  p2_tbuf u_tbuf (.clk, .rst, .swap, .sel,
    .rd_en(p10_re), .rd_idx(p10_idx), .rd_b2(1'b1), .rd_b1_data(), .rd_b2_data(),
    .wr_en(1'b0), .wr_b2(1'b0), .wr_idx('0), .wr_data('0),
    .wo_re, .wo_idx, .wo_gnt, .wo_data,
    .dbg_we, .dbg_b2, .dbg_idx, .dbg_wdata, .dbg_b1, .dbg_b2_data);

  // ---------------------------------------------------------------------------------------------- p2_mem, C5 alone
  localparam int NC = 6;
  logic [NC-1:0]        c_v, c_rdy, c_we, c_w64, c_rv, c_rrdy;
  logic [NC-1:0][23:0]  c_addr;
  logic [NC-1:0][7:0]   c_be;
  logic [NC-1:0][63:0]  c_wdata, c_rdata;
  always_comb begin
    c_v     = '0;
    c_addr  = '0;
    c_rrdy  = '1;
    c_we    = '0;
    c_w64   = '0;
    c_be    = '1;
    c_wdata = '0;
    c_v[P2_C_WOUT]     = m5_v;
    c_addr[P2_C_WOUT]  = m5_addr;
    c_we[P2_C_WOUT]    = 1'b1;
    c_be[P2_C_WOUT]    = {4'd0, m5_be};
    c_wdata[P2_C_WOUT] = {32'd0, m5_wdata};
  end
  logic [1:0][19:0] vidx;
  logic [1:0][3:0]  vbe;
  logic [1:0][31:0] vwd, vrd;
  logic [1:0][2:0]  vsrc, vrsrc;
  p2_mem #(.NC(NC)) u_mem (.clk, .rst, .c_v, .c_rdy, .c_we, .c_w64, .c_addr, .c_be, .c_wdata, .c_rv, .c_rrdy, .c_rdata,
    .vh_req_v, .vh_req_rdy, .vh_req_we, .vh_req_idx(vidx), .vh_req_be(vbe), .vh_req_wdata(vwd), .vh_req_src(vsrc),
    .vh_rsp_v, .vh_rsp_data(vrd), .vh_rsp_src(vrsrc));
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

// p2_regs: the CORE's register block (PLAN M12; ARCHITECTURE 3.1, 1.2, 1.3): the 8 KB block 0x000-0x1FFC on one register
// port, the fields the units read as live wires, FOG_TABLE and PALETTE_RAM forwarded to the RAMs that hold them, and
// the start / soft-reset pulses. Owns isp 2 and tsp 0 (the register tables; nulldc3 libswirl/hw/pvr/pvr_regs.h, field
// layout p2_regs_pkg, generated).
//
//   write   reg_wr: the word at reg_addr takes reg_wdata at the next edge (a write takes effect at the next edge)
//             STARTRENDER (0x014)   `start`, a 1-clock pulse the clock after the write (the register keeps no value:
//                                   refsw3-offline's reg_write never stores it, main.cpp)
//             SOFTRESET (0x008)     `soft_rst` when bit 1 is set (ARCHITECTURE 1.3 item 5); bit 0 is the TA's (out of
//                                   scope, conv G7); the register reads 0 afterwards (main.cpp stores 0)
//             ID, REVISION          read-only: writes are dropped (main.cpp reg_write); they read 0x17FD11DB and
//                                   0x00000011 (main.cpp reset_all; M13, M12's open item)
//             FOG_TABLE 0x200-0x3FC the 128 x 16-bit fog table (p2_pp_fog's RAM): ft_we, its low 16 bits
//             PALETTE_RAM 0x1000-   the 1024 x 32 palette (p2_tex_pal's RAM): pal_we
//   read    reg_rd: reg_rdata one clock later: the word as last written, from the read-back RAM (one write and one read
//           port, 2048 x 32; every word of the block, the tables included). Reads have no side effect.
//   live    every register a unit reads is a flip-flop copy here, read where it is used (refsw3 reads them at the time of
//           use; ARCHITECTURE 3.1: a CPU write during a render other than to the palette and the fog table is GAP and out
//           of scope for p2-offline). No arithmetic here: each consumer decodes its own fields.
// soft_rst does not clear the register file [M pvr-renderer: 0 of 20 registers changed].
module p2_regs
  import p2_regs_pkg::*;
(
  input  logic         clk,
  input  logic         rst,
  // the register port (ARCHITECTURE 1.2)
  input  logic         reg_wr,
  input  logic         reg_rd,
  input  logic [12:2]  reg_addr,
  input  logic [31:0]  reg_wdata,
  output logic [31:0]  reg_rdata,
  // events
  output logic         start,
  output logic         soft_rst,
  // the tables' write ports
  output logic         pal_we,
  output logic [9:0]   pal_widx,
  output logic [31:0]  pal_wdata,
  output logic         ft_we,
  output logic [6:0]   ft_idx,
  output logic [15:0]  ft_wdata,
  // live registers
  output logic [31:0]  param_base,
  output logic [31:0]  region_base,
  output logic [31:0]  span_sort_cfg,
  output logic [31:0]  fb_r_ctrl,
  output logic [31:0]  fb_w_ctrl,
  output logic [31:0]  fb_w_linestride,
  output logic [31:0]  fb_w_sof1,
  output logic [31:0]  fb_w_sof2,
  output logic [31:0]  fb_x_clip,
  output logic [31:0]  fb_y_clip,
  output logic [31:0]  fpu_shad_scale,
  output logic [31:0]  fpu_cull_val,
  output logic [31:0]  fpu_param_cfg,
  output logic [31:0]  half_offset,
  output logic [31:0]  fpu_perp_val,
  output logic [31:0]  isp_backgnd_d,
  output logic [31:0]  isp_backgnd_t,
  output logic [31:0]  isp_feed_cfg,
  output logic [31:0]  fog_col_ram,
  output logic [31:0]  fog_col_vert,
  output logic [31:0]  fog_density,
  output logic [31:0]  fog_clamp_max,
  output logic [31:0]  fog_clamp_min,
  output logic [31:0]  text_control,
  output logic [31:0]  scaler_ctl,
  output logic [31:0]  pal_ram_ctrl,
  output logic [31:0]  y_coeff,
  output logic [31:0]  pt_alpha_ref
);
  logic [12:0] a;
  assign a = {reg_addr, 2'b00};

  // ---------------------------------------------------------------------------------------------- the stored word
  logic        ro, wr_ok;
  logic [31:0] wv;
  assign ro    = a == P2_REG_ID || a == P2_REG_REVISION;
  assign wr_ok = reg_wr && !ro && a != P2_REG_STARTRENDER;
  assign wv    = a == P2_REG_SOFTRESET ? 32'd0 : reg_wdata;

  // the read-back RAM: one write, one registered read; ID and REVISION are constants, chosen after the RAM's output
  // register (the RAM keeps its registered read: conventions 4.2)
  logic [31:0] rb [2048];
  logic [31:0] rb_q;
  logic [1:0]  rd_k;
  always_ff @(posedge clk) begin
    if (wr_ok) rb[reg_addr] <= wv;
    if (reg_rd) begin
      rb_q <= rb[reg_addr];
      rd_k <= a == P2_REG_ID ? 2'd1 : (a == P2_REG_REVISION ? 2'd2 : 2'd0);
    end
  end
  assign reg_rdata = rd_k == 2'd1 ? 32'h17FD11DB : (rd_k == 2'd2 ? 32'h00000011 : rb_q);

  // ---------------------------------------------------------------------------------------------- pulses, tables
  always_ff @(posedge clk) begin
    if (rst) begin
      start    <= 1'b0;
      soft_rst <= 1'b0;
      pal_we   <= 1'b0;
      ft_we    <= 1'b0;
    end else begin
      start    <= reg_wr && a == P2_REG_STARTRENDER;
      soft_rst <= reg_wr && a == P2_REG_SOFTRESET && reg_wdata[1];
      pal_we   <= reg_wr && a >= P2_REG_PALETTE_RAM_START;
      ft_we    <= reg_wr && a >= P2_REG_FOG_TABLE_START && a <= P2_REG_FOG_TABLE_END;
    end
    pal_widx  <= reg_addr[11:2];
    pal_wdata <= reg_wdata;
    ft_idx    <= reg_addr[8:2];
    ft_wdata  <= reg_wdata[15:0];
  end

  // ---------------------------------------------------------------------------------------------- live registers
  always_ff @(posedge clk)
    if (reg_wr)
      case (a)
        P2_REG_PARAM_BASE:      param_base      <= reg_wdata;
        P2_REG_REGION_BASE:     region_base     <= reg_wdata;
        P2_REG_SPAN_SORT_CFG:   span_sort_cfg   <= reg_wdata;
        P2_REG_FB_R_CTRL:       fb_r_ctrl       <= reg_wdata;
        P2_REG_FB_W_CTRL:       fb_w_ctrl       <= reg_wdata;
        P2_REG_FB_W_LINESTRIDE: fb_w_linestride <= reg_wdata;
        P2_REG_FB_W_SOF1:       fb_w_sof1       <= reg_wdata;
        P2_REG_FB_W_SOF2:       fb_w_sof2       <= reg_wdata;
        P2_REG_FB_X_CLIP:       fb_x_clip       <= reg_wdata;
        P2_REG_FB_Y_CLIP:       fb_y_clip       <= reg_wdata;
        P2_REG_FPU_SHAD_SCALE:  fpu_shad_scale  <= reg_wdata;
        P2_REG_FPU_CULL_VAL:    fpu_cull_val    <= reg_wdata;
        P2_REG_FPU_PARAM_CFG:   fpu_param_cfg   <= reg_wdata;
        P2_REG_HALF_OFFSET:     half_offset     <= reg_wdata;
        P2_REG_FPU_PERP_VAL:    fpu_perp_val    <= reg_wdata;
        P2_REG_ISP_BACKGND_D:   isp_backgnd_d   <= reg_wdata;
        P2_REG_ISP_BACKGND_T:   isp_backgnd_t   <= reg_wdata;
        P2_REG_ISP_FEED_CFG:    isp_feed_cfg    <= reg_wdata;
        P2_REG_FOG_COL_RAM:     fog_col_ram     <= reg_wdata;
        P2_REG_FOG_COL_VERT:    fog_col_vert    <= reg_wdata;
        P2_REG_FOG_DENSITY:     fog_density     <= reg_wdata;
        P2_REG_FOG_CLAMP_MAX:   fog_clamp_max   <= reg_wdata;
        P2_REG_FOG_CLAMP_MIN:   fog_clamp_min   <= reg_wdata;
        P2_REG_TEXT_CONTROL:    text_control    <= reg_wdata;
        P2_REG_SCALER_CTL:      scaler_ctl      <= reg_wdata;
        P2_REG_PAL_RAM_CTRL:    pal_ram_ctrl    <= reg_wdata;
        P2_REG_Y_COEFF:         y_coeff         <= reg_wdata;
        P2_REG_PT_ALPHA_REF:    pt_alpha_ref    <= reg_wdata;
        default: ;
      endcase
endmodule

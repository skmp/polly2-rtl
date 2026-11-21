// p2_isp_buf: the ISP's per-pixel state of one tile (PLAN M6, M7; ARCHITECTURE 3.4.7; isp 10.1, 11.2, 11.4, 11.6, 13;
// refcore refsw_tile.cpp depthBuffer / tagBuffer / stencilBuffer / tagStatus, opTag, refTagC, resPass, resTag,
// resDepth, everRendered, savedDepth and the buffer operations ClearBuffers, ClearParamStatusBuffer,
// PeelBuffersPTInitial, PeelBuffersPTChunk, PeelBuffersPTFinal, PeelBuffers, SaveDepth, SaveDepthAt, RestoreDepth at
// refsw3 4f3efe15). 32 rows x 32 lanes, read and written a row at a time.
//
// Storage (ARCHITECTURE 3.4.7's table). Wide fields are RAMs, one per lane and field (p2_isp_lram; conventions 4.2):
//   depthA   64 (p2_zkey_t)  2 read copies: F (raster R1, sweeps, feedback) and C (the cutter); both written together
//   tagA     32              as depthA. All 32 bits: ClearBuffers(ISP_BACKGND_T.full) keeps a background tag's bits
//                            31:29 (pvr-tests/bgtie, scenegen BGTAG), and 0xFFFFFFFF IS TAG_BELOW (KeyAbove)
//   depthB, tagB             the punch-through boundary / the translucent sort's reference (PEEL, PT_INIT / PT_CHUNK:
//                            tagB = TAG_BELOW, the feedback)
//   depthC, refTagC, opTag   the punch-through passes' opaque layer (PT_INIT, PT_CHUNK)
//   resTag                   the feedback's resolved tag
//   rsd      64              resDepth (punch-through) and savedDepth (translucent sort) in one array [A: resDepth is
//                            live in the PT phases, savedDepth from SAVE to RESTORE, never both; tb/common/isp_live.h]
// Narrow fields are flip-flops: stencil[2:0] (bit 0 the volume status, 1 the parity, 2 touched), valid, rendered,
// rcur / rlp (refsw3's resPass as "resolved in this pass" / "in the pass before": ptResolvedLastPass is
// resPass == PtPass - 1; PASS_START moves rcur into rlp), everRendered.
//
// Ports. Every non-C RAM read goes to one row address: the sweep engine's while it runs, else the feedback's, else the
// raster's (ctl issues raster work, sweeps and punch-through SHADEs one after the other, so only one of them reads at
// a time):
//   F read    f_re / f_row: depthA, tagA, depthB, tagB, depthC, refTagC of the row the next clock (raster R1)
//   N read    n_row: the row's stencil, valid, rendered, rlp combinationally (flip-flops)
//   C read    c_re / c_row: depthA, tagA of the C copy the next clock (the cutter); the flip-flop arrays whole (k_*)
//   write     raster R2 (depthA, tagA, valid per lane, the stencil a row); the sweep engine; the cutter (valid = 0 in
//             TR_PRESORT, savedDepth = depthA in TR_AUTOSORT); the feedback (one pixel); the debug port (sim). Two of them
//             never write one row in one clock: raster, sweeps and feedback by ctl's order, the cutter against the others
//             by the row barrier (checked)
//   sweeps    two stages, one row a clock over the 32 rows [G; GAP T13]: A issues the row's reads, B writes the row
//             (33 clocks); a row starts only when the row barrier lets it (bar_ok: the cutter has passed it)
//   debug     sim only: a row of every field combinationally, and a row write of every field
module p2_isp_buf
  import p2_pkg::*;
(
  input  logic                              clk,
  input  logic                              rst,
  // F read (raster R0 -> R1)
  input  logic                              f_re,
  input  logic [P2_TILE_LOG2-1:0]           f_row,
  output p2_zkey_t [P2_TILE-1:0]            f_depth,
  output logic [P2_TILE-1:0][31:0]          f_tag,
  output p2_zkey_t [P2_TILE-1:0]            f_depth_b,
  output logic [P2_TILE-1:0][31:0]          f_tag_b,
  output p2_zkey_t [P2_TILE-1:0]            f_depth_c,
  output logic [P2_TILE-1:0][31:0]          f_reftag_c,
  // N read
  input  logic [P2_TILE_LOG2-1:0]           n_row,
  output logic [P2_TILE-1:0][2:0]           n_stencil,
  output logic [P2_TILE-1:0]                n_valid,
  output logic [P2_TILE-1:0]                n_rendered,
  output logic [P2_TILE-1:0]                n_rlp,
  // C read (the cutter)
  input  logic                              c_re,
  input  logic [P2_TILE_LOG2-1:0]           c_row,
  output p2_zkey_t [P2_TILE-1:0]            c_depth,
  output logic [P2_TILE-1:0][31:0]          c_tag,
  output logic [P2_TILE-1:0][P2_TILE-1:0]   k_valid,      // [row][lane]
  output logic [P2_TILE-1:0][P2_TILE-1:0]   k_st0,
  output logic [P2_TILE-1:0][P2_TILE-1:0]   k_rendered,
  // the raster's write port (R2)
  input  logic                              w_v,
  input  logic [P2_TILE_LOG2-1:0]           w_row,
  input  logic [P2_TILE-1:0]                w_dwe,
  input  logic [P2_TILE-1:0]                w_twe,
  input  p2_zkey_t [P2_TILE-1:0]            w_depth,
  input  logic [P2_TILE-1:0][31:0]          w_tag,
  input  logic                              w_swe,
  input  logic [P2_TILE-1:0][2:0]           w_stencil,
  input  logic [P2_TILE-1:0]                w_vwe,
  input  logic [P2_TILE-1:0]                w_valid,
  // the cutter's writes
  input  logic                              cv_we,        // valid = 0 on these lanes (TR_PRESORT)
  input  logic [P2_TILE_LOG2-1:0]           cv_row,
  input  logic [P2_TILE-1:0]                cv_lane,
  input  logic                              cs_we,        // savedDepth = cs_data on these lanes (TR_AUTOSORT)
  input  logic [P2_TILE_LOG2-1:0]           cs_row,
  input  logic [P2_TILE-1:0]                cs_lane,
  input  p2_zkey_t [P2_TILE-1:0]            cs_data,
  // the feedback (p2_isp_fb): its read of depthA / tagA (F port, data the next clock), then its write of one pixel
  input  logic                              fb_re,
  input  logic [P2_TILE_LOG2-1:0]           fb_row,
  input  logic                              fbw_v,
  input  logic [P2_TILE_LOG2-1:0]           fbw_row,
  input  logic [P2_TILE-1:0]                fbw_lane,     // one-hot
  input  logic                              fbw_pass,     // the alpha test passed (not run-only, not failed)
  input  p2_zkey_t                          fbw_depth,    // the pixel's depthA
  input  logic [31:0]                       fbw_tag,      // the pixel's tagA
  // sweeps (p2_isp_ctl)
  input  logic                              sw_v,
  input  p2_sweep_t                         sw_op,
  input  p2_zkey_t                          sw_key,
  input  logic [31:0]                       sw_tag,
  output logic                              sw_busy,
  // the row barrier (p2_isp_cut): the rows a later epoch may write
  input  logic [P2_TILE-1:0]                bar_ok,
  // debug (sim)
  input  logic [P2_TILE_LOG2-1:0]           dbg_row,
  output p2_zkey_t [P2_TILE-1:0]            dbg_depth,
  output logic [P2_TILE-1:0][31:0]          dbg_tag,
  output p2_zkey_t [P2_TILE-1:0]            dbg_depth_b,
  output logic [P2_TILE-1:0][31:0]          dbg_tag_b,
  output p2_zkey_t [P2_TILE-1:0]            dbg_depth_c,
  output logic [P2_TILE-1:0][31:0]          dbg_reftag_c,
  output logic [P2_TILE-1:0][31:0]          dbg_optag,
  output logic [P2_TILE-1:0][31:0]          dbg_restag,
  output p2_zkey_t [P2_TILE-1:0]            dbg_rsd,
  output logic [P2_TILE-1:0][2:0]           dbg_stencil,
  output logic [P2_TILE-1:0]                dbg_valid,
  output logic [P2_TILE-1:0]                dbg_rendered,
  output logic [P2_TILE-1:0]                dbg_rcur,
  output logic [P2_TILE-1:0]                dbg_rlp,
  output logic [P2_TILE-1:0]                dbg_ever,
  input  logic                              dbg_we,
  input  p2_zkey_t [P2_TILE-1:0]            dbg_wdepth,
  input  logic [P2_TILE-1:0][31:0]          dbg_wtag,
  input  p2_zkey_t [P2_TILE-1:0]            dbg_wdepth_b,
  input  logic [P2_TILE-1:0][31:0]          dbg_wtag_b,
  input  p2_zkey_t [P2_TILE-1:0]            dbg_wdepth_c,
  input  logic [P2_TILE-1:0][31:0]          dbg_wreftag_c,
  input  logic [P2_TILE-1:0][31:0]          dbg_woptag,
  input  logic [P2_TILE-1:0][31:0]          dbg_wrestag,
  input  p2_zkey_t [P2_TILE-1:0]            dbg_wrsd,
  input  logic [P2_TILE-1:0][2:0]           dbg_wstencil,
  input  logic [P2_TILE-1:0]                dbg_wvalid,
  input  logic [P2_TILE-1:0]                dbg_wrendered,
  input  logic [P2_TILE-1:0]                dbg_wrcur,
  input  logic [P2_TILE-1:0]                dbg_wrlp,
  input  logic [P2_TILE-1:0]                dbg_wever
);
  localparam int TAG_BITS = 32;     // ISP_BACKGND_T.full (refsw_tile.cpp ClearBuffers)
  localparam logic [31:0] BELOW = P2_TAG_BELOW;
  typedef logic [P2_TILE-1:0] lanes_t;

  // ---------------------------------------------------------------------------------------------- the sweep engine
  logic                    sa_act, sb_v;
  p2_sweep_t               sw_q;
  logic [P2_TILE_LOG2-1:0] sa_row, sb_row;
  p2_zkey_t                sw_k;
  logic [31:0]             sw_t;
  logic                    sa_go;
  assign sa_go   = sa_act && bar_ok[sa_row];
  assign sw_busy = sa_act || sb_v;
  always_ff @(posedge clk) begin
    if (rst) begin
      sa_act <= 1'b0;
      sb_v   <= 1'b0;
    end else begin
      sb_v <= sa_go;
      if (sa_go) begin
        sb_row <= sa_row;
        sa_row <= sa_row + 1'b1;
        if (sa_row == '1)
          sa_act <= 1'b0;
      end
      if (sw_v && !sw_busy) begin
        sa_act <= 1'b1;
        sw_q   <= sw_op;
        sa_row <= '0;
        sw_k   <= sw_key;
        sw_t   <= sw_tag;
      end
    end
  end

  // ---------------------------------------------------------------------------------------------- the reads
  logic                    rd_re;
  logic [P2_TILE_LOG2-1:0] rd_row;
  always_comb begin
    rd_re  = sa_go || fb_re || f_re;
    rd_row = sa_go ? sa_row : (fb_re ? fb_row : f_row);
  end
  // the RAMs' read data (F copy and the others), for the raster, the feedback and the sweep's stage B
  p2_zkey_t [P2_TILE-1:0]   q_da, q_db, q_dc, q_rsd;
  logic [P2_TILE-1:0][31:0] q_ta, q_tb, q_rtc, q_opt, q_rst;
  assign f_depth    = q_da;
  assign f_tag      = q_ta;
  assign f_depth_b  = q_db;
  assign f_tag_b    = q_tb;
  assign f_depth_c  = q_dc;
  assign f_reftag_c = q_rtc;

  // ---------------------------------------------------------------------------------------------- the flip-flops
  logic [P2_TILE-1:0][P2_TILE-1:0][2:0] st;     // [row][lane]
  logic [P2_TILE-1:0][P2_TILE-1:0]      vl, rn, rc, rl, ev;
  lanes_t b_rn, b_ev, b_rc;                     // stage B's row of them
  assign b_rn = rn[sb_row];
  assign b_ev = ev[sb_row];
  assign b_rc = rc[sb_row];

  // ---------------------------------------------------------------------------------------------- the RAM writes
  // one write port per RAM; ctl's order and the barrier keep its users apart (checked below)
  logic sbw;                // stage B writes this clock
  assign sbw = sb_v;
  logic                     da_we, ta_we, db_we, tb_we, dc_we, rtc_we, opt_we, rst_we, rsd_we;
  logic [P2_TILE_LOG2-1:0]  da_row, ta_row, db_row, tb_row, dc_row, rtc_row, opt_row, rst_row, rsd_row;
  lanes_t                   da_ln, ta_ln, db_ln, tb_ln, dc_ln, rtc_ln, opt_ln, rst_ln, rsd_ln;
  p2_zkey_t [P2_TILE-1:0]   da_wd, db_wd, dc_wd, rsd_wd;
  logic [P2_TILE-1:0][31:0] ta_wd, tb_wd, rtc_wd, opt_wd, rst_wd;
  // one lane's word for the whole row
  function automatic logic [P2_TILE-1:0][31:0] rep_t(input logic [31:0] t);
    for (int i = 0; i < P2_TILE; i++)
      rep_t[i] = t;
  endfunction
  function automatic p2_zkey_t [P2_TILE-1:0] rep_d(input p2_zkey_t d);
    for (int i = 0; i < P2_TILE; i++)
      rep_d[i] = d;
  endfunction

  lanes_t fin_r;            // PT_FINAL: rendered || everRendered
  assign fin_r = b_rn | b_ev;
  logic [P2_TILE-1:0][31:0] wt;
  always_comb begin
    for (int i = 0; i < P2_TILE; i++)
      wt[i] = w_tag[i];
    // the raster (R2) / the sweep's stage B / the feedback / the cutter / debug
    da_we = 1'b0; da_row = w_row; da_ln = '0; da_wd = w_depth;
    ta_we = 1'b0; ta_row = w_row; ta_ln = '0; ta_wd = wt;
    db_we = 1'b0; db_row = sb_row; db_ln = '0; db_wd = q_da;
    tb_we = 1'b0; tb_row = sb_row; tb_ln = '0; tb_wd = q_ta;
    dc_we = 1'b0; dc_row = sb_row; dc_ln = '0; dc_wd = q_da;
    rtc_we = 1'b0; rtc_row = sb_row; rtc_ln = '0; rtc_wd = q_ta;
    opt_we = 1'b0; opt_row = sb_row; opt_ln = '0; opt_wd = q_ta;
    rst_we = 1'b0; rst_row = fbw_row; rst_ln = fbw_lane; rst_wd = rep_t(fbw_tag);
    rsd_we = 1'b0; rsd_row = fbw_row; rsd_ln = fbw_lane; rsd_wd = rep_d(fbw_depth);
    if (w_v) begin
      da_we = |w_dwe; da_ln = w_dwe;
      ta_we = |w_twe; ta_ln = w_twe;
    end
    if (sbw) begin
      da_row = sb_row;
      ta_row = sb_row;
      unique case (sw_q)
        P2_SW_CLEAR: begin
          da_we = 1'b1; da_ln = '1; da_wd = rep_d(sw_k);
          ta_we = 1'b1; ta_ln = '1;
          for (int i = 0; i < P2_TILE; i++)
            ta_wd[i] = sw_t;
        end
        P2_SW_PT_INIT: begin
          dc_we = 1'b1; dc_ln = '1; dc_wd = q_da;
          opt_we = 1'b1; opt_ln = '1; opt_wd = q_ta;
          rtc_we = 1'b1; rtc_ln = '1; rtc_wd = q_ta;
          tb_we = 1'b1; tb_ln = '1; tb_wd = rep_t(BELOW);
        end
        P2_SW_PT_CHUNK: begin
          dc_we = 1'b1; dc_ln = b_rn; dc_wd = q_rsd;
          rtc_we = 1'b1; rtc_ln = b_rn; rtc_wd = q_rst;
          tb_we = 1'b1; tb_ln = '1; tb_wd = rep_t(BELOW);
        end
        P2_SW_PT_FINAL: begin
          da_we = 1'b1; da_ln = '1;
          ta_we = 1'b1; ta_ln = '1;
          for (int i = 0; i < P2_TILE; i++) begin
            da_wd[i] = fin_r[i] ? q_rsd[i] : q_dc[i];
            ta_wd[i] = fin_r[i] ? q_rst[i] : q_opt[i];
          end
        end
        P2_SW_PEEL: begin
          db_we = 1'b1; db_ln = '1; db_wd = q_da;
          tb_we = 1'b1; tb_ln = '1; tb_wd = q_ta;
          da_we = 1'b1; da_ln = '1; da_wd = rep_d(sw_k);
        end
        P2_SW_SAVE: begin
          rsd_we = 1'b1; rsd_row = sb_row; rsd_ln = '1; rsd_wd = q_da;
        end
        P2_SW_RESTORE: begin
          da_we = 1'b1; da_ln = '1; da_wd = q_rsd;
        end
        default: ;
      endcase
    end
    if (fbw_v) begin
      // every message: depthB, tagB = depthA, tagA (the next pass looks below it); a pass also resTag, resDepth
      db_we = 1'b1; db_row = fbw_row; db_ln = fbw_lane; db_wd = rep_d(fbw_depth);
      tb_we = 1'b1; tb_row = fbw_row; tb_ln = fbw_lane; tb_wd = rep_t(fbw_tag);
      rst_we = fbw_pass;
      rsd_we = fbw_pass;
    end
    if (cs_we) begin
      rsd_we = 1'b1; rsd_row = cs_row; rsd_ln = cs_lane; rsd_wd = cs_data;
    end
`ifndef SYNTHESIS
    if (dbg_we) begin
      da_we = 1'b1; da_row = dbg_row; da_ln = '1; da_wd = dbg_wdepth;
      ta_we = 1'b1; ta_row = dbg_row; ta_ln = '1; ta_wd = dbg_wtag;
      db_we = 1'b1; db_row = dbg_row; db_ln = '1; db_wd = dbg_wdepth_b;
      tb_we = 1'b1; tb_row = dbg_row; tb_ln = '1; tb_wd = dbg_wtag_b;
      dc_we = 1'b1; dc_row = dbg_row; dc_ln = '1; dc_wd = dbg_wdepth_c;
      rtc_we = 1'b1; rtc_row = dbg_row; rtc_ln = '1; rtc_wd = dbg_wreftag_c;
      opt_we = 1'b1; opt_row = dbg_row; opt_ln = '1; opt_wd = dbg_woptag;
      rst_we = 1'b1; rst_row = dbg_row; rst_ln = '1; rst_wd = dbg_wrestag;
      rsd_we = 1'b1; rsd_row = dbg_row; rsd_ln = '1; rsd_wd = dbg_wrsd;
    end
`endif
  end

  // ---------------------------------------------------------------------------------------------- the RAMs
  // the tag RAMs hold TAG_BITS of the word
  logic [P2_TILE-1:0][TAG_BITS-1:0] ta_wn, ta_qf, ta_qc, ta_dq;
  always_comb
    for (int i = 0; i < P2_TILE; i++) begin
      ta_wn[i] = TAG_BITS'(ta_wd[i]);
      q_ta[i]  = 32'(ta_qf[i]);
      c_tag[i] = 32'(ta_qc[i]);
      dbg_tag[i] = 32'(ta_dq[i]);
    end
  p2_isp_lram #(.W(64)) u_da_f (.clk(clk), .we(da_we), .w_row(da_row), .w_lane(da_ln), .w_data(da_wd), .re(rd_re),
    .r_row(rd_row), .q(q_da), .dbg_row(dbg_row), .dbg_q(dbg_depth));
  p2_isp_lram #(.W(64)) u_da_c (.clk(clk), .we(da_we), .w_row(da_row), .w_lane(da_ln), .w_data(da_wd), .re(c_re),
    .r_row(c_row), .q(c_depth), .dbg_row(dbg_row), .dbg_q());
  p2_isp_lram #(.W(TAG_BITS)) u_ta_f (.clk(clk), .we(ta_we), .w_row(ta_row), .w_lane(ta_ln), .w_data(ta_wn),
    .re(rd_re), .r_row(rd_row), .q(ta_qf), .dbg_row(dbg_row), .dbg_q(ta_dq));
  p2_isp_lram #(.W(TAG_BITS)) u_ta_c (.clk(clk), .we(ta_we), .w_row(ta_row), .w_lane(ta_ln), .w_data(ta_wn),
    .re(c_re), .r_row(c_row), .q(ta_qc), .dbg_row(dbg_row), .dbg_q());
  p2_isp_lram #(.W(64)) u_db (.clk(clk), .we(db_we), .w_row(db_row), .w_lane(db_ln), .w_data(db_wd), .re(rd_re),
    .r_row(rd_row), .q(q_db), .dbg_row(dbg_row), .dbg_q(dbg_depth_b));
  p2_isp_lram #(.W(32)) u_tb (.clk(clk), .we(tb_we), .w_row(tb_row), .w_lane(tb_ln), .w_data(tb_wd), .re(rd_re),
    .r_row(rd_row), .q(q_tb), .dbg_row(dbg_row), .dbg_q(dbg_tag_b));
  p2_isp_lram #(.W(64)) u_dc (.clk(clk), .we(dc_we), .w_row(dc_row), .w_lane(dc_ln), .w_data(dc_wd), .re(rd_re),
    .r_row(rd_row), .q(q_dc), .dbg_row(dbg_row), .dbg_q(dbg_depth_c));
  p2_isp_lram #(.W(32)) u_rtc (.clk(clk), .we(rtc_we), .w_row(rtc_row), .w_lane(rtc_ln), .w_data(rtc_wd), .re(rd_re),
    .r_row(rd_row), .q(q_rtc), .dbg_row(dbg_row), .dbg_q(dbg_reftag_c));
  p2_isp_lram #(.W(32)) u_opt (.clk(clk), .we(opt_we), .w_row(opt_row), .w_lane(opt_ln), .w_data(opt_wd), .re(rd_re),
    .r_row(rd_row), .q(q_opt), .dbg_row(dbg_row), .dbg_q(dbg_optag));
  p2_isp_lram #(.W(32)) u_rst (.clk(clk), .we(rst_we), .w_row(rst_row), .w_lane(rst_ln), .w_data(rst_wd), .re(rd_re),
    .r_row(rd_row), .q(q_rst), .dbg_row(dbg_row), .dbg_q(dbg_restag));
  p2_isp_lram #(.W(64)) u_rsd (.clk(clk), .we(rsd_we), .w_row(rsd_row), .w_lane(rsd_ln), .w_data(rsd_wd), .re(rd_re),
    .r_row(rd_row), .q(q_rsd), .dbg_row(dbg_row), .dbg_q(dbg_rsd));

  // ---------------------------------------------------------------------------------------------- flip-flop writes
  always_ff @(posedge clk) begin
    // the raster (R2)
    if (w_v) begin
      if (w_swe)
        st[w_row] <= w_stencil;
      for (int i = 0; i < P2_TILE; i++)
        if (w_vwe[i])
          vl[w_row][i] <= w_valid[i];
    end
    // the sweep's stage B
    if (sbw) begin
      unique case (sw_q)
        P2_SW_CLEAR: begin
          st[sb_row] <= '0;
          vl[sb_row] <= '1;
          rn[sb_row] <= '0;
        end
        P2_SW_CLRSTATUS: begin
          vl[sb_row] <= '0;
          rn[sb_row] <= '0;
        end
        P2_SW_PT_INIT: begin
          st[sb_row] <= '0;
          vl[sb_row] <= '0;
          rn[sb_row] <= '0;
          ev[sb_row] <= '0;
          rc[sb_row] <= '0;
          rl[sb_row] <= '0;
        end
        P2_SW_PT_CHUNK: begin
          ev[sb_row] <= b_ev | b_rn;
          vl[sb_row] <= '0;
          rn[sb_row] <= '0;
          rc[sb_row] <= '0;
          rl[sb_row] <= '0;
        end
        P2_SW_PASS_START: begin
          rl[sb_row] <= b_rc;
          rc[sb_row] <= '0;
        end
        P2_SW_PT_FINAL:
          rn[sb_row] <= fin_r;
        P2_SW_PEEL: begin
          st[sb_row] <= '0;
          vl[sb_row] <= '0;
          rn[sb_row] <= '0;
        end
        default: ;
      endcase
    end
    // the cutter (TR_PRESORT: the cut pixels are shaded)
    if (cv_we)
      for (int i = 0; i < P2_TILE; i++)
        if (cv_lane[i])
          vl[cv_row][i] <= 1'b0;
    // the feedback: valid = 0; a pass: rendered, rcur
    if (fbw_v)
      for (int i = 0; i < P2_TILE; i++)
        if (fbw_lane[i]) begin
          vl[fbw_row][i] <= 1'b0;
          if (fbw_pass) begin
            rn[fbw_row][i] <= 1'b1;
            rc[fbw_row][i] <= 1'b1;
          end
        end
`ifndef SYNTHESIS
    if (dbg_we) begin
      st[dbg_row] <= dbg_wstencil;
      vl[dbg_row] <= dbg_wvalid;
      rn[dbg_row] <= dbg_wrendered;
      rc[dbg_row] <= dbg_wrcur;
      rl[dbg_row] <= dbg_wrlp;
      ev[dbg_row] <= dbg_wever;
    end
`endif
  end
  assign n_stencil  = st[n_row];
  assign n_valid    = vl[n_row];
  assign n_rendered = rn[n_row];
  assign n_rlp      = rl[n_row];
  always_comb
    for (int r = 0; r < P2_TILE; r++)
      for (int i = 0; i < P2_TILE; i++)
        k_st0[r][i] = st[r][i][0];
  assign k_valid    = vl;
  assign k_rendered = rn;
  assign dbg_stencil  = st[dbg_row];
  assign dbg_valid    = vl[dbg_row];
  assign dbg_rendered = rn[dbg_row];
  assign dbg_rcur     = rc[dbg_row];
  assign dbg_rlp      = rl[dbg_row];
  assign dbg_ever     = ev[dbg_row];

`ifndef SYNTHESIS
  // one writer of a row at a time (ARCHITECTURE 3.4.7 "Why one write port suffices")
  always_ff @(posedge clk)
    if (!rst) begin
      if (sw_busy && w_v)
        $error("p2_isp_buf: a raster write during a sweep (ctl issues them one after the other)");
      if (fbw_v && (w_v || sw_busy))
        $error("p2_isp_buf: a feedback write beside a raster (%0d, row %0d) or sweep (%0d, op %0d) write", w_v, w_row,
               sw_busy, sw_q);
      if (cs_we && (sbw && sw_q == P2_SW_SAVE || fbw_v && fbw_pass))
        $error("p2_isp_buf: the cutter's savedDepth write beside another one");
      if (cv_we && w_v && cv_row == w_row)
        $error("p2_isp_buf: the cutter and the raster write row %0d in one clock (the row barrier)", w_row);
      if (cv_we && sbw && cv_row == sb_row)
        $error("p2_isp_buf: the cutter and a sweep write row %0d in one clock (the row barrier)", sb_row);
    end
`endif
endmodule

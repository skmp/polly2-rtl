// p2_wout: the write-out (PLAN M12; ARCHITECTURE 3.10; tsp 17.2-17.4): a finished tile from the secondary tile buffer to
// the framebuffer, through the scaler, the pixel clip, the strip buffer, the pack and the dither, on C5. refcore
// refsw_lists.cpp RenderCORE at refsw3 4f3efe15: its write-out of an entry (copy core-writeout), putRow, filtered,
// emitRows, endStream and the frame's end (core-endframe); put is p2_wout_put.
//
//   start(tx, ty)   p2_tbuf's WRITE action (after the swap: the secondary buffer is the finished tile). By SCALER_CTL's
//                   vscalefactor (bits 15:0):
//     0x400         a tile's lines go to their own rows: pixel (x, y) to (32 tx + x, 32 ty + y)
//     0             nothing is written (GAP, not measured; refsw3 writes nothing)
//     otherwise     the tiles' lines are one stream (below)
//   eof             the frame's end: endStream(stuck) with a stream factor
//   flush           a render's start: the stream and the strip number begin again (RenderCORE's locals)
//   hscale (SCALER_CTL[16]): pixel pairs averaged, (a + b) >> 1 per channel, at x / 2 (putRow)
//
// The stream (refsw3's text, scalermeas, scalertile, ycoeff; polly2-data underdefeat_*): lines go into an 8-line ring of
// 32 pixels (`ring`: eight line RAMs of 32 words); a tile with y = 0 ends the stream before it (endStream(false)) and starts a
// new one (streamLines = streamRow = 0, the start pos 1024 with the filter, interlace and fieldselect, else 0). After each
// line taken in, the rows that can be written are written (emitRows): row j at pos = j * factor + start (1/1024 lines),
// k = pos >> 10, f = pos[9:6]; non-end: while k + (filter ? 2 : 1) <= streamLines - 1; end: while k + 1 <= last or
// (k == last and pos[9:0] == 0), last = (filter ? streamLines - 1 : streamLines) - 1. A row: per pixel x and channel
// a = filtered(k), with f != 0 (a (16 - f) + filtered(k + 1) f) >> 4; filtered(i) = the line, or with the filter (factor
// above 0x400) ((c0 above >> 4) + (c1 line >> 4) + (c0 below >> 4)) >> 4 & 0xFF, c1 = Y_COEFF[15:8], c0 = Y_COEFF[7:0],
// above = line max(i - 1, 0); the row goes to x = the tile being worked on, y = j & 1023 (the 10-bit row counter: the
// stream's, not the tile's). endStream: with the filter the last line is taken in once more; then the end's rows; with
// `stuck` (the frame's end) the filtered last line reads pixel 0 for every x (the hardware bug refsw3 reproduces).
//
// Structure: a tile-buffer reader at one pixel a clock (the secondary port, p2_tbuf: it loses a clock to P10's reads of
// buffer 2) into a line FIFO of WO_FIFO pixels [G 64: ARCHITECTURE 6, fitted on T10 / T15]; at 0x400 the pixels go
// straight on to put (one a clock), with the stream into the ring and out through the row engine (the four lines a
// pixel: eight line RAMs read side by side, one pixel a clock; the scaler is untimed, GAP); p2_wout_put does the pixel's
// bytes and C5.
// [M tim 3.11: 1045 / 1105 / 1357 clk a tile; per line max(32 + 0.66, W + 10.4)]
module p2_wout
  import p2_regs_pkg::*;
#(
  parameter int WO_FIFO = 64
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         flush,
  // the registers (refsw3 reads them at RenderCORE's start; constant through a render here)
  input  logic [31:0]  fb_w_ctrl,
  input  logic [31:0]  fb_w_linestride,
  input  logic [31:0]  fb_w_sof1,
  input  logic [31:0]  fb_w_sof2,
  input  logic [31:0]  fb_x_clip,
  input  logic [31:0]  fb_y_clip,
  input  logic [31:0]  fb_r_ctrl,
  input  logic [31:0]  scaler_ctl,
  input  logic [31:0]  y_coeff,
  // p2_tbuf's controller
  input  logic         start,
  input  logic [5:0]   tx,
  input  logic [5:0]   ty,
  input  logic         eof,
  output logic         busy,
  output logic         rd_done,          // the reader has read the tile's last pixel (a pulse)
  // the secondary tile buffer's read port (shared with P10, p2_tbuf)
  output logic         rd_re,
  output logic [9:0]   rd_idx,
  input  logic         rd_gnt,
  input  logic [31:0]  rd_data,
  // C5
  output logic         m_v,
  input  logic         m_rdy,
  output logic [23:0]  m_addr,
  output logic [3:0]   m_be,
  output logic [31:0]  m_wdata
);
  localparam int FB = $clog2(WO_FIFO);
  p2_scaler_ctl_t sc;
  assign sc = p2_scaler_ctl_t'(scaler_ctl);
  logic [15:0] vf;
  logic        vfilter, halve, mdirect, mnone;
  assign vf      = sc.vscalefactor;
  assign vfilter = vf > 16'h0400;
  assign halve   = sc.hscale;
  assign mdirect = vf == 16'h0400;
  assign mnone   = vf == 16'h0000;
  logic [7:0]  yc0, yc1;
  assign yc0 = y_coeff[7:0];
  assign yc1 = y_coeff[15:8];

  // ---------------------------------------------------------------------------------------------- the reader, the FIFO
  logic          rd_act, rd_pend;
  logic [9:0]    ridx;
  logic [FB:0]   fn;                       // in the FIFO, plus the read in flight
  logic [31:0]   fifo [WO_FIFO];
  logic [FB-1:0] fwp, frp;
  logic          f_pop, f_v;
  logic [31:0]   f_d;
  assign rd_re  = rd_act && fn != (FB + 1)'(WO_FIFO);
  assign rd_idx = ridx;
  assign f_v    = fn != '0 && !(fn == (FB + 1)'(1) && rd_pend);
  assign f_d    = fifo[frp];
  always_ff @(posedge clk) begin
    if (rst || flush) begin
      rd_act  <= 1'b0;
      rd_pend <= 1'b0;
      fn      <= '0;
      fwp     <= '0;
      frp     <= '0;
      rd_done <= 1'b0;
    end else begin
      rd_done <= 1'b0;
      if (start && !mnone) begin
        rd_act <= 1'b1;
        ridx   <= '0;
      end else if (rd_re && rd_gnt) begin
        ridx <= ridx + 10'd1;
        if (ridx == 10'd1023) begin
          rd_act  <= 1'b0;
          rd_done <= 1'b1;
        end
      end
      rd_pend <= rd_re && rd_gnt;
      if (rd_pend) begin
        fifo[fwp] <= rd_data;
        fwp       <= fwp + 1'b1;
      end
      if (f_pop)
        frp <= frp + 1'b1;
      fn <= (FB + 1)'(fn + (FB + 1)'(rd_re && rd_gnt) - (FB + 1)'(f_pop));
    end
  end

  // ---------------------------------------------------------------------------------------------- the pixel source
  // what goes to put: a pixel of a row (X0: the tile's x, Y, x in the row), from the FIFO (0x400) or the row engine;
  // hscale pairs it here
  logic        o_v, o_rdy;
  logic [11:0] o_x0, o_y;
  logic [4:0]  o_x;
  logic [31:0] o_px;
  logic [31:0] h_px;
  logic        u_v, u_rdy, put_idle;
  logic [11:0] u_x, u_y;
  logic [31:0] u_px;
  always_comb begin
    logic [8:0] s [4];
    for (int c = 0; c < 4; c++)
      s[c] = 9'(h_px[8 * c +: 8]) + 9'(o_px[8 * c +: 8]);
    if (!halve) begin
      u_v   = o_v;
      u_x   = o_x0 + 12'(o_x);
      u_px  = o_px;
      o_rdy = u_rdy;
    end else begin
      u_v   = o_v && o_x[0];
      u_x   = {1'b0, o_x0[11:1]} + 12'(o_x[4:1]);
      u_px  = {s[3][8:1], s[2][8:1], s[1][8:1], s[0][8:1]};
      o_rdy = !o_x[0] || u_rdy;
    end
    u_y = o_y;
  end
  always_ff @(posedge clk)
    if (o_v && o_rdy && !o_x[0])
      h_px <= o_px;

  p2_wout_put u_put (.clk, .rst, .flush, .fb_w_ctrl, .fb_w_linestride, .fb_w_sof1, .fb_w_sof2, .fb_x_clip, .fb_y_clip,
    .fb_r_ctrl, .i_v(u_v), .i_rdy(u_rdy), .i_x(u_x), .i_y(u_y), .i_px(u_px), .idle(put_idle),
    .m_v, .m_rdy, .m_addr, .m_be, .m_wdata);

  // ---------------------------------------------------------------------------------------------- the ring
  // eight line RAMs of 32 words (line i in RAM i & 7), every one read at the same x each clock: a row's pixel needs lines
  // max(k - 1, 0) .. k + 2, four different RAMs
  logic             rg_we, rg_re;
  logic [2:0]       rg_ws;
  logic [4:0]       rg_wa, rg_ra;
  logic [31:0]      rg_wd;
  logic [7:0][31:0] rg_q;
  genvar gl;
  generate
    for (gl = 0; gl < 8; gl = gl + 1) begin : g_line
      logic [31:0] lram [32];
      always_ff @(posedge clk) begin
        if (rg_we && rg_ws == 3'(gl)) lram[rg_wa] <= rg_wd;
        if (rg_re) rg_q[gl] <= lram[rg_ra];
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------------------------- the stream's state
  logic [31:0] sLines;                     // streamLines
  logic [23:0] sRow;                       // streamRow
  logic        sStart;                     // streamStart is 1024
  logic        sXv;                        // streamX >= 0
  logic [5:0]  sX;                         // streamX / 32
  logic        fieldStart;
  assign fieldStart = vfilter && sc.interlace && sc.fieldselect;

  // ---------------------------------------------------------------------------------------------- the control
  typedef enum logic [3:0] {
    W_IDLE,      // nothing
    W_DIRECT,    // 0x400: the FIFO's pixels to put
    W_END0,      // a tile at y = 0 with a stream factor: endStream(false) first
    W_FILL,      // a line into the ring
    W_EMIT,      // the row engine runs (emitRows)
    W_COPYR,     // endStream: the last line read again ...
    W_COPYW,     // ... into the next place
    W_EOF,       // the frame's end: endStream(true)
    W_DRAIN      // waiting for put to finish
  } wst_t;
  wst_t        st, ret;                    // ret: where W_EMIT goes back to
  logic [5:0]  tX, tY;
  logic [9:0]  cnt;                        // W_DIRECT: pixels; W_FILL / copy: x; lines in the tile
  logic        e_end, e_stuck;             // the row engine's call
  logic [5:0]  e_X;

  // the row engine: emitRows, one pixel a clock. E_CHECK decides whether a row is written (and its k, f); E_ROW reads the
  // four lines at x (rx) a clock and puts the pixel out the clock after (ov, ox) when the source takes it. With `stuck`
  // (endStream at the frame's end, with the filter) filtered(last) reads pixel 0 for every x: the row's pixel-0 words of
  // the four lines are kept (z) when x = 0 is read, and stand in for the line words of a filtered() on the last line.
  typedef enum logic [1:0] { E_CHECK, E_ROW } est_t;
  est_t        es;
  logic        e_go, e_busy;
  logic [39:0] pos;
  logic signed [33:0] k, last, sl1;
  logic [3:0]  f;
  logic [5:0]  rx;                         // the next x to read (32: the row's reads are done)
  logic        ov;                         // a pixel's words are in rg_q (ox)
  logic [4:0]  ox;
  logic        e_go_on;
  logic [3:0][31:0] z;                     // the four lines' words at x = 0
  always_comb begin
    sl1  = 34'(sLines) - 34'sd1;
    pos  = 40'(sRow) * 40'(vf) + (sStart ? 40'd1024 : 40'd0);
    k    = $signed({4'b0000, pos[39:10]});
    f    = pos[9:6];
    last = (e_end && vfilter) ? sl1 - 34'sd1 : sl1;
    if (e_end)
      e_go_on = (k + 34'sd1 <= last) || (k == last && pos[9:0] == 10'd0);
    else
      e_go_on = !(k + (vfilter ? 34'sd2 : 34'sd1) > sl1);
  end
  // the four lines' words of the pixel being put out, and of x = 0
  logic [3:0][31:0] lw, lz;
  always_comb begin
    logic signed [33:0] km1;
    logic [3:0][2:0]    sl;
    km1   = k > 34'sd0 ? k - 34'sd1 : 34'sd0;
    sl[0] = km1[2:0];
    sl[1] = k[2:0];
    sl[2] = 3'(k + 34'sd1);
    sl[3] = 3'(k + 34'sd2);
    for (int i = 0; i < 4; i++) begin
      lw[i] = rg_q[sl[i]];
      lz[i] = ox == 5'd0 ? lw[i] : z[i];
    end
  end
  // the row's pixel: filtered(k) from lines k - 1, k, k + 1, filtered(k + 1) from k, k + 1, k + 2 (pixel 0's words for a
  // filtered() on the last line with `stuck`)
  logic [31:0] e_px;
  function automatic logic [7:0] filt(input logic [7:0] a, input logic [7:0] v, input logic [7:0] b,
                                      input logic [7:0] c0, input logic [7:0] c1);
    logic [15:0] pa, pv, pb;
    logic [13:0] s;
    pa = 16'(c0) * 16'(a);
    pv = 16'(c1) * 16'(v);
    pb = 16'(c0) * 16'(b);
    s  = 14'(pa >> 4) + 14'(pv >> 4) + 14'(pb >> 4);
    return s[11:4];
  endfunction
  always_comb begin
    logic        sk, sk1;
    logic [3:0][31:0] la, lb;
    sk  = e_stuck && vfilter && k == last;
    sk1 = e_stuck && vfilter && k + 34'sd1 == last;
    la  = sk ? lz : lw;
    lb  = sk1 ? lz : lw;
    for (int c = 0; c < 4; c++) begin
      logic [7:0]  fa, fb;
      logic [12:0] m;
      fa = vfilter ? filt(la[0][8 * c +: 8], la[1][8 * c +: 8], la[2][8 * c +: 8], yc0, yc1) : la[1][8 * c +: 8];
      fb = vfilter ? filt(lb[1][8 * c +: 8], lb[2][8 * c +: 8], lb[3][8 * c +: 8], yc0, yc1) : lb[2][8 * c +: 8];
      m  = 13'(fa) * (13'd16 - 13'(f)) + 13'(fb) * 13'(f);
      e_px[8 * c +: 8] = f != 4'd0 ? m[11:4] : fa;
    end
  end

  // the pixel source: the FIFO at 0x400, the row engine otherwise
  always_comb begin
    o_v  = 1'b0;
    o_x0 = {1'b0, tX, 5'd0};
    o_y  = {tY, 5'd0} + 12'(cnt[9:5]);
    o_x  = cnt[4:0];
    o_px = f_d;
    if (st == W_DIRECT)
      o_v = f_v;
    else if (es == E_ROW && ov) begin
      o_v  = 1'b1;
      o_x0 = {1'b0, e_X, 5'd0};
      o_y  = {2'b00, sRow[9:0]};
      o_x  = ox;
      o_px = e_px;
    end
  end
  assign f_pop = (st == W_DIRECT && o_v && o_rdy) || (st == W_FILL && f_v);

  // the ring's ports
  logic e_adv;                             // E_ROW: the pixel in rg_q is taken (or there is none)
  assign e_adv = !ov || o_rdy;
  always_comb begin
    rg_we = 1'b0;
    rg_ws = sLines[2:0];
    rg_wa = cnt[4:0];
    rg_wd = f_d;
    rg_re = 1'b0;
    rg_ra = rx[4:0];
    if (st == W_FILL && f_v)
      rg_we = 1'b1;
    if (st == W_COPYR) begin
      rg_re = 1'b1;
      rg_ra = cnt[4:0];
    end
    if (st == W_COPYW) begin
      rg_we = 1'b1;
      rg_wd = rg_q[sl1[2:0]];
    end
    if (es == E_ROW && e_adv && !rx[5])
      rg_re = 1'b1;
  end

  assign e_busy = es != E_CHECK || e_go;
  assign busy   = st != W_IDLE || rd_act || fn != '0 || !put_idle;

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      st     <= W_IDLE;
      es     <= E_CHECK;
      e_go   <= 1'b0;
      sLines <= '0;
      sRow   <= '0;
      sStart <= 1'b0;
      sXv    <= 1'b0;
    end else begin
      // ---- the row engine (e_go: run emitRows(e_X, e_end, e_stuck) to its end)
      case (es)
        E_CHECK:
          if (e_go) begin
            if (e_go_on) begin
              es <= E_ROW;
              rx <= '0;
              ov <= 1'b0;
            end else
              e_go <= 1'b0;
          end
        default:   // E_ROW
          if (e_adv) begin
            if (ov && ox == 5'd0)
              z <= lw;
            if (!rx[5]) begin
              ov <= 1'b1;
              ox <= rx[4:0];
              rx <= rx + 6'd1;
            end else begin
              // the row's last pixel taken
              ov   <= 1'b0;
              sRow <= sRow + 24'd1;
              es   <= E_CHECK;
            end
          end
      endcase

      // ---- the tile, the frame's end
      case (st)
        W_IDLE:
          if (start) begin
            tX  <= tx;
            tY  <= ty;
            cnt <= '0;
            if (mnone)
              st <= W_IDLE;
            else if (mdirect)
              st <= W_DIRECT;
            else if (ty == 6'd0) begin
              // endStream(false), then a new stream
              e_X     <= sX;
              e_end   <= 1'b1;
              e_stuck <= 1'b0;
              ret     <= W_END0;
              if (sXv && sLines != '0)
                st <= vfilter ? W_COPYR : W_EMIT;
              else
                st <= W_END0;
              if (sXv && sLines != '0 && !vfilter)
                e_go <= 1'b1;
            end else
              st <= W_FILL;
          end else if (eof && !mdirect && !mnone) begin
            e_X     <= sX;
            e_end   <= 1'b1;
            e_stuck <= 1'b1;
            ret     <= W_DRAIN;
            if (sXv && sLines != '0) begin
              st <= vfilter ? W_COPYR : W_EMIT;
              if (!vfilter) e_go <= 1'b1;
            end
          end
        W_DIRECT:
          if (o_v && o_rdy) begin
            cnt <= cnt + 10'd1;
            if (cnt == 10'd1023)
              st <= W_DRAIN;
          end
        W_END0: begin
          sLines <= '0;
          sRow   <= '0;
          sStart <= fieldStart;
          st     <= W_FILL;
        end
        W_FILL:
          if (f_v) begin
            cnt <= cnt + 10'd1;
            if (cnt[4:0] == 5'd31) begin
              sLines  <= sLines + 32'd1;
              e_X     <= tX;
              e_end   <= 1'b0;
              e_stuck <= 1'b0;
              e_go    <= 1'b1;
              ret     <= cnt == 10'd1023 ? W_DRAIN : W_FILL;
              st      <= W_EMIT;
            end
          end
        W_EMIT:
          if (!e_busy) begin
            st <= ret;
            if (ret == W_DRAIN && !e_end) begin
              sXv <= 1'b1;
              sX  <= tX;
            end
          end
        W_COPYR: begin
          st <= W_COPYW;
        end
        W_COPYW: begin
          cnt <= cnt + 10'd1;
          if (cnt[4:0] == 5'd31) begin
            sLines <= sLines + 32'd1;
            cnt    <= '0;
            e_go   <= 1'b1;
            st     <= W_EMIT;
          end else
            st <= W_COPYR;
        end
        default:   // W_DRAIN
          if (put_idle && !u_v)
            st <= W_IDLE;
      endcase
    end
  end
`ifndef SYNTHESIS
  // +wotrace: the tiles, the rows (debug)
  logic tr;
  initial tr = $test$plusargs("wotrace");
  always_ff @(posedge clk)
    if (tr && !rst) begin
      if (st == W_IDLE && start) $display("wo: tile %0d %0d mode %0d sX %0d sXv %0d sLines %0d", tx, ty, mdirect ? 0 : mnone ? 2 : 1, sX, sXv, sLines);
      if (st == W_IDLE && eof) $display("wo: eof sX %0d sXv %0d sLines %0d", sX, sXv, sLines);
      if (es == E_CHECK && e_go && e_go_on) $display("wo: row %0d k %0d f %0d X %0d end %0d stuck %0d lines %0d", sRow, k, f, e_X, e_end, e_stuck, sLines);
    end
`endif
endmodule

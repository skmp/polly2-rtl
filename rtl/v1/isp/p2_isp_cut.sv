// p2_isp_cut: the ISP side of a SHADE pass (PLAN M7; ARCHITECTURE 3.4.8, 2.3; isp 12.1, 12.3, 4.4; tsp 3.1; refcore
// refsw_tile.cpp SpanGen<rm>, RenderParamTags's ISP-side effects and tilePixelsShaded at refsw3 4f3efe15).
//
// Commands from p2_isp_ctl, one held while the one before is cut (cmd_rdy: the slot is free):
//   SHADE(rm, opinpt, last)  cut the tile's runs of the pass. Per row j = 0 .. 31:
//       part[i] = valid, or for PT_MV stencil0 && (rendered || opinpt)
//       vol[i]  = stencil0, forced to 0 in TR_PRESORT, both PT passes, and OPAQUE with opinpt
//       a run starts at i where part[i] && (i == 0 || !part[i-1] || tag[i] != tag[i-1] (all 32 bits) || vol[i] != vol[i-1])
//       each run: tag, y, x, lenm1, rm, the epoch, vmask (stencil0 of its pixels), pmask (rendered of its pixels in
//       PT_PASS0 / N and PT_MV, else 0) [uvrun, optrun, volrun, ptruns]
//     side effects: TR_PRESORT valid = 0 on the cut pixels; TR_AUTOSORT savedDepth = depthA on them (SaveDepthAt: the
//     shaded pixels are exactly the valid ones); the entry's shaded_any (tilePixelsShaded != 0)
//     flags: the pass's last run carries eop; with `last` (ctl issued it as the entry's last SHADE) also eoe, and the
//     entry record goes into p2_entq with it. A pass with no run emits nothing (no eop; with `last`, a null eoe item).
//     The epoch (7 bits) counts the passes that emitted a run.
//   END                      the entry's end decided after its last SHADE was cut (after a punch-through pass with no
//                            later phase, after a pre-sorted walk): a null item with eoe and the entry record.
//
// Structure [M tim 3.4: one run a clock whatever its length; a line of 32 one-pixel runs costs 31 more than one run]:
//   A  the next row from the row pointer with a part pixel (a priority encoder over the 32 rows' part bits, computed
//      from the flip-flop fields: an empty row costs 0 clocks [G; GAP T3]); its tagA / depthA from the buffer's C copy
//      (a registered read) and its flip-flop fields latched. A issues the next row while B emits its row's last run
//   B  the row: the run starts and ends (31 neighbour compares), a priority encoder emitting one run a clock (rs_rdy);
//      the side effects in its first clock
// The row barrier (ARCHITECTURE 3.4.7): bar_ok[j] says a later epoch may write row j: every row when nothing is being
// cut; the rows the current SHADE has finished (B done, or skipped) when it is the last one issued; none while another
// SHADE waits in the slot. A full p2_entq stalls the cutter at its eoe item. ev_isp: an eoe item was accepted.
module p2_isp_cut
  import p2_pkg::*;
  import p2_regs_pkg::*;
(
  input  logic                              clk,
  input  logic                              rst,
  // ctl
  input  logic                              cmd_v,
  output logic                              cmd_rdy,
  input  logic                              cmd_end,       // END (else SHADE)
  input  p2_rm_t                            cmd_rm,
  input  logic                              cmd_opinpt,
  input  logic                              cmd_last,
  input  p2_entrec_t                        cmd_rec,       // tilex, tiley, z_keep, no_writeout, last (shaded_any is ours)
  output logic                              idle,          // nothing in the slot, nothing being cut
  // p2_isp_buf: C read, the flip-flop fields, the side effects
  output logic                              c_re,
  output logic [P2_TILE_LOG2-1:0]           c_row,
  input  p2_zkey_t [P2_TILE-1:0]            c_depth,
  input  logic [P2_TILE-1:0][31:0]          c_tag,
  input  logic [P2_TILE-1:0][P2_TILE-1:0]   k_valid,
  input  logic [P2_TILE-1:0][P2_TILE-1:0]   k_st0,
  input  logic [P2_TILE-1:0][P2_TILE-1:0]   k_rendered,
  output logic                              cv_we,
  output logic [P2_TILE_LOG2-1:0]           cv_row,
  output logic [P2_TILE-1:0]                cv_lane,
  output logic                              cs_we,
  output logic [P2_TILE_LOG2-1:0]           cs_row,
  output logic [P2_TILE-1:0]                cs_lane,
  output p2_zkey_t [P2_TILE-1:0]            cs_data,
  output logic [P2_TILE-1:0]                bar_ok,
  // the run stream (p2_runq), valid/ready
  output logic                              rs_v,
  input  logic                              rs_rdy,
  output p2_rs_t                            rs,
  // p2_entq
  output logic                              eq_v,
  input  logic                              eq_rdy,
  output p2_entrec_t                        eq,
  output logic                              ev_isp
);
  typedef logic [P2_TILE-1:0] lanes_t;

  // ---------------------------------------------------------------------------------------------- the slot
  logic        q_v, q_end, q_opinpt, q_last;
  p2_rm_t      q_rm;
  p2_entrec_t  q_rec;
  // the command being worked on
  typedef enum logic [1:0] { C_IDLE, C_CUT, C_NULL } cst_t;
  cst_t        cst;
  logic        a_act;                       // C_CUT: rows are still to be found
  p2_rm_t      rm;
  logic        opinpt, last, any;           // any: this pass has emitted a run
  p2_entrec_t  rec;
  logic        shaded;                      // the entry's shaded_any so far
  logic [P2_EPOCH_BITS-1:0] epoch;
  logic        start;                       // the slot's command starts this clock
  assign cmd_rdy = !q_v;
  assign start   = q_v && cst == C_IDLE;
  assign idle    = !q_v && cst == C_IDLE;

  // ---------------------------------------------------------------------------------------------- part, vol
  function automatic lanes_t f_part(input p2_rm_t m, input logic op, input lanes_t v, input lanes_t s0, input lanes_t r);
    return m == P2_RM_PUNCHTHROUGH_MV ? (s0 & (r | {P2_TILE{op}})) : v;
  endfunction
  function automatic lanes_t f_vol(input p2_rm_t m, input logic op, input lanes_t s0);
    if (m == P2_RM_TRANSLUCENT_PRESORT || m == P2_RM_PUNCHTHROUGH_PASS0 || m == P2_RM_PUNCHTHROUGH_PASSN ||
        (m == P2_RM_OPAQUE && op))
      return '0;
    return s0;
  endfunction

  // the rows with a part pixel (from the flip-flops: stable for the rows not yet cut, ARCHITECTURE 3.4.8)
  lanes_t rows_nz;
  always_comb
    for (int r = 0; r < P2_TILE; r++)
      rows_nz[r] = f_part(rm, opinpt, k_valid[r], k_st0[r], k_rendered[r]) != '0;

  // ---------------------------------------------------------------------------------------------- stage A
  logic [P2_TILE_LOG2:0]   a_ptr;           // the next row to look at (32: done)
  lanes_t                  above;           // rows >= a_ptr
  lanes_t                  cand;
  logic [P2_TILE_LOG2-1:0] a_row;
  logic                    a_found;
  always_comb begin
    for (int r = 0; r < P2_TILE; r++)
      above[r] = 6'(r) >= a_ptr;
    cand    = rows_nz & above;
    a_found = cand != '0;
    a_row   = '0;
    for (int r = P2_TILE - 1; r >= 0; r--)
      if (cand[r])
        a_row = 5'(r);
  end

  // ---------------------------------------------------------------------------------------------- stage B
  logic                    b_v, b_first;
  logic [P2_TILE_LOG2-1:0] b_row;
  lanes_t                  b_valid, b_st0, b_rend, b_left;   // b_left: the run starts not yet emitted
  lanes_t                  b_part, b_vol, b_start, b_endm;
  logic [P2_TILE-1:0][31:0] b_tag;
  always_comb begin
    b_part = f_part(rm, opinpt, b_valid, b_st0, b_rend);
    b_vol  = f_vol(rm, opinpt, b_st0);
    for (int i = 0; i < P2_TILE; i++) begin
      b_tag[i] = c_tag[i];
      if (i == 0)
        b_start[i] = b_part[i];
      else
        b_start[i] = b_part[i] && (!b_part[i-1] || b_tag[i] != b_tag[i-1] || b_vol[i] != b_vol[i-1]);
    end
    for (int i = 0; i < P2_TILE; i++) begin
      if (i == P2_TILE - 1)
        b_endm[i] = b_part[i];
      else
        b_endm[i] = b_part[i] && (!b_part[i+1] || b_start[i+1]);
    end
  end
  // the run: the lowest start left, and the first end at or after it
  lanes_t                  starts;
  logic [P2_TILE_LOG2-1:0] s, e;
  lanes_t                  from_s;
  assign starts = b_first ? b_start : b_left;
  always_comb begin
    s = '0;
    for (int i = P2_TILE - 1; i >= 0; i--)
      if (starts[i])
        s = 5'(i);
    for (int i = 0; i < P2_TILE; i++)
      from_s[i] = 5'(i) >= s;
    e = '0;
    for (int i = P2_TILE - 1; i >= 0; i--)
      if (b_endm[i] && from_s[i])
        e = 5'(i);
  end
  lanes_t rest;                             // the starts after this run
  logic   row_last_run, pass_last_run;
  always_comb begin
    rest = starts & ~(P2_TILE'(1) << s);
    row_last_run  = rest == '0;
    // the pass's last run: no row is left for A (once A has found none, the rows after it are passed and a later
    // epoch may write them: their flip-flops no longer say anything about this pass)
    pass_last_run = row_last_run && !(a_act && a_found);
  end

  // the item
  logic   b_emit, b_eoe, b_take, null_take;
  lanes_t len_mask;
  always_comb begin
    len_mask = '0;
    for (int i = 0; i < P2_TILE; i++)
      len_mask[i] = 5'(i) <= 5'(e - s);
    b_emit = b_v && starts != '0;
    b_eoe  = pass_last_run && last;
    rs     = '0;
    rs_v   = 1'b0;
    if (b_emit) begin
      rs_v       = !b_eoe || eq_rdy;
      rs.tag     = p2_tag_t'(b_tag[s]);
      rs.y       = b_row;
      rs.x       = s;
      rs.lenm1   = 5'(e - s);
      rs.rm      = rm;
      rs.epoch   = epoch;
      rs.vmask   = (b_st0 >> s) & len_mask;
      rs.pmask   = (rm == P2_RM_PUNCHTHROUGH_PASS0 || rm == P2_RM_PUNCHTHROUGH_PASSN || rm == P2_RM_PUNCHTHROUGH_MV) ?
                   ((b_rend >> s) & len_mask) : '0;
      rs.eop     = pass_last_run;
      rs.eoe     = b_eoe;
    end else if (cst == C_NULL) begin
      // the null eoe item: flags only
      rs_v     = eq_rdy;
      rs.null_ = 1'b1;
      rs.rm    = rm;
      rs.epoch = epoch;
      rs.eoe   = 1'b1;
    end
  end
  assign b_take    = b_emit && rs_v && rs_rdy;
  assign null_take = cst == C_NULL && rs_v && rs_rdy;
  logic b_done;                              // B's row leaves this clock
  assign b_done = b_v && (starts == '0 || (b_take && row_last_run));

  // A issues a row when B is free next clock
  logic a_go;
  assign a_go  = a_act && a_found && (!b_v || b_done);
  assign c_re  = a_go;
  assign c_row = a_row;

  // the side effects in B's first clock
  assign cv_we   = b_v && b_first && rm == P2_RM_TRANSLUCENT_PRESORT;
  assign cv_row  = b_row;
  assign cv_lane = b_part;
  assign cs_we   = b_v && b_first && rm == P2_RM_TRANSLUCENT_AUTOSORT;
  assign cs_row  = b_row;
  assign cs_lane = b_part;
  assign cs_data = c_depth;

  // the entry record, with the eoe item
  assign eq_v = (b_take && b_eoe) || null_take;
  always_comb begin
    eq            = rec;
    eq.shaded_any = shaded || b_emit;
  end
  assign ev_isp = eq_v && rs_rdy;

  // ---------------------------------------------------------------------------------------------- the barrier
  lanes_t done;
  assign bar_ok = (q_v && !q_end) ? '0 : (cst == C_CUT) ? done : '1;

  // ---------------------------------------------------------------------------------------------- the sequence
  logic rows_end;                           // C_CUT: every row cut (A has found the last, B has emitted it)
  assign rows_end = cst == C_CUT && !a_act && !b_v;

  always_ff @(posedge clk) begin
    if (rst) begin
      q_v    <= 1'b0;
      cst    <= C_IDLE;
      a_act  <= 1'b0;
      b_v    <= 1'b0;
      epoch  <= '0;
      shaded <= 1'b0;
    end else begin
      // A
      if (a_act) begin
        if (a_go) begin
          // the rows skipped up to it are passed
          for (int r = 0; r < P2_TILE; r++)
            if (6'(r) >= a_ptr && 5'(r) < a_row)
              done[r] <= 1'b1;
          a_ptr <= 6'(a_row) + 6'd1;
        end else if (!a_found) begin
          for (int r = 0; r < P2_TILE; r++)
            if (6'(r) >= a_ptr)
              done[r] <= 1'b1;
          a_act <= 1'b0;
        end
      end
      // B
      if (b_v) begin
        b_first <= 1'b0;
        b_left  <= b_take ? rest : starts;
        if (b_take) begin
          any    <= 1'b1;
          shaded <= 1'b1;
        end
        if (b_done) begin
          done[b_row] <= 1'b1;
          b_v         <= 1'b0;
        end
      end
      if (a_go) begin
        b_v     <= 1'b1;
        b_first <= 1'b1;
        b_row   <= a_row;
        b_valid <= k_valid[a_row];
        b_st0   <= k_st0[a_row];
        b_rend  <= k_rendered[a_row];
      end
      if (b_take && b_eoe)
        shaded <= 1'b0;
      // the pass's end: the epoch counts the passes with a run; a last SHADE with no run owes the null eoe item
      if (rows_end) begin
        if (any)
          epoch <= epoch + 1'b1;
        cst <= (last && !any) ? C_NULL : C_IDLE;
      end
      if (null_take) begin
        cst    <= C_IDLE;
        shaded <= 1'b0;
      end
      // the slot
      if (cmd_v && cmd_rdy) begin
        q_v      <= 1'b1;
        q_end    <= cmd_end;
        q_rm     <= cmd_rm;
        q_opinpt <= cmd_opinpt;
        q_last   <= cmd_last;
        q_rec    <= cmd_rec;
      end
      if (start) begin
        q_v <= 1'b0;
        rec <= q_rec;
        any <= 1'b0;
        if (q_end)
          cst <= C_NULL;
        else begin
          cst    <= C_CUT;
          rm     <= q_rm;
          opinpt <= q_opinpt;
          last   <= q_last;
          a_act  <= 1'b1;
          a_ptr  <= '0;
          done   <= '0;
        end
      end
    end
  end

endmodule

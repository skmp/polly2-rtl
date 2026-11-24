// p2_tbuf_ctl: the tile buffers' entry-end controller (PLAN M12; ARCHITECTURE 3.9; tsp 17.1, isp 4.4): refcore
// refsw_lists.cpp RenderCORE's end of an entry at refsw3 4f3efe15 (tb/ref/ref_copies.h core-prev, core-writeout,
// core-endframe) and refsw_tile.cpp NextTileAccumulationBuffers.
//
// When an entry's eoe point leaves P10 its record is popped from p2_entq (p2_isp_cut pushed it with the eoe item) and,
// with prevWrittenOut, havePrev and the tile before (reset at a render's start, `flush`):
//   emptyKeepZ        = z_keep && !shaded_any && prevWrittenOut
//   emptyAfterNoWrite = z_keep && !shaded_any && !prevWrittenOut && havePrev
//   the action: no_writeout NONE; emptyKeepZ SWAP; otherwise WRITE(emptyAfterNoWrite ? the tile before : the tile), which
//   swaps the buffers and starts the write-out of the new secondary buffer (the finished tile) [accbuf pages 0, 3: a keep-Z
//   tile that shades nothing swaps but writes nothing; keepz page 1: after an entry not written out it writes that
//   entry's picture at that entry's tile]
//   prevWrittenOut = !no_writeout && !emptyKeepZ; the tile before = this one; havePrev = 1
// The action is pending from that point until it is done (`hold`: P10 takes no point meanwhile, p2_tsp_pp's hold9, so
// the next entry's first point reads the swapped buffers [M tim 3.10: "they swap when the TSP starts the next tile, which
// is also when the previous tile's write-out starts"]). When an action may go is p2_tbuf_hs's (refsw3-equivalent: once
// the write-out is idle, the WRITE wait that makes a tile cost max(ISP, TSP, write-out) [M tim 3.1]).
// The last entry's (last_region): after its action, the frame's end to p2_wout (endStream(stuck) with a stream factor),
// then ev_tsp once the write-out is idle [ARCHITECTURE 1.3 item 4: the last write-out's last VRAM write accepted, or the
// eoe item leaving when the last entry is not written out]. ev_vid: the write-out reader's end on the last entry's tile
// when it is written out, else with ev_tsp [G, GAP T15].
module p2_tbuf_ctl
  import p2_pkg::*;
#(
  parameter int P2_HS = 0      // p2_tbuf_hs: 0 refsw3's (every action waits for the write-out), 1 the [G] lost handshake
) (
  input  logic          clk,
  input  logic          rst,
  input  logic          flush,          // a render's start
  // the eoe point leaving P10; p2_entq's head
  input  logic          p10_eoe,
  input  logic          eq_v,
  output logic          eq_rdy,
  input  p2_entrec_t    eq,
  // the buffers, the pipe
  output logic          swap,
  output logic          hold,
  // p2_wout
  output logic          wo_start,
  output logic [5:0]    wo_tx,
  output logic [5:0]    wo_ty,
  output logic          wo_eof,
  input  logic          wo_busy,
  input  logic          wo_rd_done,
  // events
  output logic          ev_tsp,
  output logic          ev_vid,
  output logic          idle            // no action pending, the frame's end done
);
  typedef enum logic [1:0] { A_NONE, A_SWAP, A_WRITE } act_t;

  logic        prev_wo, have_prev;
  logic [5:0]  prev_x, prev_y;
  logic        p_v, p_last;            // an action pending; the render's last entry's
  act_t        p_act;
  logic [5:0]  p_x, p_y;
  typedef enum logic [2:0] { F_IDLE, F_W0, F_EOF, F_W1, F_END } fst_t;
  fst_t        fs;

  // the decision
  logic        ekz, eanw;
  act_t        act;
  assign ekz    = eq.z_keep && !eq.shaded_any && prev_wo;
  assign eanw   = eq.z_keep && !eq.shaded_any && !prev_wo && have_prev;
  assign act    = eq.no_writeout ? A_NONE : (ekz ? A_SWAP : A_WRITE);
  assign eq_rdy = p10_eoe;

  // when the pending action goes
  logic go, lost;
  p2_tbuf_hs #(.P2_HS(P2_HS)) u_hs (.is_swap(p_act == A_SWAP), .is_write(p_act == A_WRITE), .wo_busy, .go, .lost);
  logic done;
  assign done     = p_v && (p_act == A_NONE || go);
  assign swap     = p_v && go && p_act != A_NONE;
  assign wo_start = p_v && go && p_act == A_WRITE && !lost;
  assign wo_tx    = p_x;
  assign wo_ty    = p_y;
  assign hold     = p_v;
  assign wo_eof   = fs == F_EOF && !wo_busy;
  assign idle     = !p_v && fs == F_IDLE;

  logic last_wr, vid_done;              // the last entry started a write-out (ev_vid at its reader's end); ev_vid sent
  always_ff @(posedge clk) begin
    if (rst || flush) begin
      prev_wo   <= 1'b0;
      have_prev <= 1'b0;
      p_v       <= 1'b0;
      fs        <= F_IDLE;
      ev_tsp    <= 1'b0;
      ev_vid    <= 1'b0;
      last_wr   <= 1'b0;
      vid_done  <= 1'b0;
    end else begin
      ev_tsp <= 1'b0;
      ev_vid <= 1'b0;
      if (p10_eoe) begin
        prev_wo   <= !eq.no_writeout && !ekz;
        prev_x    <= eq.tilex;
        prev_y    <= eq.tiley;
        have_prev <= 1'b1;
        p_v       <= 1'b1;
        p_act     <= act;
        p_x       <= eanw ? prev_x : eq.tilex;
        p_y       <= eanw ? prev_y : eq.tiley;
        p_last    <= eq.last;
      end else if (done) begin
        p_v <= 1'b0;
        if (p_last) begin
          fs       <= F_W0;
          last_wr  <= p_act == A_WRITE && !lost;
          vid_done <= 1'b0;
        end
      end
      if (wo_rd_done && last_wr) begin
        ev_vid   <= 1'b1;
        last_wr  <= 1'b0;
        vid_done <= 1'b1;
      end
      case (fs)
        F_W0:    fs <= F_EOF;                  // the write-out's busy rises the clock after its start
        F_EOF:   if (!wo_busy) fs <= F_W1;     // the frame's end issued (wo_eof)
        F_W1:    fs <= F_END;
        F_END:   if (!wo_busy) begin
                   fs     <= F_IDLE;
                   ev_tsp <= 1'b1;
                   if (!vid_done)
                     ev_vid <= 1'b1;
                 end
        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (!rst && p10_eoe && !eq_v)
      $error("p2_tbuf_ctl: an eoe point left P10 with no record in p2_entq");
  always_ff @(posedge clk)
    if (!rst && p10_eoe && p_v)
      $error("p2_tbuf_ctl: an eoe point left P10 with the last entry's action still pending");
`endif
endmodule

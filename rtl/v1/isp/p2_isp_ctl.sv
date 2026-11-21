// p2_isp_ctl: the ISP's entry, phase, chunk and pass controller (PLAN M6, M7; ARCHITECTURE 3.4.1; isp 1, 4.1, 4.2, 11;
// refcore refsw_lists.cpp RenderCORE's entry at refsw3 4f3efe15). The phase order is RenderCORE's:
//
//   Z         !z_keep: buf CLEAR with key bgkey(ISP_BACKGND_D) (p2_zword_pkg, RenderCORE's bgZ block: pvr-tests/bgdepth,
//             bgtie, bgspec, bgneg, depthgaps_bglow*, depthgaps_bgpin) and tag ISP_BACKGND_T, all 32 bits; z_keep: buf
//             CLRSTATUS (ClearParamStatusBuffer: keep Z keeps the stencil, isp 15 #17)
//   OP        the opaque list walked as OPAQUE, if the entry has one
//   OP_MOD    the opaque modifier list walked as MODIFIER, if the entry has both (never with no OP list: isp 15 #18)
//   OpInPt    the punch-through list scanned (olw ObjectListHasPrimitive): it HOLDS a primitive (isp 11.3; optcull)
//   OP_SHADE  SHADE(OPAQUE) (through p2_isp_ctl_tg, a pass-through until T21)
//   PT        PT_INIT; pcache reset; per chunk c (PT_CHUNK from the second; pcache reset): per pass p, PASS_START (rlp =
//             rcur), more = 0, the pass's walk: p = 0 a walk through p2_isp_ptc (chunk 0 from the list's start, a later
//             chunk continues where the last stopped: the held descriptor is its first member) filling pcache, p > 0
//             pcache's replay (in full-walk mode, after a chunk overflowed pcache, every pass a walk from the list's
//             start); PT_WALK; !more: the chunk's end; else SHADE(PT_PASS0), wait for PASS_DONE (p2_isp_fb); PT_SHADE;
//             !anyfail: the chunk's end. The chunk's end: another chunk if ptc counted one (more_chunks), else PT_FINAL;
//             then with an OP_MOD list its walk again (PT_MOD) and SHADE(PT_MV) (PT_MV_SHADE)
//   TR        pre_sort: CLRSTATUS, the list walked as TR_PRESORT with a SHADE after every primitive (the raster takes one
//             descriptor, its rows are written, the SHADE is issued, then the next) (TR_PS)
//             else SAVE (TR_SAVE); per pass PEEL(bits(0x7F7FFFFF)) (TR_PEEL), more = 0, the list walked (pass 0, filling
//             pcache in units) or replayed (later passes; walked when pcache overflowed) as TR_AUTOSORT (TR_WALK), the
//             TR_MOD list walked as MODIFIER every pass (TR_MOD), SHADE(AUTOSORT) (TR_SHADE), again while more; RESTORE
//             (TR_RESTORE)
//   END       the entry's end: the last SHADE carried `last` (its last run eoe) when ctl knew at its issue that it was
//             the last (OP_SHADE with no PT and no TR, PT_MV_SHADE with no TR, the sort's last pass); otherwise an END
//             command to the cutter (a null eoe item) [ARCHITECTURE 3.4.8]
//
// A walk is done when olw, pfetch, setup (its hand-off too), the raster and pix are all idle; a punch-through walk also
// when ptc holds the next chunk's first descriptor (with the raster and pix idle); a replay when pcache has handed on
// its last descriptor and the raster and pix are idle. MoreToDraw is p2_isp_pix's (more_clr before each walk).
//
// The entry's next phase never waits for the cutter, except for a punch-through pass's PASS_DONE (refsw3's order; probe
// T20): the row barrier (p2_isp_buf, p2_isp_cut) holds every row write of a later epoch until the cutter has passed the
// row. The next entry is accepted once this one's last command has been issued (ARCHITECTURE 3.4.1 "Entry k+1 starts").
// A SHADE is issued when the cutter's command slot is free.
//
// Phase halt (sim; PLAN 1.3): with halt_en, after each phase the controller stops with `halted` and the phase's number
// (tb/common/isp_live.h's Phase) until `resume`; after a SHADE phase (and END) it first waits for the cutter to be idle,
// so that the pass's runs are all out. A phase the entry does not have is not run and does not halt. In free-running
// mode (halt_en = 0) nothing waits for the cutter but the slot.
//
// P2_PTCARRY (ARCHITECTURE 3.4.1, PLAN M7): 0, refsw3's punch-through chunk boundary (no carry). The candidate mechanisms
// K1 / K2 wait for probe T12.
//
// Cycle [G CTL_T = 1, ARCHITECTURE 6; T13]: each transition takes one clock.
module p2_isp_ctl
  import p2_pkg::*;
  import p2_regs_pkg::*;
#(
  parameter int P2_PTCARRY = 0
) (
  input  logic          clk,
  input  logic          rst,
  // entries (p2_seq), valid/ready
  input  logic          ent_v,
  output logic          ent_rdy,
  input  p2_entry_t     ent,
  // the render's registers
  input  logic [31:0]   bg_tag,          // ISP_BACKGND_T
  input  logic [31:0]   bg_depth,        // ISP_BACKGND_D
  // sweeps (p2_isp_buf)
  output logic          sw_v,
  output p2_sweep_t     sw_op,
  output p2_zkey_t      sw_key,
  output logic [31:0]   sw_tag,
  input  logic          sw_busy,
  // walks (p2_isp_olw; the rm and the tile for pfetch)
  output logic          walk_v,
  output logic [23:0]   walk_addr,
  output logic          walk_scan,
  output p2_rm_t        walk_rm,
  output logic [5:0]    tilex,
  output logic [5:0]    tiley,
  input  logic          has_prim,        // the scan's answer
  input  logic          front_idle,      // olw, pfetch, setup (and its hand-off) idle
  input  logic          back_idle,       // the raster and pix idle
  input  logic          ho_take,         // the raster took a descriptor from the setup side
  output logic          ho_block,        // TR_PRESORT: the next descriptor waits for the SHADE
  input  logic          more,            // MoreToDraw (p2_isp_pix)
  output logic          more_clr,
  // p2_isp_ptc
  output logic          pt,
  output logic          pt_en,
  output logic          pt_restart,
  output logic          pt_set_cur,
  output logic [15:0]   pt_cur,
  output logic          pt_fw_clr,
  input  logic          pt_fw,
  input  logic          pt_hold,
  input  logic          pt_more_chunks,
  // p2_isp_pcache
  output logic          pc_reset,
  output logic          pc_tr,
  output logic          pc_fill_en,
  input  logic          pc_ovf,
  output logic          rp_start,
  input  logic          rp_busy,
  output logic          src_rp,          // the raster's input is pcache's replay
  // p2_isp_cut
  output logic          cmd_v,
  input  logic          cmd_rdy,
  output logic          cmd_end,
  output p2_rm_t        cmd_rm,
  output logic          cmd_opinpt,
  output logic          cmd_last,
  output p2_entrec_t    cmd_rec,
  input  logic          cut_idle,
  // p2_isp_fb
  input  logic          pass_done,
  input  logic          anyfail,
  // phase halt (sim)
  input  logic          halt_en,
  input  logic          resume,
  output logic          halted,
  output logic [4:0]    halt_phase,
  // status
  output logic          busy,            // an entry is in progress
  output logic          ent_done,        // a 1-clock pulse: the entry's ISP work is over
  output logic [15:0]   st_chunks,       // this entry's punch-through chunks, passes (walks), sort passes
  output logic [15:0]   st_passes,
  output logic [15:0]   st_trpasses,
  output logic [15:0]   st_ptshades      // ... and punch-through SHADEs (a pass that drew)
);
  // tb/common/isp_live.h Phase
  localparam logic [4:0] PH_Z = 5'd0, PH_OP = 5'd1, PH_OP_MOD = 5'd2, PH_OP_SHADE = 5'd3, PH_PT_INIT = 5'd4,
                         PH_PT_CHUNK = 5'd5, PH_PT_WALK = 5'd6, PH_PT_SHADE = 5'd7, PH_PT_FINAL = 5'd8,
                         PH_PT_MOD = 5'd9, PH_PT_MV_SHADE = 5'd10, PH_TR_PS = 5'd11, PH_TR_SAVE = 5'd12,
                         PH_TR_PEEL = 5'd13, PH_TR_WALK = 5'd14, PH_TR_MOD = 5'd15, PH_TR_SHADE = 5'd16,
                         PH_TR_RESTORE = 5'd17, PH_END = 5'd18;
  localparam p2_zkey_t PEEL_KEY = p2_zword_pkg::bits(32'h7F7F_FFFF);   // the largest finite float

  typedef enum logic [4:0] {
    S_IDLE, S_SW, S_SWW, S_WK, S_WKW, S_SCAN, S_SCANW, S_SH, S_SHW, S_PASS, S_PASSW, S_PW, S_PWW, S_PSH, S_PSHW,
    S_PSW, S_PSWW, S_PSSH, S_TW, S_TWW, S_END, S_ENDW, S_HALT, S_FIN, S_NEXT
  } st_t;
  st_t        st, after;           // after: where S_HALT goes on resume
  p2_entry_t  e;
  logic [4:0] ph;                  // the phase in progress (its halt number)
  p2_sweep_t  sw_q;
  logic [23:0] wk_addr;
  p2_rm_t     rm_q;
  logic       opinpt, eoe_sent, ps_wait;
  logic [15:0] chunk, pass, trpass, pt_shades, pass_tot;
  // the SHADE to issue (S_SH)
  p2_rm_t     sh_rm;
  logic       sh_last;

  assign ent_rdy = st == S_IDLE;
  assign busy    = st != S_IDLE;
  assign tilex   = e.tilex;
  assign tiley   = e.tiley;
  assign halted  = st == S_HALT;
  assign walk_rm = rm_q;

  // the entry's lists
  logic has_op, has_opm, has_tr, has_trm, has_pt;
  assign has_op  = !e.empty[P2_LIST_OP];
  assign has_opm = !e.empty[P2_LIST_OP_MOD];
  assign has_tr  = !e.empty[P2_LIST_TR];
  assign has_trm = !e.empty[P2_LIST_TR_MOD];
  assign has_pt  = !e.empty[P2_LIST_PT];
  assign st_chunks   = has_pt ? chunk + 16'd1 : '0;
  assign st_passes   = pass_tot;
  assign st_trpasses = trpass + 16'(has_tr && !e.pre_sort);
  assign st_ptshades = pt_shades;

  // a punch-through pass / a sort pass after the first: pcache's replay (a walk after an overflow)
  logic pt_rp, tr_rp;
  assign pt_rp = pass != '0 && !pt_fw;
  assign tr_rp = trpass != '0 && !pc_ovf;

`ifndef SYNTHESIS
  initial
    if (P2_PTCARRY != 0)
      $fatal(1, "p2_isp_ctl: P2_PTCARRY %0d: only 0 (refsw3, no carry) is built until probe T12", P2_PTCARRY);
`endif

  // ---------------------------------------------------------------------------------------------- the outputs
  logic shade_op, sh_go;
  p2_isp_ctl_tg u_tg (.shade_in(1'b1), .shade_out(shade_op));
  assign sh_go = ph != PH_OP_SHADE || shade_op;

  always_comb begin
    sw_v       = st == S_SW || st == S_PASS;
    sw_op      = st == S_PASS ? P2_SW_PASS_START : sw_q;
    sw_key     = sw_q == P2_SW_PEEL ? PEEL_KEY : p2_zword_pkg::bgkey(bg_depth);
    sw_tag     = bg_tag;
    walk_v     = st == S_WK || (st == S_SCAN && has_pt) || st == S_PSW ||
                 (st == S_PW && (pt_fw || (pass == '0 && chunk == '0))) || (st == S_TW && !tr_rp);
    walk_addr  = st == S_SCAN ? {e.ptr[P2_LIST_PT], 2'b00} : wk_addr;
    walk_scan  = st == S_SCAN;
    more_clr   = st == S_PW || st == S_TW;
    pt_restart = st == S_PW && (pt_fw ? 1'b1 : (pass == '0 && chunk == '0));
    pt_set_cur = st == S_PW && pass == '0;
    pt_cur     = chunk;
    pt_en      = (st == S_PW || st == S_PWW) && (pass == '0 || pt_fw);
    pt_fw_clr  = st == S_SW && sw_q == P2_SW_PT_INIT;
    pc_reset   = st == S_SW && (sw_q == P2_SW_PT_INIT || sw_q == P2_SW_PT_CHUNK || sw_q == P2_SW_PEEL && trpass == '0);
    pc_tr      = !pt;
    pc_fill_en = ((st == S_PW || st == S_PWW) && pass == '0 && !pt_fw) || ((st == S_TW || st == S_TWW) && trpass == '0);
    rp_start   = (st == S_PW && pt_rp) || (st == S_TW && tr_rp);
    src_rp     = ((st == S_PW || st == S_PWW) && pt_rp) || ((st == S_TW || st == S_TWW) && tr_rp);
    ho_block   = ps_wait;
    cmd_v      = (st == S_SH && sh_go) || st == S_PSH || st == S_PSSH || (st == S_END && !eoe_sent);
    cmd_end    = st == S_END;
    cmd_rm     = st == S_PSH ? P2_RM_PUNCHTHROUGH_PASS0 : (st == S_PSSH ? P2_RM_TRANSLUCENT_PRESORT : sh_rm);
    cmd_opinpt = opinpt;
    cmd_last   = st == S_SH && sh_last;
    cmd_rec    = '0;
    cmd_rec.tilex       = e.tilex;
    cmd_rec.tiley       = e.tiley;
    cmd_rec.z_keep      = e.z_keep;
    cmd_rec.no_writeout = e.no_writeout;
    cmd_rec.last        = e.last;
  end

  // the punch-through phase: from PT_INIT to the last chunk's end
  logic pt_q;
  assign pt = pt_q;

  // ---------------------------------------------------------------------------------------------- the next phase
  // after the phase `ph` (its work done): the state that follows it
  st_t nx;
  always_comb begin
    unique case (ph)
      PH_Z:           nx = has_op ? S_WK : S_SCAN;
      PH_OP:          nx = has_opm ? S_WK : S_SCAN;
      PH_OP_MOD:      nx = S_SCAN;
      PH_OP_SHADE:    nx = has_pt ? S_SW : (has_tr ? S_SW : S_END);
      PH_PT_INIT,
      PH_PT_CHUNK:    nx = S_PASS;
      PH_PT_WALK:     nx = more ? S_PSH : S_SW;
      PH_PT_SHADE:    nx = anyfail ? S_PASS : S_SW;
      PH_PT_FINAL:    nx = has_opm ? S_WK : (has_tr ? S_SW : S_END);
      PH_PT_MOD:      nx = S_SH;
      PH_PT_MV_SHADE: nx = has_tr ? S_SW : S_END;
      PH_TR_PS:       nx = S_END;
      PH_TR_SAVE:     nx = S_SW;
      PH_TR_PEEL:     nx = S_TW;
      PH_TR_WALK:     nx = has_trm ? S_WK : S_SH;
      PH_TR_MOD:      nx = S_SH;
      PH_TR_SHADE:    nx = S_SW;
      PH_TR_RESTORE:  nx = S_END;
      default:        nx = S_FIN;
    endcase
  end

  // S_NEXT sets up the state it goes to (the sweep, the walk, the SHADE) and the phase that follows
  always_ff @(posedge clk) begin
    ent_done <= 1'b0;
    if (rst) begin
      st      <= S_IDLE;
      pt_q    <= 1'b0;
      ps_wait <= 1'b0;
    end else begin
      unique case (st)
        S_IDLE:
          if (ent_v) begin
            e         <= ent;
            chunk     <= '0;
            pass      <= '0;
            pass_tot  <= '0;
            trpass    <= '0;
            pt_shades <= '0;
            opinpt    <= 1'b0;
            eoe_sent  <= 1'b0;
            ph        <= PH_Z;
            sw_q      <= ent.z_keep ? P2_SW_CLRSTATUS : P2_SW_CLEAR;
            st        <= S_SW;
          end
        // ---- a sweep (its phase is ph)
        S_SW: st <= S_SWW;                                        // buf takes it (sw_v): busy from the next clock
        S_SWW:
          if (!sw_busy) begin
            if (sw_q == P2_SW_CLRSTATUS && ph == PH_TR_PS)
              st <= S_PSW;                                        // the pre-sorted walk follows its status clear
            else
              st <= S_NEXT;
          end
        // ---- a list walk: OP, OP_MOD, PT_MOD, TR_MOD (ph)
        S_WK: st <= S_WKW;
        S_WKW:
          if (front_idle && back_idle)
            st <= S_NEXT;
        // ---- OpInPt: the punch-through list holds a primitive
        S_SCAN:
          if (has_pt)
            st <= S_SCANW;
          else begin
            opinpt <= 1'b0;
            st     <= S_SH;
          end
        S_SCANW:
          if (front_idle) begin
            opinpt <= has_prim;
            st     <= S_SH;
          end
        // ---- a SHADE (sh_rm, sh_last; ph): issued when the cutter's slot is free
        S_SH:
          if (!sh_go)
            st <= S_SHW;
          else if (cmd_rdy) begin
            if (sh_last)
              eoe_sent <= 1'b1;
            st <= S_SHW;
          end
        S_SHW:
          if (!halt_en || cut_idle)
            st <= S_NEXT;
        // ---- a punch-through pass: PASS_START, the walk (or replay), the SHADE, PASS_DONE
        S_PASS: st <= S_PASSW;
        S_PASSW:
          if (!sw_busy)
            st <= S_PW;
        S_PW: st <= S_PWW;                                        // the walk / replay starts (walk_v, rp_start, set_cur)
        S_PWW:
          if (back_idle && (src_rp ? !rp_busy : (front_idle || pt_hold))) begin
            pass_tot <= pass_tot + 16'd1;
            ph       <= PH_PT_WALK;
            st       <= S_NEXT;
          end
        S_PSH:
          if (cmd_rdy) begin
            pt_shades <= pt_shades + 16'd1;
            st        <= S_PSHW;
          end
        S_PSHW:
          if (pass_done) begin
            pass <= pass + 16'd1;
            ph   <= PH_PT_SHADE;
            st   <= S_NEXT;
          end
        // ---- the pre-sorted walk: one descriptor, its rows, its SHADE
        S_PSW: st <= S_PSWW;
        S_PSWW:
          if (ps_wait) begin
            if (back_idle)
              st <= S_PSSH;
          end else if (ho_take)
            ps_wait <= 1'b1;
          else if (front_idle && back_idle)
            st <= S_NEXT;
        S_PSSH:
          if (cmd_rdy) begin
            ps_wait <= 1'b0;
            st      <= S_PSWW;
          end
        // ---- a sort pass's walk (or replay)
        S_TW: st <= S_TWW;
        S_TWW:
          if (back_idle && (src_rp ? !rp_busy : front_idle)) begin
            ph <= PH_TR_WALK;
            st <= S_NEXT;
          end
        // ---- the entry's end
        S_END:
          if (eoe_sent || cmd_rdy) begin
            eoe_sent <= 1'b1;
            st       <= S_ENDW;
          end
        S_ENDW:
          if (!halt_en || cut_idle) begin
            ph <= PH_END;
            st <= S_NEXT;
          end
        S_HALT:
          if (resume)
            st <= after;
        S_FIN: begin
          ent_done <= 1'b1;
          st       <= S_IDLE;
        end
        // ---- the phase `ph` is over: halt, then what follows it
        S_NEXT: if (!halt_en || cut_idle) begin
          // (a halt waits for the cutter: the phase's runs are all out, TR_PS's last SHADE too)
          unique case (ph)
            PH_Z: begin
              ph      <= has_op ? PH_OP : PH_OP_SHADE;
              wk_addr <= {e.ptr[P2_LIST_OP], 2'b00};
              rm_q    <= P2_RM_OPAQUE;
            end
            PH_OP: begin
              ph      <= has_opm ? PH_OP_MOD : PH_OP_SHADE;
              wk_addr <= {e.ptr[P2_LIST_OP_MOD], 2'b00};
              rm_q    <= P2_RM_MODIFIER;
            end
            PH_OP_MOD:
              ph <= PH_OP_SHADE;
            PH_OP_SHADE: begin
              if (has_pt) begin
                ph   <= PH_PT_INIT;
                sw_q <= P2_SW_PT_INIT;
              end else if (has_tr) begin
                ph   <= e.pre_sort ? PH_TR_PS : PH_TR_SAVE;
                sw_q <= e.pre_sort ? P2_SW_CLRSTATUS : P2_SW_SAVE;
              end
            end
            PH_PT_INIT, PH_PT_CHUNK: begin
              pass    <= '0;
              wk_addr <= {e.ptr[P2_LIST_PT], 2'b00};
              rm_q    <= P2_RM_PUNCHTHROUGH_PASS0;
            end
            PH_PT_WALK, PH_PT_SHADE: begin
              if (ph == PH_PT_WALK && more) begin
                ph <= PH_PT_SHADE;
              end else if (ph == PH_PT_SHADE && anyfail) begin
                rm_q <= pt_fw ? P2_RM_PUNCHTHROUGH_PASSN : P2_RM_PUNCHTHROUGH_PASS0;
              end else if (pt_more_chunks) begin
                chunk <= chunk + 16'd1;
                ph    <= PH_PT_CHUNK;
                sw_q  <= P2_SW_PT_CHUNK;
              end else begin
                ph   <= PH_PT_FINAL;
                sw_q <= P2_SW_PT_FINAL;
              end
            end
            PH_PT_FINAL: begin
              pt_q <= 1'b0;
              if (has_opm) begin
                ph      <= PH_PT_MOD;
                wk_addr <= {e.ptr[P2_LIST_OP_MOD], 2'b00};
                rm_q    <= P2_RM_MODIFIER;
              end else if (has_tr) begin
                ph   <= e.pre_sort ? PH_TR_PS : PH_TR_SAVE;
                sw_q <= e.pre_sort ? P2_SW_CLRSTATUS : P2_SW_SAVE;
              end
            end
            PH_PT_MOD:
              ph <= PH_PT_MV_SHADE;
            PH_PT_MV_SHADE:
              if (has_tr) begin
                ph   <= e.pre_sort ? PH_TR_PS : PH_TR_SAVE;
                sw_q <= e.pre_sort ? P2_SW_CLRSTATUS : P2_SW_SAVE;
              end
            PH_TR_SAVE, PH_TR_SHADE: begin
              if (ph == PH_TR_SHADE && !more) begin
                ph   <= PH_TR_RESTORE;
                sw_q <= P2_SW_RESTORE;
              end else begin
                if (ph == PH_TR_SHADE)
                  trpass <= trpass + 16'd1;
                ph   <= PH_TR_PEEL;
                sw_q <= P2_SW_PEEL;
              end
            end
            PH_TR_PEEL: begin
              wk_addr <= {e.ptr[P2_LIST_TR], 2'b00};
              rm_q    <= P2_RM_TRANSLUCENT_AUTOSORT;
            end
            PH_TR_WALK:
              if (has_trm) begin
                ph      <= PH_TR_MOD;
                wk_addr <= {e.ptr[P2_LIST_TR_MOD], 2'b00};
                rm_q    <= P2_RM_MODIFIER;
              end else
                ph <= PH_TR_SHADE;
            PH_TR_MOD:
              ph <= PH_TR_SHADE;
            default: ;
          endcase
          // the TR_PS walk's rm and list (after its status clear)
          if ((ph == PH_OP_SHADE && !has_pt || ph == PH_PT_FINAL && !has_opm || ph == PH_PT_MV_SHADE) && has_tr &&
              e.pre_sort) begin
            wk_addr <= {e.ptr[P2_LIST_TR], 2'b00};
            rm_q    <= P2_RM_TRANSLUCENT_PRESORT;
          end
          // the punch-through phase starts with PT_INIT
          if (ph == PH_OP_SHADE && has_pt)
            pt_q <= 1'b1;
          // the SHADEs and what they know: is it the entry's last?
          if ((ph == PH_OP && !has_opm) || ph == PH_OP_MOD || ph == PH_Z && !has_op) begin
            sh_rm   <= P2_RM_OPAQUE;
            sh_last <= !has_pt && !has_tr;
          end
          if (ph == PH_PT_MOD) begin
            sh_rm   <= P2_RM_PUNCHTHROUGH_MV;
            sh_last <= !has_tr;
          end
          if (ph == PH_TR_WALK && !has_trm || ph == PH_TR_MOD) begin
            sh_rm   <= P2_RM_TRANSLUCENT_AUTOSORT;
            sh_last <= !more;
          end
          if (halt_en) begin
            st         <= S_HALT;
            halt_phase <= ph;
            after      <= nx;
          end else
            st <= nx;
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule

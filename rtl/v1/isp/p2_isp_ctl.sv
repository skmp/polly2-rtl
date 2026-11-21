// p2_isp_ctl: the ISP's entry and phase controller (PLAN M6; ARCHITECTURE 3.4.1; isp 1, 4.1, 4.2, 11.1, 11.2; refcore
// refsw_lists.cpp RenderCORE's entry at refsw3 4f3efe15). M6 has the entry's first phases; OpInPt, the SHADE passes,
// punch-through and translucent are M7's:
//
//   Z       !z_keep: buf CLEAR with key bgkey(ISP_BACKGND_D) (p2_zword_pkg, RenderCORE's bgZ block: dreamcast-tests
//           pvr-tests/bgdepth, bgtie, bgspec, bgneg, depthgaps_bglow*, depthgaps_bgpin) and tag ISP_BACKGND_T, all 32
//           bits; z_keep: buf CLRSTATUS (ClearParamStatusBuffer: keep Z keeps the stencil, isp 15 #17)
//   OP      the opaque list walked as OPAQUE, if the entry has one
//   OP_MOD  the opaque modifier list walked as MODIFIER, if the entry has both (OP_MOD is never walked with no OP list:
//           RenderCORE nests it, isp 15 #18; its walk after the punch-through passes, PT_MOD, is M7's)
//
// A walk: olw streams the list, pfetch assembles, setup sets up, the raster steps rows, pix applies the rule. It is done
// when every one of them is idle (walk_idle, the AND of their idle outputs) after the walk's start.
//
// Phase halt (sim; PLAN 1.3 "phase-halt mode"): with halt_en, after each phase the controller stops with `halted` and the
// phase's number (tb/common/isp_live.h's Phase: Z 0, OP 1, OP_MOD 2) until `resume`; the tile testbench compares the
// state there. A phase the entry does not have is not run and does not halt (the phase driver calls no hook there).
//
// Cycle [G CTL_T = 1, ARCHITECTURE 6; T13]: each transition takes one clock. The entry's ISP work ends with its last
// phase; the next entry is accepted in the clock after (M7's cutter and row barrier let the ISP run on).
module p2_isp_ctl
  import p2_pkg::*;
  import p2_regs_pkg::*;
(
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
  // walks
  output logic          walk_v,          // start: olw takes walk_addr
  output logic [23:0]   walk_addr,
  output p2_rm_t        walk_rm,         // the walk's RenderMode (pfetch puts it in each primitive)
  output logic [5:0]    tilex,           // the entry's tile
  output logic [5:0]    tiley,
  input  logic          walk_idle,       // olw, pfetch, setup, raster, pix all idle
  // phase halt (sim)
  input  logic          halt_en,
  input  logic          resume,
  output logic          halted,
  output logic [4:0]    halt_phase,
  // status
  output logic          busy,            // an entry is in progress
  output logic          ent_done         // a 1-clock pulse: the entry's ISP work is over
);
  // tb/common/isp_live.h Phase
  localparam logic [4:0] PH_Z = 5'd0, PH_OP = 5'd1, PH_OP_MOD = 5'd2;

  typedef enum logic [3:0] {
    S_IDLE, S_Z, S_ZW, S_OP, S_OPW, S_MOD, S_MODW, S_HALT, S_END
  } st_t;
  st_t        st, after;           // after: where S_HALT goes on resume
  p2_entry_t  e;

  assign ent_rdy = st == S_IDLE;
  assign busy    = st != S_IDLE;
  assign tilex   = e.tilex;
  assign tiley   = e.tiley;

  always_comb begin
    sw_v      = st == S_Z;
    sw_op     = e.z_keep ? P2_SW_CLRSTATUS : P2_SW_CLEAR;
    sw_key    = p2_zword_pkg::bgkey(bg_depth);
    sw_tag    = bg_tag;
    walk_v    = st == S_OP || st == S_MOD;
    walk_addr = st == S_MOD ? {e.ptr[P2_LIST_OP_MOD], 2'b00} : {e.ptr[P2_LIST_OP], 2'b00};
    walk_rm   = (st == S_MOD || st == S_MODW) ? P2_RM_MODIFIER : P2_RM_OPAQUE;
  end

  assign halted = st == S_HALT;

  always_ff @(posedge clk) begin
    ent_done <= 1'b0;
    if (rst) begin
      st <= S_IDLE;
    end else begin
      unique case (st)
        S_IDLE:
          if (ent_v) begin
            e  <= ent;
            st <= S_Z;
          end
        S_Z: st <= S_ZW;                                          // buf takes the sweep (sw_v): busy from the next clock
        S_ZW:
          if (!sw_busy) begin
            // after Z: OP if the entry has an opaque list
            if (halt_en) begin
              st         <= S_HALT;
              halt_phase <= PH_Z;
              after      <= !e.empty[P2_LIST_OP] ? S_OP : S_END;
            end else
              st <= !e.empty[P2_LIST_OP] ? S_OP : S_END;
          end
        S_OP: st <= S_OPW;                                        // olw takes the walk (walk_v): not idle from the next clock
        S_OPW:
          if (walk_idle) begin
            if (halt_en) begin
              st         <= S_HALT;
              halt_phase <= PH_OP;
              after      <= !e.empty[P2_LIST_OP_MOD] ? S_MOD : S_END;
            end else
              st <= !e.empty[P2_LIST_OP_MOD] ? S_MOD : S_END;
          end
        S_MOD: st <= S_MODW;
        S_MODW:
          if (walk_idle) begin
            if (halt_en) begin
              st         <= S_HALT;
              halt_phase <= PH_OP_MOD;
              after      <= S_END;
            end else
              st <= S_END;
          end
        S_HALT:
          if (resume)
            st <= after;
        S_END: begin
          ent_done <= 1'b1;
          st       <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

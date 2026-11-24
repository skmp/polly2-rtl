// p2_pp_issue: the pixel pipe's P0, issue (PLAN M10; ARCHITECTURE 3.7.7 P0; refsw_tile.cpp RenderParamTags' loop over a
// span's pixels and PixelFlush_tsp's dispatch at refsw3 4f3efe15). It takes a run from p2_pxq's head and emits its points,
// one a clock, through the pipe's one global stall:
//
//   pixel n = 0 .. len - 1, x = run.x + n          the span from its first pixel (PlaneStepper3::SpanStart = span.x)
//   InVolume = vmask[n] && tag.shadow && rm not PT_PASS0 / PT_PASSN       (RenderParamTags: volHit && t.shadow; the PT
//                                                  passes shade without the volume) [uvrun kinds 1, 2; modvol]
//   the volume's words: InVolume's entry (the second volume's, or the intensity entry's: p2_tsp_store's vsel)
//   ro    = rm in {PT_PASS0, PT_PASSN} && pmask[n]                (keepRes: a pixel resolved in the pass before)
//   atest = rm in {PT_PASS0, PT_PASSN} || (rm == PT_MV && pmask[n])     (PixelFlush_tsp's pp_AlphaTest)
//   SupSample (the volume's TSP bit 12): four points (hx, hy) = (0, 0), (1, 0), (0, 1), (1, 1), one a clock
//                                                  (PixelFlush_tsp's `super` loop, k = 0 .. 3: hx = k & 1, hy = k >> 1)
//                                                  [supsample, supsample2; one point a clock G T16]
// A null item is one point with its flags and no pixel. The run's first point carries its plane words to P1
// (p2_pp_plane loads its accumulators there). A pixel's credit returns to p2_pxq at its last point.
// The pass drain [G, ARCHITECTURE 3.7.7 "Cycle": D_PP fitted on B = 1035 clk for 1024 px in MT6]: after the point that
// carries eop, P0 issues nothing until that point has left the pipe (drain_done, from its end: P3 in M10, P10 from M11).
// M11: not after a pre-sorted translucent pass. TR_PRESORT shades every primitive in a pass of its own, and its
// primitives' pixels go through the pipe back to back: primitive k's last pixel and k + 1's first at the same place one
// clock apart, the blend's read of the second taking the first's write through the P10 forward (ARCHITECTURE 3.7.7
// "Hazards") [I: no stall is measured there; tim 3.3 "pre-sorted translucent: drawn in list order"].
module p2_pp_issue
  import p2_regs_pkg::*;
  import p2_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic                                clk,
  input  logic                                rst,
  input  logic                                stall,      // the pipe's global stall
  // p2_pxq's head
  input  logic                                q_v,
  output logic                                q_rdy,
  input  p2_tsp_rdesc_t                       q_d,
  output logic                                cred_ret,
  // the point to P1
  output logic                                p_v,
  output p2_pp_ctl_t                          p_ctl,
  output logic                                p_first,    // the run's first point: run_pl is the run's
  output p2_tsp_pev_t [1:0][P2_TSP_NPL-1:0]   run_pl,
  // the pass drain: the eop point left the pipe
  input  logic                                drain_done,
  output logic                                t_drain     // waiting for the drain (statistics)
);
  p2_tsp_rdesc_t          cur;
  logic                   cur_v, draining;
  logic [P2_TILE_LOG2-1:0] n;
  logic [1:0]             pt;           // the point of a SupSample pixel

  logic       pt_pass, vol_ok, invol, sup, pxlast, lastpt, issue;
  p2_tsp_hdr_t hv;
  assign pt_pass = cur.item.rm == P2_RM_PUNCHTHROUGH_PASS0 || cur.item.rm == P2_RM_PUNCHTHROUGH_PASSN;
  assign vol_ok  = cur.item.tag.shadow && !pt_pass;
  assign invol   = vol_ok && cur.item.vmask[n];
  assign hv      = cur.vol[invol].hdr;
  assign sup     = !cur.item.null_ && hv.tsp[12];
  assign pxlast  = !sup || pt == 2'd3;
  assign lastpt  = cur.item.null_ || (pxlast && n == cur.item.lenm1);

  assign p_v     = cur_v && !draining;
  assign issue   = p_v && !stall;
  assign q_rdy   = !stall && !draining && (!cur_v || lastpt);
  assign cred_ret = issue && !cur.item.null_ && pxlast;
  assign p_first = !cur.item.null_ && n == '0 && pt == 2'd0;
  assign t_drain = draining;
  always_comb
    for (int v = 0; v < 2; v++)
      run_pl[v] = cur.vol[v].pl;

  always_comb begin
    p_ctl        = '0;
    p_ctl.null_  = cur.item.null_;
    p_ctl.eop    = lastpt && cur.item.eop;
    p_ctl.eoe    = lastpt && cur.item.eoe;
    p_ctl.last   = lastpt;
    p_ctl.need   = cur.need;
    p_ctl.sidx   = cur.sidx;
    p_ctl.tag    = cur.item.tag;
    p_ctl.rm     = cur.item.rm;
    p_ctl.tilex  = cur.tilex;
    p_ctl.tiley  = cur.tiley;
    p_ctl.y      = cur.item.y;
    p_ctl.x      = cur.item.x + n;
    p_ctl.n      = n;
    p_ctl.vsel   = invol;
    p_ctl.ro     = pt_pass && cur.item.pmask[n];
    p_ctl.atest  = pt_pass || (cur.item.rm == P2_RM_PUNCHTHROUGH_MV && cur.item.pmask[n]);
    p_ctl.super_ = sup;
    p_ctl.hx     = sup && pt[0];
    p_ctl.hy     = sup && pt[1];
    p_ctl.pxlast = pxlast;
    p_ctl.hdr    = hv;
    p_ctl.k      = cur.vol[invol].k;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      cur_v    <= 1'b0;
      draining <= 1'b0;
      n        <= '0;
      pt       <= '0;
    end else begin
      if (draining && drain_done) draining <= 1'b0;
      if (issue) begin
        if (lastpt) begin
          cur_v <= 1'b0;
          n     <= '0;
          pt    <= '0;
          if (cur.item.eop && cur.item.rm != P2_RM_TRANSLUCENT_PRESORT) draining <= 1'b1;
        end else if (pxlast) begin
          n  <= n + 1'b1;
          pt <= '0;
        end else begin
          pt <= pt + 2'd1;
        end
      end
      if (q_v && q_rdy) begin
        cur   <= q_d;
        cur_v <= 1'b1;
        n     <= '0;
        pt    <= '0;
      end
    end
  end
endmodule

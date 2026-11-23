// p2_pp_plane: the pixel pipe's P1, the plane values (PLAN M10; ARCHITECTURE 3.7.7 P1; tsp 5.3-5.5 at refsw3 4f3efe15:
// pvr_tsp_plane.h PlaneT::Value from the integer k on, refsw_tile.h PlaneStepper3::Val; num H12a). Per plane of the point's
// volume:
//
//   k = base + n step                       the run's first value, every further pixel adds F(A') [uvspan: 411,287 of
//                                           411,287 readings; a run is not cut at fixed columns: split=16 63,619 wrong]
//   SupSample point (hx, hy): k = base + (2n + hx) step2 + hy hyd      (half steps along the run, the centre's too;
//                                           a point half a line down: C + B/2 floored together, hyd) [supsample 798 /
//                                           870 / 2,119 wrong otherwise; ssrare; sshalf]
//   value = H12a(k, unit)                   16 bits from the leading one toward minus infinity, k = 0 +0, k = -1 the
//                                           -1-unit value -2^-143, the exponent floor -128 (p2_fp_value_norm) [uvmeas
//                                           wfixed, valueFixed: 30,852 .. 13,321,784 wrong with a fixed drop; wzero1;
//                                           wtiny]
// The steps accumulate (the accumulators acc, acc2: one per plane and volume, both volumes stepping every pixel, so that
// a run with mixed vmask has either volume's value at every pixel); 11 normalizers, the point's volume's planes. The
// run's words come with its first point (p2_pp_issue run_pl). Output registered: the P1 / P2 register.
module p2_pp_plane
  import p2_pkg::*;
  import p2_fp_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic                                clk,
  input  logic                                rst,
  input  logic                                stall,
  input  logic                                p_v,
  input  p2_pp_ctl_t                          p_ctl,
  input  logic                                p_first,
  input  p2_tsp_pev_t [1:0][P2_TSP_NPL-1:0]   run_pl,
  // P1 / P2
  output logic                                o_v,
  output p2_pp_ctl_t                          o_ctl,
  output p2_pval_t [P2_TSP_NPL-1:0]           o_val
);
  localparam int NPL = P2_TSP_NPL;
  localparam int KB  = P2_TSP_KBITS;

  // the run's words (from its first point) and the accumulators, per volume and plane
  logic signed [KB-1:0]                 acc  [2][NPL];   // base + n step
  logic signed [KB-1:0]                 acc2 [2][NPL];   // base + 2n step2
  logic signed [P2_TSP_STEPBITS-1:0]    r_step  [2][NPL];
  logic signed [P2_TSP_STEPBITS-1:0]    r_step2 [2][NPL];
  logic signed [P2_TSP_HYDBITS-1:0]     r_hyd   [2][NPL];
  logic signed [P2_FP_EW-1:0]           r_unit  [2][NPL];

  // this point's words: the run's own at its first point
  logic signed [KB-1:0]                 ka   [2][NPL];   // non-SupSample value
  logic signed [KB-1:0]                 ks   [2][NPL];   // SupSample: base + 2n step2
  logic signed [P2_TSP_STEPBITS-1:0]    w_step  [2][NPL];
  logic signed [P2_TSP_STEPBITS-1:0]    w_step2 [2][NPL];
  logic signed [P2_TSP_HYDBITS-1:0]     w_hyd   [2][NPL];
  logic signed [P2_FP_EW-1:0]           w_unit  [2][NPL];
  always_comb
    for (int v = 0; v < 2; v++)
      for (int p = 0; p < NPL; p++) begin
        w_step[v][p]  = p_first ? run_pl[v][p].step  : r_step[v][p];
        w_step2[v][p] = p_first ? run_pl[v][p].step2 : r_step2[v][p];
        w_hyd[v][p]   = p_first ? run_pl[v][p].hyd   : r_hyd[v][p];
        w_unit[v][p]  = p_first ? run_pl[v][p].unit  : r_unit[v][p];
        ka[v][p]      = p_first ? run_pl[v][p].base  : acc[v][p];
        ks[v][p]      = p_first ? run_pl[v][p].base  : acc2[v][p];
      end

  // the point's k per plane of its volume, and the normalizers
  logic signed [KB-1:0]       k  [NPL];
  logic signed [P2_FP_EW-1:0] ku [NPL];
  p2_pval_t [NPL-1:0]         val;
  genvar g;
  generate
    for (g = 0; g < NPL; g = g + 1) begin : g_pl
      always_comb begin
        logic signed [KB-1:0] hs, hl;
        hs = p_ctl.hx ? KB'(w_step2[p_ctl.vsel][g]) : '0;          // sign-extended (signed to signed)
        hl = p_ctl.hy ? KB'(w_hyd[p_ctl.vsel][g]) : '0;
        if (p_ctl.super_)
          k[g] = ks[p_ctl.vsel][g] + hs + hl;
        else
          k[g] = ka[p_ctl.vsel][g];
        ku[g] = w_unit[p_ctl.vsel][g];
      end
      p2_fp_value_norm #(.KW(KB)) u_norm (.k(k[g]), .unit(ku[g]), .o_neg(val[g].neg), .o_exp(val[g].exp), .o_mant(val[g].mant));
    end
  endgenerate

  logic adv;
  assign adv = p_v && !stall;

  always_ff @(posedge clk) begin
    if (rst) begin
      o_v <= 1'b0;
    end else if (!stall) begin
      o_v <= p_v;
    end
    if (adv) begin
      o_ctl <= p_ctl;
      o_val <= val;
      for (int v = 0; v < 2; v++)
        for (int p = 0; p < NPL; p++) begin
          if (p_first) begin
            r_step[v][p]  <= run_pl[v][p].step;
            r_step2[v][p] <= run_pl[v][p].step2;
            r_hyd[v][p]   <= run_pl[v][p].hyd;
            r_unit[v][p]  <= run_pl[v][p].unit;
          end
          // after the pixel's last point, the next pixel: + step, + 2 step2 (both volumes)
          if (p_ctl.pxlast) begin
            acc[v][p]  <= ka[v][p] + KB'(w_step[v][p]);
            acc2[v][p] <= ks[v][p] + KB'(w_step2[v][p]) + KB'(w_step2[v][p]);
          end else if (p_first) begin
            acc[v][p]  <= ka[v][p];
            acc2[v][p] <= ks[v][p];
          end
        end
    end
  end
endmodule

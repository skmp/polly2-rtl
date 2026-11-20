// p2_isp_alu: the ISP setup's arithmetic unit, driven by p2_isp_setup's microprogram (ARCHITECTURE 3.4.4 "Datapath";
// PLAN M4). P2_ISP_NM multipliers, P2_ISP_NA adders, one reciprocal and the operand register file; the numbers and the
// latencies are the free parameters of ARCHITECTURE 6, in the generated p2_isp_prog_pkg (tools/gen/gen_setup_prog.cpp).
//
//   multiplier  p2_fp_rng_mul 24 x 24 -> 24 (num H5 with the H10 depth flavour switchable per issue):
//                 MUL_E  the edge unit's Mul(a, b, productBits), then the swamp at 2^128 (num H7a; pvr_isp_edge.h the
//                        `swamp` lambda of EdgeWinding and EdgeTile::Setup) [faredge_cmax, faredge_m131]; operand a can be
//                        read through the swamp (the start's dxP = sw(dx), dyP = sw(dy): L192, L197)
//                 MUL_R  the depth setup's ranged `mul` (pvr_isp_depth.h L362-368: an infinity times a zero is a zero, the
//                        product limited at 2^128 and 2^-126) [zovf_ps, depthgaps_nanprod, zspec]
//                 MUL_U  Mul(a, b, coefBits), unranged (A = a inv, B: L659-660) [depthgaps_edges]
//   adder       p2_fp_rng_add 24 / 25, b negated for a subtraction (num H6 with H10):
//                 ADD_E  the edge unit's plain Add (P2_RNG_ADD_NONE: no range, no zero rule; isp 6.2), then nothing, the
//                        swamp, or the saturation to 2^127 (the start: L198-200) [faredge_cmax, hugepos a]
//                 ADD_Z  the depth setup's addRule with the zero rule (P2_RNG_ADD_DEPTH: add, subC, addE alike since
//                        0de9776b; DepthHW::zeroRuleCoords = zeroRuleEdges = 1, p2_hw_check) [depthgaps_zadd,
//                        depth2_zcoord, depth2_zedge]; the post-operation PERP makes a determinant at most FPU_PERP_VAL
//                        +0 (pvr_softfp.h Perpendicular, num H9) [perpval, perpeq, detinf]
//                 ADD_M1 / ADD_M2  the determinant-zero mean's sums (L646-653): two infinities of opposite signs as their
//                        23-bit fractions say, the larger fraction's (ADD_M1: the first two corners' fractions; ADD_M2:
//                        the sum's 0 against the third's), else ADD_Z [depthgaps_dzinf 48 / 48, perpmean_word]
//   reciprocal  p2_fp_recip24 (num H8; refsw3's inv0, inv and invS are one value)
//   registers   P2_ISP_NREG tuples: the inputs (loaded by `ld` when p2_isp_setup accepts a primitive) and one for every
//               value of the graphs (single assignment: no two writes to one register in a program)
//
// Timing [I: the structure the scheduler assumed]: an operation issued in step s reads its operands from the register file
// in step s and its result is in the register file from step s + L (L = P2_ISP_L_MUL, _ADD, _RCP): it is computed at the
// issue and carried L - 1 more stages. The writes of an operation issued in a program's last ALU step land before the
// hand-off step reads them (the generator checks every output readable at the hand-off step).
module p2_isp_alu
  import p2_hw_pkg::*;
  import p2_pkg::*;
  import p2_fp_pkg::*;
  import p2_isp_prog_pkg::*;
(
  input  logic                                  clk,
  input  logic                                  rst,
  input  logic                                  issue,        // the micro-word uw issues this clock
  input  p2_isp_uword_t                         uw,
  input  logic                                  ld,           // load the input registers
  input  p2_fp24_t [P2_ISP_NIN-1:0]             ld_val,
  input  logic [31:0]                           fpu_perp_val,
  input  logic [2:0][22:0]                      frac,         // the corners' depth fractions (exponent field 255), else 0
  output p2_fp24_t [P2_ISP_NREG-1:0]            rf,
  // taps (the testbench's program trace): the register writes of this clock, multipliers, adders, the reciprocal
  output logic [P2_ISP_NM+P2_ISP_NA:0]                  t_wv,
  output logic [P2_ISP_NM+P2_ISP_NA:0][P2_ISP_RW-1:0]   t_wrd
);
  localparam int NW = P2_ISP_NM + P2_ISP_NA + 1;     // write ports

  // one result a unit makes, on its way to the register file
  typedef struct packed {
    logic                 v;
    logic [P2_ISP_RW-1:0] rd;
    p2_fp24_t             val;
  } wr_t;

  wr_t [NW-1:0] res;     // computed at the issue
  wr_t [NW-1:0] wr;      // written at the end of this clock

  // ---------------------------------------------------------------------------------------------- multipliers
  genvar g;
  generate
    for (g = 0; g < P2_ISP_NM; g = g + 1) begin : g_mul
      p2_isp_mslot_t s;
      p2_fp24_t      a0, a, b, p, ps;
      assign s  = uw.m[g];
      assign a0 = rf[s.ra];
      assign b  = rf[s.rb];
      p2_fp24_t asw;
      p2_isp_fsw #(.SAT(1'b0)) u_swa (.i(a0), .o(asw));
      assign a = s.swa ? asw : a0;
      p2_fp_rng_mul #(.W(P2_FP24_MANT_BITS)) u_mul (
        .ranged(s.op == P2_ISP_MUL_R),
        .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
        .b_neg(b.neg), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
        .o_neg(p.neg), .o_bad(p.bad), .o_exp(p.exp), .o_mant(p.mant));
      p2_isp_fsw #(.SAT(1'b0)) u_swp (.i(p), .o(ps));
      always_comb begin
        res[g].v   = issue && s.v;
        res[g].rd  = s.rd;
        res[g].val = (s.op == P2_ISP_MUL_E) ? ps : p;
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------------------------- adders
  generate
    for (g = 0; g < P2_ISP_NA; g = g + 1) begin : g_add
      p2_isp_aslot_t s;
      p2_fp24_t      a, b, r, rsw, rsat, rm;
      logic          perp;
      logic [22:0]   fa, fb;
      assign s = uw.a[g];
      assign a = rf[s.ra];
      always_comb begin
        b     = rf[s.rb];
        b.neg = b.neg ^ s.sub;
      end
      // EdgeHW and DepthHW have one sum width and reach (24 / 25: p2_hw_check)
      p2_fp_rng_add #(.W(P2_ISP_DEPTH_SUM_BITS), .R(P2_ISP_DEPTH_REACH)) u_add (
        .mode(s.op == P2_ISP_ADD_E ? P2_RNG_ADD_NONE : P2_RNG_ADD_DEPTH),
        .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
        .b_neg(b.neg), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
        .o_neg(r.neg), .o_bad(r.bad), .o_exp(r.exp), .o_mant(r.mant));
      p2_isp_fsw #(.SAT(1'b0)) u_sw (.i(r), .o(rsw));
      p2_isp_fsw #(.SAT(1'b1)) u_sat (.i(r), .o(rsat));
      p2_fp_perp u_perp (.det_bad(r.bad), .det_exp(r.exp), .det_mant(r.mant), .fpu_perp_val(fpu_perp_val), .perp(perp));
      // the mean's infinite corners (addBad): ADD_M1 adds corners 1 and 2 with their fractions, ADD_M2 the sum (its
      // fraction 0) and corner 3
      assign fa = (s.op == P2_ISP_ADD_M1) ? frac[0] : 23'd0;
      assign fb = (s.op == P2_ISP_ADD_M1) ? frac[1] : frac[2];
      always_comb begin
        rm = r;
        if ((s.op == P2_ISP_ADD_M1 || s.op == P2_ISP_ADD_M2) && a.bad && b.bad && a.neg != b.neg && fa != fb) begin
          rm     = '0;
          rm.bad = 1'b1;
          rm.neg = (fa > fb) ? a.neg : b.neg;
        end
      end
      always_comb begin
        res[P2_ISP_NM + g].v  = issue && s.v;
        res[P2_ISP_NM + g].rd = s.rd;
        case (s.post)
          P2_ISP_PO_SW:   res[P2_ISP_NM + g].val = rsw;
          P2_ISP_PO_SAT:  res[P2_ISP_NM + g].val = rsat;
          P2_ISP_PO_PERP: res[P2_ISP_NM + g].val = perp ? '0 : rm;
          default:        res[P2_ISP_NM + g].val = rm;
        endcase
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------------------------- the reciprocal
  p2_fp24_t ra, rr;
  assign ra = rf[uw.r.ra];
  p2_fp_recip24 u_recip (.i_neg(ra.neg), .i_bad(ra.bad), .i_exp(ra.exp), .i_mant(ra.mant),
    .o_neg(rr.neg), .o_bad(rr.bad), .o_exp(rr.exp), .o_mant(rr.mant));
  always_comb begin
    res[NW - 1].v   = issue && uw.r.v;
    res[NW - 1].rd  = uw.r.rd;
    res[NW - 1].val = rr;
  end

  // ---------------------------------------------------------------------------------------------- the latencies
  // a unit of latency L writes its result at the end of the clock L - 1 after the issue
  generate
    for (g = 0; g < NW; g = g + 1) begin : g_lat
      localparam int L = (g < P2_ISP_NM) ? P2_ISP_L_MUL : (g < P2_ISP_NM + P2_ISP_NA) ? P2_ISP_L_ADD : P2_ISP_L_RCP;
      if (L <= 1) begin : g_l1
        assign wr[g] = res[g];
      end else begin : g_ln
        wr_t [L-2:0] pipe;
        always_ff @(posedge clk) begin
          if (rst) begin
            for (int k = 0; k < L - 1; k++)
              pipe[k].v <= 1'b0;
          end else begin
            pipe[0] <= res[g];
            for (int k = 1; k < L - 1; k++)
              pipe[k] <= pipe[k - 1];
          end
        end
        assign wr[g] = pipe[L-2];
      end
      assign t_wv[g]  = wr[g].v;
      assign t_wrd[g] = wr[g].rd;
    end
  endgenerate

  // ---------------------------------------------------------------------------------------------- the register file
  always_ff @(posedge clk) begin
    if (ld)
      for (int k = 0; k < P2_ISP_NIN; k++)
        rf[k] <= ld_val[k];
    for (int k = 0; k < NW; k++)
      if (wr[k].v)
        rf[wr[k].rd] <= wr[k].val;
  end
endmodule

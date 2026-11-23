// p2_pp_div: the pixel pipe's P2, the divider (PLAN M10; ARCHITECTURE 3.7.7 P2; tsp 6 at refsw3 4f3efe15: pvr_tsp_plane.h
// RecipTable, DenominatorSeen, Divide; refsw_tile.h PlaneStepper3::Quot; num H13). An attribute is its plane's value over
// the pixel's 1/w W, both at the same point:
//
//   den = W: 0 read as 2^-128 [uvmeas wzero2: 32,784 readings], below zero DenominatorSeen (the 15 bits under the
//   leading one negated, the sign dropped) [wneg: 780,000 of 780,000; texfar_m1: the -1-unit value as 0xFFFF 2^-143]
//   r = the 16-bit table reciprocal of den's mantissa [recipscan: all 32768 mantissas; 1 / 1.0 = 0.FFFF]
//   q = num x r, floored at 17 fractional bits of the mantissas' product, toward minus infinity; num 0 gives +0
//   [reciprow, reciprown: 1,560,000 of 1,560,000; hugepos c]
//
// ONE reciprocal a pixel (p2_fp_div_den) shared by all its quotients (p2_fp_div_quot, a 16 x 17 multiplier each):
// U, V, the base colour's B, G, R, A, the offset colour's B, G, R, A, and the mip level's w = Divide(1.0, W) (MipSelect:
// `Divide(one, q)`, the divider's own reciprocal, DenominatorSeen included) [I PIPELINE_SHAPE [5]; ARCHITECTURE 3.11].
// The quotients of planes the entry does not set up are made all the same and read by nothing. o_q[0] is the mip w,
// o_q[p] plane p's quotient (p2_tsp_prog_pkg P2_TSP_PL_*, p >= 1). Output registered: the P2 / P3 register.
module p2_pp_div
  import p2_pkg::*;
  import p2_fp_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         stall,
  input  logic                         i_v,
  input  p2_pp_ctl_t                   i_ctl,
  input  p2_pval_t [P2_TSP_NPL-1:0]    i_val,
  output logic                         o_v,
  output p2_pp_ctl_t                   o_ctl,
  output p2_pval_t [P2_TSP_NPL-1:0]    o_val,
  output p2_quot_t [P2_TSP_NPL-1:0]    o_q
);
  localparam int NPL = P2_TSP_NPL;

  logic [15:0]                r;
  logic signed [P2_FP_XW-1:0] ed;
  p2_fp_div_den #(.MW(P2_PVAL_MANT_BITS)) u_den (
    .d_neg(i_val[0].neg), .d_exp(i_val[0].exp), .d_mant(i_val[0].mant), .r(r), .ed(ed));

  p2_quot_t [NPL-1:0] q;
  genvar g;
  generate
    for (g = 0; g < NPL; g = g + 1) begin : g_q
      logic                       nn;
      logic signed [P2_FP_EW-1:0] ne;
      logic [P2_PVAL_MANT_BITS-1:0] nm;
      if (g == 0) begin : g_one
        // 1.0 = FromHalves(2): mantissa 2, exponent -1
        assign nn = 1'b0;
        assign ne = {P2_FP_EW{1'b1}};          // -1
        assign nm = P2_PVAL_MANT_BITS'(2);
      end else begin : g_pl
        assign nn = i_val[g].neg;
        assign ne = i_val[g].exp;
        assign nm = i_val[g].mant;
      end
      p2_fp_div_quot #(.MW(P2_PVAL_MANT_BITS)) u_q (
        .n_neg(nn), .n_exp(ne), .n_mant(nm), .r(r), .ed(ed), .o_neg(q[g].neg), .o_exp(q[g].exp), .o_mant(q[g].mant));
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) o_v <= 1'b0;
    else if (!stall) o_v <= i_v;
    if (i_v && !stall) begin
      o_ctl <= i_ctl;
      o_val <= i_val;
      o_q   <= q;
    end
  end
endmodule

// p2_pp_col: the pixel pipe's P3 colours (PLAN M10; ARCHITECTURE 3.7.7 P3; tsp 7 at refsw3 4f3efe15: pvr_tsp_plane.h
// ColorRounded, refsw_tile.cpp InterpolateBase / InterpolateOffs; num H15), and the P3 register of the point's other
// numbers (its control, W and the values, the quotients) for the stages after it.
//
//   a colour channel from its quotient q (the colour entered the planes as c 2^-8):
//     q <= 0 -> 0;  else min(floor(q 2^8 + 1/2), MAX)          [cmeas: 2,340,000 of 2,340,000 "floor(v + 0.5)"; shade:
//                                                               80,256 of 80,256] (p2_fp_color_round)
//   base (InterpolateBase): MAX 65535 (the intensity shadow would scale before the clamp; its scale is 256 in refsw3, the
//     colours of the intensity entry being scaled per vertex at setup: SetupIntensity), then the clamp to 255
//     [modvol pages 0-2]; TSP UseAlpha 0: A = 255
//   offset (InterpolateOffs): MAX 255 each channel
// The fallback (a quotient that is an infinity) is never taken: the divider's quotients are never flagged (p2_fp_div_quot);
// the header's fallback bytes are wired for it all the same. Colours as ARGB8888 (refsw3 Color: bgra[0] = B).
module p2_pp_col
  import p2_pkg::*;
  import p2_fp_pkg::*;
  import p2_tsp_pkg::*;
  import p2_tsp_prog_pkg::*;
(
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         stall,
  input  logic                         i_v,
  input  p2_pp_ctl_t                   i_ctl,
  input  p2_pval_t [P2_TSP_NPL-1:0]    i_val,
  input  p2_quot_t [P2_TSP_NPL-1:0]    i_q,
  // P3 out
  output logic                         o_v,
  output p2_pp_ctl_t                   o_ctl,
  output p2_pval_t [P2_TSP_NPL-1:0]    o_val,
  output p2_quot_t [P2_TSP_NPL-1:0]    o_q,
  output logic [31:0]                  o_base,     // InterpolateBase
  output logic [31:0]                  o_offs      // InterpolateOffs
);
  logic [3:0][7:0] b8, o8;
  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_ch
      logic [15:0] bc, oc;
      p2_quot_t    qb, qo;
      assign qb = i_q[32'(P2_TSP_PL_CB) + g];
      assign qo = i_q[32'(P2_TSP_PL_OB) + g];
      p2_fp_color_round #(.MAX(65535), .SE(-8), .QW(P2_QUOT_MANT_BITS)) u_b (
        .q_neg(qb.neg), .q_bad(1'b0), .q_exp(qb.exp), .q_mant(qb.mant), .fallback(i_ctl.hdr.col_fb[8*g +: 8]), .o(bc));
      p2_fp_color_round #(.MAX(255), .SE(-8), .QW(P2_QUOT_MANT_BITS)) u_o (
        .q_neg(qo.neg), .q_bad(1'b0), .q_exp(qo.exp), .q_mant(qo.mant), .fallback(i_ctl.hdr.ofs_fb[8*g +: 8]), .o(oc));
      assign b8[g] = (bc > 16'd255) ? 8'd255 : bc[7:0];
      assign o8[g] = oc[7:0];
    end
  endgenerate

  logic [31:0] base;
  assign base = {i_ctl.hdr.tsp[20] ? b8[3] : 8'd255, b8[2], b8[1], b8[0]};   // TSP UseAlpha [20]

  always_ff @(posedge clk) begin
    if (rst) o_v <= 1'b0;
    else if (!stall) o_v <= i_v;
    if (i_v && !stall) begin
      o_ctl  <= i_ctl;
      o_val  <= i_val;
      o_q    <= i_q;
      o_base <= base;
      o_offs <= {o8[3], o8[2], o8[1], o8[0]};
    end
  end
endmodule

// p2_fp_floor_tb_top: make fp-floor (tb/fp/fp_floor_tb.cpp). H11, every converter at its site's widths:
//   p2_fp_floor as FloorScaled (24-bit corners, +-2^40 clamp: the row range), as FloorUnits (29-bit operands: c_, a_,
//   ax, by, ah; a 27-bit result, -0 is -1) and as the edge's unitsAt (20-bit s20 and steps, with the fraction bit);
//   p2_fp_reg_units for r0 (from first0) and for fa / fb (from p2_fp_mul(v0, invS), the product it is given at the
//   site); p2_fp_tex_coord (18-bit quotients). Outputs registered (latency 1, tb/fp/fp_tb.h).
module p2_fp_floor_tb_top
  import p2_fp_pkg::*;
(
  input  logic                       clk,
  input  logic                       in_v,
  input  logic                       v_neg,      // FloorScaled, FloorUnits, unitsAt (each takes its low bits)
  input  logic                       v_bad,
  input  logic signed [P2_FP_EW-1:0] v_exp,
  input  logic [28:0]                v_mant,
  input  logic signed [P2_FP_EW-1:0] u,          // the unit (FloorScaled: minus its shift)
  input  logic                       r_neg,      // r0: first0; step: v0
  input  logic                       r_bad,
  input  logic signed [P2_FP_EW-1:0] r_exp,
  input  logic [23:0]                r_mant,
  input  logic                       i_neg,      // step: invS
  input  logic                       i_bad,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [23:0]                i_mant,
  input  logic                       q_neg,      // TexCoordFixed: the quotient
  input  logic                       q_bad,
  input  logic signed [P2_FP_EW-1:0] q_exp,
  input  logic [17:0]                q_mant,
  input  logic [4:0]                 shift,
  output logic                       out_v,
  output logic signed [41:0]         fs_int,
  output logic signed [26:0]         fu_int,
  output logic signed [57:0]         ua_int,
  output logic                       ua_frac,
  output logic signed [30:0]         r0,
  output logic signed [30:0]         rstep,
  output logic signed [31:0]         coord
);
  p2_hw_check u_hw_check ();

  logic signed [41:0] fs;
  logic signed [26:0] fu;
  logic signed [57:0] ua;
  logic               uf, fs_frac, fu_frac;
  logic signed [30:0] r0w, rsw;
  logic signed [31:0] cw;
  logic               pn, pb;
  logic signed [P2_FP_EW-1:0] pe;
  logic [23:0]        pm;

  p2_fp_floor #(.MW(24), .OW(42), .ZNEG(1'b0), .CLAMP(40)) u_fs (
    .i_neg(v_neg), .i_exp(v_exp), .i_mant(v_mant[23:0]), .u(u), .o_int(fs), .o_frac(fs_frac));
  p2_fp_floor #(.MW(29), .OW(27), .ZNEG(1'b1), .CLAMP(0)) u_fu (
    .i_neg(v_neg), .i_exp(v_exp), .i_mant(v_mant), .u(u), .o_int(fu), .o_frac(fu_frac));
  p2_fp_floor #(.MW(20), .OW(58), .ZNEG(1'b0), .CLAMP(0)) u_ua (
    .i_neg(v_neg), .i_exp(v_exp), .i_mant(v_mant[19:0]), .u(u), .o_int(ua), .o_frac(uf));
  p2_fp_reg_units u_r0 (.i_neg(r_neg), .i_bad(r_bad), .i_exp(r_exp), .i_mant(r_mant), .step(1'b0), .o_r(r0w));
  p2_fp_mul #(.AW(24), .BW(24), .N(24)) u_rm (
    .a_neg(r_neg), .a_bad(r_bad), .a_exp(r_exp), .a_mant(r_mant),
    .b_neg(i_neg), .b_bad(i_bad), .b_exp(i_exp), .b_mant(i_mant),
    .o_neg(pn), .o_bad(pb), .o_exp(pe), .o_mant(pm));
  p2_fp_reg_units u_rs (.i_neg(pn), .i_bad(pb), .i_exp(pe), .i_mant(pm), .step(1'b1), .o_r(rsw));
  p2_fp_tex_coord #(.MW(18)) u_tc (.u_neg(q_neg), .u_bad(q_bad), .u_exp(q_exp), .u_mant(q_mant), .shift(shift),
    .o_coord(cw));

  always_ff @(posedge clk) begin
    out_v   <= in_v;
    fs_int  <= fs;
    fu_int  <= fu;
    ua_int  <= ua;
    ua_frac <= uf;
    r0      <= r0w;
    rstep   <= rsw;
    coord   <= cw;
  end
endmodule

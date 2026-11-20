// p2_fp_in_tb_top: make fp-in (tb/fp/fp_in_tb.cpp). H4, the inputs (num H4, 2.5): an IEEE single's bits both ways
// (FromBits: ranged 0; FromSingle(., 1): ranged 1), k / 2 (FromHalves, 16-bit k), the TSP evaluator's `seen` of a
// 16-bit coefficient, an 8-bit colour as the single c 2^-8. Outputs registered (latency 1, tb/fp/fp_tb.h).
module p2_fp_in_tb_top
  import p2_fp_pkg::*;
(
  input  logic                       clk,
  input  logic                       in_v,
  input  logic [31:0]                u,
  input  logic signed [15:0]         k,
  input  logic                       sn_neg,
  input  logic                       sn_bad,
  input  logic signed [P2_FP_EW-1:0] sn_exp,
  input  logic [15:0]                sn_mant,
  input  logic [7:0]                 c,
  output logic                       out_v,
  output logic                       s0_neg,
  output logic                       s0_bad,
  output logic signed [P2_FP_EW-1:0] s0_exp,
  output logic [23:0]                s0_mant,
  output logic                       s1_neg,
  output logic                       s1_bad,
  output logic signed [P2_FP_EW-1:0] s1_exp,
  output logic [23:0]                s1_mant,
  output logic                       h_neg,
  output logic                       h_bad,
  output logic signed [P2_FP_EW-1:0] h_exp,
  output logic [15:0]                h_mant,
  output logic                       so_neg,
  output logic                       so_bad,
  output logic signed [P2_FP_EW-1:0] so_exp,
  output logic [15:0]                so_mant,
  output logic [31:0]                w
);
  p2_hw_check u_hw_check ();

  logic                       n0, b0, n1, b1, nh, bh, ns, bs;
  logic signed [P2_FP_EW-1:0] e0, e1, eh, es;
  logic [23:0]                m0, m1;
  logic [15:0]                mh, ms;
  logic [31:0]                dw;

  p2_fp_in_single u_s0 (.u(u), .ranged(1'b0), .o_neg(n0), .o_bad(b0), .o_exp(e0), .o_mant(m0));
  p2_fp_in_single u_s1 (.u(u), .ranged(1'b1), .o_neg(n1), .o_bad(b1), .o_exp(e1), .o_mant(m1));
  p2_fp_in_halves #(.KW(16)) u_h (.k(k), .o_neg(nh), .o_bad(bh), .o_exp(eh), .o_mant(mh));
  p2_fp_in_seen #(.MW(16)) u_sn (
    .i_neg(sn_neg), .i_bad(sn_bad), .i_exp(sn_exp), .i_mant(sn_mant),
    .o_neg(ns), .o_bad(bs), .o_exp(es), .o_mant(ms));
  p2_fp_in_colour u_c (.c(c), .w(dw));

  always_ff @(posedge clk) begin
    out_v   <= in_v;
    s0_neg  <= n0;
    s0_bad  <= b0;
    s0_exp  <= e0;
    s0_mant <= m0;
    s1_neg  <= n1;
    s1_bad  <= b1;
    s1_exp  <= e1;
    s1_mant <= m1;
    h_neg   <= nh;
    h_bad   <= bh;
    h_exp   <= eh;
    h_mant  <= mh;
    so_neg  <= ns;
    so_bad  <= bs;
    so_exp  <= es;
    so_mant <= ms;
    w       <= dw;
  end
endmodule

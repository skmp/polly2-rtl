// p2_fp_zword_tb_top: make fp-zword (tb/fp/fp_zword_tb.cpp). H14, every function of p2_zword_pkg on its own inputs:
// key32, bits, bgkey and between on w (and off), from_fp and big on a 20-bit tuple, neg on (e, m), flat on a 24-bit
// tuple, saturated on a sign, regdepth on a 32-bit register. Outputs registered (latency 1, tb/fp/fp_tb.h).
module p2_fp_zword_tb_top
  import p2_pkg::*;
  import p2_fp_pkg::*;
(
  input  logic                       clk,
  input  logic                       in_v,
  input  logic [31:0]                w,
  input  logic [31:0]                off,
  input  logic                       v20_neg,
  input  logic                       v20_bad,
  input  logic signed [P2_FP_EW-1:0] v20_exp,
  input  logic [19:0]                v20_mant,
  input  logic signed [9:0]          e,
  input  logic signed [30:0]         m,
  input  logic                       v24_neg,
  input  logic                       v24_bad,
  input  logic signed [P2_FP_EW-1:0] v24_exp,
  input  logic [23:0]                v24_mant,
  input  logic                       sat_s,
  input  logic [31:0]                r,
  output logic                       out_v,
  output logic [31:0]                o_key32,
  output logic [63:0]                o_bits,
  output logic [63:0]                o_between,
  output logic [63:0]                o_bg,
  output logic [63:0]                o_fromfp,
  output logic [63:0]                o_big,
  output logic [63:0]                o_neg,
  output logic [63:0]                o_flat,
  output logic [63:0]                o_sat,
  output logic [63:0]                o_reg
);
  p2_hw_check u_hw_check ();

  p2_fp20_t v20;
  p2_fp24_t v24;

  always_comb begin
    v20.neg  = v20_neg;
    v20.bad  = v20_bad;
    v20.exp  = v20_exp;
    v20.mant = v20_mant;
    v24.neg  = v24_neg;
    v24.bad  = v24_bad;
    v24.exp  = v24_exp;
    v24.mant = v24_mant;
  end

  always_ff @(posedge clk) begin
    out_v     <= in_v;
    o_key32   <= p2_zword_pkg::key32(w);
    o_bits    <= p2_zword_pkg::bits(w);
    o_between <= p2_zword_pkg::between(w, off);
    o_bg      <= p2_zword_pkg::bgkey(w);
    o_fromfp  <= p2_zword_pkg::from_fp(v20);
    o_big     <= p2_zword_pkg::big(v20);
    o_neg     <= p2_zword_pkg::neg(e, m);
    o_flat    <= p2_zword_pkg::flat(v24);
    o_sat     <= p2_zword_pkg::saturated(sat_s);
    o_reg     <= p2_zword_pkg::regdepth(r);
  end
endmodule

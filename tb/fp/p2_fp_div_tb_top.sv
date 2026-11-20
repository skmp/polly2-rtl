// p2_fp_div_tb_top: make fp-div (tb/fp/fp_div_tb.cpp). H13, every piece on its own ports, each clock: the generated
// reciprocal ROM (p2_fp_recip_rom), recip_mant (p2_fp_recip_mant), denominator_seen (p2_fp_den_seen) and a whole
// division (p2_fp_div: p2_fp_div_den + p2_fp_div_quot) at the plane value's 17-bit mantissa. Outputs registered
// (latency 1, tb/fp/fp_tb.h). The *_bad outputs are 0: none of these makes a flag (Divide's quotient is a fresh Fp).
module p2_fp_div_tb_top
  import p2_pkg::*;
  import p2_fp_pkg::*;
(
  input  logic                         clk,
  input  logic                         in_v,
  // the ROM
  input  logic [8:0]                   rom_i,
  // recip_mant
  input  logic [15:0]                  rm_d,
  // denominator_seen
  input  logic                         ds_neg,
  input  logic signed [P2_FP_EW-1:0]   ds_exp,
  input  logic [16:0]                  ds_mant,
  // divide
  input  logic                         n_neg,
  input  logic signed [P2_FP_EW-1:0]   n_exp,
  input  logic [16:0]                  n_mant,
  input  logic                         d_neg,
  input  logic signed [P2_FP_EW-1:0]   d_exp,
  input  logic [16:0]                  d_mant,
  output logic                         out_v,
  output logic [16:0]                  rom_t,
  output logic [8:0]                   rom_n,
  output logic [15:0]                  rm_r,
  output logic                         s_neg,
  output logic                         s_bad,
  output logic signed [P2_FP_EW-1:0]   s_exp,
  output logic [16:0]                  s_mant,
  output logic                         q_neg,
  output logic                         q_bad,
  output logic signed [P2_FP_EW-1:0]   q_exp,
  output logic [P2_QUOT_MANT_BITS-1:0] q_mant
);
  p2_hw_check u_hw_check ();

  logic [16:0]                  t17;
  logic [8:0]                   n9;
  logic [15:0]                  r16;
  logic                         sn, qn;
  logic signed [P2_FP_EW-1:0]   se, qe;
  logic [16:0]                  sm;
  logic [P2_QUOT_MANT_BITS-1:0] qm;

  p2_fp_recip_rom u_rom (.i(rom_i), .t(t17), .n(n9));
  p2_fp_recip_mant u_rm (.d(rm_d), .r(r16));
  p2_fp_den_seen #(.MW(17)) u_seen (
    .i_neg(ds_neg), .i_exp(ds_exp), .i_mant(ds_mant), .o_neg(sn), .o_exp(se), .o_mant(sm));
  p2_fp_div #(.MW(17)) u_div (
    .n_neg(n_neg), .n_exp(n_exp), .n_mant(n_mant), .d_neg(d_neg), .d_exp(d_exp), .d_mant(d_mant),
    .o_neg(qn), .o_exp(qe), .o_mant(qm));

  always_ff @(posedge clk) begin
    out_v  <= in_v;
    rom_t  <= t17;
    rom_n  <= n9;
    rm_r   <= r16;
    s_neg  <= sn;
    s_bad  <= 1'b0;
    s_exp  <= se;
    s_mant <= sm;
    q_neg  <= qn;
    q_bad  <= 1'b0;
    q_exp  <= qe;
    q_mant <= qm;
  end
endmodule

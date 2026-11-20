// p2_fp_rng_with_zero: H10, the TSP flat (determinant-zero) mean's first addition against a corner whose depth has
// exponent field 0 (docs/spec/numerics.md H10, 4.2 withZero; refcore pvr_tsp_plane.h PlaneT::Setup L256-267):
//
//   p zero, bad, top(p) - 1 != -126, or p.neg == the zero's sign:  p
//   otherwise:  the zero is zv = (1 + m 2^-23) 2^-127 with its sign (its hidden bit kept), r = p + zv:
//               r below 2^-126 (or zero): +0;  else p, the zero taking nothing off
//
// slivers_dzspec, slivers_dzzero (9,600 of 9,600 triples, 831 of them exactly on the boundary, which keeps p). refsw3
// adds with Add(p, zv, 62, 400), exact here: both mantissas have at most 24 bits and p.exp is -149 .. -126, so the
// sum is |p| - |zv| in units of 2^-150, P - Z with P = mant << (exp + 150) in [2^24, 2^25) and Z = 2^23 | m below
// 2^24: never zero, below 2^-126 iff P - Z < 2^24. Combinational.
module p2_fp_rng_with_zero
  import p2_fp_pkg::*;
(
  input  logic                       i_neg,
  input  logic                       i_bad,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [23:0]                i_mant,
  input  logic [31:0]                zbits,       // the other corner's raw z word, exponent field 0
  output logic                       o_neg,
  output logic                       o_bad,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [23:0]                o_mant
);
  logic [4:0]                 n;
  logic signed [P2_FP_XW-1:0] t;          // top(p)
  logic signed [P2_FP_XW-1:0] sh;         // exp + 150: p in units of 2^-150
  logic [48:0]                pu;         // P (wide enough for any shift of 0 .. 25)
  logic [24:0]                zu;         // Z
  logic [48:0]                d;          // P - Z
  logic                       act, drop;

  p2_fp_lzc #(.W(24), .NW(5)) u_bl (.v(i_mant), .n(n));

  assign t    = p2_fp_xw(i_exp) + $signed({{(P2_FP_XW - 5){1'b0}}, n});
  assign act  = (i_mant != '0) && !i_bad && (t == P2_FP_XW'(P2_FP_RNG_LOW + 1)) && (i_neg != zbits[31]);
  assign sh   = p2_fp_xw(i_exp) + P2_FP_XW'(150);
  assign pu   = {25'h0, i_mant} << sh;
  assign zu   = {2'b01, zbits[22:0]};
  assign d    = pu - {24'h0, zu};
  assign drop = act && (d < 49'h1000000);

  assign o_neg  = drop ? 1'b0 : i_neg;
  assign o_bad  = drop ? 1'b0 : i_bad;
  assign o_exp  = drop ? '0 : i_exp;
  assign o_mant = drop ? '0 : i_mant;
endmodule

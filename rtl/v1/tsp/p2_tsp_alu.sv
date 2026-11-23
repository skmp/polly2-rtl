// p2_tsp_alu: the TSP's shared arithmetic unit (PLAN M9; ARCHITECTURE 3.7.4), driven by p2_tsp_setup's microprogram. It
// implements no rule of its own: P2_TSP_NM multipliers, P2_TSP_NA adders and one reciprocal (num H5, H6, H8 with the
// H10 range wrappers of lib/fp) and the operand register file, the numbers and latencies the free parameters of
// ARCHITECTURE 6 in the generated p2_tsp_prog_pkg (tools/gen/gen_tsp_prog.cpp). Each operation is the flavour its issue
// names; refsw3 (pvr_tsp_plane.h at 4f3efe15) is where each comes from:
//
//   multiplier  24 x 24 -> 24
//     MUL_T   the setup's ranged `mul` (PlaneT::Setup L178-190, MipSelect's rmul L766-777: p2_fp_rng_mul) [uvmeas whuge,
//             wtiny, wspec]
//     MUL_K   MipSelect's `kind` and its product (L665-671, L706: p2_fp_rng_kind): a product at 2^128 or more is kept as
//             {bad}, one below 2^-126 or of a zero as a zero; the sign the operands' xor in every case (the minor's
//             neg1 / neg2) [mipmeas wext, mipdump]
//     MUL_Q   the numerator's quotient check (L712-716): Mul(n, 1/det^2) below 2^-126 -> +0, at 2^128 -> an infinity,
//             else n; n infinite: n; 1/det^2 the marker {bad} (no undivided path: L687) -> +0, the numerator of the
//             divided coefficients, which are all zeros then (A0 = Sa x inv with inv = 0)
//     MUL_I2  1/det^2 = Mul(inv, inv, 24), below 2^-126 -> +0 (L688, L694); inv = 0 -> the marker {bad}
//     MUL_B   the longer length times 1/det^2 (L828-832): with the marker, a zero or an infinite length: the length;
//             else above -> an infinity, below -> +0
//     MUL_P   Mul(a, b, 24) (the length's 0x95F612 x shorter, L753: Mul(., ., 62).cut(24) is the same tuple)
//   adder       24 / 25 (MipSelect's radd 24 / 53)
//     ADD_T   the setup's addTerm (L192-224: p2_fp_rng_add TSP, TSP_ZERO 0: the zero rule of 2bee80f2 in every
//             addition, every zero sum +0) [tsp2_zadd 9,600 of 9,600; cmeas cwsum1]
//     ADD_W   the determinant-zero mean's first addition (L313-318): against a corner of exponent field 0 withZero
//             (p2_fp_rng_with_zero, that corner's raw bits), else addTerm [slivers_dzzero 9,600 of 9,600]
//     ADD_R   radd (L787-797: p2_fp_rng_add MIP at reach 53, GAP G1)
//     ADD_N   the numerator (L697-711): an infinite product: two of one sign +0, else an infinity; else the magnitude
//             of Sub(q1, q2).cut(24) (p2_fp_mip_minor) [mipk5 1991 of 1991]
//     ADD_LX, ADD_LN   the length's longer and shorter (L731-738, AtMost: p2_fp_le), {bad} when either is infinite
//     ADD_BS  the longer of the two lengths (L810)
//     ADD_P   plain Add 24 / 25 (the length's sum and difference, L753-754: Add(., ., 62, 25).cut(24) is the same tuple)
//   reciprocal  RCP_T the plane's (L335-337: p2_fp_rng_recip TSP: an infinite determinant or one of 2^126 or more a
//               zero of its sign), RCP_M MipSelect's (L684-686: rng_recip mip)
//   registers   P2_TSP_NREG tuples: the inputs (loaded by `ld` at a job's start) and one for every value of the graphs
//
// Timing [I, the structure the scheduler assumed]: an operation issued in step s reads its operands in step s, its result
// is in the register file from step s + L (L = P2_TSP_L_MUL, _ADD, _RCP). `issue` low (the step held: run start has the
// ALU this clock, ARCHITECTURE 3.7.4 "run start first") issues nothing; results already on their way still land: every
// value has its own register, so a held step cannot let a write overtake a read.
module p2_tsp_alu
  import p2_hw_pkg::*;
  import p2_pkg::*;
  import p2_fp_pkg::*;
  import p2_tsp_prog_pkg::*;
(
  input  logic                                  clk,
  input  logic                                  rst,
  input  logic                                  issue,        // the micro-word uw issues this clock
  input  p2_tsp_uword_t                         uw,
  input  logic                                  ld,           // load the input registers
  input  p2_fp24_t [P2_TSP_NIN-1:0]             ld_val,
  input  logic [1:0][31:0]                      zbits,        // corners 1 and 2's raw depths (the mean's withZero)
  output p2_fp24_t [P2_TSP_NREG-1:0]            rf,
  // taps (the testbench's program trace): the register writes of this clock
  output logic [P2_TSP_NM+P2_TSP_NA:0]                  t_wv,
  output logic [P2_TSP_NM+P2_TSP_NA:0][P2_TSP_RW-1:0]   t_wrd
);
  localparam int NW = P2_TSP_NM + P2_TSP_NA + 1;

  typedef struct packed {
    logic                 v;
    logic [P2_TSP_RW-1:0] rd;
    p2_fp24_t             val;
  } wr_t;

  wr_t [NW-1:0] res;     // computed at the issue
  wr_t [NW-1:0] wr;      // written at the end of this clock

  // an infinity as the register file marks one, and a zero
  localparam p2_fp24_t BAD  = '{neg: 1'b0, bad: 1'b1, exp: '0, mant: '0};
  localparam p2_fp24_t ZERO = '0;

  // the range of a product (num 4.2): above 2^128 - 1, below 2^-126
  function automatic logic above(input logic signed [P2_FP_EW-1:0] e, input logic [23:0] m);
    logic [4:0] n;
    logic signed [P2_FP_XW-1:0] t;
    n = 5'd0;
    for (int i = 0; i < 24; i++) if (m[i]) n = 5'(i + 1);
    t = p2_fp_xw(e) + $signed({{(P2_FP_XW - 5){1'b0}}, n});
    return m != '0 && t - P2_FP_XW'(1) > P2_FP_XW'(P2_FP_RNG_HIGH);
  endfunction
  function automatic logic below(input logic signed [P2_FP_EW-1:0] e, input logic [23:0] m);
    logic [4:0] n;
    logic signed [P2_FP_XW-1:0] t;
    n = 5'd0;
    for (int i = 0; i < 24; i++) if (m[i]) n = 5'(i + 1);
    t = p2_fp_xw(e) + $signed({{(P2_FP_XW - 5){1'b0}}, n});
    return m != '0 && t - P2_FP_XW'(1) < P2_FP_XW'(P2_FP_RNG_LOW);
  endfunction

  // ---------------------------------------------------------------------------------------------- multipliers
  genvar g;
  generate
    for (g = 0; g < P2_TSP_NM; g = g + 1) begin : g_mul
      p2_tsp_mslot_t s;
      p2_fp24_t      a, b, pr, pp;
      logic [1:0]    kd;
      p2_fp24_t      kp;
      assign s = uw.m[g];
      assign a = rf[s.ra];
      assign b = rf[s.rb];
      p2_fp_rng_mul #(.W(24)) u_rmul (
        .ranged(1'b1),
        .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
        .b_neg(b.neg), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
        .o_neg(pr.neg), .o_bad(pr.bad), .o_exp(pr.exp), .o_mant(pr.mant));
      p2_fp_mul #(.AW(24), .BW(24), .N(24)) u_mul (
        .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
        .b_neg(b.neg), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
        .o_neg(pp.neg), .o_bad(pp.bad), .o_exp(pp.exp), .o_mant(pp.mant));
      p2_fp_rng_kind #(.W(24)) u_kind (
        .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
        .b_neg(b.neg), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
        .kind(kd), .o_neg(kp.neg), .o_bad(kp.bad), .o_exp(kp.exp), .o_mant(kp.mant));
      always_comb begin
        p2_fp24_t r;
        r = pp;
        case (s.op)
          P2_TSP_MUL_T: r = pr;
          P2_TSP_MUL_K: begin
            r     = (kd == P2_KIND_NUMBER) ? kp : (kd == P2_KIND_INF) ? BAD : ZERO;
            r.neg = a.neg ^ b.neg;
          end
          P2_TSP_MUL_Q: r = a.bad ? a : b.bad ? ZERO : below(pp.exp, pp.mant) ? ZERO : above(pp.exp, pp.mant) ? BAD : a;
          P2_TSP_MUL_I2: r = (a.mant == '0) ? BAD : below(pp.exp, pp.mant) ? ZERO : pp;
          P2_TSP_MUL_B: r = (b.bad || a.bad || a.mant == '0) ? a : above(pp.exp, pp.mant) ? BAD : below(pp.exp, pp.mant) ? ZERO : pp;
          default: r = pp;                                    // MUL_P
        endcase
        res[g].v   = issue && s.v;
        res[g].rd  = s.rd;
        res[g].val = r;
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------------------------- adders
  generate
    for (g = 0; g < P2_TSP_NA; g = g + 1) begin : g_add
      p2_tsp_aslot_t s;
      p2_fp24_t      a, b, rt, rr, rp, rw0, rw1, rn;
      logic          ba_le;              // AtMost(b, a): b <= a
      assign s = uw.a[g];
      assign a = rf[s.ra];
      always_comb begin
        b     = rf[s.rb];
        b.neg = b.neg ^ s.sub;
      end
      p2_fp_rng_add #(.W(24), .R(P2_TSP_PLANE_REACH)) u_t (
        .mode(P2_RNG_ADD_TSP),
        .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
        .b_neg(b.neg), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
        .o_neg(rt.neg), .o_bad(rt.bad), .o_exp(rt.exp), .o_mant(rt.mant));
      p2_fp_rng_add #(.W(24), .R(53)) u_r (
        .mode(P2_RNG_ADD_MIP),
        .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
        .b_neg(b.neg), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
        .o_neg(rr.neg), .o_bad(rr.bad), .o_exp(rr.exp), .o_mant(rr.mant));
      p2_fp_add #(.W(24), .R(P2_TSP_PLANE_REACH)) u_p (
        .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
        .b_neg(b.neg), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
        .o_neg(rp.neg), .o_bad(rp.bad), .o_exp(rp.exp), .o_mant(rp.mant));
      // the mean's first addition: withZero(Z1, z0) when only corner 1 has field 0, withZero(Z0, z1) when only corner 2
      p2_fp_rng_with_zero u_w0 (.i_neg(b.neg), .i_bad(b.bad), .i_exp(b.exp), .i_mant(b.mant), .zbits(zbits[0]),
        .o_neg(rw0.neg), .o_bad(rw0.bad), .o_exp(rw0.exp), .o_mant(rw0.mant));
      p2_fp_rng_with_zero u_w1 (.i_neg(a.neg), .i_bad(a.bad), .i_exp(a.exp), .i_mant(a.mant), .zbits(zbits[1]),
        .o_neg(rw1.neg), .o_bad(rw1.bad), .o_exp(rw1.exp), .o_mant(rw1.mant));
      p2_fp_mip_minor #(.W(24)) u_n (
        .a_neg(a.neg), .a_bad(a.bad), .a_exp(a.exp), .a_mant(a.mant),
        .b_neg(b.neg), .b_bad(b.bad), .b_exp(b.exp), .b_mant(b.mant),
        .o_neg(rn.neg), .o_bad(rn.bad), .o_exp(rn.exp), .o_mant(rn.mant));
      p2_fp_le #(.MW(24)) u_le (
        .a_neg(b.neg), .a_bad(b.bad), .a_exp(b.exp), .a_mant(b.mant),
        .b_neg(a.neg), .b_bad(a.bad), .b_exp(a.exp), .b_mant(a.mant), .le(ba_le));
      always_comb begin
        p2_fp24_t r;
        logic     f0, f1;
        f0 = zbits[0][30:23] == 8'h00;
        f1 = zbits[1][30:23] == 8'h00;
        r  = rt;
        case (s.op)
          P2_TSP_ADD_T: r = rt;
          P2_TSP_ADD_W: r = (f0 && !f1) ? rw0 : (f1 && !f0) ? rw1 : rt;
          P2_TSP_ADD_R: r = rr;
          P2_TSP_ADD_N: r = (a.bad || b.bad) ? ((a.bad && b.bad && a.neg == b.neg) ? ZERO : BAD) : rn;
          P2_TSP_ADD_LX: r = (a.bad || b.bad) ? BAD : ba_le ? a : b;
          P2_TSP_ADD_LN: r = (a.bad || b.bad) ? BAD : ba_le ? b : a;
          P2_TSP_ADD_BS: r = (a.bad || (!b.bad && ba_le)) ? a : b;
          default: r = rp;                                    // ADD_P
        endcase
        res[P2_TSP_NM + g].v   = issue && s.v;
        res[P2_TSP_NM + g].rd  = s.rd;
        res[P2_TSP_NM + g].val = r;
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------------------------- the reciprocal
  p2_fp24_t ra, rr;
  assign ra = rf[uw.r.ra];
  p2_fp_rng_recip u_recip (.mip(uw.r.op == P2_TSP_RCP_M), .i_neg(ra.neg), .i_bad(ra.bad), .i_exp(ra.exp), .i_mant(ra.mant),
    .o_neg(rr.neg), .o_bad(rr.bad), .o_exp(rr.exp), .o_mant(rr.mant));
  always_comb begin
    res[NW - 1].v   = issue && uw.r.v;
    res[NW - 1].rd  = uw.r.rd;
    res[NW - 1].val = rr;
  end

  // ---------------------------------------------------------------------------------------------- the latencies
  generate
    for (g = 0; g < NW; g = g + 1) begin : g_lat
      localparam int L = (g < P2_TSP_NM) ? P2_TSP_L_MUL : (g < P2_TSP_NM + P2_TSP_NA) ? P2_TSP_L_ADD : P2_TSP_L_RCP;
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
      for (int k = 0; k < P2_TSP_NIN; k++)
        rf[k] <= ld_val[k];
    for (int k = 0; k < NW; k++)
      if (wr[k].v)
        rf[wr[k].rd] <= wr[k].val;
  end
endmodule

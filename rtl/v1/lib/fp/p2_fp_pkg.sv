// p2_fp_pkg: the constants of the numerics primitives in rtl/v1/lib/fp (docs/spec/numerics.md section 6,
// ARCHITECTURE 3.11): the exponent fields, the range of the ranged arithmetic, the modes of the range wrappers (H10).
//
// Every primitive takes and returns the reference's tuple (refcore pvr_softfp.h pvrfp::Fp) as flat ports:
//   <x>_neg, <x>_bad, <x>_exp (P2_FP_EW bits, two's complement: the exponent of mantissa bit 0), <x>_mant
// value = (-1)^neg * mant * 2^exp, mant not normalized; exp means something only when mant != 0 (num 1.1, 1.3).
package p2_fp_pkg;
  import p2_pkg::*;

  // the exponent field of every tuple port (num 1.4: every reachable value is in -300 .. 259; the testbenches assert
  // that the reference's exp fits it, GAP G11)
  localparam int P2_FP_EW = P2_FP_EXP_BITS;
  // exponent arithmetic inside a primitive: a sum of two fields plus a shift of at most 128 never leaves it
  localparam int P2_FP_XW = 13;

  // The range of the ranged arithmetic (num 4.2): a nonzero value with top - 1 > HIGH (|v| >= 2^128) is above it, one
  // with top - 1 < LOW (|v| < 2^-126) below it. refsw3 has the two numbers three times, equal: pvr_isp_depth.h
  // DepthTileT::Setup `limit` (literals 127, -126), pvr_tsp_plane.h PlaneHW::expHigh / expLow, MipSelect `above` /
  // `below` (literals). The testbench compares each flavour with its own copy, so a change in any one shows there.
  localparam int P2_FP_RNG_HIGH = 127;
  localparam int P2_FP_RNG_LOW  = -126;
  // the TSP's reciprocal is a zero for a determinant with top - 1 >= this (pvr_tsp_plane.h PlaneT::Setup; trsort_recip)
  localparam int P2_FP_RECIP_DET_HIGH = 126;
  // the TSP setup's zero rule: a zero added to a value v with top - 1 < -127 + zeroReach, |v| < 1.5 2^(top - 1) and
  // the other sign is +0 (pvr_tsp_plane.h PlaneT::Setup addTerm, PlaneHW::zeroReach 2; tsp2_zadd 9,600 of 9,600)
  localparam int P2_FP_ZERO_REACH = 2;

  // p2_fp_rng_add: the flavour of one addition (num 4.2)
  localparam logic [1:0] P2_RNG_ADD_NONE  = 2'd0;   // edge unit: plain Add, no range (pvr_isp_edge.h)
  localparam logic [1:0] P2_RNG_ADD_DEPTH = 2'd1;   // ISP depth setup `add` (4f3efe15): the zero rule, every zero sum +0
  localparam logic [1:0] P2_RNG_ADD_TSP   = 2'd2;   // TSP `addTerm` (4f3efe15, either addition): the zero rule, every zero sum +0
  localparam logic [1:0] P2_RNG_ADD_MIP   = 2'd3;   // MipSelect `radd` (with R = 53): no zero rule, a zero sum keeps its sign

  // p2_fp_rng_lim: the check after an operation (num 4.2)
  localparam logic [1:0] P2_RNG_LIM_PRODUCT = 2'd0;  // above: infinity of its sign; below: zero of its sign
  localparam logic [1:0] P2_RNG_LIM_SUM     = 2'd1;  // above: infinity of its sign; below: +0
  localparam logic [1:0] P2_RNG_LIM_UNDER   = 2'd2;  // below: the mantissa cleared, the rest kept (depth `under`)
  localparam logic [1:0] P2_RNG_LIM_BELOW   = 2'd3;  // below: +0; above: kept (MipSelect's 1/det and 1/det^2)

  // p2_fp_rng_kind: the class of a product (MipSelect `kind`: 0 a number, 1 an infinity, -1 a zero)
  localparam logic [1:0] P2_KIND_NUMBER = 2'd0;
  localparam logic [1:0] P2_KIND_INF    = 2'd1;
  localparam logic [1:0] P2_KIND_ZERO   = 2'd2;

  // an exponent field sign-extended to the internal width
  function automatic logic signed [P2_FP_XW-1:0] p2_fp_xw(input logic signed [P2_FP_EW-1:0] e);
    return {{(P2_FP_XW - P2_FP_EW){e[P2_FP_EW-1]}}, e};
  endfunction
endpackage

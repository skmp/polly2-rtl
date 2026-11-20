// p2_fp_div_quot: H13, one quotient of the TSP divider: a numerator times the pixel's shared reciprocal
// (docs/spec/numerics.md H13 `divide`; docs/spec/tsp.md 6.3; ARCHITECTURE 3.7.7 P2: U, V, base x4, offset x4 and the mip
// w, each one of these on the one p2_fp_div_den; refcore pvr_tsp_plane.h Divide, the product):
//
//   num == 0:   +0 whatever den is (hugepos c: the one pixel where both planes are exactly 0 is black)
//   bn = BL(num.mant), en = top(num)                    num has at most 17 bits (H12a), all of them kept
//   p  = num.mant x r x 2, floored at 17 fractional bits of the product of the two mantissas as fractions in [0.5, 1):
//        q = p >> bn, and q + 1 when num is negative and bits were lost (toward minus infinity)
//   out = {num.neg, q, en + 1 - ed - 17}                q in [2^15, 2^17): 17 significant bits from 1/2 up, 16 below
//
// [uvmeas reciprow, reciprown: 1,560,000 of 1,560,000 readings, positive and negative; "the product is cut before it is
// normalized" (dreamcast-tests README, uvmeas item 8)]. The multiplier is MW x 16 on num's mantissa left-justified to
// MW bits (the same floor: num.mant x 2^(MW - bn) changes nothing below the cut). A zero quotient would be +0
// (refsw3's `if (out.mant == 0) out.neg = false`); a nonzero num never gives one. Combinational.
module p2_fp_div_quot
  import p2_pkg::*;
  import p2_fp_pkg::*;
#(
  parameter int MW = 17
) (
  input  logic                         n_neg,
  input  logic signed [P2_FP_EW-1:0]   n_exp,
  input  logic [MW-1:0]                n_mant,
  input  logic [15:0]                  r,        // p2_fp_div_den
  input  logic signed [P2_FP_XW-1:0]   ed,       // p2_fp_div_den
  output logic                         o_neg,
  output logic signed [P2_FP_EW-1:0]   o_exp,
  output logic [P2_QUOT_MANT_BITS-1:0] o_mant
);
  localparam int NW = $clog2(MW + 1);
  localparam int PW = MW + 16;          // the product of the two mantissas
  localparam int QF = 17;               // `out.exp = en + 1 - ed - 17`: floored at 17 fractional bits
  localparam int SH = PW - QF;          // the bits under the floor

  logic [NW-1:0]              bn;
  logic [MW-1:0]              mn;       // num.mant left-justified
  logic [PW-1:0]              p;
  logic                       lost;
  logic [QF-1:0]              q;        // < 2^17 - 2: the carry of the floor never overflows it
  logic signed [P2_FP_XW-1:0] oe;

  p2_fp_lzc #(.W(MW), .NW(NW)) u_bl (.v(n_mant), .n(bn));

  assign mn   = n_mant << (NW'(MW) - bn);
  assign p    = PW'(mn) * PW'(r);
  assign lost = p[SH-1:0] != '0;
  assign q    = p[PW-1 -: QF] + QF'(n_neg && lost);
  assign oe   = p2_fp_xw(n_exp) + P2_FP_XW'(bn) + P2_FP_XW'(1) - ed - P2_FP_XW'(QF);

  always_comb begin
    if (n_mant == '0) begin
      o_neg  = 1'b0;
      o_exp  = '0;
      o_mant = '0;
    end else begin
      o_neg  = n_neg;
      o_exp  = oe[P2_FP_EW-1:0];
      o_mant = P2_QUOT_MANT_BITS'(q);
    end
  end
endmodule

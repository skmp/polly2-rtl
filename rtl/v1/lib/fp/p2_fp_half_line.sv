// p2_fp_half_line: H7b tsp_half_line, a SupSample point half a line down (docs/spec/numerics.md H7b, 8 A1; refcore
// pvr_tsp_plane.h PlaneT::Value L361-368 at 708fb8cd):
//
//   k += FloorUnits(Add(c_, bh, 62, 400), unit) - FloorUnits(c_, unit)        (super, hy = 1)
//
// with c_ = seen(C), b_ = seen(B) (p2_fp_in_seen: never zero, never bad) and bh = Mul(b_, FromHalves(1), 62) = b_ / 2
// (b_'s mantissa, exp - 1). The output is that difference, dk = floor(T / 2^unit) - floor(c_ / 2^unit), T = c_ + bh as
// refsw3's wide Add has it, which is NOT exact (ARTIFACT A1):
//   |c_.exp - bh.exp| > 90 (the window, Add case W): T = the operand of the larger top, its own tuple: bh adds nothing
//   otherwise: T = the exact sum (<= 16 + 90 + 1 bits) truncated to its 62 most significant bits, toward zero; an exact
//              cancellation is +0
// Unlike the other wide adds the 62-bit truncation is observable here: a floor follows, and a negative T that lost bits
// below the 62nd floors one unit higher (num H7b's table: C < 0, gaps 47 .. 90 give 0 where the exact sum gives -1).
// Add's reach of 400 never acts: the two tops are within 257 of each other (seen coefficients of the ranged setup), and
// beyond 400 the window returns the same operand. Evidence for the rule's place: dreamcast-tests pvr-tests/supsample,
// supsample2, ssrare (140,545 pixels where the unit shows: the 24 that carry), sshalf; the window and the truncation
// are A1 (no console test tells them apart yet).
//
// Built as num H7b says: an exact adder over the window (MW + 91 bits and a sign), a bit length, a mask of the bits
// below top - 62, and two floors to the grid 2^unit (a shift with a sticky for a negative value that lost bits).
// Domain (the site's grid, PlaneT::Value): unit >= max(top(c_), top(b_) + 4) - 22, so every floor here is below 2^24 in
// size; KW holds them with room (the testbench asserts the reference's floors fit). Combinational.
module p2_fp_half_line
  import p2_fp_pkg::*;
#(
  parameter int MW = 16,          // coefficient mantissa bits (PlaneHW::coefBits)
  parameter int KW = 27           // the floors and dk: the TSP evaluator's accumulator (num H11: 27 bits)
) (
  input  logic                       c_neg,     // c_ = seen(C)
  input  logic signed [P2_FP_EW-1:0] c_exp,
  input  logic [MW-1:0]              c_mant,
  input  logic                       b_neg,     // b_ = seen(B); bh = b_ / 2
  input  logic signed [P2_FP_EW-1:0] b_exp,
  input  logic [MW-1:0]              b_mant,
  input  logic signed [P2_FP_EW-1:0] unit,      // the plane's grid exponent (PlaneHW::gridBits under its top)
  output logic signed [KW-1:0]       dk
);
  localparam int WIN   = 90;            // pvr_softfp.h Add: `if (sx > 90 || sy > 90)` (case W)
  localparam int TRUNC = 62;            // the call's N: Add(c_, bh, 62, 400) (refsw3 cuts to 64, then 62: they compose)
  localparam int AW    = MW + WIN + 1;  // the exact sum's magnitude bits (107)
  localparam int AW1   = AW + 1;        // and with a sign
  localparam int NW    = $clog2(AW + 1);
  localparam int MNW   = $clog2(MW + 1);
  localparam int SHW   = $clog2(WIN + 1); // an alignment shift, 0 .. 90

  logic signed [P2_FP_XW-1:0] ce, be, de, lsb, tc, tb;
  logic [MNW-1:0]             nc, nb;
  logic                       win;          // the LSB exponents more than 90 apart
  logic [SHW-1:0]             sc, sb;       // each operand's shift onto lsb (0 .. 90 when not win)
  logic [AW-1:0]              mc, mb;       // the aligned magnitudes
  logic signed [AW:0]         vc, vb, s;    // signed operands and their exact sum
  logic [AW-1:0]              ms;           // |S|
  logic [NW-1:0]              ns;           // BL(|S|)
  logic [AW-1:0]              keep;         // the 62 bits from the leading one
  logic                       t_neg;
  logic [AW-1:0]              t_mag;
  logic signed [P2_FP_XW-1:0] t_exp;
  logic signed [KW-1:0]       fu_t, fu_c;

  p2_fp_lzc #(.W(MW), .NW(MNW)) u_blc (.v(c_mant), .n(nc));
  p2_fp_lzc #(.W(MW), .NW(MNW)) u_blb (.v(b_mant), .n(nb));
  p2_fp_lzc #(.W(AW), .NW(NW)) u_bls (.v(ms), .n(ns));

  // floor(sgn a 2^e / 2^unit) as an integer (pvr_tsp_plane.h FloorUnits; a +0 is 0: T is never -0 here, c_ never 0);
  // within the domain the value is below 2^24, so a left shift by more than KW never happens there
  function automatic logic signed [KW-1:0] floor_units(input logic sgn, input logic [AW-1:0] a,
                                                       input logic signed [P2_FP_XW-1:0] e,
                                                       input logic signed [P2_FP_XW-1:0] u);
    logic signed [P2_FP_XW-1:0] sh;     // unit - e: the bits to drop
    logic [KW-1:0]              q;      // within the domain the quotient is below 2^KW
    logic [AW-1:0]              lost;
    logic [KW-1:0]              m;
    sh = u - e;
    if (sh <= 0) begin
      m = (0 - sh > P2_FP_XW'(KW)) ? '0 : KW'(a << (0 - sh));
    end else begin
      q    = (sh >= P2_FP_XW'(AW)) ? '0 : KW'(a >> sh);
      lost = (sh >= P2_FP_XW'(AW)) ? a : a & ((AW'(1) << sh) - AW'(1));
      m    = KW'(q) + KW'((sgn && lost != '0) ? 1 : 0);   // a negative value with a fraction: one further from zero
    end
    return sgn ? $signed(KW'(0) - m) : $signed(m);
  endfunction

  assign ce  = p2_fp_xw(c_exp);
  assign be  = p2_fp_xw(b_exp) - P2_FP_XW'(1);      // bh = b_ * 2^-1: the same mantissa one exponent down
  assign tc  = ce + P2_FP_XW'(nc);
  assign tb  = be + P2_FP_XW'(nb);
  assign de  = ce - be;
  assign win = (de > P2_FP_XW'(WIN)) || (de < P2_FP_XW'(0 - WIN));
  assign lsb = (ce < be) ? ce : be;
  assign sc  = win ? '0 : SHW'(ce - lsb);
  assign sb  = win ? '0 : SHW'(be - lsb);
  assign mc  = AW'(c_mant) << sc;
  assign mb  = AW'(b_mant) << sb;
  assign vc  = c_neg ? $signed(AW1'(0)) - $signed({1'b0, mc}) : $signed({1'b0, mc});
  assign vb  = b_neg ? $signed(AW1'(0)) - $signed({1'b0, mb}) : $signed({1'b0, mb});
  assign s   = vc + vb;
  assign ms  = s[AW] ? AW'($signed(AW1'(0)) - s) : s[AW-1:0];
  // the 62 most significant bits of |S|, toward zero (refsw3: the 64-bit truncation, then cut(62))
  assign keep = (ns > NW'(TRUNC)) ? ~((AW'(1) << (ns - NW'(TRUNC))) - AW'(1)) : '1;

  always_comb begin
    if (win) begin
      // case W: the operand of the larger top, as it is (a tie, impossible with 16-bit mantissas, would be bh)
      t_neg = (tc > tb) ? c_neg : b_neg;
      t_mag = (tc > tb) ? AW'(c_mant) : AW'(b_mant);
      t_exp = (tc > tb) ? ce : be;
    end else begin
      t_neg = s[AW];                    // an exact cancellation is +0
      t_mag = ms & keep;
      t_exp = lsb;
    end
    fu_t = floor_units(t_neg, t_mag, t_exp, p2_fp_xw(unit));
    fu_c = floor_units(c_neg, AW'(c_mant), ce, p2_fp_xw(unit));
    dk   = fu_t - fu_c;
  end
endmodule

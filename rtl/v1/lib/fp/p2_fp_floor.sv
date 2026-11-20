// p2_fp_floor: H11, a float to an integer, floor(v / 2^u) (docs/spec/numerics.md H11, 2.10). One shifter with a sticky
// ("bits lost") and +1 for a negative magnitude that lost bits; the three refsw3 converters differ only in their zero
// convention and their clamp, which are parameters:
//
//   FloorScaled(v, s)    pvr_softfp.h L251: u = -s; a zero of either sign is 0; top(v) + s > 40 gives +-2^40
//                        (ZNEG 0, CLAMP 40). Site: RowRange (pvr_isp_edge.h L131): floor(y) and floor(2y) [covmeas mix
//                        sliver: rows floor(ymin) .. floor(ymax + 1/2)]
//   FloorUnits(v, unit)  pvr_tsp_plane.h L90: u = unit; +0 is 0, -0 is -1, one grid unit below zero (ZNEG 1, CLAMP 0)
//                        [uvmeas point 5: a flat plane on a negative determinant steps one unit down a pixel; wmeas:
//                        60 % of flat triangles a fog level low]. Its `s >= 62` clamp is unreachable (A4): the caller's
//                        values fit OW (the testbench asserts it). Sites: PlaneT::Value c_, ax, by, a_, ah
//   edge unitsAt(v, u)   pvr_isp_edge.h EdgeTile::Setup L239: a zero is 0 (ZNEG 0, CLAMP 0), and o_frac: v is not a
//                        whole number of units (any bit lost). Sites: t0, tx, ty (u = unit), a big edge's f0, fx, fy
//                        (u = unit - 6) [covmeas: 98 sets; faredge, hugepos]
//
// o_frac is the sticky for every variant. Domain: v finite (a bad v is the caller's: RowRange's corners have returned
// on a bad corner, Value's coefficients are seen(), Setup returned on a bad corner); without a clamp the value fits OW
// bits signed (the callers' widths; the testbench asserts it). Combinational.
module p2_fp_floor
  import p2_fp_pkg::*;
#(
  parameter int MW    = 24,       // mantissa bits
  parameter int OW    = 42,       // result bits, signed
  parameter bit ZNEG  = 1'b0,     // 1: -0 is -1 (FloorUnits); 0: a zero of either sign is 0
  parameter int CLAMP = 0         // > 0: top(v) - u > CLAMP gives +-2^CLAMP (FloorScaled: 40); 0: none
) (
  input  logic                       i_neg,
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [MW-1:0]              i_mant,
  input  logic signed [P2_FP_EW-1:0] u,          // the result is in units of 2^u
  output logic signed [OW-1:0]       o_int,
  output logic                       o_frac      // bits below 2^u were lost
);
  localparam int NW = $clog2(MW + 1);
  localparam int SW = $clog2(MW + OW + 1);       // a shift amount, clamped to MW + OW
  localparam int WW = MW + OW;                   // the left shift's width before the cut to OW

  logic [NW-1:0]              n;
  logic signed [P2_FP_XW-1:0] s;                 // exp - u: > 0 a left shift, < 0 a right shift
  logic signed [P2_FP_XW-1:0] ns;                // u - exp
  logic signed [P2_FP_XW-1:0] tu;                // top(v) - u
  logic                       zero, clamped;
  logic [SW-1:0]              sl, sr;            // the shifts, clamped
  logic [OW-1:0]              wide;              // the left shift (within the domain it loses nothing)
  logic [OW-1:0]              q;                 // the magnitude, toward zero
  logic [MW-1:0]              lost;

  p2_fp_lzc #(.W(MW), .NW(NW)) u_bl (.v(i_mant), .n(n));

  assign zero    = i_mant == '0;
  assign s       = p2_fp_xw(i_exp) - p2_fp_xw(u);
  assign ns      = P2_FP_XW'(0) - s;
  assign tu      = s + P2_FP_XW'(n);
  assign clamped = (CLAMP > 0) && !zero && (tu > P2_FP_XW'(CLAMP));
  assign sl      = (s <= 0) ? '0 : (s > P2_FP_XW'(MW + OW)) ? SW'(MW + OW) : SW'(s);
  assign sr      = (s >= 0) ? '0 : (ns > P2_FP_XW'(MW + OW)) ? SW'(MW + OW) : SW'(ns);
  assign wide    = OW'(WW'(i_mant) << sl);
  assign q       = (s >= 0) ? wide : OW'(MW'(i_mant >> sr));
  assign lost    = (s >= 0) ? '0 : (sr >= SW'(MW)) ? i_mant : i_mant & ((MW'(1) << sr) - MW'(1));
  assign o_frac  = lost != '0;

  always_comb begin
    if (zero)
      o_int = (ZNEG && i_neg) ? '1 : '0;          // -1, or 0
    else if (clamped)
      o_int = i_neg ? $signed(OW'(0) - (OW'(1) << CLAMP)) : $signed(OW'(1) << CLAMP);
    else if (i_neg)
      o_int = $signed(OW'(0) - q - OW'(o_frac));   // a negative with a fraction: one further from zero
    else
      o_int = $signed(q);
  end
endmodule

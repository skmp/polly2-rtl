// p2_fp_lzc: H1, the bit length of v: the index of its leading one plus one, 0 for 0 (docs/spec/numerics.md H1, 2.1;
// refcore pvr_bits.h BitLength, which every pvr_softfp.h Fp::top() and Fp::cut() reads). A priority encoder of the
// operand's width; refsw3 has no other kind of bit scan in hardware (TrailingZeros has no HW site, num 2.1).
// Instances: 16 and 17 (TSP value, numerator), 24 and 25, 34 (divider product), 49 / 50 (the 24/25 adder), 64 and
// 108 (wide adds), 128 (depth block).
//
// Built as a halving search, log2(W) steps: is there a one in the upper half of what is left? Then the leading one's
// index has that bit set, and the search goes on in the upper half. Combinational.
module p2_fp_lzc #(
  parameter int W  = 24,
  parameter int NW = $clog2(W + 1)
) (
  input  logic [W-1:0]  v,
  output logic [NW-1:0] n
);
  localparam int L = (W > 1) ? $clog2(W) : 1;   // steps
  localparam int P = 1 << L;                     // v padded to a power of two

  logic [P-1:0]  x;
  logic [NW-1:0] b;      // the leading one's index

  always_comb begin
    x = P'(v);
    b = '0;
    for (int k = L - 1; k >= 0; k--) begin
      if ((x >> (1 << k)) != '0) begin
        x = x >> (1 << k);
        b = b + NW'(1 << k);
      end
    end
    n = (v == '0) ? '0 : b + NW'(1);
  end
endmodule

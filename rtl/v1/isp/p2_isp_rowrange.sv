// p2_isp_rowrange: the rows a polygon is rasterized on, before the tile (refcore pvr_isp_edge.h RowRange L130 at refsw3
// 4f3efe15; isp 8.6; num 5.1 L134):
//
//   first = min over the corners of floor(y);  last = max over the corners of floor(y + 1/2) = (floor(2y) + 1) >> 1
//
// every corner of a quad included, through FloorScaled (num H11: a zero is 0, beyond 2^40 clamped to +-2^40), the same
// in row numbers whatever HALF_OFFSET is [covmeas rule 10, mix sliver: 0 of 635 pixels above the top corner's row, 0 of
// 483 two rows below, the row after the bottom corner's exactly when frac(ymax) >= 0.5 (72 of 72 / 0 of 70); sliver35
// with HALF_OFFSET 6]. The corners are finite (a bad corner ends the primitive first). The tile's part is
// p2_isp_rowclip. Combinational.
module p2_isp_rowrange
  import p2_pkg::*;
  import p2_fp_pkg::*;
#(
  parameter int RW = 42                         // the row numbers: +-2^40, and one more bit for the tile's arithmetic
) (
  input  p2_fp24_t [3:0]        y,
  input  logic                  quad,
  output logic signed [RW-1:0]  row_first,
  output logic signed [RW-1:0]  row_last
);
  logic signed [3:0][RW-1:0] f0, f1;
  logic signed [RW-1:0]      fk [4];
  logic signed [RW-1:0]      lk [4];

  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_c
      // FloorScaled(y, 0) and FloorScaled(y, 1): floor(y / 2^0) and floor(y / 2^-1), clamp 40
      p2_fp_floor #(.MW(P2_FP24_MANT_BITS), .OW(RW), .ZNEG(1'b0), .CLAMP(40)) u_f0 (
        .i_neg(y[g].neg), .i_exp(y[g].exp), .i_mant(y[g].mant), .u(P2_FP_EW'(0)), .o_int(f0[g]), .o_frac());
      p2_fp_floor #(.MW(P2_FP24_MANT_BITS), .OW(RW), .ZNEG(1'b0), .CLAMP(40)) u_f1 (
        .i_neg(y[g].neg), .i_exp(y[g].exp), .i_mant(y[g].mant), .u(P2_FP_EW'(0) - P2_FP_EW'(1)), .o_int(f1[g]),
        .o_frac());
      assign fk[g] = f0[g];
      assign lk[g] = (f1[g] + RW'(1)) >>> 1;
    end
  endgenerate

  always_comb begin
    row_first = fk[0];
    row_last  = lk[0];
    for (int k = 1; k < 4; k++) begin
      if (k < 3 || quad) begin
        if (fk[k] < row_first) row_first = fk[k];
        if (lk[k] > row_last)  row_last  = lk[k];
      end
    end
  end
endmodule

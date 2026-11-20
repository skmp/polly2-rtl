// p2_fp_cull: H9, the ISP's culls on the edge unit's swamped determinant (EdgeWinding, num H7a) (docs/spec/numerics.md
// H9, 2.12; refcore refsw_tile.cpp CulledBySize, CulledByFacing).
//
//   by_size:    det.bad: 0;  size = FPU_CULL_VAL & 0x7fffffff;  size >= 0x7f800000: 1 (an infinity or any NaN culls
//               every triangle);  else |det| <= |FromBits(size)| (equal is culled: raster page 4; a denormal register
//               is kept as one; cullval: only the register's size counts, 2^-149 culls nothing, 4800 of 4800 regions)
//   by_facing:  cull_mode < 2 or det.bad or det == 0: 0;  else (cull_mode & 1) ? !det.neg : det.neg
//               (faredge_cull: the swamped determinant's size and sign, 1,200 of 1,200 regions)
//
// The caller applies them only with CullMode != 0 and no bad corner (refsw_tile.cpp L785). Combinational.
module p2_fp_cull
  import p2_fp_pkg::*;
(
  input  logic                       det_neg,
  input  logic                       det_bad,
  input  logic signed [P2_FP_EW-1:0] det_exp,
  input  logic [23:0]                det_mant,
  input  logic [31:0]                fpu_cull_val,
  input  logic [1:0]                 cull_mode,     // ISP_TSP CullMode
  output logic                       by_size,
  output logic                       by_facing
);
  logic [31:0]                size;
  logic                       sz_neg, sz_bad, abs_le;
  logic signed [P2_FP_EW-1:0] sz_exp;
  logic [23:0]                sz_mant;

  assign size = fpu_cull_val & 32'h7FFFFFFF;

  p2_fp_in_single u_size (
    .u(size), .ranged(1'b0), .o_neg(sz_neg), .o_bad(sz_bad), .o_exp(sz_exp), .o_mant(sz_mant));

  p2_fp_abs_le #(.MW(24)) u_le (
    .a_exp(det_exp), .a_mant(det_mant), .b_bad(sz_bad), .b_exp(sz_exp), .b_mant(sz_mant), .le(abs_le));

  assign by_size   = det_bad ? 1'b0 : (size >= 32'h7F800000) ? 1'b1 : abs_le;
  assign by_facing = (cull_mode < 2'd2 || det_bad || det_mant == '0) ? 1'b0 : cull_mode[0] ? !det_neg : det_neg;
endmodule

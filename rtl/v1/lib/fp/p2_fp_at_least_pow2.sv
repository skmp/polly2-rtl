// p2_fp_at_least_pow2: H9, |v| >= 2^e: mant != 0 and top(v) > e (docs/spec/numerics.md H9, 2.6; refcore
// pvr_softfp.h Fp::atLeastPow2). Sites: the edge unit's swamp and saturation, every one at e = 128 (pvr_isp_edge.h
// EdgeWinding L113, EdgeTile::Setup L181, L190-191, L196; num H7a; faredge_cmax, hugepos_v4-v6). Combinational.
module p2_fp_at_least_pow2
  import p2_fp_pkg::*;
#(
  parameter int MW = 24
) (
  input  logic signed [P2_FP_EW-1:0] i_exp,
  input  logic [MW-1:0]              i_mant,
  input  logic signed [P2_FP_EW-1:0] e,
  output logic                       ge
);
  localparam int NW = $clog2(MW + 1);

  logic [NW-1:0]              n;
  logic signed [P2_FP_XW-1:0] t;

  p2_fp_lzc #(.W(MW), .NW(NW)) u_bl (.v(i_mant), .n(n));

  assign t  = p2_fp_xw(i_exp) + $signed({{(P2_FP_XW - NW){1'b0}}, n});
  assign ge = (i_mant != '0) && (t > p2_fp_xw(e));
endmodule

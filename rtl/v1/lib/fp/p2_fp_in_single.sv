// p2_fp_in_single: H4, an IEEE single's bits as the setup units take them (docs/spec/numerics.md H4, 2.5; refcore
// pvr_softfp.h Fp::FromBits, Fp::FromSingle). f = u[30:23], m = u[22:0].
//
//   ranged = 0 (FromBits: the edge unit's x, y; FPU_CULL_VAL and FPU_PERP_VAL & 0x7fffffff):
//     f == 255:  bad, unsigned, mant 0          (an infinity or a NaN)
//     f == 0:    {u[31], m, -149}               (a denormal kept as it is, unnormalized; m = 0 is +-0)
//     else:      {u[31], 0x800000 | m, f - 150}
//   ranged = 1 (FromSingle(u, 1): the depth and TSP setups' x, y, z and attributes, MipSelect's DCalcCtrl-1 inputs):
//     f == 255:  bad with its sign, mant 0      (uvmeas wexp, whuge, wspec: "field 255 infinity, whatever the
//     f == 0:    +-0, the fraction ignored       mantissa says"; field 0 is zero: wtiny, cmeas cwext1)
//     else:      as ranged = 0
//
// A bad or zero result's exp is not read (num 1.3): it is 0 here, as refcore leaves it. Combinational.
module p2_fp_in_single
  import p2_fp_pkg::*;
(
  input  logic [31:0]                u,
  input  logic                       ranged,
  output logic                       o_neg,
  output logic                       o_bad,
  output logic signed [P2_FP_EW-1:0] o_exp,
  output logic [23:0]                o_mant
);
  logic [7:0]  f;
  logic [22:0] m;
  assign f = u[30:23];
  assign m = u[22:0];

  always_comb begin
    o_neg  = u[31];
    o_bad  = 1'b0;
    o_exp  = '0;
    o_mant = '0;
    if (f == 8'hFF) begin
      o_bad = 1'b1;
      if (!ranged) o_neg = 1'b0;        // FromBits: an unsigned infinity
    end else if (f == 8'h00) begin
      if (!ranged) begin                // FromBits: the denormal itself
        o_mant = {1'b0, m};
        o_exp  = P2_FP_EW'(-149);
      end
    end else begin
      o_mant = {1'b1, m};
      o_exp  = $signed({{(P2_FP_EW - 8){1'b0}}, f}) - P2_FP_EW'(150);
    end
  end
endmodule

// p2_isp_depth_setup: the ISP depth setup datapath as a fixed-latency unit (PLAN M3; ARCHITECTURE 3.4.4 steps 6-7, 2.4
// p2_ztile_t; isp 6.3, 9.1-9.5 at refsw3 4f3efe15). One (primitive, tile) pair a clock in, its p2_ztile_t LAT = 2
// clocks later; no back-pressure. M4's microprogrammed p2_isp_setup replaces the datapath's sequencing (the
// scheduler shares the operations with the edge unit's program); the functions are these.
//
//   stage A (combinational on the inputs, registered into s1): p2_isp_depth_plane, the primitive's plane a, b, c, det
//     (ranged, the zero rule in every addition, FPU_PERP_VAL) and the determinant-zero mean's key; it does not depend
//     on the tile
//   stage B (registered into the outputs): p2_isp_depth_tile, the tile's regime and its fields: first0 at the tile's
//     first sample point (HALF_OFFSET[0]), REG, BLOCK, CONST
//
// The plane is set up for every primitive, culled and bad ones included (the caller decides: ARCHITECTURE 3.4.4 step
// 8); a bad corner's depth is never drawn. Depth never shows in the setup's time [M tim 3.2]: every regime takes the
// same path.
module p2_isp_depth_setup
  import p2_pkg::*;
(
  input  logic             clk,
  input  logic             rst,
  input  logic             in_v,
  input  logic [2:0][31:0] x_bits,        // the first three corners' x, y, z as IEEE singles, rasterizer order
  input  logic [2:0][31:0] y_bits,
  input  logic [2:0][31:0] z_bits,
  input  logic [31:0]      fpu_perp_val,  // FPU_PERP_VAL
  input  logic             half,          // HALF_OFFSET[0] (fpu_pixel_half_offset): sample at pixel centres
  input  logic [5:0]       tile_x,
  input  logic [5:0]       tile_y,
  output logic             out_v,
  output p2_ztile_t        z,
  // the setup's intermediate values for the testbench (refsw3's a, b, c, det after Perpendicular, first0, A, B)
  output p2_fp24_t         dbg_a,
  output p2_fp24_t         dbg_b,
  output p2_fp24_t         dbg_c,
  output p2_fp24_t         dbg_det,
  output p2_fp24_t         dbg_first0,
  output p2_fp24_t         dbg_sa,
  output p2_fp24_t         dbg_sb
);
  // ---------------------------------------------------------------------------------------------------------- stage A
  p2_fp24_t pa, pb, pc, pdet;
  p2_zkey_t pmean;
  p2_isp_depth_plane u_plane (.x_bits(x_bits), .y_bits(y_bits), .z_bits(z_bits), .fpu_perp_val(fpu_perp_val),
    .a(pa), .b(pb), .c(pc), .det(pdet), .mean_key(pmean));

  logic       s1_v, s1_half;
  p2_fp24_t   s1_a, s1_b, s1_c, s1_det;
  p2_zkey_t   s1_mean;
  logic [5:0] s1_tx, s1_ty;
  always_ff @(posedge clk) begin
    if (rst)
      s1_v <= 1'b0;
    else
      s1_v <= in_v;
    s1_a    <= pa;
    s1_b    <= pb;
    s1_c    <= pc;
    s1_det  <= pdet;
    s1_mean <= pmean;
    s1_half <= half;
    s1_tx   <= tile_x;
    s1_ty   <= tile_y;
  end

  // ---------------------------------------------------------------------------------------------------------- stage B
  p2_ztile_t bz;
  p2_fp24_t  bfirst0, bsa, bsb;
  p2_isp_depth_tile u_tile (.a(s1_a), .b(s1_b), .c(s1_c), .det(s1_det), .mean_key(s1_mean), .tile_x(s1_tx),
    .tile_y(s1_ty), .half(s1_half), .z(bz), .first0_o(bfirst0), .sa_o(bsa), .sb_o(bsb));

  always_ff @(posedge clk) begin
    if (rst)
      out_v <= 1'b0;
    else
      out_v <= s1_v;
    z          <= bz;
    dbg_a      <= s1_a;
    dbg_b      <= s1_b;
    dbg_c      <= s1_c;
    dbg_det    <= s1_det;
    dbg_first0 <= bfirst0;
    dbg_sa     <= bsa;
    dbg_sb     <= bsb;
  end
endmodule

// p2_isp_edge_tb_top: make isp-edge (tb/isp_edge/isp_edge_tb.cpp, PLAN M2). Flat ports around the two edge units:
//   - p2_isp_edge_setup: one (primitive, tile) pair a clock in, its bad / culled / winding / determinant, the four
//     p2_edge_t and jf / jl / rows_v two clocks later (fixed latency, no back-pressure);
//   - p2_isp_edge_raster: a descriptor in (valid / ready), its rows out (valid / ready), one a clock.
// The testbench moves each setup result into the raster's input itself (a FIFO in C++), so that each side sees random
// gaps and back-pressure of its own (PLAN 1.2 section 4). The edges cross as one unpacked array per field.
module p2_isp_edge_tb_top
  import p2_pkg::*;
(
  input  logic                                clk,
  input  logic                                rst,
  // ---- setup
  input  logic                                su_in_v,
  input  logic [31:0]                         su_x [4],
  input  logic [31:0]                         su_y [4],
  input  logic                                su_quad,
  input  logic                                su_modvol,
  input  logic [1:0]                          su_cull_mode,
  input  logic [31:0]                         su_cull_val,
  input  logic                                su_half,
  input  logic [5:0]                          su_tile_x,
  input  logic [5:0]                          su_tile_y,
  output logic                                su_out_v,
  output logic                                su_bad,
  output logic                                su_culled,
  output logic                                su_flip,
  output logic                                su_det_neg,
  output logic                                su_det_bad,
  output logic [P2_FP_EXP_BITS-1:0]           su_det_exp,
  output logic [P2_FP24_MANT_BITS-1:0]        su_det_mant,
  output logic                                su_const_v [4],
  output logic                                su_const_in [4],
  output logic [P2_EDGE_T0_BITS-1:0]          su_t0 [4],
  output logic [P2_EDGE_STEP_BITS-1:0]        su_tx [4],
  output logic [P2_EDGE_STEP_BITS-1:0]        su_ty [4],
  output logic [P2_EDGE_ZSH_BITS-1:0]         su_zsh [4],
  output logic                                su_big [4],
  output logic [P2_EDGE_FAR_BITS-1:0]         su_far32 [4],
  output logic [P2_TILE_LOG2-1:0]             su_jf,
  output logic [P2_TILE_LOG2-1:0]             su_jl,
  output logic                                su_rows_v,
  // ---- raster
  input  logic                                ra_in_v,
  output logic                                ra_in_rdy,
  input  logic                                ra_const_v [4],
  input  logic                                ra_const_in [4],
  input  logic [P2_EDGE_T0_BITS-1:0]          ra_t0 [4],
  input  logic [P2_EDGE_STEP_BITS-1:0]        ra_tx [4],
  input  logic [P2_EDGE_STEP_BITS-1:0]        ra_ty [4],
  input  logic [P2_EDGE_ZSH_BITS-1:0]         ra_zsh [4],
  input  logic                                ra_big [4],
  input  logic [P2_EDGE_FAR_BITS-1:0]         ra_far32 [4],
  input  logic [P2_TILE_LOG2-1:0]             ra_jf,
  input  logic [P2_TILE_LOG2-1:0]             ra_jl,
  input  logic                                ra_rows_v,
  input  logic                                ra_kill,
  output logic                                ra_row_v,
  input  logic                                ra_out_rdy,
  output logic [P2_TILE_LOG2-1:0]             ra_row_j,
  output logic [P2_TILE-1:0]                  ra_in_mask,
  output logic                                ra_row_last
);
  p2_hw_check u_hw_check ();

  p2_fp24_t       det;
  p2_edge_t [3:0] su_e, ra_e;

  p2_isp_edge_setup u_setup (
    .clk(clk), .rst(rst), .in_v(su_in_v),
    .x_bits({su_x[3], su_x[2], su_x[1], su_x[0]}), .y_bits({su_y[3], su_y[2], su_y[1], su_y[0]}),
    .quad(su_quad), .modvol(su_modvol), .cull_mode(su_cull_mode), .fpu_cull_val(su_cull_val), .half(su_half),
    .tile_x(su_tile_x), .tile_y(su_tile_y),
    .out_v(su_out_v), .bad(su_bad), .culled(su_culled), .flip(su_flip), .det(det), .edges(su_e),
    .jf(su_jf), .jl(su_jl), .rows_v(su_rows_v));

  assign su_det_neg  = det.neg;
  assign su_det_bad  = det.bad;
  assign su_det_exp  = det.exp;
  assign su_det_mant = det.mant;

  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_e
      assign su_const_v[g]  = su_e[g].const_v;
      assign su_const_in[g] = su_e[g].const_in;
      assign su_t0[g]       = su_e[g].t0;
      assign su_tx[g]       = su_e[g].tx;
      assign su_ty[g]       = su_e[g].ty;
      assign su_zsh[g]      = su_e[g].zsh;
      assign su_big[g]      = su_e[g].big;
      assign su_far32[g]    = su_e[g].far32;
      p2_edge_t ri;
      always_comb begin
        ri          = '0;
        ri.const_v  = ra_const_v[g];
        ri.const_in = ra_const_in[g];
        ri.t0       = ra_t0[g];
        ri.tx       = ra_tx[g];
        ri.ty       = ra_ty[g];
        ri.zsh      = ra_zsh[g];
        ri.big      = ra_big[g];
        ri.far32    = ra_far32[g];
      end
      assign ra_e[g] = ri;
    end
  endgenerate

  p2_isp_edge_raster u_raster (
    .clk(clk), .rst(rst), .in_v(ra_in_v), .in_rdy(ra_in_rdy), .in_edges(ra_e), .in_jf(ra_jf), .in_jl(ra_jl),
    .in_rows_v(ra_rows_v), .in_kill(ra_kill), .row_v(ra_row_v), .out_rdy(ra_out_rdy), .row_j(ra_row_j),
    .in_mask(ra_in_mask), .row_last(ra_row_last));
endmodule

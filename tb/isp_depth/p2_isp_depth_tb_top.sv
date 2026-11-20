// p2_isp_depth_tb_top: make isp-depth (tb/isp_depth/isp_depth_tb.cpp, PLAN M3). Flat ports around the two depth units:
//   - p2_isp_depth_setup: one (primitive, tile) pair a clock in, its p2_ztile_t and the setup's intermediate values two
//     clocks later (fixed latency, no back-pressure);
//   - p2_isp_depth_raster: a descriptor in (valid / ready), its rows of 32 keys out (valid / ready), one a clock.
// The testbench moves each setup result into the raster's input itself (a FIFO in C++), so that each side sees random
// gaps and back-pressure of its own (PLAN 1.2 section 4).
module p2_isp_depth_tb_top
  import p2_pkg::*;
(
  input  logic                              clk,
  input  logic                              rst,
  // ---- setup
  input  logic                              su_in_v,
  input  logic [31:0]                       su_x [3],
  input  logic [31:0]                       su_y [3],
  input  logic [31:0]                       su_z [3],
  input  logic [31:0]                       su_perp,
  input  logic                              su_half,
  input  logic [5:0]                        su_tile_x,
  input  logic [5:0]                        su_tile_y,
  output logic                              su_out_v,
  output logic [1:0]                        su_regime,
  output logic [63:0]                       su_key,
  output logic [P2_ZT_REG_BITS-1:0]         su_r0,
  output logic [1:0]                        su_sa,
  output logic [1:0]                        su_sb,
  output logic [30:0]                       su_fa,
  output logic [30:0]                       su_fb,
  output logic [P2_ZT_S_BITS-1:0]           su_S,
  output logic [P2_ZT_STEP_BITS-1:0]        su_DX,
  output logic [P2_ZT_STEP_BITS-1:0]        su_DY,
  output logic [9:0]                        su_gexp,
  output logic [8:0]                        su_E,
  output logic [P2_ZT_NSH_BITS-1:0]         su_nsh,
  output logic                              su_fbw,
  // the intermediate values, each as {neg, bad, exp[9:0], mant[23:0]} (36 bits): a, b, c, det, first0, A, B
  output logic [35:0]                       su_dbg [7],
  // ---- raster
  input  logic                              ra_in_v,
  output logic                              ra_in_rdy,
  input  logic [1:0]                        ra_regime,
  input  logic [63:0]                       ra_key,
  input  logic [P2_ZT_REG_BITS-1:0]         ra_r0,
  input  logic [1:0]                        ra_sa,
  input  logic [1:0]                        ra_sb,
  input  logic [30:0]                       ra_fa,
  input  logic [30:0]                       ra_fb,
  input  logic [P2_ZT_S_BITS-1:0]           ra_S,
  input  logic [P2_ZT_STEP_BITS-1:0]        ra_DX,
  input  logic [P2_ZT_STEP_BITS-1:0]        ra_DY,
  input  logic [9:0]                        ra_gexp,
  input  logic [8:0]                        ra_E,
  input  logic [P2_ZT_NSH_BITS-1:0]         ra_nsh,
  input  logic                              ra_fbw,
  input  logic [P2_TILE_LOG2-1:0]           ra_jf,
  input  logic [P2_TILE_LOG2-1:0]           ra_jl,
  input  logic                              ra_rows_v,
  output logic                              ra_row_v,
  input  logic                              ra_out_rdy,
  output logic [P2_TILE_LOG2-1:0]           ra_row_j,
  output logic [63:0]                       ra_zk [P2_TILE],
  output logic                              ra_row_last
);
  p2_hw_check u_hw_check ();

  p2_ztile_t sz, rz;
  p2_fp24_t  d [7];

  p2_isp_depth_setup u_setup (
    .clk(clk), .rst(rst), .in_v(su_in_v),
    .x_bits({su_x[2], su_x[1], su_x[0]}), .y_bits({su_y[2], su_y[1], su_y[0]}), .z_bits({su_z[2], su_z[1], su_z[0]}),
    .fpu_perp_val(su_perp), .half(su_half), .tile_x(su_tile_x), .tile_y(su_tile_y),
    .out_v(su_out_v), .z(sz),
    .dbg_a(d[0]), .dbg_b(d[1]), .dbg_c(d[2]), .dbg_det(d[3]), .dbg_first0(d[4]), .dbg_sa(d[5]), .dbg_sb(d[6]));

  assign su_regime = sz.regime;
  assign su_key    = sz.key;
  assign su_r0     = sz.r0;
  assign su_sa     = sz.sa;
  assign su_sb     = sz.sb;
  assign su_fa     = sz.fa;
  assign su_fb     = sz.fb;
  assign su_S      = sz.S;
  assign su_DX     = sz.DX;
  assign su_DY     = sz.DY;
  assign su_gexp   = sz.gexp;
  assign su_E      = sz.E;
  assign su_nsh    = sz.nsh;
  assign su_fbw    = sz.fbw;

  genvar g;
  generate
    for (g = 0; g < 7; g = g + 1) begin : g_dbg
      assign su_dbg[g] = {d[g].neg, d[g].bad, d[g].exp, d[g].mant};
    end
  endgenerate

  always_comb begin
    rz        = '0;
    rz.regime = p2_zregime_t'(ra_regime);
    rz.key    = ra_key;
    rz.r0     = ra_r0;
    rz.sa     = ra_sa;
    rz.sb     = ra_sb;
    rz.fa     = ra_fa;
    rz.fb     = ra_fb;
    rz.S      = ra_S;
    rz.DX     = ra_DX;
    rz.DY     = ra_DY;
    rz.gexp   = ra_gexp;
    rz.E      = ra_E;
    rz.nsh    = ra_nsh;
    rz.fbw    = ra_fbw;
  end

  p2_zkey_t [P2_TILE-1:0] zk;
  p2_isp_depth_raster u_raster (
    .clk(clk), .rst(rst), .in_v(ra_in_v), .in_rdy(ra_in_rdy), .in_z(rz), .in_jf(ra_jf), .in_jl(ra_jl),
    .in_rows_v(ra_rows_v), .row_v(ra_row_v), .out_rdy(ra_out_rdy), .row_j(ra_row_j), .zk(zk),
    .row_last(ra_row_last));

  generate
    for (g = 0; g < P2_TILE; g = g + 1) begin : g_zk
      assign ra_zk[g] = zk[g];
    end
  endgenerate
endmodule

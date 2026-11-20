// p2_isp_depth_raster: the depth half of p2_isp_raster, the row stepper: one tile row a clock, the 32 lanes' stored keys
// (ARCHITECTURE 3.4.5 depth lanes, 2.4 p2_ztile_t; isp 9.4a, 9.5, 9.6; refcore pvr_isp_depth.h DepthTileT::At at
// refsw3 4f3efe15). M4 joins it with p2_isp_edge_raster under one descriptor; the handshake is that unit's.
//
// A descriptor (one primitive's depth in one tile, its rows jf .. jl) is taken when in_v && in_rdy; one with rows_v = 0
// has no row and is dropped. Its rows go out in order, one a clock, each as row_v / row_j / zk with row_last on the
// last; out_rdy = 0 holds the row. in_rdy is high when idle or with the last row going out.
//   BLOCK and REG are both "a row base plus lane offsets" on one 30-bit accumulator: the lane value is
//   v_i = base_j + i sx, base_j = base_0 + j sy, with
//     BLOCK  base_0 = S, sx = 2 DX, sy = 2 DY        (half units of G; |v| < 2^29, no wrap: isp 9.4a)
//     REG    base_0 = r0, sx = sa 2^25 + fa, sy = sb 2^25 + fb   (mod 2^30: the register's sign at 2^131, isp 9.5)
//   set at the take to base_0 + jf sy and stepped by sy a row; each lane converts its value (p2_isp_depth_lane).
module p2_isp_depth_raster
  import p2_pkg::*;
(
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         in_v,
  output logic                         in_rdy,
  input  p2_ztile_t                    in_z,
  input  logic [P2_TILE_LOG2-1:0]      in_jf,
  input  logic [P2_TILE_LOG2-1:0]      in_jl,
  input  logic                         in_rows_v,
  output logic                         row_v,
  input  logic                         out_rdy,
  output logic [P2_TILE_LOG2-1:0]      row_j,
  output p2_zkey_t [P2_TILE-1:0]       zk,
  output logic                         row_last
);
  localparam int TW = P2_ZT_T_BITS;
  typedef logic signed [TW-1:0] v_t;

  logic                    act;
  logic [P2_TILE_LOG2-1:0] j, jl;
  // the descriptor's per-lane fields (the steps live in base / sx / sy)
  p2_zregime_t                     zd_regime;
  p2_zkey_t                        zd_key;
  logic signed [9:0]               zd_gexp;
  logic signed [8:0]               zd_e;
  logic signed [P2_ZT_NSH_BITS-1:0] zd_nsh;
  logic                            zd_fbw;
  v_t                      base, sx, sy;

  logic adv, last, take;
  assign adv    = act && (!row_v || out_rdy);
  assign last   = j == jl;
  assign in_rdy = !act || (adv && last);
  assign take   = in_v && in_rdy && in_rows_v;

  // the steps of the descriptor being taken
  v_t in_base, in_sx, in_sy, in_base_jf;
  always_comb begin
    if (in_z.regime == P2_Z_REG) begin
      in_base = v_t'(in_z.r0);
      in_sx   = v_t'(in_z.sa) * v_t'(32'sd33554432) + v_t'(in_z.fa);
      in_sy   = v_t'(in_z.sb) * v_t'(32'sd33554432) + v_t'(in_z.fb);
    end else begin
      in_base = v_t'(in_z.S);
      in_sx   = v_t'(in_z.DX) * v_t'(2);
      in_sy   = v_t'(in_z.DY) * v_t'(2);
    end
    in_base_jf = in_base + in_sy * v_t'({1'b0, in_jf});
  end

  // the lanes
  p2_zkey_t [P2_TILE-1:0] k;
  genvar g;
  generate
    for (g = 0; g < P2_TILE; g = g + 1) begin : g_lane
      v_t vi;
      assign vi = base + sx * v_t'(g);
      p2_isp_depth_lane u_lane (.regime(zd_regime), .v(vi), .gexp(zd_gexp), .e(zd_e), .nsh(zd_nsh), .fbw(zd_fbw),
        .key_c(zd_key), .key(k[g]));
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      act   <= 1'b0;
      row_v <= 1'b0;
    end else begin
      if (adv) begin
        row_v    <= 1'b1;
        row_j    <= j;
        zk       <= k;
        row_last <= last;
        j        <= j + 1'b1;
        base     <= base + sy;
        if (last)
          act <= 1'b0;
      end else if (out_rdy)
        row_v <= 1'b0;
      if (take) begin
        act  <= 1'b1;
        j    <= in_jf;
        jl   <= in_jl;
        zd_regime <= in_z.regime;
        zd_key    <= in_z.key;
        zd_gexp   <= in_z.gexp;
        zd_e      <= in_z.E;
        zd_nsh    <= in_z.nsh;
        zd_fbw    <= in_z.fbw;
        base <= in_base_jf;
        sx   <= in_sx;
        sy   <= in_sy;
      end
    end
  end
endmodule

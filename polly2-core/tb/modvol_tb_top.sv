// modvol_tb_top - harness for the OPAQUE MODIFIER VOLUME datapath:
//
//   * stencil_tile_buffer : the 3-bit-per-pixel stencil plane - flip/summary
//     accumulate, SummarizeStencilOr / SummarizeStencilAnd, the CLEAR/zero walk,
//     and the spanner's 4-wide aligned INV read.
//   * peel_tile_buffer with b_modvol=1 : the depth side of a modvol fragment -
//     DepthMode forced to 6 (greater-or-equal, refsw2 PixelFlush_isp RM_MODIFIER),
//     the per-lane pass exported on b_mv_we, and NOTHING written back (no depth,
//     no tag, no valid, and b_we held low so u_taginvw stays untouched).
//
// Both are driven through their real peel_core access patterns: the stage A read /
// stage B write-back pair for the raster, and the read-ahead / delayed-write chunk
// walk for CLEAR and summarize.
module modvol_tb_top import tsp_pkg::*; #(
    parameter integer LANES = 8
) (
    input                     clk,
    input                     reset,

    // ---- stencil: raster stage A / stage B ----
    input                     st_ras_a_valid,
    input      [4:0]          st_ras_a_y,
    input      [4:0]          st_ras_a_x,
    input                     st_ras_b_valid,
    input      [LANES-1:0]    st_mv_we,
    input      [4:0]          st_b_y,
    input      [4:0]          st_b_x,
    // ---- stencil: CLEAR / zero walk ----
    input                     st_clr_valid,
    input      [6:0]          st_clr_addr,
    // ---- stencil: summarize RMW walk ----
    input                     st_sum_rd_valid,
    input      [6:0]          st_sum_rd_addr,
    input                     st_sum_wr_valid,
    input      [6:0]          st_sum_wr_addr,
    input                     st_sum_and,
    // ---- stencil: spanner 4-wide read ----
    input                     st_rd4_valid,
    input      [9:0]          st_rd4_group,
    output     [3:0]          st_g4_inv,

    // ---- peel buffer: CLEAR walk (seed a known depth/tag) ----
    input                     pl_clr_valid,
    input      [6:0]          pl_clr_addr,
    input      [30:0]         pl_clr_depth,
    input      [31:0]         pl_clr_tag,
    // ---- peel buffer: raster stage A / stage B ----
    input                     pl_ras_a_valid,
    input      [4:0]          pl_ras_a_y,
    input      [4:0]          pl_ras_a_x,
    input                     pl_ras_b_valid,
    input      [LANES-1:0]    pl_b_inside,
    input      [4:0]          pl_b_y,
    input      [4:0]          pl_b_x,
    input      [31:0]         pl_b_tag,
    input      [2:0]          pl_b_mode,
    input                     pl_b_modvol,
    output     [LANES-1:0]    pl_b_mv_we,
    output     [LANES-1:0]    pl_b_we,
    // ---- peel buffer: single-pixel read-back ----
    input                     pl_sh_rd_valid,
    input      [9:0]          pl_sh_rd_id,
    output                    pl_sh_valid,
    output     [31:0]         pl_sh_tag,
    output     [30:0]         pl_sh_depth
);
    // per-lane fragment depth, written from the C driver (a packed 31*LANES port is
    // painfully wide to poke through Verilator's flat interface).
    (* verilator public_flat_rw *) reg [30:0] invw_lane [0:LANES-1];
    wire [31*LANES-1:0] pl_b_invw;
    genvar gv;
    generate
      for (gv = 0; gv < LANES; gv = gv + 1) begin : ginvw
        assign pl_b_invw[31*gv +: 31] = invw_lane[gv];
      end
    endgenerate

    stencil_tile_buffer #(.LANES(LANES)) u_stencil (
        .clk(clk), .reset(reset),
        .ras_a_valid(st_ras_a_valid), .ras_a_y(st_ras_a_y), .ras_a_x(st_ras_a_x),
        .ras_b_valid(st_ras_b_valid), .mv_we(st_mv_we), .b_y(st_b_y), .b_x(st_b_x),
        .clr_valid(st_clr_valid), .clr_addr(st_clr_addr),
        .sum_rd_valid(st_sum_rd_valid), .sum_rd_addr(st_sum_rd_addr),
        .sum_wr_valid(st_sum_wr_valid), .sum_wr_addr(st_sum_wr_addr),
        .sum_and(st_sum_and),
        .rd4_valid(st_rd4_valid), .rd4_group(st_rd4_group),
        .g4_inv(st_g4_inv)
    );

    peel_tile_buffer #(.LANES(LANES)) u_peel (
        .clk(clk), .reset(reset),
        .ras_a_valid(pl_ras_a_valid), .ras_a_y(pl_ras_a_y), .ras_a_x(pl_ras_a_x),
        .ras_b_valid(pl_ras_b_valid), .b_inside(pl_b_inside), .b_invw(pl_b_invw),
        .b_y(pl_b_y), .b_x(pl_b_x), .b_tag(pl_b_tag), .b_mode(pl_b_mode),
        .b_zwdis(1'b0), .b_peeling(1'b0),
        .b_fwd(1'b0), .b_res({LANES{1'b0}}),
        .b_modvol(pl_b_modvol), .b_mv_we(pl_b_mv_we),
        .b_pass_lp(), .b_more(), .b_oldtag(), .b_we(pl_b_we),
        .sh_rd_valid(pl_sh_rd_valid), .sh_rd_id(pl_sh_rd_id),
        .sh_valid(pl_sh_valid), .sh_tag(pl_sh_tag), .sh_depth(pl_sh_depth),
        .clr_valid(pl_clr_valid), .clr_addr(pl_clr_addr),
        .clr_depth(pl_clr_depth), .clr_tag(pl_clr_tag),
        .pb_rd_valid(1'b0), .pb_rd_addr(7'd0),
        .pb_wr_valid(1'b0), .pb_wr_addr(7'd0),
        .pb_first(1'b0),
        .pb_ptinit(1'b0), .pb_ptswap(1'b0), .pb_ptfix(1'b0),
        .pb_res({LANES{1'b0}}), .pb_zres({(31*LANES){1'b0}}),
        .pb_zkeep(1'b0)
    );
endmodule

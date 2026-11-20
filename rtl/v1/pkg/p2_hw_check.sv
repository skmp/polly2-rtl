// p2_hw_check: elaboration checks on the generated p2_hw_pkg (conventions.md 5, PLAN M0).
//
// - MODE switches. refcore's *HW structs have members with more than one value (DepthHW::range, startOnSlopes,
//   PlaneHW::macOrder, ...). The RTL implements one value of each, written here. If a regenerated p2_hw_pkg has
//   another, elaboration stops here: a refsw3 change then breaks the RTL build instead of diverging silently.
//   make hw-pkg-check elaborates this module with each member the generator marks (MODE) at its value - 1 and + 1,
//   and p2_core with one of those, and fails if any of them still elaborates: write each check as
//   `if (P2_X != <value>) $fatal`, one per member.
// - The widths the shared number formats of p2_pkg stand for: every refcore width a format serves must equal it.
//
// Simulation only: Quartus 17 rejects an elaboration $error / $fatal inside a generate if (conventions.md 4.2).
// Under Verilator a failed check is a USERFATAL warning, which every build and lint here makes an error
// (-Werror-USERFATAL).
// p2_core instantiates this module, so every build and lint of the core runs it; a unit testbench top that does not
// contain p2_core instantiates it too.
module p2_hw_check;
  import p2_hw_pkg::*;
  import p2_pkg::*;

`ifndef SYNTHESIS
  generate
    // ---- MODE switches: the value the RTL implements ----
    // EdgeHW::guard -1: the tile-start adds are exact before the cut (num 3.1, covmeas point 3)
    if (P2_ISP_EDGE_GUARD != -1) begin : g_edge_guard
      $fatal(1, "p2_hw_pkg: EdgeHW::guard is %0d; the RTL implements -1", P2_ISP_EDGE_GUARD);
    end
    // EdgeHW::lastColumnByStep: a zero pixel in column 31 goes by the column step's sign (num 3.1)
    if (P2_ISP_EDGE_LAST_COLUMN_BY_STEP != 1) begin : g_edge_last_column_by_step
      $fatal(1, "p2_hw_pkg: EdgeHW::lastColumnByStep is %0d; the RTL implements 1", P2_ISP_EDGE_LAST_COLUMN_BY_STEP);
    end
    // DepthHW::startOnSlopes 1: any start is cut to the slopes' grid too (zstart; ARCHITECTURE 2.4: no float regime)
    if (P2_ISP_DEPTH_START_ON_SLOPES != 1) begin : g_depth_start_on_slopes
      $fatal(1, "p2_hw_pkg: DepthHW::startOnSlopes is %0d; the RTL implements 1", P2_ISP_DEPTH_START_ON_SLOPES);
    end
    // DepthHW::range 1: the depth setup's range rules (num 4; huge, zovf_*)
    if (P2_ISP_DEPTH_RANGE != 1) begin : g_depth_range
      $fatal(1, "p2_hw_pkg: DepthHW::range is %0d; the RTL implements 1", P2_ISP_DEPTH_RANGE);
    end
    // PlaneHW::range 1: the TSP setup's range rules (num 4; uvmeas wexp, whuge, wtiny, wspec, wneg)
    if (P2_TSP_PLANE_RANGE != 1) begin : g_plane_range
      $fatal(1, "p2_hw_pkg: PlaneHW::range is %0d; the RTL implements 1", P2_TSP_PLANE_RANGE);
    end
    // PlaneHW experiments, hardware value 0 (num 3.3: not to be implemented)
    if (P2_TSP_PLANE_VALUE_FIXED != 0) begin : g_plane_value_fixed
      $fatal(1, "p2_hw_pkg: PlaneHW::valueFixed is %0d; the RTL implements 0", P2_TSP_PLANE_VALUE_FIXED);
    end
    if (P2_TSP_PLANE_TILE_LOCAL != 0) begin : g_plane_tile_local
      $fatal(1, "p2_hw_pkg: PlaneHW::tileLocal is %0d; the RTL implements 0", P2_TSP_PLANE_TILE_LOCAL);
    end
    if (P2_TSP_PLANE_MAC_ORDER != 0) begin : g_plane_mac_order
      $fatal(1, "p2_hw_pkg: PlaneHW::macOrder is %0d; the RTL implements 0", P2_TSP_PLANE_MAC_ORDER);
    end
    if (P2_TSP_PLANE_SUM_A != 0) begin : g_plane_sum_a
      $fatal(1, "p2_hw_pkg: PlaneHW::sumA is %0d; the RTL implements 0", P2_TSP_PLANE_SUM_A);
    end
    if (P2_TSP_PLANE_SUM_W != 0) begin : g_plane_sum_w
      $fatal(1, "p2_hw_pkg: PlaneHW::sumW is %0d; the RTL implements 0", P2_TSP_PLANE_SUM_W);
    end

    // ---- the shared formats of p2_pkg ----
    // p2_fp24_t: every setup product, sum and reciprocal of the edge, depth and TSP units
    if (P2_ISP_EDGE_PRODUCT_BITS != P2_FP24_MANT_BITS || P2_ISP_EDGE_SUM_BITS != P2_FP24_MANT_BITS ||
        P2_ISP_DEPTH_PRODUCT_BITS != P2_FP24_MANT_BITS || P2_ISP_DEPTH_SUM_BITS != P2_FP24_MANT_BITS ||
        P2_ISP_DEPTH_RECIP_BITS != P2_FP24_MANT_BITS || P2_ISP_DEPTH_COEF_BITS != P2_FP24_MANT_BITS ||
        P2_TSP_PLANE_PRODUCT_BITS != P2_FP24_MANT_BITS || P2_TSP_PLANE_SUM_BITS != P2_FP24_MANT_BITS ||
        P2_TSP_PLANE_RECIP_BITS != P2_FP24_MANT_BITS) begin : g_fp24
      $fatal(1, "p2_hw_pkg: the setup widths are no longer all %0d bits: p2_pkg's p2_fp24_t no longer serves them",
             P2_FP24_MANT_BITS);
    end
    // p2_fp20_t: the edge and depth starts and steps
    if (P2_ISP_EDGE_START_BITS != P2_FP20_MANT_BITS || P2_ISP_EDGE_SLOPE_BITS != P2_FP20_MANT_BITS ||
        P2_ISP_DEPTH_START_BITS != P2_FP20_MANT_BITS || P2_ISP_DEPTH_SLOPE_BITS != P2_FP20_MANT_BITS) begin : g_fp20
      $fatal(1, "p2_hw_pkg: the start and step widths are no longer all %0d bits: p2_pkg's p2_fp20_t no longer serves them",
             P2_FP20_MANT_BITS);
    end
    // p2_zword_pkg::from_fp / big take p2_fp20_t: the stored depth's bits must fit it
    if (P2_ISP_DEPTH_STORED_BITS > P2_FP20_MANT_BITS) begin : g_stored
      $fatal(1, "p2_hw_pkg: DepthHW::storedBits is %0d, wider than p2_fp20_t", P2_ISP_DEPTH_STORED_BITS);
    end
  endgenerate
`endif

endmodule

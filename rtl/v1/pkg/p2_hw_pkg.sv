// GENERATED: do not edit. tools/gen/gen_hw_pkg.cpp from the refcore *HW structs (nulldc3 refsw3/refcore:
// pvr_isp_edge.h, pvr_isp_depth.h, pvr_tsp_plane.h). Regenerate: make hw-pkg; check: make hw-pkg-check.
//
// The widths are refsw3's measured precisions (the evidence is at each member in refcore and in
// docs/spec/numerics.md section 3). The RTL takes its widths from this package and nowhere else.
// MODE members are switches of which the RTL implements one value: rtl/v1/pkg/p2_hw_check.sv fails
// elaboration if a value below is not that one (conventions.md section 5).
package p2_hw_pkg;

  // pvrisp::EdgeHW (pvr_isp_edge.h)
  localparam int P2_ISP_EDGE_PRODUCT_BITS        = 24;   // pvrisp::EdgeHW::productBits
  localparam int P2_ISP_EDGE_SUM_BITS            = 24;   // pvrisp::EdgeHW::sumBits
  localparam int P2_ISP_EDGE_REACH               = 25;   // pvrisp::EdgeHW::reach
  localparam int P2_ISP_EDGE_GUARD               = -1;   // pvrisp::EdgeHW::guard (MODE)
  localparam int P2_ISP_EDGE_START_BITS          = 20;   // pvrisp::EdgeHW::startBits
  localparam int P2_ISP_EDGE_SLOPE_BITS          = 20;   // pvrisp::EdgeHW::slopeBits
  localparam int P2_ISP_EDGE_PAIR_BITS           = 21;   // pvrisp::EdgeHW::pairBits
  localparam int P2_ISP_EDGE_BLOCK_ADD           = 6;    // pvrisp::EdgeHW::blockAdd
  localparam int P2_ISP_EDGE_START_ADD           = 1;    // pvrisp::EdgeHW::startAdd
  localparam int P2_ISP_EDGE_ZERO_SHIFT          = 21;   // pvrisp::EdgeHW::zeroShift
  localparam int P2_ISP_EDGE_TIE_SHIFT           = 21;   // pvrisp::EdgeHW::tieShift
  localparam int P2_ISP_EDGE_OVERFLOW_EXP        = 128;  // pvrisp::EdgeHW::overflowExp
  localparam int P2_ISP_EDGE_SATURATE_EXP        = 127;  // pvrisp::EdgeHW::saturateExp
  localparam int P2_ISP_EDGE_LAST_COLUMN_BY_STEP = 1;    // pvrisp::EdgeHW::lastColumnByStep (MODE)
  localparam int P2_ISP_EDGE_BLOCK_MAX           = 129;  // pvrisp::EdgeHW::blockMax
  localparam int P2_ISP_EDGE_WALK_EXP            = 131;  // pvrisp::EdgeHW::walkExp

  // pvrisp::DepthHW (pvr_isp_depth.h)
  localparam int P2_ISP_DEPTH_PRODUCT_BITS    = 24;   // pvrisp::DepthHW::productBits
  localparam int P2_ISP_DEPTH_SUM_BITS        = 24;   // pvrisp::DepthHW::sumBits
  localparam int P2_ISP_DEPTH_REACH           = 25;   // pvrisp::DepthHW::reach
  localparam int P2_ISP_DEPTH_RECIP_BITS      = 24;   // pvrisp::DepthHW::recipBits
  localparam int P2_ISP_DEPTH_COEF_BITS       = 24;   // pvrisp::DepthHW::coefBits
  localparam int P2_ISP_DEPTH_START_BITS      = 20;   // pvrisp::DepthHW::startBits
  localparam int P2_ISP_DEPTH_SLOPE_BITS      = 20;   // pvrisp::DepthHW::slopeBits
  localparam int P2_ISP_DEPTH_PAIR_BITS       = 21;   // pvrisp::DepthHW::pairBits
  localparam int P2_ISP_DEPTH_TILE_BITS       = 26;   // pvrisp::DepthHW::tileBits
  localparam int P2_ISP_DEPTH_STORED_BITS     = 19;   // pvrisp::DepthHW::storedBits
  localparam int P2_ISP_DEPTH_START_ON_SLOPES = 1;    // pvrisp::DepthHW::startOnSlopes (MODE)
  localparam int P2_ISP_DEPTH_RANGE           = 1;    // pvrisp::DepthHW::range (MODE)

  // pvrtsp::PlaneHW (pvr_tsp_plane.h)
  localparam int P2_TSP_PLANE_PRODUCT_BITS = 24;   // pvrtsp::PlaneHW::productBits
  localparam int P2_TSP_PLANE_SUM_BITS     = 24;   // pvrtsp::PlaneHW::sumBits
  localparam int P2_TSP_PLANE_REACH        = 25;   // pvrtsp::PlaneHW::reach
  localparam int P2_TSP_PLANE_RECIP_BITS   = 24;   // pvrtsp::PlaneHW::recipBits
  localparam int P2_TSP_PLANE_COEF_BITS    = 16;   // pvrtsp::PlaneHW::coefBits
  localparam int P2_TSP_PLANE_GRID_BITS    = 22;   // pvrtsp::PlaneHW::gridBits
  localparam int P2_TSP_PLANE_VALUE_BITS   = 16;   // pvrtsp::PlaneHW::valueBits
  localparam int P2_TSP_PLANE_VALUE_FIXED  = 0;    // pvrtsp::PlaneHW::valueFixed (MODE)
  localparam int P2_TSP_PLANE_RANGE        = 1;    // pvrtsp::PlaneHW::range (MODE)
  localparam int P2_TSP_PLANE_EXP_LOW      = -126; // pvrtsp::PlaneHW::expLow
  localparam int P2_TSP_PLANE_EXP_HIGH     = 127;  // pvrtsp::PlaneHW::expHigh
  localparam int P2_TSP_PLANE_ZERO_REACH   = 2;    // pvrtsp::PlaneHW::zeroReach
  localparam int P2_TSP_PLANE_TILE_LOCAL   = 0;    // pvrtsp::PlaneHW::tileLocal (MODE)
  localparam int P2_TSP_PLANE_MAC_ORDER    = 0;    // pvrtsp::PlaneHW::macOrder (MODE)
  localparam int P2_TSP_PLANE_SUM_A        = 0;    // pvrtsp::PlaneHW::sumA (MODE)
  localparam int P2_TSP_PLANE_SUM_W        = 0;    // pvrtsp::PlaneHW::sumW (MODE)

endpackage

// spg_mode.h - the raster geometry a testbench is running against, taken FROM THE
// RTL rather than restated as literals.
//
// WHY THIS EXISTS
//   spg_sync_tb, spg_bands_tb, spg_depth_tb and spg_loopback_tb each used to hardcode
//   the 1080p numbers (2200x1125, X0=320, Y0=60, ">> 1" for the 2x doubling). That is
//   invisible while spg.sv is 1080p and fatal the moment it is not: retargeting the
//   module to 480p turned all four red, and the failures said nothing about the RTL -
//   only that the testbenches had a mode baked in.
//
//   Verilator's --public-params exposes every parameter and localparam of the DUT as a
//   compile-time constant, so a testbench can read the module's OWN arithmetic - X0,
//   X1, Y0, Y1, H_TOTAL, V_TOTAL are the localparams spg.sv computed, not a copy of the
//   formula. Change spg.sv's mode and every testbench follows with no edit.
//
// USAGE
//   The parameters live on the generated root class under a hierarchical name, which
//   differs when spg is the top module versus instantiated inside a wrapper. The
//   including translation unit supplies that mapping and then includes this header:
//
//       #include "Vspg.h"
//       #include "Vspg___024root.h"
//       #define SPG_P(n) (Vspg___024root::spg__DOT__##n)
//       #include "spg_mode.h"
//
//   ...or, from inside a wrapper (see spg_loopback_tb.cpp):
//
//       #define SPG_P(n) (Vspg_loopback_top___024root::spg_loopback_top__DOT__u_spg__DOT__##n)
//
//   Build the model with --public-params or the symbols will not exist.
#ifndef SPG_MODE_H
#define SPG_MODE_H

#ifndef SPG_P
#  error "define SPG_P(name) to map a parameter name onto the generated root class"
#endif

#include <cstdio>

namespace spg_mode {

// ---- straight from the RTL -----------------------------------------------------
static const long H_ACTIVE = SPG_P(H_ACTIVE);
static const long H_FP     = SPG_P(H_FP);
static const long H_SYNC   = SPG_P(H_SYNC);
static const long H_BP     = SPG_P(H_BP);
static const long V_ACTIVE = SPG_P(V_ACTIVE);
static const long V_FP     = SPG_P(V_FP);
static const long V_SYNC   = SPG_P(V_SYNC);
static const long V_BP     = SPG_P(V_BP);
static const long SRC_W    = SPG_P(SRC_W);
static const long SRC_H    = SPG_P(SRC_H);
static const long SCALE    = SPG_P(SCALE);

// spg.sv's own derived localparams - deliberately read rather than recomputed here,
// so a testbench cannot disagree with the module about where the window is.
static const long H_TOTAL  = SPG_P(H_TOTAL);
static const long V_TOTAL  = SPG_P(V_TOTAL);
static const long X0       = SPG_P(X0);
static const long X1       = SPG_P(X1);
static const long Y0       = SPG_P(Y0);
static const long Y1       = SPG_P(Y1);

// ---- derived for the testbenches -----------------------------------------------

// Both axes scale by a right shift (spg.sv n_pre / vshift), so SCALE is always a
// power of two. Raster offset -> source index is a shift by SHIFT.
static const int SHIFT = (SCALE == 4) ? 2 : (SCALE == 2) ? 1 : 0;

// Clocks in one full frame. Also the natural unit for a run-away guard.
static const long FRAME_CLKS = H_TOTAL * V_TOTAL;

// Telling an inter-line de gap from an inter-frame one. A line gap is
// H_TOTAL-H_ACTIVE (138 at 480p, 280 at 1080p); a frame gap is at least
// (V_TOTAL-V_ACTIVE)*H_TOTAL, tens of thousands. Anything between separates them.
static const long VBLANK_GAP_MIN = 2 * H_TOTAL;

// Prefetch lookahead in OUTPUT lines (spg.sv y_look_raw = vcnt + this). It is 2 at
// SCALE=2 and 1 at SCALE=1 - at 1:1 a 2-line lookahead would be two SOURCE lines,
// landing in the buffer being scanned out. So the request for source line s is
// issued at output line Y0 - LOOKAHEAD + SCALE*s, which is what a per-line FB_R_SOF
// test needs in order to know which lines a mid-frame change should reach.
static const long LOOKAHEAD = (SCALE == 2) ? 2 : 1;
static long request_line(long src_line) { return Y0 - LOOKAHEAD + SCALE * src_line; }

// The border bands are 640x30 linear framebuffers doubled to fill the top and bottom
// margins, so they exist only when the window leaves a margin. At SCALE=1 a 480-line
// source fills a 480-line raster exactly: Y0 == 0, and the bands are structurally
// absent (spg.sv waives the resulting UNSIGNED warning for the same reason). A
// testbench whose subject is the bands has nothing to assert in that case.
static const bool HAS_BANDS = (Y0 > 0);
static const long BAND_SRC_H = HAS_BANDS ? (Y0 / SCALE) : 0;   // source lines per band
static const long BAND_STRIDE = SRC_W * 2;                     // 565, 2 bytes/px

// raster coordinate -> source index within the game window
static inline long src_x(long x) { return (x - X0) >> SHIFT; }
static inline long src_y(long y) { return (y - Y0) >> SHIFT; }

static inline void print_mode(const char* tb) {
    printf("%s: %ldx%ld raster (%ldx%ld total), %ldx%ld source at SCALE=%ld"
           " -> window x %ld..%ld, y %ld..%ld%s\n",
           tb, H_ACTIVE, V_ACTIVE, H_TOTAL, V_TOTAL, SRC_W, SRC_H, SCALE,
           X0, X1 - 1, Y0, Y1 - 1, HAS_BANDS ? "" : ", no border bands");
}

}  // namespace spg_mode

#endif  // SPG_MODE_H

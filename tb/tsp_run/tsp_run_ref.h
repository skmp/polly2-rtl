// tsp_run_ref.h: the TSP run testbench's view of the reference (PLAN M10). Plain C++: the Verilated testbench
// (tsp_run_tb.cpp) includes only this; tsp_run_ref.cpp, compiled with refsw3-offline's flags beside the L2 glue (tb/ref),
// implements it on the p2ref API: the entry is refsw3's own GetFpuEntry (p2ref::fpu_entry) for the tile, the values
// PlaneStepper3::Val (PlaneT::Value) with SpanStart and the SupSample statics as RenderParamTags / PixelFlush_tsp set them,
// the quotients PlaneStepper3::Quot (Divide), the colours refcore's InterpolateBase / InterpolateOffs, the level MipSelect
// (L1) and the copy of PixelFlush_tsp's mipChoose (p2ref::mip_choose, tb/tsp_run/ref_copies_run.h).
#pragma once
#include <cstdint>

namespace trref {

struct T { bool neg = false, bad = false; int exp = 0; uint64_t mant = 0; };   // pvrfp::Fp

// one point of a pixel as refsw3 shades it
struct Pt {
    bool super = false;         // the volume's TSP SupSample: the point is one of four
    bool tex = false, ofs = false, mip = false;   // U, V live; the offset planes live (Texture && Offset && not a bump
                                                  // map); the level live (Texture && TCW MipMapped)
    T val[11];                  // PlaneT::Value of invW, U, V, Col B G R A, Ofs B G R A of the volume
    T q[11];                    // q[0] Divide(1.0, W) as MipSelect has it (sign dropped); q[p] Divide(val[p], W)
    uint32_t base = 0, offs = 0;   // InterpolateBase, InterpolateOffs (ARGB8888)
    int rl = 0, rk = 0;         // MipSelect's level and k
    int level = 0, k = 0;       // mipChoose's level and dTri
};

void reset();                                           // p2ref::reset_core
uint8_t* vram();
void set_vram32(uint32_t addr, uint32_t w);
// the render's registers: PARAM_BASE, FPU_SHAD_SCALE, FPU_PERP_VAL, HALF_OFFSET (bit 1 the TSP's half pixel); then
// begin_render; the entries' cache is emptied
void set_regs(uint32_t paramBase, uint32_t shadScale, uint32_t perpVal, uint32_t halfOffset);
// the fog of pvr-tests/wmeas (table fog, every pair (0, 255), density 1.0, fog colour white, a black polygon): the
// green the console's framebuffer holds for a 1/w W (refcore's FogUnit through p2ref::fog)
void wmeas_regs();
int wmeas_green(const T& W);
// a point: the entry of tag (InVolume inVol) set up in the tile (left, top); the run's first column x0 on line y; pixel
// n of the run; a SupSample point (hx, hy) when the volume has SupSample (out->super), else the pixel
void point(uint32_t tag, int inVol, int left, int top, int x0, int y, int n, int hx, int hy, Pt* out);
// coverage (not a comparison): num H7b's class of plane p's half line hyd = F(Add(C', B'/2, 62, 400)) - F(C') in the tile:
// bit 0 the two floors' fractions carry (hyd != F(B'/2)), bit 1 the window (the exponents more than 90 apart: B'/2 adds
// nothing), bit 2 the exact sum is wider than 62 bits (the truncation), bit 3 C' < 0
int h7b(uint32_t tag, int inVol, int left, int top, int p);
// debugging (not a comparison): the evaluator's terms of plane p at the run's start, as PlaneT::Value has them
void terms(uint32_t tag, int inVol, int left, int top, int x0, int y, int p, char* out, int outN);

}   // namespace trref

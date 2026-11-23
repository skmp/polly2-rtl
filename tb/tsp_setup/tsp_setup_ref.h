// tsp_setup_ref.h: the TSP setup testbench's view of the reference (PLAN M9). Plain C++: the Verilated testbench
// (tsp_setup_tb.cpp) includes only this; tsp_setup_ref.cpp, compiled with refsw3-offline's flags beside the L2 glue
// (tb/ref), implements it on the p2ref API: the store entry of (tag, vsel) is refsw3's own GetFpuEntry
// (p2ref::fpu_entry: decode_pvr_vertices, IPs3::Setup, SetupIntensity) read back, and K the copies of MipSelect's K part
// (tb/tsp_setup/ref_copies_tsp.h) on that entry's planes.
#pragma once
#include <cstdint>

namespace tsref {

struct T { bool neg = false, bad = false; int exp = 0; uint64_t mant = 0; };   // pvrfp::Fp
struct Plane { T a, b, c; };
// one store entry as refsw3 has it, of the volume vsel (InVolume): PixelFlush_tsp reads Col[vsel], Ofs[vsel], and the
// second TSP / TCW / U / V when vsel && !intensity
struct Entry {
    uint32_t isp = 0, tsp = 0, tcw = 0;
    uint8_t colFb[4] = {}, ofsFb[4] = {};     // Col[vsel][i].fallback, Ofs[vsel][i].fallback
    Plane pl[11];                             // invW, U, V, Col B G R A, Ofs B G R A (p2_tsp_prog_pkg's P2_TSP_PL_*)
    // K (when textured and the TCW mipmapped): K8, dzForce; kOld: K8 with MIP_K 1 (the old model the mipk observations
    // are relative to: pvr-tests/mipk/kfit.cpp's base), as kfit's integer
    bool kHave = false, dz = false;
    T k8;
    int kOld = 0;
};

void reset();                                           // p2ref::reset_core
uint8_t* vram();                                        // emu_vram, 64-bit physical order
void set_vram32(uint32_t addr, uint32_t w);             // a word at a 32-bit-view address
// the render's registers: PARAM_BASE, FPU_SHAD_SCALE, FPU_PERP_VAL; then begin_render (FPU_PERP_VAL into pvrfp)
void set_regs(uint32_t paramBase, uint32_t shadScale, uint32_t perpVal);
// the entry of (tag, vsel): GetFpuEntry with its cache cleared first (the block may have been rewritten)
void entry(uint32_t tag, int vsel, Entry* out);

}   // namespace tsref

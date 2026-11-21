// isp_tile_ref.h: the ISP tile testbench's view of the reference (PLAN 1.3 "ISP tile testbench", M6). Plain C++: the
// Verilated testbench (isp_tile_tb.cpp, compiled with Verilator's flags) includes only this; isp_tile_ref.cpp, compiled
// with refsw3-offline's flags beside the L2 glue (tb/ref), implements it on the p2ref API and the M5 phase driver
// (tb/ref/phase_driver.cpp): the reference's phases are the driver's, the comparisons go through p2ref's state taps.
#pragma once
#include <cstdint>

namespace itref {

// a region array entry as RenderCORE read it (refcore RegionArrayEntry); lists in p2_pkg's order OP, OP_MOD, TR, TR_MOD, PT
struct Entry {
    int tilex, tiley;
    bool no_writeout, pre_sort, z_keep, last;
    uint32_t ptr[5];            // ptr_in_words
    bool empty[5];
};

// the fields of one pixel M6 compares (refcore depthBuffer[A] as StoredDepth::k, tagBuffer[A] all 32 bits,
// stencilBuffer, tagStatus.valid)
struct Pix {
    int64_t depth;
    uint32_t tag;
    uint8_t stencil;
    bool valid;
};

// the registers the ISP of M6 reads
struct Regs {
    uint32_t param_base, fpu_shad_scale, fpu_cull_val, fpu_perp_val, half_offset, bg_tag, bg_depth;
};

// the phase hook: tb/common/isp_live.h's Phase numbers (Z 0, OP 1, OP_MOD 2, OP_SHADE 3, ..., END 18)
typedef void (*Hook)(int phase, const Entry& e, void* user);

void reset_core();                          // p2ref::reset_core: a new refsw3-offline process's core
bool load_state(const char* dir);           // a capture's r<k>: vram.bin[.gz] + pvr_regs.bin
uint8_t* vram();                            // refcore's emu_vram, 64-bit physical order (the VRAM model reads it)
Regs regs();
void pixels(Pix* out);                      // the 1024 pixels, row major
// one render through the phase driver (p2drv::render), the hook after every phase; false: it did not end
bool render(Hook h, void* user, int maxPasses);

}   // namespace itref

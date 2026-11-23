// isp_tile_ref.h: the ISP tile testbench's view of the reference (PLAN 1.3 "ISP tile testbench", M6, M7). Plain C++:
// the Verilated testbench (isp_tile_tb.cpp, compiled with Verilator's flags) includes only this; isp_tile_ref.cpp,
// compiled with refsw3-offline's flags beside the L2 glue (tb/ref), implements it on the p2ref API and the M5 phase
// driver (tb/ref/phase_driver.cpp): the reference's phases are the driver's, the comparisons go through p2ref's state
// taps, the runs through refsw3's own SpanGen (p2ref::span_gen) and, for the pre-sorted passes refsw3 shades inside its
// walk, through refsw3's render log (its PASS / SPAN lines, which RenderParamTags writes for every pass).
#pragma once
#include <cstdint>
#include <vector>

namespace itref {

// a region array entry as RenderCORE read it (refcore RegionArrayEntry); lists in p2_pkg's order OP, OP_MOD, TR, TR_MOD, PT
struct Entry {
    int tilex, tiley;
    bool no_writeout, pre_sort, z_keep, last;
    uint32_t ptr[5];            // ptr_in_words
    bool empty[5];
};

// one pixel's ISP state (p2ref::IspPix: depths as StoredDepth::k, tags all 32 bits)
struct Pix {
    int64_t depth, depthB, depthC, resDepth, savedDepth;
    uint32_t tag, tagB, opTag, refTagC, resTag;
    uint8_t stencil;
    bool valid, rendered, everRendered;
    int resPass;
};

// a run of a SHADE pass (refsw3's Span, with the masks the RTL's run item carries: vmask stencil bit 0 of pixel x + i
// at bit i, pmask `rendered` in the punch-through passes and PT_MV, else 0)
struct Run {
    uint32_t tag;
    int y, x, len;
    uint32_t vmask, pmask;
};

// the registers the ISP reads
struct Regs {
    uint32_t param_base, fpu_shad_scale, fpu_cull_val, fpu_perp_val, half_offset, bg_tag, bg_depth, isp_feed_cfg;
    uint32_t span_sort_cfg;     // not the ISP's: the run-stream dump (--dump-runs) records it for M8's sorter gate
};

// the phase hook: tb/common/isp_live.h's Phase numbers (Z 0, OP 1, OP_MOD 2, OP_SHADE 3, ..., END 18)
typedef void (*Hook)(int phase, const Entry& e, void* user);

void reset_core();                          // p2ref::reset_core: a new refsw3-offline process's core
bool load_state(const char* dir);           // a capture's r<k>: vram.bin[.gz] + pvr_regs.bin
uint8_t* vram();                            // refcore's emu_vram, 64-bit physical order (the VRAM model reads it)
Regs regs();
void pixels(Pix* out);                      // the 1024 pixels, row major
int pt_pass();                              // PtPass
bool opinpt();                              // OpInPt
bool more();                                // MoreToDraw
uint32_t tile_pixels_shaded();
// the runs SpanGen<rm> cuts from the state now, with their masks; rm is refsw3's RenderMode
void spans(int rm, std::vector<Run>& out);
// the pre-sorted passes: begin() points refsw3's render log at a buffer; end() reads back every pass RenderParamTags
// logged since (PASS lines; SPAN lines in the order shaded, put back in raster order), the masks from the state now
// (the stencil does not change in a pre-sorted walk), and stops the log
void presort_begin();
void presort_end(std::vector<std::vector<Run>>& passes);
// one render through the phase driver (p2drv::render), the hook after every phase; false: it did not end
bool render(Hook h, void* user, int maxPasses);

}   // namespace itref

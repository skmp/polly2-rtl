// wout_ref.h: the reference of make wout (tb/wout/wout_tb.cpp, PLAN M12), with no refcore type in it (the Verilated side
// includes it). wout_ref.cpp (refsw3-offline's flags, the L2 glue) runs RenderCORE's frame from its verbatim copies
// (tb/ref/ref_copies.h section A, p2ref::copy::RenderFrame: core-put, core-prev, core-writeout, core-endframe) on a
// region array of entries whose ISP and TSP work is replaced by the testbench's tiles: each entry's phases put the
// entry's tile into buffer 1 (an entry that shades nothing leaves buffer 1 as it is) and set tilePixelsShaded.
#pragma once
#include <cstdint>
#include <vector>

namespace woref {

struct Ent {
    int tx = 0, ty = 0;
    bool zkeep = false, noWo = false, shaded = false, last = false;
    std::vector<uint32_t> tile;     // the shaded tile, B G R A words (empty when !shaded)
};
struct Frame {
    uint32_t fb_w_ctrl, fb_w_linestride, fb_w_sof1, fb_w_sof2, fb_x_clip, fb_y_clip, fb_r_ctrl, scaler_ctl, y_coeff;
    uint32_t region_base;           // the region array (already in the video memory given to run)
    uint32_t buf0[2][1024];         // buffers 1, 2 at the frame's start
    std::vector<Ent> ents;
};
// the region array's words for the frame's entries (6-word entries: control, five empty lists), at 32-bit-area address
// f.region_base, into a video memory image (64-bit physical order)
void write_region_array(const Frame& f, uint8_t* vram);
// the frame on a video memory image (64-bit physical order, 8 MB): vram in, vram out; the buffers and which store is
// buffer 1 at the end
void run(const Frame& f, uint8_t* vram, uint32_t bufEnd[2][1024], int* selEnd);

}   // namespace woref

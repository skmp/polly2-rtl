// tsp_tile_ref.h: the reference side of the TSP tile testbench (make tsp-tile, PLAN M11, 1.3 "TSP tile testbench"), with
// no libswirl / refcore type in it (the Verilated side includes it). tsp_tile_ref.cpp (compiled with refsw3-offline's
// flags beside the L2 glue) renders a capture's render through the M5 phase driver and records, for the RTL:
//   - every entry (its tile, which store is buffer 1 at its start) and, in order, every SHADE pass it has: the pass's
//     RenderMode and runs, in the order the TSP shades them (refsw3's SpanGen + SpanSort of the state before the pass,
//     the masks from that state: vmask = stencil bit 0, pmask = `rendered` in the punch-through modes); the pre-sorted
//     passes too (tb/tsp_tile/refcore_glue_lists_rpt.cpp routes the walk's RenderParamTags calls to the pass hook);
//   - every pixel the pass shades, in order, through the verbatim copies of RenderParamTags' loop and PixelFlush_tsp:
//     its index, run-only, the alpha test's outcome, and the tile-buffer write the TSP makes (buffer, value);
//   - after each pass: offsKept, tspAlphaStuck and a hash of both buffers (to prove the recorded writes are all of them);
//   - the buffers and offsKept at the render's start and end, and the 64-bit words the render's write-out changed (the
//     texture reads that meet them make a VRAM-race render, ARCHITECTURE 3.2.1); video memory after the render (M12).
#pragma once
#include <cstdint>
#include <vector>

namespace ttref {

struct Run {
    uint32_t tag;
    int y, x, len;
    uint32_t vmask, pmask;
};
struct Pix {
    uint16_t idx;
    bool ro, at, wr, wb2;       // run-only; the alpha test passed; the TSP writes; to buffer 2
    uint32_t w;                 // the word written
    uint32_t tsp;               // the volume's TSP word (the report)
};
struct Pass {
    int rm = 0;
    std::vector<Run> runs;
    size_t pix0 = 0, npix = 0;  // its pixels in Render::pix
    uint32_t offsKept = 0;      // after the pass
    bool stuck = false;
    uint64_t hash = 0;          // both buffers (buffer 1 then 2) after the pass
};
struct Entry {
    int tx = 0, ty = 0;
    int sel = 0;                // the reference's tile_buffer_sel at the entry's start
    bool zkeep = false, noWriteout = false, presort = false;
    std::vector<Pass> passes;
};
struct Regs {
    uint32_t param_base, fpu_shad_scale, fpu_perp_val, half_offset, text_control, pal_ram_ctrl;
    uint32_t fog_col_ram, fog_col_vert, fog_density, fog_clamp_max, fog_clamp_min, pt_alpha_ref, span_sort_cfg;
    // the write-out's (M12)
    uint32_t fb_w_ctrl, fb_w_linestride, fb_w_sof1, fb_w_sof2, fb_x_clip, fb_y_clip, fb_r_ctrl, scaler_ctl, y_coeff;
    uint32_t fog_table[128];
    uint32_t palette[1024];
};
struct Render {
    bool ended = false;         // p2drv::render returned true
    Regs regs;
    std::vector<Entry> ents;
    std::vector<Pix> pix;
    uint32_t buf0[2][1024];     // buffers 1, 2 at the start
    int sel0 = 0;
    uint32_t offsKept0 = 0;
    uint32_t bufEnd[2][1024];
    int selEnd = 0;
    uint32_t offsKeptEnd = 0;
    std::vector<uint8_t> vramPre;          // emu_vram before the render (64-bit physical order)
    std::vector<uint8_t> vramPost;         // ... and after it (M12: the write-out's result)
    std::vector<uint64_t> wrote;           // a bit per 64-bit word the render changed
    long changedWords = 0;
};

void reset_core();
bool load_state(const char* dir);
// renders the loaded state through the phase driver, recording into `out`; maxPasses as p2drv::Options
void render(Render& out, int maxPasses);
uint64_t hash_buffers(const uint32_t* b1, const uint32_t* b2);

}   // namespace ttref

// p2ref.h: the p2ref API (PLAN 1.1, conventions.md 7.3 L2): refsw3's core (nulldc3 refsw3/refcore) as calls a
// testbench can make one at a time. The functions are defined in tb/ref/refcore_glue.cpp, the translation unit that
// #includes refsw_lists.cpp and refsw_tile.cpp (every static of refcore is in scope there), and in
// tb/ref/refcore_env.cpp (the host environment refcore needs: pvr_regs, emu_vram, the loaders).
//
// L2 code: compiled with refsw3-offline's FLAGS / INC / DEF (parsed from $(NULLDC3)/refsw3-offline/build.sh by the
// Makefile, plus -DRenderCORE=RenderCORE_sw and -I$(REFCORE)), so that the numbers are refsw3-offline's.
//
// How the API maps onto the tree at refsw3 4f3efe15 (PLAN 1.1's list was written before; where they differ the tree
// is followed):
//   - one entry is begun with begin_entry() (RenderCORE's ClearFpuCache and tilePixelsShaded = 0);
//   - the punch-through phases are refcore's: pt_initial (PeelBuffersPTInitial), pt_begin(chunk size) (ptChunking on,
//     ptChunks 1), pt_chunk_start(c) (ptChunk = c; PeelBuffersPTChunk from the second chunk on), pt_pass_start(p)
//     (ClearMoreToDraw, PtPass, the chunk walk's counters), pt_final (ptChunking off, PeelBuffersPTFinal);
//     pt_chunks() is read after each chunk's passes (the walk counts the chunks, PtChunkTake);
//   - a SHADE pass is render_param_tags(rm): span_gen + span_sort + the VERBATIM copy of RenderParamTags' loop
//     (tb/ref/ref_copies.h, copy core-rpt-loop) calling the verbatim pieces of PixelFlush_tsp (copies core-tsp-*):
//     every pixel the driver shades goes through the copies, so the frames self-test proves them. render_param_tags_core
//     is refcore's own RenderParamTags<rm>;
//   - RM_TRANSLUCENT_PRESORT shades inside the walk (RenderTriangle calls RenderParamTags after every triangle): walk()
//     does what refcore does.
#pragma once

#include <cstdint>
#include "refcore/refsw_tile.h"

namespace p2ref {

using refcore::RenderMode;
using refcore::RegionArrayEntry;
using refcore::FpuEntry;
using refcore::PixPos;
using refcore::Color;
using refcore::taRECT;
typedef pvrisp::StoredDepth ZType;
typedef uint32_t u32;

// ---- environment (refcore_env.cpp) ----------------------------------------------------------------------------------
uint8_t* vram();                            // refcore::emu_vram: 64-bit physical order, VRAM_SIZE bytes
uint8_t* regs();                            // pvr_regs, the 8 KB register block
// vram.bin (32-bit-area order, as refsw3-offline's `save` writes it, mapped through pvr_map32) or the same gzipped
// (any file: zlib reads both); pvr_regs.bin (8 KB, or the 32 KB of older builds); false with a message on stderr
bool load_vram(const char* path);
bool load_regs(const char* path);
bool load_state(const char* dir);           // <dir>/vram.bin[.gz] + <dir>/pvr_regs.bin
bool save_vram(const char* path);           // 32-bit-area order, raw (.gz: gzipped)
uint32_t vram32(uint32_t addr);             // the word at a 32-bit-area address
void set_vram32(uint32_t addr, uint32_t w);

// ---- the core between renders (refcore_glue.cpp) --------------------------------------------------------------------
// every state of refcore that outlives a render, to what a new refsw3-offline process has: the tile buffers and which
// is which, offsKept, the ISP buffers, the FPU cache, the PT counters, MoreToDraw, OpInPt
void reset_core();
// RenderCORE_sw, refcore's own whole render (the glue's control: -DRenderCORE=RenderCORE_sw)
void render_core();

// ---- a render, as RenderCORE does it --------------------------------------------------------------------------------
void begin_render();                        // pvrfp::perpVal from FPU_PERP_VAL
uint32_t read_entry(uint32_t base, RegionArrayEntry* e);   // ReadRegionArrayEntry: the entry's size in bytes
void begin_entry();                         // ClearFpuCache(); tilePixelsShaded = 0
ZType bg_key();                             // the background key of ISP_BACKGND_D (tb/fp copy fp-bgkey)
uint32_t bg_tag();                          // ISP_BACKGND_T.full
// ISP phases
void clear_buffers(uint32_t bgtag, ZType bgkey);   // ClearBuffers(tag, key, 0)
void clear_status();                        // ClearParamStatusBuffer
void walk(RenderMode rm, uint32_t list_addr, const taRECT& r);     // RenderObjectList
bool list_has_prim(uint32_t list_addr);     // ObjectListHasPrimitive
void set_opinpt(bool v);
bool opinpt();
void pt_initial();
void pt_begin(int chunk_size);
int  pt_chunks();
void pt_chunk_start(int chunk);
void pt_pass_start(int pass);
void pt_final();
int  pt_pass();                             // PtPass
// the PT loop of RenderCORE as one call (tb/ref/ref_copies.h copy core-pt-loop: PeelBuffersPTInitial .. PeelBuffersPTFinal,
// shading with refcore's RenderParamTags); the phase driver's --ptcopy mode
void pt_phase_copy(RegionArrayEntry& entry, taRECT& rect);
void save_depth();
void restore_depth();
void peel(ZType k);                         // PeelBuffers(k, 0)
bool more();
void clear_more();
// SHADE
struct SpanRec { uint32_t tag; uint8_t y, x, len; };   // refcore's Span (a static type of refsw_tile.cpp)
int  span_gen(RenderMode rm, SpanRec* out);    // SpanGen<rm>: the tile's runs of this pass in raster order
int  span_sort(const SpanRec* s, int n, uint16_t* order);   // SpanSort (SPAN_SORT_CFG)
void render_param_tags(RenderMode rm, int left, int top);        // through the copies (above)
void render_param_tags_core(RenderMode rm, int left, int top);   // refcore's RenderParamTags<rm>
uint32_t tile_pixels_shaded();
// the TSP's pixel through the copies of PixelFlush_tsp (the hook a TSP testbench replaces: set_pixel_hook)
typedef bool (*PixelHook)(bool atest, const FpuEntry* e, PixPos p, uint32_t idx, const pvrfp::Fp& invW, bool inVol,
                          uint32_t tag);
bool pixel_flush_tsp(bool atest, const FpuEntry* e, PixPos p, uint32_t idx, const pvrfp::Fp& invW, bool inVol,
                     uint32_t tag);                       // the copies
bool pixel_flush_tsp_core(bool atest, const FpuEntry* e, PixPos p, uint32_t idx, const pvrfp::Fp& invW, bool inVol,
                          uint32_t tag);                  // refcore's PixelFlush_tsp
void set_pixel_hook(PixelHook h);           // null: pixel_flush_tsp (the copies)
const FpuEntry& fpu_entry(int left, int top, RenderMode rm, uint32_t tag);   // GetFpuEntry
// the TSP's pieces, through refcore's dispatch tables
Color texture_filter(refcore::TSP tsp, refcore::TCW tcw, const pvrfp::Fp& u, const pvrfp::Fp& v, uint32_t level);
Color combiner(bool texture, bool offset, int shadInstr, Color base, Color tex, Color offs);
Color bump(Color t, Color o);
Color fog(bool offset, bool colorClamp, int fogCtrl, Color c, const pvrfp::Fp& invW, uint8_t offsA);
bool blend(int srcSel, int dstSel, int srcInstr, int dstInstr, bool atest, uint32_t idx, Color c);
void next_tile_buffers();

// ---- state taps -----------------------------------------------------------------------------------------------------
// one pixel of the ISP's buffers (depths as refsw3's StoredDepth: the RTL compares .k; tags all 32 bits). Which field
// is live in which phase: tb/common/isp_live.h
struct IspPix {
    ZType depthA, depthB, depthC, resDepth, savedDepth;
    uint32_t tagA, tagB, opTag, refTagC, resTag;
    uint8_t stencil;
    bool valid, rendered, everRendered;
    int resPass;
};
IspPix isp_pixel(int idx);
void set_isp_pixel(int idx, const IspPix& p);
uint32_t color(int buffer, int idx);        // buffer 1: colorBuffer1 (being shaded), 2: colorBuffer2
Color offs_kept();
bool alpha_stuck();

// ---- checks of the copies no render reaches -------------------------------------------------------------------------
// PtChunkTake (copy core-pt-take) beside refcore's on n random calls: the number that differ (then reset_core)
long check_pt_take(uint64_t seed, long n);

}   // namespace p2ref

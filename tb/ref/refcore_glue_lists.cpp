// refcore_glue_lists.cpp: the L2 glue (PLAN 1.1, conventions.md 7.3), refsw_lists.cpp's half (refcore_glue.cpp has the
// other and says why there are two). The p2ref wrappers (tb/ref/p2ref.h) of the region array and the object list walk,
// RenderCORE's punch-through counters (PtChunkTake's statics) and RenderCORE_sw itself; tb/ref/ref_copies.h's section B1.
#include "refcore/refsw_lists.cpp"

#define P2REF_GLUE_LISTS
#include "ref_copies.h"

namespace refcore {
extern int PtPass;          // refsw_tile.cpp
void PeelBuffersPTChunk();
}

namespace p2ref {
using namespace refcore;

// the statics of refsw_lists.cpp, to what a new process has (p2ref::reset_core)
void reset_core_lists()
{
    ptChunking = false;
    ptChunk = ptChunkSize = ptChunkAt = ptChunkFill = ptChunks = 0;
    ptChunkPrevQuad = false;
    ptChunkCulled = 0;
}

void render_core() { RenderCORE(); }        // RenderCORE_sw
void begin_render() { copy::BeginRender(); }
uint32_t read_entry(uint32_t base, RegionArrayEntry* e) { return ReadRegionArrayEntry(base, e); }
void walk(RenderMode rm, uint32_t list_addr, const taRECT& r)
{
    taRECT rect = r;
    RenderObjectList(rm, list_addr, &rect);
}
bool list_has_prim(uint32_t list_addr) { return ObjectListHasPrimitive(list_addr); }
void pt_begin(int chunk_size)
{
    ptChunking = true;
    ptChunkSize = chunk_size;
    ptChunks = 1;
}
int pt_chunks() { return ptChunks; }
void pt_chunk_start(int chunk)
{
    ptChunk = chunk;
    if (chunk)
        PeelBuffersPTChunk();
}
void pt_pass_start(int pass)
{
    ClearMoreToDraw();
    refcore::PtPass = pass;
    ptChunkAt = 0;
    ptChunkFill = 0;
    ptChunkPrevQuad = false;
    ptChunkCulled = 0;
}
void pt_final()
{
    ptChunking = false;
    PeelBuffersPTFinal();
}
void pt_phase_copy(RegionArrayEntry& entry, taRECT& rect) { P2PtPhaseCopy(entry, rect); }

// ---- PtChunkTake: the copy against refcore's ------------------------------------------------------------------------
// n random calls (vertex counts 3 / 4, culled primitives in between, chunk sizes 0 .. 0x3ff and the chunk being
// peeled) on both; the number of calls whose answer or counters differ
long check_pt_take(uint64_t seed, long n)
{
    uint64_t s = seed * 0x9E3779B97F4A7C15ull + 1;
    auto rnd = [&](uint64_t k) { s ^= s >> 12; s ^= s << 25; s ^= s >> 27; return (s * 0x2545F4914F6CDD1Dull >> 11) % k; };
    long bad = 0;
    for (long i = 0; i < n; i++) {
        if (i % 64 == 0) {
            static const int sizes[] = { 0, 1, 2, 3, 4, 5, 6, 0x20, 0x23, 0x40, 0x3ff };
            ptChunkSize = copy_take::ptChunkSize = rnd(4) ? sizes[rnd(11)] : (int)rnd(0x400);
            ptChunk = copy_take::ptChunk = (int)rnd(4);
            ptChunkAt = copy_take::ptChunkAt = 0;
            ptChunkFill = copy_take::ptChunkFill = 0;
            ptChunkPrevQuad = copy_take::ptChunkPrevQuad = false;
            ptChunkCulled = copy_take::ptChunkCulled = 0;
            ptChunks = copy_take::ptChunks = 1;
        }
        if (rnd(5) == 0) {
            ptChunkCulled = copy_take::ptChunkCulled = 3;
            continue;
        }
        const int nv = rnd(3) ? 3 : 4;
        const bool a = PtChunkTake(nv), b = copy_take::PtChunkTake(nv);
        if (a != b || ptChunkAt != copy_take::ptChunkAt || ptChunkFill != copy_take::ptChunkFill ||
            ptChunks != copy_take::ptChunks || ptChunkPrevQuad != copy_take::ptChunkPrevQuad)
            bad++;
    }
    reset_core_lists();
    return bad;
}

}   // namespace p2ref

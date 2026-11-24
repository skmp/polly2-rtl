// tsp_unit_ref.h: the reference of make tsp-tile's unit sections (tb/tsp_tile/tsp_unit_tb.cpp), with no libswirl / refcore
// type in it. tsp_unit_ref.cpp (refsw3-offline's flags, beside the L2 glue) calls refsw3's TSP pieces through p2ref:
// TextureFilter through refcore's dispatch tables (p2ref::texture_filter), ColorCombiner (p2ref::combiner), BumpMapper
// (p2ref::bump), FogUnit (p2ref::fog), BlendingUnit (p2ref::blend), and the verbatim copies of PixelFlush_tsp's bumpLight,
// shade, fade and the SupSample average (tb/tsp_tile/ref_copies_tile.h through p2ref::*_copy). Numbers as their tuples
// (neg, exp, mant), colours as ARGB8888 words.
#pragma once
#include <cstdint>

namespace turef {

void init();                        // p2ref::reset_core
uint8_t* vram();                    // emu_vram (64-bit physical order)
void set_reg(uint32_t addr, uint32_t v);    // a register of the 8 KB block (PALETTE_RAM, FOG_TABLE included)
uint32_t texture_filter(uint32_t tsp, uint32_t tcw, bool uneg, int uexp, uint64_t umant, bool vneg, int vexp,
                        uint64_t vmant, uint32_t level);
uint32_t combiner(bool texture, bool offset, int shadInstr, uint32_t b, uint32_t t, uint32_t o);
uint32_t bump(uint32_t t, uint32_t o);
uint32_t bump_light(uint32_t ofsFallback);
uint32_t shade(uint32_t isp, uint32_t tsp, uint32_t tcw, uint32_t b, uint32_t t, uint32_t o);
uint32_t fog(bool offset, bool colorClamp, int fogCtrl, uint32_t c, bool wneg, int wexp, uint64_t wmant, uint8_t offsA);
uint32_t fade(uint32_t isp, uint32_t tsp, uint32_t tcw, uint32_t c, int k);
uint32_t super_avg(const uint32_t* c4);
// BlendingUnit at pixel idx with the buffers' words b1, b2 there: the alpha test's outcome, the words after (in b1, b2)
bool blend(int srcSel, int dstSel, int srcInstr, int dstInstr, bool atest, uint32_t idx, uint32_t col, uint32_t* b1,
           uint32_t* b2);

}   // namespace turef

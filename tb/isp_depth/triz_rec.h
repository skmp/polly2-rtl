// triz_rec.h: one record of build/vec/<test>.trz (PLAN M3 "the console pages' primitives with their depths"): a
// primitive as refsw3's RasterizeTriangle took it in one tile of a dreamcast-tests page, with what the depth setup
// reads: its first three corners' x, y, z exactly (the render log's TRIA line, `%a`; refsw_lists.cpp L143), HALF_OFFSET
// and FPU_PERP_VAL of that render, the tile. Written by tools/gate/tria_conv.cpp beside the edge records of
// tb/isp_edge/tri_rec.h (build/vec/<test>.tri, unchanged), read by tb/isp_depth/isp_depth_tb.cpp (section tria).
// VecFile magic kTriZMagic, fixed size. A quad's record is written too (its depth is its first three corners':
// refsw_tile.cpp L811-813; the TRIA line does not hold corner 4, so its coverage is not known here).
// The log prints a NaN without its payload ("nan", "-nan"): such a corner comes back as 0x7fc00000 / 0xffc00000, the
// same for the RTL and refsw3 (only the determinant-zero mean reads a NaN's fraction: isp 9.4b).
#pragma once
#include <cstdint>

namespace p2tri {

constexpr uint32_t kTriZMagic = 0x5A495254;    // "TRIZ"

struct TriZRec {
    uint32_t x[3], y[3], z[3];    // the first three corners' bits
    uint32_t isp;                 // ISP_TSP word
    uint32_t perpVal;             // FPU_PERP_VAL of the render
    uint32_t halfOffset;          // HALF_OFFSET of the render
    uint16_t render;              // the render's number in the test's stream (its page)
    uint8_t tileX, tileY;
    uint8_t quad;                 // a quad array's primitive
    uint8_t modvol;               // RM_MODIFIER (no depth is stored; the setup runs all the same)
    uint8_t pad[2];
};
static_assert(sizeof(TriZRec) == 56, "TriZRec layout");

}   // namespace p2tri

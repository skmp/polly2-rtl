// tri_rec.h: one record of build/vec/<test>.tri (PLAN 1.2 "triangles from console pages"): a primitive as refsw3's
// RasterizeTriangle took it in one tile of a dreamcast-tests page, its corners exactly (the render log's TRIA line,
// `%a`), with what the edge setup reads besides: the ISP word (CullMode), the render mode's class (MODIFIER or not),
// the tile, HALF_OFFSET and FPU_CULL_VAL of that render. Written by tools/gate/tria_conv.cpp, read by
// tb/isp_edge/isp_edge_tb.cpp (section tria). VecFile magic kTriMagic, fixed size.
#pragma once
#include <cstdint>

namespace p2tri {

constexpr uint32_t kTriMagic = 0x41495254;     // "TRIA"

struct TriRec {
    uint32_t x[4], y[4];          // the corners' bits; [3] for a quad only
    uint32_t isp;                 // ISP_TSP word (CullMode 28:27)
    uint32_t cullVal;             // FPU_CULL_VAL of the render
    uint32_t halfOffset;          // HALF_OFFSET of the render
    uint16_t render;              // the render's number in the test's stream (its page)
    uint8_t tileX, tileY;
    uint8_t quad;                 // a quad array's primitive (corner 4 from the QARR line: see tria_conv.cpp)
    uint8_t modvol;               // RM_MODIFIER: no row range
    uint8_t pad[2];
};
static_assert(sizeof(TriRec) == 52, "TriRec layout");

}   // namespace p2tri

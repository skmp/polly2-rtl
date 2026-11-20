// ref_copies_edge.h: the refcore code of the ISP edge path that no wrapper reaches, copied VERBATIM (PLAN 1.1 "copies",
// M2; the marker format is tb/ref/ref_copies.h's; tools/check_ref_copies.sh re-extracts every copy and fails on drift):
//
//   edge-cull     refsw_tile.cpp CulledBySize, CulledByFacing (static)
//   edge-setup    refsw_tile.cpp RasterizeTriangle: the winding, the bad corners, the cull, the four EdgeTile::Setup
//   edge-rows     refsw_tile.cpp RasterizeTriangle: RowRange, the row-31 shift, SetFirstRow
//
// Around them, ours: the few types and globals the copies read (Vertex: the corners' bits; DrawParameters: CullMode;
// taRECT: the tile; HALF_OFFSET; FPU_CULL_VAL through PvrReg; RENDLOG, which records "CULLED"), and p2edgeref::Setup,
// RasterizeTriangle's setup as one function: its EdgeTile values, its row range and how it ended. L1 headers only.
#pragma once
#include <cstdint>
#include "pvr_isp_edge.h"

namespace p2edgeref {

typedef uint32_t u32;
enum RenderModeRef { RM_OPAQUE = 0, RM_PUNCHTHROUGH_PASS0, RM_PUNCHTHROUGH_PASSN, RM_PUNCHTHROUGH_MV,
                     RM_TRANSLUCENT_AUTOSORT, RM_TRANSLUCENT_PRESORT, RM_MODIFIER };
struct Vertex { u32 x = 0, y = 0; };
struct IspWordRef { u32 CullMode = 0; };
struct DrawParameters { IspWordRef isp; };
struct taRECT { int left = 0, top = 0; };
struct HalfOffsetRef { u32 fpu_pixel_half_offset = 1; };
inline HalfOffsetRef HALF_OFFSET;
inline u32 fpuCullVal = 0;
#define FPU_CULL_VAL_addr 0
#define PvrReg(addr, type) ((type)p2edgeref::fpuCullVal)

// how RasterizeTriangle's setup ended, and what it made
struct Result {
    bool culled = false;          // RENDLOG("CULLED")
    bool reached = false;         // past the setup (neither a bad corner nor culled)
    pvrisp::EdgeTile E[4];
    int64_t rowFirst = INT64_MIN, rowLast = INT64_MAX;
};
inline Result* result = nullptr;
#define RENDLOG(...) (p2edgeref::result->culled = true)

// P2REF-COPY edge-cull refsw_tile.cpp // The ISP's cull by size: |det| <= |FPU_CULL_VAL|
// The ISP's cull by size: |det| <= |FPU_CULL_VAL|, the determinant as the setup has it (pvrisp::Winding). Equal is
// culled (dreamcast-tests/pvr-tests/raster page 4: legs of 1 pixel with the threshold at 1.0, cullval: every
// determinant of 1/4 .. 192 at 0.5, 1 and 2). The register's sign does not count, and an infinity or any NaN culls
// every triangle (dreamcast-tests/pvr-tests/cullval: -1, -2, -0.5, -0 render as 1, 2, 0.5, +0; -inf, NaN, -NaN and a
// signalling NaN as +inf; 2^-149 culls nothing, 16 of 16 pages). An infinite determinant draws nothing anyway.
static bool CulledBySize(const pvrfp::Fp& det)
{
    using pvrfp::Fp;
    if (det.bad)
        return false;
    const u32 size = PvrReg(FPU_CULL_VAL_addr, u32) & 0x7fffffff;
    if (size >= 0x7f800000)
        return true;
    return pvrfp::AbsAtMost(det, Fp::FromBits(size));
}

// The ISP's cull by facing (CullMode 2, 3): a determinant below zero (-0 is not) or above zero
static bool CulledByFacing(u32 cullMode, const pvrfp::Fp& det)
{
    if (cullMode < 2 || det.bad || det.zero())
        return false;
    return (cullMode & 1) ? !det.neg : det.neg;
}
// P2REF-END edge-cull

// RasterizeTriangle's setup (refsw_tile.cpp L770-847), render_mode a run-time value here
inline void Setup(int render_mode, DrawParameters* params, const Vertex& v1, const Vertex& v2, const Vertex& v3,
                  const Vertex* v4, taRECT* area, Result* out)
{
    *out = Result();
    result = out;                 // RENDLOG("CULLED") marks it; a bad corner returns with neither mark
    pvrisp::EdgeTile* const keep = out->E;
// P2REF-COPY edge-setup refsw_tile.cpp // The winding, the area for culling and the inside test are computed
    // The winding, the area for culling and the inside test are computed in the setup units' own arithmetic
    // (pvr_isp_edge.h on pvr_softfp.h; every rule measured on a console with dreamcast-tests/pvr-tests/covmeas and
    // dreamcast-tests/pvr-tests/hugepos). The same code is the model the probes of dreamcast-tests/model run.
    static const pvrisp::EdgeHW edgeConfig;          // the hardware's numbers, baked in (pvr_isp_edge.h)
    using pvrfp::Fp;
    const Fp FX[4] = { Fp::FromBits(v1.x), Fp::FromBits(v2.x), Fp::FromBits(v3.x), v4 ? Fp::FromBits(v4->x) : Fp() };
    const Fp FY[4] = { Fp::FromBits(v1.y), Fp::FromBits(v2.y), Fp::FromBits(v3.y), v4 ? Fp::FromBits(v4->y) : Fp() };
    bool badCorner = false;
    Fp det;
    // -1 when the determinant is positive or zero (a zero counts as positive: covmeas, mix sliver); the determinant the
    // edges are turned by and the culling tests is the one with the setup's overflowing products swamping the rest
    // (pvrisp::EdgeWinding; dreamcast-tests/pvr-tests/faredge_m131, faredge_cull)
    pvrisp::Winding(FX, FY, edgeConfig, &badCorner);
    const int sgn = pvrisp::EdgeWinding(FX, FY, edgeConfig, &det);
    // an infinity or a NaN among the corners: a console draws nothing (dreamcast-tests/pvr-tests/huge)
    if (badCorner || FX[3].bad || FY[3].bad)
        return;
    // cull: det is twice the area as the setup has it; corners at 2^100 are fine here (dreamcast-tests/pvr-tests/huge,
    // dreamcast-tests/pvr-tests/hugepos)
    if (params->isp.CullMode != 0 && (CulledBySize(det) || CulledByFacing(params->isp.CullMode, det))) {
        RENDLOG("CULLED");
        return;
    }

    // The ISP evaluates an edge per tile: a start value at the first sample point and whole steps, and it
    // decides rows and tie pixels in its own way (pvrisp::EdgeTile). The edges are turned to one winding
    // (sgn): hardware draws clockwise and counter-clockwise triangles alike.
    const int64_t halfBit = HALF_OFFSET.fpu_pixel_half_offset ? 1 : 0;
    const int64_t x0h = 2 * (int64_t)area->left + halfBit, y0h = 2 * (int64_t)area->top + halfBit;
    const int last = v4 ? 3 : 0;                                // where the third edge ends
    pvrisp::EdgeTile E12, E23, E31, E41;
    E12.Setup(FX[0], FY[0], FX[1], FY[1], x0h, y0h, sgn, edgeConfig);
    E23.Setup(FX[1], FY[1], FX[2], FY[2], x0h, y0h, sgn, edgeConfig);
    E31.Setup(FX[2], FY[2], FX[last], FY[last], x0h, y0h, sgn, edgeConfig);
    if (v4)
        E41.Setup(FX[3], FY[3], FX[0], FY[0], x0h, y0h, sgn, edgeConfig);
// P2REF-END edge-setup
// P2REF-COPY edge-rows refsw_tile.cpp int64_t rowFirst = INT64_MIN, rowLast = INT64_MAX;
    int64_t rowFirst = INT64_MIN, rowLast = INT64_MAX;
    if (render_mode != RM_MODIFIER) {
        pvrisp::RowRange(FY, v4 ? 4 : 3, &rowFirst, &rowLast);
        // A polygon whose first row is the tile's last (31) starts a row earlier in that tile, the walk of its edges as
        // well (dreamcast-tests/pvr-tests/faredge_walk pages 0-3: slivers to a far corner whose top corner is in row
        // 28 .. 31 of the tile; their pushed edges draw in the row above the top corner when the row range lets them:
        // with the plain range 366 of the test's 3,537 tiles wrong, with this 0; rows 30 and 31 both a row earlier 272,
        // a top corner in the last quarter of its row 892; held out, faredge_far32: 390, 0, 36, 440; faredge_m131 page 6
        // tile (17,8), page 11 tile (2,10), faredge_ecap page 9 tile (7,7): row 30 drawn). Every polygon, not only one
        // with an edge whose block exponent was cut: dreamcast-tests/pvr-tests/edge2_walk page 6 (points, three equal
        // corners, whose edges are inside everywhere, and triangles of corners 1/1024 apart, at y = row + 0, 1/4, 1/2,
        // 3/4, 1023/1024 of rows 28 .. 31 of their tile): with the top corner in row 31 rows 30 and 31 are filled (25
        // points, 18 tiny triangles: 43 tiles wrong with the rule for cut edges only, 0 with it for every polygon); in
        // rows 28 .. 30 none starts earlier (225 tiles). The user tile clip has no part in it: dreamcast-tests/pvr-tests/
        // edge2_row31 (300 of 300 tiles; the same probes drawn with no user tile clip, with the clip of their own tile
        // and with one of the 3x3 tiles around it: in each, the 13 points with the top corner in row 31 fill rows 30
        // and 31 and 9, 9, 10 of the 12 tiny triangles there draw in row 30; none of the 75 in rows 28 .. 30 starts
        // earlier). Why row 31 is not known.
        if (rowFirst - (int64_t)area->top == 31)
            rowFirst--;
        // the walk down the tile of an edge with a cut block exponent begins at the polygon's first row (EdgeTile::Walk)
        const int64_t first = rowFirst - (int64_t)area->top;
        E12.SetFirstRow(first);
        E23.SetFirstRow(first);
        E31.SetFirstRow(first);
        if (v4)
            E41.SetFirstRow(first);
    }
// P2REF-END edge-rows
    keep[0] = E12;
    keep[1] = E23;
    keep[2] = E31;
    keep[3] = E41;
    out->rowFirst = rowFirst;
    out->rowLast = rowLast;
    out->reached = true;
    (void)det;
    (void)sgn;
}

#undef RENDLOG
#undef PvrReg
#undef FPU_CULL_VAL_addr

}   // namespace p2edgeref

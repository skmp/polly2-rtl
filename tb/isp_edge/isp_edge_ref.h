// isp_edge_ref.h: the reference side of tb/isp_edge (PLAN M2): refsw3's RasterizeTriangle setup (the verbatim copies of
// ref_copies_edge.h) and EdgeTile::Inside for a setup job; refsw3's EdgeTile with a descriptor's values and its own
// Walk() for a raster-only job; the comparison of every field; the width claims of isp 8.5 on refsw3's values.
#pragma once
#include <cmath>
#include <cstdint>
#include <cstring>

#include "isp_edge_dut.h"
#include "ref_copies_edge.h"

namespace edgetb {

using pvrfp::Fp;

struct Ref {
    p2edgeref::Result r;
    bool bad = false;
    Fp det;
    int sgn = -1;
    int nEdges = 3;
    uint32_t rows = 0;             // bit j: row j is rasterized
    uint32_t mask[32] = {};
};

static inline int64_t iabs64(int64_t v) { return v < 0 ? -v : v; }
static inline int bitlen(uint64_t v) { return v ? 64 - __builtin_clzll(v) : 0; }

inline void RefSetup(const Job& j, Ref& f)
{
    p2edgeref::HALF_OFFSET.fpu_pixel_half_offset = j.half;
    p2edgeref::fpuCullVal = j.cullVal;
    p2edgeref::Vertex v[4];
    for (int k = 0; k < 4; k++) {
        v[k].x = j.x[k];
        v[k].y = j.y[k];
    }
    p2edgeref::DrawParameters p;
    p.isp.CullMode = j.cull;
    p2edgeref::taRECT a;
    a.left = 32 * j.tileX;
    a.top = 32 * j.tileY;
    p2edgeref::Setup(j.modvol ? p2edgeref::RM_MODIFIER : p2edgeref::RM_OPAQUE, &p, v[0], v[1], v[2],
                     j.quad ? &v[3] : nullptr, &a, &f.r);
    f.bad = !f.r.reached && !f.r.culled;
    static const pvrisp::EdgeHW cfg;
    const Fp FX[4] = {Fp::FromBits(j.x[0]), Fp::FromBits(j.x[1]), Fp::FromBits(j.x[2]), j.quad ? Fp::FromBits(j.x[3]) : Fp()};
    const Fp FY[4] = {Fp::FromBits(j.y[0]), Fp::FromBits(j.y[1]), Fp::FromBits(j.y[2]), j.quad ? Fp::FromBits(j.y[3]) : Fp()};
    f.sgn = pvrisp::EdgeWinding(FX, FY, cfg, &f.det);
    f.nEdges = j.quad ? 4 : 3;
    f.rows = 0;
    if (!f.r.reached)
        return;
    for (int y = 0; y < 32; y++) {
        const int64_t Y = (int64_t)a.top + y;
        if (Y < f.r.rowFirst || Y > f.r.rowLast)
            continue;
        f.rows |= 1u << y;
        uint32_t m = 0;
        for (int x = 0; x < 32; x++) {
            bool in = true;
            for (int k = 0; k < f.nEdges && in; k++)
                in = f.r.E[k].Inside(x, y);
            if (in)
                m |= 1u << x;
        }
        f.mask[y] = m;
    }
}

// refsw3's EdgeTile holding a descriptor's values, walked by its own Walk() from row jf
inline pvrisp::EdgeTile TileOf(const EdgeOut& e, int jf)
{
    pvrisp::EdgeTile t;
    t.constant = e.cv;
    t.constantInside = e.ci;
    t.lastColumnByStep = true;
    t.t0 = e.t0;
    t.tx = e.tx;
    t.ty = e.ty;
    t.zero2 = (int64_t)1 << e.zsh;
    t.tie2 = t.zero2 << (pvrisp::EdgeHW::zeroShift - pvrisp::EdgeHW::tieShift);
    t.big = !e.cv && e.big;
    t.firstRow = jf;
    if (t.big) {
        t.f0 = e.t0;
        t.fx = e.tx;
        t.fy = e.ty;
        t.h = (int64_t)1 << 30;
        t.z = t.zero2;
        t.Walk();
    }
    return t;
}

inline void RefRaster(const Job& j, Ref& f)
{
    pvrisp::EdgeTile t[4];
    for (int k = 0; k < 4; k++)
        t[k] = TileOf(j.de[k], j.djf);
    f.rows = 0;
    if (!j.drowsV)
        return;
    for (int y = j.djf; y <= j.djl; y++) {
        f.rows |= 1u << y;
        uint32_t m = 0;
        for (int x = 0; x < 32; x++) {
            bool in = !j.kill;
            for (int k = 0; k < 4 && in; k++)
                in = t[k].Inside(x, y);
            if (in)
                m |= 1u << x;
        }
        f.mask[y] = m;
    }
}

// the width claims (PLAN M2 gate item 5; isp 8.5), on refsw3's values
struct Widths {
    long ordEdges = 0, bigEdges = 0, constD30 = 0, walks = 0;
    int dMinOrd = 99, dMaxOrd = -99;
    int64_t maxOrd = 0, maxT0Big = 0, maxStepBig = 0, maxStepOrd = 0, maxT0Ord = 0, maxWalk = 0, maxFar = 0;
};

inline int DOf(const pvrisp::EdgeTile& e) { return bitlen((uint64_t)e.zero2) - 1 + pvrisp::EdgeHW::zeroShift - 1; }

// the walk of isp 8.4b on refsw3's fields, every value it forms measured (isp 8.5: below 2^33)
inline int64_t WalkMax(const pvrisp::EdgeTile& e, int s)
{
    const int64_t H = e.h, Z = e.z;
    int64_t mx = 0;
    auto see = [&](int64_t v) { if (iabs64(v) > mx) mx = iabs64(v); };
    auto wrap = [&](int64_t v) { int64_t w = v % (2 * H); if (w >= H) w -= 2 * H; else if (w < -H) w += 2 * H; return w; };
    const int64_t far32 = e.fx > 0 ? (32 * e.fx) % H : (e.fx < 0 && (-32 * e.fx) % H == 0) ? H : 0;
    auto rowVals = [&](int64_t r) { for (int i = 0; i <= 32; i++) see(r + e.fx * i); };
    bool dead = false, wasAbove = false;
    for (int j = s; j < 32 && !dead; j++) {
        const int64_t r = e.f0 + e.fy * j, rw = wrap(r);
        see(r);
        see(rw);
        see(rw + far32);
        const bool above = rw + far32 > Z;
        const bool ends = j > s && wasAbove && !above;
        wasAbove = above;
        if (rw == r)
            rowVals(r);
        if (!(rw >= -Z && rw <= Z) && !(e.fx == 0 || (rw > 0) == (e.fx > 0))) {
            const int64_t mid = rw + 16 * e.fx;
            see(mid);
            if (mid >= H || mid < -H)
                rowVals(rw + (rw > 0 ? 2 * H : -2 * H));
            else
                rowVals(rw);
        }
        if (ends)
            dead = true;
    }
    return mx;
}

}   // namespace edgetb

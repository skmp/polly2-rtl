// isp_depth_ref.h: the reference side of tb/isp_depth (PLAN M3): refsw3's DepthTileT<DepthHW>::Setup / At and
// StoredDepth (L1), the plane through the verbatim copy of ref_copies_depth.h; the descriptor refsw3's values give in
// the RTL's form (ARCHITECTURE 2.4 p2_ztile_t: the G form of isp 9.4a); the coverage of a pixel (pvr_isp_edge.h, as
// RasterizeTriangle has it) for the reports of item 5.
#pragma once
#include <cmath>
#include <cstdint>
#include <cstring>

#include "isp_depth_dut.h"
#include "pvr_isp_edge.h"
#include "ref_copies_depth.h"

namespace depthtb {

using pvrfp::Fp;
using pvrfp::i128;
using pvrfp::u128;
typedef pvrisp::DepthTileT<pvrisp::DepthHW> DepthHWTile;

static inline uint32_t fb(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline float fl(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static inline int64_t iabs64(int64_t v) { return v < 0 ? -v : v; }
static inline int bitlen128(u128 m) { return (uint64_t)(m >> 64) ? 64 + Fp::Bits((uint64_t)(m >> 64)) : Fp::Bits((uint64_t)m); }

struct Ref {
    DepthHWTile Z;
    p2depthref::PlaneOut pl;
    ZDesc d;
    bool floatForm = false;       // refsw3 valid && !block && ovf != 2: the float form (unreachable: isp 9.4a)
    bool offGrid = false;         // d0, dx, dy not on G
    bool startZero = false;       // BLOCK: d0 == 0 (the start cut to zero, or zero)
    int unit = 0;
};

inline void RefSetup(const Job& j, Ref& r)
{
    static const pvrisp::DepthHW cfg;
    pvrfp::perpVal = Fp::FromBits(j.perp & 0x7fffffffu);
    r.Z.Setup(j.x, j.y, j.z, 32 * j.tileX, 32 * j.tileY, cfg, j.half);
    r.pl = p2depthref::Plane(j.x, j.y, j.z, cfg);
    const DepthHWTile& Z = r.Z;
    ZDesc& d = r.d;
    d = ZDesc();
    if (Z.ovf == 2) {
        d.regime = Z_REG;
        d.r0 = Z.r0;
        d.sa = Z.sa;
        d.sb = Z.sb;
        d.fa = Z.fa;
        d.fb = Z.fb;
        return;
    }
    if (!Z.valid) {
        d.regime = Z_CONST;
        d.key = Z.first_z.k;
        return;
    }
    if (!Z.block) {
        r.floatForm = true;
        d.regime = Z_BLOCK;
        return;
    }
    d.regime = Z_BLOCK;
    const bool pairV = !Z.A.zero() || !Z.B.zero();
    const int pair = !pairV ? 0 : Z.A.zero() ? Z.B.top() : Z.B.zero() ? Z.A.top() : std::max(Z.A.top(), Z.B.top());
    const int e = Z.unit + 26;
    const int gx = (pairV && pair + 5 > e) ? pair + 5 : e;
    d.gexp = gx - 26;
    r.unit = Z.unit;
    const int g = d.gexp - Z.unit;
    if (g < 0 || g > 100) {
        r.offGrid = true;
        return;
    }
    const i128 G = (i128)1 << g;
    auto onGrid = [&](i128 v) { return v - (v / G) * G == 0; };
    if (!onGrid(Z.d0) || !onGrid(Z.dx) || !onGrid(Z.dy) || (Z.d0 / G) % 2 != 0) {
        r.offGrid = true;
        return;
    }
    d.S = (int64_t)(Z.d0 / G);
    d.DX = (int64_t)(Z.dx / G);
    d.DY = (int64_t)(Z.dy / G);
    d.E = Z.E;
    d.nsh = Z.E - 15 - d.gexp;
    r.startZero = Z.d0 == 0;
    d.fbw = r.startZero && d.nsh < 0;
}

// the pixels of the tile the primitive covers, row by row (pvr_isp_edge.h as RasterizeTriangle has it at 4f3efe15: the
// swamped winding, the row range with the row-31 shift; no cull); a triangle
inline void CoverMask(const uint32_t x[3], const uint32_t y[3], int left, int top, bool half, bool modvol, uint32_t m[32])
{
    static const pvrisp::EdgeHW ec;
    for (int j = 0; j < 32; j++)
        m[j] = 0;
    const Fp FX[3] = {Fp::FromBits(x[0]), Fp::FromBits(x[1]), Fp::FromBits(x[2])};
    const Fp FY[3] = {Fp::FromBits(y[0]), Fp::FromBits(y[1]), Fp::FromBits(y[2])};
    bool bad = false;
    Fp det;
    pvrisp::Winding(FX, FY, ec, &bad);
    const int sgn = pvrisp::EdgeWinding(FX, FY, ec, &det);
    if (bad)
        return;
    const int64_t hb = half ? 1 : 0, x0h = 2 * (int64_t)left + hb, y0h = 2 * (int64_t)top + hb;
    pvrisp::EdgeTile E[3];
    for (int k = 0; k < 3; k++)
        E[k].Setup(FX[k], FY[k], FX[(k + 1) % 3], FY[(k + 1) % 3], x0h, y0h, sgn, ec);
    int64_t rf = INT64_MIN, rl = INT64_MAX;
    if (!modvol) {
        pvrisp::RowRange(FY, 3, &rf, &rl);
        if (rf - top == 31)
            rf--;
        for (int k = 0; k < 3; k++)
            E[k].SetFirstRow(rf - top);
    }
    for (int j = 0; j < 32; j++) {
        if (top + j < rf || top + j > rl)
            continue;
        for (int i = 0; i < 32; i++)
            if (E[0].Inside(i, j) && E[1].Inside(i, j) && E[2].Inside(i, j))
                m[j] |= 1u << i;
    }
}

// the key of a lane value as the spec writes it (isp 9.6, the G form; RegDepth for REG): the reference of the
// raster-only descriptors (rdesc), which no setup made
inline int64_t LaneKey(const ZDesc& d, int i, int j)
{
    using pvrisp::StoredDepth;
    if (d.regime == Z_REG)
        return DepthHWTile::RegDepth(d.r0 + (int64_t)(d.sa * i + d.sb * j) * ((int64_t)1 << 25) + i * d.fa + j * d.fb).k;
    if (d.regime != Z_BLOCK)
        return d.key;
    const int64_t t = d.S + 2 * (int64_t)i * d.DX + 2 * (int64_t)j * d.DY;
    if (t >= 0) {
        Fp v;
        v.mant = (uint64_t)t;
        v.exp = d.gexp - 1;
        const Fp s = v.cut(19);
        if (!s.zero() && s.top() - 1 >= 128)
            return StoredDepth::Big(s).k;
        return StoredDepth::FromFp(s).k;
    }
    if (d.fbw)
        return StoredDepth::Bits(0x80000000u | (uint32_t)(d.E + 126) << 23).k;
    const int64_t M = d.nsh >= 0 ? (t >> d.nsh) : (int64_t)((i128)t << -d.nsh);
    return StoredDepth::Neg(d.E, M < -((int64_t)1 << 40) ? -((int64_t)1 << 40) : M).k;
}

}   // namespace depthtb

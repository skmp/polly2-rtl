// ref_copies_depth.h: the refcore code of the ISP depth path that no wrapper reaches, copied VERBATIM (PLAN 1.1
// "copies", M3; the marker format is tb/ref/ref_copies.h's; tools/check_ref_copies.sh re-extracts every copy and fails on
// drift):
//
//   depth-plane   pvr_isp_depth.h DepthTileT::Setup L343-426 at refsw3 4f3efe15: the inputs, the ranged operations
//                 (limit, mul, addRule, add, subC, addE), the edges, a, b, c and the determinant with Perpendicular
//
// DepthTileT keeps none of these (they are locals of Setup); its own Setup, At and StoredDepth are the reference of
// every key (L1). Around the copy, ours: p2depthref::Plane, the copy as a function of the corners and the
// configuration, returning a, b, c and det for the testbench's plane-level comparison (where a key differs, the first
// value that does says where). L1 headers only.
#pragma once
#include <cstdint>
#include "pvr_isp_depth.h"

namespace p2depthref {

struct PlaneOut { pvrfp::Fp a, b, c, det, e1, e2, e3; };

template<class Cfg>
inline PlaneOut Plane(const uint32_t x[3], const uint32_t y[3], const uint32_t z[3], const Cfg& cfg)
{
    using namespace pvrfp;
    using pvrisp::StoredDepth;
    StoredDepth first_z;
    (void)first_z;
// P2REF-COPY depth-plane pvr_isp_depth.h first_z = StoredDepth::Bits(z[0]);
        first_z = StoredDepth::Bits(z[0]);
        const auto PB = cfg.productBits;
        const auto SB = cfg.sumBits;
        const auto RE = cfg.reach;
        Fp X[3], Y[3], Z[3];
        const bool ranged = cfg.range != 0;
        bool forced = false;                            // the start as the overflow has it (below)
        Fp forcedFirst;
        Fp rangedFirst;                                 // the start in the setup's range (below)
        bool haveRangedFirst = false;
        auto inf = [](bool neg) { Fp r; r.bad = true; r.neg = neg; return r; };
        auto zero = [](bool neg) { Fp r; r.neg = neg; return r; };
        auto load = [&](uint32_t u) { return Fp::FromSingle(u, ranged); };
        auto limit = [&](const Fp& r, bool sumSign) {
            if (!ranged || r.zero()) return r;
            if (r.top() - 1 > 127) return inf(r.neg);
            if (r.top() - 1 < -126) return zero(sumSign ? false : r.neg);
            return r;
        };
        auto mul = [&](const Fp& p, const Fp& q) {
            if (ranged && (p.bad || q.bad)) {
                const Fp& other = p.bad ? q : p;
                return (!other.bad && other.zero()) ? zero(p.neg != q.neg) : inf(p.neg != q.neg);
            }
            return limit(Mul(p, q, PB), false);
        };
        // An addition of the setup's. A sum of zero is +0, -0 + -0 too. A zero added to a number x of 2^-126 ..
        // 1.5 2^-126 in size whose sign is not the zero's is +0 (as if the zero were 2^-127 with its sign and the sum
        // then below the range; the TSP's setup adds a zero so too: pvr_tsp_plane.h Setup); to any other x it is x, to
        // the bit. A zero is one from an input, a product below 2^-126 with its sign, or a sum. In every addition:
        // dreamcast-tests/pvr-tests/depthgaps_zadd (32 slivers read out to the bit, one triangle per case, nothing
        // else near 2^-126; 12 flat probes against quads at 0, z and z + 2^-126): the slope's last addition, +0 +
        // t3: t3 = -2^-126, -1.25 2^-126, -(1.5 - 2^-22) 2^-126 give a slope of 0, -1.5, -1.75, -(2 - 2^-22) and
        // +1 .. +1.75 (2^-126) themselves exactly (not 2^-127 more or less: refsw3's TSP planes' rule then, 76 of 109
        // regions); -0 + -0 is +0 (as -0: 108 of 109); zeros from products below 2^-126 the same; the first
        // addition, -0 + 1.25 2^-126 is +0, +0 + 1.25 and -0 + 1.75 are kept (without the rule there: 108 of 109);
        // the tile's start +0 + c: c = -(1 .. 1.5 - 2^-10) 2^-126 starts at 0, -(1.5 .. 2 - 2^-9) and +1 .. +1.75 at
        // c / det exactly; 109 of 109 regions (a zero as a zero: 84). depthgaps_field1 (1000 of zexfil's flat
        // probes at depths of exponent fields 0 .. 5, most of field 1, against 0 and against a probe of the same
        // shape at another depth): 2000 of 2000 orders with this (1642 with a zero as a zero, 1944 with the TSP's
        // planes' rule in the last additions, 1972 with -0 + -0 = -0, 1996 without the rule in the first additions).
        // The coordinate differences (y1 - y2 .., x2 - x1 ..) go through the same adder, with the rule:
        // dreamcast-tests/pvr-tests/depth2_zcoord (16 triangles near the origin, one coordinate of two corners among
        // +-0 and +-(1 .. 1.5) 2^-126, where such a difference multiplies a depth of 2^126 and more or an infinity:
        // the product a zero, or an infinity times zero 0, with the rule; refsw3 without it there (zeroRuleCoords 0)
        // stores other words at all 2,599 pixels; 5 background probes each: 80 of 80 regions with it, 4,558 probe
        // pixels on 49 pages that tell the two apart). So do the edges x_j y_k - x_k y_j and the determinant's sums:
        // dreamcast-tests/pvr-tests/depth2_zedge (13 triangles near the origin, tiny and signed-zero coordinates,
        // an infinite corner: an edge of +0 against one of +-(1 .. 1.5) 2^-126 makes the infinite depth's term of the
        // constant 0 or an infinity; refsw3 without the rule there (zeroRuleEdges 0) stores other words at all 160
        // pixels; 65 of 65 regions with it, 110 probe pixels on 29 pages that tell the two apart).
        // rule false: the same addition without the zero rule (zeroRuleCoords, zeroRuleEdges 0: not the hardware's)
        auto addRule = [&](const Fp& p, const Fp& q, bool rule) {
            if (ranged && (p.bad || q.bad)) {
                if (p.bad && q.bad && p.neg != q.neg) return zero(false);
                return inf(p.bad ? p.neg : q.neg);
            }
            if (rule && ranged && p.zero() != q.zero()) {
                const Fp& v = p.zero() ? q : p;
                const bool zneg = p.zero() ? p.neg : q.neg;
                const int n = Fp::Bits(v.mant);
                if (v.top() - 1 == -126 && zneg != v.neg && !((v.mant >> (n - 2)) & 1))
                    return zero(false);
            }
            Fp r = limit(Add(p, q, SB, RE), true);
            if (ranged && !r.bad && r.zero())
                r.neg = false;
            return r;
        };
        auto add = [&](const Fp& p, const Fp& q) { return addRule(p, q, true); };
        auto subC = [&](const Fp& p, const Fp& q) { return addRule(p, -q, cfg.zeroRuleCoords != 0); };
        auto addE = [&](const Fp& p, const Fp& q) { return addRule(p, q, cfg.zeroRuleEdges != 0); };
        for (int k = 0; k < 3; k++) {
            X[k] = load(x[k]); Y[k] = load(y[k]); Z[k] = load(z[k]);
        }
        auto edge = [&](int j, int k) { return addE(mul(X[j], Y[k]), -mul(X[k], Y[j])); };
        Fp e1 = edge(1, 2), e2 = edge(2, 0), e3 = edge(0, 1);
        auto sum3 = [&](const Fp& p, const Fp& q, const Fp& r) { return add(add(p, q), r); };
        Fp a = sum3(mul(Z[0], subC(Y[1], Y[2])), mul(Z[1], subC(Y[2], Y[0])), mul(Z[2], subC(Y[0], Y[1])));
        Fp b = sum3(mul(Z[0], subC(X[2], X[1])), mul(Z[1], subC(X[0], X[2])), mul(Z[2], subC(X[1], X[0])));
        Fp c = sum3(mul(Z[0], e1), mul(Z[2], e3), mul(Z[1], e2));       // (v1 + v3) + v2
        Fp det = addE(addE(e1, e2), e3);
        if (pvrfp::Perpendicular(det))
            det = Fp();                                 // FPU_PERP_VAL: as a determinant of zero (pvr_softfp.h)
// P2REF-END depth-plane
    (void)forced; (void)haveRangedFirst; (void)RE;
    PlaneOut o;
    o.a = a; o.b = b; o.c = c; o.det = det; o.e1 = e1; o.e2 = e2; o.e3 = e3;
    return o;
}

}   // namespace p2depthref

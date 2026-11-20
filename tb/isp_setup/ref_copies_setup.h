// ref_copies_setup.h: the refcore code behind the values M4's setup microprogram computes, copied VERBATIM (PLAN 1.1
// "copies", M4; the marker format is tb/ref/ref_copies.h's; tools/check_ref_copies.sh re-extracts every copy and fails on
// drift). They are the reference of the graph check (tools/gen/gen_setup_prog.cpp --check, PLAN M4 gate item 1): the
// graph's outputs, the values p2_isp_setup's hand-off step reads, against the values refsw3's own code computes:
//
//   setup-edge-start     pvr_isp_edge.h EdgeTile::Setup L183-200 at refsw3 4f3efe15: c, dx, dy, first and the tile's
//                        saturated start of one edge (the swamp lambda, the saturations)
//   setup-depth-plane    pvr_isp_depth.h DepthTileT::Setup L343-426: the ranged operations, the edges, a, b, c and the
//                        determinant with Perpendicular (the same lines as tb/isp_depth/ref_copies_depth.h's depth-plane)
//   setup-depth-first0   L470-472: inv0 = Recip(det), the tile's first sample point, first0
//   setup-depth-mean     L646-653: the determinant-zero mean with the infinite corners' fractions
//   setup-depth-slopes   L658-660: A = Mul(a, inv, coefBits), B (C is not used by the ISP's regimes)
//
// Around them, ours: p2setupref::EdgeStart (one edge's dx, dy, start) and p2setupref::DepthValues (a, b, c, det, first0,
// mean, A, B of one primitive in one tile), every value computed whatever the regime (refsw3 computes some of them only
// in some regimes; the operations themselves have no side effects). L1 headers only.
#pragma once
#include <cstdint>
#include "pvr_isp_depth.h"
#include "pvr_isp_edge.h"

namespace p2setupref {

using pvrfp::Fp;

struct EdgeVals { Fp dx, dy, start; };

// one edge a -> b in the tile whose first sample point is (x0Halves, y0Halves) half pixels: EdgeTile::Setup's arithmetic
// before the blocking (dx and dy as computed, before the saturation of the steps)
template<class Cfg>
inline EdgeVals EdgeStart(const Fp& xa, const Fp& ya, const Fp& xb, const Fp& yb, int64_t x0Halves, int64_t y0Halves,
                          const Cfg& cfg)
{
    using namespace pvrfp;
    const auto PB = cfg.productBits;
    const auto SB = cfg.sumBits;
    const auto RE = cfg.reach;
    EdgeVals o;
// P2REF-COPY setup-edge-start pvr_isp_edge.h const auto OE = cfg.overflowExp;
        const auto OE = cfg.overflowExp;
        auto swamp = [&](const Fp& v) { return v.atLeastPow2(OE) ? Fp::Pow2(OE + 72, v.neg) : v; };
        Fp c = swamp(Sub(swamp(Mul(xb, ya, PB)), swamp(Mul(xa, yb, PB)), SB, RE));
        // A coordinate difference that reaches 2^128 swamps too in the products of the start (first), but steps by
        // +-2^127, the saturated value: dreamcast-tests/pvr-tests/hugepos_v4, _v5, _v6 (differences past 2^128: as an
        // infinite step instead, 68,397 / 67,565 pixels of hugepos_v5 / v6 wrong), hugepos_cov pages 6-9 and 26-29,
        // hugepos_sw2 pages 7-10, 18-21 and 29-32, hugepos_rules page 8 (|dx| or |dy| of 2^128 .. 1.75 2^128; hugepos's
        // triangles a and c are not drawn, a at 2^125 with dx = -2^128 exactly has its 4 pixels in row 0 only).
        Fp dx = Sub(xa, xb, SB, RE), dy = Sub(ya, yb, SB, RE);
        const Fp dxP = swamp(dx), dyP = swamp(dy);
        dx = dx.atLeastPow2(OE) ? Fp::Pow2(cfg.saturateExp, dx.neg) : dx;
        dy = dy.atLeastPow2(OE) ? Fp::Pow2(cfg.saturateExp, dy.neg) : dy;
        Fp x0 = Fp::FromHalves(x0Halves), y0 = Fp::FromHalves(y0Halves);
        const auto GD = cfg.guard;
        Fp first = swamp(Add(swamp(Mul(dxP, y0, PB)), -swamp(Mul(dyP, x0, PB)), SB, RE, GD));
        Fp start = Add(first, c, SB, RE, GD);
        if (start.atLeastPow2(OE))
            start = Fp::Pow2(cfg.saturateExp, start.neg);
// P2REF-END setup-edge-start
    // the saturated steps are p2_isp_edge_steps' (fixed logic); the graph's dx, dy are the differences before it
    o.dx = Sub(xa, xb, SB, RE);
    o.dy = Sub(ya, yb, SB, RE);
    o.start = start;
    (void)c; (void)dxP; (void)dyP; (void)dx; (void)dy;
    return o;
}

struct DepthVals {
    Fp a, b, c, det, first0, mean, A, B;
    bool haveFirst0 = false;      // det neither zero nor bad (refsw3 computes first0, A and B only then)
};

// one primitive in the tile (left, top), the sample point of centers (HALF_OFFSET[0])
template<class Cfg>
inline DepthVals DepthValues(const uint32_t x[3], const uint32_t y[3], const uint32_t z[3], int left, int top,
                             const Cfg& cfg, bool centers)
{
    using namespace pvrfp;
    using pvrisp::StoredDepth;
    StoredDepth first_z;
    const int64_t sampleHalf = centers ? 1 : 0;
    DepthVals o;
// P2REF-COPY setup-depth-plane pvr_isp_depth.h first_z = StoredDepth::Bits(z[0]);
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
// P2REF-END setup-depth-plane
    (void)forced; (void)haveRangedFirst; (void)RE; (void)rangedFirst; (void)forcedFirst; (void)first_z;
    o.a = a; o.b = b; o.c = c; o.det = det;
    if (!det.zero() && !det.bad) {
// P2REF-COPY setup-depth-first0 pvr_isp_depth.h Fp inv0 = Recip(det, cfg.recipBits);
            Fp inv0 = Recip(det, cfg.recipBits);
            Fp x00 = Fp::FromHalves(2 * (int64_t)left + sampleHalf), y00 = Fp::FromHalves(2 * (int64_t)top + sampleHalf);
            Fp first0 = mul(add(add(mul(a, x00), mul(b, y00)), c), inv0);
// P2REF-END setup-depth-first0
        o.first0 = first0;
        o.haveFirst0 = true;
    }
    {
// P2REF-COPY setup-depth-mean pvr_isp_depth.h const Fp third = pvrfp::OneThird();
                const Fp third = pvrfp::OneThird();
                auto frac = [&](int k) { return ((z[k] >> 23) & 0xff) == 255 ? z[k] & 0x7fffffu : 0u; };
                auto addBad = [&](const Fp& p, uint32_t pf, const Fp& q, uint32_t qf) {
                    if (ranged && p.bad && q.bad && p.neg != q.neg && pf != qf)
                        return inf(pf > qf ? p.neg : q.neg);
                    return add(p, q);
                };
                const Fp mean = mul(addBad(addBad(Z[0], frac(0), Z[1], frac(1)), 0, Z[2], frac(2)), third);
// P2REF-END setup-depth-mean
        o.mean = mean;
    }
    Fp A, B;
    if (!det.zero() && !det.bad) {
// P2REF-COPY setup-depth-slopes pvr_isp_depth.h Fp inv = Recip(det, cfg.recipBits);
        Fp inv = Recip(det, cfg.recipBits);
        A = Mul(a, inv, cfg.coefBits);
        B = Mul(b, inv, cfg.coefBits);
// P2REF-END setup-depth-slopes
    }
    o.A = A; o.B = B;
    return o;
}

}   // namespace p2setupref

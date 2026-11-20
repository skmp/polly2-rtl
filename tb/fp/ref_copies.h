// ref_copies.h (tb/fp): the refcore rules behind the range wrappers (H10) and the culls (H9) that no wrapper reaches
// (local lambdas of DepthTileT::Setup, PlaneT::Setup, MipSelect; the statics CulledBySize / CulledByFacing of
// refsw_tile.cpp), copied VERBATIM between markers (docs/spec/numerics.md 7.1, PLAN 1.1). tools/check_ref_copies.sh
// re-extracts every block from $(REFCORE) and fails on drift; every gate runs it. The marker format is in
// tb/ref/ref_copies.h. Code outside the blocks is ours: the functions around them give each copy the names it captures
// (the HW configuration: DepthHW, PlaneHW, ranged = 1) and dispatch on an operation.
//
//   p2fpref::depth(op, a, b, af, bf)   pvr_isp_depth.h L321-371 (inf, zero, load, limit, mul, add, sub), L571-575
//                                      (addBad), L596 (under), at 708fb8cd
//   p2fpref::tsp(op, a, b, zbits)      pvr_tsp_plane.h L144-184 (ranged, inf, zero, above, below, load, mul, addTerm,
//                                      add, sum3, sub), L257-267 (withZero), L285-287 (the reciprocal's range)
//   p2fpref::mip(op, a, b, &kind)      pvr_tsp_plane.h L602-612 (above, below, inf, kind), L619-621 (1/det), L629-630
//                                      (1/det^2 below the range), L699-710 (rmul), L720-730 (radd)
//   p2fpref::seen(v)                   pvr_tsp_plane.h L311-315 (PlaneT::Value: the evaluator's view of a coefficient)
//   p2fpref::culledBySize(det, reg), culledByFacing(mode, det)   refsw_tile.cpp L722-740
//
// One rule needs the testbench's help: depth `add`'s zero rule reads the bit under a one-bit mantissa's leading one
// with a shift by -1 (num D2, undefined in C++). The testbench expects +0 there (the value rule, as GCC computes it on
// x86-64) and counts the cases; it does not rely on this copy's result for them.
#pragma once
#include <cstdint>
#include "pvr_softfp.h"
#include "pvr_isp_depth.h"
#include "pvr_tsp_plane.h"

namespace p2fpref {
using pvrfp::Fp;

// ---------------------------------------------------------------------------------------------------------------
// the ISP depth setup's ranged operations (DepthHW: productBits 24, sumBits 24, reach 25, range 1)
enum DepthOp { D_LIMIT_PRODUCT, D_LIMIT_SUM, D_MUL, D_ADD, D_ADDBAD, D_UNDER };

inline Fp depth(DepthOp op, const Fp& a, const Fp& b = Fp(), uint32_t af = 0, uint32_t bf = 0)
{
    using namespace pvrfp;
    const auto PB = pvrisp::DepthHW::productBits;
    const auto SB = pvrisp::DepthHW::sumBits;
    const auto RE = pvrisp::DepthHW::reach;
    const bool ranged = pvrisp::DepthHW::range != 0;
// P2REF-COPY fp-depth-rng pvr_isp_depth.h auto inf = [](bool neg) { Fp r; r.bad = true; r.neg = neg; return r; };
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
        // then below the range; the TSP's mean adds a zero so, pvr_tsp_plane.h withZero); to any other x it is x, to
        // the bit. A zero is one from an input, a product below 2^-126 with its sign, or a sum. In every addition:
        // dreamcast-tests/pvr-tests/depthgaps_zadd (32 slivers read out to the bit, one triangle per case, nothing
        // else near 2^-126; 12 flat probes against quads at 0, z and z + 2^-126): the slope's last addition, +0 +
        // t3: t3 = -2^-126, -1.25 2^-126, -(1.5 - 2^-22) 2^-126 give a slope of 0, -1.5, -1.75, -(2 - 2^-22) and
        // +1 .. +1.75 (2^-126) themselves exactly (not 2^-127 more or less: the TSP's planes' rule, 76 of 109
        // regions); -0 + -0 is +0 (as -0: 108 of 109); zeros from products below 2^-126 the same; the first
        // addition, -0 + 1.25 2^-126 is +0, +0 + 1.25 and -0 + 1.75 are kept (without the rule there: 108 of 109);
        // the tile's start +0 + c: c = -(1 .. 1.5 - 2^-10) 2^-126 starts at 0, -(1.5 .. 2 - 2^-9) and +1 .. +1.75 at
        // c / det exactly; 109 of 109 regions (a zero as a zero: 84). depthgaps_field1 (1000 of zexfil's flat
        // probes at depths of exponent fields 0 .. 5, most of field 1, against 0 and against a probe of the same
        // shape at another depth): 2000 of 2000 orders with this (1642 with a zero as a zero, 1944 with the TSP's
        // planes' rule in the last additions, 1972 with -0 + -0 = -0, 1996 without the rule in the first additions).
        // GAP: the rule sits in the setup's shared add, so it also applies to the coordinate differences and the
        // determinant of the depth setup; only the depth products' sums were measured.
        auto add = [&](const Fp& p, const Fp& q) {
            if (ranged && (p.bad || q.bad)) {
                if (p.bad && q.bad && p.neg != q.neg) return zero(false);
                return inf(p.bad ? p.neg : q.neg);
            }
            if (ranged && p.zero() != q.zero()) {
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
        auto sub = [&](const Fp& p, const Fp& q) { return add(p, -q); };
// P2REF-END fp-depth-rng
// P2REF-COPY fp-depth-addbad pvr_isp_depth.h auto addBad = [&](const Fp& p, uint32_t pf, const Fp& q, uint32_t qf) {
                auto addBad = [&](const Fp& p, uint32_t pf, const Fp& q, uint32_t qf) {
                    if (ranged && p.bad && q.bad && p.neg != q.neg && pf != qf)
                        return inf(pf > qf ? p.neg : q.neg);
                    return add(p, q);
                };
// P2REF-END fp-depth-addbad
// P2REF-COPY fp-depth-under pvr_isp_depth.h auto under = [](Fp& v) { if (!v.zero() && v.top() - 1 < -126) v.mant = 0; };
            auto under = [](Fp& v) { if (!v.zero() && v.top() - 1 < -126) v.mant = 0; };
// P2REF-END fp-depth-under
    (void)load;
    (void)sub;
    switch (op) {
    case D_LIMIT_PRODUCT: return limit(a, false);
    case D_LIMIT_SUM: return limit(a, true);
    case D_MUL: return mul(a, b);
    case D_ADD: return add(a, b);
    case D_ADDBAD: return addBad(a, af, b, bf);
    case D_UNDER: {
        Fp v = a;
        under(v);
        return v;
    }
    }
    return Fp();
}

// ---------------------------------------------------------------------------------------------------------------
// the TSP setup's ranged operations (PlaneHW)
enum TspOp { T_MUL, T_ADD, T_ADD3, T_RECIP, T_WITHZERO };

inline Fp tsp(TspOp op, const Fp& a, const Fp& b = Fp(), uint32_t zbits = 0)
{
    using namespace pvrfp;
    const pvrtsp::PlaneHW cfg{};
    const auto PB = cfg.productBits;
    const auto SB = cfg.sumBits;
    const auto RE = cfg.reach;
// P2REF-COPY fp-tsp-rng pvr_tsp_plane.h const bool ranged = cfg.range != 0;
        const bool ranged = cfg.range != 0;
        auto inf = [](bool neg) { Fp r; r.bad = true; r.neg = neg; return r; };
        auto zero = [](bool neg) { Fp r; r.neg = neg; return r; };
        auto above = [&](const Fp& v) { return !v.zero() && v.top() - 1 > cfg.expHigh; };
        auto below = [&](const Fp& v) { return !v.zero() && v.top() - 1 < cfg.expLow; };
        auto load = [&](uint32_t u) { return Fp::FromSingle(u, ranged); };
        auto mul = [&](const Fp& p, const Fp& q) {
            if (!ranged)
                return Mul(p, q, PB);
            const bool neg = p.neg != q.neg;
            if (p.bad || q.bad) {
                const Fp& other = p.bad ? q : p;
                return (!other.bad && other.zero()) ? zero(neg) : inf(neg);
            }
            Fp r = Mul(p, q, PB);
            if (above(r)) return inf(neg);
            if (below(r)) return zero(neg);
            return r;
        };
        auto addTerm = [&](const Fp& p0, const Fp& q0, bool third) {
            if (!ranged)
                return Add(p0, q0, SB, RE);
            if (p0.bad || q0.bad) {
                if (p0.bad && q0.bad && p0.neg != q0.neg)
                    return zero(false);
                return inf(p0.bad ? p0.neg : q0.neg);
            }
            Fp p = p0, q = q0;
            if (third) {
                auto smallest = [&](const Fp& v) { return !v.zero() && v.top() - 1 < -127 + cfg.zeroReach; };
                if (q0.zero() && smallest(p0)) { q.mant = 1; q.exp = -127; }
                if (p0.zero() && smallest(q0)) { p.mant = 1; p.exp = -127; }
            }
            Fp r = Add(p, q, SB, RE);
            if (above(r)) return inf(r.neg);
            if (below(r)) return zero(false);
            return r;
        };
        auto add = [&](const Fp& p, const Fp& q) { return addTerm(p, q, false); };
        auto sum3 = [&](const Fp& t1, const Fp& t2, const Fp& t3) { return addTerm(addTerm(t1, t2, false), t3, true); };
        auto sub = [&](const Fp& p, const Fp& q) { return add(p, -q); };
// P2REF-END fp-tsp-rng
// P2REF-COPY fp-tsp-withzero pvr_tsp_plane.h auto withZero = [&](const Fp& p, uint32_t zeroBits) {
            auto withZero = [&](const Fp& p, uint32_t zeroBits) {
                const bool zneg = (zeroBits >> 31) != 0;
                if (p.zero() || p.bad || p.top() - 1 != cfg.expLow || p.neg == zneg)
                    return p;
                Fp zv;
                zv.mant = (1u << 23) | (zeroBits & 0x7fffffu);
                zv.exp = -150;
                zv.neg = zneg;
                const Fp r = Add(p, zv, 62, 400);
                return (r.zero() || r.top() - 1 < cfg.expLow) ? Fp() : p;
            };
// P2REF-END fp-tsp-withzero
    (void)load;
    (void)sum3;
    (void)sub;
    if (op == T_RECIP) {
        const Fp& det = a;
// P2REF-COPY fp-tsp-recip pvr_tsp_plane.h Fp inv = det.bad ? zero(det.neg) : Recip(det, cfg.recipBits);
        Fp inv = det.bad ? zero(det.neg) : Recip(det, cfg.recipBits);
        if (ranged && below(inv))
            inv = zero(inv.neg);
// P2REF-END fp-tsp-recip
        return inv;
    }
    switch (op) {
    case T_MUL: return mul(a, b);
    case T_ADD: return add(a, b);
    case T_ADD3: return addTerm(a, b, true);
    case T_WITHZERO: return withZero(a, zbits);
    default: break;
    }
    return Fp();
}

// ---------------------------------------------------------------------------------------------------------------
// MipSelect's ranged operations (w.cfg.range 1); kind: 0 a number, 1 an infinity, -1 a zero
enum MipOp { M_KIND, M_RECIP, M_INV2_BELOW, M_RMUL, M_RADD };

inline Fp mip(MipOp op, const Fp& a, const Fp& b = Fp(), int* kindOut = nullptr)
{
    using namespace pvrfp;
    const bool ranged = true;
// P2REF-COPY fp-mip-kind pvr_tsp_plane.h auto above = [](const Fp& x) { return !x.zero() && x.top() - 1 > 127; };
    auto above = [](const Fp& x) { return !x.zero() && x.top() - 1 > 127; };
    auto below = [](const Fp& x) { return !x.zero() && x.top() - 1 < -126; };
    auto inf = []() { Fp x; x.bad = true; return x; };
    // one product of two sums: 0 a number, 1 an infinity, -1 a zero (the value itself: minor, below)
    auto kind = [&](const Fp& x, const Fp& y) {
        if (!ranged) return 0;
        if (x.bad || y.bad) return ((!x.bad && x.zero()) || (!y.bad && y.zero())) ? -1 : 1;
        if (x.zero() || y.zero()) return -1;
        Fp m = Mul(x, y, 24);
        return above(m) ? 1 : below(m) ? -1 : 0;
    };
// P2REF-END fp-mip-kind
    (void)inf;
    if (op == M_KIND) {
        if (kindOut)
            *kindOut = kind(a, b);
        return Mul(a, b, 24);
    }
    if (op == M_RECIP) {
        const Fp& det = a;
// P2REF-COPY fp-mip-recip pvr_tsp_plane.h Fp inv = det.bad ? Fp() : Recip(det, 24);
    Fp inv = det.bad ? Fp() : Recip(det, 24);
    if (ranged && below(inv))
        inv = Fp();
// P2REF-END fp-mip-recip
    return inv;
    }
    if (op == M_INV2_BELOW) {
        Fp inv2 = a;
// P2REF-COPY fp-mip-inv2 pvr_tsp_plane.h if (ranged && below(inv2))
    if (ranged && below(inv2))
        inv2 = Fp();
// P2REF-END fp-mip-inv2
    return inv2;
    }
// P2REF-COPY fp-mip-rmul pvr_tsp_plane.h auto rmul = [&](const Fp& x, const Fp& y) {
        auto rmul = [&](const Fp& x, const Fp& y) {
            if (x.bad || y.bad) {
                const Fp& o = x.bad ? y : x;
                Fp z; z.neg = x.neg != y.neg;
                if (!o.bad && o.zero()) return z;
                z.bad = true; return z;
            }
            Fp m = Mul(x, y, 24);
            if (ranged && above(m)) { Fp z; z.bad = true; z.neg = m.neg; return z; }
            if (ranged && below(m)) { Fp z; z.neg = m.neg; return z; }
            return m;
        };
// P2REF-END fp-mip-rmul
// P2REF-COPY fp-mip-radd pvr_tsp_plane.h auto radd = [&](const Fp& x, const Fp& y) {
        auto radd = [&](const Fp& x, const Fp& y) {
            if (x.bad || y.bad) {
                Fp z;
                if (x.bad && y.bad && x.neg != y.neg) return z;
                z.bad = true; z.neg = x.bad ? x.neg : y.neg; return z;
            }
            Fp m = Add(x, y, 24, 53);
            if (ranged && above(m)) { Fp z; z.bad = true; z.neg = m.neg; return z; }
            if (ranged && below(m)) return Fp();
            return m;
        };
// P2REF-END fp-mip-radd
    if (op == M_RMUL)
        return rmul(a, b);
    return radd(a, b);
}

// ---------------------------------------------------------------------------------------------------------------
// the TSP evaluator's view of a coefficient (PlaneT::Value)
inline Fp seen(const Fp& a)
{
    using namespace pvrfp;
// P2REF-COPY fp-tsp-seen pvr_tsp_plane.h auto seen = [](const Fp& v) {
        auto seen = [](const Fp& v) {
            if (v.bad) return Fp::Pow2(-128, v.neg);
            if (v.zero()) return Fp::Pow2(-127, v.neg);
            return v;
        };
// P2REF-END fp-tsp-seen
    return seen(a);
}

// ---------------------------------------------------------------------------------------------------------------
// the ISP's culls (refsw_tile.cpp), with FPU_CULL_VAL from g_fpu_cull_val
typedef uint32_t u32;
inline uint32_t g_fpu_cull_val;
#define FPU_CULL_VAL_addr 0
#define PvrReg(addr, type) ((type)p2fpref::g_fpu_cull_val)
// P2REF-COPY fp-cull refsw_tile.cpp static bool CulledBySize(const pvrfp::Fp& det)
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

// P2REF-END fp-cull
#undef PvrReg
#undef FPU_CULL_VAL_addr

inline bool culledBySize(const Fp& det, uint32_t fpuCullVal)
{
    g_fpu_cull_val = fpuCullVal;
    return CulledBySize(det);
}
inline bool culledByFacing(uint32_t cullMode, const Fp& det) { return CulledByFacing(cullMode, det); }

}   // namespace p2fpref

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
#include <algorithm>
#include <cstdint>
#include "pvr_softfp.h"
#include "pvr_isp_depth.h"
#include "pvr_isp_edge.h"
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

// ===============================================================================================================
// M1b (PLAN M1 round b): the copies behind H7a (the edge start's swamp), H7b and H12a (PlaneT::Value's integer part and
// its normalizer), H7c (MipSelect's minor), H11 (edge unitsAt, the depth REG's rstep and r0, TexCoordFixed /
// CoordKeep) and H14 (the background key of refsw_lists.cpp RenderCORE). All at 708fb8cd.
//
//   p2fpref::edgeStart(xa, ya, xb, yb, x0h, y0h)   pvr_isp_edge.h EdgeTile::Setup L180-197: c, dx, dy, dxP, dyP,
//                                                  first, start (the caller has excluded bad corners, L161)
//   p2fpref::valueK(A, B, C, x0h, yh, n, tl, tt, super, hx, hy, &unit)   pvr_tsp_plane.h PlaneT::Value L311-369: the
//                                                  integer k before the normalizer, and the grid exponent
//   p2fpref::valueNorm(k, unit)                    pvr_tsp_plane.h PlaneT::Value L377-397
//   p2fpref::mipMinor(q1, q2)                      pvr_tsp_plane.h MipSelect minor L642-644
//   p2fpref::unitsAt(v, &frac, unit)               pvr_isp_edge.h EdgeTile::Setup L239-257
//   p2fpref::regStep(v0, cap, invS), regStart(first0)   pvr_isp_depth.h DepthTileT::Setup L433-444, L476-483
//   p2fpref::coordKeep(f), texCoordFixed(u, shift)  refsw_tile.cpp L1264-1316
//   p2fpref::bgKey(bg)                             refsw_lists.cpp RenderCORE L637-652 (StoredDepth as ZType)

// ---------------------------------------------------------------------------------------------------------------
struct EdgeStart {
    Fp c, dx, dy, dxP, dyP, first, start;
};
inline EdgeStart edgeStart(const Fp& xa, const Fp& ya, const Fp& xb, const Fp& yb, int64_t x0Halves, int64_t y0Halves)
{
    using namespace pvrfp;
    const pvrisp::EdgeHW cfg{};
    const auto PB = cfg.productBits;
    const auto SB = cfg.sumBits;
    const auto RE = cfg.reach;
// P2REF-COPY fp-edge-start pvr_isp_edge.h const auto OE = cfg.overflowExp;
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
// P2REF-END fp-edge-start
    return EdgeStart{c, dx, dy, dxP, dyP, first, start};
}

// ---------------------------------------------------------------------------------------------------------------
// PlaneT::Value up to the normalizer: k in units of 2^unit (PlaneHW: range 1, macOrder 0, tileLocal 0)
inline int64_t valueK(const Fp& A, const Fp& B, const Fp& C, int64_t x0Halves, int64_t yHalves, int n, int tileLeft,
                      int tileTop, bool super, int hx, int hy, int* unitOut)
{
    using namespace pvrfp;
    using pvrtsp::FloorUnits;
    const pvrtsp::PlaneHW cfg{};
// P2REF-COPY fp-tsp-valuek pvr_tsp_plane.h auto seen = [](const Fp& v) {
        auto seen = [](const Fp& v) {
            if (v.bad) return Fp::Pow2(-128, v.neg);
            if (v.zero()) return Fp::Pow2(-127, v.neg);
            return v;
        };
        const Fp a_ = seen(A), b_ = seen(B), c_ = seen(C);
        // range 0: as before the limits were measured, a zero coefficient does not count for the grid
        auto top = [&](const Fp& v, const Fp& s) { return (!cfg.range && v.zero() && !v.bad) ? NoExp : s.top(); };
        int ex = Fp::FromHalves(2 * (int64_t)(tileLeft + 16)).top(), ey = Fp::FromHalves(2 * (int64_t)(tileTop + 16)).top();
        int e = top(C, c_);
        if (top(A, a_) != NoExp && top(A, a_) + ex - 1 > e) e = top(A, a_) + ex - 1;
        if (top(B, b_) != NoExp && top(B, b_) + ey - 1 > e) e = top(B, b_) + ey - 1;
        if (e == NoExp)
            e = 0;                                      // a plane that is zero everywhere: any grid
        int unit = e - cfg.gridBits;
        Fp ax = Mul(a_, Fp::FromHalves(x0Halves), 62), by = Mul(b_, Fp::FromHalves(yHalves), 62);
        if (ax.zero()) ax.neg = a_.neg;                 // x = 0: still on the coefficient's side of zero
        if (by.zero()) by.neg = b_.neg;
        int64_t k = FloorUnits(c_, unit) + FloorUnits(ax, unit) + FloorUnits(by, unit) + (int64_t)n * FloorUnits(a_, unit);
        if (cfg.macOrder) {
            auto exact = [](const Fp& p, const Fp& q) { return Add(p, q, 62, 400); };
            if (cfg.macOrder == 1)
                k = FloorUnits(exact(c_, by), unit) + FloorUnits(ax, unit) + (int64_t)n * FloorUnits(a_, unit);
            else if (cfg.macOrder == 2)
                k = FloorUnits(exact(c_, ax), unit) + FloorUnits(by, unit) + (int64_t)n * FloorUnits(a_, unit);
            else
                k = FloorUnits(exact(exact(c_, by), ax), unit) + (int64_t)n * FloorUnits(a_, unit);
        }
        if (cfg.tileLocal) {
            const Fp xt = Fp::FromHalves(2 * (int64_t)tileLeft), yt = Fp::FromHalves(2 * (int64_t)tileTop);
            const Fp ct = Add(Add(c_, Mul(a_, xt, 62), 62, 400), Mul(b_, yt, 62), 62, 400);
            Fp axl = Mul(a_, Fp::FromHalves(x0Halves - 2 * (int64_t)tileLeft), 62), byl = Mul(b_, Fp::FromHalves(yHalves - 2 * (int64_t)tileTop), 62);
            if (axl.zero()) axl.neg = a_.neg;
            if (byl.zero()) byl.neg = b_.neg;
            if (cfg.tileLocal == 2) {
                const int el = Fp::FromHalves(2 * 16).top();
                int e2 = ct.zero() ? NoExp : ct.top();
                if (a_.top() + el - 1 > e2) e2 = a_.top() + el - 1;
                if (b_.top() + el - 1 > e2) e2 = b_.top() + el - 1;
                unit = e2 - cfg.gridBits;
            }
            k = FloorUnits(ct, unit) + FloorUnits(axl, unit) + FloorUnits(byl, unit) + (int64_t)n * FloorUnits(a_, unit);
            if (cfg.tileLocal == 3) {       // every piece rounded down by itself: C, A Xt, B Yt, A x, B y
                Fp axt = Mul(a_, xt, 62), byt = Mul(b_, yt, 62);
                if (axt.zero()) axt.neg = a_.neg;
                if (byt.zero()) byt.neg = b_.neg;
                k = FloorUnits(c_, unit) + FloorUnits(axt, unit) + FloorUnits(byt, unit) + FloorUnits(axl, unit) + FloorUnits(byl, unit)
                    + (int64_t)n * FloorUnits(a_, unit);
            }
        }
        if (super) {
            const Fp half = Fp::FromHalves(1);
            Fp ah = Mul(a_, half, 62), bh = Mul(b_, half, 62);
            if (ah.zero()) ah.neg = a_.neg;
            if (bh.zero()) bh.neg = b_.neg;
            k += -(int64_t)n * FloorUnits(a_, unit) + (int64_t)(2 * n + hx) * FloorUnits(ah, unit);
            if (hy)
                k += FloorUnits(Add(c_, bh, 62, 400), unit) - FloorUnits(c_, unit);
        }
// P2REF-END fp-tsp-valuek
    *unitOut = unit;
    return k;
}
inline Fp valueNorm(int64_t k, int unit)
{
    using namespace pvrfp;
    const pvrtsp::PlaneHW cfg{};
// P2REF-COPY fp-tsp-valuenorm pvr_tsp_plane.h Fp v;
        Fp v;
        if (k == 0)
            return v;
        if (k == -1 && cfg.range)
            return Fp::Pow2(-143, true);
        v.neg = k < 0;
        uint64_t m = (uint64_t)(k < 0 ? -k : k);
        int bits = Fp::Bits(m), drop = bits > cfg.valueBits ? bits - cfg.valueBits : 0;
        if (cfg.valueFixed > drop)
            drop = cfg.valueFixed < 63 ? cfg.valueFixed : 63;
        if (drop) {
            uint64_t lost = m & ((1ull << drop) - 1);
            m >>= drop;
            if (lost && v.neg)
                m += 1;
        }
        v.mant = m;
        v.exp = unit + drop;
        if (cfg.range && v.top() - 1 < -128)
            v.exp += -128 - (v.top() - 1);
        return v;
// P2REF-END fp-tsp-valuenorm
}

// ---------------------------------------------------------------------------------------------------------------
inline Fp mipMinor(const Fp& q1, const Fp& q2)
{
    using namespace pvrfp;
// P2REF-COPY fp-mip-minor pvr_tsp_plane.h Fp n = Sub(q1, q2, 62, 200).cut(24);
            Fp n = Sub(q1, q2, 62, 200).cut(24);
            n.neg = false;
            n.bad = false;
// P2REF-END fp-mip-minor
    return n;
}

// ---------------------------------------------------------------------------------------------------------------
inline int64_t unitsAt(const Fp& v, bool* frac, int u)
{
    using namespace pvrfp;
// P2REF-COPY fp-edge-unitsat pvr_isp_edge.h auto unitsAt = [&](const Fp& v, bool* frac, int unit) -> int64_t {
        auto unitsAt = [&](const Fp& v, bool* frac, int unit) -> int64_t {      // floor(v / 2^unit); *frac: not a whole number
            if (frac) *frac = false;
            if (v.zero())
                return 0;
            int s = v.exp - unit;
            int64_t m;
            if (s >= 0)
                m = (int64_t)(v.mant << s);
            else {
                uint64_t lost = (-s >= 64) ? v.mant : (v.mant & ((1ull << -s) - 1));
                m = (-s >= 64) ? 0 : (int64_t)(v.mant >> -s);
                if (lost) {
                    if (frac) *frac = true;
                    if (v.neg)
                        m += 1;                         // floor of a negative: one further from zero
                }
            }
            return v.neg ? -m : m;
        };
// P2REF-END fp-edge-unitsat
    return unitsAt(v, frac, u);
}
inline int64_t regStep(const Fp& v0, bool cap, const Fp& invS)
{
    using namespace pvrfp;
    const pvrisp::DepthHW cfg{};
// P2REF-COPY fp-depth-rstep pvr_isp_depth.h auto rstep = [&](const Fp& v0, bool cap) -> int64_t {
                    auto rstep = [&](const Fp& v0, bool cap) -> int64_t {
                        if (cap || v0.zero())
                            return 0;
                        const Fp q = Mul(v0, invS, cfg.coefBits).cut(cfg.slopeBits).cutBelow(102);
                        if (q.zero())
                            return 0;
                        // modulo the register's 2^131 (GAP: a slope of 2^128 or more after the division, from a
                        // determinant below 1, is not measured)
                        const int sh = q.exp - 102;
                        const int64_t m = sh < 30 ? (int64_t)((q.mant << sh) & ((uint64_t(1) << 30) - 1)) : 0;
                        return q.neg ? -m : m;
                    };
// P2REF-END fp-depth-rstep
    return rstep(v0, cap);
}
inline int64_t regStart(const Fp& first0)
{
    using namespace pvrfp;
    const pvrisp::DepthHW cfg{};
    int64_t r0 = 0;
// P2REF-COPY fp-depth-r0 pvr_isp_depth.h if (first0.bad) {
                if (first0.bad) {
                    r0 = first0.neg ? -(int64_t(1) << 25) : (int64_t(1) << 25);
                } else if (!first0.zero()) {
                    const Fp st = first0.cut(cfg.startBits);
                    const int sh = st.exp - 102;
                    const int64_t m = sh >= 0 ? (sh < 40 ? (int64_t)(st.mant << sh) : 0) : (-sh < 64 ? (int64_t)(st.mant >> -sh) : 0);
                    r0 = st.neg ? -m : m;
                }
// P2REF-END fp-depth-r0
    return r0;
}

// ---------------------------------------------------------------------------------------------------------------
#ifndef ALWAYS_INLINE
#define P2FPREF_UNDEF_ALWAYS_INLINE
#define ALWAYS_INLINE inline
#endif
// P2REF-COPY fp-tex-coord refsw_tile.cpp ALWAYS_INLINE int CoordKeep(int64_t f) {
ALWAYS_INLINE int CoordKeep(int64_t f) {
    if (f >= 1073741824)
        return (int)(1073741824 + (f & 67108863));
    if (f < -1073741824)
        return (int)(-1073741824 + (f & 67108863));
    return (int)f;
}

// A texture coordinate in 1/256 texel as hardware sees it. Hardware's coordinates come out a hair toward
// zero: a coordinate that is exactly on a boundary belongs to the texel before it, except at 0
// (dreamcast-tests/pvr-tests/sample: point sampling with half-pixel shifts, bilinear with the weights of page 2).
// Values within 1/32 of a unit of an integer are treated as being exactly on it.
ALWAYS_INLINE int TexCoordFixed(const pvrfp::Fp& u, int shift) {
    // u * 2^shift (the size of the texture in 1/256 texel: exact, u has 17 bits), rounded down in two's complement,
    // below zero too (dreamcast-tests/pvr-tests/coordfix: every weight step from -4 to +4 texels and at up to 2^17
    // texels, clamp and flip; toward zero gets 437 of its 1568 regions wrong). The coordinate the TSP delivers is
    // already rounded down (PlaneStepper3), which is what makes a coordinate exactly on a texel boundary show the
    // texel before it (dreamcast-tests/pvr-tests/sample, uvmeas). Far outside an int (coordinates of thousands of
    // texture repeats): the sign and the low 26 bits, which is all that wrapping, flipping and clamping look at.
    // That holds at 2^128 and beyond too: there is no overflow to texel 0 there (as the old float code had it), a
    // clamped one is the last texel, below zero the first, wrapped and flipped the low bits are zeros
    // (dreamcast-tests/pvr-tests/texfar_edge: quotients of exactly 2^128, (1 + 2^-15) 2^128, 1.5 2^128, 2^129,
    // 2^132 and up to the largest float times the size, in 1/256 texel, of 8, 64 and 1024 texel textures, along U
    // and V, point and bilinear: 63 clamped regions the last texel, as above 2^127; texfar: 28 regions;
    // texfar_quot: quotients over a zero 1/w up to 2^260 in 1/256 texel, 103 regions; texfar_m1q: up to 2^261).
    // The low bits are the integer's own up to where the quotient's 17 bits leave them (texfar_bits: tops 2^9 ..
    // 2^36, wrap and flip, both signs, U and V: 300 of 300, as refsw3 had it).
    // A quotient is never an infinity or a NaN (Divide); u.bad is for a caller that has one.
    if (u.bad || u.zero())
        return 0;
    const int top = u.top() + shift;                    // |u| 2^shift is in [2^(top - 1), 2^top)
    const int e = u.exp + shift;                        // u 2^shift = mant 2^e
    if (top <= 31) {
        int64_t f;
        if (e >= 0)
            f = (int64_t)(u.mant << e);
        else {
            const int s = -e;
            const uint64_t lost = s >= 64 ? u.mant : (u.mant & ((1ull << s) - 1));
            f = s >= 64 ? 0 : (int64_t)(u.mant >> s);
            if (u.neg && lost)
                f += 1;
        }
        if (u.neg)
            f = -f;
        return CoordKeep(f);
    }
    // 2^30 and more: an integer; its low 26 bits (two's complement for a negative one)
    const uint64_t low = e >= 26 ? 0 : (uint64_t)(u.mant << e) & 67108863;
    if (!u.neg)
        return (int)(1073741824 + low);
    return (int)(-1073741824 + (int64_t)((67108864 - low) & 67108863));
}
// P2REF-END fp-tex-coord
#ifdef P2FPREF_UNDEF_ALWAYS_INLINE
#undef ALWAYS_INLINE
#undef P2FPREF_UNDEF_ALWAYS_INLINE
#endif
inline int coordKeep(int64_t f) { return CoordKeep(f); }
inline int texCoordFixed(const Fp& u, int shift) { return TexCoordFixed(u, shift); }

// ---------------------------------------------------------------------------------------------------------------
// the background's key from ISP_BACKGND_D (StoredDepth is refsw3's ZType)
inline pvrisp::StoredDepth bgKey(uint32_t isp_backgnd_d)
{
    typedef pvrisp::StoredDepth ZType;
    struct { u32 i; } ISP_BACKGND_D = {isp_backgnd_d};
// P2REF-COPY fp-bgkey refsw_lists.cpp const u32 bg = ISP_BACKGND_D.i, field = (bg >> 23) & 0xff;
            const u32 bg = ISP_BACKGND_D.i, field = (bg >> 23) & 0xff;
            ZType bgZ;
            if (bg >> 31) {
                const int f = field == 255 ? 254 : (int)field;
                const int E = std::max(f - 126, 6);
                const uint64_t m20 = (0x800000u | (bg & 0x7fffffu)) >> 4;       // the depth is m20 2^(f - 146)
                const int sh = f - 120 - E;                                     // in units of 2^(E - 26)
                const uint64_t t = f < 107 ? 0 : sh >= 0 ? m20 << sh : (-sh < 64 ? m20 >> -sh : 0);
                bgZ = t ? ZType::Neg(E, -(int64_t)((t + 1023) >> 10)) : ZType();
            } else {
                const int cut = std::max(5, 130 - (int)field);
                u32 bgBits = cut > 23 ? 0 : (bg & ~((1u << cut) - 1));
                if (field == 255)
                    bgBits -= 1u << 23;
                bgZ = ZType::Bits(bgBits);
            }
// P2REF-END fp-bgkey
    return bgZ;
}

}   // namespace p2fpref

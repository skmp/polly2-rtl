// fp_range_tb.cpp: make fp-range. H10, the range wrappers, against the verbatim copies of tb/fp/ref_copies.h
// (docs/spec/numerics.md H10, 4, 7.3) and, for the edge flavour, refcore's plain Mul / Add:
//
//   p2_fp_rng_lim      PRODUCT / SUM: depth `limit(r, false / true)`; UNDER: depth `under`; BELOW: MipSelect's
//                      `if (ranged && below(inv2)) inv2 = Fp()`
//   p2_fp_rng_mul      ranged 0: Mul(a, b, C<24>) (edge); ranged 1: depth `mul`, TSP `mul` and mip `rmul`, each
//   p2_fp_rng_add 25   NONE: Add(a, b, C<24>, C<25>) (edge); DEPTH: depth `add`; TSP: TSP `addTerm(., ., false)` and
//                      `addTerm(., ., true)` (one rule at 4f3efe15); MIP: no refsw3 site at reach 25
//   p2_fp_rng_add 53   NONE: Add(a, b, 24, 53); MIP: mip `radd` (DEPTH and TSP have no refsw3 site at reach 53)
//   p2_fp_rng_add_inf  depth `addBad`
//   p2_fp_rng_kind     mip `kind` and Mul(a, b, 24)
//   p2_fp_rng_recip    mip 0: the TSP's `inv` (not for a zero determinant: refsw3 never takes one there); mip 1:
//                      MipSelect's `inv` (+0 for a zero determinant since 4f3efe15)
//   p2_fp_rng_with_zero   TSP `withZero`
//
// num D2: depth `add`'s zero rule shifts by -1 for a one-bit mantissa. Those cases expect +0 (the value rule,
// |v| < 1.5 2^-126, which GCC computes on x86-64) whatever this build's copy computes; they are counted.
//
// Sections (--only):
//   directed  console facts as literals: depthgaps_zadd (-0 + 1.25 2^-126 is +0; +0 + 1.25 and -0 + 1.75 are kept;
//             -0 + -0 is +0; a zero against -(1 .. 1.5 - 2^-22) 2^-126 is +0, against -1.5 2^-126 kept); the TSP's
//             zero rule (tsp2_zadd: 1.25 2^-126 + 0 is +0 in either addition, -1.75 kept, -0 + -0 +0) and MipSelect's
//             radd (-0 + -0 = -0); trsort_recip (a determinant of exactly 2^126: a zero reciprocal); inf * 0 = 0, inf - inf = +0 (uvmeas wspec); a product of
//             exactly 2^128 an infinity (zovf_ps), a sum of it too (zovf_lim); slivers_dzzero's boundary kept
//   classes   the class pairs of num 7.3 ({+-0, +-bad, [2^-126, 2^-125), [2^-125, 2^-124), ordinary, [2^127, 2^128)}
//             for both operands) x every mode, 100 members a pair (1000 --full), and arbitrary tuples
//   zrule     every v in [2^-126, 2^-125) x 2 signs against +-0 both ways round (--full; quick 300k), the one-bit
//             mantissas of D2 in every representation, -0 + -0
//   withzero  every depth in [2^-126, 2^-125) x 2 signs against a zero of random fraction and sign (--full; quick 300k)
//   addinf    exponent-field-255 pairs with equal, larger and smaller fractions, both signs
//   boundary  products and sums that land at 2^128 and 2^-126 exactly and one unit either side
//   recip     determinants of every class: bad, zero, above 2^126, tiny, random
//   stream    random cases with random gap clocks
#include <memory>

#include "Vp2_fp_range_tb_top.h"
#include "fp_tb.h"
#include "ref_copies.h"
#include "vecgen.h"

using namespace fptb;
using namespace p2fpref;
typedef Vp2_fp_range_tb_top Top;

enum { LIM_PRODUCT, LIM_SUM, LIM_UNDER, LIM_BELOW };
enum { ADD_NONE, ADD_DEPTH, ADD_TSP, ADD_MIP };
enum { KIND_NUMBER, KIND_INF, KIND_ZERO };

static uint64_t g_d2 = 0, g_d2CopyOther = 0;   // num D2 cases met, and those where this build's copy is not +0

// num D2: exactly one operand zero, the other a one-bit mantissa at 2^-126 of the other sign (no bad operand)
static bool d2(const Fp& p, const Fp& q)
{
    if (p.bad || q.bad || p.zero() == q.zero())
        return false;
    const Fp& v = p.zero() ? q : p;
    const bool zneg = p.zero() ? p.neg : q.neg;
    return bl(v.mant) == 1 && v.top() - 1 == -126 && zneg != v.neg;
}

struct Case {
    Fp a, b;
    uint32_t af = 0, bf = 0, zbits = 0;
    unsigned limMode = 0, addMode = 0;
    bool mulRanged = false, recipMip = false;
    // directed: the console's values (when set)
    bool litAdd = false, litMul = false, litWz = false, litRcp = false;
    Fp litAddV, litMulV, litWzV, litRcpV;

    void drive(Top* t) const
    {
        FP_SET(t, a, a);
        FP_SET(t, b, b);
        t->a_frac = af;
        t->b_frac = bf;
        t->zbits = zbits;
        t->lim_mode = limMode;
        t->mul_ranged = mulRanged;
        t->add_mode = addMode;
        t->recip_mip = recipMip;
    }
    void check(Top* t, Fails& f) const
    {
        auto in = [&] {
            char m[160];
            snprintf(m, sizeof m, "; af 0x%x bf 0x%x zbits 0x%08x lim %u add %u mulRanged %d recipMip %d", af, bf, zbits,
                     limMode, addMode, mulRanged, recipMip);
            return "a " + str(a) + " b " + str(b) + m;
        };
        // the generator's domain: every operand fits its port
        expect(f, mantFits(a.mant, 24) && mantFits(b.mant, 24) && expFits(a.exp) && expFits(b.exp),
               [&] { return "generator: an operand does not fit its port: " + in(); });
        // lim
        {
            Fp w;
            const char* n;
            switch (limMode) {
            case LIM_PRODUCT: w = depth(D_LIMIT_PRODUCT, a); n = "depth limit(a, false)"; break;
            case LIM_SUM: w = depth(D_LIMIT_SUM, a); n = "depth limit(a, true)"; break;
            case LIM_UNDER: w = depth(D_UNDER, a); n = "depth under(a)"; break;
            default: w = mip(M_INV2_BELOW, a); n = "mip below(inv2)"; break;
            }
            expectFp(f, n, w, FP_GET(t, lim), 24, in);
        }
        // mul
        {
            const Fp got = FP_GET(t, mul);
            if (!mulRanged)
                expectFp(f, "edge Mul(a, b, 24)", pvrfp::Mul(a, b, pvrfp::C<24>{}), got, 24, in);
            else {
                expectFp(f, "depth mul", depth(D_MUL, a, b), got, 24, in);
                expectFp(f, "TSP mul", tsp(T_MUL, a, b), got, 24, in);
                expectFp(f, "mip rmul", mip(M_RMUL, a, b), got, 24, in);
            }
            if (litMul)
                expectFp(f, "console: product", litMulV, got, 24, in);
        }
        // add, reach 25
        {
            const Fp got = FP_GET(t, add);
            switch (addMode) {
            case ADD_NONE: expectFp(f, "edge Add(a, b, 24, 25)", pvrfp::Add(a, b, pvrfp::C<24>{}, pvrfp::C<25>{}), got, 24, in); break;
            case ADD_DEPTH: {
                const Fp copy = depth(D_ADD, a, b);
                if (d2(a, b)) {
                    g_d2++;
                    if (!(copy.zero() && !copy.neg && !copy.bad))
                        g_d2CopyOther++;
                    expectFp(f, "depth add (num D2: +0)", Fp(), got, 24, in);
                } else
                    expectFp(f, "depth add", copy, got, 24, in);
                break;
            }
            case ADD_TSP:
                expectFp(f, "TSP addTerm(a, b, false)", tsp(T_ADD, a, b), got, 24, in);
                expectFp(f, "TSP addTerm(a, b, true)", tsp(T_ADD3, a, b), got, 24, in);
                break;
            default: break;   // MIP: radd has no site at reach 25
            }
            if (litAdd)
                expectFp(f, "console: sum", litAddV, got, 24, in);
        }
        // add, reach 53
        {
            const Fp got = FP_GET(t, a53);
            if (addMode == ADD_NONE)
                expectFp(f, "Add(a, b, 24, 53)", pvrfp::Add(a, b, 24, 53), got, 24, in);
            else if (addMode == ADD_MIP)
                expectFp(f, "mip radd", mip(M_RADD, a, b), got, 24, in);
        }
        // the depth mean's addBad
        {
            const Fp copy = depth(D_ADDBAD, a, b, af, bf);
            const bool viaAdd = !(a.bad && b.bad && a.neg != b.neg && af != bf);
            if (viaAdd && d2(a, b)) {
                g_d2++;
                expectFp(f, "depth addBad (num D2: +0)", Fp(), FP_GET(t, ainf), 24, in);
            } else
                expectFp(f, "depth addBad", copy, FP_GET(t, ainf), 24, in);
        }
        // kind
        {
            int k = 0;
            const Fp prod = mip(M_KIND, a, b, &k);
            const unsigned want = k < 0 ? KIND_ZERO : k > 0 ? KIND_INF : KIND_NUMBER;
            expect(f, t->kind == want, [&] { return "mip kind " + std::to_string(t->kind) + ", want " + std::to_string(want) + ": " + in(); });
            expectFp(f, "mip kind's Mul(a, b, 24)", prod, FP_GET(t, kp), 24, in);
        }
        // the reciprocal wrappers
        {
            const Fp got = FP_GET(t, rcp);
            const bool zeroDet = a.zero() && !a.bad;
            if (recipMip)
                expectFp(f, "mip inv", mip(M_RECIP, a), got, 24, in);
            else if (!zeroDet)
                expectFp(f, "TSP inv", tsp(T_RECIP, a), got, 24, in);
            if (litRcp)
                expectFp(f, "console: reciprocal", litRcpV, got, 24, in);
        }
        // withZero
        {
            const Fp got = FP_GET(t, wz);
            expectFp(f, "TSP withZero", tsp(T_WITHZERO, a, Fp(), zbits), got, 24, in);
            if (litWz)
                expectFp(f, "console: withZero", litWzV, got, 24, in);
        }
    }
};

// a random tuple of any representation within the tops that keep every product's exponent in the field
static Fp arbitrary(Gen& g) { return g.num((int)g.r.range(1, 24), -230, 230, 80, 40, 200); }

// the raw fraction of a bad operand (an exponent-field-255 corner), 0 for a finite one
static uint32_t fracOf(const Fp& v, Gen& g) { return v.bad ? (g.r.chance(200) ? 0 : g.r.u32() & 0x7FFFFF) : 0; }

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-range", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-range");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x726e67);
    // the modes of case i (every combination over 64 consecutive cases)
    auto modes = [](Case& c, uint64_t i) {
        c.addMode = (unsigned)(i % 4);
        c.limMode = (unsigned)((i / 4) % 4);
        c.mulRanged = (i / 16) % 2;
        c.recipMip = (i / 32) % 2;
    };
    auto basic = [&](const Fp& x, const Fp& y, uint64_t i, Gen& g) {
        Case c;
        c.a = x;
        c.b = y;
        c.af = fracOf(x, g);
        c.bf = (x.bad && y.bad && g.r.chance(300)) ? c.af : fracOf(y, g);
        c.zbits = (g.r.u32() & 0x807FFFFF);
        modes(c, i);
        return c;
    };

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            p2tb::Rng r(a.seed);
            Gen g(r);
            auto sum = [&](const Fp& x, const Fp& y, unsigned mode, const Fp& v) {
                Case c = basic(x, y, 0, g);
                c.addMode = mode;
                c.litAdd = true;
                c.litAddV = v;
                ls.push(c);
            };
            auto prod = [&](const Fp& x, const Fp& y, const Fp& v) {
                Case c = basic(x, y, 0, g);
                c.mulRanged = true;
                c.litMul = true;
                c.litMulV = v;
                ls.push(c);
            };
            const Fp pz = mk(false, false, 0, 0), nz = mk(true, false, 0, 0);
            auto u126 = [](bool neg, uint64_t m) { return mk(neg, false, -149, m); };   // m 2^-149: 0x800000 is 2^-126
            // depthgaps_zadd (708fb8cd): the zero rule in every addition of the depth setup
            sum(nz, u126(false, 0xA00000), ADD_DEPTH, pz);                    // -0 + 1.25 2^-126 = +0
            sum(pz, u126(false, 0xA00000), ADD_DEPTH, u126(false, 0xA00000)); // +0 + 1.25: kept
            sum(nz, u126(false, 0xE00000), ADD_DEPTH, u126(false, 0xE00000)); // -0 + 1.75: kept
            sum(nz, nz, ADD_DEPTH, pz);                                       // -0 + -0 = +0
            sum(pz, u126(true, 0x800000), ADD_DEPTH, pz);                     // +0 - 2^-126 = +0
            sum(pz, u126(true, 0xA00000), ADD_DEPTH, pz);                     // +0 - 1.25 2^-126
            sum(u126(true, 0xBFFFFE), pz, ADD_DEPTH, pz);                     // -(1.5 - 2^-22) 2^-126 + 0
            sum(pz, u126(true, 0xC00000), ADD_DEPTH, u126(true, 0xC00000));   // -1.5 2^-126: kept
            // the TSP's zero rule (tsp2_zadd, 4f3efe15): as the depth setup's, in every addition of the sum
            sum(u126(true, 0xA00000), pz, ADD_TSP, pz);                       // -1.25 2^-126 + 0 = +0 (cmeas cwext1)
            sum(pz, u126(false, 0xA00000), ADD_TSP, u126(false, 0xA00000));   // +0 + 1.25: kept (same sign)
            sum(nz, u126(false, 0xA00000), ADD_TSP, pz);                      // -0 + 1.25 = +0
            sum(nz, u126(false, 0xE00000), ADD_TSP, u126(false, 0xE00000));   // -0 + 1.75: kept
            sum(nz, nz, ADD_TSP, pz);                                         // -0 + -0 = +0
            sum(mk(false, false, 0, 3), mk(true, false, 0, 3), ADD_TSP, pz);  // x - x = +0
            // MipSelect's radd: no zero rule, -0 + -0 = -0 (at reach 53; reach 25 is unchecked in MIP mode)
            sum(nz, nz, ADD_MIP, nz);
            sum(nz, u126(false, 0xA00000), ADD_MIP, u126(false, 0xA00000));
            // infinities (uvmeas wspec): +inf + -inf = +0, inf + x = inf
            sum(mk(false, true, 0, 0), mk(true, true, 0, 0), ADD_TSP, pz);
            sum(mk(false, true, 0, 0), mk(true, true, 0, 0), ADD_DEPTH, pz);
            sum(mk(true, true, 0, 0), mk(false, false, 3, 5), ADD_TSP, mk(true, true, 0, 0));
            // 2^127 + 2^127 = 2^128: an infinity (zovf_lim); the edge flavour keeps it
            sum(mk(false, false, 104, 0x800000), mk(false, false, 104, 0x800000), ADD_DEPTH, mk(false, true, 0, 0));
            sum(mk(false, false, 104, 0x800000), mk(false, false, 104, 0x800000), ADD_NONE, mk(false, false, 105, 0x800000));
            // products: inf * 0 = 0 with the sign (uvmeas wspec), inf * x = inf, 2^127 * 2 = 2^128 (zovf_ps), below
            // 2^-126 a zero of its sign
            prod(mk(false, true, 0, 0), nz, nz);
            prod(mk(false, true, 0, 0), mk(true, false, 0, 2), mk(true, true, 0, 0));
            prod(mk(false, false, 104, 0x800000), mk(false, false, -22, 0x800000), mk(false, true, 0, 0));
            prod(mk(false, false, 104, 0xFFFFFF), mk(false, false, -23, 0x800000), mk(false, false, 104, 0xFFFFFF));
            prod(mk(false, false, -123, 0x800000), mk(true, false, -53, 0x800000), nz);
            // trsort_recip pages 3, 11 (4f3efe15): the TSP's reciprocal of a determinant of exactly +-2^126 is a zero of
            // its sign; of 2^126 (1 - 2^-24) it is kept (page 2)
            auto rcp = [&](const Fp& d, bool mipSite, const Fp& v) {
                Case c = basic(d, pz, 0, g);
                c.recipMip = mipSite;
                c.litRcp = true;
                c.litRcpV = v;
                ls.push(c);
            };
            rcp(mk(false, false, 103, 0x800000), false, pz);
            rcp(mk(true, false, 103, 0x800000), false, nz);
            rcp(mk(false, false, 103, 0x800001), false, pz);
            {
                const Fp d = mk(false, false, 102, 0xFFFFFF);
                rcp(d, false, pvrfp::Recip(d, 24));
            }
            rcp(nz, true, pz);                                                // MipSelect: det 0 gives +0
            // slivers_dzzero: on the boundary the depth is kept; one unit more and the sum is +0
            {
                Case c = basic(u126(false, 0xC00000), pz, 0, g);
                c.zbits = 0x80000000;
                c.litWz = true;
                c.litWzV = u126(false, 0xC00000);
                ls.push(c);
                c.zbits = 0x80000001;
                c.litWzV = pz;
                ls.push(c);
            }
        }
        sectionDone("fp-range", "directed", ls.cases() - n0);
    }
    if (a.want("classes")) {
        f.set("classes");
        const uint64_t n0 = ls.cases();
        const uint64_t members = a.full ? 1000 : 100;
        const uint64_t pairs = Gen::RC_N * Gen::RC_N;
        for (uint64_t i = 0; i < pairs * members * 2; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed, i);
                Gen g(r);
                const uint64_t p = i % pairs, m = i / pairs;
                Fp x, y;
                if (m < members) {
                    x = g.ranged((int)(p % Gen::RC_N));
                    y = g.ranged((int)(p / Gen::RC_N));
                } else {   // arbitrary tuples, unnormalized, bad with a mantissa
                    x = arbitrary(g);
                    y = arbitrary(g);
                }
                ls.push(basic(x, y, m, g));
            }
        sectionDone("fp-range", "classes", ls.cases() - n0);
    }
    if (a.want("zrule")) {
        f.set("zrule");
        const uint64_t n0 = ls.cases();
        auto one = [&](uint64_t i, Gen& g) {
            const uint64_t m = 0x800000 | (i & 0x7FFFFF);
            const bool vneg = (i >> 23) & 1, zneg = (i >> 24) & 1, swap = (i >> 25) & 1;
            Fp v = mk(vneg, false, -149, m), z = mk(zneg, false, (int)g.r.range(-200, 200), 0);
            Case c = basic(swap ? z : v, swap ? v : z, i, g);
            c.addMode = g.r.chance(500) ? ADD_TSP : ADD_DEPTH;
            ls.push(c);
        };
        if (a.full) {
            uint64_t lo, hi;
            a.range(1ull << 26, &lo, &hi);
            p2tb::Rng r(a.seed ^ lo);
            Gen g(r);
            for (uint64_t i = lo; i < hi; i++)
                one(i, g);
        } else {
            const uint64_t n = a.count(300000);
            for (uint64_t i = 0; i < n; i++)
                if (a.mine(i)) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x2e, i);
                    Gen g(r);
                    one(g.r.below(1ull << 26), g);
                }
        }
        // D2: 2^-126 as a one-bit mantissa and in every other representation, against +-0 both ways; -0 + -0
        if (a.mine(0)) {
            p2tb::Rng r(a.seed ^ 0xd2);
            Gen g(r);
            for (int k = 0; k < 24; k++)
                for (int s = 0; s < 8; s++) {
                    const Fp v = mk(s & 1, false, -126 - k, 1ull << k), z = mk(s & 2, false, 0, 0);
                    for (unsigned mode = 0; mode < 4; mode++) {
                        Case c = basic((s & 4) ? z : v, (s & 4) ? v : z, 0, g);
                        c.addMode = mode;
                        ls.push(c);
                    }
                }
            for (unsigned mode = 0; mode < 4; mode++) {
                Case c = basic(mk(true, false, 0, 0), mk(true, false, 0, 0), 0, g);
                c.addMode = mode;
                ls.push(c);
            }
        }
        sectionDone("fp-range", "zrule", ls.cases() - n0);
    }
    if (a.want("withzero")) {
        f.set("withzero");
        const uint64_t n0 = ls.cases();
        auto one = [&](uint64_t i, Gen& g) {
            const uint64_t m = 0x800000 | (i & 0x7FFFFF);
            const bool neg = (i >> 23) & 1;
            Case c = basic(mk(neg, false, -149, m), Fp(), i, g);
            // a zero of the other sign mostly, of either fraction; the boundary P - Z = 2^24 half the time
            const bool zneg = g.r.chance(800) ? !neg : neg;
            uint32_t fr = g.r.u32() & 0x7FFFFF;
            if (g.r.chance(500)) {
                const int64_t d = (int64_t)(m << 1) - (1 << 24) - (1 << 23) + (int64_t)g.r.range(-1, 1);
                if (d >= 0 && d <= 0x7FFFFF)
                    fr = (uint32_t)d;
            }
            c.zbits = (zneg ? 0x80000000u : 0) | fr;
            ls.push(c);
        };
        if (a.full) {
            uint64_t lo, hi;
            a.range(1ull << 24, &lo, &hi);
            p2tb::Rng r(a.seed ^ lo);
            Gen g(r);
            for (uint64_t i = lo; i < hi; i++)
                one(i, g);
        } else {
            const uint64_t n = a.count(300000);
            for (uint64_t i = 0; i < n; i++)
                if (a.mine(i)) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x3e, i);
                    Gen g(r);
                    one(g.r.below(1ull << 24), g);
                }
        }
        // other depths: outside the binade, zero, bad, unnormalized ones inside it
        const uint64_t n = a.full ? 1000000 : 100000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x3f, i);
                Gen g(r);
                Fp p = (i & 1) ? Gen::at(g.mant(24), (int)g.r.range(-127, -123), g.r.u64() & 1) : g.rangedAny();
                Case c = basic(p, Fp(), i, g);
                c.zbits = g.r.u32() & 0x807FFFFF;
                ls.push(c);
            }
        sectionDone("fp-range", "withzero", ls.cases() - n0);
    }
    if (a.want("addinf")) {
        f.set("addinf");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.full ? 1000000 : 50000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xaf, i);
                Gen g(r);
                Fp x = mk(i & 1, true, 0, 0), y = (i & 4) ? mk(i & 2, true, 0, 0) : g.rangedAny();
                Case c = basic(x, y, i, g);
                c.af = g.r.u32() & 0x7FFFFF;
                switch ((i >> 3) % 3) {
                case 0: c.bf = y.bad ? c.af : 0; break;                                      // equal fractions
                case 1: c.bf = y.bad ? (c.af ? c.af - (uint32_t)g.r.range(1, c.af) : 0) : 0; break;   // smaller
                default: c.bf = y.bad ? std::min<uint32_t>(0x7FFFFF, c.af + (uint32_t)g.r.range(1, 0x1000)) : 0;   // larger
                }
                if (i & 8)
                    std::swap(c.a, c.b), std::swap(c.af, c.bf);
                ls.push(c);
            }
        sectionDone("fp-range", "addinf", ls.cases() - n0);
    }
    if (a.want("boundary")) {
        f.set("boundary");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 4000000 : 400000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xb0, i);
                Gen g(r);
                const bool high = i & 1;
                Fp x, y;
                if (i & 2) {
                    // a product at 2^128 / 2^-126: tops summing to the boundary's top, +-1; powers of two land exactly
                    const int T = high ? 129 : -125;
                    const uint64_t mx = (i & 4) ? 1ull << g.r.below(24) : g.mant(24);
                    const uint64_t my = (i & 8) ? 1ull << g.r.below(24) : g.mant(24);
                    const int tx = (int)g.r.range(high ? 2 : -124, high ? 127 : -2);
                    x = Gen::at(mx, tx, g.r.u64() & 1);
                    y = Gen::at(my, T - tx + 1 + (int)g.r.range(-1, 1), g.r.u64() & 1);
                } else if (high || !(i & 8)) {
                    // a sum at 2^128 / 2^-126: x just under the boundary, y the rest of the way, +-1 unit
                    const int T = high ? 128 : -125;
                    x = Gen::at((i & 4) ? 0xFFFFFF : g.mant(24), T, false);
                    const uint64_t rem = (1ull << bl(x.mant)) - x.mant + (uint64_t)g.r.range(-1, 1);
                    y = rem && bl(rem) <= 24 ? mk(false, false, x.exp, rem) : g.rangedAny();
                    if (g.r.u64() & 1)
                        x.neg = y.neg = true;
                } else {
                    // a difference that lands at 2^-126 or one unit under it: x in [2^-125, 2^-124) (units of
                    // 2^-148, 2^-126 is 0x400000 of them), y = x - 2^-126 +- 1 unit of the other sign
                    x = Gen::at(g.mantN(24), -124, false);
                    y = mk(true, false, x.exp, x.mant - 0x400000 + (uint64_t)g.r.range(-1, 1));
                    if (g.r.u64() & 1)
                        x.neg = !x.neg, y.neg = !y.neg;
                }
                ls.push(basic(x, y, i, g));
            }
        sectionDone("fp-range", "boundary", ls.cases() - n0);
    }
    if (a.want("recip")) {
        f.set("recip");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 2000000 : 200000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x1e, i);
                Gen g(r);
                Fp d;
                switch (i % 6) {
                case 0: d = mk(g.r.u64() & 1, true, 0, 0); break;                          // bad
                case 1: d = mk(g.r.u64() & 1, false, (int)g.r.range(-200, 200), 0); break; // zero
                case 2: d = Gen::at(g.mant(24), (int)g.r.range(126, 129), g.r.u64() & 1); break;   // reciprocal below
                case 3: d = Gen::at(g.mant(24), (int)g.r.range(-130, -120), g.r.u64() & 1); break;
                default: d = g.rangedAny();
                }
                Case c = basic(d, g.rangedAny(), i, g);
                ls.push(c);
            }
        sectionDone("fp-range", "recip", ls.cases() - n0);
    }
    if (a.want("stream")) {
        f.set("stream");
        const uint64_t n0 = ls.cases();
        ls.gaps(300);
        const uint64_t n = a.full ? 2000000 : 200000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x5157, i);
                Gen g(r);
                const Fp x = (i & 1) ? g.rangedAny() : arbitrary(g), y = (i & 2) ? g.rangedAny() : arbitrary(g);
                ls.push(basic(x, y, g.r.u64(), g));
            }
        ls.gaps(0);
        sectionDone("fp-range", "stream", ls.cases() - n0);
    }
    printf("fp-range: num D2 cases (one-bit mantissa at 2^-126 against a zero of the other sign, depth add): %llu, the "
           "copy computed something else in %llu\n",
           (unsigned long long)g_d2, (unsigned long long)g_d2CopyOther);
    top->final();
    return f.finish();
}

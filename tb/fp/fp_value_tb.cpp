// fp_value_tb.cpp: make fp-value. H12a p2_fp_value_norm against refcore pvr_tsp_plane.h PlaneT::Value at 708fb8cd
// (docs/spec/numerics.md H12a, 7.3; PLAN M1b): bare against the verbatim copy of the normalizer (tb/fp/ref_copies.h
// p2fpref::valueNorm, L377-397), and in place: PlaneT<PlaneHW>::Value itself (public) against the RTL fed with the k and
// the grid of Value's own integer part (p2fpref::valueK, the verbatim copy of L311-369).
//
// Sections (--only):
//   directed  console facts as literal tuples: uvmeas wzero1 (k = -1 is -2^-143 whatever the grid), 0 stays +0, the
//             valueFixed table (16 bits from the leading one, toward minus infinity: a negative that loses bits goes up a
//             unit in size, 0xFFFF... to 2^16), wtiny (the -128 floor: the mantissa kept, the exponent lifted)
//   exh       every k in [-2^20, 2^20] x unit in -170 .. -100 and 0 (--full; quick: every 97th k)
//   rand      random 27-bit k (|k| < 2^26) x unit -170 .. 130
//   inplace   random planes (16-bit coefficients of the ranged setup: zeros, bad, tops -125 .. 128) at random pixels,
//             ordinary and SupSample (hx, hy), through Value; |k| < 2^26 asserted (num H11's 27-bit accumulator)
//   stream    random k with random gap clocks
#include <memory>

#include "Vp2_fp_value_tb_top.h"
#include "fp_tb.h"
#include "ref_copies.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_value_tb_top Top;

namespace {

uint64_t g_kOut = 0, g_floor = 0, g_carry = 0;

struct Case {
    int64_t k = 0;
    int unit = 0;
    bool hasWant = false;    // in place: Value's own result; directed: a literal
    Fp want;
    std::string where;

    void drive(Top* t) const
    {
        t->k = (uint32_t)k & 0x7ffffffu;
        t->unit = efield(unit);
    }
    std::string in() const
    {
        return "k " + std::to_string(k) + " unit " + std::to_string(unit) + (where.empty() ? "" : " (" + where + ")");
    }
    void check(Top* t, Fails& f) const
    {
        auto what = [&] { return in(); };
        if (k >= ((int64_t)1 << 26) || k < -((int64_t)1 << 26))
            g_kOut++;
        const Fp ref = p2fpref::valueNorm(k, unit);
        if (!ref.zero() && ref.exp != unit + std::max(0, pvrfp::BitLength((uint64_t)std::llabs(k)) - 16))
            g_floor++;
        if (ref.mant == (1u << 16))
            g_carry++;
        const Fp got = FP_GET(t, v);
        expectFp(f, "value_norm", ref, got, 17, what);
        if (hasWant)
            expectFp(f, where.empty() ? "literal" : "PlaneT::Value", want, got, 17, what);
    }
};

Fp coef(Gen& g)
{
    const bool neg = g.r.u64() & 1;
    if (g.r.chance(60))
        return mk(neg, false, 0, 0);
    if (g.r.chance(30))
        return mk(neg, true, 0, 0);
    return Gen::at(g.mant(16), g.top(-125, 128), neg);
}

}   // namespace

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-value", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-value");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x7a1);
    auto push = [&](int64_t k, int unit) {
        Case c;
        c.k = k;
        c.unit = unit;
        ls.push(c);
    };
    auto lit = [&](int64_t k, int unit, const Fp& want) {
        Case c;
        c.k = k;
        c.unit = unit;
        c.hasWant = true;
        c.want = want;
        ls.push(c);
    };

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            lit(-1, -30, mk(true, false, -143, 1));          // wzero1: -2^-143, whatever the grid
            lit(-1, 100, mk(true, false, -143, 1));
            lit(0, -30, mk(false, false, 0, 0));             // 0 stays +0
            lit(0x12345, 0, mk(false, false, 1, 0x91a2));    // 17 bits: the last one dropped
            lit(-0x12345, 0, mk(true, false, 1, 0x91a3));    // below zero: toward minus infinity
            lit(-0x1fffe, 4, mk(true, false, 5, 0xffff));    // nothing lost
            lit(-0x1ffff, 4, mk(true, false, 5, 0x10000));   // 0xffff and a lost bit: 2^16
            lit(0x1ffff, 4, mk(false, false, 5, 0xffff));
            lit(3, -140, mk(false, false, -129, 3));         // wtiny: top - 1 = -139 lifted to -128, mantissa kept
            lit(-3, -140, mk(true, false, -129, 3));
            lit(1, -128, mk(false, false, -128, 1));         // exactly at the floor: kept
            lit(1, -129, mk(false, false, -128, 1));
        }
        sectionDone("fp-value", "directed", ls.cases() - n0);
    }
    if (a.want("exh")) {
        f.set("exh");
        const uint64_t n0 = ls.cases();
        const int64_t step = a.full ? 1 : 97;
        uint64_t i = 0;
        for (int64_t k = -((int64_t)1 << 20); k <= ((int64_t)1 << 20); k += step)
            for (int u = -171; u <= -100; u++, i++)
                if (a.mine(i))
                    push(k, u == -171 ? 0 : u);
        sectionDone("fp-value", "exh", ls.cases() - n0);
    }
    if (a.want("rand")) {
        f.set("rand");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 30000000 : 1000000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x4a, i);
                const int b = (int)r.range(0, 26);
                int64_t k = (int64_t)(r.u64() & (((uint64_t)1 << b) - 1));
                if (r.chance(100))
                    k = ((int64_t)1 << b) - 1;              // all ones: the carry to 2^16 below zero
                push(r.u64() & 1 ? -k : k, (int)r.range(-170, 130));
            }
        sectionDone("fp-value", "rand", ls.cases() - n0);
    }
    if (a.want("inplace")) {
        f.set("inplace");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 5000000 : 300000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x1b, i);
                Gen g(r);
                pvrtsp::PlaneT<pvrtsp::PlaneHW> p;
                p.A = coef(g);
                p.B = coef(g);
                p.C = coef(g);
                const int tl = 32 * (int)g.r.below(40), tt = 32 * (int)g.r.below(30);
                const int col = (int)g.r.below(32), row = (int)g.r.below(32);
                const int n1 = (int)g.r.below(32 - col);
                const bool super = g.r.chance(300);
                const int hx = super ? (int)(g.r.u64() & 1) : 0, hy = super ? (int)(g.r.u64() & 1) : 0;
                const int64_t x0h = 2 * (int64_t)(tl + col) + 1, yh = 2 * (int64_t)(tt + row) + 1;
                int unit = 0;
                Case c;
                c.k = p2fpref::valueK(p.A, p.B, p.C, x0h, yh, n1, tl, tt, super, hx, hy, &unit);
                c.unit = unit;
                c.hasWant = true;
                c.want = p.Value(x0h, yh, n1, tl, tt, super, hx, hy);
                c.where = "A " + str(p.A) + " B " + str(p.B) + " C " + str(p.C);
                ls.push(c);
            }
        sectionDone("fp-value", "inplace", ls.cases() - n0);
    }
    if (a.want("stream")) {
        f.set("stream");
        const uint64_t n0 = ls.cases();
        ls.gaps(300);
        const uint64_t n = a.full ? 2000000 : 200000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x5e, i);
                const int b = (int)r.range(0, 26);
                const int64_t k = (int64_t)(r.u64() & (((uint64_t)1 << b) - 1));
                push(r.u64() & 1 ? -k : k, (int)r.range(-170, 130));
            }
        ls.gaps(0);
        sectionDone("fp-value", "stream", ls.cases() - n0);
    }
    printf("fp-value: classes: %llu at the -128 floor, %llu carried to 2^16\n", (unsigned long long)g_floor,
           (unsigned long long)g_carry);
    f.ok(g_kOut == 0, "%llu k outside the 27-bit accumulator (num H11)", (unsigned long long)g_kOut);
    top->final();
    return f.finish();
}

// fp_cutbelow_tb.cpp: make fp-cutbelow. H3 p2_fp_cut_below against refcore pvr_softfp.h Fp::cutBelow(e)
// (docs/spec/numerics.md H3, 7.3), at 24 and 20 bits (the 20-bit instance when the mantissa fits it).
//
// Sections (--only):
//   directed  a negative value cut to nothing is -0 (num 1.2); a value on or above the grid is unchanged
//   exh16     every 16-bit mantissa x e - exp in -4 .. 70 x both signs (--full; quick: every 61st mantissa)
//   rand24    random 24-bit tuples, e - exp in -10 .. 80, and shifts of 64 and more
//   stream    random tuples with random gap clocks
#include <memory>

#include "Vp2_fp_cutbelow_tb_top.h"
#include "fp_tb.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_cutbelow_tb_top Top;

struct Case {
    Fp in;
    int e = 0;
    void drive(Top* t) const
    {
        FP_SET(t, i, in);
        t->e = efield(e);
    }
    void check(Top* t, Fails& f) const
    {
        const Fp want = in.cutBelow(e);
        auto what = [&] { return str(in) + " cutBelow " + std::to_string(e); };
        expectFp(f, "cutBelow24", want, FP_GET(t, b24), 24, what);
        if (mantFits(in.mant, 20))
            expectFp(f, "cutBelow20", want, FP_GET(t, b20), 20, what);
    }
};

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-cutbelow", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-cutbelow");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x6362);
    auto push = [&](const Fp& v, int e) {
        Case c;
        c.in = v;
        c.e = e;
        ls.push(c);
    };
    // an exponent and a grid within the field
    auto pick = [&](p2tb::Rng& r, uint64_t m, int d) {
        int ex = (int)r.range(-400, 400);
        if (ex + d > 511 || ex + d < -512)
            ex = -d / 2;
        push(mk(r.u64() & 1, r.chance(30), ex, m), ex + d);
    };

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            push(mk(true, false, -5, 3), 0);        // -3 2^-5 onto 2^0: -0 (the sign kept)
            push(mk(false, false, -5, 0x30), 0);    // 1.5 onto 2^0: 1
            push(mk(true, false, 4, 0xFFF), 4);     // on the grid: unchanged
            push(mk(true, false, 9, 0xFFF), 4);     // above it: unchanged
            push(mk(false, true, -200, 0xABCDEF), 102);   // a shift beyond 64: 0, flag kept
            push(mk(true, false, -149, 0x7FFFFF), -149 + 63);
            push(mk(true, false, -149, 0x7FFFFF), -149 + 64);
        }
        sectionDone("fp-cutbelow", "directed", ls.cases() - n0);
    }
    if (a.want("exh16")) {
        f.set("exh16");
        const uint64_t n0 = ls.cases();
        const uint64_t step = a.full ? 1 : 61;
        for (uint64_t m = 0; m < 65536; m += step)
            if (a.mine(m / step))
                for (int d = -4; d <= 70; d++)
                    for (int s = 0; s < 2; s++) {
                        p2tb::Rng r = p2tb::Rng::of(a.seed, (m * 75 + (uint64_t)(d + 4)) * 2 + s);
                        const int ex = (int)r.range(-300, 300);
                        push(mk(s != 0, r.chance(30), ex, m), ex + d);
                    }
        sectionDone("fp-cutbelow", "exh16", ls.cases() - n0);
    }
    if (a.want("rand24")) {
        f.set("rand24");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 5000000 : 500000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x24, i);
                Gen g(r);
                const uint64_t m = g.r.chance(30) ? 0 : g.mant(24);
                const int d = g.r.chance(100) ? (int)g.r.range(64, 300) : (int)g.r.range(-10, 80);
                pick(g.r, m, d);
            }
        sectionDone("fp-cutbelow", "rand24", ls.cases() - n0);
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
                const uint64_t m = g.r.chance(50) ? 0 : g.mant((int)g.r.range(1, 24));
                pick(g.r, m, (int)g.r.range(-30, 100));
            }
        ls.gaps(0);
        sectionDone("fp-cutbelow", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

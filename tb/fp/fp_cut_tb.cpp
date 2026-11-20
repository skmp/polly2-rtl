// fp_cut_tb.cpp: make fp-cut. H2 p2_fp_cut against refcore pvr_softfp.h Fp::cut(N) (docs/spec/numerics.md H2, 7.3), at
// every instance of p2_fp_cut_tb_top. An instance is checked when the vector's mantissa fits its input width. Every
// output is also held to the representation contract out.exp = max(in.exp, top - N) (num 1.3).
//
// Sections (--only):
//   directed  literal cuts (a zero stays as it is, nothing becomes a zero, a short mantissa is not normalized)
//   exh24     every 24-bit mantissa (--full; quick: 1M random ones) with a random sign, flag and exponent, the
//             exponent extremes of the field included
//   wide      every bit length 1 .. 64 with random tails (4096 a length --full, 64 quick)
//   stream    random tuples of every class with random gap clocks
#include <memory>

#include "Vp2_fp_cut_tb_top.h"
#include "fp_tb.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_cut_tb_top Top;

struct Inst {
    const char* name;
    int iw, n;
};
static const Inst kInst[] = {{"cut24->8", 24, 8},   {"cut24->16", 24, 16}, {"cut24->19", 24, 19},
                             {"cut24->20", 24, 20}, {"cut24->24", 24, 24}, {"cut62->24", 62, 24},
                             {"cut62->16", 62, 16}, {"cut64->62", 64, 62}, {"cut64->24", 64, 24}};
static const int kN = sizeof kInst / sizeof kInst[0];

struct Case {
    Fp in;
    void drive(Top* t) const { FP_SET(t, i, in); }
    void check(Top* t, Fails& f) const
    {
        const Fp got[kN] = {FP_GET(t, c24_8),  FP_GET(t, c24_16), FP_GET(t, c24_19), FP_GET(t, c24_20), FP_GET(t, c24_24),
                            FP_GET(t, c62_24), FP_GET(t, c62_16), FP_GET(t, c64_62), FP_GET(t, c64_24)};
        for (int i = 0; i < kN; i++) {
            if (!mantFits(in.mant, kInst[i].iw))
                continue;
            const Fp want = in.cut(kInst[i].n);
            // the contract (num 1.3): out.exp = max(in.exp, top - N) for a nonzero value
            if (want.mant) {
                const int ce = std::max(in.exp, want.top() - kInst[i].n);
                expect(f, want.exp == ce, [&] { return std::string("contract: ") + str(want) + " from " + str(in); });
            }
            expectFp(f, kInst[i].name, want, got[i], kInst[i].n, [&] { return str(in); });
        }
    }
};

// an exponent such that every cut of a mantissa of BL b fits the field: exp + (b - 8) <= 511
static int expFor(p2tb::Rng& r, int b)
{
    const int hi = 511 - std::max(b - 8, 0), lo = -512;
    switch (r.below(8)) {
    case 0: return lo;
    case 1: return hi;
    case 2: return (int)r.range(lo, lo + 8);
    case 3: return (int)r.range(hi - 8, hi);
    default: return (int)r.range(-300, std::min(300, hi));
    }
}

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-cut", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-cut");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x637574);
    auto push = [&](const Fp& v) {
        Case c;
        c.in = v;
        ls.push(c);
    };
    auto rnd = [&](p2tb::Rng& r, uint64_t m) {
        return mk(r.u64() & 1, r.chance(50), expFor(r, bl(m)), m);
    };

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            push(mk(false, false, 0, 0xFFFFFF));          // 24 bits to 20: 0xFFFFF at exp 4 (toward zero)
            push(mk(true, false, -149, 0x7FFFFF));        // a 23-bit denormal: to 20, 19, 16, 8
            push(mk(true, false, 17, 0));                 // -0 stays -0, exp as it is
            push(mk(false, true, 0, 0));                  // bad zero
            push(mk(false, false, 3, 1));                 // one bit: never normalized
            push(mk(false, false, 200, 0x800000));        // the edge unit's swamp value's neighbours
            push(mk(false, false, 0, 0x3FFFFFFFFFFFFFFFull));   // 62 ones
            push(mk(true, false, -300, ~0ull));           // 64 ones
        }
        sectionDone("fp-cut", "directed", ls.cases() - n0);
    }
    if (a.want("exh24")) {
        f.set("exh24");
        const uint64_t n0 = ls.cases();
        if (a.full) {
            uint64_t lo, hi;
            a.range(1ull << 24, &lo, &hi);
            for (uint64_t m = lo; m < hi; m++) {
                p2tb::Rng r = p2tb::Rng::of(a.seed, m);
                push(rnd(r, m));
            }
        } else {
            const uint64_t n = a.count(1000000);
            for (uint64_t i = 0; i < n; i++)
                if (a.mine(i)) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed, i);
                    push(rnd(r, r.u64() & Gen::mask(24)));
                }
        }
        sectionDone("fp-cut", "exh24", ls.cases() - n0);
    }
    if (a.want("wide")) {
        f.set("wide");
        const uint64_t n0 = ls.cases();
        const int tails = a.full ? 4096 : 64;
        for (int b = 1; b <= 64; b++)
            if (a.mine((uint64_t)b))
                for (int k = 0; k < tails; k++) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x77, (uint64_t)b * 4096 + k);
                    Gen g(r);
                    uint64_t m = (k & 3) == 0 ? Gen::mask(b) : (k & 3) == 1 ? 1ull << (b - 1) : g.mantN(b);
                    push(rnd(g.r, m));
                }
        sectionDone("fp-cut", "wide", ls.cases() - n0);
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
                const int w = (int)g.r.range(1, 64);
                const uint64_t m = g.r.chance(50) ? 0 : g.mant(w);
                push(rnd(g.r, m));
            }
        ls.gaps(0);
        sectionDone("fp-cut", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

// fp_recip_tb.cpp: make fp-recip. H8 p2_fp_recip24 against refcore pvr_softfp.h Recip(v, C<24>)
// (docs/spec/numerics.md H8, 2.9, 7.3), as DepthHW / PlaneHW recipBits instantiate it. v = 0 is undefined in refsw3
// (num D1) and is not driven here; p2_fp_rng_recip's testbench (fp-range) checks the RTL's value at the mip site.
// Every result is also checked to have exactly 24 significant bits (num 2.9).
//
// Sections (--only):
//   directed  the reciprocal unit's third: 1/3 = 0xAAAAAA 2^-25, cut down, never rounded (perpmean_word: the factor
//             0xaaaaaa is the reciprocal's, one step low); 1/1, 1/2^k exact; the divider's corners 2^23 + 1, 2^24 - 1
//   norm      every normalized mantissa x 3 exponents x 2 signs (--full; quick 1M random)
//   unnorm    every bit length 1 .. 23 x 4096 values (quick 256), unnormalized tuples of the same values
//   stream    random values with random gap clocks
#include <memory>

#include "Vp2_fp_recip_tb_top.h"
#include "fp_tb.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_recip_tb_top Top;

struct Case {
    Fp v;
    bool lit = false;
    Fp litv;
    void drive(Top* t) const { FP_SET(t, i, v); }
    void check(Top* t, Fails& f) const
    {
        const Fp want = pvrfp::Recip(v, pvrfp::C<24>{});
        const Fp got = FP_GET(t, r);
        auto in = [&] { return "1 / " + str(v); };
        expect(f, bl(want.mant) == 24, [&] { return "num 2.9: the reciprocal " + str(want) + " has not 24 bits; " + in(); });
        expectFp(f, "recip24", want, got, 24, in);
        if (lit)
            expectFp(f, "console: recip24", litv, got, 24, in);
    }
};

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-recip", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-recip");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x726370);
    auto push = [&](const Fp& v) {
        Case c;
        c.v = v;
        ls.push(c);
    };

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            auto lit = [&](const Fp& v, const Fp& r) {
                Case c;
                c.v = v;
                c.lit = true;
                c.litv = r;
                ls.push(c);
            };
            lit(mk(false, false, 0, 3), mk(false, false, -25, 0xAAAAAA));            // 1/3, toward zero
            lit(mk(true, false, -22, 0xC00000), mk(true, false, -25, 0xAAAAAA));     // the same 3, normalized, -3
            lit(mk(false, false, 0, 1), mk(false, false, -23, 0x800000));            // 1/1
            lit(mk(false, false, 100, 0x800000), mk(false, false, -146, 0x800000));  // 1/2^123
            lit(mk(false, true, 0, 1), mk(false, true, -23, 0x800000));              // the flag passes
            push(mk(false, false, -23, 0x800001));
            push(mk(false, false, -23, 0xFFFFFF));
            push(mk(true, false, -149, 1));                                          // a denormal's reciprocal
        }
        sectionDone("fp-recip", "directed", ls.cases() - n0);
    }
    if (a.want("norm")) {
        f.set("norm");
        const uint64_t n0 = ls.cases();
        static const int exps[3] = {-23, -150, 104};
        const uint64_t total = 6ull << 23;
        auto one = [&](uint64_t i) {
            const uint64_t m = 0x800000 | (i & 0x7FFFFF);
            const int k = (int)((i >> 23) % 3);
            push(mk((i >> 23) >= 3, false, exps[k], m));
        };
        if (a.full) {
            uint64_t lo, hi;
            a.range(total, &lo, &hi);
            for (uint64_t i = lo; i < hi; i++)
                one(i);
        } else {
            const uint64_t n = a.count(1000000);
            for (uint64_t i = 0; i < n; i++)
                if (a.mine(i)) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed, i);
                    one(r.below(total));
                }
        }
        sectionDone("fp-recip", "norm", ls.cases() - n0);
    }
    if (a.want("unnorm")) {
        f.set("unnorm");
        const uint64_t n0 = ls.cases();
        const int per = a.full ? 4096 : 256;
        for (int b = 1; b <= 23; b++)
            if (a.mine((uint64_t)b))
                for (int k = 0; k < per; k++) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x55, (uint64_t)b * 4096 + k);
                    Gen g(r);
                    const uint64_t m = k == 0 ? 1ull << (b - 1) : k == 1 ? Gen::mask(b) : g.mantN(b);
                    push(mk(g.r.u64() & 1, g.r.chance(20), (int)g.r.range(-300, 250), m));
                }
        sectionDone("fp-recip", "unnorm", ls.cases() - n0);
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
                push(Gen::at(g.mant(24), g.top(-250, 250), g.r.u64() & 1));
            }
        ls.gaps(0);
        sectionDone("fp-recip", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

// fp_mul_tb.cpp: make fp-mul. H5 p2_fp_mul against refcore pvr_softfp.h Mul(a, b, N) (docs/spec/numerics.md H5, 7.3):
// the HW instance as the sites call it (Mul(a, b, C<24>)), the others with the literal int N. An instance is checked
// when both mantissas fit its widths. Every nonzero result is held to the contract out.exp = max(a.exp + b.exp,
// top - N) (num 1.3), and refsw3's cut of each operand to 32 bits is asserted never to act (A4).
//
// Sections (--only):
//   directed  console facts: (z + z) + z times OneThird = 0xAAAAAB 2^-25 is z again (a flat triangle reads its own
//             depth: perpmean_word, slivers_detzero; 0xAAAAAA, the reciprocal unit's third, is one step low); a zero
//             product keeps the xor of the signs (num 1.2); a bad operand gives a zero flagged bad
//   exh10     every pair of 10-bit mantissas x 3 exponent offsets (--full; quick: 300k random pairs)
//   exh8      every pair of 8-bit mantissas (0 included)
//   const     the constants 0xAAAAAB 2^-25 and 0x95F612 2^-24 x every normalized 24-bit mantissa (--full; quick 2^18)
//   rand24    24 x 24 from num 7.2's classes, products crossing a bit boundary, both signs, zeros, bad (2M; 20M --full)
//   tsp16x13  every coordinate 0 .. 2^13 x 512 coefficients (--full; quick 16)
//   fog8x16   every 8 x 16 pair (--full; quick 2^18 random)
//   bias24x5  24-bit values x 1 .. 31
//   stream    random pairs of every shape with random gap clocks
#include <memory>

#include "Vp2_fp_mul_tb_top.h"
#include "fp_tb.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_mul_tb_top Top;

struct Inst {
    const char* name;
    int aw, bw, n;
};
static const Inst kInst[] = {{"mul24x24->24", 24, 24, 24}, {"mul24x24->48", 24, 24, 48}, {"mul10x10->10", 10, 10, 10},
                             {"mul8x8->8", 8, 8, 8},       {"mul24x5->8", 24, 5, 8},     {"mul16x13->29", 16, 13, 29},
                             {"mul8x16->24", 8, 16, 24}};
static const int kN = sizeof kInst / sizeof kInst[0];

static Fp ref(const Fp& x, const Fp& y, int n)
{
    if (n == 24)
        return pvrfp::Mul(x, y, pvrfp::C<24>{});   // the HW instance (EdgeHW / DepthHW / PlaneHW productBits)
    return pvrfp::Mul(x, y, n);
}

struct Case {
    Fp a, b;
    bool lit = false;
    Fp litv;   // directed: the console's value of the 24x24 product
    void drive(Top* t) const
    {
        FP_SET(t, a, a);
        FP_SET(t, b, b);
    }
    void check(Top* t, Fails& f) const
    {
        const Fp got[kN] = {FP_GET(t, m24),   FP_GET(t, m48),    FP_GET(t, m10),  FP_GET(t, m8),
                            FP_GET(t, m24x5), FP_GET(t, m16x13), FP_GET(t, m8x16)};
        auto in = [&] { return str(a) + " x " + str(b); };
        // A4: refsw3's cut_32 of the operands never acts
        expect(f, bl(a.mant) <= 32 && bl(b.mant) <= 32, [&] { return "A4: an operand above 32 bits: " + in(); });
        for (int i = 0; i < kN; i++) {
            if (!mantFits(a.mant, kInst[i].aw) || !mantFits(b.mant, kInst[i].bw))
                continue;
            const Fp want = ref(a, b, kInst[i].n);
            if (want.mant) {
                const int ce = std::max(a.exp + b.exp, want.top() - kInst[i].n);
                expect(f, want.exp == ce, [&] { return "contract: " + str(want) + " from " + in(); });
            }
            expectFp(f, kInst[i].name, want, got[i], kInst[i].n, in);
        }
        if (lit)
            expectFp(f, "console: mul24", litv, got[0], 24, in);
    }
};

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-mul", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-mul");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x6d756c);
    auto push = [&](const Fp& x, const Fp& y) {
        Case c;
        c.a = x;
        c.b = y;
        ls.push(c);
    };
    // operand tops for which every instance's result fits the field
    const int TLO = -230, THI = 230;

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            auto lit = [&](const Fp& x, const Fp& y, const Fp& v) {
                Case c;
                c.a = x;
                c.b = y;
                c.lit = true;
                c.litv = v;
                ls.push(c);
            };
            const Fp third = mk(false, false, -25, 0xAAAAAB), third_dn = mk(false, false, -25, 0xAAAAAA);
            lit(mk(false, false, -22, 0xC00000), third, mk(false, false, -23, 0x800000));        // 3 x 1/3 = 1
            lit(mk(false, false, -22, 0xC00000), third_dn, mk(false, false, -24, 0xFFFFFF));     // one step low
            lit(mk(true, false, 100, 0xC00000), third, mk(true, false, 99, 0x800000));          // any binade
            lit(mk(false, false, 5, 0x123456), mk(true, false, 0, 0), mk(true, false, 0, 0));   // x * -0 = -0
            lit(mk(true, false, 5, 0x123456), mk(true, false, 0, 0), mk(false, false, 0, 0));   // -x * -0 = +0
            lit(mk(false, true, 0, 0), mk(false, false, 1, 1), mk(false, true, 0, 0));          // bad: 0 flagged
        }
        sectionDone("fp-mul", "directed", ls.cases() - n0);
    }
    if (a.want("exh10")) {
        f.set("exh10");
        const uint64_t n0 = ls.cases();
        const uint64_t total = 1023ull * 1023 * 3;
        if (a.full) {
            uint64_t lo, hi;
            a.range(total, &lo, &hi);
            for (uint64_t i = lo; i < hi; i++) {
                const uint64_t x = i % 1023 + 1, y = (i / 1023) % 1023 + 1, o = i / (1023 * 1023);
                p2tb::Rng r = p2tb::Rng::of(a.seed, i);
                const int ex = (int)r.range(-200, 200);
                push(mk(r.u64() & 1, false, ex, x), mk(r.u64() & 1, false, (int)o * 7 - 7 - ex / 2, y));
            }
        } else {
            const uint64_t n = a.count(300000);
            for (uint64_t i = 0; i < n; i++)
                if (a.mine(i)) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed, i);
                    const int ex = (int)r.range(-200, 200);
                    push(mk(r.u64() & 1, false, ex, r.range(1, 1023)),
                         mk(r.u64() & 1, false, (int)r.range(-7, 7) - ex / 2, r.range(1, 1023)));
                }
        }
        sectionDone("fp-mul", "exh10", ls.cases() - n0);
    }
    if (a.want("exh8")) {
        f.set("exh8");
        const uint64_t n0 = ls.cases();
        for (uint64_t i = 0; i < 65536; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 8, i);
                push(mk(r.u64() & 1, r.chance(10), (int)r.range(-200, 200), i & 0xFF),
                     mk(r.u64() & 1, r.chance(10), (int)r.range(-200, 200), i >> 8));
            }
        sectionDone("fp-mul", "exh8", ls.cases() - n0);
    }
    if (a.want("const")) {
        f.set("const");
        const uint64_t n0 = ls.cases();
        const Fp k[2] = {mk(false, false, -25, 0xAAAAAB), mk(false, false, -24, 0x95F612)};
        const uint64_t total = 2ull << 23;
        auto one = [&](uint64_t i, p2tb::Rng& r) {
            const uint64_t m = 0x800000 | (i >> 1 & 0x7FFFFF);
            push(mk(r.u64() & 1, false, (int)r.range(-170, 120), m), k[i & 1]);
        };
        if (a.full) {
            uint64_t lo, hi;
            a.range(total, &lo, &hi);
            p2tb::Rng r(a.seed ^ lo);
            for (uint64_t i = lo; i < hi; i++)
                one(i, r);
        } else {
            for (uint64_t i = 0; i < (1u << 18); i++)
                if (a.mine(i)) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xC0, i);
                    one(r.u64() & (total - 1), r);
                }
        }
        sectionDone("fp-mul", "const", ls.cases() - n0);
    }
    if (a.want("rand24")) {
        f.set("rand24");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 20000000 : 2000000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x24, i);
                Gen g(r);
                Fp x = g.num(24, TLO, THI), y = g.num(24, TLO, THI);
                if (i % 4 == 0 && x.mant && !x.bad) {
                    // products crossing the bit boundary: x * y just under and over 2^(BL(x) + BL(y) - 1)
                    const int bx = bl(x.mant), by = (int)g.r.range(1, 24);
                    const unsigned __int128 p2 = (unsigned __int128)1 << (bx + by - 1);
                    uint64_t m = (uint64_t)((p2 + x.mant - 1) / x.mant) + (uint64_t)g.r.range(-2, 1);
                    if (m == 0 || bl(m) > 24)
                        m = Gen::mask(by);
                    y = Gen::at(m, g.top(TLO, THI), g.r.u64() & 1);
                }
                push(x, y);
            }
        sectionDone("fp-mul", "rand24", ls.cases() - n0);
    }
    if (a.want("tsp16x13")) {
        f.set("tsp16x13");
        const uint64_t n0 = ls.cases();
        const int coefs = a.full ? 512 : 16;
        for (uint64_t x = 0; x <= 8192; x++)
            if (a.mine(x))
                for (int k = 0; k < coefs; k++) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x1613, x * 512 + k);
                    Gen g(r);
                    // a 16-bit coefficient (seen: never zero) times FromHalves(x): exact
                    push(Gen::at(g.mant(16), g.top(-150, 140), g.r.u64() & 1), mk(false, false, -1, x));
                }
        sectionDone("fp-mul", "tsp16x13", ls.cases() - n0);
    }
    if (a.want("fog8x16")) {
        f.set("fog8x16");
        const uint64_t n0 = ls.cases();
        auto one = [&](uint64_t i, p2tb::Rng& r) {
            push(mk(false, false, 0, i & 0xFF), mk(false, false, (int)r.range(-150, 150), i >> 8));
        };
        if (a.full) {
            uint64_t lo, hi;
            a.range(1ull << 24, &lo, &hi);
            p2tb::Rng r(a.seed ^ lo);
            for (uint64_t i = lo; i < hi; i++)
                one(i, r);
        } else {
            for (uint64_t i = 0; i < (1u << 18); i++)
                if (a.mine(i)) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xF0, i);
                    one(r.u64() & 0xFFFFFF, r);
                }
        }
        sectionDone("fp-mul", "fog8x16", ls.cases() - n0);
    }
    if (a.want("bias24x5")) {
        f.set("bias24x5");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 2000000 : 200000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xB5, i);
                Gen g(r);
                push(g.num(24, -200, 200, 10, 10), mk(false, false, -1, g.r.range(1, 31)));
            }
        sectionDone("fp-mul", "bias24x5", ls.cases() - n0);
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
                const int wa = (int)g.r.range(1, 24), wb = (int)g.r.range(1, 24);
                push(g.num(wa, TLO, THI), g.num(wb, TLO, THI));
            }
        ls.gaps(0);
        sectionDone("fp-mul", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

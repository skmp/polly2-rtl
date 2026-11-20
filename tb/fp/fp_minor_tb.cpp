// fp_minor_tb.cpp: make fp-minor. H7c p2_fp_mip_minor against refcore pvr_tsp_plane.h MipSelect's minor at 708fb8cd
// (docs/spec/numerics.md H7c, 8 A1, 7.3; PLAN M1b): at 24 bits against the verbatim copy of L642-644
// (tb/fp/ref_copies.h p2fpref::mipMinor: Sub(q1, q2, 62, 200).cut(24), sign and flag cleared); at 8 bits against the
// same expression with cut(8) (the reference's Sub is generic; the window of 90 is width-independent).
//
// Sections (--only):
//   directed  the far path's L - eps: a power of two minus a far smaller operand (W ones one exponent down) and a
//             non-power-of-two (one unit less), an LSB exponent gap of exactly 90 (borrow) and 91 (the window: the
//             larger as it is, also unnormalized); zeros; exact cancellation
//   exh8      8-bit: every pair of 1 .. 8-bit mantissas x LSB exponent gaps -100 .. 100 x 4 sign pairs (--full; quick:
//             every 37th pair)
//   struct24  24-bit: top gaps 0 .. 120 x LSB offsets x signs, q2 mantissas {1, 0x800000, U, N}, q1 random
//   rand24    random products (tops -251 .. 256, zeros 5 %)
//   stream    random pairs with random gap clocks
#include <memory>

#include "Vp2_fp_minor_tb_top.h"
#include "fp_tb.h"
#include "ref_copies.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_minor_tb_top Top;

namespace {

uint64_t g_window = 0, g_far = 0, g_near = 0;

struct Case {
    Fp q1, q2;
    bool w8 = false;         // compare the 8-bit instance (mantissas of at most 8 bits)
    bool hasLit = false;
    Fp lit;

    void drive(Top* t) const
    {
        FP_SET(t, a, q1);
        FP_SET(t, b, q2);
    }
    std::string in() const { return "q1 " + str(q1) + " q2 " + str(q2); }
    void check(Top* t, Fails& f) const
    {
        auto what = [&] { return in(); };
        const Fp want = p2fpref::mipMinor(q1, q2);
        if (!q1.zero() && !q2.zero()) {
            const int de = q1.exp - q2.exp, dt = q1.top() - q2.top();
            if (de > 90 || de < -90)
                g_window++;
            else if (dt > 24 || dt < -24)
                g_far++;
            else
                g_near++;
        }
        expectFp(f, "minor24", want, FP_GET(t, n24), 24, what);
        if (hasLit)
            expectFp(f, "minor24 literal", lit, FP_GET(t, n24), 24, what);
        if (w8) {
            Fp w = pvrfp::Sub(q1, q2, 62, 200).cut(8);
            w.neg = false;
            w.bad = false;
            expectFp(f, "minor8", w, FP_GET(t, n8), 8, what);
        }
    }
};

}   // namespace

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-minor", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-minor");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x313);
    auto push = [&](const Fp& q1, const Fp& q2, bool w8 = false) {
        Case c;
        c.q1 = q1;
        c.q2 = q2;
        c.w8 = w8;
        ls.push(c);
    };
    auto lit = [&](const Fp& q1, const Fp& q2, const Fp& want) {
        Case c;
        c.q1 = q1;
        c.q2 = q2;
        c.hasLit = true;
        c.lit = want;
        ls.push(c);
    };

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            for (int s = 0; s < 2; s++) {
                // 2^23 - 2^-30 (same signs: a difference): 0xFFFFFF at 2^-1; also from an unnormalized 2^23
                lit(mk(s, false, 0, 0x800000), mk(s, false, -30, 1), mk(false, false, -1, 0xFFFFFF));
                lit(mk(s, false, 23, 1), mk(s, false, -30, 1), mk(false, false, -1, 0xFFFFFF));
                // a non-power-of-two: one unit less, left-justified
                lit(mk(s, false, 0, 0x800001), mk(s, false, -40, 3), mk(false, false, 0, 0x800000));
                lit(mk(s, false, 10, 0x3), mk(s, false, -60, 1), mk(false, false, -12, 0xBFFFFF));
                // opposite signs: a sum, the larger left-justified
                lit(mk(s, false, 23, 1), mk(!s, false, -30, 1), mk(false, false, 0, 0x800000));
                // LSB exponents 90 apart: still a borrow; 91 apart: the window, the larger as it is
                lit(mk(s, false, 23, 1), mk(s, false, 23 - 90, 1), mk(false, false, -1, 0xFFFFFF));
                lit(mk(s, false, 23, 1), mk(s, false, 23 - 91, 1), mk(false, false, 23, 1));
                lit(mk(s, false, 23 - 91, 0xFFFFFF), mk(s, false, 23, 1), mk(false, false, 23, 1));
                // zeros: the other one as it is; both: 0; exact cancellation: 0
                lit(mk(s, false, 0, 0), mk(s, false, 7, 0x5), mk(false, false, 7, 0x5));
                lit(mk(s, false, 7, 0x5), mk(!s, false, 0, 0), mk(false, false, 7, 0x5));
                lit(mk(s, false, 0, 0), mk(s, false, 0, 0), mk(false, false, 0, 0));
                lit(mk(s, false, 7, 0x5), mk(s, false, 6, 0xA), mk(false, false, 0, 0));
            }
        }
        sectionDone("fp-minor", "directed", ls.cases() - n0);
    }
    if (a.want("exh8")) {
        f.set("exh8");
        const uint64_t n0 = ls.cases();
        const uint64_t step = a.full ? 1 : 37;
        uint64_t i = 0;
        for (uint64_t p = 0; p < 255 * 255; p += step, i++)
            if (a.mine(i)) {
                const uint64_t m1 = 1 + p / 255, m2 = 1 + p % 255;
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xe8, p);
                const int base = (int)r.range(-200, 100);
                for (int gap = -100; gap <= 100; gap++)
                    for (int s = 0; s < 4; s++)
                        push(mk(s & 1, false, base, m1), mk(s >> 1, false, base + gap, m2), true);
            }
        sectionDone("fp-minor", "exh8", ls.cases() - n0);
    }
    if (a.want("struct24")) {
        f.set("struct24");
        const uint64_t n0 = ls.cases();
        uint64_t i = 0;
        for (int gap = 0; gap <= 120; gap++)
            for (int k = 0; k < 4; k++)
                for (int off = -3; off <= 3; off++)
                    for (int s = 0; s < 4; s++)
                        for (int rep = 0; rep < 8; rep++, i++)
                            if (a.mine(i)) {
                                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x524, i);
                                Gen g(r);
                                const uint64_t m1 = g.mant(24);
                                static const uint64_t mm[] = {1, 0x800000};
                                const uint64_t m2 = k < 2 ? mm[k] : k == 2 ? g.mantU(24) : g.mantN(24);
                                const int t1 = (int)g.r.range(-100, 100);
                                // q2's top `gap` below q1's, moved by `off` LSB positions (its exponent shifts)
                                const Fp q1 = Gen::at(m1, t1, s & 1);
                                Fp q2 = Gen::at(m2, t1 - gap, s >> 1);
                                q2.exp += off;
                                if (rep & 1)
                                    push(q2, q1);
                                else
                                    push(q1, q2);
                            }
        sectionDone("fp-minor", "struct24", ls.cases() - n0);
    }
    if (a.want("rand24")) {
        f.set("rand24");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 30000000 : 1500000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x24, i);
                Gen g(r);
                const Fp q1 = g.num(24, -251, 256, 50, 0);
                Fp q2 = g.r.chance(400) ? Gen::at(g.mant(24), q1.top() - (int)g.r.range(0, 120), g.r.u64() & 1)
                                        : g.num(24, -251, 256, 50, 0);
                if (q2.top() < -251)
                    q2 = Gen::at(q2.mant, -251, q2.neg);
                push(q1, q2);
            }
        sectionDone("fp-minor", "rand24", ls.cases() - n0);
    }
    if (a.want("stream")) {
        f.set("stream");
        const uint64_t n0 = ls.cases();
        ls.gaps(300);
        const uint64_t n = a.full ? 2000000 : 200000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x5e, i);
                Gen g(r);
                const Fp q1 = g.num(24, -200, 200, 50, 0);
                push(q1, Gen::at(g.mant(24), q1.zero() ? 0 : q1.top() - (int)g.r.range(-30, 110), g.r.u64() & 1));
            }
        ls.gaps(0);
        sectionDone("fp-minor", "stream", ls.cases() - n0);
    }
    printf("fp-minor: classes: %llu window, %llu far, %llu near\n", (unsigned long long)g_window,
           (unsigned long long)g_far, (unsigned long long)g_near);
    top->final();
    return f.finish();
}

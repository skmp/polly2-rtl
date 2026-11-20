// fp_add_tb.cpp: make fp-add. H6 p2_fp_add against refcore pvr_softfp.h Add (docs/spec/numerics.md H6, 2.8, 7.3): the
// HW instance as the setup sites call it, Add(a, b, C<24>, C<25>); the mip site's literal Add(a, b, 24, 53); and the
// generic template at 8 bits with reaches 9, 12 and 53. The 8-bit instances are checked when both mantissas fit.
// On the exact path (no zero, |ta - tb| < R) every result is held to the contract out.exp = max(L, top - W) (num 1.3),
// refsw3's window rule is asserted never to act and, at reach 25, its 64-bit truncation too; and its cut of the
// operands to 32 bits never acts (A4).
//
// Sections (--only):
//   directed  console facts: an operand 25 tops below is dropped, no borrow (covmeas point 3, uvmeas reach1:
//             1 - 2^-25 is 1, 1 - 2^-24 is 0xFFFFFF 2^-24); x - x = +0; the signs of zero sums (num 1.2); one zero
//             gives the other operand as it is, a bad zero flags it
//   exhsmall  W = 8: every pair of 1..8-bit mantissas x top gaps -14 .. 14 x 4 sign combinations (--full; quick 400k)
//   far53     gaps 9 .. 60 either way, where only reach 53 adds (the far path of num H6 at W = 8 and 24)
//   rand      num 7.2's pairs: gaps -30 .. 30, the reaches +-1, uniform; cancellation pairs; zeros of all four sign
//             combinations; bad operands with and without a mantissa (3M; 30M --full)
//   stream    random pairs with random gap clocks
#include <memory>

#include "Vp2_fp_add_tb_top.h"
#include "fp_tb.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_add_tb_top Top;

struct Inst {
    const char* name;
    int w, r;
};
static const Inst kInst[] = {{"add24/25", 24, 25}, {"add24/53", 24, 53}, {"add8/9", 8, 9}, {"add8/12", 8, 12}, {"add8/53", 8, 53}};
static const int kN = sizeof kInst / sizeof kInst[0];

static Fp ref(const Fp& x, const Fp& y, int w, int r)
{
    if (w == 24 && r == 25)
        return pvrfp::Add(x, y, pvrfp::C<24>{}, pvrfp::C<25>{});   // EdgeHW / DepthHW / PlaneHW sumBits, reach
    return pvrfp::Add(x, y, w, r);
}

// the exact path's facts: (taken, window would act, BL of the exact sum)
struct Exact {
    bool taken = false;
    int sx = 0, sy = 0, n = 0, lsb = 0;
};
static Exact exact(const Fp& x, const Fp& y, int r)
{
    Exact e;
    if (x.zero() || y.zero())
        return e;
    const int g = x.top() - y.top();
    if (g >= r || -g >= r)
        return e;
    e.taken = true;
    e.lsb = std::min(x.exp, y.exp);
    e.sx = x.exp - e.lsb;
    e.sy = y.exp - e.lsb;
    if (e.sx <= 90 && e.sy <= 90) {
        __int128 vx = (__int128)x.mant << e.sx, vy = (__int128)y.mant << e.sy;
        __int128 s = (x.neg ? -vx : vx) + (y.neg ? -vy : vy);
        unsigned __int128 m = s < 0 ? (unsigned __int128)(-s) : (unsigned __int128)s;
        e.n = (uint64_t)(m >> 64) ? 64 + bl((uint64_t)(m >> 64)) : bl((uint64_t)m);
    }
    return e;
}

struct Case {
    Fp a, b;
    bool lit = false;
    Fp litv;   // directed: the console's value of the 24/25 sum
    void drive(Top* t) const
    {
        FP_SET(t, a, a);
        FP_SET(t, b, b);
    }
    void check(Top* t, Fails& f) const
    {
        const Fp got[kN] = {FP_GET(t, a25), FP_GET(t, a53), FP_GET(t, s9), FP_GET(t, s12), FP_GET(t, s53)};
        auto in = [&] { return str(a) + " + " + str(b); };
        // A4: refsw3's cut_32 of the operands (step 5) never acts
        expect(f, bl(a.mant) <= 32 && bl(b.mant) <= 32, [&] { return std::string("A4: an operand above 32 bits: ") + in(); });
        for (int i = 0; i < kN; i++) {
            if (!mantFits(a.mant, kInst[i].w) || !mantFits(b.mant, kInst[i].w))
                continue;
            const Fp want = ref(a, b, kInst[i].w, kInst[i].r);
            const Exact e = exact(a, b, kInst[i].r);
            if (e.taken) {
                // A4: case W (an LSB exponent more than 90 below the other's) needs R >= 61
                expect(f, e.sx <= 90 && e.sy <= 90, [&] { return std::string("A4: the window rule acted: ") + in(); });
                // A4: at reach 25 the 64-bit truncation never acts (the sum has at most 49 bits)
                if (kInst[i].r == 25)
                    expect(f, e.n <= 64, [&] { return std::string("A4: a 25-reach sum above 64 bits: ") + in(); });
                if (want.mant) {
                    const int ce = std::max(e.lsb, want.top() - kInst[i].w);
                    expect(f, want.exp == ce, [&] { return "contract: " + str(want) + " from " + in(); });
                }
            }
            expectFp(f, kInst[i].name, want, got[i], kInst[i].w, in);
        }
        if (lit)
            expectFp(f, "console: add24/25", litv, got[0], 24, in);
    }
};

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-add", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-add");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x616464);
    auto push = [&](const Fp& x, const Fp& y) {
        Case c;
        c.a = x;
        c.b = y;
        ls.push(c);
    };
    // b's top g below a's, for mantissas ma, mb, around a top T
    auto pair = [&](uint64_t ma, uint64_t mb, int T, int g, bool na, bool nb) {
        push(Gen::at(ma, T, na), Gen::at(mb, T - g, nb));
    };

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
            const Fp one = mk(false, false, -23, 0x800000);
            lit(one, mk(true, false, -48, 0x800000), one);                          // 1 - 2^-25: dropped, no borrow
            lit(one, mk(true, false, -47, 0x800000), mk(false, false, -24, 0xFFFFFF));   // 1 - 2^-24: exact, cut
            lit(one, mk(false, false, -48, 0x800000), one);                         // 1 + 2^-25
            lit(one, mk(false, false, -47, 0x800000), one);                         // 1 + 2^-24, cut to 24 bits
            lit(mk(true, false, -48, 0x800000), one, one);                          // the other order
            lit(mk(false, false, 7, 0x123457), mk(true, false, 7, 0x123457), mk(false, false, 0, 0));    // x - x = +0
            lit(mk(true, false, 7, 0x123457), mk(false, false, 7, 0x123457), mk(false, false, 0, 0));
            lit(mk(true, false, 3, 0), mk(true, false, 9, 0), mk(true, false, 0, 0));       // -0 + -0 = -0
            lit(mk(false, false, 3, 0), mk(true, false, 9, 0), mk(false, false, 0, 0));     // +0 + -0 = +0
            lit(mk(true, false, 3, 0), mk(false, false, 5, 3), mk(false, false, 5, 3));     // -0 + x = x, as it is
            lit(mk(false, true, 0, 0), mk(false, false, 0, 5), mk(false, true, 0, 5));      // bad: the value, flagged
            // two swamp values (the edge unit's 2^200, num H7a): 2^200 + 2^200 = {2, 200}, 2^200 - 2^200 = +0
            lit(mk(false, false, 200, 1), mk(false, false, 200, 1), mk(false, false, 200, 2));
            lit(mk(true, false, 200, 1), mk(false, false, 200, 1), mk(false, false, 0, 0));
            // a finite operand against one: dropped
            lit(mk(false, false, 200, 1), mk(true, false, 104, 0xFFFFFF), mk(false, false, 200, 1));
        }
        sectionDone("fp-add", "directed", ls.cases() - n0);
    }
    if (a.want("exhsmall")) {
        f.set("exhsmall");
        const uint64_t n0 = ls.cases();
        const uint64_t total = 255ull * 255 * 29 * 4;
        auto one = [&](uint64_t i) {
            const uint64_t ma = i % 255 + 1, mb = (i / 255) % 255 + 1;
            const int g = (int)((i / (255 * 255)) % 29) - 14;
            const int s = (int)(i / (255ull * 255 * 29));
            p2tb::Rng r = p2tb::Rng::of(a.seed, i);
            pair(ma, mb, (int)r.range(-200, 200), g, s & 1, s & 2);
        };
        if (a.full) {
            uint64_t lo, hi;
            a.range(total, &lo, &hi);
            for (uint64_t i = lo; i < hi; i++)
                one(i);
        } else {
            const uint64_t n = a.count(400000);
            for (uint64_t i = 0; i < n; i++)
                if (a.mine(i)) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x5a, i);
                    one(r.below(total));
                }
        }
        sectionDone("fp-add", "exhsmall", ls.cases() - n0);
    }
    if (a.want("far53")) {
        f.set("far53");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.full ? 2000000 : 200000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x53, i);
                Gen g(r);
                const int w = (i & 1) ? 8 : 24;
                const int gap = (int)g.r.range(9, 60) * ((g.r.u64() & 1) ? 1 : -1);
                pair(g.mant(w), g.mant(w), (int)g.r.range(-200, 200), gap, g.r.u64() & 1, g.r.u64() & 1);
            }
        sectionDone("fp-add", "far53", ls.cases() - n0);
    }
    if (a.want("rand")) {
        f.set("rand");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 30000000 : 3000000);
        static const int reachGap[] = {24, 25, 26, 52, 53, 54, 8, 9, 10, 11, 12, 13};
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x7a, i);
                Gen g(r);
                const int w = g.r.chance(250) ? 8 : 24;
                const bool na = g.r.u64() & 1, nb = (i & 1) ? na : !na;   // same and opposite signs, equal shares
                const int T = g.top(-270, 258);
                switch (i % 8) {
                case 0: case 1: case 2: {   // gaps -30 .. 30
                    pair(g.mant(w), g.mant(w), T, (int)g.r.range(-30, 30), na, nb);
                    break;
                }
                case 3: {                   // the reaches, +-1
                    const int gap = reachGap[g.r.below(sizeof reachGap / sizeof reachGap[0])];
                    pair(g.mant(w), g.mant(w), T, (g.r.u64() & 1) ? gap : -gap, na, nb);
                    break;
                }
                case 4: {                   // uniform gaps
                    const int gap = (int)g.r.range(-300, 300);
                    const int Tb = std::max(-290, std::min(270, T - gap));
                    push(Gen::at(g.mant(w), T, na), Gen::at(g.mant(w), Tb, nb));
                    break;
                }
                case 5: {                   // cancellation: b = -a + delta, delta a few units of a's last bit
                    const Fp x = Gen::at(g.mant(w), T, na);
                    const int64_t d = (int64_t)g.r.range(-4, 4);
                    const int sh = (int)g.r.below(3);
                    uint64_t mb = (uint64_t)((int64_t)(x.mant << sh) + d);
                    if (mb == 0 || !mantFits(mb, w))
                        mb = x.mant;
                    push(x, mk(!na, false, x.exp - sh, mb));
                    break;
                }
                case 6: {                   // zeros, all four sign combinations, and against numbers
                    const Fp x = g.r.chance(500) ? mk(na, false, (int)g.r.range(-300, 300), 0) : Gen::at(g.mant(w), T, na);
                    push(x, mk(nb, false, (int)g.r.range(-300, 300), 0));
                    break;
                }
                default: {                  // bad operands, with and without a mantissa
                    Fp x = g.num(w, -270, 258, 100, 0), y = g.num(w, -270, 258, 100, 0);
                    x.bad = true;
                    if (g.r.chance(500))
                        x.mant = 0;
                    if (g.r.chance(300))
                        y.bad = true;
                    if (i & 2)
                        std::swap(x, y);
                    push(x, y);
                }
                }
            }
        sectionDone("fp-add", "rand", ls.cases() - n0);
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
                const int w = g.r.chance(300) ? 8 : 24;
                pair(g.mant(w), g.mant(w), g.top(-270, 258), (int)g.r.range(-60, 60), g.r.u64() & 1, g.r.u64() & 1);
            }
        ls.gaps(0);
        sectionDone("fp-add", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

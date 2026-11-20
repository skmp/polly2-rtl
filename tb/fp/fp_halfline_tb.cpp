// fp_halfline_tb.cpp: make fp-halfline. H7b p2_fp_half_line against refcore pvr_tsp_plane.h at 708fb8cd
// (docs/spec/numerics.md H7b, 8 A1, 7.3; PLAN M1b):
//   bare      dk = FloorUnits(Add(c_, bh, 62, 400), unit) - FloorUnits(c_, unit), c_ = seen(C), bh = Mul(seen(B),
//             FromHalves(1), 62) as Value forms it (public pvrfp::Add, pvrtsp::FloorUnits)
//   in place  the difference of PlaneT::Value's integer k with hy = 1 and hy = 0 (super), through the verbatim copy of
//             Value's L311-369 (tb/fp/ref_copies.h p2fpref::valueK), whose grid exponent also gives the RTL its unit
//
// Sections (--only):
//   directed  num H7b's table: C = +-0xC000 2^(C.exp) on the grid with B = -0 (bh = -2^-128) at gaps 40 .. 100 (C > 0:
//             -1 up to 90, 0 beyond; C < 0: -1 up to 46, 0 from 47: the 62-bit truncation); B = +0, +-bad
//   exh       C exponent -60 .. -10 (and the C ranges' ends) x C mantissas x B in {+-0, +-bad, tiny +-, ordinary} x the
//             grid at its lowest and 1 .. 3 above; exponent gaps 40 .. 100 between c_ and bh
//   rand      random 16-bit coefficients of the ranged setup (tops -125 .. 128, zeros, bad) and grids
//   inplace   random planes A, B, C and positions (tile, run start, n, hx) through Value's copy
//   stream    random cases with random gap clocks
#include <memory>

#include "Vp2_fp_halfline_tb_top.h"
#include "fp_tb.h"
#include "ref_copies.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_halfline_tb_top Top;

namespace {

uint64_t g_floorsOut = 0;    // reference floors outside the port's domain (a generator bug, reported)
uint64_t g_window = 0, g_trunc = 0, g_nonzero = 0;

struct Case {
    Fp C, B;                 // the coefficients (seen() is applied here)
    int unit = 0;
    bool inplace = false;
    int64_t want = 0;        // in place: k(hy = 1) - k(hy = 0) from Value's copy
    std::string where;
    bool hasLit = false;     // num H7b's table, as a literal
    int64_t lit = 0;

    void drive(Top* t) const
    {
        const Fp c = p2fpref::seen(C), b = p2fpref::seen(B);
        FP_SET(t, c, c);
        FP_SET(t, b, b);
        t->unit = efield(unit);
    }
    std::string in() const
    {
        return "C " + str(C) + " B " + str(B) + " unit " + std::to_string(unit) + (inplace ? " (in place " + where + ")" : "");
    }
    void check(Top* t, Fails& f) const
    {
        const Fp c_ = p2fpref::seen(C), b_ = p2fpref::seen(B);
        int64_t want = this->want;
        if (!inplace) {
            Fp bh = pvrfp::Mul(b_, Fp::FromHalves(1), 62);
            if (bh.zero())
                bh.neg = b_.neg;
            const Fp T = pvrfp::Add(c_, bh, 62, 400);
            const int64_t ft = pvrtsp::FloorUnits(T, unit), fc = pvrtsp::FloorUnits(c_, unit);
            if (ft >= ((int64_t)1 << 25) || ft < -((int64_t)1 << 25) || fc >= ((int64_t)1 << 25) || fc < -((int64_t)1 << 25))
                g_floorsOut++;
            want = ft - fc;
            // A4: Add's reach of 400 never acts (the tops of seen coefficients are within 257 of each other)
            if (std::abs(c_.top() - bh.top()) >= 400)
                g_floorsOut++;
            const int de = c_.exp - bh.exp;
            if (de > 90 || de < -90)
                g_window++;
            else if (pvrfp::BitLength(c_.mant) + std::abs(de) + 1 > 62)
                g_trunc++;
        }
        if (want)
            g_nonzero++;
        const int64_t got = (int64_t)sext(t->dk, 27);
        if (hasLit)
            expect(f, got == lit, [&] {
                return "num H7b's table: got " + std::to_string(got) + " want " + std::to_string(lit) + "; " + in();
            });
        expect(f, got == want, [&] {
            return "dk: got " + std::to_string(got) + " want " + std::to_string(want) + "; " + in();
        });
    }
};

// the grid exponent of Value for these coefficients at a tile (L319-325), taking an A-term top
int gridUnit(const Fp& C, const Fp& B, int aTop, int ey)
{
    const Fp c_ = p2fpref::seen(C), b_ = p2fpref::seen(B);
    int e = c_.top();
    if (b_.top() + ey - 1 > e)
        e = b_.top() + ey - 1;
    if (aTop + 4 > e)
        e = aTop + 4;
    return e - pvrtsp::PlaneHW::gridBits;
}

// a coefficient as the ranged setup leaves it, cut to 16 bits: a zero (either sign), bad, or top -125 .. 128
Fp coef(Gen& g, unsigned zeroPm = 60, unsigned badPm = 30)
{
    const bool neg = g.r.u64() & 1;
    if (g.r.chance(zeroPm))
        return mk(neg, false, 0, 0);
    if (g.r.chance(badPm))
        return mk(neg, true, 0, 0);
    return Gen::at(g.mant(16), g.top(-125, 128), neg);
}

}   // namespace

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-halfline", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-halfline");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x41f);
    auto bare = [&](const Fp& C, const Fp& B, int unit) {
        Case c;
        c.C = C;
        c.B = B;
        c.unit = unit;
        ls.push(c);
    };
    // one plane at one point through Value's copy: hy = 1 against hy = 0
    auto inplace = [&](const Fp& A, const Fp& B, const Fp& C, int tl, int tt, int col, int row, int n, int hx) {
        const int64_t x0h = 2 * (int64_t)(tl + col) + 1, yh = 2 * (int64_t)(tt + row) + 1;
        int u1 = 0, u0 = 0;
        const int64_t k1 = p2fpref::valueK(A, B, C, x0h, yh, n, tl, tt, true, hx, 1, &u1);
        const int64_t k0 = p2fpref::valueK(A, B, C, x0h, yh, n, tl, tt, true, hx, 0, &u0);
        Case c;
        c.C = C;
        c.B = B;
        c.unit = u0;
        c.inplace = true;
        c.want = k1 - k0;
        c.where = "A " + str(A) + " tile " + std::to_string(tl) + "," + std::to_string(tt) + " px " +
                  std::to_string(col) + "," + std::to_string(row) + " n " + std::to_string(n) + " hx " + std::to_string(hx);
        f.ok(u1 == u0, "the grid differs between hy 1 and 0: %d %d", u1, u0);
        ls.push(c);
    };

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            // C = +-0xC000 2^Ce on its own grid (unit = top(C) - 22), B = -0: gap = Ce + 128
            for (int gap = 40; gap <= 100; gap++)
                for (int s = 0; s < 2; s++) {
                    const int ce = gap - 128;
                    const Fp C = mk(s, false, ce, 0xC000);
                    Case t;
                    t.C = C;
                    t.B = mk(true, false, 0, 0);
                    t.unit = C.top() - 22;
                    t.hasLit = true;
                    // C > 0: -1 up to gap 90, 0 beyond (the window); C < 0: -1 up to 46, 0 from 47 (the truncation)
                    t.lit = (s ? gap <= 46 : gap <= 90) ? -1 : 0;
                    ls.push(t);
                    bare(C, mk(false, false, 0, 0), C.top() - 22);
                    bare(C, mk(true, true, 0, 0), C.top() - 22);
                    bare(C, mk(false, true, 0, 0), C.top() - 22);
                }
        }
        sectionDone("fp-halfline", "directed", ls.cases() - n0);
    }
    if (a.want("exh")) {
        f.set("exh");
        const uint64_t n0 = ls.cases();
        uint64_t i = 0;
        std::vector<int> ces;
        for (int e = -60; e <= -10; e++)
            ces.push_back(e);
        for (int e : {-141, -140, -130, -110, -100, -80, 0, 50, 100, 112})
            ces.push_back(e);
        for (int ce : ces)
            for (int mc = 0; mc < 8; mc++)
                for (int bk = 0; bk < 8; bk++)
                    for (int du = 0; du < 4; du++)
                        for (int s = 0; s < 2; s++, i++)
                            if (a.mine(i)) {
                                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xe7, i);
                                Gen g(r);
                                static const uint64_t cm[] = {0xC000, 0x8000, 0xFFFF, 1, 0x8001};
                                const uint64_t m = mc < 5 ? cm[mc] : g.mant(16);
                                const Fp C = mk(s, false, ce, m);
                                Fp B;
                                switch (bk) {
                                case 0: B = mk(false, false, 0, 0); break;
                                case 1: B = mk(true, false, 0, 0); break;
                                case 2: B = mk(false, true, 0, 0); break;
                                case 3: B = mk(true, true, 0, 0); break;
                                case 4: B = Gen::at(g.mant(16), -125, g.r.u64() & 1); break;      // tiny
                                default: {
                                    // an ordinary B whose half lies 40 .. 100 exponents under C's last bit
                                    const int gap = (int)g.r.range(40, 100);
                                    const uint64_t bm = g.mant(16);
                                    B = mk(g.r.u64() & 1, false, ce - gap + 1, bm);
                                    if (B.top() < -125 || B.top() > 128)
                                        B = Gen::at(bm, -125, B.neg);
                                    break;
                                }
                                }
                                bare(C, B, gridUnit(C, B, -1000, 5) + du);
                            }
        sectionDone("fp-halfline", "exh", ls.cases() - n0);
    }
    if (a.want("rand")) {
        f.set("rand");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 30000000 : 1000000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x4a, i);
                Gen g(r);
                const Fp C = coef(g), B = coef(g);
                const int aTop = g.r.chance(500) ? -1000 : (int)g.r.range(-125, 128) + (int)g.r.range(4, 11);
                bare(C, B, gridUnit(C, B, aTop, (int)g.r.range(5, 11)) + (g.r.chance(100) ? (int)g.r.range(1, 8) : 0));
            }
        sectionDone("fp-halfline", "rand", ls.cases() - n0);
    }
    if (a.want("inplace")) {
        f.set("inplace");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 5000000 : 300000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x1a, i);
                Gen g(r);
                const Fp A = coef(g), B = coef(g), C = coef(g);
                const int tl = 32 * (int)g.r.below(40), tt = 32 * (int)g.r.below(30);
                const int col = (int)g.r.below(32), row = (int)g.r.below(32);
                inplace(A, B, C, tl, tt, col, row, (int)g.r.below(32 - col), (int)(g.r.u64() & 1));
            }
        sectionDone("fp-halfline", "inplace", ls.cases() - n0);
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
                const Fp C = coef(g), B = coef(g);
                bare(C, B, gridUnit(C, B, -1000, (int)g.r.range(5, 11)));
            }
        ls.gaps(0);
        sectionDone("fp-halfline", "stream", ls.cases() - n0);
    }
    printf("fp-halfline: classes: %llu in the window, %llu through the 62-bit truncation, %llu with dk != 0\n",
           (unsigned long long)g_window, (unsigned long long)g_trunc, (unsigned long long)g_nonzero);
    f.ok(g_floorsOut == 0, "%llu reference floors outside 2^25 or tops 400 apart (the generator left the site's domain)",
         (unsigned long long)g_floorsOut);
    top->final();
    return f.finish();
}

// fp_floor_tb.cpp: make fp-floor. H11, the float-to-integer converters, against refcore at 708fb8cd
// (docs/spec/numerics.md H11, 2.10, 7.3; PLAN M1b):
//   FloorScaled     pvr_softfp.h (public), the row range's: shift 0 and 1 at the site
//   FloorUnits      pvr_tsp_plane.h (public), PlaneT::Value's
//   unitsAt         pvr_isp_edge.h EdgeTile::Setup's lambda (tb/fp/ref_copies.h p2fpref::unitsAt, verbatim)
//   r0, fa / fb     pvr_isp_depth.h DepthTileT::Setup's r0 block and `rstep` lambda (p2fpref::regStart, regStep);
//                   compared as the low 31 bits of refsw3's int64 (all the wrapped register reads)
//   TexCoordFixed   refsw_tile.cpp, with CoordKeep (p2fpref::texCoordFixed)
//
// Sections (--only):
//   directed  console facts with literal integers: covmeas mix sliver (rows floor(y), floor(2y)), uvmeas point 5 (-0 is
//             one unit below zero), depthgaps_rcut and depthgaps_rstart (r0 of 2^127 + 2^104, 2^127 + 2^108 + 2^107,
//             -(2^127 + 2^104), -2^101, -0.5, -(2^119 + 2^100)), zovf_creg (slopes 7 2^101 as 6 2^101, 1.5 2^101 as 0,
//             2^122 + 7 2^102 as 2^122 + 6 2^102), coordfix (rounded down below zero), texfar_edge (2^128: 2^30)
//   scaled    FloorScaled: every 17-bit mantissa x LSB exponent - shift in -70 .. 45 x sign (--full; quick every 19th),
//             the clamp at top + shift = 40 / 41, 24-bit random, zeros
//   units     FloorUnits: every 17-bit mantissa x exp - unit in -70 .. 9 x sign (--full; quick every 17th), +-0, 29-bit
//             random within the 27-bit accumulator
//   unitsat   unitsAt: every 20-bit mantissa (bit 19 set) x exp - unit in -70 .. 36 x sign (--full; quick every 41st),
//             zeros, cut-below steps
//   reg       r0 from random ranged starts (tops -125 .. 128, bad, zeros); fa / fb from random ranged slopes and
//             reciprocals of ranged determinants (products past 2^131: the modulo)
//   tex       every quotient mantissa 2^15 .. 2^17 x tops around 31 and 26 x shifts 11 and 18 x sign (--full; quick:
//             every 11th), random quotients up to 2^261, bad, zero
//   stream    random cases of every kind with random gap clocks
#include <memory>

#include "Vp2_fp_floor_tb_top.h"
#include "fp_tb.h"
#include "ref_copies.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_floor_tb_top Top;

namespace {

enum Kind : uint8_t { K_SCALED = 1, K_UNITS = 2, K_UNITSAT = 4, K_R0 = 8, K_STEP = 16, K_TEX = 32 };
uint64_t g_domain = 0;    // reference values outside the port (a generator bug, reported)

struct Case {
    uint8_t kind = 0;
    Fp v;                 // FloorScaled, FloorUnits, unitsAt
    int u = 0;            // the unit (FloorScaled: -shift)
    Fp r, inv;            // r0: first0 (r); step: v0 (r), invS (inv)
    Fp q;                 // TexCoordFixed
    int shift = 11;
    bool hasLit = false;
    int64_t lit = 0;      // a literal for the one kind of this case

    void drive(Top* t) const
    {
        FP_SET(t, v, v);
        t->u = efield(u);
        FP_SET(t, r, r);
        FP_SET(t, i, inv);
        FP_SET(t, q, q);
        t->shift = (uint8_t)shift;
    }
    std::string in() const
    {
        std::string s;
        if (kind & (K_SCALED | K_UNITS | K_UNITSAT))
            s += "v " + str(v) + " u " + std::to_string(u) + " ";
        if (kind & (K_R0 | K_STEP))
            s += "r " + str(r) + " invS " + str(inv) + " ";
        if (kind & K_TEX)
            s += "q " + str(q) + " shift " + std::to_string(shift);
        return s;
    }
    void cmp(Fails& f, const char* what, int64_t want, int64_t got) const
    {
        expect(f, got == want, [&] {
            return std::string(what) + ": got " + std::to_string(got) + " want " + std::to_string(want) + "; " + in();
        });
        if (hasLit)
            expect(f, got == lit, [&] {
                return std::string(what) + " (console fact): got " + std::to_string(got) + " want " +
                       std::to_string(lit) + "; " + in();
            });
    }
    void check(Top* t, Fails& f) const
    {
        if (kind & K_SCALED)
            cmp(f, "FloorScaled", pvrfp::FloorScaled(v, -u), (int64_t)sext(t->fs_int, 42));
        if (kind & K_UNITS) {
            const int64_t want = pvrtsp::FloorUnits(v, u);
            if (want >= ((int64_t)1 << 26) || want < -((int64_t)1 << 26) || (!v.zero() && v.exp - u >= 62))
                g_domain++;
            cmp(f, "FloorUnits", want, (int64_t)sext(t->fu_int, 27));
        }
        if (kind & K_UNITSAT) {
            bool frac = false;
            const int64_t want = p2fpref::unitsAt(v, &frac, u);
            if (want >= ((int64_t)1 << 57) || want < -((int64_t)1 << 57))
                g_domain++;
            cmp(f, "unitsAt", want, (int64_t)sext(t->ua_int, 58));
            expect(f, (t->ua_frac != 0) == frac, [&] {
                return "unitsAt frac: got " + std::to_string((int)t->ua_frac) + " want " + std::to_string((int)frac) +
                       "; " + in();
            });
        }
        if (kind & K_R0) {
            // A4: r0's `sh < 40` clamp never acts for a ranged start (|first0| < 2^128)
            if (!r.bad && !r.zero() && r.cut(20).exp - 102 >= 40)
                g_domain++;
            const int64_t want = p2fpref::regStart(r);
            cmp(f, "r0", sext((uint64_t)want, 31), (int64_t)sext(t->r0, 31));
        }
        if (kind & K_STEP) {
            const int64_t want = p2fpref::regStep(r, false, inv);
            cmp(f, "fa", want, (int64_t)sext(t->rstep, 31));
        }
        if (kind & K_TEX)
            cmp(f, "TexCoordFixed", p2fpref::texCoordFixed(q, shift), (int64_t)(int32_t)t->coord);
    }
};

}   // namespace

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-floor", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-floor");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0xf1);
    auto one = [&](uint8_t kind, const Fp& v, int u) {
        Case c;
        c.kind = kind;
        c.v = v;
        c.u = u;
        ls.push(c);
    };
    auto reg = [&](uint8_t kind, const Fp& r, const Fp& inv) {
        Case c;
        c.kind = kind;
        c.r = r;
        c.inv = inv;
        ls.push(c);
    };
    auto tex = [&](const Fp& q, int shift) {
        Case c;
        c.kind = K_TEX;
        c.q = q;
        c.shift = shift;
        ls.push(c);
    };
    auto withLit = [&](Case c, int64_t lit) {
        c.hasLit = true;
        c.lit = lit;
        ls.push(c);
    };
    auto fb = [](uint32_t w) { return Fp::FromBits(w); };
    // a value of the ranged setup (24 bits): zeros, bad, or top -125 .. 128
    auto ranged = [](Gen& g) {
        const bool neg = g.r.u64() & 1;
        if (g.r.chance(40))
            return mk(neg, false, 0, 0);
        if (g.r.chance(30))
            return mk(neg, true, 0, 0);
        return Gen::at(g.mant(24), g.top(-125, 128), neg);
    };

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            Case c;
            // covmeas mix sliver: rows floor(ymin) .. floor(ymax + 1/2) = (floor(2y) + 1) >> 1
            c.kind = K_SCALED;
            c.v = fb(0x41b40000u);   // 22.5
            c.u = 0;
            withLit(c, 22);
            c.u = -1;
            withLit(c, 45);
            c.v = fb(0xc1b40000u);   // -22.5
            c.u = 0;
            withLit(c, -23);
            c.u = -1;
            withLit(c, -45);
            c.v = fb(0x7f000000u);   // 2^127: clamped to 2^40
            c.u = 0;
            withLit(c, (int64_t)1 << 40);
            c.v = fb(0xff000000u);
            withLit(c, -((int64_t)1 << 40));
            // uvmeas point 5: FloorUnits(-0) = -1, FloorUnits(+0) = 0
            c.kind = K_UNITS;
            c.v = mk(true, false, 0, 0);
            c.u = -30;
            withLit(c, -1);
            c.v = mk(false, false, 0, 0);
            withLit(c, 0);
            c.v = mk(true, false, -40, 3);   // -3 2^-40 on the grid 2^-30: one unit below zero
            withLit(c, -1);
            // depthgaps_rcut: the start cut to 20 bits first, then toward zero onto 2^102
            c = Case();
            c.kind = K_R0;
            c.r = mk(false, false, 104, ((uint64_t)1 << 23) + 1);   // 2^127 + 2^104
            withLit(c, (int64_t)1 << 25);
            c.r = mk(true, false, 104, ((uint64_t)1 << 23) + 1);
            withLit(c, -((int64_t)1 << 25));
            c.r = mk(false, false, 107, ((uint64_t)1 << 20) + 3);   // 2^127 + 2^108 + 2^107
            withLit(c, ((int64_t)1 << 25) + 64);
            c.r = mk(false, false, 107, ((uint64_t)1 << 20) + 1);   // 2^127 + 2^107
            withLit(c, (int64_t)1 << 25);
            // depthgaps_rstart: -2^101 .. -0.5 start at 0; -(2^119 + 2^100) as -2^17 units (0xff008000 one step down)
            c.r = mk(true, false, 101, 1);
            withLit(c, 0);
            c.r = mk(true, false, -1, 1);
            withLit(c, 0);
            c.r = mk(true, false, 100, ((uint64_t)1 << 19) + 1);
            withLit(c, -((int64_t)1 << 17));
            // nantr_pos: a bad start is one step with its sign
            c.r = mk(false, true, 0, 0);
            withLit(c, (int64_t)1 << 25);
            c.r = mk(true, true, 0, 0);
            withLit(c, -((int64_t)1 << 25));
            // zovf_creg: a slope of 7 2^101 as 6 2^101; 1.5 2^101 and 1.5 2^100 as 0; 2^122 + 7 2^102 as 2^122 + 6 2^102
            const Fp one = pvrfp::Recip(Fp::Pow2(0, false), 24);
            c = Case();
            c.kind = K_STEP;
            c.inv = one;
            c.r = mk(false, false, 101, 7);
            withLit(c, 3);
            c.r = mk(false, false, 100, 3);
            withLit(c, 0);
            c.r = mk(false, false, 99, 3);
            withLit(c, 0);
            c.r = mk(false, false, 102, ((uint64_t)1 << 20) + 7);
            withLit(c, ((int64_t)1 << 20) + 6);
            // zovf_wrap W2: a slope of -2^-6 a pixel toward zero: 0 (not -2^102)
            c.r = mk(true, false, -6, 1);
            withLit(c, 0);
            // coordfix: rounded down below zero, in 1/256 texel (an 8-texel texture: shift 11)
            c = Case();
            c.kind = K_TEX;
            c.shift = 11;
            c.q = mk(true, false, -13, 3);      // -0.75 / 256 texel: -1
            withLit(c, -1);
            c.q = mk(false, false, -13, 3);     // +0.75: 0
            withLit(c, 0);
            c.q = mk(true, false, -9, 1);       // exactly -4
            withLit(c, -4);
            // texfar_edge: 2^128 times the size: no overflow to texel 0, 2^30 (the low bits zeros); below zero -2^30
            c.q = mk(false, false, 128 - 16, 0x10000);
            withLit(c, (int64_t)1 << 30);
            c.q = mk(true, false, 128 - 16, 0x10000);
            withLit(c, -((int64_t)1 << 30));
        }
        sectionDone("fp-floor", "directed", ls.cases() - n0);
    }
    if (a.want("scaled")) {
        f.set("scaled");
        const uint64_t n0 = ls.cases();
        const uint64_t step = a.full ? 1 : 19;
        uint64_t i = 0;
        for (uint64_t m = 0; m < (1u << 17); m += step)
            for (int e = -70; e <= 45; e++)
                for (int s = 0; s < 2; s++, i++)
                    if (a.mine(i)) {
                        const int sh = (int)(i % 3) - 1;          // the shift: -1, 0, 1
                        one(K_SCALED, mk(s, false, e - sh, m), -sh);
                    }
        const uint64_t n = a.count(a.full ? 10000000 : 400000);
        for (uint64_t j = 0; j < n; j++)
            if (a.mine(j)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x5c, j);
                Gen g(r);
                const int sh = (int)g.r.range(-2, 2);
                // the clamp's edge: top + shift around 40
                const int tp = g.r.chance(300) ? 40 - sh + (int)g.r.range(-2, 2) : g.top(-160, 140);
                one(K_SCALED, g.r.chance(30) ? mk(g.r.u64() & 1, false, 0, 0) : Gen::at(g.mant(24), tp, g.r.u64() & 1),
                    -sh);
            }
        sectionDone("fp-floor", "scaled", ls.cases() - n0);
    }
    if (a.want("units")) {
        f.set("units");
        const uint64_t n0 = ls.cases();
        const uint64_t step = a.full ? 1 : 17;
        uint64_t i = 0;
        for (uint64_t m = 0; m < (1u << 17); m += step)
            for (int d = -70; d <= 9; d++)
                for (int s = 0; s < 2; s++, i++)
                    if (a.mine(i)) {
                        p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x4f, i);
                        const int ex = (int)r.range(-200, 150);
                        one(K_UNITS, mk(s, false, ex, m), ex - d);
                    }
        const uint64_t n = a.count(a.full ? 10000000 : 400000);
        for (uint64_t j = 0; j < n; j++)
            if (a.mine(j)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x4e, j);
                Gen g(r);
                const int bits = (int)g.r.range(1, 29);
                const uint64_t m = g.mant(bits);
                // top(v) - unit at most 25: the value below 2^25 units
                const int unit = (int)g.r.range(-170, 120);
                const int tp = unit + (int)g.r.range(-80, 25);
                one(K_UNITS, g.r.chance(30) ? mk(g.r.u64() & 1, false, 0, 0) : Gen::at(m, tp, g.r.u64() & 1), unit);
            }
        sectionDone("fp-floor", "units", ls.cases() - n0);
    }
    if (a.want("unitsat")) {
        f.set("unitsat");
        const uint64_t n0 = ls.cases();
        const uint64_t step = a.full ? 1 : 41;
        uint64_t i = 0;
        for (uint64_t m = (1u << 19); m < (1u << 20); m += step)
            for (int d = -70; d <= 36; d++)
                for (int s = 0; s < 2; s++, i++)
                    if (a.mine(i)) {
                        p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x3a, i);
                        const int ex = (int)r.range(-300, 200);
                        one(K_UNITSAT, mk(s, false, ex, m), ex - d);
                    }
        const uint64_t n = a.count(a.full ? 10000000 : 400000);
        for (uint64_t j = 0; j < n; j++)
            if (a.mine(j)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x3b, j);
                Gen g(r);
                const int unit = (int)g.r.range(-320, 200);
                Fp v = Gen::at(g.mant(20), unit + (int)g.r.range(-80, 56), g.r.u64() & 1);
                if (g.r.chance(300))
                    v = v.cutBelow(unit);          // a step: cut below the unit first (EdgeTile::Setup L237-238)
                if (g.r.chance(30))
                    v = mk(g.r.u64() & 1, false, 0, 0);
                one(K_UNITSAT, v, unit);
            }
        sectionDone("fp-floor", "unitsat", ls.cases() - n0);
    }
    if (a.want("reg")) {
        f.set("reg");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 20000000 : 1000000);
        for (uint64_t j = 0; j < n; j++)
            if (a.mine(j)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x9e, j);
                Gen g(r);
                Fp st = ranged(g);
                if (g.r.chance(300))      // starts around the register's grid 2^102 and its steps 2^127
                    st = Gen::at(g.mant(24), (int)g.r.range(95, 128), g.r.u64() & 1);
                reg(K_R0, st, Fp());
                // a slope (not bad: an overflowed one is not stepped) and the reciprocal of a ranged determinant
                Fp v0 = ranged(g);
                v0.bad = false;
                Fp det = Gen::at(g.mant(24), g.top(-125, 128), g.r.u64() & 1);
                if (g.r.chance(300))      // products around 2^102 .. 2^135: the grid and the modulo
                    v0 = Gen::at(g.mant(24), (int)g.r.range(95, 128), g.r.u64() & 1),
                    det = Gen::at(g.mant(24), (int)g.r.range(-8, 2), g.r.u64() & 1);
                reg(K_STEP, v0, pvrfp::Recip(det, 24));
            }
        sectionDone("fp-floor", "reg", ls.cases() - n0);
    }
    if (a.want("tex")) {
        f.set("tex");
        const uint64_t n0 = ls.cases();
        const uint64_t step = a.full ? 1 : 11;
        uint64_t i = 0;
        for (uint64_t m = (1u << 15); m <= (1u << 17); m += step)
            for (int tp = -5; tp <= 40; tp++)
                for (int sh : {11, 18})
                    for (int s = 0; s < 2; s++, i++)
                        if (a.mine(i))
                            tex(mk(s, false, tp - sh - bl(m), m), sh);
        const uint64_t n = a.count(a.full ? 10000000 : 400000);
        for (uint64_t j = 0; j < n; j++)
            if (a.mine(j)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x7c, j);
                Gen g(r);
                const uint64_t m = g.r.chance(100) ? (g.r.chance(500) ? (1u << 17) : g.mant(18))
                                                   : (1u << 15) | (g.r.u64() & 0x1ffff);
                const int sh = (int)g.r.range(11, 18);
                Fp q = Gen::at(m, g.r.chance(500) ? (int)g.r.range(-20, 45) - sh : (int)g.r.range(-300, 261), g.r.u64() & 1);
                if (g.r.chance(20))
                    q = mk(q.neg, g.r.chance(500), 0, 0);
                tex(q, sh);
            }
        sectionDone("fp-floor", "tex", ls.cases() - n0);
    }
    if (a.want("stream")) {
        f.set("stream");
        const uint64_t n0 = ls.cases();
        ls.gaps(300);
        const uint64_t n = a.full ? 2000000 : 200000;
        for (uint64_t j = 0; j < n; j++)
            if (a.mine(j)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x5e, j);
                Gen g(r);
                Case c;
                c.kind = K_SCALED | K_UNITSAT | K_R0 | K_STEP | K_TEX;
                c.u = (int)g.r.range(-100, 100);
                c.v = Gen::at(g.mant(20), c.u + (int)g.r.range(-60, 39), g.r.u64() & 1);
                c.r = ranged(g);
                c.r.bad = false;
                c.inv = pvrfp::Recip(Gen::at(g.mant(24), g.top(-125, 128), g.r.u64() & 1), 24);
                c.q = Gen::at((1u << 15) | (g.r.u64() & 0x1ffff), (int)g.r.range(-30, 40), g.r.u64() & 1);
                c.shift = (int)g.r.range(11, 18);
                ls.push(c);
            }
        ls.gaps(0);
        sectionDone("fp-floor", "stream", ls.cases() - n0);
    }
    f.ok(g_domain == 0, "%llu reference values outside the ports' domains (a generator bug)",
         (unsigned long long)g_domain);
    top->final();
    return f.finish();
}

// fp_cmp_tb.cpp: make fp-cmp. H9 against refcore pvr_softfp.h AbsAtMost, AtMost, Fp::atLeastPow2, Perpendicular (with
// perpVal = FromBits(FPU_PERP_VAL & 0x7fffffff), as refsw_lists.cpp RenderCORE sets it) and the verbatim copies of
// refsw_tile.cpp CulledBySize / CulledByFacing (tb/fp/ref_copies.h) (docs/spec/numerics.md H9, 7.3).
//
// Sections (--only):
//   directed  console facts as literals: a determinant equal to FPU_PERP_VAL is perpendicular in any representation
//             (perpeq); a NaN or -infinity register is +infinity (perpval, detinf); the register's sign does not count;
//             equal is culled (raster page 4); an infinite or NaN FPU_CULL_VAL culls every triangle, 2^-149 culls
//             nothing (cullval); the swamped 2^200 is never culled by size, +0 always (faredge_cull); facing by the sign,
//             -0 never
//   regs      every exponent field x {0, 1, 0x400000, 0x7FFFFF} x sign as the register, against determinants at its
//             value in three representations, one unit either side, both signs, +-0, bad
//   pairs     random pairs for |a| <= |b| and a <= b, ties in other representations, and |a| >= 2^e around a's top
//             (1M; 10M --full)
//   stream    random cases with random gap clocks
#include <memory>

#include "Vp2_fp_cmp_tb_top.h"
#include "fp_tb.h"
#include "ref_copies.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_cmp_tb_top Top;

struct Case {
    Fp a, b;
    int e = 128;
    uint32_t reg = 0;
    uint32_t mode = 0;
    // directed: the console's verdicts (-1: not given)
    int litPerp = -1, litSize = -1, litFacing = -1, litLe = -1;

    void drive(Top* t) const
    {
        FP_SET(t, a, a);
        FP_SET(t, b, b);
        t->e = efield(e);
        t->reg_v = reg;
        t->mode = mode;
    }
    void check(Top* t, Fails& f) const
    {
        auto in = [&] {
            char b2[64];
            snprintf(b2, sizeof b2, "; e %d reg 0x%08x mode %u", e, reg, mode);
            return "a " + str(a) + " b " + str(b) + b2;
        };
        auto one = [&](const char* what, bool want, uint64_t got) {
            expect(f, (got != 0) == want, [&] { return std::string(what) + " = " + std::to_string(got) + ", want " +
                                                        std::to_string(want) + ": " + in(); });
        };
        one("AbsAtMost(a, b)", pvrfp::AbsAtMost(a, b), t->abs_le);
        one("AtMost(a, b)", pvrfp::AtMost(a, b), t->le);
        one("a.atLeastPow2(e)", a.atLeastPow2(e), t->ge);
        pvrfp::perpVal = Fp::FromBits(reg & 0x7fffffff);   // refsw_lists.cpp RenderCORE L377-378
        one("Perpendicular(a)", pvrfp::Perpendicular(a), t->perp);
        one("CulledBySize(a)", p2fpref::culledBySize(a, reg), t->by_size);
        one("CulledByFacing(mode, a)", p2fpref::culledByFacing(mode, a), t->by_facing);
        if (litPerp >= 0)
            one("console: perpendicular", litPerp != 0, t->perp);
        if (litSize >= 0)
            one("console: culled by size", litSize != 0, t->by_size);
        if (litFacing >= 0)
            one("console: culled by facing", litFacing != 0, t->by_facing);
        if (litLe >= 0)
            one("console: a <= b", litLe != 0, t->le);
    }
};

// v in another representation: shifted left by k (exp down by k) where it fits 24 bits, or its trailing zeros gone
static Fp rep(const Fp& v, int k)
{
    Fp r = v;
    if (!v.mant)
        return r;
    if (k > 0) {
        const int room = 24 - bl(v.mant);
        const int s = std::min(k, room);
        r.mant <<= s;
        r.exp -= s;
    } else {
        while (!(r.mant & 1)) {
            r.mant >>= 1;
            r.exp++;
        }
    }
    return r;
}

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-cmp", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-cmp");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x636d70);

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            auto c = [&](const Fp& det, uint32_t reg, uint32_t mode, int perp, int size, int facing) {
                Case k;
                k.a = det;
                k.b = det;
                k.reg = reg;
                k.mode = mode;
                k.litPerp = perp;
                k.litSize = size;
                k.litFacing = facing;
                ls.push(k);
            };
            const Fp q = mk(false, false, -24, 0xC00000);   // 0.75
            // perpeq: equal counts, in any representation; the size only
            c(q, 0x3F400000, 0, 1, 1, 0);
            c(mk(false, false, -2, 3), 0x3F400000, 0, 1, 1, 0);
            c(mk(true, false, -23, 0x600000), 0x3F400000, 0, 1, 1, 0);
            c(mk(false, false, -24, 0xC00001), 0x3F400000, 0, 0, 0, 0);
            c(mk(false, false, -24, 0xC00000), 0xBF400000, 0, 1, 1, 0);           // the register's sign does not count
            // perpval / detinf: NaN and -infinity registers are +infinity; they take infinite determinants too
            c(mk(false, false, 120, 0xFFFFFF), 0x7FC00000, 0, 1, 1, 0);
            c(mk(false, true, 0, 0), 0x7FC00000, 0, 1, 0, 0);
            c(mk(false, true, 0, 0), 0xFF800000, 0, 1, 0, 0);
            c(mk(true, false, 100, 1), 0xFFC00000, 0, 1, 1, 0);
            c(mk(false, true, 0, 0), 0x3F800000, 0, 0, 0, 0);                    // a finite register: not an infinite det
            c(mk(false, false, 5, 0), 0x7FC00000, 0, 0, 1, 0);                   // a zero is not perpendicular (it is one)
            c(mk(false, false, -23, 1), 0x00000000, 0, 0, 0, 0);                 // register 0: nothing
            // cullval / raster page 4
            c(mk(false, false, -23, 0x800000), 0x3F800000, 0, 1, 1, 0);          // equal: culled
            c(mk(false, false, -23, 0x800001), 0x3F800000, 0, 0, 0, 0);
            c(mk(false, false, -24, 0x800000), 0xBF000000, 0, 1, 1, 0);          // -0.5 as 0.5
            c(mk(false, false, -25, 0x800000), 0x00000001, 0, 0, 0, 0);          // 2^-149 culls nothing
            c(mk(false, false, 200, 1), 0x7F7FFFFF, 0, 0, 0, 0);                 // the swamp value: never by size
            c(mk(false, false, 0, 0), 0x3F800000, 0, 0, 1, 0);                   // +0: always
            // facing (CullMode 2: below zero; 3: above), -0 and bad never
            c(mk(true, false, 0, 1), 0x00000000, 2, -1, -1, 1);
            c(mk(false, false, 0, 1), 0x00000000, 2, -1, -1, 0);
            c(mk(true, false, 0, 0), 0x00000000, 2, -1, -1, 0);
            c(mk(false, false, 0, 1), 0x00000000, 3, -1, -1, 1);
            c(mk(true, false, 0, 1), 0x00000000, 3, -1, -1, 0);
            c(mk(true, true, 0, 0), 0x00000000, 2, -1, -1, 0);
            c(mk(true, false, 0, 1), 0x00000000, 1, -1, -1, 0);
            // zeros of either sign are equal
            Case z;
            z.a = mk(true, false, 4, 0);
            z.b = mk(false, false, 9, 0);
            z.litLe = 1;
            ls.push(z);
            std::swap(z.a, z.b);
            ls.push(z);
        }
        sectionDone("fp-cmp", "directed", ls.cases() - n0);
    }
    if (a.want("regs")) {
        f.set("regs");
        const uint64_t n0 = ls.cases();
        static const uint32_t mants[4] = {0, 1, 0x400000, 0x7FFFFF};
        for (uint64_t i = 0; i < 256 * 4 * 2; i++)
            if (a.mine(i)) {
                const uint32_t reg = (uint32_t)(i & 1) << 31 | (uint32_t)(i >> 3) << 23 | mants[(i >> 1) & 3];
                const Fp v = Fp::FromBits(reg & 0x7fffffff);
                p2tb::Rng r = p2tb::Rng::of(a.seed, i);
                std::vector<Fp> dets = {mk(false, false, 0, 0), mk(true, false, 0, 0), mk(false, true, 0, 0),
                                        mk(true, true, 0, 0)};
                if (v.mant && !v.bad) {
                    for (int s = 0; s < 2; s++) {
                        for (int k : {0, 24, -1}) {
                            Fp d = rep(v, k);
                            d.neg = s;
                            dets.push_back(d);
                        }
                        Fp up = v, dn = v;
                        up.mant += 1;
                        dn.mant -= 1;
                        up.neg = dn.neg = s;
                        if (bl(up.mant) <= 24)
                            dets.push_back(up);
                        if (dn.mant)
                            dets.push_back(dn);
                    }
                } else {
                    Gen g(r);
                    dets.push_back(g.num(24, -150, 129, 0, 0));
                }
                for (const Fp& d : dets) {
                    Case c;
                    c.a = d;
                    c.b = v;
                    c.reg = reg;
                    c.mode = (uint32_t)r.below(4);
                    c.e = 128;
                    ls.push(c);
                }
            }
        sectionDone("fp-cmp", "regs", ls.cases() - n0);
    }
    if (a.want("pairs")) {
        f.set("pairs");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 10000000 : 1000000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x9a, i);
                Gen g(r);
                Case c;
                c.a = g.num(24, -280, 259, 50, 30, 300);
                switch (i % 4) {
                case 0: c.b = g.num(24, -280, 259, 50, 30, 300); break;
                case 1: c.b = rep(c.a, (int)g.r.range(-1, 24)); c.b.neg = g.r.u64() & 1; break;   // a tie
                case 2: {                                                                       // one unit off
                    c.b = c.a;
                    if (c.b.mant > 1 && bl(c.b.mant + 1) <= 24)
                        c.b.mant += (g.r.u64() & 1) ? 1 : -1;
                    break;
                }
                default: c.b = Gen::at(g.mant(24), c.a.mant ? c.a.top() + (int)g.r.range(-1, 1) : 0, g.r.u64() & 1);
                }
                c.e = (i & 8) ? 128 : c.a.mant ? c.a.top() + (int)g.r.range(-2, 1) : (int)g.r.range(-300, 300);
                c.e = std::max(-512, std::min(511, c.e));
                c.reg = g.r.chance(500) ? g.r.u32() : 0;   // half random registers, half b's own value (below)
                if (c.reg == 0 && c.b.mant && !c.b.bad) {
                    // the register at b's value, where b is one a register can hold
                    const Fp n24 = rep(c.b, 24);
                    const int fld = n24.exp + 150;
                    if (bl(n24.mant) == 24 && fld >= 1 && fld <= 254)
                        c.reg = (uint32_t)fld << 23 | (uint32_t)(n24.mant & 0x7FFFFF);
                }
                c.mode = (uint32_t)g.r.below(4);
                ls.push(c);
            }
        sectionDone("fp-cmp", "pairs", ls.cases() - n0);
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
                Case c;
                c.a = g.num(24, -200, 200, 50, 30, 300);
                c.b = g.num(24, -200, 200, 50, 30, 300);
                c.e = (int)g.r.range(-300, 300);
                c.reg = g.r.u32();
                c.mode = (uint32_t)g.r.below(4);
                ls.push(c);
            }
        ls.gaps(0);
        sectionDone("fp-cmp", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

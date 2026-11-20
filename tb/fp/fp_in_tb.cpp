// fp_in_tb.cpp: make fp-in. H4 against refcore pvr_softfp.h Fp::FromBits, Fp::FromSingle(u, 0 / 1), Fp::FromHalves,
// SingleBits(c, -8) and the copy of PlaneT::Value's `seen` (tb/fp/ref_copies.h) (docs/spec/numerics.md H4, 7.3). Every
// vector drives all five decoders: the word u, k, the coefficient and the colour are taken from one random draw.
//
// Sections (--only):
//   directed  the console facts as literals, independent of refcore: field 255 is an infinity (unsigned from FromBits,
//             with its sign ranged), a NaN too; field 0 is a zero ranged, a denormal unranged (uvmeas wexp, whuge,
//             wspec, cullval, perpval); a colour c enters as c 2^-8 (cmeas cwext1); seen: 2^-127 and 2^-128
//   fields    all 256 exponent fields x 128 mantissa patterns x both signs
//   all32     every 32-bit word (--full only)
//   halves    every 16-bit k
//   colour    every colour
//   seen      every class of coefficient: zeros, bad values with and without a mantissa, random 16-bit ones
//   stream    random words with random gap clocks
#include <memory>

#include "Vp2_fp_in_tb_top.h"
#include "fp_tb.h"
#include "ref_copies.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_in_tb_top Top;

struct Case {
    uint32_t u = 0;
    int16_t k = 0;
    Fp sn;
    uint8_t c = 0;
    // directed: the console's values, when given (else refcore's)
    bool lit = false;
    Fp lit0, lit1;
    uint32_t litw = 0;
    bool litW = false;

    void drive(Top* t) const
    {
        t->u = u;
        t->k = (uint16_t)k;
        FP_SET(t, sn, sn);
        t->c = c;
    }
    void check(Top* t, Fails& f) const
    {
        char in[64];
        snprintf(in, sizeof in, "u 0x%08x", u);
        auto ins = [&] { return std::string(in); };
        const Fp w0 = Fp::FromBits(u), w1 = Fp::FromSingle(u, true);
        expectFp(f, "FromBits", w0, FP_GET(t, s0), 24, ins);
        expectFp(f, "FromSingle(u, 0)", Fp::FromSingle(u, false), FP_GET(t, s0), 24, ins);
        expectFp(f, "FromSingle(u, 1)", w1, FP_GET(t, s1), 24, ins);
        if (lit) {
            expectFp(f, "console: FromBits", lit0, FP_GET(t, s0), 24, ins);
            expectFp(f, "console: FromSingle(u, 1)", lit1, FP_GET(t, s1), 24, ins);
        }
        expectFp(f, "FromHalves", Fp::FromHalves(k), FP_GET(t, h), 16, [&] { return "k " + std::to_string(k); });
        expectFp(f, "seen", p2fpref::seen(sn), FP_GET(t, so), 16, [&] { return str(sn); });
        const uint32_t want = pvrfp::SingleBits(c, -8);
        expect(f, t->w == want, [&] {
            char b[96];
            snprintf(b, sizeof b, "SingleBits(%u, -8) = 0x%08x, want 0x%08x", c, t->w, want);
            return std::string(b);
        });
        if (litW)
            expect(f, t->w == litw, [&] {
                char b[96];
                snprintf(b, sizeof b, "console: colour %u = 0x%08x, want 0x%08x", c, t->w, litw);
                return std::string(b);
            });
    }
};

// a random draw: the word and the other decoders' inputs taken from it
static Case fromWord(uint32_t u, p2tb::Rng& r)
{
    Case c;
    c.u = u;
    c.k = (int16_t)(u ^ (u >> 16));
    c.c = (uint8_t)(u >> 3);
    Gen g(r);
    c.sn = g.num(16, -140, 140, 100, 60, 500);
    return c;
}

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-in", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-in");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x696e);

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            p2tb::Rng r(a.seed);
            auto word = [&](uint32_t u, Fp l0, Fp l1) {
                Case c = fromWord(u, r);
                c.lit = true;
                c.lit0 = l0;
                c.lit1 = l1;
                ls.push(c);
            };
            word(0x7F800000, mk(false, true, 0, 0), mk(false, true, 0, 0));        // +inf
            word(0xFF800000, mk(false, true, 0, 0), mk(true, true, 0, 0));         // -inf: unsigned unranged
            word(0x7FC00000, mk(false, true, 0, 0), mk(false, true, 0, 0));        // NaN: an infinity
            word(0xFFFFFFFF, mk(false, true, 0, 0), mk(true, true, 0, 0));
            word(0x00000001, mk(false, false, -149, 1), mk(false, false, 0, 0));   // 2^-149: a zero ranged
            word(0x80400000, mk(true, false, -149, 0x400000), mk(true, false, 0, 0));
            word(0x00800000, mk(false, false, -149, 0x800000), mk(false, false, -149, 0x800000));   // 2^-126
            word(0x3F800000, mk(false, false, -23, 0x800000), mk(false, false, -23, 0x800000));     // 1.0
            word(0x7F7FFFFF, mk(false, false, 104, 0xFFFFFF), mk(false, false, 104, 0xFFFFFF));     // the largest
            word(0x80000000, mk(true, false, 0, 0), mk(true, false, 0, 0));        // -0
            // colours: c 2^-8 (cmeas cwext1)
            auto colour = [&](uint8_t cc, uint32_t wv) {
                Case c = fromWord(0, r);
                c.c = cc;
                c.litW = true;
                c.litw = wv;
                ls.push(c);
            };
            colour(255, 0x3F7F0000);   // 255 / 256
            colour(128, 0x3F000000);   // 0.5
            colour(1, 0x3B800000);     // 2^-8
            colour(0, 0x00000000);
        }
        sectionDone("fp-in", "directed", ls.cases() - n0);
    }
    if (a.want("fields")) {
        f.set("fields");
        const uint64_t n0 = ls.cases();
        for (uint64_t i = 0; i < 256 * 128 * 2; i++)
            if (a.mine(i)) {
                const uint32_t fld = (uint32_t)(i >> 8) & 0xFF, s = (uint32_t)(i & 1), pat = (uint32_t)(i >> 1) & 0x7F;
                p2tb::Rng r = p2tb::Rng::of(a.seed, i);
                uint32_t m;
                switch (pat) {
                case 0: m = 0; break;
                case 1: m = 1; break;
                case 2: m = 0x400000; break;
                case 3: m = 0x7FFFFF; break;
                case 4: m = 0x000001 << (r.below(23)); break;
                default: m = r.u32() & 0x7FFFFF;
                }
                ls.push(fromWord(s << 31 | fld << 23 | m, r));
            }
        sectionDone("fp-in", "fields", ls.cases() - n0);
    }
    if (a.want("all32") && a.full) {
        f.set("all32");
        const uint64_t n0 = ls.cases();
        uint64_t lo, hi;
        a.range(1ull << 32, &lo, &hi);
        // the other decoders' inputs from the word's own bits (no draw: 2^32 cases)
        Case c;
        for (uint64_t u = lo; u < hi; u++) {
            c.u = (uint32_t)u;
            c.k = (int16_t)(u ^ (u >> 16));
            c.c = (uint8_t)(u >> 3);
            c.sn = mk(u & 1, (u & 0x300) == 0x300, (int)((u >> 2) & 0x1FF) - 256, (u >> 16) & ((u & 0x400) ? 0xFFFF : 0));
            ls.push(c);
        }
        sectionDone("fp-in", "all32", ls.cases() - n0);
    }
    if (a.want("halves")) {
        f.set("halves");
        const uint64_t n0 = ls.cases();
        for (uint64_t i = 0; i < 65536; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x68, i);
                Case c = fromWord(r.u32(), r);
                c.k = (int16_t)(uint16_t)i;
                ls.push(c);
            }
        sectionDone("fp-in", "halves", ls.cases() - n0);
    }
    if (a.want("colour")) {
        f.set("colour");
        const uint64_t n0 = ls.cases();
        for (uint64_t i = 0; i < 256; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x63, i);
                Case c = fromWord(r.u32(), r);
                c.c = (uint8_t)i;
                ls.push(c);
            }
        sectionDone("fp-in", "colour", ls.cases() - n0);
    }
    if (a.want("seen")) {
        f.set("seen");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 2000000 : 200000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x73, i);
                Case c = fromWord(r.u32(), r);
                Gen g(r);
                switch (i % 4) {
                case 0: c.sn = mk(g.r.u64() & 1, false, (int)g.r.range(-300, 300), 0); break;   // +-0
                case 1: c.sn = mk(g.r.u64() & 1, true, (int)g.r.range(-300, 300), 0); break;    // bad
                case 2: c.sn = Gen::at(g.mant(16), g.top(-140, 140), g.r.u64() & 1); c.sn.bad = true; break;
                default: c.sn = g.num(16, -150, 150, 0, 0); break;
                }
                ls.push(c);
            }
        sectionDone("fp-in", "seen", ls.cases() - n0);
    }
    if (a.want("stream")) {
        f.set("stream");
        const uint64_t n0 = ls.cases();
        ls.gaps(300);
        const uint64_t n = a.full ? 2000000 : 200000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x5157, i);
                ls.push(fromWord(r.u32(), r));
            }
        ls.gaps(0);
        sectionDone("fp-in", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

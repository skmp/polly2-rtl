// fp_colour_tb.cpp: make fp-colour. H15 p2_fp_color_round against refcore pvr_tsp_plane.h ColorRounded(q, -8, max,
// fallback) at 708fb8cd (docs/spec/numerics.md H15, 7.3; PLAN M1c), at both of p2_pp_col's clamps on the same quotient
// each clock: max 255 (offset colours) and 65535 (the base colour before the intensity shadow's scale), scaleExp -8
// (refsw_tile.h ColorExp), through the divider's 18-bit quotient port.
//
// Sections (--only):
//   directed  console facts as literals: cmeas (2,340,000 of 2,340,000: floor(v + 1/2), half way up: a quotient of
//             exactly 0.5 / 256 is 1, the next one down 0; 255.5 / 256 is 256, clamped to 255); cmeas wext ("where every
//             product is an infinity or a zero the quotient is just under 1, which is white": 0xFFFF 2^-16 is 255);
//             huge (a flagged quotient: the fallback, the vertex's colour); a quotient below zero or of zero: 0; from
//             2^22 the clamp
//   sweep     every 17-bit mantissa x exponent -40 .. 20 x both signs (~16M clocks, both clamps each; --full; quick:
//             2^14 random mantissas)
//   rand      random tuples: 1 .. 18-bit mantissas at exponents over the whole field, zeros, flagged values with and
//             without a mantissa, random fallbacks
//   stream    random tuples with random gap clocks
#include <memory>

#include "Vp2_fp_colour_tb_top.h"
#include "fp_tb.h"
#include "pvr_tsp_plane.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_colour_tb_top Top;

namespace {

constexpr int kSE = -8;      // refsw_tile.h IPs3::ColorExp
constexpr int kQW = 18;      // P2_QUOT_MANT_BITS

struct Case {
    Fp q;
    unsigned fallback = 0;
    bool lit = false;
    int lit255 = 0, lit65535 = 0;
    const char* litWhat = "";

    void drive(Top* t) const
    {
        t->q_neg = q.neg;
        t->q_bad = q.bad;
        t->q_exp = (SData)efield(q.exp);
        t->q_mant = (IData)q.mant;
        t->fallback = fallback;
    }
    void check(Top* t, Fails& f) const
    {
        auto in = [&] { return str(q) + " fallback " + std::to_string(fallback); };
        expect(f, mantFits(q.mant, kQW) && (q.mant == 0 || expFits(q.exp)),
               [&] { return "the quotient " + in() + " does not fit the port"; });
        const int w255 = pvrtsp::ColorRounded(q, kSE, 255, (int)fallback);
        const int w65535 = pvrtsp::ColorRounded(q, kSE, 65535, (int)fallback);
        expect(f, (int)t->c255 == w255,
               [&] { return "color_round max 255: got " + std::to_string(t->c255) + " want " + std::to_string(w255) + "; " + in(); });
        expect(f, (int)t->c65535 == w65535, [&] {
            return "color_round max 65535: got " + std::to_string(t->c65535) + " want " + std::to_string(w65535) + "; " + in();
        });
        if (lit)
            expect(f, (int)t->c255 == lit255 && (int)t->c65535 == lit65535, [&] {
                return std::string("console: ") + litWhat + ": got " + std::to_string(t->c255) + " / " +
                       std::to_string(t->c65535) + " want " + std::to_string(lit255) + " / " + std::to_string(lit65535) +
                       "; " + in();
            });
    }
};

}   // namespace

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-colour", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-colour");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x636f6c);
    auto push = [&](const Fp& q, unsigned fb) {
        Case c;
        c.q = q;
        c.fallback = fb;
        ls.push(c);
    };

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            auto lit = [&](const Fp& q, unsigned fb, int c255, int c65535, const char* what) {
                Case c;
                c.q = q;
                c.fallback = fb;
                c.lit = true;
                c.lit255 = c255;
                c.lit65535 = c65535;
                c.litWhat = what;
                ls.push(c);
            };
            lit(mk(false, false, -9, 1), 7, 1, 1, "cmeas: 0.5 / 256 is half way: up, 1");
            lit(mk(false, false, -26, 0x1FFFF), 7, 0, 0, "cmeas: just under 0.5 / 256 is 0");
            lit(mk(false, false, -9, 3), 7, 2, 2, "cmeas: 1.5 / 256 is 2");
            lit(mk(false, false, -16, 0x8080), 7, 129, 129, "cmeas: 128.5 / 256 is 129");
            lit(mk(false, false, -17, 0x100FF), 7, 128, 128, "cmeas: just under 128.5 / 256 is 128");
            lit(mk(false, false, -9, 511), 7, 255, 256, "cmeas: 255.5 / 256 is 256: clamped to 255");
            lit(mk(false, false, -16, 0xFFFF), 7, 255, 256, "cmeas wext: a quotient just under 1 is white");
            lit(mk(false, true, 0, 0), 0x86, 0x86, 0x86, "huge: a flagged quotient draws the vertex's colour");
            lit(mk(true, true, 0, 0), 0x12, 0x12, 0x12, "huge: a flagged quotient below zero likewise");
            lit(mk(true, false, -17, 0x1FFFF), 7, 0, 0, "a quotient below zero is 0");
            lit(mk(true, false, -40, 0), 7, 0, 0, "a quotient of -0 is 0");
            lit(mk(false, false, 22, 1), 7, 255, 65535, "2^22: the clamp (top - scaleExp > 30)");
            lit(mk(false, false, 5, 0x1FFFF), 7, 255, 65535, "just under 2^22: above max before the rounding");
            lit(mk(false, false, 0, 0xFF), 7, 255, 65280, "255: 65280 under the 16-bit clamp");
        }
        sectionDone("fp-colour", "directed", ls.cases() - n0);
    }
    if (a.want("sweep")) {
        f.set("sweep");
        const uint64_t n0 = ls.cases();
        const int ne = 61;   // exponent -40 .. 20
        if (a.full) {
            const uint64_t total = (uint64_t)((1u << 17) - 1) * ne * 2;
            uint64_t lo, hi;
            a.range(total, &lo, &hi);
            for (uint64_t k = lo; k < hi; k++) {
                const uint64_t m = 1 + k / (ne * 2);
                push(mk(k & 1, false, -40 + (int)((k >> 1) % ne), m), (unsigned)(k & 255));
            }
        } else {
            const uint64_t nm = a.count(1u << 14);
            for (uint64_t j = 0; j < nm; j++)
                if (a.mine(j)) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x5357, j);
                    const uint64_t m = 1 + r.below((1u << 17) - 1);
                    for (int e = 0; e < ne; e++)
                        for (int s = 0; s < 2; s++)
                            push(mk(s, false, -40 + e, m), (unsigned)(j & 255));
                }
        }
        sectionDone("fp-colour", "sweep", ls.cases() - n0);
    }
    auto randQ = [&](uint64_t salt, uint64_t i, unsigned* fb) {
        p2tb::Rng r = p2tb::Rng::of(a.seed ^ salt, i);
        Gen g(r);
        *fb = (unsigned)g.r.below(256);
        const bool neg = g.r.chance(200);
        if (g.r.chance(30))
            return mk(neg, true, (int)g.r.range(-300, 300), 0);
        if (g.r.chance(30))
            return mk(neg, false, (int)g.r.range(-300, 300), 0);
        const uint64_t m = g.mant((int)g.r.range(1, kQW));
        // tops of the colour's world (-30 .. 40 around the rounding and the clamp) and of the field's
        const int tp = g.r.chance(700) ? (int)g.r.range(-30, 40) : (int)g.r.range(-490, 500);
        return Gen::at(m, tp, neg);
    };
    if (a.want("rand")) {
        f.set("rand");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 20000000 : 1000000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                unsigned fb;
                const Fp q = randQ(0x52A4D, i, &fb);
                push(q, fb);
            }
        sectionDone("fp-colour", "rand", ls.cases() - n0);
    }
    if (a.want("stream")) {
        f.set("stream");
        const uint64_t n0 = ls.cases();
        ls.gaps(300);
        const uint64_t n = a.full ? 2000000 : 200000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                unsigned fb;
                const Fp q = randQ(0x5157, i, &fb);
                push(q, fb);
            }
        ls.gaps(0);
        sectionDone("fp-colour", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

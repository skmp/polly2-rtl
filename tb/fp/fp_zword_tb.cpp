// fp_zword_tb.cpp: make fp-zword. H14 p2_zword_pkg against refcore pvr_isp_depth.h StoredDepth (Key32, Bits, Between,
// FromFp, Big, Neg, Flat, Saturated), DepthTileT::RegDepth, and the verbatim copy of refsw_lists.cpp's background key
// (tb/fp/ref_copies.h p2fpref::bgKey) (docs/spec/numerics.md H14, 7.3; PLAN M1b). Keys are compared as the 64-bit
// order key, never as a word; where refsw3 also has a word (`bits`, for logs and the probes), the RTL's key is turned
// back into one by tb/common/zkey.h and compared with it (the inverse the testbenches and the depth tap rely on).
//
// Sections (--only):
//   directed  console facts with the console's words as literals, independent of refsw3: zword's whole steps of the
//             overflow register, nantr's +-(2^127 + 2^110), depthgaps_mm's order of the 32 steps; bgtie, bgdepth,
//             bgspec, bgbig, bgpin, depthgaps_bglow / bglow2 / bglow3 (the background against flat polygons),
//             perpmean_negstore, depthgaps_neggrid (the 0x100 groups and field 2's 0x400 groups), depthgaps_edges
//             (denormals), depthgaps_bigpos / bigord (Big), zsign (the order of 20 depths)
//   words     key32, bits and bgkey on every 32-bit word (--full, sharded in ranges); quick: every exponent field x 64
//             fractions x both signs, the boundary words, and 2^20 random words
//   between   random words and offsets 1 .. 2^32 - 1
//   fromfp    every 19-bit mantissa (and the 20-bit ones) at every exponent -175 .. 130, both signs (--full); quick:
//             every 17-bit mantissa at the exponents around the denormal boundary, and random tuples; bad, zeros
//   big       every 19-bit mantissa at every exponent with top 129 .. 531 (--full); quick: random
//   neg       E -122 .. 128 x every M in [-2^23, 0) (--full); quick: every E x M around -2^15, -2^16, -2^30 and
//             -2^k +- 3; M below -2^30 (driven as -2^30: the key no longer moves)
//   flat      every 20-bit mantissa x 8 exponents (both clamps of E, the window) x both signs (--full: all; quick: every
//             13th), random 24-bit tuples (tops -200 .. 170), bad, zeros
//   sat       both signs
//   regdepth  every 30-bit register (--full), with random bits above the wrap; quick: every whole step and its
//             neighbours, 2^26 +- k, -2^29, and 2^21 random registers; 64-bit registers (refsw3 wraps them)
//   stream    a random mix of every function with random gap clocks
#include <memory>
#include <vector>

#include "Vp2_fp_zword_tb_top.h"
#include "fp_tb.h"
#include "ref_copies.h"
#include "vecgen.h"
#include "zkey.h"

using namespace fptb;
using pvrisp::StoredDepth;
typedef Vp2_fp_zword_tb_top Top;

namespace {

enum Out { O_KEY32, O_BITS, O_BETWEEN, O_BG, O_FROMFP, O_BIG, O_NEG, O_FLAT, O_SAT, O_REG, O_N };
const char* const kOutName[O_N] = {"key32", "bits", "between", "bgkey", "from_fp", "big", "neg", "flat", "saturated",
                                   "regdepth"};

// the spec's key of a word (num H14 a), for the directed facts: independent of refsw3
int64_t litKey(uint32_t w)
{
    const int32_t k = w == 0x80000000u ? 0 : (int32_t)(w ^ ((w >> 31) ? 0x007fffffu : 0));
    return (int64_t)k * ((int64_t)1 << 32);
}
int64_t litBetween(uint32_t w, uint32_t off) { return litKey(w) + off; }

uint64_t readOut(Top* t, int o)
{
    switch (o) {
    case O_KEY32: return t->o_key32;
    case O_BITS: return t->o_bits;
    case O_BETWEEN: return t->o_between;
    case O_BG: return t->o_bg;
    case O_FROMFP: return t->o_fromfp;
    case O_BIG: return t->o_big;
    case O_NEG: return t->o_neg;
    case O_FLAT: return t->o_flat;
    case O_SAT: return t->o_sat;
    default: return t->o_reg;
    }
}

// a relation the directed facts check: output a against a literal key (b < 0) or against output b of the same case
struct Rel {
    int8_t a = -1, b = -1;
    int8_t rel = 0;      // 0 ==, 1 >, -1 <
    int64_t lit = 0;
};

uint64_t g_rtMask = 0;   // round trips through zkey.h on one case in (g_rtMask + 1)

struct Case {
    uint32_t w = 0, off = 1;
    Fp v20, v24;
    int e = 0;
    int64_t m = -1;          // M as refsw3 gets it; the port gets max(M, -2^30)
    bool sat = false;
    int64_t r = 0;           // the register as refsw3 gets it (64 bits); the port gets its low 32 bits
    uint16_t what = 0;       // the outputs compared with refsw3
    uint64_t idx = 0;
    Rel rel[2];
    int64_t* sink = nullptr; // the directed facts' cross-case orders: where output `sinkOut` goes
    int8_t sinkOut = -1;
    const char* fact = nullptr;

    void drive(Top* t) const
    {
        t->w = w;
        t->off = off;
        FP_SET(t, v20, v20);
        FP_SET(t, v24, v24);
        t->e = efield(e);
        const int64_t mp = m < -((int64_t)1 << 30) ? -((int64_t)1 << 30) : m;
        t->m = (uint32_t)mp & 0x7fffffffu;
        t->sat_s = sat;
        t->r = (uint32_t)r;
    }
    std::string in() const
    {
        char b[256];
        snprintf(b, sizeof b, "w 0x%08x off 0x%x v20 %s v24 %s e %d m %lld sat %d r %lld (0x%llx)", w, off,
                 str(v20).c_str(), str(v24).c_str(), e, (long long)m, (int)sat, (long long)r, (unsigned long long)r);
        return b;
    }
    // the key's word back through zkey.h, against refsw3's
    void roundTrip(Fails& f, const char* what, int64_t got, const StoredDepth& want) const
    {
        if (g_rtMask && (idx & g_rtMask))
            return;
        if (want.k == 0)
            return;                     // -0 and +0 share key 0; zkey.h gives the word 0
        const uint32_t b = p2tb::zkey_bits(got, 0xdeadbeefu);
        expect(f, b == want.bits, [&] {
            char s[160];
            snprintf(s, sizeof s, "%s: zkey.h gives the word 0x%08x for key 0x%016llx, refsw3 has 0x%08x; ", what, b,
                     (unsigned long long)got, want.bits);
            return std::string(s) + in();
        });
    }
    void checkKey(Fails& f, int o, int64_t got, const StoredDepth& want, bool rt) const
    {
        expect(f, got == want.k, [&] {
            char s[160];
            snprintf(s, sizeof s, "%s: got 0x%016llx want 0x%016llx (refsw3 bits 0x%08x); ", kOutName[o],
                     (unsigned long long)got, (unsigned long long)want.k, want.bits);
            return std::string(s) + in();
        });
        if (rt)
            roundTrip(f, kOutName[o], got, want);
    }
    void check(Top* t, Fails& f) const
    {
        if (what & (1u << O_KEY32)) {
            const int32_t got = (int32_t)t->o_key32, want = StoredDepth::Key32(w);
            expect(f, got == want, [&] {
                char s[96];
                snprintf(s, sizeof s, "key32: got 0x%08x want 0x%08x; ", (uint32_t)got, (uint32_t)want);
                return std::string(s) + in();
            });
        }
        if (what & (1u << O_BITS))
            checkKey(f, O_BITS, (int64_t)t->o_bits, StoredDepth::Bits(w), false);
        if (what & (1u << O_BETWEEN))
            checkKey(f, O_BETWEEN, (int64_t)t->o_between, StoredDepth::Between(w, off, 0), false);
        if (what & (1u << O_BG))
            checkKey(f, O_BG, (int64_t)t->o_bg, p2fpref::bgKey(w), true);
        if (what & (1u << O_FROMFP))
            checkKey(f, O_FROMFP, (int64_t)t->o_fromfp, StoredDepth::FromFp(v20), true);
        if (what & (1u << O_BIG)) {
            // the domain: above zero, not bad, top 129 .. 531, at most 20 bits
            if (v20.bad || v20.neg || v20.zero() || v20.top() < 129)
                f.ok(false, "big: vector outside the domain: %s", in().c_str());
            else
                checkKey(f, O_BIG, (int64_t)t->o_big, StoredDepth::Big(v20), true);
        }
        if (what & (1u << O_NEG)) {
            if (e < -122 || e > 128 || m >= 0)
                f.ok(false, "neg: vector outside the domain: %s", in().c_str());
            else
                checkKey(f, O_NEG, (int64_t)t->o_neg, StoredDepth::Neg(e, m), m >= -((int64_t)1 << 30));
        }
        if (what & (1u << O_FLAT)) {
            if (!v24.bad && !v24.zero() && v24.top() > 170)
                f.ok(false, "flat: vector outside the domain: %s", in().c_str());
            else
                checkKey(f, O_FLAT, (int64_t)t->o_flat, StoredDepth::Flat(v24, 20, 19), true);
        }
        if (what & (1u << O_SAT))
            checkKey(f, O_SAT, (int64_t)t->o_sat, StoredDepth::Saturated(sat), false);
        if (what & (1u << O_REG))
            checkKey(f, O_REG, (int64_t)t->o_reg, pvrisp::DepthTile::RegDepth(r), true);
        for (const Rel& x : rel) {
            if (x.a < 0)
                continue;
            const int64_t ka = (int64_t)readOut(t, x.a);
            const int64_t kb = x.b < 0 ? x.lit : (int64_t)readOut(t, x.b);
            const bool ok = x.rel == 0 ? ka == kb : x.rel > 0 ? ka > kb : ka < kb;
            expect(f, ok, [&] {
                char s[256];
                snprintf(s, sizeof s, "%s: %s 0x%016llx %s %s 0x%016llx does not hold; ", fact ? fact : "fact",
                         kOutName[(int)x.a], (unsigned long long)ka, x.rel == 0 ? "==" : x.rel > 0 ? ">" : "<",
                         x.b < 0 ? "the literal" : kOutName[(int)x.b], (unsigned long long)kb);
                return std::string(s) + in();
            });
        }
        if (sink)
            *sink = (int64_t)readOut(t, sinkOut);
    }
};

Fp single(uint32_t u) { return Fp::FromBits(u); }

}   // namespace

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-zword", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-zword");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x7a77);
    uint64_t idx = 0;
    auto push = [&](Case c) {
        c.idx = idx++;
        ls.push(c);
    };
    auto onW = [&](uint32_t w) {
        Case c;
        c.w = w;
        c.what = (1u << O_KEY32) | (1u << O_BITS) | (1u << O_BG);
        push(c);
    };
    auto onFromFp = [&](const Fp& v) {
        Case c;
        c.v20 = v;
        c.what = 1u << O_FROMFP;
        push(c);
    };
    auto onBig = [&](const Fp& v) {
        Case c;
        c.v20 = v;
        c.what = 1u << O_BIG;
        push(c);
    };
    auto onNeg = [&](int e, int64_t m) {
        Case c;
        c.e = e;
        c.m = m;
        c.what = 1u << O_NEG;
        push(c);
    };
    auto onFlat = [&](const Fp& v) {
        Case c;
        c.v24 = v;
        c.what = 1u << O_FLAT;
        push(c);
    };
    auto onReg = [&](int64_t r) {
        Case c;
        c.r = r;
        c.what = 1u << O_REG;
        push(c);
    };
    // a random value of at most `bits` bits whose top lies in [lo, hi]
    auto randTop = [&](Gen& g, int bits, int lo, int hi) {
        const uint64_t m = g.mant(bits);
        return Gen::at(m, g.top(lo, hi), g.r.u64() & 1);
    };

    // ---------------------------------------------------------------------------------------------------------
    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            auto fact = [&](const char* name, Case c, Rel r0, Rel r1 = Rel()) {
                c.fact = name;
                c.rel[0] = r0;
                c.rel[1] = r1;
                push(c);
            };
            auto lit = [](int o, int rel, int64_t k) {
                Rel r;
                r.a = (int8_t)o;
                r.rel = (int8_t)rel;
                r.lit = k;
                return r;
            };
            auto outs = [](int o, int rel, int ob) {
                Rel r;
                r.a = (int8_t)o;
                r.b = (int8_t)ob;
                r.rel = (int8_t)rel;
                return r;
            };
            // zword: the overflow register at whole steps m (r = m 2^25, m mod 32 a 5-bit two's complement number):
            // 0 is 0, 1 is 2^127, 2 .. 15 above every probe (the largest 0x7f7fffe0), 16 below every probe (the
            // lowest 0xc2ffffe0), 23 and 30 the bottoms of fields 253 and 254, 31 is -2^127
            std::vector<int64_t> step(32);
            for (int m = 0; m < 32; m++) {
                Case c;
                c.r = (int64_t)m << 25;
                c.what = 1u << O_REG;
                c.sink = &step[m];
                c.sinkOut = O_REG;
                Rel r0;
                if (m == 0) r0 = lit(O_REG, 0, 0);
                else if (m == 1) r0 = lit(O_REG, 0, litKey(0x7f000000u));
                else if (m <= 15) r0 = lit(O_REG, 1, litKey(0x7f7fffe0u));
                else if (m == 16) r0 = lit(O_REG, -1, litKey(0xc2ffffe0u));
                else if (m == 23) r0 = lit(O_REG, 0, litKey(0xfeffffe0u));
                else if (m == 30) r0 = lit(O_REG, 0, litKey(0xff7fffe0u));
                else if (m == 31) r0 = lit(O_REG, 0, litKey(0xff000000u));
                fact("zword whole steps", c, r0);
                // the mirror, steps of -2^127 from 0 (zword: word for word): the same register values
                Case d = c;
                d.r = -((int64_t)(32 - m) << 25);
                d.sink = nullptr;
                fact("zword mirror", d, r0);
            }
            // depthgaps_mm: -16 < -15 < .. < -1 < 0 < 1 < .. < 15, no two equal
            for (int k = 0; k < 31; k++) {
                const int lo = (k + 16) & 31, hi = (k + 17) & 31;
                expect(f, step[lo] < step[hi], [&] {
                    char s[128];
                    snprintf(s, sizeof s, "depthgaps_mm: step %d (key 0x%016llx) not below step %d (0x%016llx)",
                             lo, (unsigned long long)step[lo], hi, (unsigned long long)step[hi]);
                    return std::string(s);
                });
            }
            // nantr: 2^127 + 2^110 as itself, -(2^127 + 2^110) as 0xff000100 (E 128, M -(2^15 + 1)); 2^119 - 9 steps
            // as 0xfeff0000
            {
                Case c;
                c.what = 1u << O_REG;
                c.r = ((int64_t)1 << 25) + (1 << 8);
                fact("nantr_fin 2^127 + 2^110", c, lit(O_REG, 0, litKey(0x7f000040u)));
                c.r = -(((int64_t)1 << 25) + (1 << 8));
                fact("nantr_fin -(2^127 + 2^110)", c, lit(O_REG, 0, litKey(0xff000100u)));
                c.r = ((int64_t)1 << 17) - 9 * ((int64_t)1 << 25);
                fact("nantr_fin2 2^119 - 9 steps", c, lit(O_REG, 0, litKey(0xfeff0000u)));
            }
            // the background (bgtie, bgdepth, bgspec, bgbig, bgpin)
            {
                Case c;
                c.what = 1u << O_BG;
                c.w = 0x3f000010u;   // 0.5 + 2^-20 ties with a polygon at 0.5
                fact("bgtie", c, lit(O_BG, 0, litKey(0x3f000000u)));
                c.w = 0x35000000u;   // 2^-21: zero
                fact("bgdepth below 2^-20", c, lit(O_BG, 0, 0));
                c.w = 0x35800000u;   // 2^-20: kept
                fact("bgdepth 2^-20", c, lit(O_BG, 0, litKey(0x35800000u)));
                c.w = 0x7f800000u;   // +inf: 2^127, ties with a polygon that overflows
                fact("bgspec +inf", c, lit(O_BG, 0, litKey(0x7f000000u)));
                c.w = 0x7f800001u;   // its fraction cut
                fact("bgspec 0x7f800001", c, lit(O_BG, 0, litKey(0x7f000000u)));
                c.w = 0x7fc00000u;   // a NaN: above 2^127
                fact("bgspec NaN", c, lit(O_BG, 1, litKey(0x7f000000u)));
                c.w = 0x7f7fffffu;   // the largest float, 0x7f7fffe0 cut: above 2^127
                fact("bgbig largest", c, lit(O_BG, 1, litKey(0x7f000000u)));
                c.w = 0x7f000000u;   // 2^127 ties
                fact("bgbig 2^127", c, lit(O_BG, 0, litKey(0x7f000000u)));
                c.w = 0xff800000u;   // -inf: -2^127
                fact("bgspec -inf", c, lit(O_BG, 0, litKey(0xff000000u)));
                for (uint32_t w : {0xb5000000u, 0x80000001u, 0x80000000u}) {   // -2^-21, -2^-149, -0: 0
                    c.w = w;
                    fact("bgspec below -2^-20", c, lit(O_BG, 0, 0));
                }
                // bgpin: -1 and -1 - 2^-23 tie with a ramp's -1 of E 6 (M -1024); -2^-20 with its -2^-10 (M -1)
                c.w = 0xbf800000u;
                fact("depthgaps_bgpin -1", c, lit(O_BG, 0, litBetween(0xc2000000u, 32768 - 1024)));
                c.w = 0xbf800001u;
                fact("depthgaps_bgpin -1 - 2^-23", c, lit(O_BG, 0, litBetween(0xc2000000u, 32768 - 1024)));
                c.w = 0xb5800000u;
                fact("depthgaps_bgpin -2^-20", c, lit(O_BG, 0, litBetween(0xc2000000u, 32768 - 1)));
            }
            // depthgaps_bglow, bglow2: the background W + L against flat polygons at W: L 0 .. 15 tie, 16 .. 31 below;
            // with W's fraction 0x7fffe0 all 32 tie; bglow3: 16 .. 31 tie with W + 0x20 (a flat polygon stores it as
            // W + 0x100)
            for (uint32_t W : {0xc2800000u, 0xc2c80000u, 0xc9800000u, 0xf1800000u, 0xff000000u}) {
                for (uint32_t L = 0; L < 32; L++) {
                    Case c;
                    c.what = (1u << O_BG) | (1u << O_FLAT);
                    c.w = W + L;
                    c.v24 = single(W);
                    fact("depthgaps_bglow", c, outs(O_BG, L < 16 ? 0 : -1, O_FLAT));
                    if (L >= 16) {
                        c.v24 = single(W + 0x20);
                        fact("depthgaps_bglow3", c, outs(O_BG, 0, O_FLAT));
                    }
                }
            }
            for (uint32_t W : {0xc2ffffe0u, 0xfeffffe0u, 0xff7fffe0u})
                for (uint32_t L = 0; L < 32; L++) {
                    Case c;
                    c.what = (1u << O_BG) | (1u << O_FLAT);
                    c.w = W + L;
                    c.v24 = single(W);
                    fact("depthgaps_bglow2 fraction 0x7fffe0", c, outs(O_BG, 0, O_FLAT));
                }
            // perpmean_negstore page 0: flat quads at -0x42ffffff and just over -2^14 tie with the backgrounds
            // 0xc2ffffe0 and 0xc67fffe0
            {
                Case c;
                c.what = (1u << O_BG) | (1u << O_FLAT);
                c.v24 = single(0xc2ffffffu);
                c.w = 0xc2ffffe0u;
                fact("perpmean_negstore", c, outs(O_FLAT, 0, O_BG), lit(O_FLAT, 0, litKey(0xc2ffffe0u)));
                c.v24 = single(0xc67fffffu);
                c.w = 0xc67fffe0u;
                fact("perpmean_negstore", c, outs(O_FLAT, 0, O_BG), lit(O_FLAT, 0, litKey(0xc67fffe0u)));
            }
            // depthgaps_neggrid: flat depths below zero tie in groups of 0x100 of the word (rounded up in size), the
            // top group with 0x7fffe0; field 2 (E -122's grid 2^-138) in groups of 0x400: 0x12340 with 0x121c0 ..
            // 0x12400, not 0x12420. The groups' edges sit 0x10 up: the start's 20-bit cut comes first
            // (depthgaps_detneg: -100 - d ulp is -100 for d = 1 .. 15, -100 - 0x100 ulp for d = 16 .. 0x10f)
            for (uint32_t base : {0xc0000000u, 0x82800000u, 0xd5000000u, 0xf0000000u}) {
                for (uint32_t frac : {0x000010u, 0x000080u, 0x0000ffu, 0x000100u, 0x00010fu}) {
                    Case c;
                    c.what = 1u << O_FLAT;
                    c.v24 = single(base | frac);
                    fact("depthgaps_neggrid 0x100 groups", c, lit(O_FLAT, 0, litKey(base | 0x100u)));
                }
                {
                    Case c;
                    c.what = 1u << O_FLAT;
                    c.v24 = single(base | 0x00000fu);
                    fact("depthgaps_detneg d = 15", c, lit(O_FLAT, 0, litKey(base)));
                    c.v24 = single(base | 0x000110u);
                    fact("depthgaps_detneg d = 0x110", c, lit(O_FLAT, 0, litKey(base | 0x200u)));
                }
                for (uint32_t frac : {0x7fff10u, 0x7fffe0u, 0x7fffffu}) {
                    Case c;
                    c.what = 1u << O_FLAT;
                    c.v24 = single(base | frac);
                    fact("depthgaps_neggrid top group", c, lit(O_FLAT, 0, litKey(base | 0x7fffe0u)));
                }
            }
            {
                std::vector<int64_t> g(4);
                const uint32_t fr[4] = {0x12340u, 0x121c0u, 0x12400u, 0x12420u};
                for (int k = 0; k < 4; k++) {
                    Case c;
                    c.what = 1u << O_FLAT;
                    c.v24 = single(0x81000000u | fr[k]);
                    c.sink = &g[k];
                    c.sinkOut = O_FLAT;
                    push(c);
                }
                f.ok(g[0] == g[1] && g[0] == g[2] && g[3] != g[0],
                     "depthgaps_neggrid field 2: 0x12340 0x%llx, 0x121c0 0x%llx, 0x12400 0x%llx, 0x12420 0x%llx",
                     (unsigned long long)g[0], (unsigned long long)g[1], (unsigned long long)g[2],
                     (unsigned long long)g[3]);
            }
            // depthgaps_edges: 2^-128 and 2^-127 above 0 and below 2^-126
            for (int e2 : {-128, -127}) {
                Case c;
                c.what = 1u << O_FROMFP;
                c.v20 = mk(false, false, e2, 1);
                fact("depthgaps_edges denormal", c, lit(O_FROMFP, 1, 0), lit(O_FROMFP, -1, litKey(0x00800000u)));
            }
            // depthgaps_bigpos: from 1.07 2^128 to 13 2^127 above every probe, 0x7f7fffe0 included; bigord: ordered by
            // value
            {
                std::vector<int64_t> bk(5);
                const Fp bv[5] = {mk(false, false, 128 - 18, 0x447aeu), mk(false, false, 128 - 18, 0x60000u),
                                  mk(false, false, 129 - 18, 0x40000u), mk(false, false, 131 - 19, 0x68000u),
                                  mk(false, false, 132 - 18, 0x7ffffu)};
                for (int k = 0; k < 5; k++) {
                    Case c;
                    c.what = 1u << O_BIG;
                    c.v20 = bv[k];
                    c.sink = &bk[k];
                    c.sinkOut = O_BIG;
                    fact("depthgaps_bigpos", c, lit(O_BIG, 1, litKey(0x7f7fffe0u)), lit(O_BIG, 1, litKey(0x7f800000u)));
                }
                f.ok(bk[0] < bk[1] && bk[1] < bk[2] && bk[3] > bk[2] && bk[4] > bk[3],
                     "depthgaps_bigord: Big keys not ordered by value");
            }
            // zsign: 20 depths from -2^100 to 2^100 in the ISP's order: every negative one below zero, of two negative
            // ones the larger exponent the larger, within one exponent the float's order (-2 > -1 > -1.5 > -0.5 >
            // -0.75); -0 equal to +0. Listed ascending
            {
                const uint32_t ws[20] = {0xb5800000u, 0xbf400000u, 0xbf000000u, 0xbfc00000u, 0xbf800000u,
                                         0xc0000000u, 0xc2c80000u, 0xc9800000u, 0xf1800000u, 0x80000000u,
                                         0x00000000u, 0x35800000u, 0x3f000000u, 0x3f400000u, 0x3f800000u,
                                         0x3fc00000u, 0x40000000u, 0x42c80000u, 0x49800000u, 0x71800000u};
                std::vector<int64_t> zk(20);
                for (int k = 0; k < 20; k++) {
                    Case c;
                    c.what = (1u << O_BITS) | (1u << O_KEY32);
                    c.w = ws[k];
                    c.sink = &zk[k];
                    c.sinkOut = O_BITS;
                    push(c);
                }
                for (int k = 0; k + 1 < 20; k++) {
                    const bool zeros = k == 9;
                    f.ok(zeros ? zk[k] == zk[k + 1] : zk[k] < zk[k + 1], "zsign: depth %d (0x%08x) %s depth %d (0x%08x)",
                         k, ws[k], zeros ? "not equal to" : "not below", k + 1, ws[k + 1]);
                }
            }
            // saturated: both signs (bgbig, bgspec, zsign page 15: +-2^127)
            for (int s = 0; s < 2; s++) {
                Case c;
                c.what = 1u << O_SAT;
                c.sat = s;
                fact("saturated", c, lit(O_SAT, 0, litKey(s ? 0xff000000u : 0x7f000000u)));
            }
        }
        sectionDone("fp-zword", "directed", ls.cases() - n0);
    }

    // ---------------------------------------------------------------------------------------------------------
    if (a.want("words")) {
        f.set("words");
        const uint64_t n0 = ls.cases();
        if (a.full) {
            g_rtMask = 63;
            uint64_t lo, hi;
            a.range((uint64_t)1 << 32, &lo, &hi);
            for (uint64_t w = lo; w < hi; w++)
                onW((uint32_t)w);
            g_rtMask = 0;
        } else {
            uint64_t i = 0;
            for (uint32_t s = 0; s < 2; s++)
                for (uint32_t field = 0; field < 256; field++)
                    for (uint32_t k = 0; k < 64; k++, i++)
                        if (a.mine(i)) {
                            p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x77, i);
                            static const uint32_t fr[] = {0, 1, 0x1f, 0x20, 0x3ff, 0x400, 0x7fffe0, 0x7fffff,
                                                          0x400000, 0x3fffff, 0x7ffc00, 0x7ffbff};
                            const uint32_t frac = k < 12 ? fr[k] : (uint32_t)(r.u64() & 0x7fffff);
                            onW(s << 31 | field << 23 | frac);
                        }
            const uint64_t n = a.count(1u << 20);
            for (uint64_t j = 0; j < n; j++)
                if (a.mine(j)) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x7777, j);
                    onW(r.u32());
                }
        }
        sectionDone("fp-zword", "words", ls.cases() - n0);
    }

    if (a.want("between")) {
        f.set("between");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 4000000 : 400000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xbe7, i);
                Case c;
                c.w = r.u32();
                c.off = r.chance(100) ? (r.chance(500) ? 1u : 0xffffffffu) : 1 + (uint32_t)r.below(0xfffffffeu);
                c.what = 1u << O_BETWEEN;
                push(c);
            }
        sectionDone("fp-zword", "between", ls.cases() - n0);
    }

    if (a.want("fromfp")) {
        f.set("fromfp");
        const uint64_t n0 = ls.cases();
        if (a.full) {
            // every 19- and 20-bit mantissa (bit 18 or 19 set) at every exponent -175 .. 130, both signs
            g_rtMask = 15;
            const uint64_t mants = (uint64_t)1 << 20, nexp = 306;
            uint64_t lo, hi;
            a.range(mants * nexp, &lo, &hi);
            for (uint64_t i = lo; i < hi; i++) {
                const uint64_t m = i % mants;
                if (m < (1u << 18))
                    continue;
                const int ex = -175 + (int)(i / mants);
                onFromFp(mk(false, false, ex, m));
                onFromFp(mk(true, false, ex, m));
            }
            g_rtMask = 0;
        } else {
            uint64_t i = 0;
            for (int ex : {-170, -168, -167, -166, -165, -160, -150, -149, -148, -143, -142, -141, -126, -12, 111, 112})
                for (uint64_t m = 1; m < (1u << 17); m += 3, i++)
                    if (a.mine(i))
                        onFromFp(mk(i & 1, false, ex, m));
        }
        const uint64_t n = a.count(a.full ? 8000000 : 1000000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xf7, i);
                Gen g(r);
                Fp v = g.r.chance(20) ? mk(g.r.u64() & 1, true, 0, 0)
                       : g.r.chance(20) ? mk(g.r.u64() & 1, false, (int)g.r.range(-512, 511), 0)
                                        : randTop(g, (int)g.r.range(1, 20), -175, 135);
                onFromFp(v);
            }
        sectionDone("fp-zword", "fromfp", ls.cases() - n0);
    }

    if (a.want("big")) {
        f.set("big");
        const uint64_t n0 = ls.cases();
        if (a.full) {
            // every 19-bit mantissa (bit 18 set) at every exponent with top 129 .. 531
            g_rtMask = 15;
            const uint64_t mants = (uint64_t)1 << 18, ntop = 531 - 129 + 1;
            uint64_t lo, hi;
            a.range(mants * ntop, &lo, &hi);
            for (uint64_t i = lo; i < hi; i++) {
                const uint64_t m = (1u << 18) | (i % mants);
                const int tp = 129 + (int)(i / mants);
                onBig(mk(false, false, tp - 19, m));
            }
            g_rtMask = 0;
        }
        const uint64_t n = a.count(a.full ? 8000000 : 1000000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xb19, i);
                Gen g(r);
                const int bits = (int)g.r.range(1, 20);
                const uint64_t m = g.mant(bits);
                const int tp = g.r.chance(500) ? (int)g.r.range(129, 140) : (int)g.r.range(129, 511 + bl(m));
                onBig(mk(false, false, tp - bl(m), m));
            }
        sectionDone("fp-zword", "big", ls.cases() - n0);
    }

    if (a.want("neg")) {
        f.set("neg");
        const uint64_t n0 = ls.cases();
        if (a.full) {
            g_rtMask = 63;
            const uint64_t ms = (uint64_t)1 << 23, ne = 251;
            uint64_t lo, hi;
            a.range(ms * ne, &lo, &hi);
            for (uint64_t i = lo; i < hi; i++)
                onNeg(-122 + (int)(i / ms), -1 - (int64_t)(i % ms));
            g_rtMask = 0;
        } else {
            uint64_t i = 0;
            for (int e = -122; e <= 128; e++) {
                std::vector<int64_t> ms;
                for (int64_t c : {(int64_t)1 << 15, (int64_t)1 << 16, (int64_t)1 << 30})
                    for (int d = -3; d <= 3; d++)
                        ms.push_back(-(c + d));
                for (int k = 0; k <= 31; k++)
                    for (int d = -1; d <= 1; d++)
                        if (((int64_t)1 << k) + d > 0)
                            ms.push_back(-(((int64_t)1 << k) + d));
                ms.push_back(-((int64_t)1 << 40));
                ms.push_back(INT64_MIN / 2);
                for (int64_t m : ms)
                    if (a.mine(i++))
                        onNeg(e, m);
            }
        }
        const uint64_t n = a.count(a.full ? 8000000 : 1000000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x9e9, i);
                const int e = (int)r.range(-122, 128);
                const int64_t m = r.chance(100) ? -(int64_t)r.range(1, (int64_t)1 << 40) : -(int64_t)r.range(1, (int64_t)1 << 18);
                onNeg(e, m);
            }
        sectionDone("fp-zword", "neg", ls.cases() - n0);
    }

    if (a.want("flat")) {
        f.set("flat");
        const uint64_t n0 = ls.cases();
        // every 20-bit mantissa x 8 tops: both clamps of E (-122 from below, 128 from above), the edges around them
        static const int tops[8] = {-140, -123, -122, -121, 0, 128, 129, 150};
        const uint64_t step = a.full ? 1 : 13;
        uint64_t i = 0;
        for (uint64_t m = 1; m < (1u << 20); m += step)
            for (int k = 0; k < 8; k++)
                for (int s = 0; s < 2; s++, i++)
                    if (a.mine(i))
                        onFlat(mk(s, false, tops[k] - bl(m), m));
        const uint64_t n = a.count(a.full ? 8000000 : 1000000);
        for (uint64_t j = 0; j < n; j++)
            if (a.mine(j)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xf1a7, j);
                Gen g(r);
                Fp v = g.r.chance(20) ? mk(g.r.u64() & 1, true, 0, 0)
                       : g.r.chance(20) ? mk(g.r.u64() & 1, false, (int)g.r.range(-512, 511), 0)
                                        : randTop(g, 24, -200, 170);
                onFlat(v);
            }
        sectionDone("fp-zword", "flat", ls.cases() - n0);
    }

    if (a.want("sat")) {
        f.set("sat");
        const uint64_t n0 = ls.cases();
        if (a.mine(0))
            for (int s = 0; s < 2; s++) {
                Case c;
                c.sat = s;
                c.what = 1u << O_SAT;
                push(c);
            }
        sectionDone("fp-zword", "sat", ls.cases() - n0);
    }

    if (a.want("regdepth")) {
        f.set("regdepth");
        const uint64_t n0 = ls.cases();
        if (a.full) {
            g_rtMask = 63;
            uint64_t lo, hi;
            a.range((uint64_t)1 << 30, &lo, &hi);
            for (uint64_t i = lo; i < hi; i++) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x4e9, i);
                // the 30-bit register as a two's complement number, with random bits above the wrap
                const int64_t r30 = (int64_t)(i << 34) >> 34;
                onReg(r30 + (int64_t)((r.u64() & 3) << 30) - (r.chance(500) ? (int64_t)1 << 32 : 0));
            }
            g_rtMask = 0;
        } else {
            uint64_t i = 0;
            for (int64_t m = -40; m <= 40; m++)
                for (int64_t d : {-2, -1, 0, 1, 2, 1 << 8, -(1 << 8), (1 << 24) - 1, -(1 << 24) + 1})
                    if (a.mine(i++))
                        onReg(m * ((int64_t)1 << 25) + d);
            for (int k = 0; k < 30; k++)
                for (int d = -3; d <= 3; d++)
                    for (int s = 0; s < 2; s++)
                        if (a.mine(i++))
                            onReg((s ? -1 : 1) * (((int64_t)1 << k) + d));
            const uint64_t n = a.count(1u << 21);
            for (uint64_t j = 0; j < n; j++)
                if (a.mine(j)) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x4e6, j);
                    // refsw3's 64-bit register (the sum of r0, the steps and the slopes) or a 30-bit one
                    onReg(r.chance(300) ? (int64_t)r.u64() >> r.below(40) : (int64_t)(r.u64() << 34) >> 34);
                }
        }
        sectionDone("fp-zword", "regdepth", ls.cases() - n0);
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
                Case c;
                c.w = r.u32();
                c.off = 1 + (uint32_t)r.below(0xfffffffeu);
                c.v20 = randTop(g, (int)r.range(1, 20), -175, 135);
                c.v24 = randTop(g, 24, -200, 170);
                c.e = (int)r.range(-122, 128);
                c.m = -(int64_t)r.range(1, (int64_t)1 << 20);
                c.sat = r.u64() & 1;
                c.r = (int64_t)r.u64() >> 20;
                c.what = (1u << O_KEY32) | (1u << O_BITS) | (1u << O_BETWEEN) | (1u << O_BG) | (1u << O_FROMFP) |
                         (1u << O_NEG) | (1u << O_FLAT) | (1u << O_SAT) | (1u << O_REG);
                if (!c.v20.neg && c.v20.top() >= 129)
                    c.what |= 1u << O_BIG;
                push(c);
            }
        ls.gaps(0);
        sectionDone("fp-zword", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

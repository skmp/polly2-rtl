// fp_div_tb.cpp: make fp-div. H13, the TSP divider, against refcore pvr_tsp_plane.h at 708fb8cd (docs/spec/numerics.md
// H13, 7.3; docs/spec/tsp.md 6; PLAN M1c): the generated ROM p2_fp_recip_rom against RecipTable's t and n,
// p2_fp_recip_mant against RecipTable::Mantissa, p2_fp_den_seen against DenominatorSeen, and p2_fp_div (p2_fp_div_den +
// p2_fp_div_quot) against Divide. Every clock drives all four (p2_fp_div_tb_top); a section chooses the subject and the
// other three get vectors derived from the case number, which are checked too.
//
// Operands are plane values (p2_pval_t: neg, a mantissa of at most 17 bits, exp; never flagged: H12a never makes one,
// and Divide reads no flag): tops -142 .. 143 (num H12a: the -128 floor, -2^-143 for k = -1, "below about 2^142"), so
// every quotient's exponent fits the 10-bit field, which is asserted (G11) with the 18-bit port.
//
// Sections (--only):
//   directed  console facts as literals (dreamcast-tests README uvmeas items 2, 3, 7; tsp 6): r(32768) = 65535 (1 / 1.0
//             reads 65535 / 65536); over all 32768 D the RTL's r is floor(2^31 / D) for 28487, one less for 1110 and
//             one more for 3171 (recipscan); wneg: -1.25 reads as 1.75, -1.75 as 1.25, -2^k as 2^k; texfar_m1: -2^-143
//             reads as 0xFFFF 2^-143; texfar_m1q: -1 unit over -1 unit is -2^-16, a hair below 0; wzero2: a den of 0
//             is 2^-128 (1 / 0 = 0xFFFF 2^112); hugepos c: 0 / anything is +0; 1 / 1.0 = 0.FFFF; the floor toward
//             minus infinity: 0.75 / 1 arrives a whole unit of the 16th bit low, -0.75 / 1 half a unit high
//   recip     every ROM index (t, n against RecipTable) and every D in 32768 .. 65535 (recip_mant)
//   seen      every 17-bit mantissa x both signs x tops around -127 (-131 .. -120) and ordinary ones (--full; quick:
//             every 13th mantissa)
//   divide    all 2^16 + 1 numerator mantissas (0 .. 2^16) x 64 denominators, and all 32768 16-bit denominator
//             mantissas x 64 numerators, each x the four sign pairs (--full; quick: every 29th)
//   rand      random tuples of both operands: every class (normalized 16 bits, fewer, 2^16, -2^-143, zeros of both
//             signs, the den's tops around -127)
//   stream    random tuples with random gap clocks
#include <memory>

#include "Vp2_fp_div_tb_top.h"
#include "fp_tb.h"
#include "pvr_tsp_plane.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_div_tb_top Top;

namespace {

const pvrtsp::RecipTable& tab()
{
    static const pvrtsp::RecipTable t;
    return t;
}

constexpr int kMW = 17;            // the plane value's mantissa port (P2_PVAL_MANT_BITS)
constexpr int kQW = 18;            // the quotient's (P2_QUOT_MANT_BITS)
constexpr int kTopLo = -142, kTopHi = 143;

// the recipscan histogram of the RTL's r against floor(2^31 / D) (directed)
bool g_hist = false;
uint64_t g_eq = 0, g_lo = 0, g_hi = 0, g_other = 0;

void setPv(CData* neg, SData* exp, IData* mant, const Fp& v)
{
    *neg = v.neg;
    *exp = (SData)efield(v.exp);
    *mant = (IData)v.mant;
}
Fp getPv(uint64_t neg, uint64_t exp, uint64_t mant) { return fromPort(neg, 0, exp, mant); }

enum Lit { L_NONE, L_R, L_SEEN, L_QUOT };

struct Case {
    unsigned romI = 0;
    unsigned d = 32768;
    Fp ds, num, den;
    Lit lit = L_NONE;
    unsigned litR = 0;
    Fp litFp;
    const char* litWhat = "";

    void drive(Top* t) const
    {
        t->rom_i = romI;
        t->rm_d = d;
        setPv(&t->ds_neg, &t->ds_exp, &t->ds_mant, ds);
        setPv(&t->n_neg, &t->n_exp, &t->n_mant, num);
        setPv(&t->d_neg, &t->d_exp, &t->d_mant, den);
    }
    void check(Top* t, Fails& f) const
    {
        const pvrtsp::RecipTable& T = tab();
        // the ROM
        expect(f, t->rom_t == (uint32_t)(T.t[romI] - 65536) && t->rom_n == (uint32_t)T.n[romI], [&] {
            char b[160];
            snprintf(b, sizeof b, "recip_rom[%u]: got t %u n %u, want t %lld n %lld", romI, (unsigned)t->rom_t + 65536,
                     (unsigned)t->rom_n, (long long)T.t[romI], (long long)T.n[romI]);
            return std::string(b);
        });
        // recip_mant (its domain: a 16-bit mantissa with the leading bit set)
        expect(f, d >= 32768 && d <= 65535, [&] { return "recip_mant: D " + std::to_string(d) + " outside the domain"; });
        const int64_t r = T.Mantissa(d);
        expect(f, t->rm_r == (uint32_t)r, [&] {
            return "recip_mant(" + std::to_string(d) + "): got " + std::to_string(t->rm_r) + " want " + std::to_string(r);
        });
        if (g_hist) {
            const int64_t fl = (int64_t)((1ull << 31) / d), got = t->rm_r;
            (got == fl ? g_eq : got == fl - 1 ? g_lo : got == fl + 1 ? g_hi : g_other)++;
        }
        // denominator_seen
        const Fp sWant = pvrtsp::DenominatorSeen(ds);
        expectFp(f, "denominator_seen", sWant, FP_GET(t, s), kMW, [&] { return str(ds); });
        // divide
        auto inQ = [&] { return str(num) + " / " + str(den); };
        expect(f, fits(num, kMW) && fits(den, kMW) && !num.bad && !den.bad,
               [&] { return "divide: an operand outside the plane value's domain: " + inQ(); });
        const Fp qWant = pvrtsp::Divide(num, den);
        const Fp qGot = FP_GET(t, q);
        expectFp(f, "divide", qWant, qGot, kQW, inQ);
        // literals: the console's values
        if (lit == L_R)
            expect(f, t->rm_r == litR, [&] {
                return std::string("console: ") + litWhat + ": r(" + std::to_string(d) + ") got " +
                       std::to_string(t->rm_r) + " want " + std::to_string(litR);
            });
        else if (lit == L_SEEN)
            expectFp(f, (std::string("console: ") + litWhat).c_str(), litFp, FP_GET(t, s), kMW, [&] { return str(ds); });
        else if (lit == L_QUOT)
            expectFp(f, (std::string("console: ") + litWhat).c_str(), litFp, qGot, kQW, inQ);
    }
};

// a plane value (H12a's outputs) of a random class; top in [lo, hi]
Fp pval(Gen& g, int lo, int hi, bool neg)
{
    switch (g.r.below(16)) {
    case 0: return mk(neg, false, (int)g.r.range(-200, 200), 0);              // a zero (Divide: num +0 / den 2^-128)
    case 1: return mk(neg, false, -143, 1);                                   // k = -1: -2^-143 (or its positive twin)
    case 2: return Gen::at(1u << 16, g.top(lo, hi), neg);                     // 2^16 after the normalizer's carry
    case 3: case 4: return Gen::at(g.mantU(16), g.top(lo, hi), neg);          // fewer than 16 bits
    case 5: return Gen::at(g.mantN(17), g.top(lo, hi), neg);                  // 17 bits (beyond H12a; refsw3 defines it)
    default: return Gen::at(g.mant(16), g.top(lo, hi), neg);                  // 16 bits from the leading one
    }
}

// a value derived from the case number for the inputs that are not a section's subject (cheap)
Case base(uint64_t i)
{
    Case c;
    const uint64_t h = p2tb::Rng::Mix(i * 0x632BE59BD9B4E019ull);
    c.romI = (unsigned)(i & 511);
    c.d = 32768 + (unsigned)(h & 32767);
    const uint64_t m1 = (h >> 15) & 0x1FFFF, m2 = (h >> 32) & 0x1FFFF, m3 = (h >> 49) & 0x7FFF;
    c.ds = mk((h >> 7) & 1, false, (int)((h >> 20) % 280) - 140 - bl(m1), m1);
    c.num = mk((h >> 9) & 1, false, (int)((h >> 40) % 280) - 140 - bl(m2), m2);
    c.den = mk((h >> 11) & 1, false, (int)((h >> 3) % 280) - 140 - bl(m3 | 0x8000), m3 | 0x8000);
    return c;
}

// the 64 operands of the divide section's other side, from the seed
std::vector<Fp> sixtyFour(uint64_t seed, bool forDen)
{
    std::vector<Fp> v;
    p2tb::Rng r = p2tb::Rng::of(seed, forDen ? 0xDE7 : 0x7E3);
    Gen g(r);
    v.push_back(mk(false, false, 0, 0));                 // 0
    v.push_back(mk(false, false, -143, 1));              // the -1-unit value's size
    v.push_back(mk(false, false, 0, 1));                 // 1
    v.push_back(mk(false, false, -16, 0xFFFF));          // just under 1
    v.push_back(Gen::at(1u << 16, 1, false));            // 1 as 2^16 2^-16
    v.push_back(mk(false, false, -127 - 16, 0x8000));    // 2^-128 written out
    v.push_back(Gen::at(0xC000, -126, false));           // tops around -127
    v.push_back(Gen::at(0xFFFF, -127, false));
    while (v.size() < 64)
        v.push_back(pval(g, kTopLo, kTopHi, false));
    return v;
}

}   // namespace

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-div", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-div");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x646976);

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            auto litR = [&](unsigned d, unsigned r, const char* what) {
                Case c = base(d);
                c.d = d;
                c.lit = L_R;
                c.litR = r;
                c.litWhat = what;
                ls.push(c);
            };
            auto litS = [&](const Fp& den, const Fp& want, const char* what) {
                Case c = base(den.mant);
                c.ds = den;
                c.lit = L_SEEN;
                c.litFp = want;
                c.litWhat = what;
                ls.push(c);
            };
            auto litQ = [&](const Fp& num, const Fp& den, const Fp& want, const char* what) {
                Case c = base(num.mant ^ den.mant);
                c.num = num;
                c.den = den;
                c.lit = L_QUOT;
                c.litFp = want;
                c.litWhat = what;
                ls.push(c);
            };
            litR(32768, 65535, "uvmeas item 2, recipscan: 1 / 1.0 is 65535 / 65536");
            // the recipscan histogram over every D, the RTL's r
            g_hist = true;
            for (unsigned d = 32768; d <= 65535; d++) {
                Case c = base(d);
                c.d = d;
                ls.push(c);
            }
            g_hist = false;
            expect(f, g_eq == 28487 && g_lo == 1110 && g_hi == 3171 && g_other == 0, [&] {
                char b[200];
                snprintf(b, sizeof b, "console: recipscan: r = floor(2^31 / D) for %llu, one less %llu, one more %llu, "
                         "other %llu; want 28487, 1110, 3171, 0", (unsigned long long)g_eq, (unsigned long long)g_lo,
                         (unsigned long long)g_hi, (unsigned long long)g_other);
                return std::string(b);
            });
            // wneg: -v between two powers of two reads as 3 2^p - v; a power of two as itself
            litS(mk(true, false, -2, 5), mk(false, false, -15, 0xE000), "wneg: -1.25 reads as 1.75");
            litS(mk(true, false, -2, 7), mk(false, false, -15, 0xA000), "wneg: -1.75 reads as 1.25");
            litS(mk(true, false, 3, 1), mk(false, false, -12, 0x8000), "wneg: -8 reads as 8");
            litS(mk(true, false, -16, 0xFFFF), mk(false, false, -16, 0x8001), "wneg: -(1 - 2^-16) reads as 2^-16 + 1/2");
            litS(mk(false, false, -2, 5), mk(false, false, -2, 5), "a positive den is unchanged");
            // texfar_m1: the -1-unit value
            litS(mk(true, false, -143, 1), mk(false, false, -143, 0xFFFF), "texfar_m1: -2^-143 reads as 0xFFFF 2^-143");
            litQ(mk(true, false, -143, 1), mk(true, false, -143, 1), mk(true, false, -31, 0x8000),
                 "texfar_m1q: -1 unit over -1 unit is -2^-16, a hair below 0, not -1");
            // wzero2: a den of 0 is 2^-128
            litQ(mk(false, false, 0, 1), mk(false, false, 0, 0), mk(false, false, 112, 0xFFFF),
                 "wzero2: 1 / 0 = 1 / 2^-128 = 0xFFFF 2^112");
            litQ(mk(false, false, 0, 1), mk(true, false, 0, 0), mk(false, false, 112, 0xFFFF),
                 "wzero2: 1 / -0 likewise (the den's sign is dropped)");
            // hugepos c: a num of 0 is +0, whatever den is
            litQ(mk(true, false, 5, 0), mk(false, false, 0, 0), mk(false, false, 0, 0), "hugepos c: -0 / 0 is +0");
            litQ(mk(false, false, 5, 0), mk(true, false, -143, 1), mk(false, false, 0, 0), "hugepos c: 0 / -2^-143 is +0");
            // uvmeas item 2: 1 / 1.0 = 0.FFFF; item 3: the product floored toward minus infinity at 17 fraction bits
            litQ(mk(false, false, 0, 1), mk(false, false, 0, 1), mk(false, false, -16, 0xFFFF),
                 "uvmeas: 1 / 1.0 = 0xFFFF 2^-16");
            litQ(mk(false, false, -16, 0xC000), mk(false, false, 0, 1), mk(false, false, -17, 98302),
                 "uvmeas: 0.75 / 1 a whole unit of the 16th bit low");
            litQ(mk(true, false, -16, 0xC000), mk(false, false, 0, 1), mk(true, false, -17, 98303),
                 "uvmeas: -0.75 / 1 half a unit of the 16th bit high");
        }
        sectionDone("fp-div", "directed", ls.cases() - n0);
    }
    if (a.want("recip")) {
        f.set("recip");
        const uint64_t n0 = ls.cases();
        for (uint64_t k = 0; k < 32768; k++)
            if (a.mine(k)) {
                Case c = base(k * 7 + 1);
                c.romI = (unsigned)(k & 511);
                c.d = 32768 + (unsigned)k;
                ls.push(c);
            }
        sectionDone("fp-div", "recip", ls.cases() - n0);
    }
    if (a.want("seen")) {
        f.set("seen");
        const uint64_t n0 = ls.cases();
        static const int tops[] = {-131, -130, -129, -128, -127, -126, -125, -124, -120, 0, 143};
        const int nt = sizeof tops / sizeof tops[0];
        const uint64_t total = (uint64_t)((1u << 17) - 1) * 2 * nt;
        const uint64_t step = a.full ? 1 : 13;
        uint64_t lo = 0, hi = total;
        if (a.full)
            a.range(total, &lo, &hi);
        for (uint64_t k = lo; k < hi; k += step)
            if (a.full || a.mine(k / step)) {
                const uint64_t m = 1 + k / (2 * nt);
                const int tp = tops[k % nt];
                Case c = base(k);
                c.ds = Gen::at(m, tp, (k / nt) & 1);
                ls.push(c);
            }
        sectionDone("fp-div", "seen", ls.cases() - n0);
    }
    if (a.want("divide")) {
        f.set("divide");
        const uint64_t n0 = ls.cases();
        const std::vector<Fp> dens = sixtyFour(a.seed, true), nums = sixtyFour(a.seed, false);
        const uint64_t partA = 65537ull * 64 * 4, partB = 32768ull * 64 * 4, total = partA + partB;
        const uint64_t step = a.full ? 1 : 29;
        uint64_t lo = 0, hi = total;
        if (a.full)
            a.range(total, &lo, &hi);
        for (uint64_t k = lo; k < hi; k += step) {
            if (!a.full && !a.mine(k / step))
                continue;
            Case c = base(k);
            p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xD1D, k);
            const bool nneg = k & 1, dneg = (k >> 1) & 1;     // the four sign pairs
            if (k < partA) {
                // every numerator mantissa 0 .. 2^16 at a random top, over each of the 64 denominators
                const uint64_t m = (k >> 2) / 64;
                c.num = m ? Gen::at(m, (int)r.range(kTopLo, kTopHi), nneg) : mk(nneg, false, 0, 0);
                c.den = dens[(k >> 2) % 64];
                c.den.neg = dneg;
            } else {
                // every 16-bit denominator mantissa at a random top, under each of the 64 numerators
                const uint64_t j = k - partA;
                c.den = Gen::at(32768 + (j >> 2) / 64, (int)r.range(kTopLo, kTopHi), dneg);
                c.num = nums[(j >> 2) % 64];
                c.num.neg = nneg;
            }
            ls.push(c);
        }
        sectionDone("fp-div", "divide", ls.cases() - n0);
    }
    auto randCase = [&](uint64_t salt, uint64_t i) {
        p2tb::Rng r = p2tb::Rng::of(a.seed ^ salt, i);
        Gen g(r);
        Case c = base(i ^ salt);
        c.num = pval(g, kTopLo, kTopHi, g.r.u64() & 1);
        c.den = g.r.chance(100) ? Gen::at(g.mant(16), (int)g.r.range(-130, -124), g.r.u64() & 1)
                                : pval(g, kTopLo, kTopHi, g.r.u64() & 1);
        c.ds = pval(g, -132, kTopHi, g.r.u64() & 1);
        c.d = 32768 + (unsigned)g.r.below(32768);
        c.romI = (unsigned)g.r.below(512);
        return c;
    };
    if (a.want("rand")) {
        f.set("rand");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 20000000 : 500000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i))
                ls.push(randCase(0x52A4D, i));
        sectionDone("fp-div", "rand", ls.cases() - n0);
    }
    if (a.want("stream")) {
        f.set("stream");
        const uint64_t n0 = ls.cases();
        ls.gaps(300);
        const uint64_t n = a.full ? 2000000 : 200000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i))
                ls.push(randCase(0x5157, i));
        ls.gaps(0);
        sectionDone("fp-div", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

// fp_zblock_tb.cpp: make fp-zblock. H12b p2_fp_depth_block against refcore pvr_isp_depth.h DepthTileT::At at 708fb8cd
// (docs/spec/numerics.md H12b, H14 e, 8 A2, A5; ARCHITECTURE 2.4 BLOCK; PLAN M1b). The testbench sets a DepthTile's
// block form directly (valid, block, d0, dx, dy, unit, E; Setup would reset them) from the G form the RTL takes:
// d0 = S 2^(gexp - unit), dx = DX 2^(gexp - unit), dy likewise; the RTL lane gets t = S + (2i + h) DX + (2j + h) DY
// (the raster's accumulation, M3's), gexp, E, nsh = E - 15 - gexp and fbk (refsw3 NegWord's sh = E - 15 - unit outside
// 0 .. 120). Asserted on every pixel: |t| < 2^29 (isp 9.4a), and A2: refsw3's t (unit grid) below 2^64 when >= 0.
//
// Sections (--only):
//   directed  depthgaps_negladder / depthgaps_search (a ramp of E 5 from a start of exactly 0, A = -0.71, B = -0.05 a
//             pixel: the pixels in [-32, -16) in the window, i.e. float words; those above -16 above every word of
//             field 131 and below field 132's last), depthgaps_bigpos (a start of -2^127 stepping up past 2^128: above
//             0x7f7fffe0), the fallback word (A5)
//   rand      random S (|S| < 2^27), DX, DY (< 2^21), gexp - unit 0 .. 25, every i, j, both h, E across -122 .. 128
//             with both clamps, nsh -40 .. 30 (the fallback and the left shift), the denormal and 2^128 ends of gexp
//   stream    random pixels with random gap clocks
#include <memory>

#include "Vp2_fp_zblock_tb_top.h"
#include "fp_tb.h"
#include "vecgen.h"
#include "zkey.h"

using namespace fptb;
typedef Vp2_fp_zblock_tb_top Top;

namespace {

uint64_t g_neg = 0, g_fbk = 0, g_big = 0, g_lshift = 0, g_denorm = 0, g_domain = 0;

int64_t litKey(uint32_t w)
{
    const int32_t k = w == 0x80000000u ? 0 : (int32_t)(w ^ ((w >> 31) ? 0x007fffffu : 0));
    return (int64_t)k * ((int64_t)1 << 32);
}

struct Case {
    int64_t S = 0, DX = 0, DY = 0;
    int gexp = 0, unit = 0, E = 0, i = 0, j = 0, h = 0;
    int8_t rel = 2;          // a console fact: 0 ==, 1 >, -1 <, 3 strictly between lo and hi; 2 none
    int64_t lo = 0, hi = 0;
    const char* fact = nullptr;

    int64_t t() const { return S + (2 * i + h) * DX + (2 * j + h) * DY; }
    int nsh() const { return E - 15 - gexp; }
    bool fbk() const
    {
        const int sh = E - 15 - unit;     // refsw3 NegWord: E - 16 - unit + 1
        return sh < 0 || sh > 120;
    }
    void drive(Top* tp) const
    {
        tp->t = (uint32_t)t() & 0x3fffffffu;
        tp->gexp = efield(gexp);
        tp->e = (uint16_t)E & 0x3ff;
        tp->nsh = (uint8_t)nsh();
        tp->fbk = fbk();
    }
    std::string in() const
    {
        char b[256];
        snprintf(b, sizeof b, "S %lld DX %lld DY %lld gexp %d unit %d E %d i %d j %d h %d (t %lld nsh %d fbk %d)",
                 (long long)S, (long long)DX, (long long)DY, gexp, unit, E, i, j, h, (long long)t(), nsh(), (int)fbk());
        return b;
    }
    void check(Top* tp, Fails& f) const
    {
        const int64_t tt = t();
        if (tt >= ((int64_t)1 << 29) || tt < -((int64_t)1 << 29) || nsh() < -128 || nsh() > 127)
            g_domain++;
        pvrisp::DepthTile d;
        d.valid = true;
        d.block = true;
        d.ovf = 0;
        const int g = gexp - unit;
        d.d0 = (pvrfp::i128)S << g;
        d.dx = (pvrfp::i128)DX << g;
        d.dy = (pvrfp::i128)DY << g;
        d.unit = unit;
        d.E = E;
        const pvrisp::StoredDepth want = d.At(i, j, h == 0);
        // A2: refsw3's own t (on its grid 2^(unit - 1)) is below 2^64 when it is not negative
        const pvrfp::i128 tref = d.d0 + (2 * i + h) * d.dx + (2 * j + h) * d.dy;
        if (!(tref < 0)) {
            const pvrfp::u128 m = (pvrfp::u128)tref;
            f.ok((uint64_t)(m >> 64) == 0, "A2: refsw3's t has more than 64 bits: %s", in().c_str());
        }
        if (tt < 0) {
            g_neg++;
            if (fbk())
                g_fbk++;
            else if (nsh() < 0)
                g_lshift++;
        } else if (tt > 0 && gexp - 1 + pvrfp::BitLength((uint64_t)tt) - 1 >= 128) {
            g_big++;
        } else if (tt > 0 && gexp - 1 + pvrfp::BitLength((uint64_t)tt) <= -125) {
            g_denorm++;
        }
        const int64_t got = (int64_t)tp->key;
        expect(f, got == want.k, [&] {
            char s[160];
            snprintf(s, sizeof s, "key: got 0x%016llx want 0x%016llx (refsw3 bits 0x%08x); ", (unsigned long long)got,
                     (unsigned long long)want.k, want.bits);
            return std::string(s) + in();
        });
        if (rel != 2) {
            const bool ok = rel == 0 ? got == lo : rel == 1 ? got > lo : rel == -1 ? got < lo : (got > lo && got < hi);
            expect(f, ok, [&] {
                char s[200];
                snprintf(s, sizeof s, "%s: key 0x%016llx against 0x%016llx .. 0x%016llx; ", fact, (unsigned long long)got,
                         (unsigned long long)lo, (unsigned long long)hi);
                return std::string(s) + in();
            });
        }
    }
};

}   // namespace

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-zblock", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-zblock");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x2b1);

    // a tile from the G form: gexp, E (clamped as Setup does), unit = gexp - g
    auto random = [&](p2tb::Rng& r) {
        Case c;
        const int g = r.chance(300) ? 0 : (int)r.range(0, 25);
        switch (r.below(6)) {
        case 0: c.E = -122; break;
        case 1: c.E = 128; break;
        default: c.E = (int)r.range(-122, 128); break;
        }
        // nsh: 11 (E unclamped), 11 .. 14 (E clamped up at -122), below 11 down to -40 (E clamped at 128, the fallback
        // or the left shift), up to 30
        int nsh = 11;
        switch (r.below(5)) {
        case 0: nsh = (int)r.range(11, 14); break;
        case 1: nsh = (int)r.range(-40, 10); break;
        case 2: nsh = (int)r.range(-15, 30); break;
        default: break;
        }
        c.gexp = c.E - 15 - nsh;
        c.unit = c.gexp - g;
        if (c.unit < -400 || c.gexp > 400) {
            c.gexp = c.E - 26;
            c.unit = c.gexp;
        }
        const int sb = (int)r.range(0, 27), db = (int)r.range(0, 21);
        auto val = [&](int bits) {
            const int64_t m = bits ? (int64_t)(r.u64() & (((uint64_t)1 << bits) - 1)) : 0;
            return r.u64() & 1 ? -m : m;
        };
        c.S = r.chance(100) ? 0 : val(sb);
        c.DX = r.chance(100) ? 0 : val(db);
        c.DY = r.chance(100) ? 0 : val(r.chance(500) ? db : (int)r.range(0, 21));
        c.i = (int)r.below(32);
        c.j = (int)r.below(32);
        c.h = r.chance(500) ? -1 : 0;
        return c;
    };

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            // depthgaps_negladder / search: a ramp from a start of exactly 0 (unit = gexp = pair - 21 = -21: A -0.71,
            // B -0.05 a pixel), E 5: values in [-32, -16) are float words of the window; values above -16 lie above
            // every word of field 131 (0xc1800000 has the largest key there) and below field 132's last (0xc27fffff)
            for (int j = 0; j < 32; j++)
                for (int i = 0; i < 32; i++) {
                    Case c;
                    c.E = 5;
                    c.gexp = -21;
                    c.unit = -21;
                    c.S = 0;
                    c.DX = -1488978;      // -0.71 2^21
                    c.DY = -104858;       // -0.05 2^21
                    c.i = i;
                    c.j = j;
                    const int64_t M = c.t() >> 11;
                    if (c.t() >= 0)
                        continue;
                    c.fact = "depthgaps_negladder";
                    if (M >= -65536) {
                        if (M <= -32768) {
                            c.rel = 3;        // a window word: field 131's words
                            c.lo = litKey(0xc1ffffffu) - 1;
                            c.hi = litKey(0xc1800000u) + 1;
                        } else {
                            c.rel = 3;
                            c.lo = litKey(0xc1800000u);
                            c.hi = litKey(0xc27fffffu);
                        }
                    }
                    ls.push(c);
                }
            // depthgaps_bigpos: a start of -2^127 (the forced start) stepping up by 2^126 a pixel: from 2^128 above
            // every float word, 0x7f7fffe0 included (gexp 127: G = 2^127, t in half units of G)
            for (int i = 0; i < 10; i++) {
                Case c;
                c.E = 128;
                c.gexp = 101;            // G = 2^101: -2^127 is -2^27 half units, 2^126 a pixel is 2^25 units
                c.unit = 101;
                c.S = -((int64_t)1 << 27);
                c.DX = (int64_t)1 << 25;
                c.i = i;
                c.h = 0;
                const int64_t v = c.t();   // value v 2^100
                if (v >= ((int64_t)1 << 28)) {
                    c.fact = "depthgaps_bigpos";
                    c.rel = 1;
                    c.lo = litKey(0x7f7fffe0u);
                }
                ls.push(c);
            }
            // A5: a start cut to zero with slopes past 2^134: nsh < 0 with gexp == unit, NegWord's fallback word
            for (int E : {128, 100}) {
                Case c;
                c.E = E;
                c.gexp = E - 15 + 3;     // nsh = -3
                c.unit = c.gexp;
                c.S = 0;
                c.DX = -5;
                c.i = 3;
                c.fact = "A5 fallback";
                c.rel = 0;
                c.lo = litKey(0x80000000u | (uint32_t)(E + 126) << 23);
                ls.push(c);
            }
        }
        sectionDone("fp-zblock", "directed", ls.cases() - n0);
    }
    if (a.want("rand")) {
        f.set("rand");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 50000000 : 1500000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x6b, i);
                ls.push(random(r));
            }
        sectionDone("fp-zblock", "rand", ls.cases() - n0);
    }
    if (a.want("stream")) {
        f.set("stream");
        const uint64_t n0 = ls.cases();
        ls.gaps(300);
        const uint64_t n = a.full ? 2000000 : 200000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x5e, i);
                ls.push(random(r));
            }
        ls.gaps(0);
        sectionDone("fp-zblock", "stream", ls.cases() - n0);
    }
    printf("fp-zblock: classes: %llu below zero (%llu fallback, %llu left shift), %llu Big, %llu denormal\n",
           (unsigned long long)g_neg, (unsigned long long)g_fbk, (unsigned long long)g_lshift, (unsigned long long)g_big,
           (unsigned long long)g_denorm);
    f.ok(g_domain == 0, "%llu pixels outside |t| < 2^29 or nsh outside 8 bits (a generator bug)",
         (unsigned long long)g_domain);
    top->final();
    return f.finish();
}

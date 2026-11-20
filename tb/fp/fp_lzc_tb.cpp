// fp_lzc_tb.cpp: make fp-lzc. H1 p2_fp_lzc against refcore pvr_bits.h BitLength (docs/spec/numerics.md H1, 7.3), at
// every instance width of p2_fp_lzc_tb_top. Above 64 bits the reference is BitLength of the high word plus 64, as
// pvr_softfp.h Add takes the bit length of its 128-bit sums.
//
// Sections (--only):
//   directed  0, 1, every single bit, every all-ones prefix, at every width
//   exh24     every 24-bit value (--full); quick: every 17-bit value and 1M random 24-bit values
//   wide      every leading position 0 .. 127 with random tails below it (4096 a position --full, 64 quick)
//   stream    random values of every width class with random gap clocks
#include <memory>

#include "Vp2_fp_lzc_tb_top.h"
#include "fp_tb.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_lzc_tb_top Top;

static const int kWidths[] = {16, 17, 24, 25, 34, 49, 50, 64, 77, 108, 128};

static int ref(uint64_t lo, uint64_t hi, int w)
{
    if (w <= 64)
        return pvrfp::BitLength(lo & Gen::mask(w));
    const uint64_t h = hi & Gen::mask(w - 64);
    return h ? 64 + pvrfp::BitLength(h) : pvrfp::BitLength(lo);
}

struct Case {
    uint64_t lo = 0, hi = 0;
    void drive(Top* t) const
    {
        t->v[0] = (uint32_t)lo;
        t->v[1] = (uint32_t)(lo >> 32);
        t->v[2] = (uint32_t)hi;
        t->v[3] = (uint32_t)(hi >> 32);
    }
    void check(Top* t, Fails& f) const
    {
        const int got[] = {t->n16, t->n17, t->n24, t->n25, t->n34, t->n49, t->n50, t->n64, t->n77, t->n108, t->n128};
        for (size_t i = 0; i < sizeof kWidths / sizeof kWidths[0]; i++) {
            const int want = ref(lo, hi, kWidths[i]);
            expect(f, got[i] == want, [&] {
                char b[160];
                snprintf(b, sizeof b, "BL%d(0x%016llx%016llx) = %d, want %d", kWidths[i], (unsigned long long)hi,
                         (unsigned long long)lo, got[i], want);
                return std::string(b);
            });
        }
    }
};

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-lzc", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-lzc");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x6c7a63);
    auto push = [&](uint64_t lo, uint64_t hi) {
        Case c;
        c.lo = lo;
        c.hi = hi;
        ls.push(c);
    };

    if (a.want("directed")) {
        f.set("directed");
        uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            push(0, 0);
            for (int b = 0; b < 128; b++) {
                push(b < 64 ? 1ull << b : 0, b < 64 ? 0 : 1ull << (b - 64));
                push(b < 64 ? Gen::mask(b + 1) : ~0ull, b < 64 ? 0 : Gen::mask(b - 63));
            }
        }
        sectionDone("fp-lzc", "directed", ls.cases() - n0);
    }
    if (a.want("exh24")) {
        f.set("exh24");
        uint64_t n0 = ls.cases();
        if (a.full) {
            uint64_t lo, hi;
            a.range(1ull << 24, &lo, &hi);
            for (uint64_t v = lo; v < hi; v++)
                push(v, 0);
        } else {
            uint64_t lo, hi;
            a.range(1ull << 17, &lo, &hi);
            for (uint64_t v = lo; v < hi; v++)
                push(v, 0);
            const uint64_t n = a.count(1000000);
            for (uint64_t i = 0; i < n; i++)
                if (a.mine(i)) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed, i);
                    push(r.u64() & Gen::mask(24), 0);
                }
        }
        sectionDone("fp-lzc", "exh24", ls.cases() - n0);
    }
    if (a.want("wide")) {
        f.set("wide");
        uint64_t n0 = ls.cases();
        const int tails = a.full ? 4096 : 64;
        for (int b = 0; b < 128; b++)
            if (a.mine((uint64_t)b)) {
                for (int k = 0; k < tails; k++) {
                    p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x77, (uint64_t)b * 4096 + k);
                    uint64_t lo = r.u64(), hi = r.u64();
                    if (b < 64) {
                        hi = 0;
                        lo = (lo & Gen::mask(b)) | (1ull << b);
                    } else {
                        hi = (hi & Gen::mask(b - 64)) | (1ull << (b - 64));
                    }
                    push(lo, hi);
                }
            }
        sectionDone("fp-lzc", "wide", ls.cases() - n0);
    }
    if (a.want("stream")) {
        f.set("stream");
        uint64_t n0 = ls.cases();
        ls.gaps(300);
        const uint64_t n = a.full ? 2000000 : 200000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x5157, i);
                const int w = kWidths[r.below(sizeof kWidths / sizeof kWidths[0])];
                const int b = (int)r.below((uint64_t)w + 1);   // BL b, 0 .. w
                uint64_t lo = r.u64(), hi = r.u64();
                if (b == 0) {
                    lo = hi = 0;
                } else if (b <= 64) {
                    hi = 0;
                    lo = (lo & Gen::mask(b - 1)) | (1ull << (b - 1));
                } else {
                    hi = (hi & Gen::mask(b - 65)) | (1ull << (b - 65));
                }
                push(lo, hi);
            }
        ls.gaps(0);
        sectionDone("fp-lzc", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

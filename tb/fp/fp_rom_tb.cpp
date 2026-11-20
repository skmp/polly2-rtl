// fp_rom_tb.cpp: make fp-rom. The measured-table ROMs of PLAN M1c (docs/spec/tsp.md 12, 17.3, 20 and appendix B):
// p2_rom_bm_sin, p2_rom_bm_cos (two ports, as p2_pp_shade reads COS[S] and COS[4 x]) and p2_rom_dither, generated from
// refsw3's text (tools/gen/gen_table_roms.cpp), against verbatim copies of the same lines (tb/fp/ref_copies.h
// p2fpref::tables: refsw_tile.cpp BM_HW_SIN / BM_HW_COS, refsw_lists.cpp ditherAdd at 708fb8cd; drift-checked by
// every gate).
//
// Sections (--only):
//   directed  console facts: fbpack's dither table as tsp 17.3 prints it (every entry pinned, lower bound = upper bound;
//             rows are y); bumpfn: K3 = 255 at S = 0 and R = Q gives t3 = ((255 COS[0] >> 8) COS[0]) >> 8 = 253 from
//             the ROM's words; SIN[0] is 0 or 1 and COS[255] 0, 1 or 2 (the only freedom bumpfn leaves)
//   every     every index of SIN, of both COS ports and of the dither ROM against the copies
//   stream    random indices with random gap clocks
#include <memory>

#include "Vp2_fp_rom_tb_top.h"
#include "fp_tb.h"
#include "ref_copies.h"

using namespace fptb;
typedef Vp2_fp_rom_tb_top Top;

namespace {

using p2fpref::tables::BM_HW_COS;
using p2fpref::tables::BM_HW_SIN;
using p2fpref::tables::ditherAdd;

enum Lit { L_NONE, L_DITHER, L_T3, L_SIN0, L_COS255 };

struct Case {
    unsigned s = 0, c = 0, c2 = 0, y = 0, x = 0;
    Lit lit = L_NONE;
    int litV = 0;

    void drive(Top* t) const
    {
        t->sin_i = s;
        t->cos_i = c;
        t->cos2_i = c2;
        t->dy = y;
        t->dx = x;
    }
    void check(Top* t, Fails& f) const
    {
        expect(f, t->sin_v == BM_HW_SIN[s],
               [&] { return "SIN[" + std::to_string(s) + "]: got " + std::to_string(t->sin_v) + " want " + std::to_string(BM_HW_SIN[s]); });
        expect(f, t->cos_v == BM_HW_COS[c],
               [&] { return "COS[" + std::to_string(c) + "]: got " + std::to_string(t->cos_v) + " want " + std::to_string(BM_HW_COS[c]); });
        expect(f, t->cos2_v == BM_HW_COS[c2], [&] {
            return "COS[" + std::to_string(c2) + "] (second port): got " + std::to_string(t->cos2_v) + " want " +
                   std::to_string(BM_HW_COS[c2]);
        });
        expect(f, (int)t->dith_v == ditherAdd[y][x], [&] {
            return "ditherAdd[" + std::to_string(y) + "][" + std::to_string(x) + "]: got " + std::to_string(t->dith_v) +
                   " want " + std::to_string(ditherAdd[y][x]);
        });
        switch (lit) {
        case L_DITHER:
            expect(f, (int)t->dith_v == litV, [&] {
                return "console: fbpack: DITHER[" + std::to_string(y) + "][" + std::to_string(x) + "] got " +
                       std::to_string(t->dith_v) + " want " + std::to_string(litV);
            });
            break;
        case L_T3: {
            // BumpMapper's last term with K3 = 255, S = 0, x = 0 (R = Q): ((K3 COS[S]) >> 8) COS[4 x] >> 8
            const int t3 = (((255 * (int)t->cos_v) >> 8) * (int)t->cos2_v) >> 8;
            expect(f, t3 == litV, [&] {
                return "console: bumpfn: K3 255 at S = 0, R = Q: t3 " + std::to_string(t3) + " want " + std::to_string(litV);
            });
            break;
        }
        case L_SIN0:
            expect(f, t->sin_v <= 1, [&] { return "console: bumpfn: SIN[0] is 0 or 1, got " + std::to_string(t->sin_v); });
            break;
        case L_COS255:
            expect(f, t->cos_v <= 2, [&] { return "console: bumpfn: COS[255] is 0, 1 or 2, got " + std::to_string(t->cos_v); });
            break;
        default:
            break;
        }
    }
};

}   // namespace

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-rom", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-rom");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x726f6d);

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            // docs/spec/tsp.md 17.3, as printed there (rows are y)
            static const int kDither[4][4] = {{5, 13, 7, 15}, {9, 1, 11, 3}, {6, 14, 4, 12}, {10, 2, 8, 0}};
            for (unsigned y = 0; y < 4; y++)
                for (unsigned x = 0; x < 4; x++) {
                    Case c;
                    c.y = y;
                    c.x = x;
                    c.lit = L_DITHER;
                    c.litV = kDither[y][x];
                    ls.push(c);
                }
            Case c;
            c.c = 0;
            c.c2 = 0;
            c.lit = L_T3;
            c.litV = 253;
            ls.push(c);
            c = Case();
            c.s = 0;
            c.lit = L_SIN0;
            ls.push(c);
            c = Case();
            c.c = 255;
            c.lit = L_COS255;
            ls.push(c);
        }
        sectionDone("fp-rom", "directed", ls.cases() - n0);
    }
    if (a.want("every")) {
        f.set("every");
        const uint64_t n0 = ls.cases();
        for (unsigned i = 0; i < 256; i++)
            if (a.mine(i)) {
                Case c;
                c.s = i;
                c.c = i;
                c.c2 = 255 - i;
                c.y = (i >> 2) & 3;
                c.x = i & 3;
                ls.push(c);
            }
        sectionDone("fp-rom", "every", ls.cases() - n0);
    }
    if (a.want("stream")) {
        f.set("stream");
        const uint64_t n0 = ls.cases();
        ls.gaps(300);
        const uint64_t n = a.full ? 200000 : 20000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x5157, i);
                const uint64_t h = r.u64();
                Case c;
                c.s = h & 255;
                c.c = (h >> 8) & 255;
                c.c2 = (h >> 16) & 255;
                c.y = (h >> 24) & 3;
                c.x = (h >> 26) & 3;
                ls.push(c);
            }
        ls.gaps(0);
        sectionDone("fp-rom", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

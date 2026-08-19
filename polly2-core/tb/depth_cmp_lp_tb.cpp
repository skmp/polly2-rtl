// depth_cmp_lp_tb - ordered depth/tag compare (isp_depth_cmp_lp) regression, both
// directions.
//
// The DUT decides, per fragment, whether it becomes this pass's staged candidate. This
// TB runs the whole resolve loop around it exactly as peel_tile_buffer does:
//
//   TR (pt=0), far -> near          PT (pt=1), near -> far
//     ref  = {opaque depth, 0}        boundary = {FLT_MAX, 0xFFFFFF}
//     repeat:                         repeat:
//       zb = FLT_MAX, valid = 0         zb = 0, valid = 0
//       sweep fragments, apply pass     sweep fragments, apply pass
//       emit the staged one             emit the staged one
//       ref <- staged key               boundary <- staged key (iff staged)
//     until nothing asserted `more`   until nothing asserted `more`
//
// and checks the emitted sequence against an INDEPENDENT sort on
//
//     key = { depth[30:0], tag[23:0] }
//
// ASCENDING for TR - farthest first, and at equal depth in submission order (earliest
// tag behind), which is the blend order translucent needs. refsw2's rule peeled a
// coplanar stack in DECREASING tag order (reverse submission), which is what the
// composite key replaced.
//
// DESCENDING for PT - nearest first, latest tag first. The PT sweep here never resolves
// a lane, i.e. every alpha test fails, which is precisely the case a depth-only boundary
// got wrong: it skipped a whole coplanar plane after the first fragment of it failed, so
// the hole punched through everything behind. The enumeration must visit every coplanar
// fragment one pass at a time.
//
#include <verilated.h>
#include "Vdepth_cmp_lp_tb_top.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <algorithm>
#include <random>

static const uint32_t TAG_INVALID_SENTINEL = 0x80000000u;
static const uint32_t FLT_MAX_BITS         = 0x7F7FFFFFu;   // sign-stripped FLT_MAX
static const uint32_t REFSORT_MAX          = 0x00FFFFFFu;

struct Frag { uint32_t z; uint32_t tag; };

// the key the RTL builds: {depth[30:0], tag[23:0]} - 55 bits
static uint64_t key_of(uint32_t z, uint32_t tag) {
    return ((uint64_t)(z & 0x7FFFFFFFu) << 24) | (tag & 0x00FFFFFFu);
}

static int g_fail = 0;
static void fail(const char* what) { printf("  FAIL: %s\n", what); g_fail++; }

// one full resolve of `frags`; returns the emitted candidates in order.
// TR runs the TWO-LAYER loop exactly as peel_tile_buffer does: slot A (farthest
// owed) + slot B (next), an A-accept SLIDES old A into B, the pass emits A then
// B (still back-to-front), and the reference advances to the NEAREST staged
// (B if it staged, else A) with B's tag left resting in the PW_TAG companion.
// PT is the unchanged single-slot walk (slot B tied off).
static std::vector<Frag> resolve(Vdepth_cmp_lp_tb_top* dut, bool pt,
                                 const std::vector<Frag>& frags,
                                 uint32_t ref_z, uint32_t ref_sort, int* passes_out) {
    std::vector<Frag> emitted;
    uint32_t zb2 = ref_z, pb2 = ref_sort;
    uint32_t pbA = TAG_INVALID_SENTINEL;      // resting tag across passes (PW_TAG)
    const uint32_t seed_z = pt ? 0u : FLT_MAX_BITS;
    int passes = 0;
    const int PASS_LIMIT = (int)frags.size() + 8;

    for (;;) {
        uint32_t zbA = seed_z;
        uint32_t zbB = 0, tagB = 0;
        int vA = 0, vB = 0, more_acc = 0;
        passes++;

        for (const Frag& f : frags) {
            dut->pt = pt;
            dut->nw = f.z;  dut->tag = f.tag;
            dut->zb = zbA;  dut->pb  = pbA;
            dut->zb2 = zb2; dut->pb2_sort = pb2;
            dut->valid  = vA;
            dut->zbB    = zbB;
            dut->pbB_sort = tagB & 0x00FFFFFFu;
            dut->validB = vB;
            dut->eval();
            if (dut->more) more_acc = 1;
            if (pt) {
                if (dut->pass) { zbA = f.z; pbA = f.tag; vA = 1; }
            } else {
                if (dut->pass) {            // A-accept: old A slides into B
                    zbB = zbA; tagB = pbA; vB = vA;
                    zbA = f.z; pbA = f.tag; vA = 1;
                } else if (dut->pass_b) {   // lands between A and B
                    zbB = f.z; tagB = f.tag; vB = 1;
                }
            }
        }

        if (vA)        emitted.push_back({zbA, pbA});
        if (!pt && vB) emitted.push_back({zbB, tagB});
        // boundary/reference advances to the NEAREST staged this pass
        if (!pt && vB)          { zb2 = zbB; pb2 = tagB & 0x00FFFFFFu; pbA = tagB; }
        else if (zbA != seed_z) { zb2 = zbA; pb2 = pbA & 0x00FFFFFFu; }

        if (!more_acc) break;
        if (passes > PASS_LIMIT) { fail("resolve did not converge (pass limit)"); break; }
    }
    if (passes_out) *passes_out = passes;
    return emitted;
}

// expected: every fragment strictly past the reference key, ordered by direction
static std::vector<Frag> expected_order(bool pt, const std::vector<Frag>& frags,
                                        uint32_t ref_z, uint32_t ref_sort) {
    std::vector<Frag> v;
    uint64_t kr = key_of(ref_z, ref_sort);
    for (const Frag& f : frags) {
        uint64_t k = key_of(f.z, f.tag);
        if (pt ? (k < kr) : (k > kr)) v.push_back(f);
    }
    std::sort(v.begin(), v.end(), [&](const Frag& a, const Frag& b) {
        uint64_t ka = key_of(a.z, a.tag), kb = key_of(b.z, b.tag);
        return pt ? (ka > kb) : (ka < kb);
    });
    return v;
}

static void check(const char* name, const std::vector<Frag>& got,
                  const std::vector<Frag>& want) {
    if (got.size() != want.size()) {
        printf("  FAIL %s: emitted %zu, expected %zu\n", name, got.size(), want.size());
        g_fail++;
        return;
    }
    for (size_t i = 0; i < got.size(); i++) {
        if (got[i].z != want[i].z || got[i].tag != want[i].tag) {
            printf("  FAIL %s: [%zu] = {z=%08x tag=%08x}, expected {z=%08x tag=%08x}\n",
                   name, i, got[i].z, got[i].tag, want[i].z, want[i].tag);
            g_fail++;
            return;
        }
    }
    printf("  ok   %s (%zu)\n", name, got.size());
}

static uint32_t zbits(float f) { uint32_t u; memcpy(&u, &f, 4); return u & 0x7FFFFFFFu; }
static uint32_t mktag(uint32_t sort24) { return sort24 & 0x00FFFFFFu; }   // valid tag, bit31=0

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vdepth_cmp_lp_tb_top* dut = new Vdepth_cmp_lp_tb_top;
    int seed = 1, scenes = 200;
    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "+seed=",   6)) seed   = atoi(argv[i] + 6);
        if (!strncmp(argv[i], "+scenes=", 8)) scenes = atoi(argv[i] + 8);
    }

    printf("== TR (pt=0), directed ==\n");

    // a coplanar stack: three translucent polys at the SAME depth, submitted T1<T2<T3.
    // Correct blend order is back-to-front = submission order. The old rule gave T3,T2,T1.
    {
        uint32_t z = zbits(0.5f);
        std::vector<Frag> f = {{z, mktag(0x100)}, {z, mktag(0x200)}, {z, mktag(0x300)}};
        auto got = resolve(dut, false, f, zbits(0.1f), 0, nullptr);
        check("coplanar stack of 3 (submission order)", got,
              expected_order(false, f, zbits(0.1f), 0));
        if (got.size() == 3 && got[0].tag != mktag(0x100))
            fail("coplanar stack did not start at the EARLIEST tag");
    }
    // shuffled arrival: order must come from the tag, not from arrival
    {
        uint32_t z = zbits(0.25f);
        std::vector<Frag> f = {{z, mktag(0x300)}, {z, mktag(0x100)}, {z, mktag(0x200)}};
        auto got = resolve(dut, false, f, zbits(0.1f), 0, nullptr);
        check("coplanar stack, shuffled arrival", got,
              expected_order(false, f, zbits(0.1f), 0));
    }
    // KNOWN HOLE, pinned deliberately: a REAL fragment with tag[23:0]==0 sitting exactly
    // ON the pass-1 reference ties with the sentinel (whose sort field is also 0) and is
    // rejected. Does not occur in any golden scene; see the module header.
    {
        uint32_t zref = zbits(0.375f);
        std::vector<Frag> f = {{zref, mktag(0)}, {zbits(0.5f), mktag(0x10)}};
        auto got = resolve(dut, false, f, zref, 0, nullptr);
        check("tag[23:0]==0 on the reference is dropped (known hole)", got,
              expected_order(false, f, zref, 0));
        for (const Frag& g : got)
            if (g.tag == mktag(0)) fail("tag==0 emitted - the key gained a tie-break?");
        if (got.size() != 1 || got[0].tag != mktag(0x10))
            fail("the non-tying fragment must still be emitted");
    }
    // mixed depths + coplanar groups
    {
        std::vector<Frag> f;
        for (int d = 0; d < 4; d++)
            for (int t = 0; t < 3; t++)
                f.push_back({zbits(0.2f + 0.1f * d), mktag(0x1000 * (d + 1) + 0x10 * t)});
        auto got = resolve(dut, false, f, zbits(0.05f), 0, nullptr);
        check("4 depths x 3 coplanar", got, expected_order(false, f, zbits(0.05f), 0));
    }
    // everything at or behind the reference -> nothing peels, loop terminates
    {
        std::vector<Frag> f = {{zbits(0.1f), mktag(0x10)}, {zbits(0.05f), mktag(0x20)}};
        int p = 0;
        auto got = resolve(dut, false, f, zbits(0.2f), mktag(0x5), &p);
        check("all behind the reference", got, expected_order(false, f, zbits(0.2f), mktag(0x5)));
        if (p > 2) fail("empty peel took more than one pass");
    }

    printf("== PT (pt=1), directed ==\n");

    // THE REGRESSION: a coplanar PT group, every alpha test failing. A depth-only
    // boundary visited the first of them and then skipped the rest of the plane, so a
    // failed alpha test punched a hole through everything behind. All three must be
    // visited, nearest-plane-first, latest tag first within the plane.
    {
        uint32_t z = zbits(0.5f);
        std::vector<Frag> f = {{z, mktag(0x100)}, {z, mktag(0x200)}, {z, mktag(0x300)}};
        int p = 0;
        auto got = resolve(dut, true, f, FLT_MAX_BITS, REFSORT_MAX, &p);
        check("coplanar PT group is stepped through, not skipped", got,
              expected_order(true, f, FLT_MAX_BITS, REFSORT_MAX));
        if (got.size() != 3) fail("a coplanar PT fragment was skipped (the hole bug)");
        if (got.size() == 3 && got[0].tag != mktag(0x300))
            fail("PT must start at the LATEST tag in the nearest plane");
    }
    // near/far planes, two coplanar in each: strict near-to-far, latest tag first
    {
        std::vector<Frag> f = {{zbits(0.9f), mktag(0x10)}, {zbits(0.9f), mktag(0x20)},
                               {zbits(0.2f), mktag(0x30)}, {zbits(0.2f), mktag(0x40)}};
        auto got = resolve(dut, true, f, FLT_MAX_BITS, REFSORT_MAX, nullptr);
        check("two PT planes x 2 coplanar, near first", got,
              expected_order(true, f, FLT_MAX_BITS, REFSORT_MAX));
        if (got.size() == 4 && !(got[0].z == zbits(0.9f) && got[3].z == zbits(0.2f)))
            fail("PT did not walk near -> far");
    }
    // single fragment: one pass, no spurious MoreToDraw
    {
        std::vector<Frag> f = {{zbits(0.5f), mktag(0x77)}};
        int p = 0;
        auto got = resolve(dut, true, f, FLT_MAX_BITS, REFSORT_MAX, &p);
        check("single PT fragment", got, expected_order(true, f, FLT_MAX_BITS, REFSORT_MAX));
        if (p != 2) printf("  note: single-fragment PT took %d passes (1 draw + 1 drain)\n", p);
    }

    printf("== randomized (%d scenes/direction, seed %d) ==\n", scenes, seed);
    std::mt19937 rng(seed);
    for (int dir = 0; dir < 2; dir++) {
        bool pt = (dir == 1);
        int bad = 0;
        for (int s = 0; s < scenes; s++) {
            int n = 1 + (int)(rng() % 12);
            int ndepth = 1 + (int)(rng() % 4);   // few depths -> heavy coincidence
            std::vector<uint32_t> depths;
            for (int i = 0; i < ndepth; i++)
                depths.push_back(zbits(0.05f + 0.9f * (float)(rng() % 1000) / 1000.0f));
            std::vector<Frag> f;
            for (int i = 0; i < n; i++)
                f.push_back({depths[rng() % ndepth], mktag(rng() & 0x00FFFFFFu)});
            // tags are unique (they are addresses in the param buffer)
            std::sort(f.begin(), f.end(), [](const Frag& a, const Frag& b) { return a.tag < b.tag; });
            f.erase(std::unique(f.begin(), f.end(),
                                [](const Frag& a, const Frag& b) { return a.tag == b.tag; }), f.end());
            std::shuffle(f.begin(), f.end(), rng);

            uint32_t refz   = pt ? FLT_MAX_BITS : zbits(0.01f);
            uint32_t refsrt = pt ? REFSORT_MAX  : 0;
            int p = 0;
            auto got  = resolve(dut, pt, f, refz, refsrt, &p);
            auto want = expected_order(pt, f, refz, refsrt);
            bool ok = got.size() == want.size();
            for (size_t i = 0; ok && i < got.size(); i++)
                ok = got[i].z == want[i].z && got[i].tag == want[i].tag;
            if (!ok) {
                if (bad < 5) {
                    printf("  FAIL %s scene %d (%zu frags): got", pt ? "PT" : "TR", s, f.size());
                    for (auto& g : got) printf(" %06x", g.tag & 0xFFFFFF);
                    printf("  want");
                    for (auto& w : want) printf(" %06x", w.tag & 0xFFFFFF);
                    printf("\n");
                }
                bad++; g_fail++;
            }
            if (p > (int)f.size() + 1) {
                printf("  FAIL %s scene %d: %d passes for %zu candidates\n",
                       pt ? "PT" : "TR", s, p, want.size());
                g_fail++;
            }
        }
        if (!bad) printf("  ok   all %d randomized %s scenes resolve in exact key order\n",
                         scenes, pt ? "PT" : "TR");
    }

    delete dut;
    printf(g_fail ? "\n=== depth_cmp_lp: %d FAILURES ===\n" : "\n=== depth_cmp_lp: PASS ===\n", g_fail);
    return g_fail ? 1 : 0;
}

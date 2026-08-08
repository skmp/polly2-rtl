// depth_cmp_lp_tb - layer-peel depth/tag compare (isp_depth_cmp_lp) regression.
//
// The DUT decides, per fragment, whether it becomes this pass's staged layer. This
// TB runs the whole peel loop around it exactly as peel_core does:
//
//   pb2 = TAG_INVALID_SENTINEL, zb2 = reference (opaque) depth
//   repeat:
//     zb = FLT_MAX, valid = 0            (PeelBuffers seeds the pass)
//     for each fragment in SUBMISSION order: drive the DUT, apply pass/more
//     if valid: this pass emits (pb, zb)
//     zb2 <- zb, pb2 <- pb               (PeelBuffers swap)
//   until no fragment asserted `more`
//
// and checks the emitted layer sequence against an INDEPENDENT sort. The property
// under test is the whole point of the composite key: layers come out ordered by
//
//     { depth[30:0], tag[23:0], ~tag[31] }   ascending
//
// i.e. farthest first, and for COINCIDENT depths in increasing tag order, which is
// submission order (earliest submitted is behind). The old refsw2 rule
// (`invW == zb2 && tag >= tagRendered -> reject`) peeled coincident fragments in
// DECREASING tag order - reverse submission - which is what this test pins down.
//
// Cases: directed coplanar stacks, the tag[23:0]==0 fragment sitting exactly on the
// pass-1 reference (the sentinel tie the key's LSB exists to break), and randomized
// scenes with heavy depth collisions.
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

struct Frag { uint32_t z; uint32_t tag; };

// the key the RTL builds: {depth[30:0], tag[23:0]} - 55 bits
static unsigned __int128 key_of(uint32_t z, uint32_t tag) {
    unsigned __int128 k = (unsigned __int128)(z & 0x7FFFFFFFu);
    k = (k << 24) | (tag & 0x00FFFFFFu);
    return k;
}

static int g_fail = 0;
static void fail(const char* what) { printf("  FAIL: %s\n", what); g_fail++; }

// one full peel of `frags` starting from (ref_z, ref_tag); returns the emitted layers
static std::vector<Frag> peel(Vdepth_cmp_lp_tb_top* dut, const std::vector<Frag>& frags,
                              uint32_t ref_z, uint32_t ref_tag, int* passes_out) {
    std::vector<Frag> emitted;
    uint32_t zb2 = ref_z, pb2 = ref_tag;
    uint32_t pb  = TAG_INVALID_SENTINEL;      // stale across passes, like dt_tag
    int passes = 0;
    const int PASS_LIMIT = (int)frags.size() + 8;

    for (;;) {
        uint32_t zb = FLT_MAX_BITS;           // PeelBuffers: depth <- FLT_MAX, valid <- 0
        int valid = 0, more_acc = 0;
        passes++;

        for (const Frag& f : frags) {
            dut->nw = f.z; dut->tag = f.tag;
            dut->zb = zb;  dut->zb2 = zb2;
            dut->pb = pb;  dut->pb2 = pb2;
            dut->valid = valid;
            dut->eval();
            if (dut->more) more_acc = 1;
            if (dut->pass) { zb = f.z; pb = f.tag; valid = 1; }
        }

        if (valid) emitted.push_back({zb, pb});
        zb2 = zb; pb2 = pb;                   // PeelBuffers swap

        if (!more_acc) break;
        if (passes > PASS_LIMIT) { fail("peel did not converge (pass limit)"); break; }
    }
    if (passes_out) *passes_out = passes;
    return emitted;
}

// expected: every fragment strictly after the reference key, in ascending key order
static std::vector<Frag> expected_order(const std::vector<Frag>& frags,
                                        uint32_t ref_z, uint32_t ref_tag) {
    std::vector<Frag> v;
    unsigned __int128 kr = key_of(ref_z, ref_tag);
    for (const Frag& f : frags) if (key_of(f.z, f.tag) > kr) v.push_back(f);
    std::sort(v.begin(), v.end(), [](const Frag& a, const Frag& b) {
        return key_of(a.z, a.tag) < key_of(b.z, b.tag);
    });
    return v;
}

static void check(const char* name, const std::vector<Frag>& got,
                  const std::vector<Frag>& want) {
    if (got.size() != want.size()) {
        printf("  FAIL %s: emitted %zu layers, expected %zu\n", name, got.size(), want.size());
        g_fail++;
        return;
    }
    for (size_t i = 0; i < got.size(); i++) {
        if (got[i].z != want[i].z || got[i].tag != want[i].tag) {
            printf("  FAIL %s: layer %zu = {z=%08x tag=%08x}, expected {z=%08x tag=%08x}\n",
                   name, i, got[i].z, got[i].tag, want[i].z, want[i].tag);
            g_fail++;
            return;
        }
    }
    printf("  ok   %s (%zu layers)\n", name, got.size());
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

    printf("== directed ==\n");

    // 1. a coplanar stack: three translucent polys at the SAME depth, submitted
    //    T1 < T2 < T3. Correct blend order is back-to-front = submission order.
    //    The old rule peeled T3, T2, T1.
    {
        uint32_t z = zbits(0.5f);
        std::vector<Frag> f = {{z, mktag(0x100)}, {z, mktag(0x200)}, {z, mktag(0x300)}};
        int p = 0;
        auto got = peel(dut, f, zbits(0.1f), TAG_INVALID_SENTINEL, &p);
        check("coplanar stack of 3 (submission order)", got,
              expected_order(f, zbits(0.1f), TAG_INVALID_SENTINEL));
        if (got.size() == 3 && got[0].tag != mktag(0x100))
            fail("coplanar stack did not start at the EARLIEST tag");
    }

    // 2. submission order shuffled: the peel must still emit by tag, not by arrival
    {
        uint32_t z = zbits(0.25f);
        std::vector<Frag> f = {{z, mktag(0x300)}, {z, mktag(0x100)}, {z, mktag(0x200)}};
        auto got = peel(dut, f, zbits(0.1f), TAG_INVALID_SENTINEL, nullptr);
        check("coplanar stack, shuffled arrival", got,
              expected_order(f, zbits(0.1f), TAG_INVALID_SENTINEL));
    }

    // 3. KNOWN HOLE, pinned deliberately: a REAL fragment with tag[23:0]==0 (the record
    //    at param offset 0, first triangle) sitting exactly ON the pass-1 reference
    //    depth ties with the sentinel, which also has tag[23:0]==0, so it is REJECTED
    //    and never drawn. The key carries no bit that separates them. This does not
    //    occur in any of the 42 golden scenes; appending ~tag[31] as the key LSB closes
    //    it if a scene ever needs it (see the module header). Fragments at other depths
    //    are unaffected - only the exact tie is lost.
    {
        uint32_t zref = zbits(0.375f);
        std::vector<Frag> f = {{zref, mktag(0)}, {zbits(0.5f), mktag(0x10)}};
        auto got = peel(dut, f, zref, TAG_INVALID_SENTINEL, nullptr);
        check("tag[23:0]==0 on the reference is dropped (known hole)", got,
              expected_order(f, zref, TAG_INVALID_SENTINEL));
        for (const Frag& g : got)
            if (g.tag == mktag(0)) fail("tag==0 fragment emitted - the key gained a tie-break?");
        if (got.size() != 1 || got[0].tag != mktag(0x10))
            fail("the non-tying fragment must still be emitted");
    }

    // 4. mixed depths + coplanar groups
    {
        std::vector<Frag> f;
        for (int d = 0; d < 4; d++)
            for (int t = 0; t < 3; t++)
                f.push_back({zbits(0.2f + 0.1f * d), mktag(0x1000 * (d + 1) + 0x10 * t)});
        auto got = peel(dut, f, zbits(0.05f), TAG_INVALID_SENTINEL, nullptr);
        check("4 depths x 3 coplanar", got,
              expected_order(f, zbits(0.05f), TAG_INVALID_SENTINEL));
    }

    // 5. everything at or behind the reference -> nothing peels, loop terminates
    {
        std::vector<Frag> f = {{zbits(0.1f), mktag(0x10)}, {zbits(0.05f), mktag(0x20)}};
        int p = 0;
        auto got = peel(dut, f, zbits(0.2f), mktag(0x5), &p);
        check("all behind the reference", got, expected_order(f, zbits(0.2f), mktag(0x5)));
        if (p > 2) fail("empty peel took more than one pass");
    }

    printf("== randomized (%d scenes, seed %d) ==\n", scenes, seed);
    std::mt19937 rng(seed);
    int bad = 0;
    for (int s = 0; s < scenes; s++) {
        int n = 1 + (int)(rng() % 12);
        // few distinct depths -> heavy coincidence, which is the interesting case
        int ndepth = 1 + (int)(rng() % 4);
        std::vector<uint32_t> depths;
        for (int i = 0; i < ndepth; i++)
            depths.push_back(zbits(0.05f + 0.9f * (float)(rng() % 1000) / 1000.0f));
        std::vector<Frag> f;
        for (int i = 0; i < n; i++)
            f.push_back({depths[rng() % ndepth], mktag(rng() & 0x00FFFFFFu)});
        // tags must be unique (they are addresses in the param buffer)
        std::sort(f.begin(), f.end(), [](const Frag& a, const Frag& b) { return a.tag < b.tag; });
        f.erase(std::unique(f.begin(), f.end(),
                            [](const Frag& a, const Frag& b) { return a.tag == b.tag; }), f.end());
        std::shuffle(f.begin(), f.end(), rng);

        uint32_t refz = zbits(0.01f);
        int p = 0;
        auto got  = peel(dut, f, refz, TAG_INVALID_SENTINEL, &p);
        auto want = expected_order(f, refz, TAG_INVALID_SENTINEL);
        bool ok = got.size() == want.size();
        for (size_t i = 0; ok && i < got.size(); i++)
            ok = got[i].z == want[i].z && got[i].tag == want[i].tag;
        if (!ok) {
            if (bad < 5) {
                printf("  FAIL scene %d (%zu frags): got", s, f.size());
                for (auto& g : got) printf(" %06x", g.tag & 0xFFFFFF);
                printf("  want");
                for (auto& w : want) printf(" %06x", w.tag & 0xFFFFFF);
                printf("\n");
            }
            bad++; g_fail++;
        }
        if (p > (int)f.size() + 1) { printf("  FAIL scene %d: %d passes for %zu layers\n",
                                            s, p, want.size()); g_fail++; }
    }
    if (!bad) printf("  ok   all %d randomized scenes peel in exact key order\n", scenes);

    delete dut;
    printf(g_fail ? "\n=== depth_cmp_lp: %d FAILURES ===\n" : "\n=== depth_cmp_lp: PASS ===\n", g_fail);
    return g_fail ? 1 : 0;
}

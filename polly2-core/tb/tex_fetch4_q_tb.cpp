// Self-checking TB: tex_fetch4_q (queued/coalescing fetch) vs tex_fetch4_ob (golden).
//
// Drives the SAME pixel sequence into both units (independent handshakes + random
// input gaps), collects both output streams, and compares them IN ORDER:
//   * out_pl must match the issue order exactly (the payload contract),
//   * textured pixels' 4 corner words must be identical,
//   * both are ALSO checked against a software model computed from vram[].
// Phases: locality walks (dedup/packing), pure random, direct-mapped ALIAS stress
// (same index / different tag inside one group), VQ-heavy, untextured mix, and a
// mid-run FLUSH (drain -> flush -> continue).
#include "Vtex_fetch4_q_tb_top.h"
#include "Vtex_fetch4_q_tb_top___024root.h"
#include "verilated.h"
#define VRAM dut->rootp->tex_fetch4_q_tb_top__DOT__vram
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <vector>

static Vtex_fetch4_q_tb_top* dut;
static vluint64_t tck = 0;
static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    tck++;
}

static inline uint64_t vword(uint32_t w) {
    return (uint64_t)0xC0FFEE0000000000ULL | ((uint64_t)(w & 0xFFFFF) << 16) | (w * 2654435761u & 0xFFFF);
}

struct Pix {
    uint8_t  tex, vq;
    uint32_t texaddr, vqaddr;   // word bases
    uint32_t off[4];            // byte offsets (22b)
    uint16_t id;
};
static std::vector<Pix> seq;

// software model: expected corner words
static void expect_words(const Pix& p, uint64_t w[4]) {
    for (int i = 0; i < 4; i++) {
        uint32_t wa  = (p.texaddr + (p.off[i] >> 3)) & 0xFFFFF;
        uint64_t mem = vword(wa);
        if (p.vq) {
            uint32_t lane = p.off[i] & 7;
            uint32_t idx  = (uint32_t)((mem >> (8 * lane)) & 0xFF);
            w[i] = vword((p.vqaddr + idx) & 0xFFFFF);
        } else w[i] = mem;
    }
}

struct Out { uint16_t pl; uint64_t t[4]; };
static std::deque<Out> qout, gout;
static uint32_t q_in = 0, g_in = 0;      // next seq index to present per unit
static uint32_t checked = 0, errors = 0;

// per-unit input driver state (present-and-hold across !ready)
struct Drv {
    bool     presenting = false;
    int      gap = 0;
};
static Drv qd, gd;

static void set_inputs_q(bool valid, const Pix* p) {
    dut->q_valid = valid;
    if (!p) return;
    dut->q_tex = p->tex; dut->q_vq = p->vq;
    dut->q_texaddr = p->texaddr; dut->q_vqaddr = p->vqaddr;
    dut->q_off0 = p->off[0]; dut->q_off1 = p->off[1];
    dut->q_off2 = p->off[2]; dut->q_off3 = p->off[3];
    dut->q_pl = p->id;
}
static void set_inputs_g(bool valid, const Pix* p) {
    dut->g_valid = valid;
    if (!p) return;
    dut->g_tex = p->tex; dut->g_vq = p->vq;
    dut->g_texaddr = p->texaddr; dut->g_vqaddr = p->vqaddr;
    dut->g_off0 = p->off[0]; dut->g_off1 = p->off[1];
    dut->g_off2 = p->off[2]; dut->g_off3 = p->off[3];
    dut->g_pl = p->id;
}

static void compare_streams() {
    while (!qout.empty() && !gout.empty()) {
        Out a = qout.front(); qout.pop_front();
        Out b = gout.front(); gout.pop_front();
        const Pix& p = seq[checked];
        uint16_t want_pl = p.id;
        if (a.pl != want_pl || b.pl != want_pl) {
            if (errors++ < 10)
                printf("[%llu] ORDER/PL mismatch at out #%u: dut=%04x gold=%04x want=%04x\n",
                       (unsigned long long)tck, checked, a.pl, b.pl, want_pl);
        } else if (p.tex) {
            uint64_t w[4]; expect_words(p, w);
            for (int i = 0; i < 4; i++) {
                if (a.t[i] != b.t[i]) {
                    if (errors++ < 10)
                        printf("[%llu] TEXEL mismatch out #%u (id %04x) corner %d: dut=%016llx gold=%016llx\n",
                               (unsigned long long)tck, checked, p.id, i,
                               (unsigned long long)a.t[i], (unsigned long long)b.t[i]);
                }
                if (a.t[i] != w[i]) {
                    if (errors++ < 10)
                        printf("[%llu] MODEL mismatch out #%u (id %04x) corner %d: dut=%016llx model=%016llx (off=%06x)\n",
                               (unsigned long long)tck, checked, p.id, i,
                               (unsigned long long)a.t[i], (unsigned long long)w[i], p.off[i]);
                }
            }
        }
        checked++;
    }
}

// one simulation step: drive both units, sample, tick, harvest outputs
static void step() {
    // ---- DUT drive ----
    if (!qd.presenting && q_in < seq.size()) {
        if (qd.gap > 0) qd.gap--;
        else qd.presenting = true;
    }
    set_inputs_q(qd.presenting, q_in < seq.size() ? &seq[q_in] : nullptr);
    // ---- GOLDEN drive ----
    if (!gd.presenting && g_in < seq.size()) {
        if (gd.gap > 0) gd.gap--;
        else gd.presenting = true;
    }
    set_inputs_g(gd.presenting, g_in < seq.size() ? &seq[g_in] : nullptr);

    dut->eval();
    bool q_acc = qd.presenting && dut->q_ready;
    bool g_acc = gd.presenting && dut->g_ready;
    bool q_o = dut->q_ov, g_o = dut->g_ov;
    Out qo, go;
    if (q_o) { qo.pl = dut->q_opl; qo.t[0]=dut->q_t0; qo.t[1]=dut->q_t1; qo.t[2]=dut->q_t2; qo.t[3]=dut->q_t3; }
    if (g_o) { go.pl = dut->g_opl; go.t[0]=dut->g_t0; go.t[1]=dut->g_t1; go.t[2]=dut->g_t2; go.t[3]=dut->g_t3; }

    tick();

    if (q_acc) { q_in++; qd.presenting = false; if ((rand() % 8) == 0) qd.gap = rand() % 4; }
    if (g_acc) { g_in++; gd.presenting = false; if ((rand() % 8) == 0) gd.gap = rand() % 4; }
    if (q_o) qout.push_back(qo);
    if (g_o) gout.push_back(go);
    compare_streams();
}

static void drain(const char* what) {
    uint64_t t0 = tck;
    while ((checked < seq.size()) && tck - t0 < 8000000) step();
    if (checked != seq.size()) {
        printf("FAIL: %s drain timeout: checked %u / %zu (dutq=%zu goldq=%zu q_in=%u g_in=%u)\n",
               what, checked, seq.size(), qout.size(), gout.size(), q_in, g_in);
        errors++;
    }
}

// ---- stimulus generation ----
static uint16_t next_id = 0;
static void px(uint8_t tex, uint8_t vq, uint32_t ta, uint32_t va,
               uint32_t o0, uint32_t o1, uint32_t o2, uint32_t o3) {
    Pix p; p.tex = tex; p.vq = vq; p.texaddr = ta & 0xFFFFF; p.vqaddr = va & 0xFFFFF;
    p.off[0] = o0 & 0x3FFFFF; p.off[1] = o1 & 0x3FFFFF;
    p.off[2] = o2 & 0x3FFFFF; p.off[3] = o3 & 0x3FFFFF;
    p.id = next_id++;
    seq.push_back(p);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtex_fetch4_q_tb_top;
    srand(12345);

    for (uint32_t w = 0; w < (1u << 20); w++) VRAM[w] = vword(w);

    dut->reset = 1; dut->flush = 0;
    set_inputs_q(false, nullptr); set_inputs_g(false, nullptr);
    for (int i = 0; i < 1100; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 4; i++) tick();

    const uint32_t TEXBASE = 0x10000;    // word base of the test texture region
    const uint32_t VQBASE  = 0x80000;    // word base of the codebook region

    // ---- phase 1: LOCALITY WALK (bilinear-quad-like, exercises dedup/packing) ----
    {
        uint32_t b = 0x4000;             // byte cursor
        for (int n = 0; n < 20000; n++) {
            if ((rand() % 50) == 0) b = (rand() % 0x100000) & ~1u;   // texture jump
            else b += (rand() % 3) * 2;                              // span walk
            uint32_t s = 64 << (rand() % 3);                         // "stride"
            if ((rand() % 12) == 0) px(0, 0, TEXBASE, VQBASE, 0, 0, 0, 0); // untex
            else px(1, 0, TEXBASE, VQBASE, b, b + 2, b + s, b + s + 2);
        }
        drain("locality");
    }

    // ---- phase 2: PURE RANDOM (4 unique words per pixel, heavy misses) ----
    for (int n = 0; n < 15000; n++)
        px(1, 0, TEXBASE, VQBASE,
           rand() & 0x3FFFFE, rand() & 0x3FFFFE, rand() & 0x3FFFFE, rand() & 0x3FFFFE);
    drain("random");

    // ---- FLUSH: drain done above; pulse flush, wait out the 1024-line sweep ----
    dut->flush = 1; tick(); dut->flush = 0;
    for (int i = 0; i < 1100; i++) tick();

    // ---- phase 3: ALIAS stress (same index, different tag, inside one group) ----
    // line index = word[11:2] mod 1024 -> +4096 words = +32768 bytes aliases.
    for (int n = 0; n < 4000; n++) {
        uint32_t b = (rand() % 0x8000) & ~1u;
        px(1, 0, TEXBASE, VQBASE, b, b + 32768, b + 65536, b + 98304);
    }
    drain("alias");

    // ---- phase 4: VQ-heavy (codebook second trip; index depends on data) ----
    {
        uint32_t b = 0x2000;
        for (int n = 0; n < 10000; n++) {
            b += (rand() % 3) * 1;
            uint8_t v = (rand() % 4) != 0;          // 75% VQ
            px(1, v, TEXBASE, VQBASE, b, b + 1, b + 8, b + 9);
        }
        drain("vq");
    }

    // ---- phase 5: chaos mix (everything at once) ----
    for (int n = 0; n < 15000; n++) {
        int k = rand() % 10;
        uint32_t b = rand() & 0x3FFFFE;
        if (k == 0)      px(0, 0, TEXBASE, VQBASE, 0, 0, 0, 0);
        else if (k < 4)  px(1, 1, TEXBASE + (rand() % 4) * 0x8000, VQBASE + (rand() % 2) * 0x100,
                            b, b + 2, b + 64, b + 66);
        else if (k < 7)  px(1, 0, TEXBASE, VQBASE, b, b + 2, b + 32768, b + 32770);
        else             px(1, 0, TEXBASE, VQBASE,
                            rand() & 0x3FFFFE, rand() & 0x3FFFFE, rand() & 0x3FFFFE, rand() & 0x3FFFFE);
    }
    drain("chaos");

    printf("=== tex_fetch4_q_tb: %u pixels checked, %u errors, %llu cycles ===\n",
           checked, errors, (unsigned long long)tck);
    if (errors || checked != seq.size()) { printf("FAIL\n"); dut->final(); return 1; }
    printf("PASS\n");
    dut->final();
    return 0;
}

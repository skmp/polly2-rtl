// Self-checking TB for tex_fetch4_ob over the PIPELINED tex_cache_4p_1c (2-cycle
// lookup, b-group replay, streaming prefetch walker).
//
// Drives pixel sequences (present-and-hold + random input gaps), collects the output
// stream and checks it IN ORDER against a software model computed from the same
// address->word formula the DDR channels serve:
//   * out_pl must match the issue order exactly (the payload contract),
//   * textured pixels' 4 corner words must be identical to the model,
//   * a warmed back-to-back phase must sustain ~1 pixel/cycle (the pipelining's point),
//   * the locality-walk phase must issue REAL prefetch bursts (pf_issues delta),
//   * a mid-run FLUSH (drain -> flush -> continue) must not corrupt anything.
// Phases: throughput, locality walk (prefetch material), pure random, direct-mapped
// ALIAS stress (same index / different tag inside one group), VQ-heavy, untextured
// mix, flush + rerun.
#include "Vtex_fetch4_pl_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

static Vtex_fetch4_pl_tb_top* dut;
static vluint64_t tck = 0;

static inline uint64_t vword(uint32_t w) {
    w &= 0xFFFFF;
    return 0xC0FFEE0000000000ULL | ((uint64_t)w << 16)
         | (uint64_t)(uint16_t)(w * 2654435761u);
}

struct Pix {
    uint8_t  tex, vq;
    uint32_t texaddr, vqaddr;   // word bases (21b)
    uint32_t off[4];            // byte offsets (22b)
    uint16_t id;
    uint8_t  phase;
};
static std::vector<Pix> seq;

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

static uint32_t rng_s = 0x12345678;
static uint32_t rnd() { rng_s ^= rng_s << 13; rng_s ^= rng_s >> 17; rng_s ^= rng_s << 5; return rng_s; }

static uint32_t checked = 0, errors = 0;
static std::vector<vluint64_t> out_tick;

static void check_out(uint16_t pl, const uint64_t t[4]) {
    if (checked >= seq.size()) {
        if (errors++ < 10) printf("[%llu] EXTRA output (pl=%04x)\n", (unsigned long long)tck, pl);
        return;
    }
    const Pix& p = seq[checked];
    if (pl != p.id) {
        if (errors++ < 10)
            printf("[%llu] ORDER/PL mismatch at out #%u: got=%04x want=%04x\n",
                   (unsigned long long)tck, checked, pl, p.id);
    } else if (p.tex) {
        uint64_t w[4]; expect_words(p, w);
        for (int i = 0; i < 4; i++)
            if (t[i] != w[i]) {
                if (errors++ < 10)
                    printf("[%llu] TEXEL mismatch out #%u (id %04x, ph %d) corner %d: got=%016llx want=%016llx\n",
                           (unsigned long long)tck, checked, p.id, p.phase, i,
                           (unsigned long long)t[i], (unsigned long long)w[i]);
            }
    }
    out_tick.push_back(tck);
    checked++;
}

// one clock: inputs must already be set; samples in_ready/out_valid mid-cycle
static bool cyc_ready;
static void cycle() {
    dut->clk = 0; dut->eval();
    cyc_ready = dut->in_ready;
    if (dut->out_valid) {
        uint64_t t[4] = { dut->t0, dut->t1, dut->t2, dut->t3 };
        check_out(dut->o_pl, t);
    }
    dut->clk = 1; dut->eval();
    tck++;
}

static void set_inputs(bool valid, const Pix* p) {
    dut->in_valid = valid;
    if (!p) return;
    dut->in_tex = p->tex; dut->in_vq = p->vq;
    dut->in_texaddr = p->texaddr; dut->in_vqaddr = p->vqaddr;
    dut->in_off0 = p->off[0]; dut->in_off1 = p->off[1];
    dut->in_off2 = p->off[2]; dut->in_off3 = p->off[3];
    dut->in_pl = p->id;
}

static void add_pix(uint8_t phase, uint8_t tex, uint8_t vq, uint32_t ta, uint32_t va,
                    uint32_t o0, uint32_t o1, uint32_t o2, uint32_t o3) {
    Pix p;
    p.tex = tex; p.vq = vq;
    p.texaddr = ta & 0x1FFFFF; p.vqaddr = va & 0x1FFFFF;
    p.off[0] = o0 & 0x3FFFFF; p.off[1] = o1 & 0x3FFFFF;
    p.off[2] = o2 & 0x3FFFFF; p.off[3] = o3 & 0x3FFFFF;
    p.id = (uint16_t)seq.size(); p.phase = phase;
    seq.push_back(p);
}

// drive seq[from..to) with the given max input gap; returns false on timeout
static bool run_until(uint32_t issue_to, uint32_t check_to, int maxgap) {
    uint32_t in = 0;
    // find how many are already issued: caller tracks via static
    static uint32_t issued = 0;
    in = issued;
    bool presenting = false;
    int gap = 0;
    vluint64_t last_progress = tck;
    while (checked < check_to) {
        if (in < issue_to) {
            if (!presenting) { if (gap > 0) gap--; else presenting = true; }
            set_inputs(presenting, presenting ? &seq[in] : nullptr);
        } else set_inputs(false, nullptr);
        cycle();
        if (presenting && cyc_ready) {
            in++; presenting = false;
            gap = maxgap ? (int)(rnd() % (uint32_t)(maxgap + 1)) : 0;
            last_progress = tck;
        }
        if (checked && out_tick.back() > last_progress) last_progress = out_tick.back();
        if (tck - last_progress > 200000) {
            printf("[%llu] TIMEOUT: issued=%u checked=%u (want %u)\n",
                   (unsigned long long)tck, in, checked, check_to);
            errors++;
            issued = in;
            return false;
        }
    }
    issued = in;
    return true;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtex_fetch4_pl_tb_top;

    // ---------------- build the sequence ----------------
    // phase 0: THROUGHPUT - 4-line working set, back to back
    const uint32_t TP_N = 320;
    for (uint32_t i = 0; i < TP_N; i++)
        add_pix(0, 1, 0, 0x1000, 0, rnd() % 128, rnd() % 128, rnd() % 128, rnd() % 128);
    uint32_t ph0_end = seq.size();

    // phase 1: LOCALITY WALK - one fresh line per pixel (prefetch material)
    const uint32_t LW_N = 600;
    for (uint32_t i = 0; i < LW_N; i++) {
        uint32_t b = 0x40000 + i * 32;
        add_pix(1, 1, 0, 0x2000, 0, b, b + 8, b + 16, b + 24);
    }
    uint32_t ph1_end = seq.size();

    // phase 2: pure RANDOM (20% VQ, 10% untextured)
    for (uint32_t i = 0; i < 1500; i++) {
        uint32_t r = rnd();
        add_pix(2, (r % 10) != 0, (r % 5) == 0, rnd(), rnd(),
                rnd(), rnd(), rnd(), rnd());
    }
    uint32_t ph2_end = seq.size();

    // phase 3: ALIAS stress - 4 corners same index, different tags (32KB apart)
    for (uint32_t i = 0; i < 400; i++) {
        uint32_t base = (rnd() % 0x30000) & ~7u;
        uint32_t j    = (rnd() % 4) * 8;
        add_pix(3, 1, 0, 0x3000, 0,
                base, base + 32768 + j, base + 2 * 32768, base + 3 * 32768 + j);
    }
    uint32_t ph3_end = seq.size();

    // phase 4: VQ heavy (few codebooks)
    for (uint32_t i = 0; i < 500; i++) {
        uint32_t cb = 0x8000 + (rnd() % 4) * 0x400;
        add_pix(4, 1, 1, rnd(), cb, rnd(), rnd(), rnd(), rnd());
    }
    uint32_t ph4_end = seq.size();

    // phase 5: untextured mix
    for (uint32_t i = 0; i < 300; i++)
        add_pix(5, i & 1, 0, rnd(), rnd(), rnd(), rnd(), rnd(), rnd());
    uint32_t ph5_end = seq.size();

    // phase 6 (post-flush): locality again at fresh addresses
    for (uint32_t i = 0; i < 400; i++) {
        uint32_t b = 0x80000 + i * 32;
        add_pix(6, 1, 0, 0x4000, 0, b, b + 8, b + 16, b + 24);
    }

    // ---------------- reset ----------------
    dut->reset = 1; dut->flush = 0; set_inputs(false, nullptr);
    for (int i = 0; i < 8; i++) cycle();
    dut->reset = 0;
    // invalidate sweep runs at start; the FIFO absorbs early pixels meanwhile

    // ---------------- run ----------------
    // phase 0 back-to-back (throughput measured on the warmed tail)
    run_until(ph0_end, ph0_end, 0);
    {
        uint32_t a = 120, b = TP_N - 1;
        vluint64_t span = out_tick[b] - out_tick[a];
        uint32_t n = b - a;
        printf("throughput: %u warmed outputs in %llu cycles\n", n, (unsigned long long)span);
        if (span > n + 30) {
            printf("THROUGHPUT FAIL: expected ~%u cycles, got %llu\n", n, (unsigned long long)span);
            errors++;
        }
    }

    // phase 1: locality walk; require the prefetch walker to have fired
    uint32_t pf_before = dut->pf_issues;
    run_until(ph1_end, ph1_end, 0);
    uint32_t pf_delta = dut->pf_issues - pf_before;
    printf("prefetch bursts during locality walk: %u\n", pf_delta);
    if (pf_delta < 10) {
        printf("PREFETCH FAIL: walker barely fired (%u bursts)\n", pf_delta);
        errors++;
    }

    // phases 2..5 with random gaps
    run_until(ph2_end, ph2_end, 3);
    run_until(ph3_end, ph3_end, 1);
    run_until(ph4_end, ph4_end, 2);
    run_until(ph5_end, ph5_end, 1);

    // drain, FLUSH, continue
    for (int i = 0; i < 32; i++) cycle();
    dut->flush = 1; cycle(); dut->flush = 0;
    run_until((uint32_t)seq.size(), (uint32_t)seq.size(), 0);

    dut->final();
    printf("=== tex_fetch4_pl: %u outputs checked, %u errors, pf_issues=%u ===\n",
           checked, errors, (uint32_t)dut->pf_issues);
    if (errors || checked != seq.size()) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}

// tex_mlp_tb - drives tex_cache_4p_1c's four corner ports directly to pin down the
// MULTI-OUTSTANDING demand fill path (MLP). See tex_mlp_tb_top.sv for the channel model.
//
// Phases:
//   1 DEDUP     4 corners in ONE line            -> exactly 1 burst
//   2 SPREAD    4 corners in n distinct lines    -> exactly n bursts, CONCURRENT, and the
//                                                   batch latency must grow far slower
//                                                   than n serial round trips
//   3 ALIAS     corners on one index, many tags  -> right data, bounded batches
//   4 RANDOM    random address stress            -> every word model-checked
//   5 THRUPUT   all-hit stream                   -> 1 group/cycle, no bursts
//   6 FLUSH     flush mid-stream                 -> refetches, still correct
//   7 RIDE      demand wants a line the prefetch client already has in flight
//                                                -> no second burst for it
#include "Vtex_mlp_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static Vtex_mlp_tb_top* dut;
static vluint64_t cyc = 0;
static int fails = 0;

static void fail(const char* what, const char* det = "") {
    printf("FAIL [cyc %llu] %s %s\n", (unsigned long long)cyc, what, det);
    if (++fails > 20) { printf("too many failures\n"); exit(1); }
}

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    cyc++;
}

// memory content: must match vword() in the tb top bit for bit
static uint64_t vword(uint32_t w) {
    uint32_t h = (uint32_t)(w * 2654435761u);
    return 0xC0FFEE0000000000ull | ((uint64_t)w << 16) | (uint64_t)(h & 0xffff);
}

// word address from (line, word-in-line)
static uint32_t wa(uint32_t line, uint32_t wsel) { return (line << 2) | (wsel & 3); }

struct Res { uint64_t d[4]; vluint64_t acked; };

// Present one group and wait for its ack. The cache is group-atomic: ready gates the
// accept, ack (2+ cycles later) carries all four words at once.
static Res group(const uint32_t a[4], vluint64_t* issued_at = nullptr) {
    dut->q_a0 = a[0]; dut->q_a1 = a[1]; dut->q_a2 = a[2]; dut->q_a3 = a[3];
    dut->q_req = 1;
    // wait for the accept
    int guard = 0;
    while (!dut->q_ready) { tick(); if (++guard > 5000) { fail("ready never asserted"); break; } }
    if (issued_at) *issued_at = cyc;
    tick();                       // the accept edge
    dut->q_req = 0;
    Res r{};
    guard = 0;
    while (!dut->q_ack) { tick(); if (++guard > 5000) { fail("ack never arrived"); break; } }
    r.d[0] = dut->q_d0; r.d[1] = dut->q_d1; r.d[2] = dut->q_d2; r.d[3] = dut->q_d3;
    r.acked = cyc;
    tick();                       // consume the ack cycle
    return r;
}

static void check(const uint32_t a[4], const Res& r, const char* who) {
    for (int i = 0; i < 4; i++)
        if (r.d[i] != vword(a[i])) {
            char b[192];
            snprintf(b, sizeof b, "%s port%d addr=%07x got %016llx want %016llx",
                     who, i, a[i], (unsigned long long)r.d[i],
                     (unsigned long long)vword(a[i]));
            fail("wrong word", b);
        }
}

static void reset_dut() {
    dut->reset = 1; dut->flush = 0; dut->q_req = 0; dut->pfill = 0; dut->pfaddr = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->reset = 0;
    // let the invalidate sweep finish (1024 entries)
    for (int i = 0; i < 1100; i++) tick();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtex_mlp_tb_top;
    reset_dut();

    // ---------------- 1 DEDUP: four corners, one line ----------------
    {
        uint32_t base = dut->n_burst;
        uint32_t a[4] = { wa(0x100, 0), wa(0x100, 1), wa(0x100, 2), wa(0x100, 3) };
        Res r = group(a);
        check(a, r, "dedup");
        uint32_t n = dut->n_burst - base;
        if (n != 1) { char b[64]; snprintf(b, sizeof b, "expected 1 burst, got %u", n); fail("dedup", b); }
        printf("1 DEDUP    : 4 corners / 1 line -> %u burst\n", n);
    }

    // ---------------- 2 SPREAD: n distinct lines per group ----------------
    // Latency is measured accept->ack. Serial fills would make it grow by a full round
    // trip per line; overlapped fills grow by roughly the extra beats only.
    vluint64_t lat[5] = {0,0,0,0,0};
    for (int n = 1; n <= 4; n++) {
        reset_dut();
        uint32_t base = dut->n_burst;
        // n distinct lines, corners spread over them (repeat the last to fill 4 ports)
        uint32_t line[4] = { 0x200u, 0x311u, 0x422u, 0x533u };
        uint32_t a[4];
        for (int i = 0; i < 4; i++) a[i] = wa(line[i < n ? i : n - 1], i);
        vluint64_t t0;
        Res r = group(a, &t0);
        check(a, r, "spread");
        uint32_t nb = dut->n_burst - base;
        lat[n] = r.acked - t0;
        if (nb != (uint32_t)n) { char b[64]; snprintf(b, sizeof b, "n=%d expected %d bursts, got %u", n, n, nb); fail("spread", b); }
        if (n > 1 && dut->max_out < 2) fail("spread", "bursts never overlapped (max_out < 2)");
        printf("2 SPREAD   : n=%d lines -> %u bursts, max_out=%u, latency=%llu cyc\n",
               n, nb, dut->max_out, (unsigned long long)lat[n]);
    }
    // the point of the whole exercise: 4 lines must cost far less than 4 serial trips
    if (lat[4] >= 2 * lat[1])
        fail("spread", "4-line batch cost >= 2x a 1-line batch - fills are not concurrent");
    printf("           : 4-line batch = %.2fx a 1-line batch (serial would be ~4x)\n",
           (double)lat[4] / (double)lat[1]);

    // ---------------- 3 ALIAS: same index, different tags ----------------
    {
        reset_dut();
        for (int rep = 0; rep < 32; rep++) {
            uint32_t ix = 0x37;
            uint32_t a[4] = { wa((0u << 10) | ix, 0), wa((1u << 10) | ix, 1),
                              wa((2u << 10) | ix, 2), wa((3u << 10) | ix, 3) };
            Res r = group(a);
            check(a, r, "alias");
        }
        printf("3 ALIAS    : 32 groups of 4 corners on one index, all tags - ok\n");
    }

    // ---------------- 4 RANDOM stress with the prefetch port active ----------------
    {
        reset_dut();
        srand(12345);
        uint32_t pf_line = 0;
        for (int i = 0; i < 4000; i++) {
            uint32_t a[4];
            // mix: mostly a local walk (shared lines), sometimes wild
            uint32_t l0 = (rand() % 8 == 0) ? (uint32_t)(rand() & 0x1ffff)
                                            : (uint32_t)(0x800 + (i / 3) % 64);
            for (int k = 0; k < 4; k++) {
                uint32_t l = l0 + ((rand() % 3 == 0) ? (uint32_t)(rand() % 5) : 0u);
                a[k] = wa(l & 0x7ffffff, rand() & 3);
            }
            // keep the prefetch client fed with plausible neighbours
            if (!dut->pfbusy) {
                pf_line = (l0 + 1 + (rand() % 4)) & 0x7ffffff;
                dut->pfaddr = wa(pf_line, 0);
                dut->pfill = 1;
            } else dut->pfill = 0;
            Res r = group(a);
            check(a, r, "random");
        }
        dut->pfill = 0;
        printf("4 RANDOM   : 4000 groups w/ prefetch active - ok (%u demand + %u prefetch bursts)\n",
               (unsigned)dut->n_burst, (unsigned)dut->n_pburst);
    }

    // ---------------- 5 THRUPUT: an all-hit stream acks 1 group/cycle ----------------
    {
        // warm 8 lines, then stream them back to back
        uint32_t line[8];
        for (int i = 0; i < 8; i++) line[i] = 0x1000 + i;
        for (int i = 0; i < 8; i++) {
            uint32_t a[4] = { wa(line[i],0), wa(line[i],1), wa(line[i],2), wa(line[i],3) };
            Res r = group(a); check(a, r, "warm");
        }
        uint32_t base = dut->n_burst;
        // back-to-back: hold req high and count acks per cycle
        int acks = 0, cycles = 0;
        dut->q_req = 1;
        for (int i = 0; i < 200; i++) {
            uint32_t l = line[i & 7];
            dut->q_a0 = wa(l,0); dut->q_a1 = wa(l,1); dut->q_a2 = wa(l,2); dut->q_a3 = wa(l,3);
            if (!dut->q_ready) fail("thruput", "ready dropped on an all-hit stream");
            tick();
            cycles++;
            if (dut->q_ack) acks++;
        }
        dut->q_req = 0;
        // drain
        for (int i = 0; i < 8; i++) { tick(); if (dut->q_ack) acks++; }
        if (dut->n_burst != base) fail("thruput", "a warmed line missed");
        if (acks < cycles - 4) { char b[64]; snprintf(b, sizeof b, "%d acks in %d cycles", acks, cycles); fail("thruput", b); }
        printf("5 THRUPUT  : %d acks in %d cycles on an all-hit stream, 0 bursts\n", acks, cycles);
    }

    // ---------------- 6 FLUSH mid-stream ----------------
    {
        uint32_t a[4] = { wa(0x1000,0), wa(0x1000,1), wa(0x1000,2), wa(0x1000,3) };
        uint32_t base = dut->n_burst;
        dut->flush = 1; tick(); dut->flush = 0;
        for (int i = 0; i < 1100; i++) tick();          // sweep
        Res r = group(a); check(a, r, "flush");
        if (dut->n_burst == base) fail("flush", "a flushed line still hit");
        printf("6 FLUSH    : post-flush refetch ok\n");
    }

    // ---------------- 7 RIDE: demand wants a line the prefetch has in flight ----------------
    {
        reset_dut();
        uint32_t L = 0x2abc;
        // hand the prefetch client the line and let its re-check pass + burst start
        dut->pfaddr = wa(L, 0); dut->pfill = 1;
        for (int i = 0; i < 6; i++) tick();
        dut->pfill = 0;
        if (!dut->pfbusy) fail("ride", "prefetch receiver never took the line");
        uint32_t base = dut->n_burst;
        uint32_t a[4] = { wa(L,0), wa(L,1), wa(L,2), wa(L,3) };
        Res r = group(a);
        check(a, r, "ride");
        uint32_t n = dut->n_burst - base;
        if (n != 0) { char b[64]; snprintf(b, sizeof b, "expected 0 demand bursts, got %u", n); fail("ride", b); }
        printf("7 RIDE     : demand rode the in-flight prefetch, %u extra demand bursts\n", n);
    }

    // ---------------- 8 PFDEPTH: the receiver pipelines several speculative lines ----
    // The walker holds pf_fill until !pf_fbusy. With a single-line receiver that meant one
    // line per FULL round trip; the ring must release it as soon as the burst is issued,
    // so a stream of distinct lines has to hand over far faster AND several must be in
    // flight at once.
    // NOTE the receiver can only advance while the demand pipe is NOT presenting reads
    // (pchk_go and p_we both need !rd_en, and rd_en is high on EVERY S_RUN cycle) - which
    // is exactly the freeze window the walker probes in. So this phase must run demand
    // misses and the prefetch stream together, as the real core does.
    {
        reset_dut();
        uint32_t pbase = dut->n_pburst, dbase = dut->n_burst;
        int handovers = 0, maxocc = 0;
        uint32_t DL = 0x5000, PL = 0x6000;      // disjoint demand / prefetch line streams
        dut->q_req = 1;
        vluint64_t t0 = cyc;
        while (cyc - t0 < 4000) {
            dut->q_a0 = wa(DL,0); dut->q_a1 = wa(DL,1);
            dut->q_a2 = wa(DL,2); dut->q_a3 = wa(DL,3);
            bool took = dut->q_ready;
            dut->pfaddr = wa(PL, 0); dut->pfill = 1;
            bool handed = !dut->pfbusy;         // the walker's contract: hold until !fbusy
            tick();
            if (took)   DL++;
            if (handed) { handovers++; PL++; }
            if (dut->pq_occ > maxocc) maxocc = dut->pq_occ;
        }
        dut->q_req = 0; dut->pfill = 0;
        for (int i = 0; i < 400; i++) { tick(); if (dut->pq_occ > maxocc) maxocc = dut->pq_occ; }
        uint32_t pnb = dut->n_pburst - pbase, dnb = dut->n_burst - dbase;
        if (maxocc < 2) fail("pfdepth", "prefetch ring never held more than one line");
        printf("8 PFDEPTH  : %u demand + %u prefetch bursts in 4000 cyc, %d handovers, "
               "ring high-water %d of 4\n", dnb, pnb, handovers, maxocc);
    }

    if (dut->n_err) fail("channel", "arbiter protocol violations (see $error above)");

    printf(fails ? "\n=== tex_mlp_tb: %d FAILURE(S) ===\n" : "\n=== tex_mlp_tb: all checks passed ===\n", fails);
    delete dut;
    return fails ? 1 : 0;
}

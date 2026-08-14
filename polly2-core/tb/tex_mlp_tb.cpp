// tex_mlp_tb - drives tex_fill_engine + its two caches. See tex_mlp_tb_top.sv for what
// this covers that tex_fetch4_pl does not.
//
//   1 DEDUP     4 corners in ONE line              -> exactly 1 burst
//   2 SPREAD    4 corners in n distinct lines      -> n bursts, CONCURRENT
//   3 CAPS      flood the scan port                -> COL outstanding never exceeds its
//                                                     cap, and the queue self-limits
//   4 VQPRIO    COL queue loaded, then a VQ miss   -> the VQ burst goes out first, and
//                                                     VQ slots stay available
//   5 MIXED     both caches + scan running together, every word model-checked
//   6 FLUSH     mid-run flush with bursts in flight (orphan drain)
#include "Vtex_mlp_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>

static Vtex_mlp_tb_top* dut;
static vluint64_t cyc = 0;
static int fails = 0;

static void fail(const char* what, const char* det = "") {
    printf("FAIL [cyc %llu] %s %s\n", (unsigned long long)cyc, what, det);
    if (++fails > 20) { printf("too many failures\n"); exit(1); }
}
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cyc++; }

static uint64_t vword(uint32_t w) {
    uint32_t h = (uint32_t)(w * 2654435761u);
    return 0xC0FFEE0000000000ull | ((uint64_t)w << 16) | (uint64_t)(h & 0xffff);
}
static uint32_t wa(uint32_t line, uint32_t wsel) { return (line << 2) | (wsel & 3); }

static void reset_dut() {
    dut->reset = 1; dut->flush = 0;
    dut->q_req = 0; dut->v_req = 0; dut->s_req = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 1100; i++) tick();     // the caches' invalidate sweep
}

// one data-cache quad; returns the ack cycle
static vluint64_t quad(const uint32_t a[4], uint64_t out[4], vluint64_t* t0 = nullptr) {
    dut->q_a0=a[0]; dut->q_a1=a[1]; dut->q_a2=a[2]; dut->q_a3=a[3];
    dut->q_req = 1;
    int guard = 0;
    while (!dut->q_ready) { tick(); if (++guard > 20000) { fail("q_ready never asserted"); break; } }
    if (t0) *t0 = cyc;
    tick(); dut->q_req = 0;
    guard = 0;
    while (!dut->q_ack) { tick(); if (++guard > 20000) { fail("q_ack never arrived"); break; } }
    out[0]=dut->q_d0; out[1]=dut->q_d1; out[2]=dut->q_d2; out[3]=dut->q_d3;
    vluint64_t at = cyc;
    tick();
    return at;
}
static void check4(const uint32_t a[4], const uint64_t got[4], const char* who) {
    for (int i = 0; i < 4; i++)
        if (got[i] != vword(a[i])) {
            char b[192];
            snprintf(b, sizeof b, "%s port%d addr=%07x got %016llx want %016llx",
                     who, i, a[i], (unsigned long long)got[i],
                     (unsigned long long)vword(a[i]));
            fail("wrong word", b);
        }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtex_mlp_tb_top;
    reset_dut();
    uint64_t d[4];

    // ---------------- 1 DEDUP ----------------
    {
        uint32_t base = dut->n_burst;
        uint32_t a[4] = { wa(0x100,0), wa(0x100,1), wa(0x100,2), wa(0x100,3) };
        quad(a, d); check4(a, d, "dedup");
        uint32_t n = dut->n_burst - base;
        if (n != 1) { char b[64]; snprintf(b,sizeof b,"expected 1 burst, got %u", n); fail("dedup", b); }
        printf("1 DEDUP  : 4 corners / 1 line -> %u burst\n", n);
    }

    // ---------------- 2 SPREAD ----------------
    vluint64_t lat[5] = {0,0,0,0,0};
    for (int n = 1; n <= 4; n++) {
        reset_dut();
        uint32_t base = dut->n_burst;
        uint32_t line[4] = { 0x200u, 0x311u, 0x422u, 0x533u };
        uint32_t a[4];
        for (int i = 0; i < 4; i++) a[i] = wa(line[i < n ? i : n-1], i);
        vluint64_t t0; vluint64_t at = quad(a, d, &t0);
        check4(a, d, "spread");
        uint32_t nb = dut->n_burst - base;
        lat[n] = at - t0;
        if (nb != (uint32_t)n) { char b[64]; snprintf(b,sizeof b,"n=%d got %u bursts", n, nb); fail("spread", b); }
        if (n > 1 && dut->max_out < 2) fail("spread", "bursts never overlapped");
        printf("2 SPREAD : n=%d lines -> %u bursts, max_out=%u, latency=%llu cyc\n",
               n, nb, dut->max_out, (unsigned long long)lat[n]);
    }
    if (lat[4] >= 2*lat[1]) fail("spread", "4-line batch >= 2x a 1-line batch");
    printf("         : 4-line batch = %.2fx a 1-line batch (serial would be ~4x)\n",
           (double)lat[4]/(double)lat[1]);

    // ---------------- 3 CAPS: flood the scan port ----------------
    {
        reset_dut();
        int maxcol = 0; uint32_t L = 0x4000;
        dut->s_req = 1;
        for (int i = 0; i < 3000; i++) {
            dut->s_line = L;
            bool took = dut->s_ack;
            tick();
            if (took) L++;
            if (dut->col_out > maxcol) maxcol = dut->col_out;
        }
        dut->s_req = 0;
        for (int i = 0; i < 400; i++) tick();
        if (maxcol < 2) fail("caps", "COL never went multi-outstanding under a scan flood");
        printf("3 CAPS   : scan flood -> COL outstanding high-water %d, %u bursts\n",
               maxcol, (unsigned)dut->n_burst);
    }

    // ---------------- 4 VQPRIO ----------------
    // load the COL queue from the scan port, then present a VQ quad miss: the engine must
    // put the VQ burst out ahead of the queued COL work, and its slots stay free.
    {
        reset_dut();
        uint32_t L = 0x5000;
        dut->s_req = 1;
        for (int i = 0; i < 40; i++) { dut->s_line = L; if (dut->s_ack) L++; tick(); }
        // keep the scan port hammering so COL always has work queued
        uint32_t vqb = dut->n_vq;
        uint32_t va[4] = { wa(0x6001,0), wa(0x6002,1), wa(0x6003,2), wa(0x6004,3) };
        dut->v_a0=va[0]; dut->v_a1=va[1]; dut->v_a2=va[2]; dut->v_a3=va[3];
        dut->v_req = 1;
        int guard = 0;
        while (!dut->v_ack) {
            dut->s_line = L; if (dut->s_ack) L++;
            tick();
            if (++guard > 20000) { fail("vqprio", "VQ quad never acked"); break; }
        }
        dut->v_req = 0; dut->s_req = 0;
        uint32_t nv = dut->n_vq - vqb;
        if (nv != 4) { char b[64]; snprintf(b,sizeof b,"expected 4 VQ bursts, got %u", nv); fail("vqprio", b); }
        if (!dut->vq_won) fail("vqprio", "no VQ burst ever won issue while COL had work");
        printf("4 VQPRIO : VQ quad resolved in %d cyc with COL saturated, %u VQ bursts, "
               "VQ-over-COL observed=%d\n", guard, nv, (int)dut->vq_won);
    }

    // ---------------- 5 MIXED ----------------
    {
        reset_dut();
        srand(7777);
        uint32_t S = 0x7000;
        dut->s_req = 1;
        for (int i = 0; i < 1500; i++) {
            uint32_t l0 = (rand() % 6 == 0) ? (uint32_t)(rand() & 0x3fff)
                                            : (uint32_t)(0x800 + (i/3) % 48);
            uint32_t a[4];
            for (int k = 0; k < 4; k++)
                a[k] = wa((l0 + ((rand()%3==0) ? (uint32_t)(rand()%4) : 0u)) & 0x7ffffff, rand()&3);
            // keep the scan port and the VQ cache busy alongside
            dut->s_line = S; if (dut->s_ack) S++;
            if ((i & 7) == 0) {
                uint32_t vl = 0x9000 + (i % 97);
                dut->v_a0=wa(vl,0); dut->v_a1=wa(vl,1); dut->v_a2=wa(vl,2); dut->v_a3=wa(vl,3);
                dut->v_req = 1;
            }
            quad(a, d); check4(a, d, "mixed");
            if (dut->v_ack) dut->v_req = 0;
        }
        dut->s_req = 0; dut->v_req = 0;
        for (int i = 0; i < 400; i++) tick();
        printf("5 MIXED  : 1500 quads + scan + VQ traffic - ok (COL=%u VQ=%u bursts)\n",
               (unsigned)dut->n_col, (unsigned)dut->n_vq);
    }

    // ---------------- 6 FLUSH with bursts in flight ----------------
    {
        uint32_t a[4] = { wa(0xA100,0), wa(0xA100,1), wa(0xA100,2), wa(0xA100,3) };
        dut->s_req = 1; dut->s_line = 0xB000;
        for (int i = 0; i < 6; i++) tick();          // get bursts in flight
        dut->s_req = 0;
        dut->flush = 1; tick(); dut->flush = 0;      // orphan them
        for (int i = 0; i < 1400; i++) tick();       // sweep + drain
        quad(a, d); check4(a, d, "flush");
        printf("6 FLUSH  : flush with bursts in flight, post-flush refetch ok\n");
    }

    if (dut->n_err) fail("channel", "protocol violations (see $error above)");
    printf(fails ? "\n=== tex_mlp_tb: %d FAILURE(S) ===\n" : "\n=== tex_mlp_tb: all checks passed ===\n", fails);
    delete dut;
    return fails ? 1 : 0;
}

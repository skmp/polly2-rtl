// simplex_pvr_top read master vs core reset (pvr-rd-reset).
//
// The read master keeps rd_beats (beats still owed by the bridge) across reset
// on purpose, so a miscount in it used to wedge every read until the FPGA was
// reprogrammed. This bench checks the contract that keeps it exact:
//
//  1. Avalon hold rule: once DDRAM_RD is up and the bridge stalls it, it stays
//     up with the same address and burstcount until accepted - reset or not.
//     (Withdrawing a stalled read is what MiSTer's f2sdram_safe_terminator
//     guards against; MMIO RESET never reaches that module.)
//  2. Reset at every phase of a read (taken, stalled, accepted, mid-beats) with
//     a bridge that stalls ~50% of cycles: after each reset the stale beats are
//     swallowed and a fresh burst returns exactly its 8 beats, no strays.
//  3. Lost burst: the bridge accepts a command and never returns its beats (what
//     any miscount looks like). After the next reset the master must recover on
//     its own and serve a fresh burst instead of staying blocked forever.
#include "Vsimplex_pvr_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vsimplex_pvr_top* dut;
static int errors = 0;

static uint32_t lfsr = 0xACE1u;
static uint32_t rnd() { lfsr = (lfsr >> 1) ^ (-(int)(lfsr & 1) & 0xB400u); return lfsr; }

// ---------------- f2sdram read-port model + Avalon monitor ----------------
struct RdCmd { uint64_t addr; uint32_t left; };
static std::vector<RdCmd> rdq;
static uint64_t rd_pattern(uint64_t a) { return (a << 32) | (~a & 0xFFFFFFFFull); }
static bool drop_next = false;     // scenario 3: accept the next command, return nothing
static bool held = false;          // last cycle: RD up and stalled
static uint64_t held_addr = 0;
static uint32_t held_burst = 0;
static int hold_violations = 0;

static void read_port_tick() {
    // Avalon hold rule, checked on the outputs about to be sampled
    if (held) {
        if (!dut->DDRAM_RD || dut->DDRAM_ADDR != held_addr || dut->DDRAM_BURSTCNT != held_burst) {
            if (++hold_violations <= 4)
                printf("FAIL: stalled read %s (addr %llx burst %u)\n",
                       dut->DDRAM_RD ? "changed while held" : "withdrawn",
                       (unsigned long long)held_addr, held_burst);
        }
    }
    dut->DDRAM_BUSY = (rnd() & 1);                 // ~50% waitrequest
    // deliver first (multi-cycle latency), sparse ~25% beat rate
    dut->DDRAM_DOUT_READY = 0;
    if (!rdq.empty() && (rnd() & 3) == 1) {
        RdCmd& c = rdq.front();
        dut->DDRAM_DOUT = rd_pattern(c.addr);
        dut->DDRAM_DOUT_READY = 1;
        c.addr++;
        if (--c.left == 0) rdq.erase(rdq.begin());
    }
    held = dut->DDRAM_RD && dut->DDRAM_BUSY;
    held_addr = dut->DDRAM_ADDR;
    held_burst = dut->DDRAM_BURSTCNT;
    if (dut->DDRAM_RD && !dut->DDRAM_BUSY) {
        if (dut->DDRAM_BURSTCNT == 0) { printf("FAIL: burstcount 0 issued\n"); errors++; }
        if (drop_next) drop_next = false;          // accepted, beats never come
        else rdq.push_back({dut->DDRAM_ADDR, dut->DDRAM_BURSTCNT});
    }
}

static void tick() {
    dut->clk = 0; dut->eval();
    dut->DDRAM2_BUSY = 0;
    read_port_tick();
    dut->clk = 1; dut->eval();
}

static void regwrite(int addr, uint32_t data) {
    dut->wr_en = 1; dut->wr_addr = addr; dut->wr_data = data;
    tick();
    dut->wr_en = 0;
    tick();
}

// stub telemetry: TEST_SELECT = beats seen, FB_W_SOF2 = stray beats,
// FB_R_SOF2 = xor of dout[31:0]
static bool check_fresh_burst(uint32_t word, const char* what, int wait) {
    regwrite(8, word);
    for (int i = 0; i < wait && dut->TEST_SELECT < 8; i++) tick();
    for (int i = 0; i < 200; i++) tick();          // room for extra (wrong) beats
    uint32_t want_x = 0;
    for (int i = 0; i < 8; i++) want_x ^= (uint32_t)(rd_pattern(word + i) & 0xFFFFFFFF);
    bool ok = dut->TEST_SELECT == 8 && dut->FB_W_SOF2 == 0 && dut->FB_R_SOF2 == want_x;
    if (!ok) {
        printf("FAIL: %s: core saw %u beats (want 8), %u strays, xor %08x want %08x\n",
               what, dut->TEST_SELECT, dut->FB_W_SOF2, dut->FB_R_SOF2, want_x);
        errors++;
    }
    return ok;
}

static void reset_core(int cycles) {
    dut->reset = 1;
    for (int i = 0; i < cycles; i++) tick();
    dut->reset = 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vsimplex_pvr_top;
    dut->reset = 1;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 8; i++) tick();

    // ---- scenario 2 (exercises 1 throughout): reset at every phase ----
    int sweeps = 0;
    for (int seed = 0; seed < 4; seed++) {
        lfsr = 0xACE1u + seed * 0x1111u;
        for (int k = 0; k < 48; k++) {
            regwrite(8, 0x100 + k * 16);           // burst in flight
            for (int i = 0; i < k; i++) tick();
            reset_core(4 + (k % 9));               // reset lands at phase k
            int guard = 0;                         // let every stale beat drain
            while (!rdq.empty() && ++guard < 4000) tick();
            for (int i = 0; i < 16; i++) tick();
            char what[64];
            snprintf(what, sizeof what, "seed %d, reset at +%d", seed, k);
            if (!check_fresh_burst(0x4000 + k * 16, what, 4000) && errors > 8) goto done;
            reset_core(4);                         // clear the stub's counters
            for (int i = 0; i < 8; i++) tick();
            sweeps++;
        }
    }
    printf("[reset sweep] %d reset phases, fresh burst exact after each\n", sweeps);

    // ---- scenario 3: a burst that never returns ----
    drop_next = true;
    regwrite(8, 0x800);
    for (int i = 0; i < 200; i++) tick();          // accepted, no beats
    reset_core(8);                                 // what AutoReset does next
    for (int i = 0; i < 16; i++) tick();
    if (check_fresh_burst(0x900, "lost burst, after the flush timeout", 70000))
        printf("[lost burst] read channel recovered without reprogramming\n");

done:
    if (hold_violations) {
        printf("FAIL: %d Avalon hold-rule violations\n", hold_violations);
        errors++;
    }
    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    delete dut;
    return errors != 0;
}

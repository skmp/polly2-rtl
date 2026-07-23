// simplex_pvr_top burst-vs-reset testbench.
//
// Models the HPS f2sdram ports the way the hard bridge behaves:
//  - write port: once a burst command (addr, burstcount) is accepted it
//    COUNTS DATA BEATS and ignores address/burstcount until all beats have
//    arrived. A fabric reset that drops WE mid-burst therefore desyncs it
//    permanently (it eats the next burst's first beats as this one's tail) -
//    the "stuck off-by-one writes until fabric reboot" bug.
//  - read port: accepted commands are executed to completion regardless of
//    fabric state - beats of a burst issued before a reset still arrive
//    after it, and must be swallowed without reaching the core.
//
// Scenarios:
//  1. Stream pixels, assert core reset while a write burst is mid-flight,
//     stream a fresh tile after reset -> every post-reset pixel must land at
//     its correct byte address (the in-flight burst must have been completed
//     by the DUT during reset; the model checks it never ends up mid-burst).
//  2. Issue a read burst, reset after 2 beats returned, deliver the stale
//     beats straddling the reset release, then issue a second read -> the
//     core must see exactly the 8 beats of the second burst (stale beats
//     counted but suppressed: unexpected-beat counter must stay 0).
#include "Vsimplex_pvr_top.h"
#include "verilated.h"
#include <cstdio>
#include <map>
#include <vector>
#include <cstdint>

static Vsimplex_pvr_top* dut;
static int errors = 0;

static uint32_t lfsr = 0xACE1u;
static int rnd() { lfsr = (lfsr >> 1) ^ (-(int)(lfsr & 1) & 0xB400u); return lfsr & 3; }

// ---------------- f2sdram write-port model (beat counting) ----------------
static std::map<uint64_t, uint8_t> mem;   // byte address -> value
static uint32_t w_expect = 0;             // beats remaining of current burst
static uint64_t w_cur = 0;                // current word address

static void write_port_tick() {
    dut->DDRAM2_BUSY = (rnd() == 0);      // ~25% waitrequest
    if (dut->DDRAM2_WE && !dut->DDRAM2_BUSY) {
        if (w_expect == 0) {              // idle: latch a new command
            w_cur = dut->DDRAM2_ADDR;
            w_expect = dut->DDRAM2_BURSTCNT;
            if (w_expect == 0) { printf("BAD burstcount 0\n"); errors++; w_expect = 1; }
        }
        // mid-burst: address/burstcount ignored, beat counted - like the bridge
        for (int b = 0; b < 8; b++)
            if (dut->DDRAM2_BE & (1 << b))
                mem[w_cur * 8 + b] = (uint8_t)(dut->DDRAM2_DIN >> (8 * b));
        w_cur++;
        w_expect--;
    }
}

// ---------------- f2sdram read-port model ----------------
struct RdCmd { uint64_t addr; uint32_t left; };
static std::vector<RdCmd> rdq;
static uint64_t rd_pattern(uint64_t a) { return (a << 32) | (~a & 0xFFFFFFFFull); }

static void read_port_tick() {
    dut->DDRAM_BUSY = (rnd() == 0);
    // deliver first (so a command never returns data on its accept cycle;
    // the real bridge has multi-cycle latency), sparse ~25% beat rate so
    // stale beats straddle a reset release
    dut->DDRAM_DOUT_READY = 0;
    if (!rdq.empty() && rnd() == 1) {
        RdCmd& c = rdq.front();
        dut->DDRAM_DOUT = rd_pattern(c.addr);
        dut->DDRAM_DOUT_READY = 1;
        c.addr++;
        if (--c.left == 0) rdq.erase(rdq.begin());
    }
    if (dut->DDRAM_RD && !dut->DDRAM_BUSY)
        rdq.push_back({dut->DDRAM_ADDR, dut->DDRAM_BURSTCNT});
}

static void tick() {
    dut->clk = 0; dut->eval();
    write_port_tick();                    // sample outputs, drive inputs for posedge
    read_port_tick();
    dut->clk = 1; dut->eval();
}

static void regwrite(int addr, uint32_t data) {
    dut->wr_en = 1; dut->wr_addr = addr; dut->wr_data = data;
    tick();
    dut->wr_en = 0;
    tick();
}

// stub argb = hash32({py, px}) (xorpat 0 here); master 565-packs with refsw2
// quantization (c*31/255, no dither)
static int div255i(int x) { return (x + (x >> 8) + 1) >> 8; }
static uint16_t px565(uint32_t pix) {
    uint32_t a = (((pix / 640) << 11) | (pix % 640)) * 2654435761u;
    int r = (a >> 16) & 0xFF, g = (a >> 8) & 0xFF, b = a & 0xFF;
    return (uint16_t)((div255i(r * 31) << 11) | (div255i(g * 63) << 5) | div255i(b * 31));
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vsimplex_pvr_top;
    dut->reset = 1;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 4; i++) tick();

    const uint32_t SOF = (1u << 22) | 0x100;  // bank 1 = upper half (BE=F0), base word 0x40
    const uint64_t FB_BASE = (SOF & 0x3FFFFC) >> 2;
    regwrite(12, SOF);

    // ---- scenario 1: reset mid write-burst ----
    regwrite(0, 0);          // pix base 0
    regwrite(4, 64);         // stream 64 px = 32 words = 2 full bursts
    int guard = 0;           // run until a burst is mid-flight
    while (!(w_expect > 4) && ++guard < 4000) tick();
    if (guard >= 4000) { printf("never saw a mid-flight write burst\n"); errors++; }
    dut->reset = 1;          // core reset lands mid-burst
    for (int i = 0; i < 12; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 200; i++) tick();  // let the reset-drain finish
    if (w_expect != 0) {
        printf("FAIL: bridge left mid-burst after reset (expect=%u) - desync\n", w_expect);
        errors++;
        w_expect = 0;        // resync model so the next scenario still runs
    }

    // ---- post-reset tile: every pixel must land exactly right ----
    mem.clear();
    regwrite(0, 4096);       // fresh base, word 2048
    regwrite(4, 64);
    for (int i = 0; i < 3000; i++) tick();  // stream + idle-gap flush + drain
    if (w_expect != 0) { printf("FAIL: burst still open after stream\n"); errors++; }
    for (uint32_t i = 0; i < 64; i++) {
        uint32_t pix = 4096 + i;
        uint64_t word = FB_BASE + (pix >> 1);
        uint64_t byte0 = word * 8 + 4 + ((pix & 1) ? 2 : 0);  // bank 1 = upper 32-bit half
        uint16_t want = px565(pix);
        uint16_t got = (uint16_t)(mem.count(byte0) ? mem[byte0] : 0)
                     | (uint16_t)((mem.count(byte0 + 1) ? mem[byte0 + 1] : 0) << 8);
        if (got != want) {
            printf("FAIL: pix %u at byte %llu: got %04x want %04x\n",
                   pix, (unsigned long long)byte0, got, want);
            if (++errors > 8) break;
        }
    }

    // ---- scenario 2: reset mid read-burst ----
    regwrite(8, 0x100);      // read burst A: 8 beats from 0x100
    guard = 0;               // wait for 2 beats to reach the core
    while (dut->TEST_SELECT < 2 && ++guard < 4000) tick();
    if (guard >= 4000) { printf("burst A beats never arrived\n"); errors++; }
    dut->reset = 1;          // stale beats will straddle the release
    for (int i = 0; i < 6; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 600; i++) tick();  // stale beats drain into the adapter
    regwrite(8, 0x200);      // read burst B: 8 beats from 0x200
    for (int i = 0; i < 2000; i++) tick();
    uint32_t beats = dut->TEST_SELECT;
    uint32_t unexp = dut->FB_W_SOF2;
    uint32_t xacc = dut->FB_R_SOF2;
    uint32_t want_x = 0;
    for (int i = 0; i < 8; i++) want_x ^= (uint32_t)(rd_pattern(0x200 + i) & 0xFFFFFFFF);
    if (unexp != 0) { printf("FAIL: %u stray beats reached the core after reset\n", unexp); errors++; }
    if (beats != 8) { printf("FAIL: core saw %u beats for burst B (want 8)\n", beats); errors++; }
    if (xacc != want_x) { printf("FAIL: burst B data xor %08x want %08x - misaligned beats\n", xacc, want_x); errors++; }

    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    delete dut;
    return errors != 0;
}

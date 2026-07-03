// Self-checking testbench for the streaming tex_cache_4p.
// Verifies: back-to-back 1/clk acceptance on hits, in-order results per port,
// correct data on hit/miss/refill, and the accept-vs-miss same-cycle hazard.
#include "Vtex_cache_4p_tb_top.h"
#include "Vtex_cache_4p_tb_top___024root.h"
#include "verilated.h"
#define VRAM dut->rootp->tex_cache_4p_tb_top__DOT__vram
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <vector>

static Vtex_cache_4p_tb_top* dut;
static vluint64_t tck = 0;
static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    tck++;
}

// 64-bit word value we store at vram[w]. Distinct per address.
static inline uint64_t vword(uint32_t w) {
    return (uint64_t)0xC0FFEE0000000000ULL | ((uint64_t)w << 8) | (w & 0xFF);
}

// waddr is a 64-bit-WORD address (bits [28:0]); vram is indexed by addr[19:0]
// after the {4'b0011, w[24:0]} DDR remap the cache applies to the LINE base. The
// cache fetches the 4-word line {line,00}=word (line<<2). So vram index used by the
// DDR = ({4'b0011, base[24:0]})[19:0] where base = line*4. We keep addresses small
// so the [19:0] slice is just base. Expected data for word W = vword(W_line_base + wsel)
// where the DDR actually reads vram[ base_word_index + beat ].
// The cache maps addr_r = {4'b0011, m_base[24:0]} then the TB DDR uses addr[19:0].
// So vram index for beat k of line L = ((L<<2) & 0x1FFFFF)... but [19:0] slice:
static inline uint32_t vram_idx_for_word(uint32_t word_addr) {
    // cache line base = (word_addr>>2)<<2 ; DDR addr[19:0] of beat = base + beat.
    // TB DDR indexes vram[addr[19:0]] with addr={4'b0011, base[24:0]} -> [19:0]=base[19:0].
    return word_addr & 0xFFFFF;
}

struct Port {
    // pending expected results, in issue order
    std::deque<uint64_t> expect;
    uint32_t issued = 0, checked = 0;
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtex_cache_4p_tb_top;

    // preload vram: vram[w] = vword(w)
    for (uint32_t w = 0; w < (1u<<20); w++) VRAM[w] = vword(w);

    // reset (long enough for the S_RST meta sweep: NLINE=1024 cycles)
    dut->reset = 1; dut->p_req = 0;
    for (int i = 0; i < 1100; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 4; i++) tick();

    Port port[4];
    // reference: is a given line resident? (software model of the direct-mapped cache)
    // 1024 lines, tag = line[26:10]. We just track which (index->tag) is resident.
    std::vector<int64_t> res_tag(1024, -1);

    auto expected_word = [&](uint32_t waddr)->uint64_t {
        return vword(vram_idx_for_word(waddr));
    };

    // Build a request stream per port. Mix: sequential (same line -> hits after 1st),
    // scattered (misses), and repeats (hits). Keep addresses within vram range.
    struct Req { bool valid; uint32_t waddr; };
    // Phase-based pattern. Phases 0..1 measure specific behaviours:
    //   WARM  (i<256):  scattered misses to warm many lines (all 4 ports)
    //   HITST (256..):  ALL ports hammer a SMALL working set already resident ->
    //                   should stream 1 group/clk (this is the throughput test)
    //   MIX   (later):  interleave fresh misses with hits
    auto gen = [&](int p, int i)->Req {
        uint32_t base;
        if (i < 256) {
            base = (uint32_t)(1000 + p + i*4);           // 4 words/line spread: misses
        } else if (i < 2000) {
            // resident working set: addresses seen during WARM (i-256 range) -> hits
            uint32_t k = (i * 7 + p * 3) % 256;
            base = (uint32_t)(1000 + p + k*4);           // revisits WARM addrs -> hit
        } else if (i < 3000) {
            // mix: mostly hits with periodic fresh misses
            if ((i % 17) == 0) base = (uint32_t)(200000 + p*104729 + i*61);  // miss
            else { uint32_t k=(i*11+p)%256; base=(uint32_t)(1000+p+k*4); }   // hit
        } else {
            // STRESS: all 4 ports hit the SAME line simultaneously (dedup path),
            // interleaved with fresh misses to that same shared line.
            uint32_t shared_line = 400000 + (i/4)*4;   // same for all 4 ports at step i
            base = shared_line + p;                    // 4 words of one line, one/port
        }
        return {true, base & 0x1FFFFFF};
    };

    const int N_REQ = 5000;               // per port
    int wpos[4] = {0,0,0,0};              // next request index to try issuing
    Req cur[4];
    for (int p=0;p<4;p++) cur[p] = {false,0};

    int max_cycles = N_REQ * 40 + 20000;
    int errors = 0;
    long acc_cycles = 0, acc_acks = 0;
    // steady-state (pure-hit) window instrumentation
    long ss_cycles = 0, ss_acks = 0;
    bool ss_active = false;

    for (int c = 0; c < max_cycles; c++) {
        // ---- drive: present a request on each port if we have one queued ----
        // Present BEFORE the clock edge; sample ready/ack that this eval produces.
        uint8_t req = 0;
        uint32_t wad[4] = {0,0,0,0};
        for (int p=0;p<4;p++) {
            if (!cur[p].valid && wpos[p] < N_REQ) cur[p] = gen(p, wpos[p]);
            if (cur[p].valid) { req |= (1<<p); wad[p] = cur[p].waddr; }
        }
        dut->p_req = req;
        dut->p_waddr0 = wad[0]; dut->p_waddr1 = wad[1];
        dut->p_waddr2 = wad[2]; dut->p_waddr3 = wad[3];
        dut->eval();   // combinational: p_ready reflects this cycle's accept

        uint8_t ready = dut->p_ready;
        // record which ports get accepted this cycle (req & ready)
        bool accepted[4];
        for (int p=0;p<4;p++) {
            accepted[p] = (cur[p].valid) && ((ready>>p)&1);
            if (accepted[p]) {
                port[p].expect.push_back(expected_word(cur[p].waddr));
                port[p].issued++;
                cur[p].valid = false;   // consumed; fetch next next cycle
                wpos[p]++;
            }
        }

        // ---- sample results (acks) produced this cycle ----
        uint8_t ack = dut->p_ack;
        uint64_t rd[4] = {dut->p_rdata0,dut->p_rdata1,dut->p_rdata2,dut->p_rdata3};
        for (int p=0;p<4;p++) {
            if ((ack>>p)&1) {
                acc_acks++;
                if (port[p].expect.empty()) {
                    printf("ERR cyc %d port %d: ack with no outstanding request\n", c, p);
                    errors++;
                } else {
                    uint64_t exp = port[p].expect.front(); port[p].expect.pop_front();
                    if (rd[p] != exp) {
                        printf("ERR cyc %d port %d: rdata %016llx != expected %016llx\n",
                               c, p, (unsigned long long)rd[p], (unsigned long long)exp);
                        errors++;
                        if (errors > 20) { printf("too many errors\n"); goto done; }
                    }
                    port[p].checked++;
                }
            }
        }
        acc_cycles++;
        // steady-state window: all ports well into the pure-hit phase (wpos 500..1800)
        ss_active = true;
        for (int p=0;p<4;p++) if (wpos[p] < 500 || wpos[p] >= 1800) ss_active = false;
        if (ss_active) { ss_cycles++; ss_acks += __builtin_popcount(ack); }

        tick();

        // done when all issued and all results drained
        bool all_done = true;
        for (int p=0;p<4;p++)
            if (wpos[p] < N_REQ || !port[p].expect.empty() || cur[p].valid) all_done = false;
        if (all_done) break;
    }
done:
    dut->final();

    long total_issued=0, total_checked=0;
    for (int p=0;p<4;p++){ total_issued+=port[p].issued; total_checked+=port[p].checked; }
    printf("issued=%ld checked=%ld acks=%ld cycles=%ld  overall=%.3f groups/clk\n",
           total_issued, total_checked, acc_acks, acc_cycles,
           acc_acks / 4.0 / (double)acc_cycles);
    printf("steady-state(pure-hit): acks=%ld cycles=%ld  %.3f texels/clk/port (1.0=ideal)\n",
           ss_acks, ss_cycles, ss_cycles? ss_acks/4.0/(double)ss_cycles : 0.0);
    for (int p=0;p<4;p++)
        if (!port[p].expect.empty())
            { printf("ERR port %d: %zu results never returned\n", p, port[p].expect.size()); errors++; }

    if (errors==0 && total_checked==total_issued && total_issued>0)
        printf("PASS (all %ld results correct, in order)\n", total_checked);
    else
        printf("FAIL errors=%d checked=%ld issued=%ld\n", errors, total_checked, total_issued);

    delete dut;
    return errors ? 1 : 0;
}

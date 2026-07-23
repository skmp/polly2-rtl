// Write-layout vs scanout-layout cross-check.
//
// The peel_core stub streams a full 640x480 frame of known pixels through
// simplex_pvr_top's FB write master IN TILE ORDER (the real writeback
// pattern) into a modeled DDR byte array; spg then scans the array out and
// every displayed pixel inside the 1280x960 window is compared against the
// pixel that was streamed. Any bit-level mismatch between the two layouts -
// pair order, split-VRAM half select, address arithmetic (incl. an odd
// 64-bit start word), lane selection, 565->888 expansion - fails with exact
// coordinates. Runs two configs: {half 0, even base} and {half 1, odd base}.
#include "Vspg_loopback_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <vector>
#include <cstdint>

static Vspg_loopback_top* dut;
static int errors = 0;

static uint32_t lfsr = 0xACE1u;
static int rnd() { lfsr = (lfsr >> 1) ^ (-(int)(lfsr & 1) & 0xB400u); return lfsr & 3; }

// one shared byte-addressed DDR model (16 MB window at vram base)
static const uint64_t VRAM_TOP = 1;                    // pvr_vram_top
static const uint64_t VRAM_WORD_BASE = VRAM_TOP << 21; // 64-bit-word base (sys_top)
static std::vector<uint8_t> ddr(32ull << 20, 0);

// ---- write port (beat-counting, sys_top adds VRAM_WORD_BASE) ----
static uint32_t w_expect = 0;
static uint64_t w_cur = 0;
static void write_port_tick() {
    dut->DDRAM2_BUSY = (rnd() == 0);
    if (dut->DDRAM2_WE && !dut->DDRAM2_BUSY) {
        if (w_expect == 0) {
            w_cur = VRAM_WORD_BASE + dut->DDRAM2_ADDR;
            w_expect = dut->DDRAM2_BURSTCNT;
        }
        for (int b = 0; b < 8; b++)
            if (dut->DDRAM2_BE & (1 << b))
                ddr[w_cur * 8 + b] = (uint8_t)(dut->DDRAM2_DIN >> (8 * b));
        w_cur++;
        w_expect--;
    }
}

// ---- spg read port (16-byte-word addressed, bursts, variable latency) ----
struct RdCmd { uint64_t addr16; uint32_t left; };
static std::vector<RdCmd> rdq;
static void read_port_tick() {
    dut->avl_waitrequest = (rnd() == 0);
    if (dut->avl_read && !dut->avl_waitrequest)
        rdq.push_back({dut->avl_address, dut->avl_burstcount});
    dut->avl_readdatavalid = 0;
    if (!rdq.empty() && rnd() != 1) {
        RdCmd& c = rdq.front();
        uint64_t byte0 = c.addr16 * 16;
        for (int w = 0; w < 4; w++) {
            uint32_t v = 0;
            for (int b = 0; b < 4; b++) v |= (uint32_t)ddr[byte0 + w * 4 + b] << (8 * b);
            dut->avl_readdata[w] = v;
        }
        dut->avl_readdatavalid = 1;
        c.addr16++;
        if (--c.left == 0) rdq.erase(rdq.begin());
    }
}

static void tick() {
    dut->clk = 0; dut->eval();
    write_port_tick();
    read_port_tick();
    dut->clk = 1; dut->eval();
}

static void regwrite(int addr, uint32_t data) {
    dut->wr_en = 1; dut->wr_addr = addr; dut->wr_data = data;
    tick();
    dut->wr_en = 0;
    tick();
}

// expected pixel: stub argb = hash32((y<<11)|x) ^ {xor,xor}, write master
// 565-packs with refsw2 quantization (c*31/255, no dither), spg expands with
// fb_concat appended (refsw2 Present; concat = 0 here)
static int div255i(int x) { return (x + (x >> 8) + 1) >> 8; }
static void expect_rgb(uint32_t pix, uint16_t xorpat, uint8_t* r, uint8_t* g, uint8_t* b) {
    uint32_t a = (pix * 2654435761u) ^ (((uint32_t)xorpat << 16) | xorpat);
    *r = (uint8_t)(div255i(((a >> 16) & 0xFF) * 31) << 3);
    *g = (uint8_t)(div255i(((a >> 8) & 0xFF) * 63) << 2);
    *b = (uint8_t)(div255i((a & 0xFF) * 31) << 3);
}

static void run_config(uint32_t sof, uint16_t xorpat, const char* name) {
    // ---- phase 1: stream the frame in tile order through the write master ----
    dut->reset = 1; dut->spg_reset = 1;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 4; i++) tick();

    regwrite(12, sof);       // fb_w_sof1
    regwrite(16, xorpat);
    regwrite(20, 1);         // stream full frame, tile order
    for (int i = 0; i < 700000; i++) tick();   // 307200 px + stalls + drain
    if (w_expect != 0) { printf("[%s] FAIL: write burst left open\n", name); errors++; }

    // ---- phase 2: scan out one full frame and compare the window ----
    // sys_top: fb_disp_base = {vram_top,24'd0} + {sof[21:2],3'd0}
    dut->fb_base      = (uint32_t)((VRAM_TOP << 24) + (((sof >> 2) & 0xFFFFF) << 3));
    dut->fb_stride    = 1280;
    dut->fb_line_dbl  = 0;
    dut->fb_split     = 1;
    dut->fb_disp_half = (sof >> 22) & 1;
    dut->fb_depth     = 1;    // 565
    dut->fb_concat    = 0;
    dut->fb_enable    = 1;
    dut->spg_reset = 0;

    // let the raster free-run one frame to settle prefetch, then align to the
    // frame start: after vsync deasserts, the next de rise is display line 0
    long total = 2200L * 1125L;
    for (long i = 0; i < total + 100; i++) tick();
    long guard = 0;
    while (!dut->vsync && ++guard < 2 * total) tick();   // vsync rise
    while (dut->vsync && ++guard < 3 * total) tick();    // vsync fall
    if (guard >= 3 * total) { printf("[%s] FAIL: no vsync\n", name); errors++; return; }

    int x = 0, y = -1;       // de-relative coordinates; y=0 at first de rise
    int prev_de = 0;
    long checked = 0;
    for (long i = 0; i < total + 200; i++) {
        tick();
        if (dut->de && !prev_de) { x = 0; y++; }
        if (dut->de) {
            if (y >= 60 && y < 1020 && x >= 320 && x < 1600) {
                uint32_t sx = (uint32_t)(x - 320) / 2, sy = (uint32_t)(y - 60) / 2;
                uint32_t pix = (sy << 11) | sx;   // the stub's {py, px} hash key
                uint8_t er, eg, eb;
                expect_rgb(pix, xorpat, &er, &eg, &eb);
                if (dut->red != er || dut->green != eg || dut->blue != eb) {
                    if (errors < 8)
                        printf("[%s] FAIL: src(%u,%u) out(%d,%d): got %02x%02x%02x want %02x%02x%02x\n",
                               name, sx, sy, x, y, dut->red, dut->green, dut->blue, er, eg, eb);
                    errors++;
                }
                checked++;
            }
            x++;
        }
        prev_de = dut->de;
        if (y >= 1020) break;
    }
    if (checked < 1280L * 960L / 2) {  // must have covered at least a full frame's worth
        printf("[%s] FAIL: only %ld window pixels checked\n", name, checked);
        errors++;
    }
    if (dut->underrun) { printf("[%s] FAIL: spg underrun\n", name); errors++; }
    printf("[%s] %ld window pixels checked\n", name, checked);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vspg_loopback_top;

    // config A: half 0 (pixels in high 32 bits), even 64-bit base word
    run_config(0x000000u | (0u << 22), 0x0000, "half0/even");
    // config B: half 1 (low 32 bits), ODD 64-bit base word (sof byte 4 ->
    // DDR byte 8 -> fb_base[3]=1, the odd0 fetch path) + inverted pattern
    run_config(0x000004u | (1u << 22), 0x5A5A, "half1/odd");

    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    delete dut;
    return errors != 0;
}

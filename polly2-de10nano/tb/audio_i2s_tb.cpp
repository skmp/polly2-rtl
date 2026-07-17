// End-to-end check of the MMIO audio path: pvr_mmio AUDIO_DATA (0x2018)
// -> 2048-entry async FIFO -> I2S serializer, on real async clocks
// (clk_sys 100 MHz, clk_audio 24.576 MHz). The Avalon side is driven the
// way hps_lw_bridge drives it (single transaction, write held until
// !waitrequest); the I2S side is decoded like the ADV7513 samples it
// (data on SCLK rising edges, standard I2S: 16 bits, one-SCLK delay,
// LRCLK low = left). Checks:
//  - idle: silence frames, level reads 0
//  - a small batch: no write stalls, samples appear once, in order,
//    correctly framed, silence after
//  - overfill (2100 pushes): waitrequest blocks writes while full, each
//    blocked write completes within ~one 48 kHz frame, non-audio MMIO
//    accesses never stall, level reads ~2048
//  - full drain: all 2100 samples come out exactly once, in order, then
//    silence - no loss or duplication through the blocking path
#include "Vaudio_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static const uint32_t AUDIO_DATA = 0x2018;
static const uint32_t VRAM_BASE  = 0x2000;

static Vaudio_tb_top* dut;
static int errors = 0;

// ---- two async clocks, scheduled in ps ----
static const uint64_t SYS_HALF = 5000;    // 100 MHz
static const uint64_t AUD_HALF = 20345;   // 24.576 MHz (40.69ns period)
static uint64_t next_sys = SYS_HALF, next_aud = AUD_HALF;

// ---- I2S decoder state ----
struct Frame { int16_t l, r; };
static std::vector<Frame> frames;
static std::vector<int> bits;
static int cur_lr = -1, prev_sclk = 0, halves_seen = 0;
static bool have_left = false;
static int16_t pending_left = 0;

static void finish_half() {
    if (cur_lr < 0) return;
    halves_seen++;
    if (bits.size() != 32) {
        if (halves_seen > 1) { printf("BAD half len %zu\n", bits.size()); errors++; }
        return;
    }
    uint16_t v = 0;                       // slots 1..16, MSB first
    for (int i = 0; i < 16; i++) v = (uint16_t)((v << 1) | bits[1 + i]);
    if (cur_lr == 0) { pending_left = (int16_t)v; have_left = true; }
    else if (have_left) { frames.push_back({pending_left, (int16_t)v}); have_left = false; }
}

static void monitor() {
    if (dut->sclk && !prev_sclk) {
        if (dut->lrclk != cur_lr) { finish_half(); cur_lr = dut->lrclk; bits.clear(); }
        bits.push_back(dut->sdata);
    }
    prev_sclk = dut->sclk;
}

// advance to the next clock toggle (either domain); returns true if this
// step was a clk_sys rising edge
static bool half_step() {
    bool sys_rise = false;
    uint64_t t = next_sys < next_aud ? next_sys : next_aud;
    if (t == next_sys) {
        dut->clk_sys ^= 1;
        sys_rise = dut->clk_sys;
        next_sys += SYS_HALF;
    }
    if (t == next_aud) {
        dut->clk_audio ^= 1;
        next_aud += AUD_HALF;
    }
    dut->eval();
    monitor();
    return sys_rise;
}

// advance to the next clk_sys rising edge; *wr_pre = waitrequest as the
// DUT saw it at that edge (it only moves on clk_sys edges - see audio_i2s
// full/level, all clk_sys-registered)
static void sys_edge(bool* wr_pre) {
    for (;;) {
        bool wr = dut->avs_waitrequest;
        if (half_step()) { if (wr_pre) *wr_pre = wr; return; }
    }
}

// Avalon write as hps_lw_bridge issues it; returns stalled edge count
static int avm_write(uint32_t addr, uint32_t data) {
    dut->avs_address = addr; dut->avs_writedata = data;
    dut->avs_byteenable = 0xF; dut->avs_write = 1;
    dut->eval();
    int stalls = 0;
    for (;;) {
        bool wr;
        sys_edge(&wr);
        if (!wr) break;
        if (++stalls > 4000) { printf("write to %x stuck\n", addr); errors++; break; }
    }
    dut->avs_write = 0; dut->eval();
    return stalls;
}

static uint32_t avm_read(uint32_t addr) {
    dut->avs_address = addr; dut->avs_read = 1; dut->avs_byteenable = 0xF;
    dut->eval();
    for (;;) {
        bool wr;
        sys_edge(&wr);
        if (!wr) break;
    }
    dut->avs_read = 0; dut->eval();
    if (!dut->avs_readdatavalid) { printf("no readdatavalid\n"); errors++; }
    return dut->avs_readdata;
}

static void run_frames(size_t want, long cap = 60000000) {
    while (frames.size() < want && cap-- > 0) half_step();
    if (frames.size() < want) { printf("timeout waiting for frames\n"); errors++; }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaudio_tb_top;
    dut->clk_sys = 0; dut->clk_audio = 0;
    dut->avs_address = 0; dut->avs_read = 0; dut->avs_write = 0;
    dut->avs_writedata = 0; dut->avs_byteenable = 0;
    dut->eval();

    // ---- idle: silence + zero level ----
    run_frames(3);
    for (auto& f : frames)
        if (f.l || f.r) { printf("idle frame not silent\n"); errors++; }
    if (avm_read(AUDIO_DATA) != 0) { printf("idle level != 0\n"); errors++; }

    // ---- small batch: framing, order, one-shot ----
    static const Frame batch[8] = {
        {0x7FFF, (int16_t)0x8000}, {0x1234, (int16_t)0xFEDC},
        {(int16_t)0xAAAA, 0x5555}, {1, -1},
        {256, -256}, {0x4001, 0x3FFE}, {-2, 2}, {0x0F0F, (int16_t)0xF0F0},
    };
    for (auto& s : batch) {
        int st = avm_write(AUDIO_DATA, ((uint32_t)(uint16_t)s.r << 16) | (uint16_t)s.l);
        // back-to-back pushes wait 1 cycle for the previous aud_wr pulse
        // to land; anything more would be real (wrong here) backpressure
        if (st > 1) { printf("batch push stalled (%d)\n", st); errors++; }
    }
    uint32_t lvl = avm_read(AUDIO_DATA);
    if (lvl < 6 || lvl > 8) { printf("batch level %u\n", lvl); errors++; }

    size_t fs = frames.size();
    run_frames(fs + 14);
    {
        size_t i = fs;
        while (i < frames.size() && !frames[i].l && !frames[i].r) i++;
        for (int k = 0; k < 8; k++, i++) {
            if (i >= frames.size() ||
                frames[i].l != batch[k].l || frames[i].r != batch[k].r) {
                printf("batch frame %d wrong (got %04x/%04x)\n", k,
                       i < frames.size() ? (uint16_t)frames[i].l : 0,
                       i < frames.size() ? (uint16_t)frames[i].r : 0);
                errors++;
            }
        }
        if (i < frames.size() && (frames[i].l || frames[i].r)) {
            printf("no silence after batch\n"); errors++;
        }
    }

    // ---- overfill: backpressure ----
    const int N = 2100;
    size_t fs2 = frames.size();
    int stalled = 0, max_stall = 0;
    for (int i = 0; i < N; i++) {
        int16_t l = (int16_t)(i + 1), r = (int16_t)~(i + 1);
        int st = avm_write(AUDIO_DATA, ((uint32_t)(uint16_t)r << 16) | (uint16_t)l);
        if (st > 10) { stalled++; if (st > max_stall) max_stall = st; }
    }
    if (stalled < 35)      { printf("too few stalled pushes (%d)\n", stalled); errors++; }
    if (max_stall > 2600)  { printf("stall too long (%d)\n", max_stall); errors++; }
    if (max_stall < 1000)  { printf("stall too short (%d)\n", max_stall); errors++; }

    // non-audio MMIO must not stall even with the FIFO full
    if (avm_write(VRAM_BASE, 0x32000000)) { printf("VRAM_BASE stalled\n"); errors++; }
    lvl = avm_read(AUDIO_DATA);
    if (lvl < 2046 || lvl > 2048) { printf("full level %u\n", lvl); errors++; }

    // ---- drain everything: exactly once, in order ----
    run_frames(fs2 + N + 8);
    {
        size_t i = fs2;
        while (i < frames.size() && !frames[i].l && !frames[i].r) i++;
        for (int k = 0; k < N; k++, i++) {
            int16_t l = (int16_t)(k + 1), r = (int16_t)~(k + 1);
            if (i >= frames.size() || frames[i].l != l || frames[i].r != r) {
                printf("drain frame %d wrong\n", k); errors++;
                break;
            }
        }
        if (i < frames.size() && (frames[i].l || frames[i].r)) {
            printf("no silence after drain\n"); errors++;
        }
    }
    if (avm_read(AUDIO_DATA) != 0) { printf("level != 0 after drain\n"); errors++; }

    printf("frames=%zu stalled_pushes=%d max_stall=%d\n",
           frames.size(), stalled, max_stall);
    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    delete dut;
    return errors != 0;
}

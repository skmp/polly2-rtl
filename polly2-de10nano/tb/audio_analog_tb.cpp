// End-to-end analogue audio check: MMIO FIFO ordering/backpressure, 48 kHz
// signed stereo sample delivery, last-sample repeat and DAC pulse density.
#include "Vaudio_analog_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static const uint32_t AUDIO_DATA = 0x2018;
static const uint32_t REVISION   = 0x201C;
static const uint32_t VRAM_BASE  = 0x2000;
static Vaudio_analog_tb_top* dut;
static int errors = 0;
static const uint64_t SYS_HALF = 5000, AUD_HALF = 20345;
static uint64_t next_sys = SYS_HALF, next_aud = AUD_HALF, aud_rises = 0;

struct Frame { int16_t l, r; };
static std::vector<Frame> frames;

static bool half_step() {
    bool sys_rise = false, aud_rise = false;
    uint64_t t = next_sys < next_aud ? next_sys : next_aud;
    if (t == next_sys) {
        dut->clk_sys ^= 1; sys_rise = dut->clk_sys; next_sys += SYS_HALF;
    }
    if (t == next_aud) {
        dut->clk_audio ^= 1; aud_rise = dut->clk_audio; next_aud += AUD_HALF;
    }
    dut->eval();
    if (aud_rise) {
        aud_rises++;
        if (dut->sample_strobe)
            frames.push_back({(int16_t)dut->left, (int16_t)dut->right});
    }
    return sys_rise;
}

static void sys_edge(bool* wait_pre) {
    for (;;) {
        bool w = dut->avs_waitrequest;
        if (half_step()) { if (wait_pre) *wait_pre = w; return; }
    }
}

static int avm_write(uint32_t addr, uint32_t data) {
    dut->avs_address = addr; dut->avs_writedata = data;
    dut->avs_byteenable = 0xf; dut->avs_write = 1; dut->eval();
    int stalls = 0;
    for (;;) {
        bool w; sys_edge(&w);
        if (!w) break;
        if (++stalls > 4000) { std::printf("write %x stuck\n", addr); errors++; break; }
    }
    dut->avs_write = 0; dut->eval();
    return stalls;
}

static uint32_t avm_read(uint32_t addr) {
    dut->avs_address = addr; dut->avs_read = 1; dut->avs_byteenable = 0xf;
    dut->eval();
    for (;;) { bool w; sys_edge(&w); if (!w) break; }
    dut->avs_read = 0; dut->eval();
    if (!dut->avs_readdatavalid) { std::printf("no readdatavalid\n"); errors++; }
    return dut->avs_readdata;
}

static void run_frames(size_t want, long cap = 100000000) {
    while (frames.size() < want && cap-- > 0) half_step();
    if (frames.size() < want) { std::printf("frame timeout\n"); errors++; }
}

static size_t find_frame(size_t at, Frame f) {
    while (at < frames.size() && (frames[at].l != f.l || frames[at].r != f.r)) at++;
    return at;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaudio_analog_tb_top;
    dut->clk_sys = dut->clk_audio = 0;
    dut->reset = 1;
    dut->avs_address = dut->avs_read = dut->avs_write = 0;
    dut->avs_writedata = dut->avs_byteenable = 0;
    dut->eval();
    uint64_t reset_target = aud_rises + 4;
    while (aud_rises < reset_target) half_step();
    dut->reset = 0;
    dut->eval();

    run_frames(3);
    for (const auto& f : frames)
        if (f.l || f.r) { std::printf("idle not signed silence\n"); errors++; }
    if (avm_read(AUDIO_DATA) != 0) { std::printf("idle level != 0\n"); errors++; }

    uint32_t rev = avm_read(REVISION);
    if (rev <= 1) { std::printf("bad revision\n"); errors++; }
    if (avm_write(REVISION, 0xdeadbeef)) { std::printf("revision stalled\n"); errors++; }
    if (avm_read(REVISION) != rev) { std::printf("revision writable\n"); errors++; }

    static const Frame batch[] = {
        {0x7fff, (int16_t)0x8000}, {0x1234, (int16_t)0xfedc},
        {(int16_t)0xaaaa, 0x5555}, {1, -1}, {256, -256},
        {0x4001, 0x3ffe}, {-2, 2}, {0x0f0f, (int16_t)0xf0f0}
    };
    size_t batch_start = frames.size();
    for (const auto& f : batch) {
        int st = avm_write(AUDIO_DATA,
            ((uint32_t)(uint16_t)f.r << 16) | (uint16_t)f.l);
        if (st > 1) { std::printf("batch stalled %d\n", st); errors++; }
    }
    run_frames(batch_start + 16);
    size_t bi = find_frame(batch_start, batch[0]);
    for (size_t k = 0; k < sizeof(batch)/sizeof(batch[0]); ++k, ++bi) {
        if (bi >= frames.size() || frames[bi].l != batch[k].l || frames[bi].r != batch[k].r) {
            std::printf("batch frame %zu wrong\n", k); errors++; break;
        }
    }
    if (frames.back().l != batch[7].l || frames.back().r != batch[7].r) {
        std::printf("last sample not repeated\n"); errors++;
    }

    const int N = 2100;
    size_t drain_start = frames.size();
    int stalled = 0, max_stall = 0;
    for (int i = 0; i < N; ++i) {
        int16_t l = (int16_t)(i + 1), r = (int16_t)~(i + 1);
        int st = avm_write(AUDIO_DATA,
            ((uint32_t)(uint16_t)r << 16) | (uint16_t)l);
        if (st > 10) { stalled++; if (st > max_stall) max_stall = st; }
    }
    if (stalled < 35 || max_stall < 1000 || max_stall > 2600) {
        std::printf("bad backpressure stalled=%d max=%d\n", stalled, max_stall); errors++;
    }
    if (avm_write(VRAM_BASE, 0x32000000)) { std::printf("non-audio stalled\n"); errors++; }
    uint32_t lvl = avm_read(AUDIO_DATA);
    if (lvl < 2046 || lvl > 2048) { std::printf("full level %u\n", lvl); errors++; }

    run_frames(drain_start + N + 100);
    Frame first = {1, (int16_t)~1};
    size_t di = find_frame(drain_start, first);
    for (int k = 0; k < N; ++k, ++di) {
        int16_t l = (int16_t)(k + 1), r = (int16_t)~(k + 1);
        if (di >= frames.size() || frames[di].l != l || frames[di].r != r) {
            std::printf("drain frame %d wrong\n", k); errors++; break;
        }
    }
    if (avm_read(AUDIO_DATA) != 0) { std::printf("level after drain != 0\n"); errors++; }

    const int16_t last_l = N, last_r = (int16_t)~N;
    const int expect_l = ((uint16_t)last_l) ^ 0x8000;
    const int expect_r = ((uint16_t)last_r) ^ 0x8000;
    int ones_l = 0, ones_r = 0;
    uint64_t target = aud_rises + 65536;
    while (aud_rises < target) {
        uint64_t before = aud_rises; half_step();
        if (aud_rises != before) { ones_l += dut->dac_l; ones_r += dut->dac_r; }
    }
    if (std::abs(ones_l - expect_l) > 1 || std::abs(ones_r - expect_r) > 1) {
        std::printf("PDM density L=%d/%d R=%d/%d\n", ones_l, expect_l, ones_r, expect_r);
        errors++;
    }

	// A core reset flushes queued state and restores signed-zero PCM.  Once
	// released, the offset-binary DAC must average to midpoint silence.
	dut->reset = 1;
	reset_target = aud_rises + 4;
	while (aud_rises < reset_target) half_step();
	if (dut->left || dut->right) {
		std::printf("reset did not restore signed silence\n"); errors++;
	}
	dut->reset = 0;
	int silence_ones_l = 0, silence_ones_r = 0;
	target = aud_rises + 65536;
	while (aud_rises < target) {
		uint64_t before = aud_rises; half_step();
		if (aud_rises != before) {
			silence_ones_l += dut->dac_l;
			silence_ones_r += dut->dac_r;
		}
	}
	if (std::abs(silence_ones_l - 32768) > 1 ||
	    std::abs(silence_ones_r - 32768) > 1) {
		std::printf("reset silence PDM density L=%d R=%d\n",
		            silence_ones_l, silence_ones_r);
		errors++;
	}

    std::printf("frames=%zu stalled=%d max=%d pdm=%d/%d %s\n",
        frames.size(), stalled, max_stall, ones_l, ones_r, errors ? "FAIL" : "PASS");
    delete dut;
    return errors != 0;
}

// FB write-master format check for simplex_pvr_top: the peel_core stub
// streams full 640x480 frames in tile order and every DDR byte written is
// compared (exact map equality: no wrong, missing, or EXTRA bytes) against a
// software model of the FB_W_CTRL packmodes:
//   0: 0555 KRGB (K = fb_kval[7])      1: 565 RGB
//   2: 4444 ARGB                       3: 1555 ARGB (A = a8 >= fb_alpha_threshold)
//   4: 888 RGB, 3 bytes/px packed      5: 0888 KRGB (K byte = fb_kval)
//   6: 8888 ARGB
// with refsw2's quantization for the 16-bit modes - (c*maxval + T)/255, T the
// 4x4 Bayer bias when fb_dither - and both target layouts:
//   FB_W_SOF1[24]=0: 32-bit "split" area (pvr_map32: FB word W -> DDR word
//                    W, byte W*8 + bank*4, bank = SOF bit 22; BE-masked)
//   FB_W_SOF1[24]=1: dense 64-bit-view render-to-texture mirror (FB byte F
//                    -> DDR byte F; whole beats)
// FB_X_CLIP/FB_Y_CLIP give an INCLUSIVE min/max window in WRITTEN-FB pixels
// (post-hscale x); pixels outside produce NO bytes at all (the extra-byte
// check makes a leaked clipped pixel a hard FAIL).
// Addressing: SOF + py*FB_W_LINESTRIDE*8 + px*bpp. SCALER_CTL.hscale
// averages horizontally-adjacent pixel pairs ((even+odd)>>1 per channel)
// into one written pixel at x>>1 - checked both as 1280->640 (supersampled)
// and 640->320 (pixel_double partner). Random waitrequest backpressure
// throughout; every burst must close (no beats left open).
#include "Vsimplex_pvr_top.h"
#include "verilated.h"
#include <cstdio>
#include <map>
#include <cstdint>

static Vsimplex_pvr_top* dut;
static int errors = 0;

static uint32_t lfsr = 0xACE1u;
static int rnd() { lfsr = (lfsr >> 1) ^ (-(int)(lfsr & 1) & 0xB400u); return lfsr & 3; }

// ---- f2sdram write-port model (beat counting, per-beat BE) ----
static std::map<uint64_t, uint8_t> mem;   // byte address -> value
static uint32_t w_expect = 0;
static uint64_t w_cur = 0;

static void write_port_tick() {
    dut->DDRAM2_BUSY = (rnd() == 0);      // ~25% waitrequest
    if (dut->DDRAM2_WE && !dut->DDRAM2_BUSY) {
        if (w_expect == 0) {
            w_cur = dut->DDRAM2_ADDR;
            w_expect = dut->DDRAM2_BURSTCNT;
            if (w_expect == 0) { printf("BAD burstcount 0\n"); errors++; w_expect = 1; }
        }
        for (int b = 0; b < 8; b++)
            if (dut->DDRAM2_BE & (1 << b))
                mem[w_cur * 8 + b] = (uint8_t)(dut->DDRAM2_DIN >> (8 * b));
        w_cur++;
        w_expect--;
    }
}

static void tick() {
    dut->clk = 0; dut->eval();
    write_port_tick();
    dut->clk = 1; dut->eval();
}

static void regwrite(int addr, uint32_t data) {
    dut->wr_en = 1; dut->wr_addr = addr; dut->wr_data = data;
    tick();
    dut->wr_en = 0;
    tick();
}

// ---- software model (mirrors the RTL / refsw2) ----
static const int bayer[4][4] = {
    {   8, 136,  40, 168 },
    { 200,  72, 232, 104 },
    {  56, 184,  24, 152 },
    { 248, 120, 216,  88 },
};
static int div255i(int x) { return (x + (x >> 8) + 1) >> 8; }
static int q5i(int c, int t) { return div255i(c * 31 + t) & 0x1F; }
static int q6i(int c, int t) { return div255i(c * 63 + t) & 0x3F; }
static int q4i(int c, int t) { return div255i(c * 15 + t) & 0x0F; }

struct Cfg {
    const char* name;
    int pm; bool dither, rtt; int half;   // half = SOF bit 22
    bool hscale; int in_w;                // rendered width (write out w/2 if hscale)
    uint32_t sof_off;                     // byte offset (SOF low bits)
    uint8_t kval, ath; uint16_t xorpat;
    // FB_X/Y_CLIP window, inclusive, in written-FB pixels (defaults wide open)
    int x_min = 0, x_max = 2047, y_min = 0, y_max = 1023;
};

static int bpp_of(int pm) { return pm == 4 ? 3 : (pm >= 5 ? 4 : 2); }

static int px_bytes(const Cfg& c, uint32_t argb, uint8_t* out) {
    int a = (argb >> 24) & 0xFF, r = (argb >> 16) & 0xFF,
        g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    switch (c.pm) {
    case 4:  out[0] = b; out[1] = g; out[2] = r; return 3;
    case 5:  out[0] = b; out[1] = g; out[2] = r; out[3] = c.kval; return 4;
    case 6:
    case 7:  out[0] = b; out[1] = g; out[2] = r; out[3] = a; return 4;
    default: break;
    }
    return 2;   // 16-bit: caller passes T
}

// stub pixel at screen (x, y): hash32({py, px}) ^ {xor, xor}
static uint32_t src_argb(const Cfg& c, int x, int y) {
    return ((((uint32_t)y << 11) | (uint32_t)x) * 2654435761u)
         ^ (((uint32_t)c.xorpat << 16) | c.xorpat);
}

static void run_config(const Cfg& c) {
    int bpp = bpp_of(c.pm);
    int out_w = c.hscale ? c.in_w / 2 : c.in_w;
    uint32_t sof = c.sof_off | ((uint32_t)c.half << 22) | (c.rtt ? (1u << 24) : 0);
    uint32_t wctrl = (uint32_t)c.pm | (c.dither ? 8u : 0) |
                     ((uint32_t)c.kval << 8) | ((uint32_t)c.ath << 16);
    uint32_t stride = (uint32_t)(out_w * bpp) / 8;

    mem.clear();
    regwrite(12, sof);
    regwrite(16, c.xorpat);
    regwrite(24, wctrl);
    regwrite(28, stride);
    regwrite(32, c.hscale ? (1u << 16) : 0);   // scaler_ctl
    regwrite(36, (uint32_t)(c.in_w / 32));     // tile-mode width
    regwrite(40, (uint32_t)c.x_min | ((uint32_t)c.x_max << 16));   // fb_x_clip
    regwrite(44, (uint32_t)c.y_min | ((uint32_t)c.y_max << 16));   // fb_y_clip
    regwrite(20, 1);                           // stream the frame, tile order
    for (int i = 0; i < c.in_w * 480 * 3 + 100000; i++) tick();
    if (w_expect != 0) { printf("[%s] FAIL: burst left open\n", c.name); errors++; }

    // expected DDR byte map
    uint64_t wbase = sof & (c.rtt ? 0x7FFFFFu : 0x3FFFFFu);
    std::map<uint64_t, uint8_t> want;
    for (int y = 0; y < 480; y++)
        for (int x = 0; x < out_w; x++) {
            if (x < c.x_min || x > c.x_max || y < c.y_min || y > c.y_max)
                continue;                  // clipped: no bytes expected
            uint32_t argb;
            if (c.hscale) {                    // (even + odd) >> 1 per channel
                uint32_t a0 = src_argb(c, 2 * x, y), a1 = src_argb(c, 2 * x + 1, y);
                argb = 0;
                for (int ch = 0; ch < 32; ch += 8)
                    argb |= ((((a0 >> ch) & 0xFF) + ((a1 >> ch) & 0xFF)) >> 1) << ch;
            } else {
                argb = src_argb(c, x, y);
            }
            uint8_t by[4]; int nb;
            if (c.pm == 4 || c.pm >= 5) {
                nb = px_bytes(c, argb, by);
            } else {
                int T = c.dither ? bayer[y & 3][x & 3] : 0;
                int a = (argb >> 24) & 0xFF, r = (argb >> 16) & 0xFF,
                    g = (argb >> 8) & 0xFF, b = argb & 0xFF;
                int p16 = 0;
                switch (c.pm) {
                case 0: p16 = ((c.kval >> 7) << 15) | (q5i(r,T) << 10) | (q5i(g,T) << 5) | q5i(b,T); break;
                case 1: p16 = (q5i(r,T) << 11) | (q6i(g,T) << 5) | q5i(b,T); break;
                case 2: p16 = (q4i(a,T) << 12) | (q4i(r,T) << 8) | (q4i(g,T) << 4) | q4i(b,T); break;
                default: p16 = ((a >= c.ath) << 15) | (q5i(r,T) << 10) | (q5i(g,T) << 5) | q5i(b,T); break;
                }
                by[0] = (uint8_t)p16; by[1] = (uint8_t)(p16 >> 8); nb = 2;
            }
            uint64_t F = wbase + (uint64_t)y * stride * 8 + (uint64_t)x * bpp;
            for (int k = 0; k < nb; k++) {
                uint64_t f = F + k;
                uint64_t d = c.rtt ? f : ((f >> 2) * 8 + (c.half ? 4 : 0) + (f & 3));
                want[d] = by[k];
            }
        }

    long wrong = 0, missing = 0, extra = 0;
    for (auto& kv : want) {
        auto it = mem.find(kv.first);
        if (it == mem.end()) {
            if (missing < 5) printf("[%s] missing byte at %llx (want %02x)\n",
                                    c.name, (unsigned long long)kv.first, kv.second);
            missing++;
        } else if (it->second != kv.second) {
            if (wrong < 5) printf("[%s] byte %llx: got %02x want %02x\n",
                                  c.name, (unsigned long long)kv.first, it->second, kv.second);
            wrong++;
        }
    }
    for (auto& kv : mem)
        if (!want.count(kv.first)) {
            if (extra < 5) printf("[%s] EXTRA byte written at %llx (=%02x)\n",
                                  c.name, (unsigned long long)kv.first, kv.second);
            extra++;
        }
    if (wrong || missing || extra) {
        printf("[%s] FAIL: %ld wrong, %ld missing, %ld extra\n", c.name, wrong, missing, extra);
        errors++;
    } else {
        printf("%-14s ok (%zu bytes)\n", c.name, mem.size());
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vsimplex_pvr_top;
    dut->reset = 1;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 4; i++) tick();

    static const Cfg cfgs[] = {
        { "565/split-lo",   1, false, false, 1, false,  640, 0x000100, 0x00, 0x00, 0x0000 },
        { "565/split-hi+d", 1, true,  false, 0, false,  640, 0x010000, 0x00, 0x00, 0x1234 },
        { "0555/split+d",   0, true,  false, 1, false,  640, 0x020000, 0x80, 0x00, 0x5A5A },
        { "4444/split",     2, false, false, 1, false,  640, 0x030000, 0x00, 0x00, 0x0F0F },
        { "1555/split",     3, false, false, 0, false,  640, 0x040000, 0x00, 0x80, 0x3C3C },
        { "8888/split",     6, false, false, 1, false,  640, 0x050000, 0x00, 0x00, 0x1111 },
        { "888/split",      4, false, false, 1, false,  640, 0x060000, 0x00, 0x00, 0x7777 },
        { "0888/rtt",       5, false, true,  0, false,  640, 0x100000, 0x5A, 0x00, 0x2222 },
        { "565/rtt+d",      1, true,  true,  0, false,  640, 0x180000, 0x00, 0x00, 0x4321 },
        { "888/rtt",        4, false, true,  0, false,  640, 0x200000, 0x00, 0x00, 0x0808 },
        { "8888/rtt",       6, false, true,  0, false,  640, 0x280000, 0x00, 0x00, 0x9999 },
        // hscale: 1280-wide render -> 640 written (supersampled AA), and the
        // 640 -> 320 pixel_double partner; dither phase follows WRITTEN x
        { "565/hx1280+d",   1, true,  false, 1, true,  1280, 0x070000, 0x00, 0x00, 0x6543 },
        { "8888/hx640/rtt", 6, false, true,  0, true,   640, 0x300000, 0x00, 0x00, 0xA5A5 },
        // FB_X/Y_CLIP: inclusive window in written-FB pixels. Edges chosen off
        // tile/word boundaries so partial words/beats/bursts at the clip edge
        // are exercised; the map-equality check fails on any leaked pixel.
        { "565/clip",       1, false, false, 1, false,  640, 0x080000, 0x00, 0x00, 0xB1B1,
          101, 538, 33, 446 },
        { "888/clip",       4, false, false, 1, false,  640, 0x090000, 0x00, 0x00, 0xC2C2,
          3, 636, 1, 478 },
        { "8888/rtt+clip",  6, false, true,  0, false,  640, 0x380000, 0x00, 0x00, 0xD3D3,
          160, 479, 120, 359 },
        // clip + hscale: the window applies to the WRITTEN (post-hscale) x
        { "565/hx1280+clip",1, false, false, 1, true,  1280, 0x0A0000, 0x00, 0x00, 0xE4E4,
          50, 589, 10, 469 },
        // degenerate: single-pixel window (min == max, both axes)
        { "565/clip1px",    1, false, false, 1, false,  640, 0x0B0000, 0x00, 0x00, 0xF5F5,
          320, 320, 240, 240 },
    };
    for (const Cfg& c : cfgs) {
        run_config(c);
        if (errors) break;
    }

    // ---- format x clip matrix: EVERY packmode (0..7, 7 = the treated-as-8888
    // quirk) over the 640x480 tile-order render, against three windows:
    //   0-649/0-479 : x max beyond the frame edge -> must clip NOTHING
    //   0-511/0-256 : mid-frame edges (y max 256 inclusive = 257 rows)
    //   0-127/0-127 : corner window smaller than the frame
    // 16-bit modes run with dither so the Bayer phase is checked against the
    // clip window too; kval/ath give modes 0/3/5 non-trivial K/A bits.
    static const struct { const char* tag; int x1, y1; } wins[] = {
        { "649x479", 649, 479 },
        { "511x256", 511, 256 },
        { "127x127", 127, 127 },
    };
    char names[8 * 3][24];
    int ni = 0;
    for (int pm = 0; pm <= 7 && !errors; pm++)
        for (int wi = 0; wi < 3 && !errors; wi++, ni++) {
            snprintf(names[ni], sizeof names[ni], "pm%d/clip%s", pm, wins[wi].tag);
            Cfg c{ names[ni], pm, /*dither*/ pm < 4, /*rtt*/ false, /*half*/ pm & 1,
                   /*hscale*/ false, 640, 0x010000u + (uint32_t)ni * 4,
                   /*kval*/ 0xA5, /*ath*/ 0x80, (uint16_t)(0x1000 + ni * 0x111) };
            c.x_min = 0; c.x_max = wins[wi].x1;
            c.y_min = 0; c.y_max = wins[wi].y1;
            run_config(c);
        }

    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    delete dut;
    return errors != 0;
}

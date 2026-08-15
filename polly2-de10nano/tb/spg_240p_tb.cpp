// 240p (line-doubled) display check for spg.sv.
//
// sys_top enters this mode either from FB_R_CTRL.fb_line_double or, now, from
// the display mode itself (!vclk_div && !SPG_CONTROL.interlace = a
// non-interlaced TV mode, which renders 240 lines) - spg sees the OR of the
// two on fb_line_dbl, so this tb drives that pin directly.
//
// What it checks, per-pixel over whole frames:
//   - the source is 640x240 shown at 4x vertically: output line y takes
//     source line (y-Y0)>>2, so each source line occupies FOUR output lines
//     and line 239 is the last one displayed (a 2x mapping would run off the
//     end of the surface at output line 540 and show source line 240+);
//   - the source-line advance still uses one stride per SOURCE line, not per
//     output line, in linear and split-VRAM layouts and at every fb_depth;
//   - pixel_double composes with it (a 320x240 source at 4x both ways);
//   - the border bands stay 2x (they are host OSD surfaces, not the game
//     window) while the window is 4x;
//   - no underrun: the fetch lookahead still lands a line before it is
//     displayed when requests are 4 output lines apart.
#include "Vspg.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <deque>

static const int V_ACT = 1080;
static const int X0 = 320, X1 = 1600, Y0 = 60, Y1 = 1020;
static const int SRC_H = 240;                       // 240p: half-height source

static const uint64_t TOP = 0x00600000, BOT = 0x00610000;  // band FBs (128B aligned)

static Vspg* dut;
static int errors = 0;

// deterministic DDR content: byte at DDR address a
static uint8_t pat(uint64_t a) {
    uint32_t v = (uint32_t)a * 2654435761u;
    return (uint8_t)(v >> 24);
}

static int      g_depth = 1, g_split = 0, g_half = 0, g_concat = 0;
static int      g_pixdbl = 0;
static uint64_t g_base_fb = 0;
static bool     g_bands = false;

static uint32_t base_input(uint64_t base_fb) {
    return (uint32_t)(g_split ? base_fb * 2 : base_fb);
}

// absolute FB-view byte -> DDR byte (split: pvr_map32 - FB word W at DDR byte
// W*8 + bank*4)
static uint64_t f2d(uint64_t A) {
    if (!g_split) return A;
    return (A >> 2) * 8 + (g_half ? 4 : 0) + (A & 3);
}
static uint8_t  fb8(uint64_t A) { return pat(f2d(A)); }
static uint16_t fb16(uint64_t A) { return (uint16_t)(fb8(A) | (fb8(A + 1) << 8)); }

static int stride_bytes() {
    int bpp = g_depth == 2 ? 3 : g_depth == 3 ? 4 : 2;
    return (g_pixdbl ? 320 : 640) * bpp;
}

// one game pixel: source line s (0..239), source pixel n
static void game_rgb(int s, int n, uint8_t* r, uint8_t* g, uint8_t* b) {
    uint64_t F = g_base_fb + (uint64_t)s * stride_bytes();
    switch (g_depth) {
    case 0: {                                        // 0555
        uint16_t p = fb16(F + 2 * n);
        *r = (uint8_t)((((p >> 10) & 0x1F) << 3) + g_concat);
        *g = (uint8_t)((((p >> 5) & 0x1F) << 3) + g_concat);
        *b = (uint8_t)(((p & 0x1F) << 3) + g_concat);
        break;
    }
    case 1: {                                        // 565
        uint16_t p = fb16(F + 2 * n);
        *r = (uint8_t)((((p >> 11) & 0x1F) << 3) + g_concat);
        *g = (uint8_t)((((p >> 5) & 0x3F) << 2) + (g_concat >> 1));
        *b = (uint8_t)(((p & 0x1F) << 3) + g_concat);
        break;
    }
    case 2: {                                        // 888 packed: B,G,R at 3n
        uint64_t f = F + 3 * n;
        *b = fb8(f); *g = fb8(f + 1); *r = fb8(f + 2);
        break;
    }
    default: {                                       // 0888
        uint64_t f = F + 4 * n;
        *b = fb8(f); *g = fb8(f + 1); *r = fb8(f + 2);
        break;
    }
    }
}

static void expect_px(int x, int y, uint8_t* r, uint8_t* g, uint8_t* b) {
    *r = *g = *b = 0;
    if (x < X0 || x >= X1) return;
    int n = (x - X0) >> 1;
    if (y < Y0 || y >= Y1) {                         // bands: linear 565, ALWAYS 2x
        if (!g_bands) return;
        bool top = y < Y0;
        uint64_t base = top ? TOP : BOT;
        int sy = (top ? y : y - Y1) >> 1;
        uint64_t a = base + (uint64_t)sy * 1280 + (uint64_t)n * 2;
        uint16_t p = (uint16_t)(pat(a) | (pat(a + 1) << 8));
        *r = (uint8_t)(((p >> 11) & 0x1F) << 3 | ((p >> 13) & 0x7));
        *g = (uint8_t)(((p >> 5) & 0x3F) << 2 | ((p >> 9) & 0x3));
        *b = (uint8_t)((p & 0x1F) << 3 | ((p >> 2) & 0x7));
        return;
    }
    // the whole point: 4 output lines per source line, 240 sources per frame
    game_rgb((y - Y0) >> 2, g_pixdbl ? (x - X0) >> 2 : n, r, g, b);
}

// ---- DDR burst server (light random backpressure, deterministic) ----
static uint32_t lfsr = 0xBEEF;
static int rnd4() { lfsr = (lfsr >> 1) ^ (-(int)(lfsr & 1) & 0xB400u); return lfsr & 3; }
static std::deque<uint64_t> owed;

static void tick() {
    dut->clk = 0; dut->avl_clk = 0; dut->eval();

    dut->avl_waitrequest = (rnd4() == 0);
    if (dut->avl_read && !dut->avl_waitrequest)
        for (uint32_t b = 0; b < dut->avl_burstcount; b++)
            owed.push_back((uint64_t)dut->avl_address + b);
    dut->avl_readdatavalid = 0;
    if (!owed.empty() && rnd4() != 1) {
        uint64_t wa = owed.front(); owed.pop_front();
        for (int i = 0; i < 4; i++) {
            uint32_t v = 0;
            for (int k = 0; k < 4; k++) v |= (uint32_t)pat(wa * 16 + 4 * i + k) << (8 * k);
            dut->avl_readdata[i] = v;
        }
        dut->avl_readdatavalid = 1;
    }

    dut->clk = 1; dut->avl_clk = 1; dut->eval();
}

// ---- frame walker: reconstruct (x, y) from the de stream ----
static long gap = 1000000;
static int  cx = 0, cy = -1, prev_de = 0;
static int  max_src = -1;

static void run_frames(int n, bool check, const char* name) {
    int seen = 0;
    long guard = 2475000L * (n + 2);
    while (seen < n && guard-- > 0) {
        tick();
        if (dut->de) {
            if (!prev_de) {
                cx = 0;
                if (gap > 10000) cy = 0; else cy++;
            }
            gap = 0;
            if (check && cy >= 0) {
                uint8_t er, eg, eb;
                expect_px(cx, cy, &er, &eg, &eb);
                if (dut->red != er || dut->green != eg || dut->blue != eb) {
                    if (errors < 10)
                        printf("[%s] (%d,%d) src %d: got %02x%02x%02x want %02x%02x%02x\n",
                               name, cx, cy, (cy - Y0) >> 2,
                               dut->red, dut->green, dut->blue, er, eg, eb);
                    errors++;
                }
                if (cy >= Y0 && cy < Y1 && (int)dut->src_line > max_src)
                    max_src = dut->src_line;
            }
            cx++;
        } else {
            gap++;
            if (prev_de && cy == V_ACT - 1) seen++;
        }
        prev_de = dut->de;
    }
    if (seen < n) { printf("[%s] timeout: %d/%d frames\n", name, seen, n); errors++; }
}

static void set_surface(int depth, int split, int half, uint64_t base_fb, int concat,
                        int pixdbl = 0) {
    g_depth = depth; g_split = split; g_half = half; g_concat = concat;
    g_pixdbl = pixdbl; g_base_fb = base_fb;
    dut->fb_base      = base_input(base_fb);
    dut->fb_stride    = stride_bytes();
    dut->fb_split     = split;
    dut->fb_disp_half = half;
    dut->fb_depth     = depth;
    dut->fb_concat    = concat;
    dut->fb_enable    = 1;
    dut->fb_pix_dbl   = pixdbl;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vspg;

    dut->reset = 1;
    dut->fb_line_dbl = 1;                  // 240p for the whole run
    dut->fb_top_base = 0; dut->fb_bot_base = 0;
    dut->avl_waitrequest = 0; dut->avl_readdatavalid = 0;
    set_surface(1, 0, 0, 0x00100000, 0);
    for (int i = 0; i < 10; i++) tick();
    dut->reset = 0;

    struct Cfg { const char* name; int depth, split, half; uint64_t base_fb; int concat, pd; };
    static const Cfg cfgs[] = {
        { "565/lin",        1, 0, 0, 0x00100000,     0, 0 },
        { "0555/split",     0, 1, 0, 0x00200000,     3, 0 },   // W0 even, half 0
        { "888/lin+off5",   2, 0, 0, 0x00120000 + 5, 0, 0 },
        { "0888/split-odd", 3, 1, 1, 0x00230000 + 4, 0, 0 },   // W0 odd, half 1
        { "pd/565-split",   1, 1, 1, 0x00500000 + 4, 0, 1 },   // 320x240, 4x both ways
    };
    for (const Cfg& c : cfgs) {
        set_surface(c.depth, c.split, c.half, c.base_fb, c.concat, c.pd);
        // the last config also turns the bands on: they must stay 2x/565
        g_bands = (&c == &cfgs[4]);
        dut->fb_top_base = g_bands ? TOP : 0;
        dut->fb_bot_base = g_bands ? BOT : 0;
        run_frames(2, false, c.name);      // warm: latches + both line buffers
        run_frames(1, true, c.name);
        printf("%-14s %s\n", c.name, errors ? "FAIL" : "ok");
        if (errors) break;
    }

    // the window must consume exactly source lines 0..239 (a 2x mapping would
    // have walked to 479 and read past the end of a 240-line surface)
    if (!errors && max_src != SRC_H - 1) {
        printf("last source line displayed = %d, want %d\n", max_src, SRC_H - 1);
        errors++;
    }

    if (dut->underrun) { printf("underrun flagged\n"); errors++; }

    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    delete dut;
    return errors != 0;
}

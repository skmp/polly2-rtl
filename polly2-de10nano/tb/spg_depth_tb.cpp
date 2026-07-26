// Depth-mode + per-line-SOF check for spg.sv, against a software model that
// mirrors refsw2.cpp::Present() byte-exactly:
//   - all four FB_R_CTRL fb_depth formats (0555 / 565 / 888 packed / 0888),
//     linear and split-VRAM layouts, with fb_concat appended below the
//     5/6-bit channels (565 green gets concat>>1) and the packed-888
//     odd/even byte-address fetch quirk;
//   - misaligned bases (fb_base[3:0] byte offsets, split odd 64-bit word);
//   - FB_R_SOF changing MID-FRAME: the render base is re-sampled per line
//     request while the render offset keeps accumulating, so lines
//     requested after the change come from the new base (base+line*stride)
//     - verified line-exactly, in linear (base+byte-offset change) and
//     split (base + half select change) modes;
//   - fb_enable=0 blanks the game window;
//   - VO_CONTROL.pixel_double: a 320-wide source displayed 4x horizontally
//     (halved stride/fetch), bands unaffected;
//   - border bands stay 565/MSB-replicate regardless of the game depth.
// Every active pixel of checked frames is compared; no underrun allowed.
#include "Vspg.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <deque>

static const int H_ACT = 1920, V_ACT = 1080;
static const int X0 = 320, X1 = 1600, Y0 = 60, Y1 = 1020;
static const int SRC_W = 640, SRC_H = 480;

static const uint64_t TOP = 0x00600000, BOT = 0x00610000;  // band FBs (128B aligned)

static Vspg* dut;
static int errors = 0;

// deterministic DDR content: byte at DDR address a
static uint8_t pat(uint64_t a) {
    uint32_t v = (uint32_t)a * 2654435761u;
    return (uint8_t)(v >> 24);
}

// ---- current game-surface config (drives both the DUT and the model) ----
static int      g_depth = 1, g_split = 0, g_half = 0, g_concat = 0, g_enable = 1;
static int      g_pixdbl = 0;
static bool     g_top_en = false, g_bot_en = false;
// per-source-line render base/half, as the RTL should have sampled them
static uint64_t g_base_fb[SRC_H];   // absolute FB-view byte address of line 0's px 0... see note
static int      g_half_ln[SRC_H];

// fb_base input value for a game surface: linear = FB byte addr, split = W0*8
static uint32_t base_input(uint64_t base_fb) {
    return (uint32_t)(g_split ? base_fb * 2 : base_fb);
}

// absolute FB-view byte -> DDR byte (split: pvr_map32 rule - FB word W at
// DDR byte W*8 + bank*4; half/bank=0 low bytes 0-3, half=1 high 4-7)
static uint64_t f2d(uint64_t A, int half) {
    if (!g_split) return A;
    return (A >> 2) * 8 + (half ? 4 : 0) + (A & 3);
}
static uint8_t  fb8(uint64_t A, int half) { return pat(f2d(A, half)); }
static uint16_t fb16(uint64_t A, int half) {
    return (uint16_t)(fb8(A, half) | (fb8(A + 1, half) << 8));
}

static int stride_bytes() {
    int bpp = g_depth == 2 ? 3 : g_depth == 3 ? 4 : 2;
    return (g_pixdbl ? 320 : 640) * bpp;
}

// refsw2 Present() for one game pixel: source line s, source pixel n
static void game_rgb(int s, int n, uint8_t* r, uint8_t* g, uint8_t* b) {
    uint64_t F = g_base_fb[s] + (uint64_t)s * stride_bytes();
    int half = g_half_ln[s];
    switch (g_depth) {
    case 0: { // 0555
        uint16_t p = fb16(F + 2 * n, half);
        *r = (uint8_t)((((p >> 10) & 0x1F) << 3) + g_concat);
        *g = (uint8_t)((((p >> 5) & 0x1F) << 3) + g_concat);
        *b = (uint8_t)(((p & 0x1F) << 3) + g_concat);
        break;
    }
    case 1: { // 565
        uint16_t p = fb16(F + 2 * n, half);
        *r = (uint8_t)((((p >> 11) & 0x1F) << 3) + g_concat);
        *g = (uint8_t)((((p >> 5) & 0x3F) << 2) + (g_concat >> 1));
        *b = (uint8_t)(((p & 0x1F) << 3) + g_concat);
        break;
    }
    case 2: { // 888 packed: STRAIGHT B,G,R at byte 3n (write-master layout;
              // refsw2 Present's odd/even fetch quirk deliberately not copied)
        uint64_t f = F + 3 * n;
        *b = fb8(f, half); *g = fb8(f + 1, half); *r = fb8(f + 2, half);
        break;
    }
    default: { // 0888
        uint64_t f = F + 4 * n;
        *b = fb8(f, half); *g = fb8(f + 1, half); *r = fb8(f + 2, half);
        break;
    }
    }
}

// expected output pixel at display (x, y); bands are linear 565 replicate
static void expect_px(int x, int y, uint8_t* r, uint8_t* g, uint8_t* b) {
    *r = *g = *b = 0;
    if (x < X0 || x >= X1) return;
    int n = (x - X0) >> 1;
    if (y < Y0 || y >= Y1) {
        bool top = y < Y0;
        if (top ? !g_top_en : !g_bot_en) return;
        uint64_t base = top ? TOP : BOT;
        int sy = (top ? y : y - Y1) >> 1;
        uint64_t a = base + (uint64_t)sy * 1280 + (uint64_t)n * 2;
        uint16_t p = (uint16_t)(pat(a) | (pat(a + 1) << 8));
        *r = (uint8_t)(((p >> 11) & 0x1F) << 3 | ((p >> 13) & 0x7));
        *g = (uint8_t)(((p >> 5) & 0x3F) << 2 | ((p >> 9) & 0x3));
        *b = (uint8_t)((p & 0x1F) << 3 | ((p >> 2) & 0x7));
        return;
    }
    if (!g_enable) return;
    game_rgb((y - Y0) >> 1, g_pixdbl ? (x - X0) >> 2 : n, r, g, b);
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

// runs until n frames complete; calls px_cb(x,y) on every active pixel when
// checking, and flip_cb(frame,x,y) once per tick (frame = frames completed
// so far within this call)
template <typename PXCB, typename FLIPCB>
static void run_frames(int n, bool check, const char* name, PXCB px_cb, FLIPCB flip_cb) {
    int seen = 0;
    long guard = 2475000L * (n + 2);
    while (seen < n && guard-- > 0) {
        tick();
        flip_cb(seen, cx, cy);
        if (dut->de) {
            if (!prev_de) {
                cx = 0;
                if (gap > 10000) cy = 0;
                else cy++;
            }
            gap = 0;
            if (check && cy >= 0) px_cb(cx, cy);
            cx++;
        } else {
            gap++;
            if (prev_de && cy == V_ACT - 1) seen++;
        }
        prev_de = dut->de;
    }
    if (seen < n) { printf("[%s] timeout: %d/%d frames\n", name, seen, n); errors++; }
}
static void run_frames(int n, bool check, const char* name) {
    run_frames(n, check, name, [&](int x, int y) {
        uint8_t er, eg, eb;
        expect_px(x, y, &er, &eg, &eb);
        if (dut->red != er || dut->green != eg || dut->blue != eb) {
            if (errors < 10)
                printf("[%s] (%d,%d): got %02x%02x%02x want %02x%02x%02x\n",
                       name, x, y, dut->red, dut->green, dut->blue, er, eg, eb);
            errors++;
        }
    }, [](int, int, int) {});
}

// program a static game surface (same base every line) into DUT + model
static void set_surface(int depth, int split, int half, uint64_t base_fb, int concat,
                        int enable, int pixdbl = 0) {
    g_depth = depth; g_split = split; g_half = half; g_concat = concat; g_enable = enable;
    g_pixdbl = pixdbl;
    for (int s = 0; s < SRC_H; s++) { g_base_fb[s] = base_fb; g_half_ln[s] = half; }
    dut->fb_base      = base_input(base_fb);
    dut->fb_stride    = stride_bytes();
    dut->fb_split     = split;
    dut->fb_disp_half = half;
    dut->fb_depth     = depth;
    dut->fb_concat    = concat;
    dut->fb_enable    = enable;
    dut->fb_pix_dbl   = pixdbl;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vspg;

    dut->reset = 1;
    dut->fb_line_dbl = 0;
    dut->fb_top_base = 0; dut->fb_bot_base = 0;
    dut->avl_waitrequest = 0; dut->avl_readdatavalid = 0;
    set_surface(1, 0, 0, 0x00100000, 0, 1);
    for (int i = 0; i < 10; i++) tick();
    dut->reset = 0;

    // ---- static configs: every depth, linear + split, aligned + misaligned ----
    struct Cfg { const char* name; int depth, split, half; uint64_t base_fb; int concat; };
    static const Cfg cfgs[] = {
        // split base_fb must be 4*W0 (32-bit word); W0 odd => fetch starts mid-beat
        { "0555/lin",        0, 0, 0, 0x00100000,      0 },
        { "0555/split",      0, 1, 0, 0x00200000,      3 },   // W0 even, half 0
        { "565/lin+off6",    1, 0, 0, 0x00110000 + 6,  5 },
        { "565/split-odd",   1, 1, 1, 0x00210000 + 4,  7 },   // W0 odd, half 1
        { "888/lin+off5",    2, 0, 0, 0x00120000 + 5,  0 },   // odd base: parity quirk
        { "888/split-odd",   2, 1, 0, 0x00220000 + 4,  0 },
        { "0888/lin+off12",  3, 0, 0, 0x00130000 + 12, 0 },
        { "0888/split-odd",  3, 1, 1, 0x00230000 + 4,  0 },
    };
    for (const Cfg& c : cfgs) {
        set_surface(c.depth, c.split, c.half, c.base_fb, c.concat, 1);
        // last config also turns the bands on: they must stay 565/replicate
        bool bands = (&c == &cfgs[7]);
        dut->fb_top_base = bands ? TOP : 0;
        dut->fb_bot_base = bands ? BOT : 0;
        run_frames(2, false, c.name);
        g_top_en = g_bot_en = bands;
        run_frames(1, true, c.name);
        printf("%-14s %s\n", c.name, errors ? "FAIL" : "ok");
        if (errors) break;
    }
    dut->fb_top_base = 0; dut->fb_bot_base = 0;

    // ---- per-line SOF change, linear: base page AND byte offset change ----
    // Flip mid-frame while output line FLIP_Y displays; the request for
    // source line s is issued at output line Y0-2+2s, so lines with
    // Y0-2+2s >= FLIP_Y+1 must come from the new base - line-exactly.
    if (!errors) {
        const int FLIP_Y = 500;
        const uint64_t A = 0x00300000, B = 0x00310000 + 6;
        set_surface(1, 0, 0, A, 0, 1);
        g_top_en = g_bot_en = false;
        run_frames(2, false, "sof/lin");
        bool flipped = false;
        run_frames(3, true, "sof/lin", [&](int x, int y) {
            uint8_t er, eg, eb;
            expect_px(x, y, &er, &eg, &eb);
            if (dut->red != er || dut->green != eg || dut->blue != eb) {
                if (errors < 10)
                    printf("[sof/lin] (%d,%d): got %02x%02x%02x want %02x%02x%02x\n",
                           x, y, dut->red, dut->green, dut->blue, er, eg, eb);
                errors++;
            }
        }, [&](int frame, int x, int y) {
            if (frame == 0 && !flipped && y == FLIP_Y && x == 1000) {
                flipped = true;
                dut->fb_base = base_input(B);
                for (int s = 0; s < SRC_H; s++)
                    if (Y0 - 2 + 2 * s >= FLIP_Y + 1) g_base_fb[s] = B;
            }
            // from the next frame on, every line comes from B
            if (frame == 1 && flipped) {
                flipped = false;
                for (int s = 0; s < SRC_H; s++) g_base_fb[s] = B;
            }
        });
        printf("%-14s %s\n", "sof/lin", errors ? "FAIL" : "ok");
    }

    // ---- per-line SOF change, split: 64-bit-word parity AND half flip ----
    if (!errors) {
        const int FLIP_Y = 300;
        const uint64_t A = 0x00400000;         // W0 even
        const uint64_t B = 0x00410000 + 4;     // W0 odd
        set_surface(1, 1, 0, A, 0, 1);
        run_frames(2, false, "sof/split");
        bool flipped = false;
        run_frames(3, true, "sof/split", [&](int x, int y) {
            uint8_t er, eg, eb;
            expect_px(x, y, &er, &eg, &eb);
            if (dut->red != er || dut->green != eg || dut->blue != eb) {
                if (errors < 10)
                    printf("[sof/split] (%d,%d): got %02x%02x%02x want %02x%02x%02x\n",
                           x, y, dut->red, dut->green, dut->blue, er, eg, eb);
                errors++;
            }
        }, [&](int frame, int x, int y) {
            if (frame == 0 && !flipped && y == FLIP_Y && x == 1000) {
                flipped = true;
                dut->fb_base = base_input(B);
                dut->fb_disp_half = 1;
                for (int s = 0; s < SRC_H; s++)
                    if (Y0 - 2 + 2 * s >= FLIP_Y + 1) { g_base_fb[s] = B; g_half_ln[s] = 1; }
            }
            if (frame == 1 && flipped) {
                flipped = false;
                for (int s = 0; s < SRC_H; s++) { g_base_fb[s] = B; g_half_ln[s] = 1; }
            }
        });
        printf("%-14s %s\n", "sof/split", errors ? "FAIL" : "ok");
    }

    // ---- VO_CONTROL.pixel_double: 320-wide source, 4x horizontal ----
    if (!errors) {
        static const Cfg pdcfgs[] = {
            { "pd/565-split", 1, 1, 1, 0x00500000 + 4, 0 },
            { "pd/888-lin",   2, 0, 0, 0x00510000 + 5, 0 },
        };
        for (const Cfg& c : pdcfgs) {
            set_surface(c.depth, c.split, c.half, c.base_fb, c.concat, 1, 1);
            run_frames(2, false, c.name);
            run_frames(1, true, c.name);
            printf("%-14s %s\n", c.name, errors ? "FAIL" : "ok");
            if (errors) break;
        }
    }

    // ---- fb_enable = 0: game window black ----
    if (!errors) {
        set_surface(1, 0, 0, 0x00100000, 0, 0);
        run_frames(2, false, "fb_enable");
        run_frames(1, true, "fb_enable");
        printf("%-14s %s\n", "fb_enable=0", errors ? "FAIL" : "ok");
    }

    if (dut->underrun) { printf("underrun flagged\n"); errors++; }

    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    delete dut;
    return errors != 0;
}

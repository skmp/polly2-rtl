// Border-band check for spg.sv: models the vbuf DDR port with pattern
// memory (16bpp pixel value = hash of its byte address), runs full frames,
// and compares EVERY active pixel against the expected composition:
//   lines          0 .. Y0-1      top band    (640x30 linear FB, SCALE-doubled)
//   lines         Y0 .. Y1-1      game window (640x480 linear FB, SCALE-doubled)
//   lines         Y1 .. V_ACT-1   bottom band (640x30 linear FB, SCALE-doubled)
// with x outside X0..X1 always black (border), plus:
//   - bands disabled from cold start show black until enabled
//   - clearing FB_BOT-equivalent input turns the bottom band black again
//     on the next latched frame while the top band stays up
//   - no underrun is flagged
//
// Geometry comes from spg.sv's parameters (spg_mode.h), not from literals, so this
// runs against whatever mode the module was built for.
//
// SKIPPED AT SCALE=1. The bands fill the margin between the game window and the
// raster edge, and a 480-line source in a 480-line raster leaves no margin: Y0 == 0,
// and spg.sv's `vcnt < Y0` comparisons fold to constant-false (it waives the
// resulting UNSIGNED warning for exactly this reason). The subject of this testbench
// is then structurally absent - so it says so and exits 0. A pass would be a lie and
// a failure would be noise; `make spg-bands-1080p` is where it still has teeth.
#include "Vspg.h"
#include "Vspg___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <deque>

#define SPG_P(n) (Vspg___024root::spg__DOT__##n)
#include "spg_mode.h"
using namespace spg_mode;

static const uint32_t GAME = 0x00100000;   // linear game FB (fb_split = 0)
static const uint32_t TOP  = 0x00200000;
static const uint32_t BOT  = 0x00210000;   // all 128-byte aligned

// deterministic DDR content: 16bpp pixel at byte address a
static uint16_t pix(uint32_t a) {
    uint32_t v = (a >> 1) * 2654435761u;
    return (uint16_t)(v >> 13);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    print_mode("spg_bands_tb");
    if (!HAS_BANDS) {
        printf("SKIP: no border bands at SCALE=%ld - the %ldx%ld source fills the "
               "%ldx%ld raster exactly (Y0 == 0), so there is no margin for them.\n",
               SCALE, SRC_W, SRC_H, H_ACTIVE, V_ACTIVE);
        return 0;
    }

    Vspg* dut = new Vspg;
    dut->mode_480p = spg_mode::MODE_480P;   // raster under test (tb/spg_mode.h)
    int errors = 0;

    const uint32_t STRIDE = (uint32_t)BAND_STRIDE;

    dut->reset = 1;
    dut->fb_base = GAME; dut->fb_stride = STRIDE;
    dut->fb_line_dbl = 0; dut->fb_split = 0; dut->fb_disp_half = 0;
    dut->fb_depth = 1; dut->fb_concat = 0; dut->fb_enable = 1;   // 565 game FB
    dut->fb_top_base = 0; dut->fb_bot_base = 0;   // bands off at cold start
    dut->avl_waitrequest = 0; dut->avl_readdatavalid = 0;

    // burst server: beats owed to the DUT, one every other avl cycle
    std::deque<uint32_t> owed;   // 16-byte word addresses
    int serve_gap = 0;

    auto tick = [&]() {
        dut->clk = 0; dut->avl_clk = 0; dut->eval();

        // avl posedge inputs: command accept + read return for this edge
        if (dut->avl_read && !dut->avl_waitrequest)
            for (uint32_t b = 0; b < dut->avl_burstcount; b++)
                owed.push_back(dut->avl_address + b);
        dut->avl_readdatavalid = 0;
        if (!owed.empty() && ++serve_gap >= 2) {
            serve_gap = 0;
            uint32_t wa = owed.front(); owed.pop_front();
            for (int i = 0; i < 4; i++)
                dut->avl_readdata[i] = (uint32_t)pix(wa * 16 + 4 * i)
                                     | ((uint32_t)pix(wa * 16 + 4 * i + 2) << 16);
            dut->avl_readdatavalid = 1;
        }

        dut->clk = 1; dut->avl_clk = 1; dut->eval();
    };

    for (int i = 0; i < 10; i++) tick();
    dut->reset = 0;

    // reconstruct (x, y) from the de stream: a de gap longer than a line is vblank
    long gap = 1000000;
    int x = 0, y = -1, prev_de = 0, frame = -1;
    bool top_en = false, bot_en = false;

    auto expected = [&](int px_, int py, uint16_t* out, bool* band) -> bool {
        // returns false for black; out = RGB565 source pixel otherwise
        if (px_ < X0 || px_ >= X1) return false;
        uint32_t sx = (uint32_t)src_x(px_);
        if (py < Y0) {
            if (!top_en) return false;
            *out = pix(TOP + (uint32_t)(py >> SHIFT) * STRIDE + sx * 2);
            *band = true;
        } else if (py < Y1) {
            *out = pix(GAME + (uint32_t)src_y(py) * STRIDE + sx * 2);
            *band = false;
        } else {
            if (!bot_en) return false;
            *out = pix(BOT + (uint32_t)((py - Y1) >> SHIFT) * STRIDE + sx * 2);
            *band = true;
        }
        return true;
    };

    // run FRAMES full frames; check pixels only when 'check' is set
    auto run_frames = [&](int n, bool check) {
        int seen = 0;
        long guard = FRAME_CLKS * (n + 2);
        while (seen < n && guard-- > 0) {
            tick();
            if (dut->de) {
                if (!prev_de) {
                    x = 0;
                    if (gap > VBLANK_GAP_MIN) { y = 0; frame++; }
                    else y++;
                }
                gap = 0;
                if (check && y >= 0) {
                    uint16_t p = 0;
                    bool band = false;
                    uint8_t er = 0, eg = 0, eb = 0;
                    if (expected(x, y, &p, &band)) {
                        if (band) {   // bands: MSB-replicated expansion
                            er = (uint8_t)(((p >> 11) & 0x1F) << 3 | ((p >> 13) & 0x7));
                            eg = (uint8_t)(((p >> 5) & 0x3F) << 2 | ((p >> 9) & 0x3));
                            eb = (uint8_t)((p & 0x1F) << 3 | ((p >> 2) & 0x7));
                        } else {      // game: refsw2 565, fb_concat (0) appended
                            er = (uint8_t)(((p >> 11) & 0x1F) << 3);
                            eg = (uint8_t)(((p >> 5) & 0x3F) << 2);
                            eb = (uint8_t)((p & 0x1F) << 3);
                        }
                    }
                    if (dut->red != er || dut->green != eg || dut->blue != eb) {
                        if (errors < 10)
                            printf("frame %d (%d,%d): got %02x%02x%02x want %02x%02x%02x\n",
                                   frame, x, y, dut->red, dut->green, dut->blue,
                                   er, eg, eb);
                        errors++;
                    }
                }
                x++;
            } else {
                gap++;
                if (prev_de && y == V_ACTIVE - 1) seen++;
            }
            prev_de = dut->de;
        }
        if (seen < n) { printf("timeout: %d/%d frames\n", seen, n); errors++; }
    };

    // ---- phase 1: bands disabled -> borders black, game correct ----
    run_frames(2, false);              // let the game pipeline settle
    run_frames(2, true);
    printf("phase1 (bands off): %s\n", errors ? "FAIL" : "ok");

    // ---- phase 2: enable both bands; latched at next vblank ----
    dut->fb_top_base = TOP; dut->fb_bot_base = BOT;
    run_frames(2, false);              // latch + first banded frame
    top_en = true; bot_en = true;
    run_frames(3, true);
    printf("phase2 (bands on):  %s\n", errors ? "FAIL" : "ok");

    // ---- phase 3: bottom band off again, top stays ----
    dut->fb_bot_base = 0;
    run_frames(2, false);
    bot_en = false;
    run_frames(2, true);
    printf("phase3 (bot off):   %s\n", errors ? "FAIL" : "ok");

    if (dut->underrun) { printf("underrun flagged\n"); errors++; }

    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    delete dut;
    return errors != 0;
}

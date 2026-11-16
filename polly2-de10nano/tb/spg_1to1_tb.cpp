// Per-pixel SAMPLING assertion for the 480p SPG target (720x480p @ 59.94, CEA VIC 2/3).
//
// WHY THIS EXISTS
// spg_480p_tb proves the RASTER is right (858x525, 31.469 kHz, 59.940 Hz). It says nothing
// about which source pixel lands where, and the two are independent: the retarget moved the
// window to a 1:1 fit while the pixel and line address generators still assume the 2x doubling
// 1080p needed. The picture would be the top-left quarter of the framebuffer, blown up 2x.
//
// spg_bands_tb cannot cover this. It hardcodes the 1080p geometry, AND its whole subject - the
// top/bottom border bands - is structurally absent at 1:1: a 480-line source exactly fills a
// 480-line raster, so Y0 == 0 and there is no margin for a band. Hence this file.
//
// HOW IT WORKS
// Rather than compare against an expected value, the DDR model makes every 32-bit framebuffer
// word ENCODE THE COORDINATE OF THE SOURCE PIXEL IT HOLDS. fb_depth=3 (0888) passes the low
// 24 bits through untouched (r8 = p32[23:16], g8 = p32[15:8], b8 = p32[7:0]), so the testbench
// can DECODE which source pixel the RTL actually sampled at each raster position:
//
//     bit    23   tag, always 1 - a real pixel is never confusable with black
//     bits 18:10  source line
//     bits  9:0   source column
//
// That turns vague "the image looks wrong" into "raster x=41 is showing source column 0".
//
// WHAT IT ASSERTS  (docs/DESIGN-640x480p.md section 5)
//   1. source column n appears at raster x = X0 + n, and exactly once, for all n in [0, SRC_W)
//   2. source line m appears at raster y = Y0 + m, and in exactly one output line,
//      for all m in [0, SRC_H)
//   3. every pixel of one output line comes from ONE source line - i.e. no line buffer was
//      written while it was being scanned out
//   4. fb_pix_dbl still gives 2x horizontally (320-wide source) and fb_line_dbl 2x vertically
//      (240-line source), and the two still compose
//   plus: outside the window is black, the RTL's own src_line output agrees with the pixels,
//   and no underrun is flagged.
//
// ASSERTION 3 IS NOT REDUNDANT, AND IS THE REASON THIS IS NOT A TIMING TEST.
// There are two line buffers selected by source-line parity (rbuf_r <= src_cur[0]), and the
// prefetch runs `vcnt + 2` OUTPUT lines ahead. At 2x that is 1 source line ahead, so the
// parity differs and the prefetch cannot touch the buffer being displayed. At 1:1 it is 2
// source lines ahead - same parity, SAME BUFFER - and the prefetch overwrites the line being
// scanned out. So the lookahead must shrink to `vcnt + 1` as part of the 1:1 change.
// Assertion 3 is what catches that. It stays quiet until vshift actually moves to 0, which
// means it is a guard against a HALF-APPLIED fix, not a check of today's behaviour.
//
// This file is written TEST-FIRST (docs/REQUIREMENTS.md P1): it is expected to FAIL against the
// current 2x address generators and to pass only once task `spg-scale` lands. The first failure
// is predicted in the design doc - raster x=40 and x=41 both return source column 0.
#include "Vspg.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <deque>
#include <vector>

// --- target mode: mirrors the spg.sv localparam block, not literals ---------------
#define H_ACTIVE 720
#define V_ACTIVE 480
#define H_FP      16
#define H_SYNC    62
#define H_BP      60
#define V_FP       9
#define V_SYNC     6
#define V_BP      30
#define SRC_W    640
#define SRC_H    480
#define SCALE      1

#define H_TOTAL (H_ACTIVE + H_FP + H_SYNC + H_BP)   // 858
#define V_TOTAL (V_ACTIVE + V_FP + V_SYNC + V_BP)   // 525
#define X0 ((H_ACTIVE - SRC_W * SCALE) / 2)         // 40
#define X1 (X0 + SRC_W * SCALE)                     // 680
#define Y0 ((V_ACTIVE - SRC_H * SCALE) / 2)         // 0
#define Y1 (Y0 + SRC_H * SCALE)                     // 480

static const uint32_t GAME = 0x00100000;   // linear game FB, 16-byte aligned (fb_split = 0)
static const uint32_t TAG  = 0x00800000;

// geometry of the source the DDR model is currently serving (varies per phase)
static uint32_t g_stride  = SRC_W * 4;
static uint32_t g_src_w   = SRC_W;
static uint32_t g_src_h   = SRC_H;

static uint32_t encode(uint32_t line, uint32_t col) {
    return TAG | ((line & 0x1FFu) << 10) | (col & 0x3FFu);
}

// the 32-bit FB word at absolute DDR byte address a; 0 (untagged) if it is not a
// source pixel of the current framebuffer
static uint32_t word32(uint32_t a) {
    if (a < GAME) return 0;
    uint32_t off  = a - GAME;
    uint32_t line = off / g_stride;
    uint32_t rem  = off % g_stride;
    if (line >= g_src_h || (rem & 3u)) return 0;
    uint32_t col = rem >> 2;
    if (col >= g_src_w) return 0;
    return encode(line, col);
}

struct Phase {
    const char* name;
    int      pix_dbl;
    int      line_dbl;
    uint32_t src_w;
    uint32_t src_h;
    int      hshift;    // raster px per source px = 1 << hshift
    int      vshift;    // raster lines per source line = 1 << vshift
    uint32_t stride;    // FB-view bytes per source line
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vspg* dut = new Vspg;
    dut->mode_480p = 1;   // this testbench's literals are the 480p raster
    int errors = 0, printed = 0, shown = 0;

#define ERR(...) do { errors++; if (printed < 24) { printf("    "); printf(__VA_ARGS__); \
                      printf("\n"); printed++; } } while (0)

    dut->reset = 1;
    dut->fb_base = GAME; dut->fb_stride = SRC_W * 4;
    dut->fb_line_dbl = 0; dut->fb_pix_dbl = 0;
    dut->fb_split = 0; dut->fb_disp_half = 0;
    dut->fb_depth = 3; dut->fb_concat = 0; dut->fb_enable = 1;   // 0888: 24 bits pass through
    dut->fb_top_base = 0; dut->fb_bot_base = 0;                  // bands are dead at 1:1 anyway
    dut->avl_waitrequest = 0; dut->avl_readdatavalid = 0;

    // burst server, as in spg_bands_tb: beats owed to the DUT, one every other avl cycle.
    // A 640px 0888 line is 160 beats = 320 clocks, inside an 858-clock output line.
    std::deque<uint32_t> owed;   // 16-byte word addresses
    int serve_gap = 0;

    auto tick = [&]() {
        dut->clk = 0; dut->avl_clk = 0; dut->eval();

        if (dut->avl_read && !dut->avl_waitrequest)
            for (uint32_t b = 0; b < dut->avl_burstcount; b++)
                owed.push_back(dut->avl_address + b);
        dut->avl_readdatavalid = 0;
        if (!owed.empty() && ++serve_gap >= 2) {
            serve_gap = 0;
            uint32_t wa = owed.front(); owed.pop_front();
            for (int i = 0; i < 4; i++)
                dut->avl_readdata[i] = word32(wa * 16 + 4 * i);
            dut->avl_readdatavalid = 1;
        }

        dut->clk = 1; dut->avl_clk = 1; dut->eval();
    };

    for (int i = 0; i < 10; i++) tick();
    dut->reset = 0;

    // reconstruct (x, y) from the de stream: hblank is 138 clks, vblank 38610
    long gap = 1000000;
    int x = 0, y = -1, prev_de = 0, frame = -1;
    const Phase* ph = 0;

    // per-output-line and per-frame accounting
    std::vector<int> col_hits(SRC_W, 0);
    std::vector<int> line_hits(SRC_H, 0);
    int  line_src = -1;        // source line this output line is showing
    bool line_mixed = false;   // ... or more than one of them
    int  line_other = -1;
    int  src_line_port = -1;   // the RTL's own src_line, sampled mid-line

    auto frame_begin = [&]() {
        for (size_t i = 0; i < line_hits.size(); i++) line_hits[i] = 0;
    };
    auto line_begin = [&]() {
        for (size_t i = 0; i < col_hits.size(); i++) col_hits[i] = 0;
        line_src = -1; line_mixed = false; line_other = -1; src_line_port = -1;
    };

    auto check_pixel = [&](int px, int py) {
        uint32_t v = ((uint32_t)dut->red << 16) | ((uint32_t)dut->green << 8) | dut->blue;
        bool in_win = (px >= X0 && px < X1) && (py >= Y0 && py < Y1);
        if (!in_win) {
            if (v != 0) ERR("(%d,%d): outside the window but not black - got %06x", px, py, v);
            return;
        }
        if (!(v & TAG)) {
            ERR("(%d,%d): no source pixel - got %06x (black, or the line was never fetched)",
                px, py, v);
            return;
        }
        uint32_t sl = (v >> 10) & 0x1FFu;
        uint32_t sc = v & 0x3FFu;

        uint32_t want_c = (uint32_t)(px - X0) >> ph->hshift;
        if (sc != want_c)
            ERR("(%d,%d): showing source column %u, want %u", px, py, sc, want_c);
        if (sc < ph->src_w) col_hits[sc]++;

        if (line_src < 0) line_src = (int)sl;
        else if ((int)sl != line_src && !line_mixed) { line_mixed = true; line_other = (int)sl; }

        // sample the RTL's own view of the displayed source line well away from the
        // line edges, where its 1-clk pipe and the 2-clk RGB pipe are both settled
        if (px == X0 + 100) src_line_port = (int)dut->src_line;
    };

    auto line_end = [&](int py) {
        if (py < Y0 || py >= Y1) return;
        int want_l = (py - Y0) >> ph->vshift;

        if (line_mixed)
            ERR("output line %d mixes source lines %d and %d - a line buffer was written "
                "while it was being scanned out", py, line_src, line_other);
        if (line_src < 0) { ERR("output line %d showed no decodable pixel", py); return; }
        if (line_src != want_l)
            ERR("output line %d is showing source line %d, want %d", py, line_src, want_l);
        if (src_line_port >= 0 && src_line_port != line_src)
            ERR("output line %d: src_line port says %d but the pixels are source line %d",
                py, src_line_port, line_src);

        int want_hits = 1 << ph->hshift;
        for (uint32_t c = 0; c < ph->src_w; c++) {
            if (col_hits[c] != want_hits) {
                ERR("output line %d: source column %u appears %d times, want %d",
                    py, c, col_hits[c], want_hits);
                break;   // one report per line is enough; the count is already wrong
            }
        }
        if (line_src >= 0 && (uint32_t)line_src < ph->src_h) line_hits[line_src]++;
    };

    auto frame_end = [&]() {
        int want_hits = 1 << ph->vshift;
        for (uint32_t m = 0; m < ph->src_h; m++) {
            if (line_hits[m] != want_hits) {
                ERR("frame %d: source line %u occupies %d output lines, want %d",
                    frame, m, line_hits[m], want_hits);
                break;
            }
        }
    };

    auto run_frames = [&](int n, bool check) {
        int seen = 0;
        long guard = (long)H_TOTAL * (long)V_TOTAL * (long)(n + 3);
        while (seen < n && guard-- > 0) {
            tick();
            if (dut->de) {
                if (!prev_de) {
                    x = 0;
                    if (gap > 1000) { y = 0; frame++; if (check) frame_begin(); }
                    else y++;
                    if (check) line_begin();
                }
                gap = 0;
                if (check && y >= 0) check_pixel(x, y);
                x++;
            } else {
                gap++;
                if (prev_de && y >= 0) {
                    if (check) line_end(y);
                    if (y == V_ACTIVE - 1) { if (check) frame_end(); seen++; }
                }
            }
            prev_de = dut->de;
        }
        if (seen < n) { printf("    timeout: %d/%d frames\n", seen, n); errors++; }
    };

    // fb_pix_dbl feeds a 320-wide source at 2x, fb_line_dbl a 240-line source at 2x, and the
    // two compose - each still exactly filling the 640x480 window. That is what keeps the
    // 1:1 retarget from being a special case bolted onto the doubling path.
    static const Phase phases[] = {
        { "1:1 (640x480 source)",  0, 0, 640, 480, 0, 0, 640 * 4 },
        { "fb_pix_dbl  (320x480)", 1, 0, 320, 480, 1, 0, 320 * 4 },
        { "fb_line_dbl (640x240)", 0, 1, 640, 240, 0, 1, 640 * 4 },
        { "both        (320x240)", 1, 1, 320, 240, 1, 1, 320 * 4 },
    };

    int prev_underrun = 0;
    for (size_t p = 0; p < sizeof(phases) / sizeof(phases[0]); p++) {
        ph = &phases[p];
        int before = errors;
        // Per-phase print budget. Wrong sampling is wrong on nearly every pixel, so a
        // single global budget is spent entirely on phase 1 and the later phases report a
        // bare "FAIL". Each phase tests a different shift combination, and telling them
        // apart is the whole point when spg-scale is only half applied.
        printed = 0;

        g_stride = ph->stride; g_src_w = ph->src_w; g_src_h = ph->src_h;
        dut->fb_pix_dbl  = ph->pix_dbl;
        dut->fb_line_dbl = ph->line_dbl;
        dut->fb_stride   = ph->stride;

        printf("--- %s ---\n", ph->name);
        run_frames(3, false);   // the per-frame config latches at vcnt==0: let it take, and
        run_frames(2, true);    // let the prefetch pipeline fill before believing anything
        printf("  %s\n", errors == before ? "ok" : "FAIL");

        if (dut->underrun && !prev_underrun) {
            ERR("underrun flagged during this phase");
            prev_underrun = 1;
        }
        shown += printed;
    }

    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    if (shown < errors) printf("(%d further errors not shown)\n", errors - shown);
    delete dut;
    return errors != 0;
}

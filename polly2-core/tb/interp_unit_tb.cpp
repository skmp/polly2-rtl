// interp_unit_tb - directed LATENCY and HANDSHAKE test for interp_unit.
//
// Written for the absolute-coordinate rework, which changed the i1 stage from a
// comb-out fp_mul_i5_pp behind a wrapper boundary register to a REGISTERED-OUTPUT
// fp_mul16_spp_ro fed by coord_f32, and made i1_v the unit's LIVE out_valid rather
// than a wrapper-registered copy. That is a change of handshake semantics, not just
// of a delay count, and nothing else tests it.
//
// The operands are chosen so the whole FP chain is EXACT, which makes this a pure
// structural test with no tolerance to hide behind:
//   plane k: ddx = 1.0, ddy = 0, c = k*1024, w = 1.0, half = 0
//   => attr[k] = coord_f32(px) * 1.0 + 0 + k*1024 = px + k*1024, exactly
// (every value is a small integer, exactly representable, and x1.0 / +0 are exact
//  in these units - see fp_mul24's header on why *1.0 is exact at full precision).
//
// Three checks:
//   A LATENCY  - one pixel in, out_valid exactly INTERPLAT cycles later, right value
//   B STREAM   - 32 back-to-back pixels, 1 per cycle, in order, no dup/drop
//   C STALL    - the same stream with stall asserted at EVERY position, for widths
//                1..3, must produce a BIT-IDENTICAL output sequence. A live valid
//                that re-fires (or is swallowed) across a stall shows up here as a
//                duplicated or missing pixel.
#include "Vinterp_unit_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

static Vinterp_unit_tb_top* dut;
static int errors = 0;

static const int INTERPLAT = 10;     // expected, per interp_unit's header
static const int NPIX      = 32;

static uint32_t f2b(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    b2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

// plane k's expected attribute for pixel px
static uint32_t expect(int px, int k) { return f2b((float)px + (float)(k * 1024)); }

static void set_planes() {
    for (int k = 0; k < 10; k++) {
        dut->ddx_f[k] = f2b(1.0f);
        dut->ddy_f[k] = f2b(0.0f);
        dut->c_f[k]   = f2b((float)(k * 1024));
    }
    dut->w    = f2b(1.0f);
    dut->half = 0;
    dut->py   = 0;
}

static void reset_dut() {
    dut->reset = 1; dut->stall = 0; dut->in_valid = 0; dut->px = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    tick();
}

// Run the NPIX stream, optionally stalling for `swidth` cycles starting `spos`
// cycles after the first issue. Returns the observed (px-recovered) output order.
static std::vector<int> run_stream(int spos, int swidth, bool check_planes) {
    reset_dut();
    set_planes();
    std::vector<int> got;
    int issued = 0, cyc = 0;
    // enough cycles for every pixel plus the pipe to drain, plus the stall
    int limit = NPIX + INTERPLAT + swidth + 40;
    while (cyc < limit) {
        bool stalling = (spos >= 0) && (cyc >= spos) && (cyc < spos + swidth);
        dut->stall    = stalling;
        // The caller contract: hold the input stable across a stall, do not advance.
        dut->in_valid = (issued < NPIX) && !stalling;
        dut->px       = (issued < NPIX) ? issued : 0;
        tick();
        // CONSUMER CONTRACT: out_valid HOLDS through a stall (the whole pipe freezes),
        // so a consumer must gate it with ~stall - tsp_shade_v2_pp does exactly that
        // (tu_issue = iv_ov & en, en = ~stall). Counting a held valid as a second
        // result is a tb bug, not a pipeline bug.
        if (dut->out_valid && !stalling) {
            int p = (int)b2f(dut->attr_f[0]);          // plane 0 == px exactly
            got.push_back(p);
            if (check_planes) {
                for (int k = 0; k < 10; k++) {
                    if (dut->attr_f[k] != expect(p, k)) {
                        if (errors < 10)
                            printf("  FAIL plane %d for px=%d: got %08x (%g) want %08x (%g)\n",
                                   k, p, dut->attr_f[k], b2f(dut->attr_f[k]),
                                   expect(p, k), b2f(expect(p, k)));
                        errors++;
                    }
                }
            }
        }
        if (!stalling && issued < NPIX) issued++;
        cyc++;
    }
    return got;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vinterp_unit_tb_top;
    dut->clk = 0;

    // ---------- A: fixed latency of a single pixel ----------
    reset_dut();
    set_planes();
    dut->px = 7; dut->in_valid = 1; dut->stall = 0;
    tick();                      // pixel consumed on this edge
    dut->in_valid = 0;
    int lat = 0;
    while (lat < 64 && !dut->out_valid) { tick(); lat++; }
    if (!dut->out_valid) {
        printf("  FAIL A: no out_valid within 64 cycles\n"); errors++;
    } else {
        if (lat + 1 != INTERPLAT) {
            printf("  FAIL A: latency %d, expected INTERPLAT=%d\n", lat + 1, INTERPLAT);
            errors++;
        }
        for (int k = 0; k < 10; k++)
            if (dut->attr_f[k] != expect(7, k)) {
                printf("  FAIL A: plane %d got %08x (%g) want %08x (%g)\n",
                       k, dut->attr_f[k], b2f(dut->attr_f[k]), expect(7,k), b2f(expect(7,k)));
                errors++;
            }
        if (!errors) printf("  ok   A latency = %d cycles, all 10 planes exact\n", lat + 1);
    }

    // ---------- B: back-to-back stream, in order, no dup/drop ----------
    std::vector<int> ref = run_stream(-1, 0, true);
    if ((int)ref.size() != NPIX) {
        printf("  FAIL B: got %zu results for %d pixels (dup/drop)\n", ref.size(), NPIX);
        errors++;
    } else {
        for (int i = 0; i < NPIX; i++)
            if (ref[i] != i) {
                printf("  FAIL B: position %d carries px=%d (out of order)\n", i, ref[i]);
                errors++;
                break;
            }
        if (!errors) printf("  ok   B %d pixels streamed 1/cycle, in order, planes exact\n", NPIX);
    }

    // ---------- C: a stall anywhere must not change the output sequence ----------
    int cfail = 0;
    for (int width = 1; width <= 3; width++) {
        for (int pos = 0; pos < NPIX + INTERPLAT; pos++) {
            std::vector<int> got = run_stream(pos, width, false);
            if (got != ref) {
                if (cfail < 6)
                    printf("  FAIL C: stall width %d at cycle %d changed the stream "
                           "(%zu results vs %zu)\n", width, pos, got.size(), ref.size());
                cfail++;
            }
        }
    }
    if (cfail) { printf("  FAIL C: %d stall positions corrupted the stream\n", cfail); errors += cfail; }
    else       printf("  ok   C stall (widths 1-3, every position) leaves the stream identical\n");

    dut->final();
    if (errors) { printf("\n=== interp_unit: %d FAILURES ===\n", errors); return 1; }
    printf("\n=== interp_unit: PASS ===\n");
    return 0;
}

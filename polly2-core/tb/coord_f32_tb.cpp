// coord_f32_tb - exhaustive check of the coordinate -> fp32 lookup.
//
//   * all 4096 (coord, half) pairs vs the host float (coord + 0.5*half)
//   * LOGIC style == ROM style, bit for bit
//   * the structural claims the RTL relies on: sign always 0, mantissa[11:0] always 0
//   * en=0 holds the output (stall behaviour)
#include "Vcoord_f32_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>

static Vcoord_f32_tb_top* dut;
static int fails = 0;

static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

static uint32_t f2b(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

static void check(int coord, int half) {
    dut->coord = coord; dut->half = half; dut->en = 1;
    tick();
    uint32_t want = f2b((float)coord + (half ? 0.5f : 0.0f));
    if (dut->f_logic != want && fails < 20) {
        printf("  FAIL logic: coord=%d half=%d got=%08x want=%08x\n",
               coord, half, dut->f_logic, want);
        fails++;
    } else if (dut->f_logic != want) fails++;

    if (dut->f_rom != dut->f_logic) {
        if (fails < 20)
            printf("  FAIL style mismatch: coord=%d half=%d rom=%08x logic=%08x\n",
                   coord, half, dut->f_rom, dut->f_logic);
        fails++;
    }
    // structural invariants the packing depends on
    if (dut->f_logic & 0x80000000u) { printf("  FAIL sign set: coord=%d half=%d\n", coord, half); fails++; }
    if (dut->f_logic & 0x00000FFFu) { printf("  FAIL mant[11:0] nonzero: coord=%d half=%d f=%08x\n", coord, half, dut->f_logic); fails++; }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vcoord_f32_tb_top;
    dut->clk = 0; dut->en = 1; dut->coord = 0; dut->half = 0;
    tick();

    // ---- exhaustive: every coordinate, both pixel-centre settings ----
    for (int c = 0; c <= 2047; c++)
        for (int h = 0; h <= 1; h++)
            check(c, h);

    // ---- the specific values the raster/interp rework depends on ----
    struct { int c, h; float v; } spot[] = {
        {0,0,0.0f}, {0,1,0.5f}, {1,0,1.0f}, {1,1,1.5f},
        {31,1,31.5f}, {32,0,32.0f},           // tile-local -> absolute boundary
        {639,1,639.5f}, {1023,1,1023.5f},     // 640-wide and 1024-wide screens
        {2047,0,2047.0f}, {2047,1,2047.5f},   // top of the range
    };
    for (auto& s : spot) {
        dut->coord = s.c; dut->half = s.h; dut->en = 1; tick();
        if (dut->f_logic != f2b(s.v)) {
            printf("  FAIL spot: %d(+%s) got=%08x want=%08x (%f)\n",
                   s.c, s.h ? ".5" : ".0", dut->f_logic, f2b(s.v), s.v);
            fails++;
        }
    }

    // ---- en=0 must HOLD (the callers gate whole pipelines off one clock-enable) ----
    dut->coord = 100; dut->half = 0; dut->en = 1; tick();
    uint32_t held_l = dut->f_logic, held_r = dut->f_rom;
    dut->coord = 7;   dut->half = 1; dut->en = 0; tick(); tick();
    if (dut->f_logic != held_l || dut->f_rom != held_r) {
        printf("  FAIL en=0 did not hold: logic %08x->%08x rom %08x->%08x\n",
               held_l, dut->f_logic, held_r, dut->f_rom);
        fails++;
    }
    dut->en = 1; tick();
    if (dut->f_logic != f2b(7.5f)) {
        printf("  FAIL resume after stall: got=%08x want=%08x\n", dut->f_logic, f2b(7.5f));
        fails++;
    }

    dut->final();
    if (fails) { printf("\n=== coord_f32: %d FAILURES ===\n", fails); return 1; }
    printf("  ok   4096 entries exact vs host float (both styles, bit-identical)\n");
    printf("  ok   sign always 0, mantissa[11:0] always 0 (19-bit packing valid)\n");
    printf("  ok   en=0 holds, resumes correctly\n");
    printf("\n=== coord_f32: PASS ===\n");
    return 0;
}

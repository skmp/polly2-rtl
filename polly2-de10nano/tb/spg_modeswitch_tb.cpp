// Runtime raster switch for spg.sv: one model, mode_480p flipped under reset.
//
// The other spg testbenches each run ONE mode for their whole life (chosen at
// compile time - see spg_mode.h). The hardware does not: sys_top flips
// mode_480p while holding spg in reset, then releases it into the other raster.
// This walks 1080p -> 480p -> 1080p -> 480p in a single simulation and, after
// each release, measures the raster from the outputs alone:
//  - HS period (clocks between HS rising edges)    == H_TOTAL of the new mode
//  - HS pulse width                                == H_SYNC
//  - VS period (clocks between VS rising edges)    == H_TOTAL * V_TOTAL
//  - DE run length per line                        == H_ACTIVE
//  - DE lines per frame                            == V_ACTIVE
// Nothing may leak from the previous mode: the first full frame after release
// must already be the new geometry.
//
// Both parameter sets are read straight from the RTL (--public-params), so this
// restates no timing literal.
#include "Vspg.h"
#include "Vspg___024root.h"
#include "verilated.h"
#include <cstdio>
#include <vector>

#define P(n) ((long)Vspg___024root::spg__DOT__##n)

struct Mode {
    const char* name; int sel;
    long h_act, h_sync, h_tot, v_act, v_tot;
};

static Vspg* dut;
static int errors = 0;

static void tick() {
    dut->clk = 0; dut->avl_clk = 0; dut->eval();
    dut->clk = 1; dut->avl_clk = 1; dut->eval();
}

static void run_mode(const Mode& m) {
    // switch exactly as sys_top does: reset held across the select change
    dut->reset = 1;
    for (int i = 0; i < 8; i++) tick();
    dut->mode_480p = m.sel;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;

    const long frame = m.h_tot * m.v_tot;
    std::vector<long> hs_rise, hs_fall, vs_rise;
    std::vector<long> de_runs;          // per line, after the first VS edge
    std::vector<long> lines_per_frame;
    int prev_hs = 0, prev_vs = 0, prev_de = 0;
    long run = 0, lines = 0;
    for (long t = 0; t < frame * 3 + 100; t++) {
        tick();
        if (dut->hsync && !prev_hs) hs_rise.push_back(t);
        if (!dut->hsync && prev_hs) hs_fall.push_back(t);
        if (dut->vsync && !prev_vs) {
            if (!vs_rise.empty()) lines_per_frame.push_back(lines);
            vs_rise.push_back(t);
            lines = 0;
        }
        if (dut->de) run++;
        if (!dut->de && prev_de) {
            if (!vs_rise.empty()) { de_runs.push_back(run); lines++; }
            run = 0;
        }
        prev_hs = dut->hsync; prev_vs = dut->vsync; prev_de = dut->de;
    }

    int before = errors;
    auto bad = [&](const char* what, long got, long want) {
        if (errors - before < 6)
            printf("  [%s] BAD %s: %ld (want %ld)\n", m.name, what, got, want);
        errors++;
    };
    // skip the first two HS edges: the output pipe is mid-flight at release
    for (size_t i = 2; i < hs_rise.size(); i++)
        if (hs_rise[i] - hs_rise[i-1] != m.h_tot) bad("HS period", hs_rise[i] - hs_rise[i-1], m.h_tot);
    for (size_t i = 2; i < hs_rise.size() && i < hs_fall.size(); i++) {
        long w = hs_fall[i] - hs_rise[i];
        if (w > 0 && w != m.h_sync) bad("HS width", w, m.h_sync);
    }
    for (size_t i = 1; i < vs_rise.size(); i++)
        if (vs_rise[i] - vs_rise[i-1] != frame) bad("VS period", vs_rise[i] - vs_rise[i-1], frame);
    for (long r : de_runs) if (r != m.h_act) bad("DE run", r, m.h_act);
    for (long l : lines_per_frame) if (l != m.v_act) bad("DE lines/frame", l, m.v_act);
    if (vs_rise.size() < 3) bad("VS edges seen", (long)vs_rise.size(), 3);

    printf("%-6s mode_480p=%d  HS period %ld, %zu frames, %zu DE lines checked  %s\n",
           m.name, m.sel, m.h_tot, vs_rise.size(), de_runs.size(),
           errors == before ? "ok" : "FAIL");
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vspg;

    const Mode hd = { "1080p", 0, P(H_ACTIVE_HD), P(H_SYNC_HD), P(H_TOTAL_HD),
                                  P(V_ACTIVE_HD), P(V_TOTAL_HD) };
    const Mode sd = { "480p",  1, P(H_ACTIVE_SD), P(H_SYNC_SD), P(H_TOTAL_SD),
                                  P(V_ACTIVE_SD), P(V_TOTAL_SD) };

    dut->fb_base = 0; dut->fb_stride = 640 * 2;
    dut->fb_line_dbl = 0; dut->fb_split = 1; dut->fb_disp_half = 0;
    dut->avl_waitrequest = 1; dut->avl_readdatavalid = 0;
    dut->mode_480p = 0;                  // the hardware's reset default

    const Mode seq[] = { hd, sd, hd, sd };
    for (const Mode& m : seq) run_mode(m);

    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    delete dut;
    return errors != 0;
}

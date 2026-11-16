// Timing assertion for the 480p SPG target (CEA-861 VIC 2/3, 720x480p @ 59.94).
//
// WHY THIS EXISTS
// The MiSTercade V2 cabinet drives a 31 kHz-capable arcade CRT through an HDMI-fed DAC.
// polly2's stock SPG emits 1080p59.94 (~67.4 kHz horizontal), which that monitor cannot lock.
// 480p is the Dreamcast's own VGA mode and maps 1:1 onto SRC_W=640 / SRC_H=480, so it needs
// no scaling at all — unlike the 2x doubling the stock raster performs.
//
// This file is written TEST-FIRST: it is expected to FAIL against unmodified spg.sv (which is
// 1080p) and to pass only once the parameters are retargeted. An assertion that has never been
// observed failing has proved nothing.
//
// TARGET TIMING (CEA-861 VIC 2/3)
//   pixel clock 27.000 MHz (26.973 MHz for exact 59.94)
//   H: 720 active + 16 front + 62 sync + 60 back = 858 total  -> 27e6/858   = 31.47 kHz
//   V: 480 active +  9 front +  6 sync + 30 back = 525 total  -> 31468/525  = 59.94 Hz
//   game window: 640 wide in a 720 raster -> X0 = 40, no pillarbox vertically, NO doubling
#include "Vspg.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

// --- target mode ---------------------------------------------------------------
#define H_ACTIVE 720
#define H_FP      16
#define H_SYNC    62
#define H_BP      60
#define V_ACTIVE 480
#define V_FP       9
#define V_SYNC     6
#define V_BP      30

#define H_TOTAL (H_ACTIVE + H_FP + H_SYNC + H_BP)   // 858
#define V_TOTAL (V_ACTIVE + V_FP + V_SYNC + V_BP)   // 525
#define PIXEL_CLOCK_HZ 27000000.0

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vspg* dut = new Vspg;
    dut->mode_480p = 1;   // this testbench's literals are the 480p raster

    dut->reset = 1;
    dut->fb_base = 0; dut->fb_stride = 1280;
    dut->fb_line_dbl = 0; dut->fb_split = 1; dut->fb_disp_half = 0;
    dut->avl_waitrequest = 1; dut->avl_readdatavalid = 0;

    auto tick = [&](){
        dut->clk = 0; dut->avl_clk = 0; dut->eval();
        dut->clk = 1; dut->avl_clk = 1; dut->eval();
    };
    for (int i = 0; i < 10; i++) tick();
    dut->reset = 0;

    const long TOTAL = (long)H_TOTAL * (long)V_TOTAL;   // 450450
    long t = 0;
    int prev_hs = 0, prev_vs = 0, prev_de = 0;
    std::vector<long> hs_rise, hs_fall, vs_rise, vs_fall;
    std::vector<long> de_runs;
    long de_pixels = 0, de_lines = 0, run = 0;
    int errors = 0;

    for (long n = 0; n < TOTAL * 3 + 100; n++, t++) {
        tick();
        if (dut->hsync && !prev_hs) hs_rise.push_back(t);
        if (!dut->hsync && prev_hs) hs_fall.push_back(t);
        if (dut->vsync && !prev_vs) vs_rise.push_back(t);
        if (!dut->vsync && prev_vs) vs_fall.push_back(t);
        if (dut->de) { de_pixels++; run++; }
        if (!dut->de && prev_de) {
            // Ignore lines before the first VS edge: the output pipe is mid-flight when reset
            // deasserts, so line 0 carries a stale pixel. Same caveat as spg_sync_tb.
            if (!vs_rise.empty()) { de_runs.push_back(run); de_lines++; }
            run = 0;
        }
        prev_hs = dut->hsync; prev_vs = dut->vsync; prev_de = dut->de;
    }

    // --- measure -----------------------------------------------------------------
    long h_period = (hs_rise.size() > 3) ? hs_rise[3] - hs_rise[2] : -1;
    long h_pulse  = -1;
    for (size_t i = 1; i < hs_fall.size() && i < hs_rise.size(); i++) {
        if (hs_fall[i] > hs_rise[i]) { h_pulse = hs_fall[i] - hs_rise[i]; break; }
    }
    long v_period = (vs_rise.size() > 2) ? vs_rise[2] - vs_rise[1] : -1;
    long v_pulse  = -1;
    for (size_t i = 1; i < vs_fall.size() && i < vs_rise.size(); i++) {
        if (vs_fall[i] > vs_rise[i]) { v_pulse = vs_fall[i] - vs_rise[i]; break; }
    }
    long de_run = de_runs.empty() ? -1 : de_runs[de_runs.size() / 2];   // median-ish sample
    long lines_per_frame = (vs_rise.size() > 2) ? de_lines / (long)(vs_rise.size() - 1) : -1;

    printf("--- measured ---\n");
    printf("  H period        %6ld   (want %d)\n",  h_period, H_TOTAL);
    printf("  H sync width    %6ld   (want %d)\n",  h_pulse,  H_SYNC);
    printf("  V period        %6ld   (want %ld)\n", v_period, TOTAL);
    printf("  V sync width    %6ld   (want %d)\n",  v_pulse,  V_SYNC * H_TOTAL);
    printf("  DE run/line     %6ld   (want %d)\n",  de_run,   H_ACTIVE);
    printf("  DE lines/frame  %6ld   (want %d)\n",  lines_per_frame, V_ACTIVE);
    if (h_period > 0) {
        double hz = PIXEL_CLOCK_HZ / (double)h_period;
        printf("  => H rate       %8.3f kHz  (want %.3f)\n", hz / 1000.0,
               PIXEL_CLOCK_HZ / (double)H_TOTAL / 1000.0);
        if (v_period > 0)
            printf("  => V rate       %8.3f Hz   (want %.3f)\n",
                   PIXEL_CLOCK_HZ / (double)v_period,
                   PIXEL_CLOCK_HZ / (double)TOTAL);
    }

    // --- assert ------------------------------------------------------------------
    printf("--- assertions ---\n");
    auto check = [&](const char* what, long got, long want) {
        if (got != want) { printf("  FAIL %-16s got %ld want %ld\n", what, got, want); errors++; }
        else             { printf("  ok   %-16s %ld\n", what, got); }
    };
    check("H period",       h_period,        H_TOTAL);
    check("H sync width",   h_pulse,         H_SYNC);
    check("V period",       v_period,        TOTAL);
    check("V sync width",   v_pulse,         (long)V_SYNC * H_TOTAL);
    check("DE run/line",    de_run,          H_ACTIVE);
    check("DE lines/frame", lines_per_frame, V_ACTIVE);

    // VS edges must coincide with an HS rising edge (CEA-861), as in spg_sync_tb.
    auto on_hs = [&](long tv){
        for (long h : hs_rise) if (h == tv) return true;
        return false;
    };
    int align_err = 0;
    for (size_t i = 1; i < vs_rise.size(); i++) if (!on_hs(vs_rise[i])) align_err++;
    for (size_t i = 1; i < vs_fall.size(); i++) if (!on_hs(vs_fall[i])) align_err++;
    if (align_err) { printf("  FAIL VS/HS alignment: %d edges off\n", align_err); errors += align_err; }
    else           { printf("  ok   VS/HS alignment\n"); }

    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    delete dut;
    return errors != 0;
}

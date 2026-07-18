// irq_stretch (render-done -> f2h IRQ1 pulse) checks:
//  - idle: irq stays low
//  - a 1-clk done pulse: irq rises on the edge that samples it and stays
//    high for exactly CYCLES (64) clocks, then drops
//  - level input: a long-held done gives exactly one 64-clk pulse (edge
//    detect - no retrigger while held), nothing on release
//  - retrigger mid-stretch: a second edge during the pulse reloads the
//    counter - the line never drops (one coalesced GIC edge) and drains
//    exactly 64 clocks after the second edge
//  - a second edge after the line has drained gives a second clean pulse
//  - rst mid-stretch kills the pulse immediately; edges while rst is held
//    are swallowed; done held high across the rst release doesn't fire
//    (the edge detector tracks through reset); normal operation resumes
//    after release
#include "Virq_stretch.h"
#include "verilated.h"
#include <cstdio>

static const int CYCLES = 64;   // must match the instantiation default

static Virq_stretch* dut;
static int errors = 0;

static void tick() {
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
}

// drive a 1-clk pulse on `in`; after this the loading edge has been clocked
static void pulse() {
    dut->in = 1; tick();
    dut->in = 0;
}

// count how long irq stays high from here (ticks until it drops)
static int drain(int limit = 10 * CYCLES) {
    int high = 0;
    while (dut->irq && high < limit) { tick(); high++; }
    return high;
}

static void expect(const char* what, int got, int want) {
    if (got != want) { printf("%s: %d, expected %d\n", what, got, want); errors++; }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Virq_stretch;
    dut->clk = 0; dut->rst = 0; dut->in = 0; dut->eval();

    // ---- idle: no spurious irq ----
    for (int i = 0; i < 200; i++) {
        tick();
        if (dut->irq) { printf("irq high while idle (t=%d)\n", i); errors++; break; }
    }

    // ---- single 1-clk pulse: exactly CYCLES high ----
    pulse();
    if (!dut->irq) { printf("irq low right after done edge\n"); errors++; }
    expect("single-pulse high time", drain(), CYCLES);
    for (int i = 0; i < 100; i++) { tick(); if (dut->irq) { printf("irq re-rose after drain\n"); errors++; break; } }

    // ---- level input: one pulse only, nothing on release ----
    dut->in = 1; tick();
    int high = drain(20 * CYCLES);
    expect("level-input high time", high, CYCLES);
    for (int i = 0; i < 200; i++) {
        tick();
        if (dut->irq) { printf("irq re-rose while done held (t=%d)\n", i); errors++; break; }
    }
    dut->in = 0;
    for (int i = 0; i < 200; i++) {
        tick();
        if (dut->irq) { printf("irq rose on done release (t=%d)\n", i); errors++; break; }
    }

    // ---- retrigger mid-stretch: no drop, drains CYCLES after 2nd edge ----
    pulse();
    for (int i = 0; i < 20; i++) {
        tick();
        if (!dut->irq) { printf("irq dropped before retrigger (t=%d)\n", i); errors++; }
    }
    pulse();                       // reload at CYCLES-21 remaining
    expect("retriggered high time", drain(), CYCLES);

    // ---- a fresh edge after draining: a second full pulse ----
    for (int i = 0; i < 100; i++) tick();
    pulse();
    expect("second-pulse high time", drain(), CYCLES);

    // ---- rst mid-stretch: pulse dies on the next edge ----
    pulse();
    for (int i = 0; i < 10; i++) tick();
    if (!dut->irq) { printf("irq low before rst test\n"); errors++; }
    dut->rst = 1; tick();
    if (dut->irq) { printf("irq survived rst\n"); errors++; }

    // ---- edges while rst is held are swallowed ----
    for (int i = 0; i < 3; i++) { dut->in = 1; tick(); dut->in = 0; tick(); }
    dut->rst = 0;
    for (int i = 0; i < 200; i++) {
        tick();
        if (dut->irq) { printf("swallowed edge fired after rst (t=%d)\n", i); errors++; break; }
    }

    // ---- done held high across the rst release: no spurious pulse ----
    dut->in = 1; tick();               // edge lands...
    dut->rst = 1; tick();              // ...but a reset window opens
    for (int i = 0; i < 10; i++) tick();
    dut->rst = 0;                      // release with done still high
    for (int i = 0; i < 200; i++) {
        tick();
        if (dut->irq) { printf("irq fired on rst release with done high (t=%d)\n", i); errors++; break; }
    }
    dut->in = 0;
    for (int i = 0; i < 10; i++) tick();

    // ---- normal operation after all that ----
    pulse();
    expect("post-rst high time", drain(), CYCLES);

    if (errors) printf("FAIL (%d errors)\n", errors);
    else        printf("PASS\n");
    delete dut;
    return errors != 0;
}

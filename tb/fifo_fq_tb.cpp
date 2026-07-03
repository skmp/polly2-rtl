// fifo_fq testbench: randomized push/pop vs a reference queue model.
//
// Contract under test (FIRST-WORD-FALL-THROUGH):
//   - head_data/head_valid present the FRONT entry COMBINATIONALLY this cycle.
//   - pop (when head_valid) consumes the presented head; the next head falls
//     through and is presented next cycle (registered prefetch fills the gap, so
//     back-to-back pops must see zero bubble).
//   - push when !full appends at the tail; a push into the slot being (re)loaded
//     is bypassed so it appears on head_data next cycle (push-into-empty works).
//   - count/full/empty reflect occupancy.
//
// KEY difference from fifo_pq: the read is combinational (head visible NOW), so
// the model checks head_data/head_valid against model.front()/!empty EACH cycle,
// with no 1-cycle read latency.

#include "Vfifo_fq.h"
#include "verilated.h"
#include <deque>
#include <cstdio>
#include <cstdlib>

static const int DEPTH = 8;

static Vfifo_fq* dut;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static void tick() {
    dut->clk = 0; dut->eval();
    main_time++;
    dut->clk = 1; dut->eval();
    main_time++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vfifo_fq;

    std::deque<uint32_t> model;
    long errors = 0, checks = 0;

    dut->reset = 1; dut->push = 0; dut->pop = 0; dut->wdata = 0;
    tick(); tick();
    dut->reset = 0;
    // let the (empty) prefetch settle
    dut->eval();

    srand(0xFCFC);
    const long N = 200000;
    uint32_t next_data = 1;

    for (long i = 0; i < N; i++) {
        // Drive stimulus, THEN (before the edge) check the combinational head that
        // reflects the CURRENT model state. head_valid must equal !empty and, if
        // valid, head_data must equal model.front().
        bool cur_empty = model.empty();
        bool cur_full  = ((int)model.size() == DEPTH);

        // check combinational head BEFORE issuing the edge (reflects current state)
        dut->push = 0; dut->pop = 0;          // neutral inputs for the pure-head check
        dut->eval();
        checks++;
        if (dut->head_valid != (cur_empty ? 0 : 1)) {
            if (errors < 20) printf("[%ld] head_valid mismatch: dut=%d exp=%d (cnt=%zu)\n",
                                    i, dut->head_valid, !cur_empty, model.size());
            errors++;
        }
        if (!cur_empty && dut->head_data != model.front()) {
            if (errors < 20) printf("[%ld] head_data mismatch: dut=%08x exp=%08x\n",
                                    i, dut->head_data, model.front());
            errors++;
        }
        if (dut->count != model.size()) {
            if (errors < 20) printf("[%ld] count mismatch: dut=%d exp=%zu\n", i, dut->count, model.size());
            errors++;
        }
        if (dut->empty != (cur_empty ? 1 : 0)) { if (errors<20) printf("[%ld] empty mismatch\n", i); errors++; }
        if (dut->full  != (cur_full  ? 1 : 0)) { if (errors<20) printf("[%ld] full mismatch\n", i);  errors++; }

        // now choose real stimulus
        bool want_push = (rand() & 1);
        bool want_pop  = (rand() & 1);
        if ((rand() % 5) == 0) want_push = true;
        if ((rand() % 5) == 0) want_pop  = true;

        uint32_t wd = next_data;
        dut->push  = want_push;
        dut->pop   = want_pop;
        dut->wdata = wd;
        dut->eval();   // settle combinational do_push/do_pop with real inputs

        bool do_push = want_push && !cur_full;
        bool do_pop  = want_pop  && !cur_empty;   // pop gated by head_valid==!empty

        tick();

        if (do_pop)  model.pop_front();
        if (do_push) { model.push_back(wd); next_data++; }
    }

    dut->final();
    printf("fifo_fq: %ld checks, %ld errors\n", checks, errors);
    delete dut;
    return errors ? 1 : 0;
}

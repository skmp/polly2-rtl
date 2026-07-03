// fifo_pq testbench: randomized push/pop vs a reference queue model.
//
// Contract (registered 1-cycle read):
//   - push when !full stores wdata at the tail.
//   - pop when !empty: rdata/rvalid appear the NEXT cycle (registered read).
//   - count/full/empty are combinational and reflect occupancy AFTER the edge.
//
// Timing model. We use one helper `step(push,pop,wdata)` that:
//   1. sets inputs,
//   2. samples the COMBINATIONAL status (full/empty/count) that reflects current
//      occupancy (they are assign-from-cnt, stable with inputs set),
//   3. clocks the posedge,
//   4. returns; the caller then checks the REGISTERED outputs (rvalid/rdata),
//      which now reflect the pop that was issued in THIS step.
// The registered read latency is captured by comparing rvalid/rdata to the pop
// decision of the step just clocked.

#include "Vfifo_pq.h"
#include "verilated.h"
#include <deque>
#include <cstdio>
#include <cstdlib>

static const int DEPTH = 8;
static Vfifo_pq* dut;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static void posedge() {
    dut->clk = 0; dut->eval(); main_time++;
    dut->clk = 1; dut->eval(); main_time++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vfifo_pq;
    std::deque<uint32_t> model;
    long errors = 0, checks = 0;

    dut->reset = 1; dut->push = 0; dut->pop = 0; dut->wdata = 0;
    posedge(); posedge();
    dut->reset = 0;
    dut->push = 0; dut->pop = 0; dut->eval();

    srand(0xF1F0);
    const long N = 200000;
    uint32_t next_data = 1;

    for (long i = 0; i < N; i++) {
        bool want_push = (rand() & 1);
        bool want_pop  = (rand() & 1);
        if ((rand() % 5) == 0) want_push = true;
        if ((rand() % 5) == 0) want_pop  = true;
        uint32_t wd = next_data;

        // set inputs and settle combinational status for the CURRENT occupancy
        dut->push = want_push; dut->pop = want_pop; dut->wdata = wd;
        dut->eval();

        bool cur_full  = ((int)model.size() == DEPTH);
        bool cur_empty = model.empty();
        bool do_push = want_push && !cur_full;
        bool do_pop  = want_pop  && !cur_empty;

        // combinational status BEFORE the edge reflects current occupancy
        checks++;
        if (dut->full  != (cur_full ? 1:0)) { if(errors<20) printf("[%ld] full mismatch dut=%d exp=%d\n", i, dut->full, cur_full); errors++; }
        if (dut->empty != (cur_empty?1:0)) { if(errors<20) printf("[%ld] empty mismatch dut=%d exp=%d\n", i, dut->empty, cur_empty); errors++; }
        if (dut->count != model.size())    { if(errors<20) printf("[%ld] count mismatch dut=%d exp=%zu\n", i, dut->count, model.size()); errors++; }

        // predict the registered read produced by THIS step's pop
        bool     exp_rvalid = do_pop;
        uint32_t exp_rdata  = do_pop ? model.front() : 0;

        // clock the edge
        posedge();

        // update model
        if (do_pop)  model.pop_front();
        if (do_push) { model.push_back(wd); next_data++; }

        // check REGISTERED outputs (now reflect this step's pop)
        if (dut->rvalid != (exp_rvalid?1:0)) {
            if (errors<20) printf("[%ld] rvalid mismatch dut=%d exp=%d\n", i, dut->rvalid, exp_rvalid);
            errors++;
        }
        if (exp_rvalid && dut->rdata != exp_rdata) {
            if (errors<20) printf("[%ld] rdata mismatch dut=%08x exp=%08x\n", i, dut->rdata, exp_rdata);
            errors++;
        }
    }

    dut->final();
    printf("fifo_pq: %ld checks, %ld errors\n", checks, errors);
    delete dut;
    return errors ? 1 : 0;
}

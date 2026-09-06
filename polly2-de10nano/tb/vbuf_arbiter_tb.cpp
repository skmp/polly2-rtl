#include "Vvbuf_arbiter.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>

struct Master {
    bool active = false;
    int issued = 0;
    int completed = 0;
    uint32_t address = 0;
    uint8_t burst = 0;
};

static uint32_t beat_word(int owner, int sequence, int beat) {
    return 0xa0000000u | ((uint32_t)owner << 27) |
           ((uint32_t)sequence << 8) | (uint32_t)beat;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vvbuf_arbiter dut;
    Master master[2];
    int errors = 0;
    int cycle = 0;
    const int commands = 24;

    bool response = false;
    int response_owner = 0, response_sequence = 0;
    int response_beat = 0, response_beats = 0, response_latency = 0;
    int previous_accept = -1;

    dut.clk = 0;
    dut.reset = 1;
    dut.m0_read = dut.m1_read = 0;
    dut.s_waitrequest = 0;
    dut.s_readdatavalid = 0;
    for (int w = 0; w < 4; ++w) dut.s_readdata[w] = 0;
    dut.eval();
    for (int i = 0; i < 4; ++i) {
        dut.clk = 1; dut.eval();
        dut.clk = 0; dut.eval();
    }
    dut.reset = 0;

    while (cycle < 20000) {
        for (int owner = 0; owner < 2; ++owner) {
            if (!master[owner].active && master[owner].issued < commands) {
                master[owner].active = true;
                master[owner].address = (owner ? 0x08000000u : 0x01000000u) |
                                        ((uint32_t)master[owner].issued << 8);
                master[owner].burst = (uint8_t)(1 + (master[owner].issued % 7));
            }
        }

        dut.m0_read = master[0].active;
        dut.m0_address = master[0].address;
        dut.m0_burstcount = master[0].burst;
        dut.m1_read = master[1].active;
        dut.m1_address = master[1].address;
        dut.m1_burstcount = master[1].burst;

        // Repeated command stalls plus response gaps exercise command locking
        // and ownership retention independently.
        dut.s_waitrequest = ((cycle * 7) % 13 == 3) || ((cycle * 7) % 13 == 4);
        bool return_beat = response && response_latency == 0 &&
                           ((cycle + response_beat) % 4 != 1);
        dut.s_readdatavalid = return_beat;
        uint32_t word = beat_word(response_owner, response_sequence, response_beat);
        for (int w = 0; w < 4; ++w) dut.s_readdata[w] = word ^ (uint32_t)w;
        dut.eval();

        bool slave_accept = dut.s_read && !dut.s_waitrequest;
        bool m0_accept = master[0].active && !dut.m0_waitrequest;
        bool m1_accept = master[1].active && !dut.m1_waitrequest;

        if (slave_accept) {
            int owner = (dut.s_address & 0x08000000u) ? 1 : 0;
            if (response || m0_accept + m1_accept != 1 ||
                (owner == 0) != m0_accept || (owner == 1) != m1_accept) {
                std::printf("bad command ownership at cycle %d\n", cycle);
                ++errors;
            }
            if (dut.s_address != master[owner].address ||
                dut.s_burstcount != master[owner].burst) {
                std::printf("command payload changed at cycle %d\n", cycle);
                ++errors;
            }
            if (previous_accept >= 0 && owner == previous_accept) {
                std::printf("round-robin fairness failed at cycle %d\n", cycle);
                ++errors;
            }
            previous_accept = owner;
        }

        if (return_beat) {
            bool v0 = dut.m0_readdatavalid;
            bool v1 = dut.m1_readdatavalid;
            if (v0 + v1 != 1 || (response_owner == 0) != v0 ||
                (response_owner == 1) != v1) {
                std::printf("return routed to wrong owner at cycle %d\n", cycle);
                ++errors;
            }
            uint32_t got = response_owner ? dut.m1_readdata[0] : dut.m0_readdata[0];
            if (got != word) {
                std::printf("return data mismatch at cycle %d\n", cycle);
                ++errors;
            }
        } else if (dut.m0_readdatavalid || dut.m1_readdatavalid) {
            std::printf("spurious master readdatavalid at cycle %d\n", cycle);
            ++errors;
        }

        dut.clk = 1;
        dut.eval();

        if (slave_accept) {
            int owner = m1_accept ? 1 : 0;
            response = true;
            response_owner = owner;
            response_sequence = master[owner].issued;
            response_beat = 0;
            response_beats = master[owner].burst;
            response_latency = 2 + (master[owner].issued % 3);
            master[owner].active = false;
            master[owner].issued++;
        } else if (response && response_latency > 0) {
            --response_latency;
        }

        if (return_beat) {
            ++response_beat;
            if (response_beat == response_beats) {
                response = false;
                master[response_owner].completed++;
            }
        }

        dut.clk = 0;
        dut.eval();
        ++cycle;

        if (!response && master[0].completed == commands &&
            master[1].completed == commands) break;
    }

    if (master[0].completed != commands || master[1].completed != commands) {
        std::printf("timeout: completed %d/%d\n",
                    master[0].completed, master[1].completed);
        ++errors;
    }

    std::printf("commands=%d/%d cycles=%d %s\n", master[0].completed,
                master[1].completed, cycle, errors ? "FAIL" : "PASS");
    dut.final();
    return errors != 0;
}

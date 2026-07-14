// Shared alignment helper for the *_spp_ro bit-exactness TBs.
//
// The pipelined DUT and the combinational ref are fed the SAME input each cycle; the
// DUT result appears some fixed number of cycles later. Rather than hard-code that
// offset (it depends on exactly where eval()/tick() sample), we record (input-tag,
// ref) pairs keyed by a monotonic counter that the RTL also echoes back via out_valid
// ordering: because in_valid is held high every cycle and stall is tied low, the DUT
// emits exactly one out_valid per input in ORDER. So the k-th out_valid corresponds to
// the k-th input. We therefore compare the k-th observed valid output against the k-th
// pushed reference, which is offset-agnostic.
#pragma once
#include <deque>
#include <cstdint>
#include <cstdio>

struct SppChecker {
    std::deque<uint32_t> refq;   // references in input order, awaiting their valid output
    long checked = 0, mism = 0, printed = 0;
    const char* name;
    SppChecker(const char* n) : name(n) {}

    // call once per cycle AFTER tick(): push this input's ref, and if out_valid fires,
    // pop the oldest un-consumed ref and compare.
    void step(uint32_t ref_now, bool out_valid, uint32_t y, long i) {
        refq.push_back(ref_now);
        if (out_valid) {
            // there must be a pending ref; the oldest one is this output's input.
            uint32_t expect = refq.front(); refq.pop_front();
            checked++;
            if (y != expect) {
                mism++;
                if (printed++ < 15)
                    printf("[%ld] MISMATCH dut=%08x ref=%08x\n", i, y, expect);
            }
        }
    }
    int report(long N) {
        printf("%s: N=%ld checked=%ld mismatches=%ld\n", name, N, checked, mism);
        return mism ? 1 : 0;
    }
};

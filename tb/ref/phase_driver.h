// phase_driver.h: a render walked through the p2ref calls (tb/ref/p2ref.h), in RenderCORE's order (PLAN 1.1 "the glue
// self-test", 1.3 "phase-halt mode"). The frame around the entries (the write-out's put / scaler, the region array walk,
// each entry's write-out) is RenderCORE's own text, the copies of tb/ref/ref_copies.h section A; each entry's ISP and
// TSP work is the driver's sequence of p2ref calls, with a hook at every phase boundary (tb/common/isp_live.h's phases),
// where a tile testbench compares, halts or feeds its RTL.
#pragma once
#include "p2ref.h"
#include "isp_live.h"

namespace p2drv {

struct Options {
    bool ptCopy = false;        // the PT phases by the verbatim PT loop (p2ref::pt_phase_copy) instead of the driver's
                                // calls: its only boundary is PT_FINAL
    int maxPasses = 0;          // > 0: a punch-through chunk or a translucent sort that takes more passes than this
                                // ends the render: render() returns false (refsw3, like a console, would go on for ever;
                                // a hook that breaks the state can make it do that)
};

// what the renders took, at most, per entry (render() adds to it)
struct Stats {
    long entries = 0;
    int ptChunks = 0, ptPasses = 0, trPasses = 0;
};

// called after each phase of each entry: the phase, the entry, its tile
typedef void (*Hook)(p2live::Phase ph, const p2ref::RegionArrayEntry& e, const p2ref::taRECT& r, void* user);

// one render (what refsw3-offline does on STARTRENDER), on the registers and video memory loaded now (p2ref::load_*)
// and the core state the renders before left (p2ref::reset_core for a new process's). False: it did not end
// (Options::maxPasses); what it left is then not a render's.
bool render(const Options& o, Hook hook = nullptr, void* user = nullptr, Stats* stats = nullptr);

}   // namespace p2drv

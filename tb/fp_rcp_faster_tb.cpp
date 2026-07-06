// fp_rcp_faster vs fp_rcp_fast equivalence: same result, faster's latency is 5, fast's 3.
#include "Vfp_rcp_fast.h"
#include "Vfp_rcp_faster.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vfp_rcp_fast*   a;
static Vfp_rcp_faster* b;
static void tick(){ a->clk=b->clk=0; a->eval(); b->eval(); a->clk=b->clk=1; a->eval(); b->eval(); }

int main(int c,char**v){
    Verilated::commandArgs(c,v);
    a=new Vfp_rcp_fast; b=new Vfp_rcp_faster;
    a->reset=b->reset=1; a->stall=b->stall=0; a->in_valid=b->in_valid=0;
    tick(); tick(); a->reset=b->reset=0;

    // stream random x through both; compare y at each unit's own out_valid.
    std::vector<uint32_t> ins;
    uint32_t rng=0x1234567;
    auto rnd=[&](){ rng^=rng<<13; rng^=rng>>17; rng^=rng<<5; return rng; };
    for (int i=0;i<20000;i++) ins.push_back(rnd());

    // feed both in lockstep; collect outputs in order (both in-order pipelines).
    std::vector<uint32_t> ya, yb; size_t fed=0;
    for (int cyc=0; cyc<(int)ins.size()+16; cyc++){
        bool feed = fed < ins.size();
        uint32_t x = feed ? ins[fed] : 0;
        a->in_valid=b->in_valid=feed; a->x=b->x=x;
        tick();
        if (a->out_valid) ya.push_back(a->y);
        if (b->out_valid) yb.push_back(b->y);
        if (feed) fed++;
    }
    // compare the common prefix
    size_t n = ya.size()<yb.size()?ya.size():yb.size();
    int fails=0;
    for (size_t i=0;i<n;i++) if (ya[i]!=yb[i]){ fails++; if(fails<8)
        printf("  [%zu] fast=%08x faster=%08x\n", i, ya[i], yb[i]); }
    printf("fp_rcp_faster: %zu compared (%zu vs %zu emitted), %d mismatch\n",
           n, ya.size(), yb.size(), fails);
    printf(fails?"RCP FAIL\n":"RCP OK\n");
    return fails?1:0;
}

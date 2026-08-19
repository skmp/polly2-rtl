// isp_setup_cache unit test (built with -GW=64 -GTAGOFF=0 so the payload is a
// plain 64-bit word with the tag in [31:0]): fill/probe/consume semantics, the
// pin protocol (a pinned index refuses aliasing fills until unpinned), the
// probe-vs-fill same-edge races (both resolve conservatively), and inval.
#include "Visp_setup_cache.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static Visp_setup_cache* dut;
static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }
static int fails=0;
static void expect(bool c,const char*w){ if(!c){ printf("FAIL: %s\n",w); fails++; } }

static uint32_t idx_of(uint32_t t){ return ((t>>3) ^ (t&7)) & 255; }
static uint64_t rec(uint32_t tag){ return (0xDEADBEEFULL<<32) | tag; }

static void clr(){ dut->inval=0; dut->pr_valid=0; dut->pin_valid=0; dut->cl_valid=0;
                   dut->fl_valid=0; dut->rd_valid=0; }
static void fill(uint32_t t){ clr(); dut->fl_valid=1; dut->fl_tag=t; dut->fl_data=rec(t); tick(); clr(); }
// probe: verdict is on pr_hit while pr_vq (the cycle after issue). The verdict
// cycle is CONSUMED here (a fill landing on it is refused by the race guard -
// correct, but not what the directed sequences below intend to exercise).
static bool probe(uint32_t t){
    bool h;
    clr(); dut->pr_valid=1; dut->pr_tag=t; tick();
    clr(); dut->pr_tag=t;  // tag held through the verdict cycle (pin contract)
    dut->eval();
    expect(dut->pr_vq, "pr_vq");
    h = dut->pr_hit;
    tick(); clr();          // retire the verdict cycle
    return h;
}
// probe + pin on the verdict cycle (the caller's surviving-hit claim)
static bool probe_pin(uint32_t t){
    bool h;
    clr(); dut->pr_valid=1; dut->pr_tag=t; tick();
    clr(); dut->pr_tag=t; dut->eval();
    h = dut->pr_hit;
    if(h){ dut->pin_valid=1; }
    tick(); clr();
    return h;
}
static void unpin(uint32_t t){ clr(); dut->cl_valid=1; dut->cl_tag=t; tick(); clr(); }
static bool consume(uint32_t t, uint64_t* d){
    clr(); dut->rd_valid=1; dut->rd_tag=t; tick();
    clr(); dut->eval();
    expect(dut->rd_vq, "rd_vq");
    if(d) *d = dut->rd_data;
    return dut->rd_ok;
}

int main(int argc,char**argv){
    setvbuf(stdout, nullptr, _IONBF, 0);
    Verilated::commandArgs(argc,argv);
    dut=new Visp_setup_cache;
    clr(); dut->reset=1; tick(); tick(); dut->reset=0; clr(); tick();

    const uint32_t A=0x100, B=0x900;                 // same idx (0x20), different tags
    expect(idx_of(A)==idx_of(B), "A/B alias construction");
    const uint32_t C=0x208;                          // different idx

    // ---- cold: miss ----
    expect(probe(A)==false, "cold probe misses");

    // ---- fill -> hit; alias -> miss; other idx untouched ----
    fill(A);
    expect(probe(A)==true,  "A hits after fill");
    expect(probe(B)==false, "alias B misses (stored tag is A)");
    expect(probe(C)==false, "C (other idx) misses");

    // ---- consume returns the record ----
    { uint64_t d=0; expect(consume(A,&d)==true, "consume A ok");
      expect(d==rec(A), "consume A data"); }

    // ---- pin protocol: a pinned index refuses aliasing fills ----
    expect(probe_pin(A)==true, "A hits and pins");
    fill(B);                                          // must be DROPPED (idx pinned)
    expect(probe(A)==true,  "A still resident after dropped alias fill");
    { uint64_t d=0; expect(consume(A,&d)==true, "pinned A consumable");
      expect(d==rec(A), "pinned A data intact"); }
    unpin(A);
    fill(B);                                          // now accepted
    expect(probe(B)==true,  "B hits after unpin+fill");
    expect(probe(A)==false, "A evicted by B");

    // ---- same-edge race: fill landing with the probe read -> conservative miss,
    //      and the fill itself is dropped on the verdict/pin edge ----
    fill(A);                                          // resident again
    { clr(); dut->pr_valid=1; dut->pr_tag=A;          // probe A...
      dut->fl_valid=1; dut->fl_tag=B; dut->fl_data=rec(B);  // ...fill alias same edge
      tick(); clr(); dut->pr_tag=A; dut->eval();
      expect(dut->pr_vq, "race pr_vq");
      expect(dut->pr_hit==false, "probe racing a same-idx fill reads MISS"); }
    // the fill from the race cycle DID land (pr_infl was still low on that edge);
    // a fill on the verdict cycle itself is the dropped one - either way the probe
    // said miss, so no skip was claimed and correctness holds. B or A may be
    // resident now; just verify the store is consistent:
    { bool a=probe(A), b=probe(B);
      expect(a!=b, "exactly one of A/B resident after the race"); }

    // ---- inval drops everything (tile change / render go) ----
    clr(); dut->inval=1; tick(); clr();
    expect(probe(A)==false && probe(B)==false && probe(C)==false, "inval clears all");

    printf("isp_setup_cache: %s (%d fails)\n", fails? "FAIL":"PASS", fails);
    delete dut;
    return fails?1:0;
}

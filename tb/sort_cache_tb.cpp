// sort_cache unit test: directed semantics (enter/demote/check, same-cycle
// conflict priority, alias mismatch, reset sweep) + randomized ops against a
// C mirror of the 4-way store.
#include "Vsort_cache.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>

static Vsort_cache* dut;
static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

static const int IXW = 7, NENT = 1<<IXW, WAYS = 4;
static uint32_t idx_of(uint32_t t){ return ((t>>3) ^ (t&7)) & (NENT-1); }

// C mirror: per way {tag, done, valid-after-sweep}
struct Ent { uint32_t tag; bool done; };
static Ent model[WAYS][NENT];

static void clr_inputs(){
    dut->en_valid=0; dut->chk_valid=0; dut->wr_valid=0;
    for(int w=0;w<WAYS;w++) dut->wr_tag[w]=0;
}

// apply one cycle of (enter?, demotes[], check?) to DUT+model; returns model's
// expected chk_done for the check issued THIS cycle (result visible next cycle).
static bool step(bool en, uint32_t en_tag, uint8_t dm, const uint32_t dtag[4],
                 bool chk, uint32_t chk_tag){
    dut->en_valid = en; dut->en_tag = en_tag;
    dut->wr_valid = dm;
    for(int w=0;w<WAYS;w++) dut->wr_tag[w] = dtag ? dtag[w] : 0;
    dut->chk_valid = chk; dut->chk_tag = chk_tag;
    // model: check reads PRE-write state (registered read of same-edge write
    // returns the old entry)
    bool exp = true;
    for(int w=0;w<WAYS;w++){
        Ent&e = model[w][idx_of(chk_tag)];
        if(!(e.done && e.tag==chk_tag)) exp=false;
    }
    // model writes: per way, demote wins over enter
    for(int w=0;w<WAYS;w++){
        if(dm&(1u<<w))  model[w][idx_of(dtag[w])] = { dtag[w], false };
        else if(en)     model[w][idx_of(en_tag)]  = { en_tag,  true  };
    }
    tick();
    return exp;
}

static int fails=0;
static void expect(bool cond, const char*what){
    if(!cond){ printf("FAIL: %s\n", what); fails++; }
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Vsort_cache;
    clr_inputs();
    dut->reset=1; tick(); tick(); dut->reset=0;

    // ---- reset sweep: ready rises after NENT cycles; checks gated meanwhile ----
    dut->chk_valid=1; dut->chk_tag=0x1234;
    int swp=0; while(!dut->ready && swp++<NENT+8) { tick(); expect(!dut->chk_valid_q, "chk_valid_q low during sweep"); }
    expect(dut->ready, "ready after sweep");
    dut->chk_valid=0; tick();
    memset(model,0,sizeof model);   // sweep leaves {tag=0,done=0} everywhere

    const uint32_t A=0x00123458u, Bx=(0x00123458u ^ 0x9u); // B: flip po[0]+toff[0] -> same idx
    expect(idx_of(A)==idx_of(Bx), "A/B alias construction");

    // drive one check and sample its (registered-read) result
    auto check_now = [&](uint32_t t)->bool{
        clr_inputs(); dut->chk_valid=1; dut->chk_tag=t; tick();
        clr_inputs(); dut->eval();
        expect(dut->chk_valid_q, "chk_valid_q");
        return dut->chk_done;
    };

    // ---- enter -> done; demote one way -> not done; re-enter -> done ----
    clr_inputs(); dut->en_valid=1; dut->en_tag=A; tick();
    expect(check_now(A)==true,  "A done after enter");
    { uint32_t d[4]={0,0,A,0}; clr_inputs(); dut->wr_valid=1u<<2; for(int w=0;w<4;w++) dut->wr_tag[w]=d[w]; tick(); }
    expect(check_now(A)==false, "A not done after way2 demote");
    clr_inputs(); dut->en_valid=1; dut->en_tag=A; tick();
    expect(check_now(A)==true,  "A done after re-enter");

    // ---- alias: demote B (same idx) on way1 kills A's agreement ----
    { clr_inputs(); dut->wr_valid=1u<<1; dut->wr_tag[1]=Bx; tick(); }
    expect(check_now(A)==false, "A not done after alias B demote way1");
    expect(check_now(Bx)==false,"B not done (demoted entry)");

    // ---- same-cycle conflict, same tag: demote wins in its way ----
    { clr_inputs(); dut->en_valid=1; dut->en_tag=A; dut->wr_valid=1u<<3; dut->wr_tag[3]=A; tick(); }
    expect(check_now(A)==false, "demote beats enter (same tag, way3)");

    // ---- same-cycle conflict, different index: enter lands in other ways only ----
    const uint32_t C=0x00200008u, D=0x00300010u;
    expect(idx_of(C)!=idx_of(D), "C/D distinct idx");
    { clr_inputs(); dut->en_valid=1; dut->en_tag=C; dut->wr_valid=1u<<0; dut->wr_tag[0]=D; tick(); }
    expect(check_now(C)==false, "enter lost way0 -> conservative not-done");
    expect(check_now(D)==false, "demoted D not done");
    clr_inputs(); dut->en_valid=1; dut->en_tag=C; tick();     // clean re-enter
    expect(check_now(C)==true,  "C done after clean enter");

    // ---- randomized soak vs model ----
    memset(model,0,sizeof model);
    // re-sync model: sweep again via reset
    clr_inputs(); dut->reset=1; tick(); dut->reset=0;
    while(!dut->ready) tick();
    uint32_t seed=0xC0FFEE;
    auto rnd=[&]{ seed=seed*1664525u+1013904223u; return seed; };
    // small tag pool so aliases + rechecks are frequent
    uint32_t pool[32]; for(int i=0;i<32;i++) pool[i]=((rnd()&0xFFFF)<<3)|(rnd()&7);
    bool pend=false, pend_exp=false;
    for(int it=0;it<20000;it++){
        bool en = (rnd()&3)==0;
        uint32_t et = pool[rnd()&31];
        uint8_t dm = rnd()&0xF; if(rnd()&1) dm=0;
        uint32_t dt[4]; for(int w=0;w<4;w++) dt[w]=pool[rnd()&31];
        bool ck = (rnd()&1);
        uint32_t ct = pool[rnd()&31];
        // sample previous check result
        if(pend){ if((bool)dut->chk_done != pend_exp){
            printf("SOAK mismatch @%d: got %d want %d\n", it, (int)dut->chk_done, (int)pend_exp); fails++; if(fails>5)break; } }
        pend_exp = step(en, et, dm, dt, ck, ct);
        pend = ck;
    }

    printf("sort_cache: %s (%d fails)\n", fails? "FAIL":"PASS", fails);
    delete dut;
    return fails?1:0;
}

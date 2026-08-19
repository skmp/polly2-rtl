// sort_cache unit test: directed semantics (enter/demote/check, write staging +
// conflict priority, redundant-demote filter, alias mismatch, reset sweep) +
// randomized ops against a C mirror of the 4-way store.
//
// Write staging (mirrors the RTL exactly):
//   enter  presented at cycle t writes at edge t+1 (timing register)
//   demote presented at cycle t writes at edge t+2 (timing register + filter stage),
//          and is DROPPED when the last write its way made was this same {0,tag}
//          (the redundant-demote filter - the entry provably already holds it)
//   check  presented at cycle t returns the store as of edge t (pre-edge state),
//          so a demote is visible to a check presented >= 3 cycles later.
#include "Vsort_cache.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>

static Vsort_cache* dut;
static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

static const int IXW = 10, NENT = 1<<IXW, WAYS = 4;   // match sort_cache.sv IXW
static uint32_t idx_of(uint32_t t){ return ((t>>3) ^ (t&7)) & (NENT-1); }

// C mirror: per way {tag, done}
struct Ent { uint32_t tag; bool done; };
static Ent model[WAYS][NENT];

// pipeline mirror: stage-1 enter, stage-1 + stage-2 demote, per-way filter tracker
static bool     en1_v;         static uint32_t en1_tag;
static uint8_t  wr1_v, dm2_v;  static uint32_t wr1_tag[WAYS], dm2_tag[WAYS];
static bool     lst_v[WAYS];   static uint32_t lst_tag[WAYS];

static void model_reset(){
    memset(model,0,sizeof model);
    en1_v=false; en1_tag=0; wr1_v=0; dm2_v=0;
    for(int w=0;w<WAYS;w++){ wr1_tag[w]=dm2_tag[w]=lst_tag[w]=0; lst_v[w]=false; }
}

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
    // model: check reads the PRE-EDGE store (registered read of same-edge writes
    // returns the old entries)
    bool exp = true;
    for(int w=0;w<WAYS;w++){
        Ent&e = model[w][idx_of(chk_tag)];
        if(!(e.done && e.tag==chk_tag)) exp=false;
    }
    // model writes landing at THIS edge: per way, the stage-2 demote (if the filter
    // lets it through) wins over the stage-1 enter. Any write that is not that
    // demote clears the tracker, so a suppression never outlives the entry it
    // asserts is resident.
    for(int w=0;w<WAYS;w++){
        bool dem = (dm2_v>>w)&1u;
        bool eff = dem && !(lst_v[w] && lst_tag[w]==dm2_tag[w]);
        if(eff){
            model[w][idx_of(dm2_tag[w])] = { dm2_tag[w], false };
            lst_v[w]=true; lst_tag[w]=dm2_tag[w];
        } else if(en1_v){
            model[w][idx_of(en1_tag)] = { en1_tag, true };
            lst_v[w]=false;
        }
    }
    // shift the pipeline mirrors (same edge)
    dm2_v = wr1_v;
    for(int w=0;w<WAYS;w++) dm2_tag[w] = wr1_tag[w];
    wr1_v = dm;
    for(int w=0;w<WAYS;w++) wr1_tag[w] = dtag ? dtag[w] : 0;
    en1_v = en; en1_tag = en_tag;
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
    model_reset();   // sweep leaves {tag=0,done=0} everywhere

    const uint32_t A=0x00123458u, Bx=(0x00123458u ^ 0x9u); // B: flip po[0]+toff[0] -> same idx
    expect(idx_of(A)==idx_of(Bx), "A/B alias construction");

    // drive one check and sample its (registered-read) result. The two leading idle
    // cycles retire anything still in the demote pipeline, so a check issued right
    // after driving a demote still observes it (the caller's 3-cycle settle rule).
    auto check_now = [&](uint32_t t)->bool{
        clr_inputs(); tick();
        clr_inputs(); tick();
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

    // ---- same-cycle conflict, same tag: demote lands one edge later and wins ----
    clr_inputs(); dut->en_valid=1; dut->en_tag=A; tick();   // clean state (clears trackers)
    { clr_inputs(); dut->en_valid=1; dut->en_tag=A; dut->wr_valid=1u<<3; dut->wr_tag[3]=A; tick(); }
    expect(check_now(A)==false, "demote beats enter (same tag, way3)");

    // ---- same-cycle presentation, different index: NO LONGER a conflict ----
    // The demote's extra register serializes the two writes (enter at edge t+1,
    // demote at t+2), so an enter no longer loses its slot to a same-cycle demote
    // at a DIFFERENT index. This removes the whole same-cycle class of enter loss
    // (35% of enters on the sa_slow2 scene).
    const uint32_t C=0x00200008u, D=0x00300010u;
    expect(idx_of(C)!=idx_of(D), "C/D distinct idx");
    { clr_inputs(); dut->en_valid=1; dut->en_tag=C; dut->wr_valid=1u<<0; dut->wr_tag[0]=D; tick(); }
    expect(check_now(C)==true,  "enter survives same-cycle demote at another index");
    expect(check_now(D)==false, "demoted D not done");

    // ---- redundant-demote filter: a repeat demote yields the port to an enter ----
    // demote D way0 (t0), repeat it (t1), enter E (t2): the repeat would land on the
    // same edge as E's write (t+3) and swallow it, but the filter suppresses it (way0
    // just wrote this exact {0,D}), so E survives in ALL ways.
    const uint32_t E=0x00400020u;
    expect(idx_of(E)!=idx_of(D), "E/D distinct idx");
    { clr_inputs(); dut->wr_valid=1u<<0; dut->wr_tag[0]=D; tick(); }
    { clr_inputs(); dut->wr_valid=1u<<0; dut->wr_tag[0]=D; tick(); }
    { clr_inputs(); dut->en_valid=1; dut->en_tag=E; tick(); }
    expect(check_now(E)==true,  "filter: enter survives a repeat demote");
    expect(check_now(D)==false, "filter: demoted D still not done");

    // ---- randomized soak vs model ----
    model_reset();
    // re-sync model: sweep again via reset
    clr_inputs(); dut->reset=1; tick(); dut->reset=0;
    while(!dut->ready) tick();
    uint32_t seed=0xC0FFEE;
    auto rnd=[&]{ seed=seed*1664525u+1013904223u; return seed; };
    // small tag pool so aliases + rechecks + repeat demotes are frequent
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

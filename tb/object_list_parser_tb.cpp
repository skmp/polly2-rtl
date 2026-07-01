// object_list_parser unit test: builds hand-crafted + randomized object lists
// in a behavioral VRAM, drives start, and checks the emitted ENTRY stream
// (entry_type + decoded param_offs/skip/shadow/mask/count) against a C golden
// mirroring refsw's RenderObjectList entry walk (refsw_lists.cpp). The parser
// presents one object-list ENTRY at a time (not one primitive) - mask (strip)
// and count (array) are exposed raw; iterating sub-elements is the consumer's
// job, so this test only checks entry-level fields, not per-triangle expansion.
#include "Vobject_list_parser_tb_top.h"
#include "Vobject_list_parser_tb_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vobject_list_parser_tb_top* dut;
#define VRAM dut->rootp->object_list_parser_tb_top__DOT__vram
static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

static uint32_t rng=0xC0FFEE11;
static uint32_t rnd(){uint32_t x=rng;x^=x<<13;x^=x>>17;x^=x<<5;rng=x;return x;}

// Write a 32-bit word at a 32-bit-VIEW byte address, de-interleaving into the
// physical 64-bit VRAM exactly like refsw pvr_map32 (so the cache's 32-bit-view
// read returns it): view word q=addr>>2 -> bank=q[20], wofs=q[19:0]; physical
// VRAM[wofs&0xFFFF], low 32 if bank0 else high 32.
static void put_word(uint32_t byte_addr, uint32_t val){
    uint32_t q = byte_addr >> 2; uint32_t bank = (q>>20)&1; uint32_t wofs = (q&0xFFFFF)&0xFFFF;
    uint64_t w = VRAM[wofs];
    w &= ~((uint64_t)0xFFFFFFFFu << (32*bank));
    w |= ((uint64_t)val) << (32*bank);
    VRAM[wofs] = w;
}
// Read a 32-bit word from a 32-bit-VIEW byte address (same de-interleave).
static uint32_t get_word(uint32_t byte_addr){
    uint32_t q = byte_addr >> 2; uint32_t bank = (q>>20)&1; uint32_t wofs = (q&0xFFFFF)&0xFFFF;
    return (uint32_t)(VRAM[wofs] >> (32*bank));
}

static uint32_t tstrip_entry(uint32_t poff,uint32_t skip,uint32_t shadow,uint32_t mask){
    return (poff&0x1FFFFF) | ((skip&7)<<21) | ((shadow&1)<<24) | ((mask&0x3F)<<25) | (0u<<31);
}
static uint32_t arr_entry(uint32_t poff,uint32_t skip,uint32_t shadow,uint32_t prims,uint32_t type){
    return (poff&0x1FFFFF) | ((skip&7)<<21) | ((shadow&1)<<24) | ((prims&0xF)<<25) | ((type&7)<<29);
}
static uint32_t link_entry(uint32_t next_words,bool eol){
    return ((next_words&0x3FFFFF)<<2) | ((eol?1u:0u)<<28) | (0b111u<<29);
}

struct GoldEntry { int type; uint32_t poff, skip, shadow, mask, count; };

// Golden: walk the object list exactly like RenderObjectList's entry loop
// (strip/array classification + link following), WITHOUT per-element expansion.
static std::vector<GoldEntry> golden_walk(uint32_t base_words){
    std::vector<GoldEntry> out;
    uint32_t base = base_words*4;
    for(int guard=0; guard<100000; guard++){
        uint32_t e = get_word(base);
        base += 4;
        if (((e>>31)&1)==0){
            uint32_t poff=e&0x1FFFFF, skip=(e>>21)&7, shadow=(e>>24)&1, mask=(e>>25)&0x3F;
            out.push_back({0,poff,skip,shadow,mask,0});
        } else {
            uint32_t type=(e>>29)&7;
            if (type==0b111){ // link
                bool eol=(e>>28)&1;
                if (eol) break;
                base = ((e>>2)&0x3FFFFF)*4;
            } else if (type==0b100 || type==0b101){
                uint32_t poff=e&0x1FFFFF, skip=(e>>21)&7, shadow=(e>>24)&1, prims=(e>>25)&0xF;
                bool quad=(type==0b101);
                out.push_back({quad?2:1, poff,skip,shadow,0,prims+1});
            } else break;
        }
    }
    return out;
}

int fails=0, total=0;

static void run_case(const char* name, uint32_t base_words){
    dut->reset=1; dut->start=0; dut->consume=0; tick(); tick(); tick(); dut->reset=0;
    // data_cache256's reset sweep takes NLINE cycles before it accepts requests
    for(int i=0;i<300;i++) tick();
    auto gold = golden_walk(base_words);

    dut->list_ptr = base_words*4; dut->start=1; tick(); dut->start=0;
    size_t gi=0;
    int guard=0;
    while(true){
        if (dut->done && gi>=gold.size()) break;
        if (dut->entry_ready){
            total++;
            if (gi>=gold.size()){
                printf("[%s] extra entry #%zu (type=%d)\n",name,gi,dut->entry_type);
                fails++;
            } else {
                auto&g=gold[gi];
                bool ok = (dut->entry_type==g.type) && (dut->entry_param_offs==g.poff)
                       && (dut->entry_skip==g.skip) && (dut->entry_shadow==g.shadow)
                       && (dut->entry_mask==g.mask) && (dut->entry_count==g.count);
                if(!ok){
                    fails++;
                    if(fails<20) printf("[%s] entry #%zu: hw(type=%d poff=%x skip=%d shadow=%d mask=%02x count=%d) "
                        "exp(type=%d poff=%x skip=%d shadow=%d mask=%02x count=%d)\n",
                        name,gi,dut->entry_type,dut->entry_param_offs,dut->entry_skip,dut->entry_shadow,
                        dut->entry_mask,dut->entry_count,
                        g.type,g.poff,g.skip,g.shadow,g.mask,g.count);
                }
            }
            dut->consume=1; tick(); dut->consume=0;
            gi++;
        } else {
            tick();
        }
        if(++guard>200000){ printf("[%s] TIMEOUT (gi=%zu/%zu)\n",name,gi,gold.size()); fails++; break; }
    }
    if (gi < gold.size()){
        printf("[%s] missing entries: got %zu expected %zu\n",name,gi,gold.size());
        fails += (int)(gold.size()-gi);
        total += (int)(gold.size()-gi);
    }
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Vobject_list_parser_tb_top;
    for(int i=0;i<65536;i++) VRAM[i]=0;

    // ---- case 1: single strip, full mask ----
    put_word(0*4, tstrip_entry(0x100, 2, 0, 0x3F));
    put_word(1*4, link_entry(0, true));
    run_case("strip_full", 0);

    // ---- case 2: strip with sparse mask ----
    put_word(10*4, tstrip_entry(0x200, 1, 1, 0b101010));
    put_word(11*4, link_entry(0, true));
    run_case("strip_sparse", 10);

    // ---- case 3: triangle array, 4 prims ----
    put_word(20*4, arr_entry(0x300, 3, 0, 3 /*prims-1*/, 0b100));
    put_word(21*4, link_entry(0, true));
    run_case("tri_array", 20);

    // ---- case 4: quad array, 2 prims ----
    put_word(30*4, arr_entry(0x400, 0, 0, 1, 0b101));
    put_word(31*4, link_entry(0, true));
    run_case("quad_array", 30);

    // ---- case 5: link chaining (strip -> jump -> array -> end) ----
    put_word(40*4, tstrip_entry(0x500, 0, 0, 0b111111));
    put_word(41*4, link_entry(100, false));
    put_word(100*4, arr_entry(0x600, 1, 0, 0, 0b100));
    put_word(101*4, link_entry(0, true));
    run_case("link_chain", 40);

    // ---- case 6: randomized lists ----
    for (int t=0; t<40; t++){
        uint32_t base = 200 + t*20;
        int n = 1 + (rnd()%4);
        uint32_t b = base;
        for (int i=0;i<n;i++){
            int kind = rnd()%3;
            if (kind==0) put_word(b*4, tstrip_entry(rnd()&0x1FFFFF, rnd()&7, rnd()&1, rnd()&0x3F));
            else if (kind==1) put_word(b*4, arr_entry(rnd()&0x1FFFFF, rnd()&7, rnd()&1, rnd()&0xF, 0b100));
            else put_word(b*4, arr_entry(rnd()&0x1FFFFF, rnd()&7, rnd()&1, rnd()&0xF, 0b101));
            b++;
        }
        put_word(b*4, link_entry(0, true));
        char name[32]; snprintf(name,sizeof(name),"rand%d",t);
        run_case(name, base);
    }

    printf("object_list_parser: %d/%d passed\n", total-fails, total);
    printf(fails?"OPARSE FAIL\n":"OPARSE OK\n");
    return fails?1:0;
}

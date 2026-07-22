// region_array_parser unit test: builds region-array entries in a behavioral
// VRAM and checks the emitted (tile,state) stream against a C golden mirroring
// refsw RenderCORE's per-tile state ordering (clear -> op -> pt -> tr -> flush).
// CLEAR and FLUSH are emitted for EVERY entry (start/end-of-entry markers carrying
// z_keep / writeout); OP/PT/TR appear only when enabled. No entry is skipped.
// Terminates on control.last_region or 16384 tiles.
#include "Vregion_array_parser_tb_top.h"
#include "Vregion_array_parser_tb_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vregion_array_parser_tb_top* dut;
#define VRAM dut->rootp->region_array_parser_tb_top__DOT__vram
static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

static uint32_t rng=0xB16B00B5;
static uint32_t rnd(){uint32_t x=rng;x^=x<<13;x^=x>>17;x^=x<<5;rng=x;return x;}

// Write a 32-bit word at a 32-bit-VIEW byte address, de-interleaving into the
// physical 64-bit VRAM like refsw pvr_map32 (matches data_cache256's read view).
static void put_word(uint32_t byte_addr, uint32_t val){
    uint32_t q = byte_addr >> 2; uint32_t bank = (q>>20)&1; uint32_t wofs = (q&0xFFFFF)&0xFFFF;
    uint64_t w = VRAM[wofs];
    w &= ~((uint64_t)0xFFFFFFFFu << (32*bank));
    w |= ((uint64_t)val) << (32*bank);
    VRAM[wofs] = w;
}

// region_state_e one-hot (must match tsp_pkg)
enum { RS_CLEAR=1, RS_OP=2, RS_PT=4, RS_TR=8, RS_FLUSH=16 };

static uint32_t control_word(uint32_t tx,uint32_t ty,bool z_keep,bool no_writeout,bool last){
    return (0u<<0) | ((tx&0x3F)<<2) | ((ty&0x3F)<<8) |
           ((no_writeout?1u:0u)<<28) | (0u<<29) | ((z_keep?1u:0u)<<30) | ((last?1u:0u)<<31);
}
// refsw ListPointer {pad0:2, ptr_in_words:22, pad1:7, empty:1}: ptr_in_words
// lives in bits [23:2], byte_addr = ptr_in_words*4. The parser reads rword[23:2]
// and emits {rword[23:2],2'b00}.
static uint32_t listptr(uint32_t ptr_words,bool empty){
    return ((ptr_words&0x3FFFFF)<<2) | ((empty?1u:0u)<<31);
}

struct Entry {
    uint32_t tx,ty; bool z_keep, no_writeout, last;
    bool op_e, pt_e, tr_e; uint32_t op_p, pt_p, tr_p;
};
struct GoldState { uint32_t tx,ty,state,ptr,wo,zk; };

// build a v2 (24-byte) region entry at byte `base`
static void build_entry(uint32_t base, const Entry&e){
    put_word(base+0,  control_word(e.tx,e.ty,e.z_keep,e.no_writeout,e.last));
    put_word(base+4,  listptr(e.op_p, !e.op_e));
    put_word(base+8,  listptr(rnd(), true));         // opaque_mod (ignored)
    put_word(base+12, listptr(e.tr_p, !e.tr_e));
    put_word(base+16, listptr(rnd(), true));         // trans_mod (ignored)
    put_word(base+20, listptr(e.pt_p, !e.pt_e));
}

// golden: expand one entry into its ordered enabled states. CLEAR is now emitted for
// EVERY entry as the start-of-entry marker (its `zk` = control.z_keep tells the consumer
// full-clear vs keep-depth-tag-invalidate); FLUSH is emitted for EVERY entry as the
// end-of-entry marker (its `wo` = !no_writeout tells the consumer whether to post the
// tile to VRAM). OP/PT/TR appear only when their list is enabled.
static void gold_entry(const Entry&e, std::vector<GoldState>&out){
    out.push_back({e.tx,e.ty,RS_CLEAR, 0, 0, e.z_keep?1u:0u});
    if (e.op_e)         out.push_back({e.tx,e.ty,RS_OP,    e.op_p*4, 0, 0});
    if (e.pt_e)         out.push_back({e.tx,e.ty,RS_PT,    e.pt_p*4, 0, 0});
    if (e.tr_e)         out.push_back({e.tx,e.ty,RS_TR,    e.tr_p*4, 0, 0});
    out.push_back({e.tx,e.ty,RS_FLUSH, 0, e.no_writeout?0u:1u, 0});
}

int fails=0, total=0;

static void run_case(const char* name, uint32_t base_words, std::vector<Entry>&entries){
    dut->reset=1; dut->start=0; dut->consume=0; tick(); tick(); tick(); dut->reset=0;
    for(int i=0;i<300;i++) tick();   // data_cache256 reset sweep

    // lay out entries contiguously (24 bytes each)
    std::vector<GoldState> gold;
    for (size_t i=0;i<entries.size();i++){
        build_entry(base_words*4 + i*24, entries[i]);
        gold_entry(entries[i], gold);
    }

    dut->region_base=base_words*4; dut->region_v1=0;
    dut->start=1; tick(); dut->start=0;

    size_t gi=0; int guard=0;
    while(true){
        if (dut->tiles_parsed && gi>=gold.size()) break;
        if (dut->list_ready){
            total++;
            if (gi>=gold.size()){
                printf("[%s] extra state #%zu (state=%d)\n",name,gi,dut->state); fails++;
            } else {
                auto&g=gold[gi];
                // writeout meaningful on FLUSH, z_keep on CLEAR; both required 0 elsewhere.
                bool ok = (dut->tile_x==g.tx)&&(dut->tile_y==g.ty)&&(dut->state==g.state)&&(dut->list_ptr==g.ptr)
                          &&(dut->writeout==g.wo)&&(dut->z_keep==g.zk);
                if(!ok){
                    fails++;
                    if(fails<20) printf("[%s] #%zu: hw(tx=%d ty=%d state=%02x ptr=%x wo=%d zk=%d) exp(tx=%d ty=%d state=%02x ptr=%x wo=%d zk=%d)\n",
                        name,gi,dut->tile_x,dut->tile_y,dut->state,dut->list_ptr,dut->writeout,dut->z_keep,g.tx,g.ty,g.state,g.ptr,g.wo,g.zk);
                }
            }
            dut->consume=1; tick(); dut->consume=0;
            gi++;
        } else tick();
        if(++guard>500000){ printf("[%s] TIMEOUT (gi=%zu/%zu)\n",name,gi,gold.size()); fails++; break; }
    }
    if (gi<gold.size()){ printf("[%s] missing: got %zu exp %zu\n",name,gi,gold.size()); fails+=(int)(gold.size()-gi); total+=(int)(gold.size()-gi); }
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Vregion_array_parser_tb_top;
    for(int i=0;i<65536;i++) VRAM[i]=0;

    // case 1: single tile, all states (clear+op+pt+tr+flush)
    { std::vector<Entry> e = {
        {3,5, false,false,true, true,true,true, 0x100,0x200,0x300} };
      run_case("all_states", 0, e); }

    // case 2: op only, z_keep set (no clear); no_writeout=1 -> FLUSH still emitted
    // (end-of-entry marker) but with writeout=0
    { std::vector<Entry> e = {
        {1,1, true,true,true, true,false,false, 0x400,0,0} };
      run_case("op_only", 40, e); }

    // case 3: every entry now emits CLEAR(start) + FLUSH(end), so NO entry is skipped.
    // entry 0: z_keep=1,no_writeout=1,no lists -> CLEAR(zk=1)+FLUSH(wo=0).
    // entry 1: z_keep=0,writeout,no lists      -> CLEAR(zk=0)+FLUSH(wo=1).
    { std::vector<Entry> e = {
        {2,2, true,true,false, false,false,false, 0,0,0},
        {7,7, false,false,true, false,false,false, 0,0,0} };
      run_case("empty_then_real", 80, e); }

    // case 4: multi-tile sequence
    { std::vector<Entry> e = {
        {0,0, false,false,false, true,false,false, 0x10,0,0},
        {1,0, true, false,false, false,false,true, 0,0,0x20},
        {2,0, false,true, true, true,true,false, 0x30,0x40,0x50} };
      run_case("multi_tile", 120, e); }

    // case 5: randomized
    for(int t=0;t<30;t++){
        int n = 1 + (rnd()%5);
        std::vector<Entry> e;
        for(int i=0;i<n;i++){
            Entry en;
            en.tx=rnd()&0x3F; en.ty=rnd()&0x3F;
            en.z_keep=rnd()&1; en.no_writeout=rnd()&1; en.last=(i==n-1);
            en.op_e=rnd()&1; en.pt_e=rnd()&1; en.tr_e=rnd()&1;
            en.op_p=rnd()&0x3FFFFF; en.pt_p=rnd()&0x3FFFFF; en.tr_p=rnd()&0x3FFFFF;
            e.push_back(en);
        }
        char name[32]; snprintf(name,sizeof(name),"rand%d",t);
        run_case(name, 200+t*40, e);
    }

    printf("region_array_parser: %d/%d passed\n", total-fails, total);
    printf(fails?"REGION FAIL\n":"REGION OK\n");
    return fails?1:0;
}

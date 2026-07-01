// data_cache256 unit test: 32-byte (256-bit) line cache over a behavioral 64-bit
// DDR. Checks: miss assembles 4 beats in the right order, hit returns the same
// line, direct-mapped aliasing forces a refill, back-to-back requests.
#include "Vdata_cache256_tb_top.h"
#include "Vdata_cache256_tb_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static Vdata_cache256_tb_top* dut;
#define VRAM dut->rootp->data_cache256_tb_top__DOT__vram
static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

static uint32_t rng=0x1234abcd;
static uint32_t rnd(){uint32_t x=rng;x^=x<<13;x^=x>>17;x^=x<<5;rng=x;return x;}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Vdata_cache256_tb_top;
    dut->clk=0; dut->reset=1; dut->req=0; dut->laddr=0;
    for(int i=0;i<4;i++)tick();
    dut->reset=0;
    // let the reset-sweep (NLINE cycles) finish clearing vld[]
    for(int i=0;i<300;i++)tick();

    // fill VRAM with a known pattern (64-bit word k)
    for(int k=0;k<65536;k++) VRAM[k] = ((uint64_t)(0xC0DE0000u+k)<<32) | (uint64_t)(0x1000u+k);

    int fails=0, total=0;

    // helper: expected 256-bit line for 32-bit-VIEW line `laddr`. Word w (0..7)
    // is 32-bit-view word index q = laddr*8 + w -> bank=q[20], wofs=q[19:0];
    // physical VRAM[wofs], take high 32 if bank else low 32 (refsw pvr_map32).
    auto expect_word=[&](uint32_t laddr,int w)->uint32_t{
        uint32_t q    = laddr*8 + w;
        uint32_t bank = (q>>20)&1;
        uint32_t wofs = q & 0xFFFFF;
        uint64_t phys = VRAM[wofs & 0xFFFF];   // DDR stub wraps at 64K phys words
        return bank ? (uint32_t)(phys>>32) : (uint32_t)phys;
    };

    auto check_line=[&](uint32_t laddr){
        total++;
        dut->req=1; dut->laddr=laddr; tick(); dut->req=0;
        int g=0; while(!dut->ack){ tick(); if(++g>1000){printf("TIMEOUT %u\n",laddr);exit(1);} }
        bool ok=true;
        for(int w=0; w<8; w++){
            uint32_t hw = dut->rdata[w];      // VlWide<8>: index by 32-bit word
            uint32_t ex = expect_word(laddr,w);
            if(hw!=ex){ ok=false; if(fails<8) printf("  laddr %u word %d: hw %08x exp %08x\n",laddr,w,hw,ex); }
        }
        if(!ok) fails++;
    };

    // 1) cold misses across several lines (bank 0)
    for(uint32_t l=0;l<32;l++) check_line(l);
    // 2) hits (same lines again)
    for(uint32_t l=0;l<32;l++) check_line(l);
    // 3) aliasing: line l and l+NLINE map to same slot -> forces refill each time
    for(int r=0;r<8;r++){ check_line(5); check_line(5+256); }
    // 4) BANK 1: view words >= 4MB (q bit20 set) -> laddr >= 0x20000. These read
    //    the HIGH 32 bits of the physical 64-bit words. Verifies de-interleave.
    for(uint32_t l=0x20000; l<0x20000+32; l++) check_line(l);
    // 5) spec example: physical word 0's two halves live at view word 0 (bank0,
    //    line 0 word 0) and view word 0x100000 (bank1, line 0x20000 word 0).
    check_line(0); check_line(0x20000);
    // 6) cross-bank + random sweep across both banks
    for(int i=0;i<256;i++){ uint32_t l = rnd()&0x3FF; check_line((rnd()&1)?l|0x20000:l); }

    printf("data_cache256: %d/%d passed\n", total-fails, total);
    printf(fails?"DCACHE256 FAIL\n":"DCACHE256 OK\n");
    return fails?1:0;
}

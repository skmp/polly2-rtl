// tsp_shade_pp_replay_tb - REPLAY the exact per-pixel shader input stream captured from a
// real scene (shade_pp_input.log, produced by peel_core's +shadedump) through BOTH the
// serial reference tsp_shade and the pipelined tsp_shade_pp, over the REAL scene VRAM.
//
// This bypasses plane setup entirely (planes are the recorded values) and drives the
// shade + texture-cache path with the genuine coordinate / cache-access pattern of the
// scene - the thing synthetic random/ramp batches don't reproduce. Any pp != serial here
// is a real shade-path bug on real data, with the exact failing pixel reported.
//
// Usage: ./tb <input.log> <vram.bin>   (defaults: shade_pp_input.log dumps/vram_menu2.bin)
#include "Vtsp_shade_pp_tb_top.h"
#include "Vtsp_shade_pp_tb_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <vector>

static Vtsp_shade_pp_tb_top* dut;
#define VRAM dut->rootp->tsp_shade_pp_tb_top__DOT__vram
static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

struct In {
    uint32_t id, px, py, invw, tsp, tcw, tc, ptx, pof;
    uint32_t ddx[10], ddy[10], c[10];
};

static void apply(const In& p){
    dut->px=p.px; dut->py=p.py; dut->invw_in=p.invw;
    dut->tsp=p.tsp; dut->tcw=p.tcw; dut->text_ctrl=p.tc;
    dut->pp_texture=p.ptx; dut->pp_offset=p.pof;
    dut->ddx0=p.ddx[0];dut->ddx1=p.ddx[1];dut->ddx2=p.ddx[2];dut->ddx3=p.ddx[3];dut->ddx4=p.ddx[4];
    dut->ddx5=p.ddx[5];dut->ddx6=p.ddx[6];dut->ddx7=p.ddx[7];dut->ddx8=p.ddx[8];dut->ddx9=p.ddx[9];
    dut->ddy0=p.ddy[0];dut->ddy1=p.ddy[1];dut->ddy2=p.ddy[2];dut->ddy3=p.ddy[3];dut->ddy4=p.ddy[4];
    dut->ddy5=p.ddy[5];dut->ddy6=p.ddy[6];dut->ddy7=p.ddy[7];dut->ddy8=p.ddy[8];dut->ddy9=p.ddy[9];
    dut->c0=p.c[0];dut->c1=p.c[1];dut->c2=p.c[2];dut->c3=p.c[3];dut->c4=p.c[4];
    dut->c5=p.c[5];dut->c6=p.c[6];dut->c7=p.c[7];dut->c8=p.c[8];dut->c9=p.c[9];
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    const char* inpath  = (argc>1)? argv[1] : "shade_pp_input.log";
    const char* vrampath= (argc>2)? argv[2] : "dumps/vram_menu2.bin";

    // ---- read the input log ----
    FILE* f=fopen(inpath,"r");
    if(!f){ printf("cannot open %s\n",inpath); return 2; }
    std::vector<In> pix;
    char line[2048];
    while(fgets(line,sizeof(line),f)){
        if(line[0]=='#') continue;
        In p; unsigned seq;
        int n=sscanf(line,"%u %u %u %u %x %x %x %x %u %u"
                          " %x %x %x %x %x %x %x %x %x %x"
                          " %x %x %x %x %x %x %x %x %x %x"
                          " %x %x %x %x %x %x %x %x %x %x",
            &seq,&p.id,&p.px,&p.py,&p.invw,&p.tsp,&p.tcw,&p.tc,&p.ptx,&p.pof,
            &p.ddx[0],&p.ddx[1],&p.ddx[2],&p.ddx[3],&p.ddx[4],&p.ddx[5],&p.ddx[6],&p.ddx[7],&p.ddx[8],&p.ddx[9],
            &p.ddy[0],&p.ddy[1],&p.ddy[2],&p.ddy[3],&p.ddy[4],&p.ddy[5],&p.ddy[6],&p.ddy[7],&p.ddy[8],&p.ddy[9],
            &p.c[0],&p.c[1],&p.c[2],&p.c[3],&p.c[4],&p.c[5],&p.c[6],&p.c[7],&p.c[8],&p.c[9]);
        if(n==40) pix.push_back(p);
    }
    fclose(f);
    printf("replay: %zu pixels from %s\n", pix.size(), inpath);

    dut=new Vtsp_shade_pp_tb_top;
    dut->clk=0; dut->reset=1; dut->ref_req=0; dut->pp_in_valid=0; dut->pp_in_id=0;

    // ---- load real VRAM (32-bit view -> 64-bit physical, inverse pvr_map32) ----
    FILE* vf=fopen(vrampath,"rb");
    if(!vf){ printf("cannot open %s\n",vrampath); return 2; }
    fseek(vf,0,SEEK_END); long vsz=ftell(vf); fseek(vf,0,SEEK_SET);
    std::vector<uint8_t> v(vsz); size_t rd=fread(v.data(),1,vsz,vf); fclose(vf); (void)rd;
    for(uint32_t w=0; w<1048576; w++) VRAM[w]=0;
    uint32_t nview=vsz/4;
    for(uint32_t q=0;q<nview;q++){
        uint32_t word=v[q*4]|(v[q*4+1]<<8)|(v[q*4+2]<<16)|(v[q*4+3]<<24);
        uint32_t bank=(q>>20)&1, wofs=q&0xFFFFF;
        uint64_t cur=VRAM[wofs];
        cur &= ~((uint64_t)0xFFFFFFFFu << (32*bank));
        cur |=  ((uint64_t)word) << (32*bank);
        VRAM[wofs]=cur;
    }

    for(int i=0;i<64;i++) tick();
    dut->reset=0; tick();

    // The recorded stream can repeat ids across tiles; process in windows of <=1024 with
    // unique ids so seen[]/id matching stays valid (pp_in_id is 10-bit).
    const size_t WIN=1024;
    size_t base=0; int total=0, fails=0; int shown=0;
    while(base<pix.size()){
        size_t n = std::min(WIN, pix.size()-base);

        // --- serial reference for this window ---
        std::vector<uint32_t> ref(n);
        for(size_t i=0;i<n;i++){
            apply(pix[base+i]);
            dut->ref_req=1; tick(); dut->ref_req=0;
            int guard=0;
            while(!dut->ref_done){ tick(); if(++guard>100000){printf("ref hang @%zu\n",base+i);return 3;} }
            ref[i]=dut->ref_argb; tick();
        }

        // --- pipelined dut for this window ---
        std::vector<uint32_t> got(n,0xDEADBEEF);
        std::vector<uint8_t> seen(n,0);
        size_t ii=0, on=0; int guard=0;
        dut->pp_in_valid=0;
        while(on<n){
            dut->eval();
            bool present = (ii<n) && !dut->pp_stall;
            if(present){ apply(pix[base+ii]); dut->pp_in_id=(uint16_t)ii; dut->pp_in_valid=1; }
            else dut->pp_in_valid=0;
            tick();
            if(present) ii++;
            if(dut->pp_out_valid){
                uint32_t id=dut->pp_out_id;
                if(id<n && !seen[id]){ got[id]=dut->pp_out_argb; seen[id]=1; on++; }
            }
            if(++guard>4000000){ printf("pp hang window@%zu in=%zu out=%zu\n",base,ii,on); break; }
        }
        dut->pp_in_valid=0;

        // --- compare ---
        for(size_t i=0;i<n;i++){
            total++;
            if(got[i]!=ref[i]){
                fails++;
                if(shown++<30) printf("MISMATCH seq=%zu id=%u (%u,%u) tcw=%08x tsp=%08x ptx=%u: pp=%08x ref=%08x\n",
                    base+i, pix[base+i].id, pix[base+i].px, pix[base+i].py,
                    pix[base+i].tcw, pix[base+i].tsp, pix[base+i].ptx, got[i], ref[i]);
            }
        }
        base+=n;
    }
    printf("replay: %d/%d matched\n", total-fails, total);
    printf(fails?"REPLAY FAIL\n":"REPLAY OK\n");
    return fails?1:0;
}

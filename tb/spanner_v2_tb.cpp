// spanner_v2_tb - drive spanner_v2 with a captured TSP-input vector and CHECK it.
//
// Usage:  spanner_v2_tb [<dir>] [<first>] [<count>]
//   dir   : directory holding spanner_input_<N>.txt + vram.bin + pvr_regs.bin
//           (default: spanner_test_vectors)
//   first : first pass index N to test (default 0)
//   count : how many consecutive passes to test (default 8)
//
// For each pass it:
//   1. loads the tag buffer (tim_*) + header controls from spanner_input_<N>.txt,
//   2. pulses start, ticks until busy=0 (or timeout),
//   3. recomputes the GOLDEN SPANGEN output in C++ (aligned-4 walk + pc_slot dedup) and
//      compares against span_out (id/rep/invw/shmask/at + exact set of run-start indices),
//   4. checks every ALLOCATED setup id got a triangle_setups write (tsg_valid[id]).
//
#include "Vspanner_v2_tb_top.h"
#include "Vspanner_v2_tb_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>

static Vspanner_v2_tb_top* dut;
#define ROOT dut->rootp
#define VRAM ROOT->spanner_v2_tb_top__DOT__u_sim__DOT__vram

// public arrays inside the top
#define TIM_VALID ROOT->spanner_v2_tb_top__DOT__tim_valid
#define TIM_TAG   ROOT->spanner_v2_tb_top__DOT__tim_tag
#define TIM_INVW  ROOT->spanner_v2_tb_top__DOT__tim_invw
#define TIM_PT    ROOT->spanner_v2_tb_top__DOT__tim_pt

#define SPO_VALID  ROOT->spanner_v2_tb_top__DOT__spo_valid
#define SPO_ID     ROOT->spanner_v2_tb_top__DOT__spo_id
#define SPO_REP    ROOT->spanner_v2_tb_top__DOT__spo_rep
#define SPO_INVW0  ROOT->spanner_v2_tb_top__DOT__spo_invw0
#define SPO_INVW1  ROOT->spanner_v2_tb_top__DOT__spo_invw1
#define SPO_INVW2  ROOT->spanner_v2_tb_top__DOT__spo_invw2
#define SPO_INVW3  ROOT->spanner_v2_tb_top__DOT__spo_invw3
#define SPO_SHMASK ROOT->spanner_v2_tb_top__DOT__spo_shmask
#define SPO_AT     ROOT->spanner_v2_tb_top__DOT__spo_at

#define TSG_VALID ROOT->spanner_v2_tb_top__DOT__tsg_valid

static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

// pc_slot: MUST match spanner_v2.pc_slot exactly.
static uint32_t pc_slot(uint32_t tag){
    return ((tag>>3)&0x3F) ^ (tag&0x7);
}

static uint8_t* load(const char* path, long* out_sz){
    FILE* f=fopen(path,"rb");
    if(!f){ printf("cannot open %s\n",path); exit(1); }
    fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);
    uint8_t* buf=(uint8_t*)malloc(sz);
    if(fread(buf,1,sz,f)!=(size_t)sz){ printf("short read %s\n",path); exit(1); }
    fclose(f); if(out_sz)*out_sz=sz; return buf;
}

// load the interleaved VRAM (inverse pvr_map32), same as frontend_isp_tb.cpp
static void load_vram(const char* path){
    long vsz; uint8_t* v = load(path, &vsz);
    if(vsz != 8*1024*1024) printf("warning: vram is %ld bytes (expected 8 MB)\n", vsz);
    for(uint32_t w=0; w<1048576; w++) VRAM[w]=0;
    uint32_t nview = vsz/4;
    for(uint32_t q=0; q<nview; q++){
        uint32_t word = v[q*4] | (v[q*4+1]<<8) | (v[q*4+2]<<16) | (v[q*4+3]<<24);
        uint32_t bank = (q>>20)&1;
        uint32_t wofs = q & 0xFFFFF;
        uint64_t cur = VRAM[wofs];
        cur &= ~((uint64_t)0xFFFFFFFFu << (32*bank));
        cur |=  ((uint64_t)word) << (32*bank);
        VRAM[wofs] = cur;
    }
    free(v);
}

struct Vec {
    uint32_t shade_mode, xbase, ybase, param_base, intensity, npix, tx, ty;
    uint32_t valid[1024], tag[1024], invw[1024], pt[1024];
};

// parse spanner_input_<N>.txt: 9 header words then 1024*4 record words, one 8-hex/line.
static bool load_vec(const std::string& path, Vec& vc){
    FILE* f=fopen(path.c_str(),"r");
    if(!f) return false;
    auto rd=[&](uint32_t& out)->bool{
        char line[64];
        if(!fgets(line,sizeof(line),f)) return false;
        out=(uint32_t)strtoul(line,nullptr,16);
        return true;
    };
    uint32_t magic;
    if(!rd(magic)){ fclose(f); return false; }
    if(magic!=0x53504E31){ printf("bad magic %08x in %s\n",magic,path.c_str()); fclose(f); return false; }
    rd(vc.shade_mode); rd(vc.xbase); rd(vc.ybase); rd(vc.param_base);
    rd(vc.intensity); rd(vc.npix); rd(vc.tx); rd(vc.ty);
    for(int i=0;i<1024;i++){ rd(vc.valid[i]); rd(vc.tag[i]); rd(vc.invw[i]); rd(vc.pt[i]); }
    fclose(f);
    return true;
}

// golden SPANGEN: aligned-4 walk, leading same-tag run capped at group boundary, dedup by
// pc_slot direct-mapped. Records, per run-start pixel: {id,rep,shmask,invw[4],at}.
struct Span { uint32_t idx,id,rep,shmask,at; uint32_t invw[4]; };
static void golden(const Vec& vc, std::vector<Span>& out){
    uint32_t slot_valid[64]={0}, slot_tag[64];
    int x=0;
    while(x<1024){
        int lane=x&3;
        uint32_t tag=vc.tag[x];
        int rep=1;
        uint32_t shmask=0;
        auto shok=[&](int p){ return vc.shade_mode ? 1u : (vc.valid[p]?1u:0u); };
        shmask |= shok(x)<<lane;
        // extend within the group while tag matches
        for(int l=lane+1; l<4; l++){
            if(vc.tag[(x&~3)+l]==tag){ rep++; shmask |= shok((x&~3)+l)<<l; }
            else break;
        }
        uint32_t id=pc_slot(tag);
        // dedup: allocate if slot empty or holds a different tag
        // (id is a 6-bit slot here since NSLOT hash uses [8:3]^[2:0]; but spanner uses
        //  SLOTW=10 with the same low-6 hash, so id fits 0..63)
        (void)slot_tag;
        if(!(slot_valid[id&63] && slot_tag[id&63]==tag)){
            slot_valid[id&63]=1; slot_tag[id&63]=tag;
        }
        Span s; s.idx=x; s.id=id; s.rep=rep; s.shmask=shmask; s.at=vc.pt[x];
        for(int k=0;k<4;k++) s.invw[k] = (k<rep) ? vc.invw[(x&~3)+lane+k] : 0;
        out.push_back(s);
        x += rep;
    }
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    const char* dir = (argc>1) ? argv[1] : "spanner_test_vectors";
    int first = (argc>2) ? atoi(argv[2]) : 0;
    int count = (argc>3) ? atoi(argv[3]) : 8;

    dut=new Vspanner_v2_tb_top;
    dut->clk=0; dut->reset=1;
    ROOT->spanner_v2_tb_top__DOT__start=0;

    char vpath[512]; snprintf(vpath,sizeof(vpath),"%s/vram.bin",dir);
    // reset a few cycles first so sim_ddr_fb settles, then load VRAM
    for(int i=0;i<20;i++) tick();
    load_vram(vpath);
    dut->reset=0; tick();

    int total_fail=0, total_pass=0;
    for(int n=first; n<first+count; n++){
        char vp[512]; snprintf(vp,sizeof(vp),"%s/spanner_input_%d.txt",dir,n);
        Vec vc;
        if(!load_vec(vp, vc)){ printf("pass %d: no vector (%s), stopping\n",n,vp); break; }

        // load tag buffer + controls
        for(int i=0;i<1024;i++){
            TIM_VALID[i]=vc.valid[i]&1;
            TIM_TAG[i]=vc.tag[i];
            TIM_INVW[i]=vc.invw[i];
            TIM_PT[i]=vc.pt[i]&1;
        }
        // clear result stores
        memset(&SPO_VALID[0],0,1024*sizeof(SPO_VALID[0]));
        memset(&TSG_VALID[0],0,1024*sizeof(TSG_VALID[0]));

        ROOT->spanner_v2_tb_top__DOT__shade_mode = vc.shade_mode&1;
        ROOT->spanner_v2_tb_top__DOT__xbase = vc.xbase;
        ROOT->spanner_v2_tb_top__DOT__ybase = vc.ybase;
        ROOT->spanner_v2_tb_top__DOT__param_base = vc.param_base & 0x7FFFFFF;
        ROOT->spanner_v2_tb_top__DOT__intensity_shadow = vc.intensity&1;

        // pulse start
        ROOT->spanner_v2_tb_top__DOT__start=1; tick();
        ROOT->spanner_v2_tb_top__DOT__start=0;
        long cyc=0; const long TIMEOUT=2000000;
        while(ROOT->spanner_v2_tb_top__DOT__busy){
            tick();
            if(++cyc>TIMEOUT){ printf("pass %d: TIMEOUT (busy stuck) after %ld cyc\n",n,cyc); total_fail++; goto next; }
        }
        // a couple trailing ticks so the last ts write lands
        tick(); tick();

        {
            std::vector<Span> gold;
            golden(vc, gold);

            int fails=0;
            // 1) exact set of run-start indices + payload match
            bool gstart[1024]={false};
            for(auto& s: gold){
                gstart[s.idx]=true;
                if(!SPO_VALID[s.idx]){
                    if(fails<10) printf("pass %d: MISSING span at idx %u (id=%u rep=%u)\n",n,s.idx,s.id,s.rep);
                    fails++; continue;
                }
                if(SPO_ID[s.idx]!=s.id || SPO_REP[s.idx]!=s.rep || SPO_SHMASK[s.idx]!=s.shmask
                   || SPO_AT[s.idx]!=(s.at&1)){
                    if(fails<10) printf("pass %d: span idx %u MISMATCH: got id=%u rep=%u shmask=%x at=%u  want id=%u rep=%u shmask=%x at=%u\n",
                        n,s.idx, SPO_ID[s.idx],SPO_REP[s.idx],SPO_SHMASK[s.idx],SPO_AT[s.idx],
                        s.id,s.rep,s.shmask,s.at&1);
                    fails++;
                }
                uint32_t giv[4]={SPO_INVW0[s.idx],SPO_INVW1[s.idx],SPO_INVW2[s.idx],SPO_INVW3[s.idx]};
                for(uint32_t k=0;k<s.rep;k++) if(giv[k]!=s.invw[k]){
                    if(fails<10) printf("pass %d: span idx %u invw[%u] got %08x want %08x\n",n,s.idx,k,giv[k],s.invw[k]);
                    fails++;
                }
            }
            // 2) no EXTRA spans the DUT emitted that golden didn't
            for(int i=0;i<1024;i++) if(SPO_VALID[i] && !gstart[i]){
                if(fails<10) printf("pass %d: EXTRA span at idx %d (id=%u rep=%u)\n",n,i,SPO_ID[i],SPO_REP[i]);
                fails++;
            }
            // 3) every allocated setup id got a triangle_setups write
            bool need_setup[1024]={false};
            {
                uint32_t sv[64]={0},st[64];
                int x=0;
                while(x<1024){
                    uint32_t tag=vc.tag[x]; uint32_t id=pc_slot(tag);
                    if(!(sv[id&63] && st[id&63]==tag)){ sv[id&63]=1; st[id&63]=tag; need_setup[id]=true; }
                    int lane=x&3,rep=1;
                    for(int l=lane+1;l<4;l++){ if(vc.tag[(x&~3)+l]==tag) rep++; else break; }
                    x+=rep;
                }
            }
            int n_need=0, n_written=0;
            for(int id=0;id<1024;id++){
                if(need_setup[id]) n_need++;
                if(TSG_VALID[id])  n_written++;
                if(need_setup[id] && !TSG_VALID[id]){
                    if(fails<10) printf("pass %d: setup id %d NOT written (triangle_setups miss)\n",n,id);
                    fails++;
                }
            }
            // distinct setups = distinct slots the DUT filled = golden allocation count.
            if(n_written != n_need){
                if(fails<10) printf("pass %d: setup COUNT mismatch: dut wrote %d slots, golden needs %d\n",n,n_written,n_need);
                fails++;
            }

            if(fails==0){
                uint32_t ec = ROOT->spanner_v2_tb_top__DOT__emit_count;
                uint32_t le = ROOT->spanner_v2_tb_top__DOT__last_emit_cyc;
                printf("pass %d: OK  (%zu spans, %d setups, cyc=%ld | spangen: %u spans by cyc %u -> %.2f cyc/span)\n",
                       n,gold.size(),n_written,cyc, ec, le, ec? (double)le/ec : 0.0);
                total_pass++;
            }
            else        { printf("pass %d: %d FAILURES (cyc=%ld)\n",n,fails,cyc); total_fail++; }
        }
        next:;
    }

    printf("\n==== spanner_v2 TB: %d passed, %d failed ====\n", total_pass, total_fail);
    return total_fail ? 1 : 0;
}

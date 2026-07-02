// isp_setup_streamed unit test: feed random triangles through both the streaming
// DUT and the reference isp_setup_min; check every DUT plane-set is bit-exact to
// the reference for the same triangle (matched by tag = triangle index).
#include "Visp_setup_streamed_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

static Visp_setup_streamed_tb_top* dut;
static void ev(){ dut->eval(); }
static void tick(){ dut->clk=0; ev(); dut->clk=1; ev(); }

// a captured plane-set
struct Planes {
    uint32_t dx12,dx23,dx31, dy12,dy23,dy31, c1,c2,c3, ddx,ddy,cinvw;
    uint32_t bx0,bx1,by0,by1, cull;
    bool operator==(const Planes&o)const{
        if (cull!=o.cull) return false;
        if (cull) return true;   // culled: planes/bbox are don't-care, only cull matters
        return dx12==o.dx12&&dx23==o.dx23&&dx31==o.dx31&&
               dy12==o.dy12&&dy23==o.dy23&&dy31==o.dy31&&
               c1==o.c1&&c2==o.c2&&c3==o.c3&&
               ddx==o.ddx&&ddy==o.ddy&&cinvw==o.cinvw&&
               bx0==o.bx0&&bx1==o.bx1&&by0==o.by0&&by1==o.by1;
    }
};
static Planes grab_ref(){
    Planes p; p.dx12=dut->ref_dx12;p.dx23=dut->ref_dx23;p.dx31=dut->ref_dx31;
    p.dy12=dut->ref_dy12;p.dy23=dut->ref_dy23;p.dy31=dut->ref_dy31;
    p.c1=dut->ref_c1;p.c2=dut->ref_c2;p.c3=dut->ref_c3;
    p.ddx=dut->ref_ddx;p.ddy=dut->ref_ddy;p.cinvw=dut->ref_cinvw;
    p.bx0=dut->ref_bx0;p.bx1=dut->ref_bx1;p.by0=dut->ref_by0;p.by1=dut->ref_by1;
    p.cull=dut->ref_cull; return p;
}
static Planes grab_dut(){
    Planes p; p.dx12=dut->dut_dx12;p.dx23=dut->dut_dx23;p.dx31=dut->dut_dx31;
    p.dy12=dut->dut_dy12;p.dy23=dut->dut_dy23;p.dy31=dut->dut_dy31;
    p.c1=dut->dut_c1;p.c2=dut->dut_c2;p.c3=dut->dut_c3;
    p.ddx=dut->dut_ddx;p.ddy=dut->dut_ddy;p.cinvw=dut->dut_cinvw;
    p.bx0=dut->dut_bx0;p.bx1=dut->dut_bx1;p.by0=dut->dut_by0;p.by1=dut->dut_by1;
    p.cull=dut->dut_cull; return p;
}

// float bits helpers
static uint32_t fb(float f){ uint32_t u; memcpy(&u,&f,4); return u; }
static float    frand(uint32_t& s, float lo, float hi){
    s = s*1664525u + 1013904223u;
    float t = (s>>8)/16777216.0f; return lo + t*(hi-lo);
}

struct Tri { uint32_t isp, x1,y1,z1,x2,y2,z2,x3,y3,z3,xb,yb; };

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Visp_setup_streamed_tb_top;
    dut->clk=0; dut->reset=1;
    dut->ref_start=0; dut->dut_in_valid=0;
    for(int i=0;i<8;i++) tick();
    dut->reset=0; tick();

    const int N = 500;
    std::vector<Tri> tris(N);
    uint32_t seed=12345;
    for(int i=0;i<N;i++){
        Tri& t=tris[i];
        // Randomize isp_word: vary CullMode[28:27] (exercises early-cull path,
        // which interleaves with normal triangles across the 4 slots), plus
        // DepthMode/Gouraud bits. This is what the real scene does and what the
        // old isp=0 test missed.
        seed = seed*1664525u + 1013904223u;
        uint32_t cull_mode = (seed>>13) & 3;       // [28:27]
        uint32_t depth_mode = (seed>>17) & 7;      // [31:29]
        t.isp = (depth_mode<<29) | (cull_mode<<27) | (((seed>>7)&1)<<23 /*gouraud*/);
        float ox=frand(seed,0,600), oy=frand(seed,0,440);
        t.xb=fb(ox); t.yb=fb(oy);
        // vary winding both ways so both cull-mode senses trigger culls on ~half
        t.x1=fb(ox+frand(seed,0,32)); t.y1=fb(oy+frand(seed,0,32)); t.z1=fb(frand(seed,0.1f,4.f));
        t.x2=fb(ox+frand(seed,0,32)); t.y2=fb(oy+frand(seed,0,32)); t.z2=fb(frand(seed,0.1f,4.f));
        t.x3=fb(ox+frand(seed,0,32)); t.y3=fb(oy+frand(seed,0,32)); t.z3=fb(frand(seed,0.1f,4.f));
    }

    // ---- 1) reference: run each triangle single-shot, record planes ----
    std::vector<Planes> refp(N);
    auto load = [&](const Tri&t){
        dut->isp_word=t.isp; dut->x1=t.x1;dut->y1=t.y1;dut->z1=t.z1;
        dut->x2=t.x2;dut->y2=t.y2;dut->z2=t.z2; dut->x3=t.x3;dut->y3=t.y3;dut->z3=t.z3;
        dut->xbase=t.xb; dut->ybase=t.yb;
    };
    for(int i=0;i<N;i++){
        load(tris[i]); dut->in_tag=i;
        dut->ref_start=1; tick(); dut->ref_start=0;
        int guard=0; while(!dut->ref_done && guard++<200) tick();
        if(!dut->ref_done){ printf("REF timeout tri %d\n",i); return 1; }
        refp[i]=grab_ref();
        tick();
    }

    // ---- 2) DUT: stream all triangles, collect tagged outputs ----
    // Exercise BACKPRESSURE on BOTH sides: randomly deassert in_valid (bubbles) and
    // randomly deassert out_ready (consumer stalls). Correct handling must lose no
    // triangle and produce each exactly once, bit-exact to the reference.
    std::vector<Planes> dutp(N); std::vector<int> got(N,0);
    int next_in=0, n_out=0, cyc=0; uint32_t bs=99991;
    while(n_out<N && cyc++<2000000){
        // random input bubbles: sometimes don't present a triangle even if available
        bs = bs*1664525u + 1013904223u;
        bool present = (next_in<N) && ((bs>>16)&3)!=0;   // ~75% present
        load(present?tris[next_in]:tris[0]);
        dut->in_tag = present?next_in:0;
        dut->dut_in_valid = present;
        // random consumer stalls on the output
        bs = bs*1664525u + 1013904223u;
        dut->dut_out_ready = ((bs>>16)&3)!=0;            // ~75% ready
        // sample outputs BEFORE tick (combinational on current state), then tick
        ev();
        if(dut->dut_in_valid && dut->dut_in_ready) next_in++;
        if(dut->dut_out_valid){   // out_valid only asserts when it retired (ready gated)
            int tg=dut->dut_out_tag;
            if(tg<0||tg>=N){ printf("bad out_tag %d\n",tg); return 1; }
            dutp[tg]=grab_dut(); got[tg]++; n_out++;
        }
        tick();
    }
    dut->dut_in_valid=0;
    if(n_out<N){ printf("DUT produced only %d/%d outputs (deadlock?)\n",n_out,N); return 1; }

    // ---- 3) compare ----
    int fails=0;
    for(int i=0;i<N;i++){
        if(got[i]!=1){ printf("tri %d: got %d outputs\n",i,got[i]); fails++; continue; }
        if(!(dutp[i]==refp[i])){
            if(fails<8){
                printf("MISMATCH tri %d:\n",i);
                printf("  dx12 ref=%08x dut=%08x\n",refp[i].dx12,dutp[i].dx12);
                printf("  c1   ref=%08x dut=%08x\n",refp[i].c1,dutp[i].c1);
                printf("  ddx  ref=%08x dut=%08x\n",refp[i].ddx,dutp[i].ddx);
                printf("  cinvw ref=%08x dut=%08x\n",refp[i].cinvw,dutp[i].cinvw);
                printf("  bbox ref=%d,%d,%d,%d dut=%d,%d,%d,%d\n",
                    refp[i].bx0,refp[i].bx1,refp[i].by0,refp[i].by1,
                    dutp[i].bx0,dutp[i].bx1,dutp[i].by0,dutp[i].by1);
            }
            fails++;
        }
    }
    printf("isp_setup_streamed: %d/%d passed\n", N-fails, N);
    delete dut;
    return fails?1:0;
}

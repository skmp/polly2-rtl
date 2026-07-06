// tex_addroffsgen_ib equivalence test: the ROM+tail pipelined offset generator vs the
// original tex_addr Morton twiddle loop (golden), across all sizes + sampled coords.
#include "Vtex_addroffsgen_ib.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static Vtex_addroffsgen_ib* d;
static void tick(){ d->clk=0; d->eval(); d->clk=1; d->eval(); }

// golden: original tex_addr twiddle loop (sizes = 1<<U, 1<<V).
static uint32_t tw_mono(int u,int v,int U,int V){
    int sx0=1<<U, sy0=1<<V, tw=0, sh=0, xr=u, yr=v, sx=sx0>>1, sy=sy0>>1;
    for(int i=0;i<11;i++){
        if(sy){ tw|=(yr&1)<<sh; yr>>=1; sy>>=1; sh++; }
        if(sx){ tw|=(xr&1)<<sh; xr>>=1; sx>>=1; sh++; }
    }
    return tw;
}
static uint32_t lin(int u,int v,int stride){ return (uint32_t)(u + stride*v); }

int main(int c,char**v){
    Verilated::commandArgs(c,v);
    d=new Vtex_addroffsgen_ib;
    d->reset=1; d->stall=0; d->in_valid=0; tick(); tick(); d->reset=0;

    int fails=0,total=0;
    for(int tw=0; tw<2; tw++){
      for(int U=0;U<=10;U++) for(int V=0;V<=10;V++){
        int sx=1<<U, sy=1<<V;
        int stride = sx;                       // typical stride = row width
        for(int iu=0; iu<sx; iu += (sx>15?sx/7:1))
        for(int iv=0; iv<sy; iv += (sy>15?sy/7:1)){
            // the 4 corners share u0,u1,v0,v1
            int u0=iu, u1=(iu+1)&(sx-1), v0=iv, v1=(iv+1)&(sy-1);
            d->u_log2=U; d->v_log2=V; d->stride=stride; d->twiddled=tw;
            d->u0=u0; d->u1=u1; d->v0=v0; d->v1=v1; d->in_valid=1;
            tick();                            // clock the ROM-read register
            d->in_valid=0; d->eval();
            // corner order: 0=(u1,v1) 1=(u0,v1) 2=(u1,v0) 3=(u0,v0)
            int cu[4]={u1,u0,u1,u0}, cv[4]={v1,v1,v0,v0};
            for(int k=0;k<4;k++){
                uint32_t got=d->offset[k];
                uint32_t exp= tw ? tw_mono(cu[k],cv[k],U,V) : lin(cu[k],cv[k],stride);
                exp &= (1u<<21)-1;
                total++;
                if(got!=exp){ fails++; if(fails<12)
                    printf("  tw%d U%d V%d c%d (u%d,v%d): got %05x exp %05x\n",
                           tw,U,V,k,cu[k],cv[k],got,exp); }
            }
        }
      }
    }
    printf("tex_addroffsgen_ib: %d/%d passed\n", total-fails, total);
    printf(fails?"ADDROFFS FAIL\n":"ADDROFFS OK\n");
    return fails?1:0;
}

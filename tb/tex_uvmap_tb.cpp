#include "Vtex_uvmap.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>

static uint32_t rng=0xBEEF1234;
static uint32_t rnd(){uint32_t x=rng;x^=x<<13;x^=x>>17;x^=x<<5;rng=x;return x;}
static uint32_t f2b(float f){uint32_t u;memcpy(&u,&f,4);return u;}

// refsw ClampFlip
static int clampflip(int clamp,int flip,int coord,int size){
    if(clamp){ if(coord<0)coord=0; else if(coord>=size)coord=size-1; }
    else if(flip){ coord &= size*2-1; if(coord&size) coord ^= size*2-1; }
    else { coord &= size-1; }
    return coord;
}

int main(int c,char**v){
    Verilated::commandArgs(c,v);
    auto*d=new Vtex_uvmap;
    int fails=0,total=0;
    // all 16 clamp/flip combos, 96 random (u,v,texu,texv) each - INCLUDING
    // negative and large UVs (wrap/flip must handle negatives: e.g. daytona road
    // has V ~ -6..-8; the float->fixed step must NOT clamp negatives to 0).
    for(int mode=0;mode<16;mode++){
      int clampu=(mode>>0)&1, clampv=(mode>>1)&1, flipu=(mode>>2)&1, flipv=(mode>>3)&1;
      for(int i=0;i<96;i++){
        int texu=rnd()%8, texv=rnd()%8;
        int sizeU=8<<texu, sizeV=8<<texv;
        // u,v in [-16, +16): spans negatives, sub-1, and many wrap periods.
        float fu = (float)((int)(rnd()%32768) - 16384)/1024.0f;  // -16..~16
        float fv = (float)((int)(rnd()%32768) - 16384)/1024.0f;
        d->u=f2b(fu); d->v=f2b(fv); d->texu=texu; d->texv=texv;
        d->clampu=clampu; d->clampv=clampv; d->flipu=flipu; d->flipv=flipv; d->eval();

        // ref: ui = fu*sizeU*256 (truncate), texel = ui>>8, frac = ui&255
        long ui=(long)(fu*sizeU*256.0f), vi=(long)(fv*sizeV*256.0f);
        int u0=ui>>8, v0=vi>>8, u1=u0+1, v1=v0+1;
        int r_c00u=clampflip(clampu,flipu,u1,sizeU), r_c00v=clampflip(clampv,flipv,v1,sizeV);
        int r_c01u=clampflip(clampu,flipu,u0,sizeU), r_c01v=clampflip(clampv,flipv,v1,sizeV);
        int r_c10u=clampflip(clampu,flipu,u1,sizeU), r_c10v=clampflip(clampv,flipv,v0,sizeV);
        int r_c11u=clampflip(clampu,flipu,u0,sizeU), r_c11v=clampflip(clampv,flipv,v0,sizeV);
        int r_uf=ui&255, r_vf=vi&255;
        total++;
        bool ok = (int)d->c00u==r_c00u&&(int)d->c00v==r_c00v&&(int)d->c01u==r_c01u&&(int)d->c01v==r_c01v
                &&(int)d->c10u==r_c10u&&(int)d->c10v==r_c10v&&(int)d->c11u==r_c11u&&(int)d->c11v==r_c11v;
        // fraction tolerance +-1 (float->fixed rounding)
        int dfu=abs((int)d->ufrac-r_uf), dfv=abs((int)d->vfrac-r_vf);
        if(!ok || dfu>1 || dfv>1){
            fails++;
            if(fails<12) printf("  m%x tu%d tv%d fu%.3f fv%.3f: c11(%d,%d)/(%d,%d) frac(%d,%d)/(%d,%d)\n",
              mode,texu,texv,fu,fv,(int)d->c11u,(int)d->c11v,r_c11u,r_c11v,(int)d->ufrac,(int)d->vfrac,r_uf,r_vf);
        }
      }
    }
    // ---- GOLDEN REPLAY: real captured tex_uvmap vectors from a scene (menu2).
    // Each line: attrU attrV tsp tcw mip  c00u c00v c01u c01v c10u c10v c11u c11v ufrac vfrac
    // (attrU/attrV are the interpolated U/V floats fed to the module; tsp carries
    // texu/texv[5:0] + clamp/flip[18:15]). This pins the module to bit-exact outputs on
    // REAL scene coordinates, catching regressions the random sweep above can miss.
    {
        FILE* f = fopen("tb/vectors/uv_menu2.txt","r");
        if(!f){ printf("  (skip golden replay: tb/vectors/uv_menu2.txt not found)\n"); }
        else {
            unsigned au,av,tsp,tcw; int mip;
            int e00u,e00v,e01u,e01v,e10u,e10v,e11u,e11v,euf,evf;
            int gtot=0, gfail=0;
            while(fscanf(f,"%x %x %x %x %d %d %d %d %d %d %d %d %d %d %d",
                         &au,&av,&tsp,&tcw,&mip,
                         &e00u,&e00v,&e01u,&e01v,&e10u,&e10v,&e11u,&e11v,&euf,&evf)==15){
                int texu=(tsp>>3)&7, texv=tsp&7;
                int clampv=(tsp>>15)&1, clampu=(tsp>>16)&1, flipv=(tsp>>17)&1, flipu=(tsp>>18)&1;
                d->u=au; d->v=av; d->texu=texu; d->texv=texv;
                d->clampu=clampu; d->clampv=clampv; d->flipu=flipu; d->flipv=flipv;
                d->miplevel=mip; d->eval();
                gtot++;
                bool ok = (int)d->c00u==e00u&&(int)d->c00v==e00v&&(int)d->c01u==e01u&&(int)d->c01v==e01v
                        &&(int)d->c10u==e10u&&(int)d->c10v==e10v&&(int)d->c11u==e11u&&(int)d->c11v==e11v
                        &&(int)d->ufrac==euf&&(int)d->vfrac==evf;
                if(!ok){
                    gfail++;
                    if(gfail<12) printf("  GOLDEN u=%08x v=%08x tsp=%08x mip=%d: "
                        "c11 rtl(%d,%d) exp(%d,%d) frac rtl(%d,%d) exp(%d,%d)\n",
                        au,av,tsp,mip,(int)d->c11u,(int)d->c11v,e11u,e11v,
                        (int)d->ufrac,(int)d->vfrac,euf,evf);
                }
            }
            fclose(f);
            printf("tex_uvmap golden(menu2): %d/%d passed\n", gtot-gfail, gtot);
            total+=gtot; fails+=gfail;
        }
    }

    printf("tex_uvmap: %d/%d passed\n", total-fails, total);
    printf(fails?"UV FAIL\n":"UV OK\n");
    return fails?1:0;
}

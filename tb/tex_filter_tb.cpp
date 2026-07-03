// tex_filter vs refsw TextureFilter (nearest + bilinear + ignore_texa).
#include "Vtex_filter.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static int ch(uint32_t c,int i){return (c>>(8*i))&0xFF;}
static int sat8(int r){return r<0?0:(r>255?255:r);}
// delta-form lerp, matches tex_filter:  p + ((q-p)*w) >> 8  (w raw 0..255).
// signed >>8 is arithmetic (toward -inf), same as the RTL >>>8.
static int lerp8(int p,int q,int w){ int d=q-p; return sat8(p + ((d*w) >> 8)); }
static uint32_t g_filter(int fm,bool ita,int ufrac,int vfrac,uint32_t t00,uint32_t t01,uint32_t t10,uint32_t t11){
    uint32_t out;
    if(fm==0){ out=t11; }
    else {
        int r[4];
        for(int i=0;i<4;i++){
            int a=lerp8(ch(t01,i),ch(t00,i),ufrac);   // v+1 row along u: p=u+0(t01),q=u+1(t00)
            int b=lerp8(ch(t11,i),ch(t10,i),ufrac);   // v+0 row along u: p=u+0(t11),q=u+1(t10)
            r[i]=lerp8(b,a,vfrac);                    // along v: p=v+0(b),q=v+1(a)
        }
        out=(r[3]<<24)|(r[2]<<16)|(r[1]<<8)|r[0];
    }
    if(ita) out=(out&0x00FFFFFF)|0xFF000000;
    return out;
}
static uint32_t rng=0x33445566;
static uint32_t rnd(){uint32_t x=rng;x^=x<<13;x^=x>>17;x^=x<<5;rng=x;return x;}

int main(int c,char**v){
    Verilated::commandArgs(c,v);
    auto*d=new Vtex_filter;
    int fails=0,total=0;
    for(int fm=0;fm<2;fm++)for(int ita=0;ita<2;ita++)
      for(int i=0;i<64;i++){
        uint32_t t00=rnd(),t01=rnd(),t10=rnd(),t11=rnd();
        int uf=rnd()&255, vf=rnd()&255;
        d->filter=fm;d->ignore_texa=ita;d->ufrac=uf;d->vfrac=vf;
        d->t00=t00;d->t01=t01;d->t10=t10;d->t11=t11;d->eval();
        uint32_t g=g_filter(fm,ita,uf,vf,t00,t01,t10,t11); total++;
        uint32_t hw=d->textel;
        // bit-exact: golden uses the same delta-form lerp as the RTL.
        int tol = 0;
        bool ok=true;
        for(int cci=0;cci<4;cci++){
            int dh=(int)((hw>>(8*cci))&0xFF)-(int)((g>>(8*cci))&0xFF);
            if(dh<0)dh=-dh; if(dh>tol) ok=false;
        }
        if(!ok){fails++;if(fails<10)printf("  fm%d ita%d uf%d vf%d -> %08x exp %08x\n",fm,ita,uf,vf,hw,g);}
      }
    printf("tex_filter: %d/%d passed\n",total-fails,total);
    printf(fails?"FILTER FAIL\n":"FILTER OK\n");
    return fails?1:0;
}

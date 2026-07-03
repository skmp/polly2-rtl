// color_combiner vs refsw ColorCombiner (texenv). Exhaustive over tex/offset/
// ShadInstr x a sweep of base/textel/offset colours.
#include "Vcolor_combiner.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static int sat8(int r){return r<0?0:(r>255?255:r);}
// delta-form combine, matches color_combiner: r = sub + ((mA-sub)*w8) >> 8
// raw 8-bit weight, arithmetic >>8, saturate. (No u8_256 *256/256 scaling.)
static int comb(int mA,int sub,int w8){ int d=mA-sub; return sat8(sub + ((d*w8)>>8)); }
static uint32_t g_combiner(bool tex,bool ofs,int si,uint32_t base,uint32_t textel,uint32_t offset){
    if(!tex) return base;
    auto B=[&](uint32_t c,int i){return (int)((c>>(8*i))&0xFF);};
    int r[4];
    for(int i=0;i<4;i++) r[i]=B(base,i);
    if(si==0){ for(int i=0;i<4;i++) r[i]=B(textel,i); }                              // replace
    else if(si==1){ for(int i=0;i<3;i++) r[i]=comb(B(textel,i),0,B(base,i)); r[3]=B(textel,3); } // modulate rgb, a=tex
    else if(si==2){ for(int i=0;i<3;i++) r[i]=comb(B(textel,i),B(base,i),B(textel,3)); r[3]=B(base,3);} // mix, a=base
    else { for(int i=0;i<4;i++) r[i]=comb(B(textel,i),0,B(base,i)); }                // modulate all
    if(ofs){ for(int i=0;i<3;i++){ r[i]=r[i]+B(offset,i); if(r[i]>255)r[i]=255; } }
    return (r[3]<<24)|(r[2]<<16)|(r[1]<<8)|r[0];
}
static uint32_t rng=0x5A5A1234;
static uint32_t rnd(){uint32_t x=rng;x^=x<<13;x^=x>>17;x^=x<<5;rng=x;return x;}

int main(int c,char**v){
    Verilated::commandArgs(c,v);
    auto*d=new Vcolor_combiner;
    int fails=0,total=0;
    for(int t=0;t<2;t++)for(int o=0;o<2;o++)for(int si=0;si<4;si++)
      for(int i=0;i<64;i++){
        uint32_t bs=rnd(),tx=rnd(),of=rnd();
        d->pp_texture=t;d->pp_offset=o;d->shadinstr=si;d->base=bs;d->textel=tx;d->offset=of;d->eval();
        uint32_t g=g_combiner(t,o,si,bs,tx,of); total++;
        if((uint32_t)d->col!=g){fails++;if(fails<10)printf("  t%d o%d si%d %08x/%08x/%08x -> %08x exp %08x\n",t,o,si,bs,tx,of,(uint32_t)d->col,g);}
      }
    printf("color_combiner: %d/%d passed\n",total-fails,total);
    printf(fails?"COMBINER FAIL\n":"COMBINER OK\n");
    return fails?1:0;
}

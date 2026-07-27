// tex_decode YUV422 vs nullDC-v1 YUV422 (drkPvr TexCache.h formula + convYUV_TW/_PL
// byte-lane layouts).
//   R = Y + Yv*11/8 ; G = Y - (Yu*11 + Yv*22)/32 ; B = Y + Yu*110/64   (C division,
//   truncation toward zero), clamp 0..255, A=0xFF.
// Byte lanes: Y = m8[2*(off&3)+1] (texel's own 16-bit lane, both layouts); chroma:
//   twiddled (64b = 2x2 quad [U|Y00][U'|Y01][V|Y10][V'|Y11], per-16b-texel twiddle):
//     U = m8[2*(off&1)], V = m8[2*(off&1)+4]     (off bit0 = y parity)
//   planar (raster UYVY pairs):
//     U = m8[2*(off&2)], V = m8[2*(off&2)+2]     (off bit1 = pair select)
// (The original refsw DecodeTextel contract - word32[off&1], Y=b[1+(off&2)] - picked
//  wrong bytes for ~half the texels in BOTH layouts; fixed in refsw + RTL together.)
// Phase 1: exhaustive 2^24 (Y,U,V) sweep, offset+twiddled cycling.
// Phase 2: random 64-bit memtel x all 4 offsets x twiddled 0/1 (lane-select check).
// Vectors stream back-to-back through the 3-cycle pipeline; expected FIFO checks
// in-order output and the latency itself.
#include "Vtex_decode.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static uint32_t rng=0xDEC0DE01;
static uint32_t rnd(){uint32_t x=rng;x^=x<<13;x^=x>>17;x^=x<<5;rng=x;return x;}

static uint8_t clamp8(int v){return v<0?0:(v>255?255:v);}
// nullDC-v1 YUV422<PixelPacker> verbatim (drkPvr TexCache.h:208)
static uint32_t ref_yuv422(int Y,int Yu,int Yv){
    Yu-=128; Yv-=128;
    int R = Y + Yv*11/8;
    int G = Y - (Yu*11 + Yv*22)/32;
    int B = Y + Yu*110/64;
    return 0xFF000000u | (clamp8(R)<<16) | (clamp8(G)<<8) | clamp8(B);
}
// byte-lane select per nullDC convYUV_TW (twiddled) / convYUV_PL (planar)
static uint32_t ref_decode(uint64_t memtel,int offset,int twiddled){
    const uint8_t* m8=(const uint8_t*)&memtel;
    int Y = m8[2*(offset&3)+1];
    int Yu,Yv;
    if(twiddled){ Yu=m8[2*(offset&1)];  Yv=m8[2*(offset&1)+4]; }
    else        { Yu=m8[2*(offset&2)];  Yv=m8[2*(offset&2)+2]; }
    return ref_yuv422(Y,Yu,Yv);
}

// expected FIFO (pipeline is in-order, no stall)
#define QN 16
static uint32_t expq[QN]; static uint64_t expcyc[QN]; static int qh=0,qt=0;

static Vtex_decode* d;
static uint64_t cyc=0;
static int fails=0; static long total=0;
static long lat_checked=0;

static void step(void){
    d->clk=1; d->eval();
    d->clk=0; d->eval();
    cyc++;
    if(d->out_valid){
        if(qh==qt){ if(fails++<10) printf("  cyc%llu: spurious out_valid\n",(unsigned long long)cyc); return; }
        uint32_t exp=expq[qt&(QN-1)]; uint64_t incyc=expcyc[qt&(QN-1)]; qt++;
        total++;
        if((uint32_t)d->argb!=exp){
            fails++;
            if(fails<10) printf("  cyc%llu: argb %08x exp %08x\n",(unsigned long long)cyc,(uint32_t)d->argb,exp);
        }
        // latency: in_valid at cycle N -> out_valid 3 posedges later
        if(cyc-incyc!=3){
            fails++;
            if(lat_checked++<4) printf("  cyc%llu: latency %llu != 3\n",(unsigned long long)cyc,(unsigned long long)(cyc-incyc));
        }
    }
}
static void feed(uint64_t memtel,int offset,int twiddled){
    d->in_valid=1; d->memtel=memtel; d->offset=offset; d->twiddled=twiddled;
    expq[qh&(QN-1)]=ref_decode(memtel,offset,twiddled); expcyc[qh&(QN-1)]=cyc; qh++;
    step();
}
static void drain(void){ d->in_valid=0; for(int i=0;i<8;i++) step(); }

int main(int c,char**v){
    Verilated::commandArgs(c,v);
    d=new Vtex_decode;
    d->pixfmt=3; d->pal_fmt=0; d->scan_order=0; d->palsel=0; d->pal_data=0;
    d->in_valid=0; d->reset=1; for(int i=0;i<4;i++) step(); d->reset=0;

    // ---- phase 1: exhaustive (Y,U,V); memtel built so every offset decodes (y,u,v)
    //      in the driven layout; offset and twiddled cycle across the sweep ----
    for(uint32_t y=0;y<256;y++)
      for(uint32_t u=0;u<256;u++)
        for(uint32_t vv=0;vv<256;vv++){
            int tw=(y^u^vv)&1;
            uint16_t lu=(y<<8)|u, lv=(y<<8)|vv;
            uint64_t m = tw ? ((uint64_t)lv<<48)|((uint64_t)lv<<32)|((uint64_t)lu<<16)|lu   // [U|Y][U|Y][V|Y][V|Y]
                            : ((uint64_t)lv<<48)|((uint64_t)lu<<32)|((uint64_t)lv<<16)|lu;  // [U|Y][V|Y][U|Y][V|Y]
            feed(m,(y+u+vv)&3,tw);
        }
    drain();
    printf("tex_decode yuv exhaustive: %ld vectors, %d fails\n",total,fails);

    // ---- phase 2: random memtel, all 4 offsets x twiddled 0/1 (distinct bytes) ----
    long p1=total;
    for(int i=0;i<100000;i++){
        uint64_t m=((uint64_t)rnd()<<32)|rnd();
        for(int of=0;of<8;of++) feed(m,of&3,of>>2);
    }
    drain();
    printf("tex_decode yuv lane-select: %ld vectors, %d fails total\n",total-p1,fails);

    printf("tex_decode: %ld/%ld passed\n",total-fails,total);
    printf(fails?"DECODE FAIL\n":"DECODE OK\n");
    return fails?1:0;
}

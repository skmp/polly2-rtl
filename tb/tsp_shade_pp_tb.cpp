// tsp_shade_pp_tb - verify the fully-pipelined tsp_shade_pp is bit-identical to
// the serial tsp_shade over the same VRAM + per-pixel inputs.
//
// For a batch (fixed planes/tsp/tcw, varying px/py/invw): first run the serial
// reference on each pixel and record ARGB; then stream the SAME pixels through
// the pipelined DUT (respecting `stall`) and match by id.
#include "Vtsp_shade_pp_tb_top.h"
#include "Vtsp_shade_pp_tb_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

static Vtsp_shade_pp_tb_top* dut;
#define VRAM dut->rootp->tsp_shade_pp_tb_top__DOT__vram
static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

static uint32_t rng=0x1234abcd;
static uint32_t rnd(){uint32_t x=rng;x^=x<<13;x^=x>>17;x^=x<<5;rng=x;return x;}

// set all 10 planes (flat wires) + scalar config
struct Cfg {
    uint32_t ddx[10], ddy[10], c[10];
    uint32_t tsp, tcw, text_ctrl, pp_texture, pp_offset;
};
static void apply_cfg(const Cfg&g){
    dut->ddx0=g.ddx[0];dut->ddx1=g.ddx[1];dut->ddx2=g.ddx[2];dut->ddx3=g.ddx[3];dut->ddx4=g.ddx[4];
    dut->ddx5=g.ddx[5];dut->ddx6=g.ddx[6];dut->ddx7=g.ddx[7];dut->ddx8=g.ddx[8];dut->ddx9=g.ddx[9];
    dut->ddy0=g.ddy[0];dut->ddy1=g.ddy[1];dut->ddy2=g.ddy[2];dut->ddy3=g.ddy[3];dut->ddy4=g.ddy[4];
    dut->ddy5=g.ddy[5];dut->ddy6=g.ddy[6];dut->ddy7=g.ddy[7];dut->ddy8=g.ddy[8];dut->ddy9=g.ddy[9];
    dut->c0=g.c[0];dut->c1=g.c[1];dut->c2=g.c[2];dut->c3=g.c[3];dut->c4=g.c[4];
    dut->c5=g.c[5];dut->c6=g.c[6];dut->c7=g.c[7];dut->c8=g.c[8];dut->c9=g.c[9];
    dut->tsp=g.tsp; dut->tcw=g.tcw; dut->text_ctrl=g.text_ctrl;
    dut->pp_texture=g.pp_texture; dut->pp_offset=g.pp_offset;
}

struct Pix { uint8_t px, py; uint32_t invw; uint32_t tcw=0, tsp=0; uint8_t ovr=0; };

int total=0, fails=0;

// apply a per-pixel tcw/tsp override on top of the batch cfg (for mixed streams)
static void apply_px(const Cfg&g, const Pix&p){
    dut->tcw = p.ovr ? p.tcw : g.tcw;
    dut->tsp = p.ovr ? p.tsp : g.tsp;
}

static void run_batch(const char* name, const Cfg&g, std::vector<Pix>&pix){
    // --- serial reference: argb per pixel ---
    std::vector<uint32_t> ref(pix.size());
    apply_cfg(g);
    for(size_t i=0;i<pix.size();i++){
        apply_px(g, pix[i]);
        dut->px=pix[i].px; dut->py=pix[i].py; dut->invw_in=pix[i].invw;
        dut->ref_req=1; tick(); dut->ref_req=0;
        int guard=0;
        while(!dut->ref_done){ tick(); if(++guard>10000){printf("[%s] ref hang\n",name);return;} }
        ref[i]=dut->ref_argb;
        tick();
    }

    // --- pipelined dut: stream the same pixels; collect by id ---
    std::vector<uint32_t> got(pix.size(), 0xDEADBEEF);
    std::vector<uint8_t>  seen(pix.size(), 0);
    apply_cfg(g);
    size_t in_i=0, out_n=0;
    int guard=0;
    dut->pp_in_valid=0;
    while(out_n < pix.size()){
        // Evaluate combinational outputs (incl. pp_stall) for the CURRENT state
        // before deciding what to drive, so the TB samples the same stall the DUT
        // will sample at the coming edge.
        dut->eval();
        bool stalled = dut->pp_stall;
        bool present = (in_i < pix.size()) && !stalled;
        if(present){
            apply_px(g, pix[in_i]);
            dut->px=pix[in_i].px; dut->py=pix[in_i].py; dut->invw_in=pix[in_i].invw;
            dut->pp_in_id=(uint16_t)in_i;
            dut->pp_in_valid=1;
        } else {
            dut->pp_in_valid=0;
        }
        tick();
        if(present) in_i++;   // the DUT consumed it this edge
        // registered outputs reflect the edge just taken; dedup via seen[].
        // NOTE streaming DUT: out_valid is a clean 1-cycle pulse INDEPENDENT of stall
        // (the back-end drains while the front may be stalled on a texture miss), so
        // we consume it whenever high - NOT gated on !pp_stall (the old frozen-pipe
        // contract). Gating on !stall would drop results that emerge during a miss.
        if(dut->pp_out_valid){
            uint32_t id=dut->pp_out_id;
            if(id<pix.size() && !seen[id]){ got[id]=dut->pp_out_argb; seen[id]=1; out_n++; }
        }
        if(++guard > 2000000){ printf("[%s] pp hang: in=%zu out=%zu\n",name,in_i,out_n); break; }
    }
    dut->pp_in_valid=0;

    // --- compare ---
    for(size_t i=0;i<pix.size();i++){
        total++;
        if(got[i]!=ref[i]){
            fails++;
            if(fails<20) printf("[%s] pix%zu (%d,%d) invw=%08x: pp=%08x ref=%08x\n",
                name,i,pix[i].px,pix[i].py,pix[i].invw,got[i],ref[i]);
        }
    }
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Vtsp_shade_pp_tb_top;
    dut->clk=0; dut->reset=1;
    dut->ref_req=0; dut->pp_in_valid=0; dut->pp_in_id=0;
    // fill VRAM with pseudo-random texel data
    for(uint32_t i=0;i<1048576;i++) VRAM[i]=((uint64_t)rnd()<<32)|rnd();
    for(int i=0;i<8;i++) tick();
    dut->reset=0; tick();

    // helper: a plausible plane set (small gradients around a base)
    auto mkcfg=[&](uint32_t tcw, uint32_t tsp, uint32_t ptx, uint32_t pof)->Cfg{
        Cfg g; memset(&g,0,sizeof(g));
        for(int k=0;k<10;k++){
            g.ddx[k]=0x3a000000 | (rnd()&0x000fffff);  // ~small
            g.ddy[k]=0x3a000000 | (rnd()&0x000fffff);
            g.c[k]  =0x3f000000 | (rnd()&0x001fffff);   // ~0.5..1
        }
        g.tcw=tcw; g.tsp=tsp; g.text_ctrl=0; g.pp_texture=ptx; g.pp_offset=pof;
        return g;
    };

    // a batch of pixels (varied coords + invW)
    auto mkpix=[&](int n)->std::vector<Pix>{
        std::vector<Pix> v;
        for(int i=0;i<n;i++){
            Pix p; p.px=rnd()&31; p.py=rnd()&31;
            p.invw=0x3f000000 | (rnd()&0x007fffff);   // ~0.5..1, positive
            v.push_back(p);
        }
        return v;
    };

    // pixfmt in tcw[29:27]; keep it simple: 0 (ARGB1555), non-VQ, non-palette.
    // tsp bits: filtmode tsp[14:13]. Test point (0) and bilinear (1).
    {
        auto p=mkpix(300);
        Cfg g=mkcfg(/*tcw*/0x00000000,/*tsp*/0x00000000,/*ptx*/1,/*pof*/0);
        run_batch("tex_point", g, p);
    }
    {
        auto p=mkpix(300);
        Cfg g=mkcfg(0x00000000, 0x00002000 /*filtmode=1 bilinear*/, 1, 0);
        run_batch("tex_bilinear", g, p);
    }
    {
        auto p=mkpix(300);
        Cfg g=mkcfg(0x00000000, 0x00000000, 0 /*no texture*/, 0);
        run_batch("no_texture", g, p);
    }
    {
        auto p=mkpix(300);
        Cfg g=mkcfg(0x00000000, 0x00002040 /*bilinear + shadinstr*/, 1, 1 /*offset*/);
        run_batch("tex_bilin_offset", g, p);
    }
    // ---- VQ (tcw[30]=1): exercises the fetcher's two-phase tc->vq cache chain ----
    {
        auto p=mkpix(300);
        Cfg g=mkcfg(0x40000000 /*VQ, pixfmt=0 1555*/, 0x00000000, 1, 0);
        run_batch("tex_vq_point", g, p);
    }
    {
        auto p=mkpix(300);
        Cfg g=mkcfg(0x40000000, 0x00002000 /*bilinear*/, 1, 0);
        run_batch("tex_vq_bilinear", g, p);
    }
    // ---- palette PAL8 (pixfmt=6) and PAL4 (pixfmt=5), non-VQ ----
    {
        auto p=mkpix(300);
        Cfg g=mkcfg(0x30000000 /*pixfmt=6 PAL8*/, 0x00000000, 1, 0);
        run_batch("tex_pal8", g, p);
    }
    {
        auto p=mkpix(300);
        Cfg g=mkcfg(0x28000000 /*pixfmt=5 PAL4*/, 0x00002000 /*bilinear*/, 1, 0);
        run_batch("tex_pal4_bilin", g, p);
    }

    // ---- MIXED stream: per-pixel tcw alternates VQ / non-VQ / palette. This is the
    // real doa2-style case where consecutive pixels differ in VQ-ness, exercising the
    // fetcher's IN-ORDER completion queue (a fast non-VQ pixel must not overtake an
    // earlier in-flight VQ pixel). ----
    {
        auto p=mkpix(400);
        for(size_t i=0;i<p.size();i++){
            p[i].ovr=1;
            switch(i%4){
                case 0: p[i].tcw=0x40000000; p[i].tsp=0x00000000; break; // VQ 1555 point
                case 1: p[i].tcw=0x00000000; p[i].tsp=0x00002000; break; // non-VQ bilinear
                case 2: p[i].tcw=0x30000000; p[i].tsp=0x00000000; break; // PAL8 point
                case 3: p[i].tcw=0x40000000; p[i].tsp=0x00002000; break; // VQ bilinear
            }
        }
        Cfg g=mkcfg(0,0,1,0);
        run_batch("tex_mixed", g, p);
    }
    // ---- HIGH-MISS mixed stress: LARGE plane gradients so consecutive pixels land on
    // wildly different cache lines -> constant tc AND vq misses (concurrent fills),
    // mixed VQ/non-VQ. This is the scene-like condition (big UV gradients) the small-
    // gradient batches above never exercise, and the one that deadlocked doa2. ----
    // big-gradient cfg builder (scattered addresses -> frequent misses)
    auto mkbig=[&](uint32_t tcw,uint32_t tsp)->Cfg{
        Cfg g; memset(&g,0,sizeof(g));
        for(int k=0;k<10;k++){
            g.ddx[k]=0x41000000 | (rnd()&0x007fffff);
            g.ddy[k]=0x41000000 | (rnd()&0x007fffff);
            g.c[k]  =0x40000000 | (rnd()&0x007fffff);
        }
        g.tcw=tcw; g.tsp=tsp; g.pp_texture=1; return g;
    };
    // high-miss but UNIFORM (isolates cache miss path from VQ/non-VQ mixing)
    { auto p=mkpix(600); run_batch("hm_vq",    mkbig(0x40000000,0x00002000), p); }
    { auto p=mkpix(600); run_batch("hm_nonvq", mkbig(0x00000000,0x00002000), p); }
    { auto p=mkpix(600); run_batch("hm_pal8",  mkbig(0x30000000,0x00000000), p); }
    // high-miss MIXED
    {
        std::vector<Pix> p;
        for(int i=0;i<600;i++){
            Pix q; q.px=rnd()&31; q.py=rnd()&31;
            q.invw=0x3f000000 | (rnd()&0x007fffff);
            q.ovr=1;
            switch(i%3){
                case 0: q.tcw=0x40000000; q.tsp=0x00002000; break;
                case 1: q.tcw=0x00000000; q.tsp=0x00002000; break;
                case 2: q.tcw=0x30000000; q.tsp=0x00000000; break;
            }
            p.push_back(q);
        }
        run_batch("tex_highmiss_mixed", mkbig(0,0x00002000), p);
    }

    printf("tsp_shade_pp: %d/%d passed\n", total-fails, total);
    printf(fails?"TSPSHADEPP FAIL\n":"TSPSHADEPP OK\n");
    return fails?1:0;
}

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

struct Pix { uint8_t px, py; uint32_t invw; uint32_t tcw=0, tsp=0; uint8_t ovr=0;
             uint8_t ovr_ptx=0; uint8_t ptx=1; };

int total=0, fails=0;

// apply a per-pixel tcw/tsp (and optionally pp_texture) override on top of the batch cfg.
static void apply_px(const Cfg&g, const Pix&p){
    dut->tcw = p.ovr ? p.tcw : g.tcw;
    dut->tsp = p.ovr ? p.tsp : g.tsp;
    if(p.ovr_ptx) dut->pp_texture = p.ptx;
    else          dut->pp_texture = g.pp_texture;
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

    // ---- COLD-RESET: a VQ batch as the VERY FIRST thing (caches cold from reset). With
    //      the group-atomic cache the 4 corners stay lockstep even through cold-fill, so
    //      the FIFO-free join is correct from pixel 0. (This was the cold-start regression.)
    { auto p=mkpix(64); run_batch("cold_first_vq",  mkcfg(0x40000000,0x00000000,1,0), p); }

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

    // ---- STEEP-PERSPECTIVE RAMP: mimic a receding textured plane (e.g. the DC BIOS
    // water). The existing batches keep invW in [0.5,1) (W nearly flat) and u,v strictly
    // positive; a receding plane has a WIDE W range AND wrapping/negative u,v. This is the
    // condition the real scene shows blockiness in but the flat batches never exercise. ----
    auto mkramp=[&](uint32_t tcw,uint32_t tsp, bool wrap)->Cfg{
        Cfg g; memset(&g,0,sizeof(g));
        // U (plane 0) and V (plane 1): strong gradient, with a negative c so u,v cross 0
        // (wrap-mode). Remaining colour planes: mild.
        g.ddx[0]=0x40000000; g.ddy[0]=0x3f800000; g.c[0]=0xC1000000; // U: 2*x + 1*y - 8
        g.ddx[1]=0x3f800000; g.ddy[1]=0x40000000; g.c[1]=0xC1000000; // V: 1*x + 2*y - 8
        for(int k=2;k<10;k++){ g.ddx[k]=0; g.ddy[k]=0; g.c[k]=0x3f000000; }
        g.tcw=tcw; g.tsp=tsp; g.pp_texture=1; g.pp_offset=0;
        // wrap vs clamp lives in tsp[16:15]; leave 0 => wrap (matches most surfaces).
        (void)wrap;
        return g;
    };
    // steep W: sweep invW across a WIDE exponent range so W = 1/invW varies a lot.
    auto mkramp_pix=[&](int n)->std::vector<Pix>{
        std::vector<Pix> v;
        for(int i=0;i<n;i++){
            Pix p; p.px=i&31; p.py=(i>>5)&31;
            // invW exponent walks 0x3d..0x45 (W spans ~1/32 .. ~64): steep perspective.
            uint32_t e = 0x3d + (i % 9);
            p.invw = (e<<23) | (rnd()&0x007fffff);
            v.push_back(p);
        }
        return v;
    };
    { auto p=mkramp_pix(1024); run_batch("ramp_wrap_point",  mkramp(0x00000000,0x00000000,true), p); }
    { auto p=mkramp_pix(1024); run_batch("ramp_wrap_bilin",  mkramp(0x00000000,0x00002000,true), p); }
    { auto p=mkramp_pix(1024); run_batch("ramp_wrap_vq",     mkramp(0x40000000,0x00002000,true), p); }
    { auto p=mkramp_pix(1024); run_batch("ramp_clamp_bilin", mkramp(0x00000000,0x00002000|0x00018000,false), p); }

    // ---- SHARED-LINE / HIT-AFTER-MISS: the real-scene pattern the batches above MISS.
    // Random px/py (used everywhere else) give scattered corners => isolated misses. A
    // real textured surface walks pixels in RASTER order with a GENTLE gradient (~0.2
    // texels/pixel, measured from menu2), so consecutive pixels share 3 of their 4 texel
    // corners and the SAME cache line is hit repeatedly right after its miss-fill. This
    // exercises: (a) cache hit immediately after a fill on the just-filled line, (b) the
    // 4 corner ports requesting the SAME/adjacent texels (repeated UV), (c) a corner that
    // hits while a sibling is still filling the shared line. Any texel<->payload offset
    // from that timing shows here as pp != serial. ----
    auto mkgentle=[&](uint32_t tcw,uint32_t tsp)->Cfg{
        Cfg g; memset(&g,0,sizeof(g));
        // U = x/8 , V = y/8  -> at texu=texv=3 (size 64) that's ~ (64/8)=8 texels across a
        // 32px tile row = 0.25 texel/pixel: heavy corner sharing, exactly like the water.
        g.ddx[0]=0x3e000000; g.ddy[0]=0x00000000; g.c[0]=0x3f000000; // U = 0.125*x + 0.5
        g.ddx[1]=0x00000000; g.ddy[1]=0x3e000000; g.c[1]=0x3f000000; // V = 0.125*y + 0.5
        for(int k=2;k<10;k++){ g.ddx[k]=0; g.ddy[k]=0; g.c[k]=0x3f000000; }
        g.tcw=tcw; g.tsp=tsp; g.pp_texture=1; g.pp_offset=0;
        return g;
    };
    // raster-order pixels, constant W (invw=1.0) so U/V step is uniform & gentle.
    auto raster_pix=[&](int n)->std::vector<Pix>{
        std::vector<Pix> v;
        for(int i=0;i<n;i++){ Pix p; p.px=i&31; p.py=(i>>5)&31; p.invw=0x3f800000; v.push_back(p); }
        return v;
    };
    // COLD cache each batch (reset between run_batch? no - so run twice: 1st warms/misses,
    // 2nd is all-hit). We rely on the scattered batches above having polluted the cache, so
    // this gentle raster walk starts COLD on its lines -> miss-fill, then immediate re-hit.
    { auto p=raster_pix(1024); run_batch("gentle_raster_point",  mkgentle(0x00000000,0x00000000), p); }
    { auto p=raster_pix(1024); run_batch("gentle_raster_bilin",  mkgentle(0x00000000,0x00002000), p); }
    { auto p=raster_pix(1024); run_batch("gentle_raster_vq",     mkgentle(0x40000000,0x00002000), p); }
    { auto p=raster_pix(1024); run_batch("gentle_raster_pal8",   mkgentle(0x30000000,0x00002000), p); }
    // Longer streaming stress: run the full 1024-pixel tile (max, since pp_in_id is 10-bit
    // -> ids must stay < 1024) several times back-to-back. Each run starts with a warm
    // cache from the previous -> exercises sustained all-hit-after-fill streaming, the
    // steady state of a real textured surface.
    {
        Cfg g=mkgentle(0x00000000,0x00002000);
        for(int rep=0; rep<4; rep++){
            auto p=raster_pix(1024);
            char nm[32]; snprintf(nm,sizeof(nm),"gentle_stream_%d",rep);
            run_batch(nm, g, p);
        }
    }

    // ---- WILD MIX: 2048 PRNG vectors, a DIFFERENT texture format on (nearly) every
    // cycle - VQ / non-VQ / no-TEX / PAL4 / PAL8 / 1555 / 565 / 4444, point & bilinear,
    // scattered coords + wide invW. Stresses back-to-back format SWITCHING (VQ pixel then
    // non-VQ then PAL then no-TEX ...) so any residual per-cycle mis-sequence in the
    // fixed pipeline / 1-cycle cache shows up. ----
    // 2048 vectors total, run as two 1024 sub-batches (pp_in_id is 10-bit -> <=1024/batch).
    for(int half=0; half<2; half++){
        std::vector<Pix> p;
        for(int i=0;i<1024;i++){
            Pix q; q.px=rnd()&31; q.py=rnd()&31;
            q.invw = ((0x3a + (rnd()%12))<<23) | (rnd()&0x007fffff);  // wide W
            q.ovr=1; q.ovr_ptx=1;
            uint32_t sel = rnd()%8;
            uint32_t filt = (rnd()&1) ? 0x00002000u : 0u;          // point/bilinear
            switch(sel){
                case 0: q.tcw=0x00000000; q.ptx=0; break;                 // NO texture
                case 1: q.tcw=0x00000000; q.ptx=1; break;                 // 1555 non-VQ
                case 2: q.tcw=0x08000000; q.ptx=1; break;                 // 565  non-VQ
                case 3: q.tcw=0x10000000; q.ptx=1; break;                 // 4444 non-VQ
                case 4: q.tcw=0x28000000; q.ptx=1; break;                 // PAL4
                case 5: q.tcw=0x30000000; q.ptx=1; break;                 // PAL8
                case 6: q.tcw=0x40000000; q.ptx=1; break;                 // VQ 1555
                case 7: q.tcw=0x48000000; q.ptx=1; break;                 // VQ 565
            }
            q.tsp = filt;
            p.push_back(q);
        }
        Cfg g=mkcfg(0,0,1,0);
        char nm[24]; snprintf(nm,sizeof(nm),"wild_mix_%d",half);
        run_batch(nm, g, p);
    }

    // ============================================================================
    // FAILURE AMPLIFIERS: the current fails are cold-cache/VQ EARLY pixels showing a
    // one-position LAG (pixel N gets pixel N-1's texel). These tests are designed to make
    // that misalignment recur mid-stream (not just at warm-up) so it fails WORSE and the
    // pattern is unambiguous. Each isolates one variable.
    // ============================================================================

    // (A) EVERY-PIXEL-MISS VQ: huge U/V gradient so consecutive pixels land on DIFFERENT
    //     cache lines -> a tc miss AND a vq miss on (almost) every pixel. If the miss-
    //     recovery misaligns, this fails on a large fraction, not just pix0..4.
    auto mk_permiss=[&](uint32_t tcw,uint32_t tsp)->Cfg{
        Cfg g; memset(&g,0,sizeof(g));
        // U = 4096*x, V = 4096*y -> each pixel step crosses many lines (guaranteed misses).
        g.ddx[0]=0x45800000; g.ddy[0]=0; g.c[0]=0x3f000000;      // U ~ 4096*x
        g.ddx[1]=0; g.ddy[1]=0x45800000; g.c[1]=0x3f000000;      // V ~ 4096*y
        for(int k=2;k<10;k++){ g.ddx[k]=0; g.ddy[k]=0; g.c[k]=0x3f000000; }
        g.tcw=tcw; g.tsp=tsp; g.pp_texture=1; return g;
    };
    { auto p=mkpix(512); run_batch("amp_permiss_vq",    mk_permiss(0x40000000,0x00000000), p); }
    { auto p=mkpix(512); run_batch("amp_permiss_nonvq", mk_permiss(0x00000000,0x00000000), p); }

    // (B) ALTERNATE HIT / MISS: pixel i alternates between a FIXED (0,0) texel (hot after
    //     first fill) and a scattered one (cold miss). Stresses the miss->hit and hit->miss
    //     TRANSITIONS every cycle - where a one-cycle recovery slip shows up.
    {
        std::vector<Pix> p;
        for(int i=0;i<512;i++){
            Pix q; q.ovr=1; q.tcw=0x40000000; q.tsp=0x00000000; // VQ point
            if(i&1){ q.px=0; q.py=0; }                          // hot corner
            else   { q.px=(rnd()&31); q.py=(rnd()&31); }         // cold-ish
            q.invw=0x3f000000|(rnd()&0x7fffff);
            p.push_back(q);
        }
        Cfg g=mk_permiss(0x40000000,0x00000000);
        run_batch("amp_alt_hitmiss_vq", g, p);
    }

    // (C) VQ-then-nonVQ back to back (format switch across the 2-trip boundary): every even
    //     pixel is VQ (2 trips), every odd is non-VQ (1 trip). A 1-trip pixel behind a
    //     stalled 2-trip pixel is exactly the reorder/lag hazard.
    {
        std::vector<Pix> p;
        for(int i=0;i<512;i++){
            Pix q; q.ovr=1; q.px=(rnd()&31); q.py=(rnd()&31);
            q.invw=0x3f000000|(rnd()&0x7fffff);
            if(i&1){ q.tcw=0x00000000; q.tsp=0x00002000; }       // non-VQ bilinear (1 trip)
            else   { q.tcw=0x40000000; q.tsp=0x00000000; }       // VQ point (2 trips)
            p.push_back(q);
        }
        Cfg g=mk_permiss(0,0x00002000);
        run_batch("amp_vq_nonvq_alt", g, p);
    }

    // (D) SINGLE-PIXEL batches: isolate the very-first-pixel-after-reset case for each
    //     format (the pp_out for a 1-pixel stream must be exactly right).
    {
        const char* nm[4]={"amp_single_nonvq","amp_single_vq","amp_single_pal8","amp_single_565"};
        uint32_t tc[4]={0x00000000,0x40000000,0x30000000,0x08000000};
        for(int k=0;k<4;k++){
            std::vector<Pix> p; Pix q; q.px=5;q.py=7;q.invw=0x3f400000; p.push_back(q);
            Cfg g=mkcfg(tc[k],0x00000000,1,0);
            run_batch(nm[k], g, p);
        }
    }

    // (E) SAME-TEXEL cold-start: TINY gradient so every pixel maps to the SAME cache line.
    //     The first pixel misses+fills; ALL following pixels HIT the just-filled line. This
    //     is the actual condition the failing tex_vq_point/hm_vq batches hit (small mkcfg
    //     gradient + cold cache) - it isolates the HIT-IMMEDIATELY-AFTER-FILL path.
    auto mk_sametexel=[&](uint32_t tcw,uint32_t tsp)->Cfg{
        Cfg g; memset(&g,0,sizeof(g));
        // near-zero U/V gradient, constant c -> all pixels sample ~one texel.
        g.ddx[0]=0x34000000; g.ddy[0]=0x34000000; g.c[0]=0x3f000000;
        g.ddx[1]=0x34000000; g.ddy[1]=0x34000000; g.c[1]=0x3f000000;
        for(int k=2;k<10;k++){ g.ddx[k]=0; g.ddy[k]=0; g.c[k]=0x3f000000; }
        g.tcw=tcw; g.tsp=tsp; g.pp_texture=1; return g;
    };
    { auto p=mkpix(64); run_batch("amp_sametexel_vq",    mk_sametexel(0x40000000,0x00000000), p); }
    { auto p=mkpix(64); run_batch("amp_sametexel_nonvq", mk_sametexel(0x00000000,0x00000000), p); }
    { auto p=mkpix(64); run_batch("amp_sametexel_pal8",  mk_sametexel(0x30000000,0x00000000), p); }
    { auto p=mkpix(64); run_batch("amp_sametexel_vqbil", mk_sametexel(0x40000000,0x00002000), p); }

    // (F) COLD VQ, MANY DISTINCT codebook lines: VQ point, MID gradient so consecutive
    //     pixels hit DIFFERENT vq codebook lines -> many distinct cold vq misses back to
    //     back at the start. This is exactly tex_vq_point's condition; a larger batch makes
    //     the cold-vq transient (if that's the bug) fail on many more pixels.
    auto mk_coldvq=[&](uint32_t tsp)->Cfg{
        Cfg g; memset(&g,0,sizeof(g));
        // moderate gradient: crosses texels within a line (varies vq_byte) but not wildly.
        g.ddx[0]=0x3e800000; g.ddy[0]=0x3e000000; g.c[0]=0x3f000000;
        g.ddx[1]=0x3e000000; g.ddy[1]=0x3e800000; g.c[1]=0x3f000000;
        for(int k=2;k<10;k++){ g.ddx[k]=0; g.ddy[k]=0; g.c[k]=0x3f000000; }
        g.tcw=0x40000000; g.tsp=tsp; g.pp_texture=1; return g;
    };
    { auto p=mkpix(300); run_batch("amp_coldvq_scattered", mk_coldvq(0x00000000), p); }

    printf("tsp_shade_pp: %d/%d passed\n", total-fails, total);
    printf(fails?"TSPSHADEPP FAIL\n":"TSPSHADEPP OK\n");
    return fails?1:0;
}

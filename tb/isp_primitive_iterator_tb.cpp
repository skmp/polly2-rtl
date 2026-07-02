// isp_primitive_iterator unit test: builds param records (isp/tsp/tcw header +
// up to 8 XYZ-only vertices, optional two-volume padding) in a behavioral
// VRAM, drives an ENT_STRIP entry (param_offs/skip/shadow/mask), and checks
// the emitted triangle stream (isp word + v0/v1/v2 XYZ) against a C golden
// mirroring refsw decode_pvr_vertices (XYZ only) + RenderTriangleStrip's
// triangle/vertex selection (refsw_lists.cpp:176..201).
#include "Visp_primitive_iterator_tb_top.h"
#include "Visp_primitive_iterator_tb_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Visp_primitive_iterator_tb_top* dut;
#define VRAM dut->rootp->isp_primitive_iterator_tb_top__DOT__vram
static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

static uint32_t rng=0xFEED1234;
static uint32_t rnd(){uint32_t x=rng;x^=x<<13;x^=x>>17;x^=x<<5;rng=x;return x;}

// 32-bit-VIEW access, de-interleaved into physical 64-bit VRAM like refsw
// pvr_map32 (matches data_cache256's read view).
static void put_word(uint32_t byte_addr, uint32_t val){
    uint32_t q = byte_addr >> 2; uint32_t bank = (q>>20)&1; uint32_t wofs = (q&0xFFFFF)&0xFFFF;
    uint64_t w = VRAM[wofs];
    w &= ~((uint64_t)0xFFFFFFFFu << (32*bank));
    w |= ((uint64_t)val) << (32*bank);
    VRAM[wofs] = w;
}
static uint32_t get_word(uint32_t byte_addr){
    uint32_t q = byte_addr >> 2; uint32_t bank = (q>>20)&1; uint32_t wofs = (q&0xFFFFF)&0xFFFF;
    return (uint32_t)(VRAM[wofs] >> (32*bank));
}

struct Vtx { uint32_t x,y,z; };
struct GoldTri { uint32_t isp, tag; Vtx v0,v1,v2; };

// refsw CoreTagFromDesc (ISP_BACKGND_T_type layout): tag_offset[2:0],
// param_offs_in_words[23:3], skip[26:24], shadow[27], cache_bypass[28].
static uint32_t core_tag(uint32_t cache_bypass, uint32_t shadow, uint32_t skip,
                         uint32_t param_offs, uint32_t tag_offset){
    return (tag_offset&7) | ((param_offs&0x1FFFFF)<<3) | ((skip&7)<<24)
         | ((shadow&1)<<27) | ((cache_bypass&1)<<28);
}

// Build a param record at byte `base`: isp,tsp,tcw [,tsp1,tcw1 if two_vol],
// then 8 vertices of (skip+3) words each (only first 3 = XYZ are meaningful;
// the rest are filled with random junk the iterator must skip over).
static uint32_t build_record(uint32_t base, uint32_t isp, uint32_t skip, bool two_vol,
                              Vtx verts[8]){
    put_word(base+0, isp);
    put_word(base+4, rnd());               // tsp
    put_word(base+8, rnd());               // tcw
    uint32_t p = base+12;
    if (two_vol){ put_word(p,rnd()); put_word(p+4,rnd()); p+=8; }
    uint32_t stride_words = 3 + skip*(two_vol?2:1);
    for(int i=0;i<8;i++){
        put_word(p+0,  verts[i].x);
        put_word(p+4,  verts[i].y);
        put_word(p+8,  verts[i].z);
        for(uint32_t w=3; w<stride_words; w++) put_word(p+4*w, rnd()); // junk
        p += stride_words*4;
    }
    return p; // end of record
}

// Golden: RenderTriangleStrip's triangle/vertex selection. refsw gates triangle
// i by mask & (1 << (5-i)) (refsw_lists.cpp:194).
static std::vector<GoldTri> golden_strip(uint32_t isp, uint32_t mask, Vtx verts[8],
                                          uint32_t param_offs, uint32_t skip, uint32_t shadow){
    std::vector<GoldTri> out;
    for(int i=0;i<6;i++){
        if (!((mask>>(5-i))&1)) continue;
        int not_even = i&1, even = not_even^1;
        uint32_t tag = core_tag((isp>>21)&1, shadow, skip, param_offs, i);
        out.push_back({isp, tag, verts[i+not_even], verts[i+even], verts[i+2]});
    }
    return out;
}

int fails=0, total=0;

static bool vtx_eq(uint32_t hx,uint32_t hy,uint32_t hz, const Vtx&g){
    return hx==g.x && hy==g.y && hz==g.z;
}

static void run_case(const char* name, uint32_t base_words, uint32_t skip, bool two_vol,
                      uint32_t mask, uint32_t isp, Vtx verts[8]){
    dut->reset=1; dut->start=0; dut->consume=0; tick(); tick(); tick(); dut->reset=0;
    for(int i=0;i<300;i++) tick();   // data_cache256 reset sweep

    build_record(base_words*4, isp, skip, two_vol, verts);
    auto gold = golden_strip(isp, mask, verts, base_words, skip, two_vol?1:0);

    dut->param_base=0;
    dut->etype = 0;                       // ENT_STRIP
    dut->entry_param_offs = base_words;   // param_offs_in_words (base is word-addr)
    dut->entry_skip = skip;
    dut->entry_shadow = two_vol ? 1 : 0;
    dut->intensity_shadow = 0;            // two_vol = shadow & ~ishadow = shadow
    dut->entry_mask = mask;
    dut->entry_count = 0;
    dut->start=1; tick(); dut->start=0;

    size_t gi=0; int guard=0;
    while(true){
        if (!dut->busy && gi>0 && !dut->triangle_ready) break;
        if (dut->prim_done) break;
        if (dut->triangle_ready){
            total++;
            if (gi>=gold.size()){
                printf("[%s] extra triangle #%zu\n",name,gi); fails++;
            } else {
                auto&g=gold[gi];
                bool ok = (dut->out_isp==g.isp)
                    && (dut->out_tag==g.tag)
                    && vtx_eq(dut->v0x,dut->v0y,dut->v0z,g.v0)
                    && vtx_eq(dut->v1x,dut->v1y,dut->v1z,g.v1)
                    && vtx_eq(dut->v2x,dut->v2y,dut->v2z,g.v2);
                if(!ok){
                    fails++;
                    if(fails<20) printf("[%s] tri #%zu mismatch: hw isp=%08x tag=%08x v0=(%x,%x,%x) v1=(%x,%x,%x) v2=(%x,%x,%x)\n"
                        "        exp isp=%08x tag=%08x v0=(%x,%x,%x) v1=(%x,%x,%x) v2=(%x,%x,%x)\n",
                        name,gi,dut->out_isp,dut->out_tag,dut->v0x,dut->v0y,dut->v0z,dut->v1x,dut->v1y,dut->v1z,dut->v2x,dut->v2y,dut->v2z,
                        g.isp,g.tag,g.v0.x,g.v0.y,g.v0.z,g.v1.x,g.v1.y,g.v1.z,g.v2.x,g.v2.y,g.v2.z);
                }
            }
            dut->consume=1; tick(); dut->consume=0;
            gi++;
        } else tick();
        if(++guard>200000){ printf("[%s] TIMEOUT (gi=%zu/%zu)\n",name,gi,gold.size()); fails++; break; }
    }
    if (gi < gold.size()){
        printf("[%s] missing triangles: got %zu expected %zu\n",name,gi,gold.size());
        fails += (int)(gold.size()-gi); total += (int)(gold.size()-gi);
    }
}

// ---- triangle ARRAY: `count` separate records, each 3 verts, 1 triangle, ----
// tag_offset=0, param_offs = that record's own word offset (refsw RenderTriangleArray).
// entry_shadow/ishadow are the entry+register bits; the PHYSICAL two_vol layout
// the iterator must use = shadow & ~ishadow.
static void run_array_s(const char* name, uint32_t base_words, uint32_t skip,
                        bool shadow, bool ishadow, uint32_t count, uint32_t isp0);
// back-compat: two_vol layout with ishadow=0 (so two_vol == shadow)
static void run_array(const char* name, uint32_t base_words, uint32_t skip,
                      bool two_vol, uint32_t count, uint32_t isp0){
    run_array_s(name, base_words, skip, two_vol, /*ishadow*/false, count, isp0);
}
static void run_array_s(const char* name, uint32_t base_words, uint32_t skip,
                        bool shadow, bool ishadow, uint32_t count, uint32_t isp0){
    bool two_vol = shadow && !ishadow;
    dut->reset=1; dut->start=0; dut->consume=0; tick(); tick(); tick(); dut->reset=0;
    for(int i=0;i<300;i++) tick();

    // record size (words): header (3 or 5) + 3 verts * (3 + skip*(1+two_vol))
    uint32_t vstride = 3 + skip*(two_vol?2:1);
    uint32_t rec_words = (two_vol?5:3) + 3*vstride;

    std::vector<GoldTri> gold;
    for(uint32_t r=0;r<count;r++){
        uint32_t rbase_words = base_words + r*rec_words;
        uint32_t isp = isp0 + r;            // distinct isp per record
        Vtx v[8]; for(int i=0;i<8;i++) v[i]={rnd(),rnd(),rnd()};
        build_record(rbase_words*4, isp, skip, two_vol, v);
        // one triangle: v0,v1,v2 (no winding swap for arrays), tag_offset=0.
        // CoreTag.shadow is the ENTRY shadow bit (not two_vol).
        uint32_t tag = core_tag((isp>>21)&1, shadow?1:0, skip, rbase_words, 0);
        gold.push_back({isp, tag, v[0], v[1], v[2]});
    }

    dut->param_base=0;
    dut->etype = 1;                          // ENT_TRI
    dut->entry_param_offs = base_words;
    dut->entry_skip = skip;
    dut->entry_shadow = shadow ? 1 : 0;
    dut->intensity_shadow = ishadow ? 1 : 0;
    dut->entry_mask = 0;
    dut->entry_count = count;                // prims+1 already
    dut->start=1; tick(); dut->start=0;

    size_t gi=0; int guard=0;
    while(true){
        if (dut->prim_done) break;
        if (dut->triangle_ready){
            total++;
            if (gi>=gold.size()){ printf("[%s] extra tri #%zu\n",name,gi); fails++; }
            else {
                auto&g=gold[gi];
                bool ok = (dut->out_isp==g.isp)&&(dut->out_tag==g.tag)
                    && vtx_eq(dut->v0x,dut->v0y,dut->v0z,g.v0)
                    && vtx_eq(dut->v1x,dut->v1y,dut->v1z,g.v1)
                    && vtx_eq(dut->v2x,dut->v2y,dut->v2z,g.v2);
                if(!ok){ fails++;
                    if(fails<20) printf("[%s] tri #%zu: hw isp=%08x tag=%08x v=(%x,%x,%x)(%x,%x,%x)(%x,%x,%x)\n"
                        "        exp isp=%08x tag=%08x v=(%x,%x,%x)(%x,%x,%x)(%x,%x,%x)\n",
                        name,gi,dut->out_isp,dut->out_tag,dut->v0x,dut->v0y,dut->v0z,dut->v1x,dut->v1y,dut->v1z,dut->v2x,dut->v2y,dut->v2z,
                        g.isp,g.tag,g.v0.x,g.v0.y,g.v0.z,g.v1.x,g.v1.y,g.v1.z,g.v2.x,g.v2.y,g.v2.z);
                }
            }
            dut->consume=1; tick(); dut->consume=0; gi++;
        } else tick();
        if(++guard>200000){ printf("[%s] TIMEOUT (gi=%zu/%zu)\n",name,gi,gold.size()); fails++; break; }
    }
    if (gi < gold.size()){
        printf("[%s] missing tris: got %zu expected %zu\n",name,gi,gold.size());
        fails += (int)(gold.size()-gi); total += (int)(gold.size()-gi);
    }
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Visp_primitive_iterator_tb_top;
    for(int i=0;i<65536;i++) VRAM[i]=0;

    // ---- case 1: full mask, skip=0, single volume ----
    { Vtx v[8]; for(int i=0;i<8;i++) v[i]={0x3F800000u+i, 0x40000000u+i, 0x40400000u+i};
      run_case("full_mask_skip0", 0, 0, false, 0x3F, 0xAAAA0001, v); }

    // ---- case 2: sparse mask, skip=2 (extra junk words per vertex) ----
    { Vtx v[8]; for(int i=0;i<8;i++) v[i]={rnd(),rnd(),rnd()};
      run_case("sparse_skip2", 50, 2, false, 0b010101, 0x11110002, v); }

    // ---- case 3: two-volume (shadow), skip=1 ----
    { Vtx v[8]; for(int i=0;i<8;i++) v[i]={rnd(),rnd(),rnd()};
      run_case("two_volume", 100, 1, true, 0x3F, 0x22220003, v); }

    // ---- case 4: single triangle only (mask bit 3) ----
    { Vtx v[8]; for(int i=0;i<8;i++) v[i]={rnd(),rnd(),rnd()};
      run_case("single_tri", 150, 0, false, 0b001000, 0x33330004, v); }

    // ---- case 5: randomized ----
    for(int t=0;t<30;t++){
        Vtx v[8]; for(int i=0;i<8;i++) v[i]={rnd(),rnd(),rnd()};
        uint32_t mask = rnd()&0x3F;
        uint32_t skip = rnd()&3; // keep skip small so record fits comfortably
        bool tv = rnd()&1;
        uint32_t isp = rnd();
        char name[32]; snprintf(name,sizeof(name),"rand%d",t);
        run_case(name, 300+t*40, skip, tv, mask, isp, v);
    }

    // ---- triangle ARRAY cases ----
    run_array("arr_c1_skip0",   1000, 0, false, 1,  0x55550010);
    run_array("arr_c4_skip0",   1100, 0, false, 4,  0x55550020);
    run_array("arr_c3_skip2",   1300, 2, false, 3,  0x55550030);
    run_array("arr_c2_twovol",  1500, 1, true,  2,  0x55550040);
    // daytona bug: entry shadow=1 BUT intensity_shadow=1 -> two_vol=0 layout.
    // (iterator must use shadow & ~intensity_shadow for the record stride.)
    run_array_s("arr_shadow_ishadow", 1700, 3, /*shadow*/true, /*ishadow*/true, 3, 0x55550050);
    run_array_s("arr_shadow_ishadow2",1900, 1, true, true, 5, 0x55550060);
    for(int t=0;t<20;t++){
        uint32_t count = 1 + (rnd()%6);
        uint32_t skip  = rnd()&3;
        bool tv = rnd()&1;
        char name[32]; snprintf(name,sizeof(name),"arr_rand%d",t);
        run_array(name, 2000+t*80, skip, tv, count, 0x66660000u+t*16);
    }

    printf("isp_primitive_iterator: %d/%d passed\n", total-fails, total);
    printf(fails?"ISPRIM FAIL\n":"ISPRIM OK\n");
    return fails?1:0;
}

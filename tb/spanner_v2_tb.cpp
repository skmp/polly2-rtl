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
#include <cmath>
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
#define SPO_X      ROOT->spanner_v2_tb_top__DOT__spo_x
#define SPO_ID     ROOT->spanner_v2_tb_top__DOT__spo_id
#define SPO_REP    ROOT->spanner_v2_tb_top__DOT__spo_rep
#define SPO_INVW0  ROOT->spanner_v2_tb_top__DOT__spo_invw0
#define SPO_INVW1  ROOT->spanner_v2_tb_top__DOT__spo_invw1
#define SPO_INVW2  ROOT->spanner_v2_tb_top__DOT__spo_invw2
#define SPO_INVW3  ROOT->spanner_v2_tb_top__DOT__spo_invw3
#define SPO_AT     ROOT->spanner_v2_tb_top__DOT__spo_at

// span-count range: read the DUT's span_cnt register directly (persists after busy->0).
// sp_first is always 0; sp_last = span_cnt-1; sp_cnt_z = (span_cnt==0).
#define SPAN_CNT   ROOT->spanner_v2_tb_top__DOT__u_dut__DOT__span_cnt
#define SP_FIRST   0u
#define SP_LAST    (SPAN_CNT>0 ? (uint32_t)(SPAN_CNT-1) : 0u)
#define SP_CNT_Z   (SPAN_CNT==0)
#define TSG_VALID ROOT->spanner_v2_tb_top__DOT__tsg_valid
#define TSG_ISP   ROOT->spanner_v2_tb_top__DOT__tsg_isp
#define TSG_TSP   ROOT->spanner_v2_tb_top__DOT__tsg_tsp
#define TSG_TCW   ROOT->spanner_v2_tb_top__DOT__tsg_tcw
#define TSG_DDX   ROOT->spanner_v2_tb_top__DOT__tsg_ddx
#define TSG_DDY   ROOT->spanner_v2_tb_top__DOT__tsg_ddy
#define TSG_C     ROOT->spanner_v2_tb_top__DOT__tsg_c

// +planecheck: INDEPENDENT refsw2 PlaneStepper3 golden. From the captured vertex record
// (verts + isp flags + xbase/ybase) recompute ddx/ddy/c in DOUBLE precision, straight from
// refsw2 refsw_tile.h PlaneStepper3::Setup, and diff against triangle_setups[id]. This is a
// TRUE independent check (not self-referential like setup_golden.txt) that proves the
// spanner's per-triangle plane MATH is correct. Plane slots (tsp_setup_stream order):
//   [0]=U(=u*z) [1]=V(=v*z) [2..5]=Col RGBA(=chan*z) [6..9]=Ofs RGBA(=chan*z). invW is NOT
// a slot (per-pixel from the depth buffer). U/V only if textured; Ofs only if offset.
static bool g_planecheck = false;
static double g_pc_worst = 0.0;

// read one 32-bit VIEW word from the sim VRAM (bank = vw[20], wofs = vw[19:0]); mirrors
// record_fetcher.vw_addr + the sim_ddr_fb 64b word layout.
static uint32_t vram_vw(uint32_t vw){
    uint32_t wofs = vw & 0xFFFFF; uint64_t q = VRAM[wofs];
    return (vw & (1u<<20)) ? (uint32_t)(q>>32) : (uint32_t)q;
}
// decoded record: 3 verts of {x,y,z,u,v,col,ofs} + isp/tsp/tcw.
struct Rec { uint32_t isp,tsp,tcw; uint32_t x[3],y[3],z[3],u[3],v[3],col[3],ofs[3]; };
// C++ GetFpuEntry: decode ONE param record from VRAM, mirroring record_fetcher exactly
// (independent of the RTL fetcher -> also validates it). param_base + tag -> verts.
static Rec decode_record(uint32_t tag, uint32_t param_base, bool intensity_shadow){
    Rec r; memset(&r,0,sizeof(r));
    uint32_t skip = (tag>>24)&7, toff = tag&7;
    bool two_vol = ((tag>>27)&1) && !intensity_shadow;
    uint32_t stride = 3 + skip*(two_vol?2:1);
    // record byte base = param_base + {tag[23:3],2'b00}; view word = byte>>2
    uint32_t rec_b = (param_base + (((tag>>3)&0x1FFFFF)<<2)) & 0x7FFFFFF;
    uint32_t rec_w = rec_b>>2;
    r.isp = vram_vw(rec_w+0); r.tsp = vram_vw(rec_w+1); r.tcw = vram_vw(rec_w+2);
    bool tex = (r.isp>>25)&1, ofs=(r.isp>>24)&1, uv16=(r.isp>>22)&1;
    uint32_t pos_col = 3 + (tex ? (uv16?1:2) : 0);
    uint32_t pos_ofs = pos_col+1;
    uint32_t fpv     = pos_col+1 + (ofs?1:0);
    uint32_t vb_w = rec_w + (two_vol?5:3) + toff*stride;
    for(int vtx=0; vtx<3; vtx++){
        uint32_t base = vb_w + vtx*stride;
        r.x[vtx]=vram_vw(base+0); r.y[vtx]=vram_vw(base+1); r.z[vtx]=vram_vw(base+2);
        if(tex){
            r.u[vtx]=vram_vw(base+3);
            if(!uv16) r.v[vtx]=vram_vw(base+4);
        }
        r.col[vtx]=vram_vw(base+pos_col);
        if(ofs) r.ofs[vtx]=vram_vw(base+pos_ofs);
    }
    (void)fpv;
    return r;
}
static inline float f32(uint32_t u){ float f; memcpy(&f,&u,4); return f; }
static inline uint32_t u32(float f){ uint32_t u; memcpy(&u,&f,4); return u; }
static inline double chanf(uint32_t c, int ch){ return (double)((c >> (8*ch)) & 0xFF); }

// ============================ SOFT-FP: bit-exact C++ ports of the RTL setup FP units =====
// Ported directly from rtl/isp_min/fp_mul16.sv, fp_add24.sv, fp_add3_24.sv, fp_rcp_fast.sv
// and rtl/tsp/fp_mul_c9.sv. Same non-IEEE reduced precision (16-bit-mantissa mul, truncate,
// DaZ, sat/flush). The SETUP MATH itself is written fresh (refsw2 structure) using these
// ops, so a bug in tsp_setup_stream's datapath still surfaces as a mismatch.

// fp_mul16: 16x16 significand multiply, truncate.
static uint32_t fmul16(uint32_t a, uint32_t b){
    uint32_t sa=a>>31, sb=b>>31, ea=(a>>23)&0xFF, eb=(b>>23)&0xFF;
    uint32_t res_sign=sa^sb;
    if(ea==0||eb==0) return res_sign<<31;                 // DaZ
    uint32_t sig_a=0x8000|((a>>8)&0x7FFF), sig_b=0x8000|((b>>8)&0x7FFF);
    uint32_t prod=sig_a*sig_b;                            // 16x16 -> 32
    int64_t e_sum=(int64_t)ea+(int64_t)eb-127;
    int top=(prod>>31)&1;
    uint32_t mant=top?((prod>>8)&0x7FFFFF):((prod>>7)&0x7FFFFF);
    int64_t e_adj=top?e_sum+1:e_sum;
    if(e_adj<=0)   return res_sign<<31;
    if(e_adj>=255) return (res_sign<<31)|(0xFEu<<23)|0x7FFFFF;
    return (res_sign<<31)|((uint32_t)(e_adj&0xFF)<<23)|mant;
}
// fp_add24: sign-magnitude align+add, normalize, truncate. sub=1 -> a - b_in.
static uint32_t fadd24(uint32_t a, uint32_t b_in, int sub){
    uint32_t b = sub ? (b_in ^ 0x80000000u) : b_in;
    uint32_t sa=a>>31, sb=b>>31, ea=(a>>23)&0xFF, eb=(b>>23)&0xFF;
    uint32_t sig_a=((ea!=0)?0x800000u:0)|(a&0x7FFFFF);
    uint32_t sig_b=((eb!=0)?0x800000u:0)|(b&0x7FFFFF);
    uint32_t exa=(ea==0)?1:ea, exb=(eb==0)?1:eb;
    int a_ge=(exa>exb)||((exa==exb)&&(sig_a>=sig_b));
    uint32_t sig_big=a_ge?sig_a:sig_b, sig_sml=a_ge?sig_b:sig_a;
    uint32_t s_sml=a_ge?sb:sa, e_sml=a_ge?exb:exa;
    uint32_t e_big=a_ge?exa:exb, s_big=a_ge?sa:sb;
    uint32_t shamt=e_big-e_sml;
    uint32_t sml_sh=(shamt>=24)?0:(sig_sml>>shamt);
    int same=(s_big==s_sml);
    uint32_t sum=same?(sig_big+sml_sh):(sig_big-sml_sh);   // 25-bit
    // normalize+pack (fp_add24_s2)
    uint32_t norm_sig; int64_t e_norm;
    if(sum & (1u<<24)){ norm_sig=(sum>>1)&0xFFFFFF; e_norm=(int64_t)e_big+1; }
    else if(sum & (1u<<23)){ norm_sig=sum&0xFFFFFF; e_norm=e_big; }
    else { norm_sig=sum&0xFFFFFF; e_norm=e_big; int found=0;
        for(int i=1;i<24 && !found;i++) if(sum&(1u<<(23-i))){ norm_sig=(sum<<i)&0xFFFFFF; e_norm=(int64_t)e_big-i; found=1; } }
    if(sum==0) return 0;
    if(e_norm<=0)  return s_big<<31;
    if(e_norm>=255)return (s_big<<31)|(0xFEu<<23)|0x7FFFFF;
    return (s_big<<31)|((uint32_t)(e_norm&0xFF)<<23)|(norm_sig&0x7FFFFF);
}
// fp_add3_24: y = a + b + c, aligned to max exp, single normalize.
static uint32_t fadd3(uint32_t a, uint32_t b, uint32_t c){
    uint32_t s[3]={a>>31,b>>31,c>>31}, e[3]={(a>>23)&0xFF,(b>>23)&0xFF,(c>>23)&0xFF};
    uint32_t w[3]={a,b,c}; uint32_t sig[3], ex[3];
    for(int i=0;i<3;i++){ int z=(e[i]==0); sig[i]=z?0:(0x800000u|(w[i]&0x7FFFFF)); ex[i]=z?0:e[i]; }
    uint32_t e_max=ex[0]; if(ex[1]>e_max)e_max=ex[1]; if(ex[2]>e_max)e_max=ex[2];
    int64_t ssum=0;
    for(int i=0;i<3;i++){ uint32_t sh=e_max-ex[i]; int64_t al=(sh>=24)?0:(sig[i]>>sh);
        ssum += s[i]? -al : al; }
    int s_res = ssum<0; uint64_t mag = s_res? (uint64_t)(-ssum) : (uint64_t)ssum;
    uint32_t norm_sig=0; int64_t e_norm=e_max; int found=0;
    if(mag&(1u<<26)){ norm_sig=(mag>>3)&0xFFFFFF; e_norm=(int64_t)e_max+3; found=1; }
    else if(mag&(1u<<25)){ norm_sig=(mag>>2)&0xFFFFFF; e_norm=(int64_t)e_max+2; found=1; }
    else if(mag&(1u<<24)){ norm_sig=(mag>>1)&0xFFFFFF; e_norm=(int64_t)e_max+1; found=1; }
    else if(mag&(1u<<23)){ norm_sig=mag&0xFFFFFF; e_norm=e_max; found=1; }
    else { for(int i=1;i<24 && !found;i++) if(mag&(1u<<(23-i))){ norm_sig=((uint32_t)mag<<i)&0xFFFFFF; e_norm=(int64_t)e_max-i; found=1; } }
    if(mag==0) return 0;
    if(e_norm<=0)  return (uint32_t)s_res<<31;
    if(e_norm>=255)return ((uint32_t)s_res<<31)|(0xFEu<<23)|0x7FFFFF;
    return ((uint32_t)s_res<<31)|((uint32_t)(e_norm&0xFF)<<23)|(norm_sig&0x7FFFFF);
}
// fp_mul_c9: f (float) * k (9-bit signed) -> float, 16-bit-mantissa.
static uint32_t fmulc9(uint32_t f, int k){
    uint32_t sf=f>>31, ef=(f>>23)&0xFF;
    if(ef==0||k==0) return (sf ^ (k<0?1u:0u))<<31;
    uint32_t ksign=(k<0)?1:0, kabs=(k<0)?(uint32_t)(-k):(uint32_t)k;
    uint32_t sig=0x8000|((f>>8)&0x7FFF);
    uint32_t prod=sig*kabs;                                // 16 x 9 -> up to 25b
    int msb=15; for(int i=15;i<=24;i++) if(prod&(1u<<i)) msb=i;
    int sh=msb-15; uint32_t norm=prod>>sh; uint32_t mant=(norm&0x7FFF)<<8;
    int64_t e=(int64_t)ef+sh; uint32_t res_sign=sf^ksign;
    if(e>=255) return (res_sign<<31)|(0xFEu<<23)|0x7FFFFF;
    return (res_sign<<31)|((uint32_t)(e&0xFF)<<23)|(mant&0x7FFFFF);
}
// fp_rcp_fast: ~1/x, seed ROM + one Newton step (matches the RTL pack()).
static uint32_t frcp(uint32_t x){
    static uint32_t rom[256]; static int init=0;
    if(!init){ for(int i=0;i<256;i++) rom[i]=(uint32_t)((0x100000000ULL)/(65536ULL+(uint64_t)i*256ULL)); init=1; }
    uint32_t sx=x>>31, ex=(x>>23)&0xFF; int xz=(ex==0);
    uint32_t m_q16=0x10000|((x>>7)&0xFFFF), idx=(x>>15)&0xFF, r0=rom[idx];
    uint64_t mr=(uint64_t)m_q16*r0;                        // Q1.32
    uint32_t two_m=(0x20000u - (uint32_t)((mr>>16)&0x3FFFF))&0x3FFFF;
    uint64_t r1_full=(uint64_t)r0*two_m; uint32_t r1=(uint32_t)((r1_full>>16)&0x1FFFF);
    uint32_t frac=(r1&0x10000)?0:((r1&0x7FFF)<<8);
    int64_t e=((r1&0x10000)?254:253)-(int64_t)ex;
    if(xz)         return (sx<<31)|(0xFEu<<23)|0x7FFFFF;
    if(e<=0)       return sx<<31;
    if(e>=255)     return (sx<<31)|(0xFEu<<23)|0x7FFFFF;
    return (sx<<31)|((uint32_t)(e&0xFF)<<23)|frac;
}
static inline uint32_t t15(uint32_t x){ return x & 0xFFFFFF00u; }   // mac16 *1.0 truncation

// SOFT-FP plane setup: refsw2 PlaneStepper3 structure, computed with the RTL FP units, so
// ddx/ddy/c come out in the SAME reduced precision as tsp_setup_stream. Returns raw u32.
// Attributes a1/a2/a3 are float32 words; verts x/y float32 words; left/top float32 (xbase).
static void planeSetupSoft(uint32_t x1,uint32_t y1,uint32_t x2,uint32_t y2,uint32_t x3,uint32_t y3,
                           uint32_t a1,uint32_t a2,uint32_t a3,uint32_t left,uint32_t top,
                           uint32_t* ddx,uint32_t* ddy,uint32_t* c){
    // GEO deltas: first operand routed through mac16 *1.0 -> t15 truncation (matches RTL).
    uint32_t dy2y1=fadd24(t15(y2),y1,1), dy3y1=fadd24(t15(y3),y1,1);
    uint32_t dx3x1=fadd24(t15(x3),x1,1), dx2x1=fadd24(t15(x2),x1,1);
    uint32_t da2=fadd24(a2,a1,1), da3=fadd24(a3,a1,1);
    // Aa = da3*dy2y1 - da2*dy3y1 ;  Ba = dx3x1*da2 - dx2x1*da3
    uint32_t Aa=fadd24(fmul16(da3,dy2y1), fmul16(da2,dy3y1), 1);
    uint32_t Ba=fadd24(fmul16(dx3x1,da2), fmul16(dx2x1,da3), 1);
    // C = dx2x1*dy3y1 - dx3x1*dy2y1  (area)
    uint32_t C=fadd24(fmul16(dx2x1,dy3y1), fmul16(dx3x1,dy2y1), 1);
    uint32_t rC=frcp(C);
    // ddx = -Aa/C = -(Aa*rC) ; ddy = -(Ba*rC)
    uint32_t nddx=fmul16(Aa,rC), nddy=fmul16(Ba,rC);
    *ddx = nddx ^ 0x80000000u; *ddy = nddy ^ 0x80000000u;
    // XL1 = x1 - left ; YT1 = y1 - top ; c = a1 - ddx*XL1 - ddy*YT1  (fp_add3_24)
    uint32_t xl1=fadd24(t15(x1),left,1), yt1=fadd24(t15(y1),top,1);
    uint32_t t_x=fmul16(*ddx,xl1)^0x80000000u;   // -ddx*XL1
    uint32_t t_y=fmul16(*ddy,yt1)^0x80000000u;   // -ddy*YT1
    *c = fadd3(a1, t_x, t_y);
}

// a diff is a REAL error only if the RTL is FAR from the ref (should now be near bit-exact).
static bool planeBad(uint32_t rtl, uint32_t ref){
    double a=(double)f32(rtl), b=(double)f32(ref), d=fabs(a-b), m=fabs(a); if(fabs(b)>m)m=fabs(b);
    double rel=(m<1e-6)?0.0:d/m;
    if(rel>g_pc_worst && d>1e-3) g_pc_worst=rel;
    return (rel>0.02 && d>0.05);
}

// golden mode for triangle_setups PLANE VALUES (ddx/ddy/c). The 660-pass span/setup
// checks don't cover plane math; this diffs a rewritten tsp_setup against the trusted
// one bit-exact. +golden writes setup_golden.txt; +checksetup diffs against it.
static int    g_setup_mode = 0;    // 0=off, 1=write golden, 2=check
static FILE*  g_setup_fp   = nullptr;
static double g_max_relerr = 0.0;  // worst relative error among REAL (non-cancellation) diffs
static double g_max_abserr = 0.0;

// A diff is a REAL error only if BOTH relative AND absolute error are large; a large
// relerr with tiny abserr is catastrophic cancellation (Aa/c subtract near-equal terms
// at 15-bit mantissa) - benign, both impls are correct to their precision.
static bool bad(uint32_t a, uint32_t b){
    float fa, fb; memcpy(&fa,&a,4); memcpy(&fb,&b,4);
    double d = fabs((double)fa - (double)fb);
    double m = fabs((double)fa); double mb = fabs((double)fb); if(mb>m) m=mb;
    double rel = (m < 1e-30) ? 0.0 : d/m;
    // ddx/ddy are bit-exact to the old unit; c differs only by the 3-way adder's single
    // normalize (more accurate), amplified by cancellation to <=~0.03 abs. Flag only a
    // genuinely large error (both large rel AND >0.1 abs).
    if(rel > 1e-2 && d > 0.1){ if(rel>g_max_relerr)g_max_relerr=rel; if(d>g_max_abserr)g_max_abserr=d; return true; }
    return false;
}

static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

// pc_slot: MUST match spanner_v2.pc_slot exactly (10-bit, 1024 slots).
static uint32_t pc_slot(uint32_t tag){
    return ((tag>>3)&0x3FF) ^ ((tag>>13)&0x3FF) ^ (tag&0x7);
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
struct Span { uint32_t idx,id,rep,at; uint32_t invw[4]; };
// per-id expected setup (black-box golden): decoded record + refsw2 planes, filled at id
// bump-allocation. gv[id]=1 when written. ddx/ddy/c[p] are DOUBLE-precision refs (plane p:
// 0=U 1=V 2..5=Col 6..9=Ofs, all *z; U/V iff textured, Ofs iff offset). pvalid[p] marks
// planes the RTL actually computes.
struct SetupGold { bool valid; uint32_t isp,tsp,tcw; bool pvalid[10]; uint32_t ddx[10],ddy[10],c[10]; };
static void golden(const Vec& vc, std::vector<Span>& out,
                   SetupGold* sg=nullptr, uint32_t param_base=0, bool intensity=false,
                   uint32_t leftx=0, uint32_t topy=0){
    // bump-allocated ids: dedup map (direct-mapped by pc_slot) -> {tag, id}; id = top++.
    uint32_t map_valid[1024]={0}, map_tag[1024], map_id[1024]; uint32_t top=0;
    int x=0;
    while(x<1024){
        int lane=x&3;
        uint32_t tag=vc.tag[x];
        int rep=1;
        // POLARITY: the captured header shade_mode is the OLD peel_core convention (=ti_mode:
        // 0=OP, 1=PEEL). spanner_v2's shade_mode is 1=OP(shade-all), 0=PEEL(gate on valid) --
        // the live peel_core feeds it ~ti_mode. So INVERT the header value here (and at the
        // DUT feed below) so the unit test matches how peel_core actually drives the module.
        bool sm_shadeall = (vc.shade_mode == 0);   // OP -> shade all
        auto shok=[&](int p){ return sm_shadeall ? 1u : (vc.valid[p]?1u:0u); };
        // Coalesce (matches spanner_v2): SHADED start extends on shaded + same tag; INVALID
        // start extends on invalid (ignoring tag). Only a SHADED run emits a span; invalid
        // runs just advance x. No shade mask (every emitted span is uniformly shaded).
        bool run_ok0 = shok(x)!=0;
        for(int l=lane+1; l<4; l++){
            bool okl = shok((x&~3)+l)!=0;
            if(okl==run_ok0 && (run_ok0 ? (vc.tag[(x&~3)+l]==tag) : true)) rep++;
            else break;
        }
        if(!run_ok0){ x += rep; continue; }   // invalid run: no span, skip
        uint32_t h=pc_slot(tag), id=0;
        if(map_valid[h] && map_tag[h]==tag){ id=map_id[h]; }              // dedup hit
        else {
            id=top++; map_valid[h]=1; map_tag[h]=tag; map_id[h]=id;       // bump-allocate
            // BLACK-BOX golden: decode this tag's record from VRAM + compute refsw2 planes.
            if(sg){
                Rec r = decode_record(tag, param_base, intensity);
                SetupGold& g = sg[id]; g.valid=true; g.isp=r.isp; g.tsp=r.tsp; g.tcw=r.tcw;
                bool tex=(r.isp>>25)&1, of=(r.isp>>24)&1, gou=(r.isp>>23)&1;
                for(int p=0;p<10;p++){
                    g.pvalid[p] = !((p<=1 && !tex) || (p>=6 && !of));
                    if(!g.pvalid[p]) continue;
                    // prime the per-vertex attribute in the SAME reduced FP as the RTL:
                    //  U/V  = fmul16(z, uv)      (float * float)
                    //  Col  = fmul_c9(z, chan)   (float * 9-bit signed colour channel)
                    //  Ofs  = fmul_c9(z, chan)
                    auto attr=[&](int vtx)->uint32_t{
                        uint32_t z=r.z[vtx];
                        if(p==0) return fmul16(z, r.u[vtx]);
                        if(p==1) return fmul16(z, r.v[vtx]);
                        if(p>=2&&p<=5){ uint32_t cc=gou?r.col[vtx]:r.col[2]; return fmulc9(z,(int)((cc>>(8*(p-2)))&0xFF)); }
                        uint32_t oo=gou?r.ofs[vtx]:r.ofs[2]; return fmulc9(z,(int)((oo>>(8*(p-6)))&0xFF));
                    };
                    planeSetupSoft(r.x[0],r.y[0],r.x[1],r.y[1],r.x[2],r.y[2],
                                   attr(0),attr(1),attr(2), leftx,topy, &g.ddx[p],&g.ddy[p],&g.c[p]);
                }
            }
        }
        Span s; s.idx=x; s.id=id; s.rep=rep; s.at=vc.pt[x];
        for(int k=0;k<4;k++) s.invw[k] = (k<rep) ? vc.invw[(x&~3)+lane+k] : 0;
        out.push_back(s);
        x += rep;
    }
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    const char* dir = (argc>1 && argv[1][0]!='+') ? argv[1] : "spanner_test_vectors";
    int first = (argc>2 && argv[2][0]!='+') ? atoi(argv[2]) : 0;
    int count = (argc>3 && argv[3][0]!='+') ? atoi(argv[3]) : 8;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"+golden"))    g_setup_mode=1;
        if(!strcmp(argv[i],"+checksetup"))g_setup_mode=2;
        if(!strcmp(argv[i],"+planecheck"))g_planecheck=true;
    }
    char gpath[512]; snprintf(gpath,sizeof(gpath),"%s/setup_golden.txt",dir);
    if(g_setup_mode==1){ g_setup_fp=fopen(gpath,"w"); }
    if(g_setup_mode==2){ g_setup_fp=fopen(gpath,"r");
        if(!g_setup_fp){ printf("no %s (run +golden first)\n",gpath); return 1; } }

    dut=new Vspanner_v2_tb_top;
    dut->clk=0; dut->reset=1;
    ROOT->spanner_v2_tb_top__DOT__start=0;

    char vpath[512]; snprintf(vpath,sizeof(vpath),"%s/vram.bin",dir);
    // reset a few cycles first so sim_ddr_fb settles, then load VRAM
    for(int i=0;i<20;i++) tick();
    load_vram(vpath);
    dut->reset=0; tick();
    ROOT->spanner_v2_tb_top__DOT__tsp_rd_done=0;

    int total_fail=0, total_pass=0; long total_cyc=0, practical_cyc=0;
    long total_distinct=0, total_runs=0;   // dedup: distinct setups vs actual engine runs
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

        // INVERT: header shade_mode is old-peel_core ti_mode (0=OP,1=PEEL); spanner_v2 wants
        // 1=OP(shade-all),0=PEEL(gate) -> feed ~header (matches live peel_core's ~ti_mode).
        ROOT->spanner_v2_tb_top__DOT__shade_mode = (vc.shade_mode==0) ? 1u : 0u;
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
        total_cyc += cyc;
        // practical: a tile can't finish faster than its shade stage (1024px @1px/clk), so
        // a fast spanner tile is floored at 1024 - spare time can't offset a slow tile.
        practical_cyc += (cyc < 1024) ? 1024 : cyc;
        total_runs += ROOT->spanner_v2_tb_top__DOT__setup_runs;

        {
            std::vector<Span> gold;
            static SetupGold sgold[1024];
            for(int i=0;i<1024;i++) sgold[i].valid=false;
            golden(vc, gold, g_planecheck?sgold:nullptr,
                   vc.param_base, vc.intensity!=0, vc.xbase, vc.ybase);

            int fails=0;
            // 1) DENSELY PACKED spans: gold[] is in SPANGEN emission order == the DUT's dense
            // slots. Compare slot-by-slot (slot k = the k-th emitted span), including the
            // run-start pixel (spo_x = sp_idx data). Then check the span COUNT via sp_last.
            for(size_t k=0;k<gold.size();k++){
                const Span& s=gold[k];
                if(!SPO_VALID[k]){
                    if(fails<10) printf("pass %d: MISSING span at slot %zu (x=%u id=%u rep=%u)\n",n,k,s.idx,s.id,s.rep);
                    fails++; continue;
                }
                if(SPO_X[k]!=s.idx || SPO_ID[k]!=s.id || SPO_REP[k]!=s.rep
                   || SPO_AT[k]!=(s.at&1)){
                    if(fails<10) printf("pass %d: span slot %zu MISMATCH: got x=%u id=%u rep=%u at=%u  want x=%u id=%u rep=%u at=%u\n",
                        n,k, SPO_X[k],SPO_ID[k],SPO_REP[k],SPO_AT[k],
                        s.idx,s.id,s.rep,s.at&1);
                    fails++;
                }
                uint32_t giv[4]={SPO_INVW0[k],SPO_INVW1[k],SPO_INVW2[k],SPO_INVW3[k]};
                for(uint32_t j=0;j<s.rep;j++) if(giv[j]!=s.invw[j]){
                    if(fails<10) printf("pass %d: span slot %zu invw[%u] got %08x want %08x\n",n,k,j,giv[j],s.invw[j]);
                    fails++;
                }
            }
            // 2) span COUNT matches: DUT sp_last range [0..sp_last] (or empty) == gold.size().
            {
                uint32_t dut_cnt = SP_CNT_Z ? 0u : (SP_LAST+1u);
                if(dut_cnt != gold.size()){
                    if(fails<10) printf("pass %d: span COUNT mismatch: dut=%u gold=%zu (sp_first=%u sp_last=%u z=%u)\n",
                        n, dut_cnt, gold.size(), SP_FIRST, SP_LAST, SP_CNT_Z);
                    fails++;
                }
                // no stray valid slot beyond the count
                for(size_t i=gold.size(); i<1024 && (int)i<(int)gold.size()+8; i++)
                    if(SPO_VALID[i]){ if(fails<10) printf("pass %d: EXTRA span at slot %zu\n",n,i); fails++; }
            }
            // 3) every allocated setup id got a triangle_setups write (bump-allocated ids).
            // Mirror the spanner run rule: SHADED-start coalesces same-elig+same-tag and
            // ALLOCATES; INVALID-start coalesces same-elig (ignoring tag) and does NOT alloc.
            bool need_setup[1024]={false};
            {
                bool sa = (vc.shade_mode==0);   // OP -> shade all
                auto ok=[&](int p){ return sa || vc.valid[p]!=0; };
                static uint32_t mv[1024],mt[1024],mi[1024]; memset(mv,0,sizeof(mv));
                uint32_t top=0; int x=0;
                while(x<1024){
                    uint32_t tag=vc.tag[x]; bool ok0=ok(x); uint32_t h=pc_slot(tag);
                    if(ok0 && !(mv[h] && mt[h]==tag)){ uint32_t id=top++; mv[h]=1; mt[h]=tag; mi[h]=id; need_setup[id]=true; }
                    int lane=x&3,rep=1;
                    for(int l=lane+1;l<4;l++){
                        if(ok((x&~3)+l)==ok0 && (ok0 ? (vc.tag[(x&~3)+l]==tag):true)) rep++;
                        else break;
                    }
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

            // ---- plane VALUE golden dump / check (ddx/ddy/c per written id, 10 planes) ----
            if(g_setup_mode && g_setup_fp){
                for(int id=0;id<1024;id++){
                    if(!TSG_VALID[id]) continue;
                    for(int p=0;p<10;p++){
                        uint32_t dx=TSG_DDX[id][p], dy=TSG_DDY[id][p], cc=TSG_C[id][p];
                        if(g_setup_mode==1){
                            fprintf(g_setup_fp,"%d %d %d %08x %08x %08x\n",n,id,p,dx,dy,cc);
                        } else { // check
                            int gn,gid,gp; uint32_t gdx,gdy,gcc;
                            if(fscanf(g_setup_fp,"%d %d %d %x %x %x\n",&gn,&gid,&gp,&gdx,&gdy,&gcc)!=6){
                                if(fails<10) printf("pass %d: golden EOF at id %d p %d\n",n,id,p); fails++; continue;
                            }
                            if(gn!=n||gid!=id||gp!=p){
                                if(fails<10) printf("pass %d: golden DESYNC got %d/%d/%d want %d/%d/%d\n",n,gn,gid,gp,n,id,p);
                                fails++;
                            } else if(bad(dx,gdx) || bad(dy,gdy) || bad(cc,gcc)){
                                if(fails<10) printf("pass %d: id %d plane %d MATH: ddx %08x/%08x ddy %08x/%08x c %08x/%08x\n",
                                    n,id,p,dx,gdx,dy,gdy,cc,gcc);
                                fails++;
                            }
                        }
                    }
                }
            }

            // ---- BLACK-BOX plane check (+planecheck): C++ decoded record + refsw2 planes
            // (computed in golden() from the INPUT tag buffer + VRAM) vs triangle_setups[id].
            if(g_planecheck){
                for(int id=0; id<1024; id++){
                    bool dutv = TSG_VALID[id]; bool refv = sgold[id].valid;
                    if(!dutv && !refv) continue;
                    if(dutv != refv){
                        if(fails<10) printf("pass %d: id %d VALID mismatch dut=%d ref=%d\n",n,id,dutv,refv);
                        fails++; continue;
                    }
                    SetupGold& g = sgold[id];
                    if(TSG_ISP[id]!=g.isp || TSG_TSP[id]!=g.tsp || TSG_TCW[id]!=g.tcw){
                        if(fails<10) printf("pass %d: id %d HDR mismatch isp %08x/%08x tsp %08x/%08x tcw %08x/%08x\n",
                            n,id, TSG_ISP[id],g.isp, TSG_TSP[id],g.tsp, TSG_TCW[id],g.tcw);
                        fails++;
                    }
                    for(int p=0;p<10;p++){
                        if(!g.pvalid[p]) continue;
                        bool bx=planeBad(TSG_DDX[id][p],g.ddx[p]);
                        bool by=planeBad(TSG_DDY[id][p],g.ddy[p]);
                        bool bc=planeBad(TSG_C  [id][p],g.c  [p]);
                        if(bx||by||bc){
                            if(fails<10) printf("pass %d: id %d plane %d PLANECHECK dut/ref: "
                                "ddx %08x/%08x (%g/%g)  ddy %08x/%08x  c %08x/%08x (%g/%g)  isp=%08x\n",
                                n,id,p, TSG_DDX[id][p],g.ddx[p], f32(TSG_DDX[id][p]),f32(g.ddx[p]),
                                TSG_DDY[id][p],g.ddy[p],
                                TSG_C[id][p],g.c[p], f32(TSG_C[id][p]),f32(g.c[p]), g.isp);
                            fails++;
                        }
                    }
                }
            }

            total_distinct += n_written;
            if(fails==0){
                uint32_t ec = ROOT->spanner_v2_tb_top__DOT__emit_count;
                uint32_t le = ROOT->spanner_v2_tb_top__DOT__last_emit_cyc;
                printf("pass %d: OK  (%zu spans, %d setups, cyc=%ld | spangen: %u spans by cyc %u -> %.2f cyc/span)\n",
                       n,gold.size(),n_written,cyc, ec, le, ec? (double)le/ec : 0.0);
                total_pass++;
            }
            else        { printf("pass %d: %d FAILURES (cyc=%ld)\n",n,fails,cyc); total_fail++; }
        }
        // model TSP finishing this tile: pulse tsp_rd_done so the ring frees (tail catches
        // up) and the next pass normalizes ids back to 0.
        ROOT->spanner_v2_tb_top__DOT__tsp_rd_done=1; tick();
        ROOT->spanner_v2_tb_top__DOT__tsp_rd_done=0; tick();
        next:;
    }

    if(g_setup_mode==2) printf("setup plane check: worst REAL diff relerr=%.4g abserr=%.4g\n", g_max_relerr, g_max_abserr);
    if(g_planecheck)    printf("planecheck (vs refsw2 double golden): worst rel diff = %.4g\n", g_pc_worst);
    printf("\n==== spanner_v2 TB: %d passed, %d failed ====\n", total_pass, total_fail);
    printf("     total spanner cycles = %ld   practical (>=1024/tile) = %ld\n",
           total_cyc, practical_cyc);
    printf("     setups: %ld distinct, %ld engine runs (%.1fx re-setup from dedup thrash)\n",
           total_distinct, total_runs, total_distinct? (double)total_runs/total_distinct : 0.0);
    return total_fail ? 1 : 0;
}

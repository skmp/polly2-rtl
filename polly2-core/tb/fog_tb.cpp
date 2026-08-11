// fog_tb - FOG unit regression: reg_file write-time precompute + fog_lut + fog_blend
// against a C model of refsw2's LookupFogTable / FogUnit.
//
// What is checked
//   1. LUT PATH  : random FOG_DENSITY + random 128-entry fog table + random 1/W ->
//                  fog alpha. The model reproduces the RTL's arithmetic contract
//                  exactly (truncating fp_mul24 product, raw 8-bit blend weights),
//                  so this is a bit-exact compare, and it covers the write-time
//                  {base255, delta} / density-to-f32 precompute since the tb writes
//                  RAW host words through reg_file.
//   2. BLEND PATH: every FogCtrl x ColorClamp x Offset combination over random
//                  colours / clamp windows / fog colours -> final ARGB, bit-exact.
//   3. DIRECTED  : the FOG_DENSITY encoding (0xFF07 is 255.0, so a pixel Z of 1/255
//                  gives 1/W = 1.0 -> table address 0), the two clamp rails, and the
//                  table-address field split.
//
// Also REPORTED (not failed on) is the drift of the RTL's raw *255/256 weights vs
// refsw2's to_u8_256() 0..256 rescale - the deliberate ~1 LSB house convention - and
// the drift of the truncating multiply vs a true IEEE one, so a change in either
// convention shows up as a number rather than as a silent golden-image diff.
#include "Vfog_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>

static Vfog_tb_top* dut;
static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

static const int FOGLAT_MAX = 7;   // fog_lut latency (see its header) - stall sweep range

static uint32_t rng_s = 0x12345678u;
static uint32_t rnd(){ rng_s ^= rng_s<<13; rng_s ^= rng_s>>17; rng_s ^= rng_s<<5; return rng_s; }

// ---------------- model: the core's non-IEEE multiply (fp_mul16) ----------------
// 16-bit significands (hidden 1 + top 15 mantissa bits), DaZ, truncate (no rounding),
// no inf/NaN, underflow flushes, overflow saturates, exact +-1.0 passthrough.
static uint32_t fp_mul16(uint32_t a, uint32_t b){
    uint32_t sa=a>>31, sb=b>>31, ea=(a>>23)&0xFF, eb=(b>>23)&0xFF;
    uint32_t sign=sa^sb;
    if(ea==0 || eb==0) return sign<<31;
    if((a&0x7FFFFFFFu)==0x3F800000u) return (sign<<31)|(b&0x7FFFFFFFu);
    if((b&0x7FFFFFFFu)==0x3F800000u) return (sign<<31)|(a&0x7FFFFFFFu);
    uint32_t siga = 0x8000u | ((a>>8) & 0x7FFFu);
    uint32_t sigb = 0x8000u | ((b>>8) & 0x7FFFu);
    uint64_t prod = (uint64_t)siga*sigb;
    int e_sum = (int)ea + (int)eb - 127;
    int top = (prod>>31)&1;
    uint32_t mant = top ? (uint32_t)((prod>>8)&0x7FFFFF) : (uint32_t)((prod>>7)&0x7FFFFF);
    int e_adj = top ? e_sum+1 : e_sum;
    if(e_adj<=0)  return sign<<31;
    if(e_adj>=255) return (sign<<31)|(0xFEu<<23)|0x7FFFFF;
    return (sign<<31)|((uint32_t)e_adj<<23)|mant;
}

// ---------------- model: FOG_DENSITY {mant[15:8], exp[7:0] s8} -> f32 -------------
// den = (mant/128) * 2^exp, normalized (the reg_file write-time convert).
static uint32_t fog_den_f32(uint32_t reg){
    uint32_t m = (reg>>8)&0xFF;
    int e = (int8_t)(reg&0xFF);
    if(m==0) return 0;
    int msb=0; for(int i=0;i<8;i++) if(m&(1u<<i)) msb=i;
    int ef = 127 + e - 7 + msb;
    if(ef<=0)   return 0;
    if(ef>=255) return (0xFEu<<23)|0x7FFFFF;
    uint32_t mant = ((m << (23-msb)) & 0x7FFFFF);
    return ((uint32_t)ef<<23)|mant;
}

// ---------------- model: LookupFogTable ------------------------------------------
// use_256: refsw2's to_u8_256 rescale; else the RTL's raw 8-bit weights (*255/256).
// ieee_mul: true IEEE product instead of the core's truncating one.
static uint32_t u8_256(uint32_t v){ return v + (v>>7); }
static uint8_t lookup_fog(uint32_t den_f32, uint32_t invw, const uint32_t* table,
                          bool use_256, bool ieee_mul, uint32_t* out_index=nullptr,
                          uint32_t* out_bf=nullptr){
    uint32_t fw;
    if(ieee_mul){
        float fa, fb; memcpy(&fa,&den_f32,4); memcpy(&fb,&invw,4);
        // match the DaZ contract so only the rounding differs
        if(((den_f32>>23)&0xFF)==0 || ((invw>>23)&0xFF)==0) fw = 0;
        else { float p = fa*fb; memcpy(&fw,&p,4); }
    } else fw = fp_mul16(den_f32, invw);

    uint32_t mag = fw & 0x7FFFFFFFu;
    bool neg = (fw>>31)&1;
    if(neg || mag < 0x3F800000u) mag = 0x3F800000u;      // 1.0f
    else if(mag > 0x437FFFFFu)   mag = 0x437FFFFFu;      // 255.999985f
    uint32_t e = (mag>>23)&0xFF, m = mag&0x7FFFFF;
    uint32_t index = (((e+1)&7)<<4) | ((m>>19)&0xF);
    uint32_t bf    = (m>>11)&0xFF;
    if(out_index) *out_index=index;
    if(out_bf)    *out_bf=bf;
    uint32_t b0 = table[index]&0xFF, b1 = (table[index]>>8)&0xFF;
    if(use_256) return (uint8_t)((b0*u8_256(bf) + b1*u8_256(255^bf))>>8);
    return (uint8_t)((b0*bf + b1*(255-bf))>>8);
}

// ---------------- model: FogUnit blend -------------------------------------------
static uint32_t fog_blend_model(uint32_t col, uint8_t fog_alpha, uint8_t offs_a,
                                uint32_t fog_ctrl, bool color_clamp, bool pp_offset,
                                uint32_t col_ram, uint32_t col_vert,
                                uint32_t cmax, uint32_t cmin, bool use_256){
    uint8_t c[4];
    for(int i=0;i<4;i++){
        uint8_t v=(col>>(8*i))&0xFF;
        if(color_clamp){
            uint8_t mx=(cmax>>(8*i))&0xFF, mn=(cmin>>(8*i))&0xFF;
            if(v>mx) v=mx;
            if(v<mn) v=mn;
        }
        c[i]=v;
    }
    auto mix=[&](uint8_t a, uint8_t cc, uint8_t f)->uint8_t{
        if(use_256) return (uint8_t)((cc*u8_256(255^a) + f*u8_256(a))>>8);
        return (uint8_t)((cc*255 + (int)(f-cc)*a)>>8);
    };
    if(fog_ctrl==0 || fog_ctrl==3){
        if(fog_ctrl==3){
            for(int i=0;i<3;i++) c[i]=(col_ram>>(8*i))&0xFF;
            c[3]=fog_alpha;
        } else {
            for(int i=0;i<3;i++) c[i]=mix(fog_alpha, c[i], (col_ram>>(8*i))&0xFF);
        }
    } else if(fog_ctrl==1 && pp_offset){
        for(int i=0;i<3;i++) c[i]=mix(offs_a, c[i], (col_vert>>(8*i))&0xFF);
    }
    return ((uint32_t)c[3]<<24)|((uint32_t)c[2]<<16)|((uint32_t)c[1]<<8)|c[0];
}

// ---------------- host writes -----------------------------------------------------
static void wr(uint32_t addr, uint32_t data){
    dut->wr_addr=addr; dut->wr_data=data; dut->wr_en=1; tick(); dut->wr_en=0;
}
// PVR register offsets (rtl/gen/pvr_regs_gen.svh)
enum { OFF_FOG_COL_RAM=0x0B0, OFF_FOG_COL_VERT=0x0B4, OFF_FOG_DENSITY=0x0B8,
       OFF_FOG_CLAMP_MAX=0x0BC, OFF_FOG_CLAMP_MIN=0x0C0, OFF_FOG_TABLE=0x200 };

static int fails=0, checks=0;
static void fail(const char* what, uint32_t got, uint32_t want, const char* ctx){
    if(fails<20) printf("FAIL %s: got %08x want %08x   (%s)\n", what, got, want, ctx);
    fails++;
}

// ---------------- LUT path ---------------------------------------------------------
// Issues a burst of 1/W values back-to-back and checks the emitted alphas in order.
struct LutJob { uint32_t invw; uint8_t want; uint32_t index, bf; };

// spos/swidth optionally inject a stall of `swidth` cycles starting `spos` cycles in.
// The caller contract is the shade front's: hold the input stable, do not advance the
// issue pointer, and gate out_valid with ~stall (it legitimately HOLDS while frozen).
static void run_lut_burst(LutJob* jobs, int n, const char* ctx,
                          int spos=-1, int swidth=0){
    int issued=0, got=0, cyc=0;
    dut->lut_valid=0; dut->lut_stall=0;
    while(got<n && cyc < n + swidth + 256){
        bool stalling = (spos>=0) && (cyc>=spos) && (cyc<spos+swidth);
        dut->lut_stall = stalling;
        dut->lut_valid = (issued<n) && !stalling;
        dut->invw      = (issued<n) ? jobs[issued].invw : 0;
        tick();
        cyc++;
        if(!stalling && issued<n) issued++;
        if(dut->lut_ov && !stalling){
            checks++;
            if(dut->lut_alpha != jobs[got].want){
                char buf[192];
                snprintf(buf,sizeof(buf),"%s invw=%08x index=%u bf=%u",
                         ctx, jobs[got].invw, jobs[got].index, jobs[got].bf);
                fail("fog_lut alpha", dut->lut_alpha, jobs[got].want, buf);
            }
            got++;
        }
    }
    if(got<n) fail("fog_lut burst stalled out", got, n, ctx);
    dut->lut_valid=0; dut->lut_stall=0;
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Vfog_tb_top;
    dut->clk=0; dut->reset=1; dut->wr_en=0; dut->lut_valid=0; dut->bl_valid=0;
    dut->invw=0; dut->bl_col=0; dut->bl_fog_alpha=0; dut->bl_offs_a=0;
    dut->bl_fog_ctrl=0; dut->bl_color_clamp=0; dut->bl_pp_offset=0; dut->lut_stall=0;
    for(int i=0;i<8;i++) tick();
    dut->reset=0; tick();

    // ---------------- 1. LUT path ----------------
    uint32_t table[128];
    int rescale_drift=0, rescale_max=0, mul_drift=0;
    for(int round=0; round<24; round++){
        // fresh table + density through the normal host write path
        for(int i=0;i<128;i++){
            table[i] = rnd() & 0xFFFF;
            wr(OFF_FOG_TABLE + 4*i, table[i]);
        }
        // densities: 255.0, unity, and random {mant,exp} pairs
        uint32_t dens = (round==0) ? 0xFF07u : (round==1) ? 0x8000u : (rnd()&0xFFFF);
        wr(OFF_FOG_DENSITY, dens);
        uint32_t den = fog_den_f32(dens);

        const int N=256;
        LutJob jobs[N];
        for(int i=0;i<N;i++){
            uint32_t invw;
            switch(i&7){
                // exercise the rails and the whole exponent range, not just noise
                case 0: invw = 0; break;                                  // 0 -> low clamp
                case 1: invw = 0x3F800000u; break;                        // 1.0
                case 2: invw = 0x7F000000u; break;                        // huge -> high clamp
                case 3: invw = 0x3F800000u + (rnd()&0x7FFFFF); break;     // [1,2)
                default: invw = ((rnd()%40 + 100)<<23) | (rnd()&0x7FFFFF); break;
            }
            jobs[i].invw = invw;
            jobs[i].want = lookup_fog(den, invw, table, false, false,
                                      &jobs[i].index, &jobs[i].bf);
            // informational drift vs the two reference conventions
            uint8_t ref256 = lookup_fog(den, invw, table, true,  false);
            uint8_t refieee= lookup_fog(den, invw, table, false, true);
            int d = (int)ref256 - (int)jobs[i].want;
            if(d) { rescale_drift++; if(abs(d)>rescale_max) rescale_max=abs(d); }
            if(refieee != jobs[i].want) mul_drift++;
        }
        char ctx[64]; snprintf(ctx,sizeof(ctx),"round %d dens=%04x",round,dens);
        run_lut_burst(jobs,N,ctx);
    }

    // ---------------- 1b. STALL: a stall anywhere must not change one alpha ----------
    // This is the case that caught a real bug. reg_file's FOG_TABLE read register is a
    // STAGE of fog_lut's pipeline (it sits between the address stage S3 and the capture
    // stage S5), and it used to be free-running. A pixel frozen in S4 then had its entry
    // overwritten by the read of the S3 address - the NEXT pixel's index - and S5 latched
    // the wrong entry when the stall lifted. The valid strobes stay perfectly aligned
    // through all of it, so ONLY a data compare across an injected stall can see it.
    // Consecutive 1/W values are made to land on DIFFERENT table indices on purpose: a
    // stall between two pixels of the same index would read back the same entry and hide
    // the fault.
    {
        for(int i=0;i<128;i++){ table[i] = rnd() & 0xFFFF; wr(OFF_FOG_TABLE+4*i, table[i]); }
        wr(OFF_FOG_DENSITY, 0x8000);                 // {mant 0x80, exp 0} = 1.0
        uint32_t den = fog_den_f32(0x8000);

        const int N=48;
        LutJob jobs[N];
        for(int i=0;i<N;i++){
            // density 1.0 passes 1/W through exactly, so the table address is built here
            // directly: index = ((e+1)&7)<<4 | m[22:19]. Stepping BOTH fields every job
            // guarantees consecutive pixels read different entries, which is what makes a
            // lost entry observable. Exponents 127..134 keep fw off both clamp rails.
            uint32_t e = 127 + (i % 8), nib = i % 16, bf = (i * 37u) & 0xFF;
            jobs[i].invw = (e<<23) | (nib<<19) | (bf<<11);
            jobs[i].want = lookup_fog(den, jobs[i].invw, table, false, false,
                                      &jobs[i].index, &jobs[i].bf);
        }
        int idx_changes=0;
        for(int i=1;i<N;i++) if(jobs[i].index != jobs[i-1].index) idx_changes++;
        checks++;
        if(idx_changes < N/2)
            fail("stall-test coverage", idx_changes, N/2,
                 "consecutive jobs must mostly hit different table indices");

        int before = fails;
        run_lut_burst(jobs, N, "stall sweep reference");     // no stall: the baseline
        for(int width=1; width<=3; width++)
            for(int pos=0; pos<N+FOGLAT_MAX; pos++){
                char ctx[64]; snprintf(ctx,sizeof(ctx),"stall w=%d @%d",width,pos);
                run_lut_burst(jobs, N, ctx, pos, width);
            }
        if(fails==before) printf("  ok  stall sweep: %d positions x widths 1-3, alphas unchanged\n",
                                 N+FOGLAT_MAX);
    }

    // ---------------- 2. directed: the FOG_DENSITY encoding ----------------
    // FOG_DENSITY 0xFF07 is {mantissa 0xFF, exponent 7} = 255.0, so a pixel Z of
    // 1/255.0 gives 1/W = 1.0 -> table address 0 with blend factor 0, and the alpha is
    // the entry's UPPER byte (the coefficient AT that address).
    {
        for(int i=0;i<128;i++){ table[i] = 0x1000u + i*3; wr(OFF_FOG_TABLE+4*i, table[i]); }
        wr(OFF_FOG_DENSITY, 0xFF07);
        float z = 1.0f/255.0f; uint32_t zb; memcpy(&zb,&z,4);
        LutJob j[2];
        j[0].invw=zb; j[0].index=0; j[0].bf=0;
        j[0].want=lookup_fog(fog_den_f32(0xFF07), zb, table, false, false, &j[0].index, &j[0].bf);
        j[1]=j[0];
        run_lut_burst(j,2,"density 255.0");
        checks++;
        if(j[0].index != 0)
            fail("density 255.0 table address", j[0].index, 0, "1/W should land at address 0");
        // bf=0 -> the entry's UPPER byte ("the coefficient where 1/W equals that
        // address"), carrying the raw-weight *255/256 rounding.
        uint32_t want0 = (((table[0]>>8)&0xFF) * 255) >> 8;
        if((j[0].want & 0xFF) != want0)
            fail("density 255.0 alpha source", j[0].want, want0,
                 "bf=0 must return the entry's upper byte");
    }

    // ---------------- 3. blend path ----------------
    {
        uint32_t col_ram=0, col_vert=0, cmax=0, cmin=0;
        for(int round=0; round<64; round++){
            col_ram = rnd(); col_vert = rnd();
            cmax = rnd(); cmin = rnd();
            wr(OFF_FOG_COL_RAM, col_ram);   wr(OFF_FOG_COL_VERT, col_vert);
            wr(OFF_FOG_CLAMP_MAX, cmax);    wr(OFF_FOG_CLAMP_MIN, cmin);

            const int N=64;
            uint32_t want[N]; int issued=0, got=0;
            struct { uint32_t col; uint8_t fa, oa; uint32_t fc; bool cc, po; } in[N];
            for(int i=0;i<N;i++){
                in[i].col = rnd(); in[i].fa = rnd()&0xFF; in[i].oa = rnd()&0xFF;
                in[i].fc  = (i&3);                    // sweep all four FogCtrl codes
                in[i].cc  = (i>>2)&1; in[i].po = (i>>3)&1;
                want[i] = fog_blend_model(in[i].col, in[i].fa, in[i].oa, in[i].fc,
                                          in[i].cc, in[i].po, col_ram, col_vert,
                                          cmax, cmin, false);
            }
            dut->bl_valid=0;
            while(got<N){
                bool go = issued<N;
                dut->bl_valid=go;
                if(go){
                    dut->bl_col=in[issued].col; dut->bl_fog_alpha=in[issued].fa;
                    dut->bl_offs_a=in[issued].oa; dut->bl_fog_ctrl=in[issued].fc;
                    dut->bl_color_clamp=in[issued].cc; dut->bl_pp_offset=in[issued].po;
                }
                tick();
                if(go) issued++;
                if(dut->bl_ov){
                    checks++;
                    if(dut->bl_col_out != want[got]){
                        char buf[192];
                        snprintf(buf,sizeof(buf),"col=%08x fa=%u oa=%u ctrl=%u clamp=%d ofs=%d",
                                 in[got].col, in[got].fa, in[got].oa, in[got].fc,
                                 in[got].cc, in[got].po);
                        fail("fog_blend", dut->bl_col_out, want[got], buf);
                    }
                    got++;
                }
            }
            dut->bl_valid=0;
        }
    }

    printf("fog: %d checks, %d failures\n", checks, fails);
    printf("  convention drift (informational, not a failure):\n");
    printf("    raw *255/256 weights vs refsw2 to_u8_256 : %d LUT samples differ (max %d LSB)\n",
           rescale_drift, rescale_max);
    printf("    truncating fp_mul16 vs IEEE product      : %d LUT samples differ\n", mul_drift);
    dut->final();
    if(fails){ printf("=== FOG TEST FAILED ===\n"); return 1; }
    printf("=== fog test passed ===\n");
    return 0;
}

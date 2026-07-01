// reg_file unit test: writes scalar regs by real PVR byte offset and reads them
// back via the struct (raw + bitfield-decoded); writes/reads the FOG (0x200) and
// PAL (0x1000) M10K tables via their read ports. Offsets/decode mirror pvr_regs.h.
#include "Vreg_file_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static Vreg_file_tb_top* dut;
static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }
static uint32_t rng=0x5Aada99d;
static uint32_t rnd(){uint32_t x=rng;x^=x<<13;x^=x>>17;x^=x<<5;rng=x;return x;}

static void wr(uint32_t off,uint32_t val){
    dut->wr_en=1; dut->wr_addr=off; dut->wr_data=val; tick(); dut->wr_en=0;
}

// PVR offsets (from pvr_regs.h)
enum { OFF_PARAM_BASE=0x020, OFF_REGION_BASE=0x02C, OFF_ISP_BACKGND_T=0x08C,
       OFF_FOG_TABLE=0x200, OFF_PAL=0x1000 };

int fails=0,total=0;
static void chk(const char*n,uint32_t got,uint32_t exp){
    total++; if(got!=exp){fails++; if(fails<20) printf("  %s: got %08x exp %08x\n",n,got,exp);}
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Vreg_file_tb_top;
    dut->clk=0; dut->reset=1; dut->wr_en=0; dut->wr_addr=0; dut->wr_data=0;
    dut->fog_raddr=0; dut->pal_raddr=0;
    for(int i=0;i<4;i++)tick(); dut->reset=0; tick();

    // ---- scalar regs ----
    wr(OFF_PARAM_BASE, 0xDEAD0020);
    wr(OFF_REGION_BASE,0xBEEF002C);
    tick();
    chk("param_base",  dut->o_param_base,  0xDEAD0020);
    chk("region_base", dut->o_region_base, 0xBEEF002C);

    // ---- bitfield reg: ISP_BACKGND_T {tag_offset:3, param_offs:21, skip:3, shadow:1, ...} ----
    // build a word: shadow=1 (bit27), skip=5 (bits26:24), param_offs=0x12345 (bits23:3), tag_offset=6 (bits2:0)
    uint32_t ispt = (6u & 7) | ((0x12345u & 0x1FFFFF)<<3) | ((5u&7)<<24) | (1u<<27);
    wr(OFF_ISP_BACKGND_T, ispt);
    tick();
    chk("ispt_raw",        dut->o_isp_backgnd_t,   ispt);
    chk("ispt_param_offs", dut->o_ispt_param_offs, 0x12345);
    chk("ispt_skip",       dut->o_ispt_skip,       5);
    chk("ispt_shadow",     dut->o_ispt_shadow,     1);

    // ---- FOG table (128 x 32) ----
    uint32_t fogvals[128];
    for(int i=0;i<128;i++){ fogvals[i]=rnd(); wr(OFF_FOG_TABLE + i*4, fogvals[i]); }
    for(int i=0;i<128;i++){
        dut->fog_raddr=i; tick(); tick();   // registered read (1 cyc) + settle
        char nm[24]; snprintf(nm,sizeof(nm),"fog[%d]",i);
        chk(nm, dut->fog_rdata, fogvals[i]);
    }

    // ---- PAL RAM (1024 x 32) ----
    uint32_t palvals[1024];
    for(int i=0;i<1024;i++){ palvals[i]=rnd(); wr(OFF_PAL + i*4, palvals[i]); }
    for(int i=0;i<1024;i++){
        dut->pal_raddr=i; tick(); tick();
        char nm[24]; snprintf(nm,sizeof(nm),"pal[%d]",i);
        chk(nm, dut->pal_rdata, palvals[i]);
    }

    // ---- cross-check: writing FOG must NOT clobber PAL or scalar regs ----
    chk("param_base_after", dut->o_param_base, 0xDEAD0020);
    dut->pal_raddr=7; tick(); tick(); chk("pal7_after", dut->pal_rdata, palvals[7]);

    printf("reg_file: %d/%d passed\n", total-fails, total);
    printf(fails?"REGFILE FAIL\n":"REGFILE OK\n");
    return fails?1:0;
}

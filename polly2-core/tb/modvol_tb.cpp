// modvol_tb - opaque modifier-volume unit test.
//
// Checks the two blocks the feature added, against a C model transcribed straight
// from refsw2 (refsw_tile.cpp):
//
//  1. stencil_tile_buffer - the per-pixel {SUM,FLIP,INV} plane.
//        flip      : *stencil ^= 0b010 ; *stencil |= 0b100      (PixelFlush_isp)
//        summarize : if (s & 0b100) { s |= (s>>1) /* or &= */ ; s &= 0b001; }
//                    (SummarizeStencilOr / SummarizeStencilAnd)
//        clear     : ClearBuffers / PeelBuffers stencilValue = 0
//     driven through the real peel_core access patterns: the stage A read /
//     stage B write-back pair, and the read-ahead / delayed-write chunk walk.
//     Read back through the spanner's 4-wide aligned INV port.
//
//  2. peel_tile_buffer with b_modvol=1 - a modifier-volume fragment must
//        (a) depth-test with DepthMode FORCED to 6 (greater-or-equal), whatever
//            the record's ISP word says (those bits are VolumeMode for a modvol),
//        (b) report the per-lane verdict on b_mv_we,
//        (c) write NOTHING back: depth, tag and valid unchanged, and b_we low so
//            the u_taginvw duplicate write never fires.
//     The same fragment with b_modvol=0 is run as a control, and must write.
#include "Vmodvol_tb_top.h"
#include "Vmodvol_tb_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>

static Vmodvol_tb_top* dut;
#define INVW_LANE dut->rootp->modvol_tb_top__DOT__invw_lane

static const int LANES  = 8;
static const int NCHUNK = 1024 / LANES;      // 128

static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

static uint32_t rng=0x1234567u;
static uint32_t rnd(){uint32_t x=rng;x^=x<<13;x^=x>>17;x^=x<<5;rng=x;return x;}

static int fails=0, total=0;
static void chk(bool ok, const char* what, long a, long b){
    total++;
    if(!ok){ fails++; if(fails<25) printf("  FAIL %s: got %ld want %ld\n", what, a, b); }
}

// ---------------- C model of the stencil plane ----------------
static uint8_t sten[1024];      // bit0 INV, bit1 FLIP, bit2 SUM

static void idle(){
    dut->st_ras_a_valid=0; dut->st_ras_b_valid=0; dut->st_clr_valid=0;
    dut->st_sum_rd_valid=0; dut->st_sum_wr_valid=0; dut->st_rd4_valid=0;
    dut->pl_clr_valid=0; dut->pl_ras_a_valid=0; dut->pl_ras_b_valid=0;
    dut->pl_sh_rd_valid=0; dut->pl_b_modvol=0;
}

// CLEAR/zero walk: one chunk per cycle, exactly as peel_core's S_CLEAR_WR.
static void stencil_clear(){
    for(int c=0;c<NCHUNK;c++){
        idle(); dut->st_clr_valid=1; dut->st_clr_addr=c; tick();
    }
    idle();
    memset(sten,0,sizeof(sten));
}

// one modvol triangle chunk: stage A presents the read, stage B flips the passing
// lanes a cycle later (the peel_core raster pair).
static void stencil_flip(int chunk, uint8_t mask){
    int y = chunk>>2, xch = (chunk&3)*LANES;
    idle(); dut->st_ras_a_valid=1; dut->st_ras_a_y=y; dut->st_ras_a_x=xch; tick();
    idle(); dut->st_ras_b_valid=1; dut->st_mv_we=mask; dut->st_b_y=y; dut->st_b_x=xch; tick();
    idle();
    for(int l=0;l<LANES;l++) if(mask & (1<<l)){
        int p = chunk*LANES + l;
        sten[p] ^= 0b010;
        sten[p] |= 0b100;
    }
}

// SummarizeStencilOr / ...And: the read-ahead / delayed-write chunk walk.
static void stencil_summarize(bool is_and){
    idle();
    dut->st_sum_and = is_and;
    for(int c=0;c<=NCHUNK;c++){
        dut->st_sum_rd_valid = (c<NCHUNK); dut->st_sum_rd_addr = (c<NCHUNK)?c:(NCHUNK-1);
        dut->st_sum_wr_valid = (c>0);      dut->st_sum_wr_addr = c-1;
        tick();
    }
    idle();
    for(int p=0;p<1024;p++){
        if (sten[p] & 0b100) {
            uint8_t inv = sten[p]&1, flip = (sten[p]>>1)&1;
            sten[p] = is_and ? (inv & flip) : (inv | flip);
        } else sten[p] &= 0b001;
        sten[p] &= 0b111;
    }
}

// read every aligned 4-group and compare INV with the model
static void stencil_verify(const char* tag){
    for(int g=0; g<1024; g+=4){
        idle(); dut->st_rd4_valid=1; dut->st_rd4_group=g; tick();
        idle(); dut->eval();
        for(int j=0;j<4;j++){
            int want = sten[g+j] & 1;
            int got  = (dut->st_g4_inv >> j) & 1;
            if (want != got) {
                total++; fails++;
                if (fails<25) printf("  FAIL %s px=%d: INV got %d want %d (model=%02x)\n",
                                     tag, g+j, got, want, sten[g+j]);
            } else total++;
        }
    }
}

// ---------------- peel_tile_buffer modvol behaviour ----------------
static void peel_clear(uint32_t depth, uint32_t tagv){
    for(int c=0;c<NCHUNK;c++){
        idle(); dut->pl_clr_valid=1; dut->pl_clr_addr=c;
        dut->pl_clr_depth=depth; dut->pl_clr_tag=tagv; tick();
    }
    idle();
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Vmodvol_tb_top;
    dut->reset=1; idle(); tick(); tick(); tick(); dut->reset=0; tick();

    // ================= 1. stencil: refsw2 volume semantics =================
    // (a) a single volume, OR-summarized ("inside last polygon"). A pixel covered
    //     an ODD number of times ends up inside.
    stencil_clear();
    stencil_flip(0, 0xFF);          // whole chunk once   -> parity 1
    stencil_flip(0, 0x0F);          // low half again     -> parity 0 for lanes 0..3
    stencil_flip(5, 0xAA);
    stencil_summarize(false);
    stencil_verify("or_single");

    // (b) a SECOND volume ORs into the same INV bits and never clears them.
    stencil_flip(0, 0x0F);
    stencil_flip(9, 0xFF);
    stencil_summarize(false);
    stencil_verify("or_second");

    // (c) AND-summarize ("outside last polygon") INTERSECTS with what is there.
    stencil_flip(0, 0x33);
    stencil_summarize(true);
    stencil_verify("and_third");

    // (d) an untouched pixel keeps its INV through a summarize of either flavour
    //     (SUM=0 -> the reference leaves the byte alone).
    stencil_summarize(false);
    stencil_verify("or_empty");
    stencil_summarize(true);
    stencil_verify("and_empty");

    // (e) CLEAR wipes everything (refsw ClearBuffers / PeelBuffers stencilValue=0).
    stencil_clear();
    stencil_verify("cleared");

    // (f) randomized soak: volumes of 1..6 triangles, random summarize flavour,
    //     with a clear every so often.
    for(int t=0;t<200;t++){
        if ((rnd()&15)==0) stencil_clear();
        int ntri = 1 + (rnd()%6);
        for(int i=0;i<ntri;i++) stencil_flip(rnd()%NCHUNK, rnd()&0xFF);
        if (rnd()&1) stencil_summarize(rnd()&1);
    }
    stencil_verify("soak");

    // ================= 2. peel_tile_buffer, b_modvol =================
    // Seed a known opaque depth/tag, then run a modvol fragment over one chunk.
    const uint32_t D = 0x40000000, T = 0x00ABCDE0;
    peel_clear(D, T);

    for(int trial=0; trial<64; trial++){
        int chunk = rnd()%NCHUNK;
        int y = chunk>>2, xch = (chunk&3)*LANES;
        uint8_t inside = rnd()&0xFF;
        uint32_t iw[LANES];
        for(int l=0;l<LANES;l++){
            // straddle the seeded depth: below / equal / above
            switch(rnd()%3){ case 0: iw[l]=D-0x100000; break;
                             case 1: iw[l]=D;          break;
                             default: iw[l]=D+0x100000; }
            INVW_LANE[l]=iw[l];
        }
        // stage A
        idle(); dut->pl_ras_a_valid=1; dut->pl_ras_a_y=y; dut->pl_ras_a_x=xch; tick();
        // stage B: MODVOL. b_mode is deliberately junk (a modvol ISP word holds
        // VolumeMode in the DepthMode bits) - the compare must force mode 6.
        idle();
        dut->pl_ras_b_valid=1; dut->pl_b_inside=inside; dut->pl_b_y=y; dut->pl_b_x=xch;
        dut->pl_b_tag=0x00FFFFF0; dut->pl_b_mode=rnd()&7; dut->pl_b_modvol=1;
        dut->eval();
        uint8_t want_mv=0;
        for(int l=0;l<LANES;l++) if((inside>>l&1) && iw[l]>=D) want_mv |= (1<<l);
        chk(dut->pl_b_mv_we==want_mv, "b_mv_we", dut->pl_b_mv_we, want_mv);
        chk(dut->pl_b_we==0,          "b_we (modvol must not write)", dut->pl_b_we, 0);
        tick();
        idle();
        // nothing may have been written back
        for(int l=0;l<LANES;l++){
            int pix = chunk*LANES + l;
            idle(); dut->pl_sh_rd_valid=1; dut->pl_sh_rd_id=pix; tick();
            idle(); dut->eval();
            chk(dut->pl_sh_depth==D, "modvol depth untouched", dut->pl_sh_depth, D);
            chk(dut->pl_sh_tag==T,   "modvol tag untouched",   dut->pl_sh_tag,   T);
        }
    }

    // control: the SAME fragment with b_modvol=0 and mode 6 DOES write.
    {
        int chunk = 7, y = chunk>>2, xch = (chunk&3)*LANES;
        for(int l=0;l<LANES;l++) INVW_LANE[l]=D+0x200000;
        idle(); dut->pl_ras_a_valid=1; dut->pl_ras_a_y=y; dut->pl_ras_a_x=xch; tick();
        idle();
        dut->pl_ras_b_valid=1; dut->pl_b_inside=0xFF; dut->pl_b_y=y; dut->pl_b_x=xch;
        dut->pl_b_tag=0x00123450; dut->pl_b_mode=6; dut->pl_b_modvol=0;
        dut->eval();
        chk(dut->pl_b_we==0xFF,   "control b_we",   dut->pl_b_we,   0xFF);
        chk(dut->pl_b_mv_we==0,   "control b_mv_we",dut->pl_b_mv_we,0);
        tick(); idle();
        for(int l=0;l<LANES;l++){
            int pix = chunk*LANES + l;
            idle(); dut->pl_sh_rd_valid=1; dut->pl_sh_rd_id=pix; tick();
            idle(); dut->eval();
            chk(dut->pl_sh_depth==D+0x200000, "control depth written", dut->pl_sh_depth, D+0x200000);
            chk(dut->pl_sh_tag==0x00123450,   "control tag written",   dut->pl_sh_tag,   0x00123450);
        }
    }

    printf("modvol: %d/%d checks passed\n", total-fails, total);
    printf(fails?"MODVOL FAIL\n":"MODVOL OK\n");
    return fails?1:0;
}

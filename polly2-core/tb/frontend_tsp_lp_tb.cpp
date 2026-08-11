// frontend_tsp_tb - full front-end + ISP + TSP shading run from real PVR dumps.
// Tile FLUSHes shade every pixel (tag -> TSP plane cache -> tsp_shade) into a
// color buffer which lands in the 640x480 framebuffer; this writes the shaded
// ARGB framebuffer to shaded_<name>.bmp.
#include "Vfrontend_tsp_lp_tb_top.h"
#include "Vfrontend_tsp_lp_tb_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>

static Vfrontend_tsp_lp_tb_top* dut;
#define VRAM dut->rootp->frontend_tsp_lp_tb_top__DOT__u_sim__DOT__vram
#define FB   dut->rootp->frontend_tsp_lp_tb_top__DOT__u_sim__DOT__fb
// +mvdump : per-pixel modifier-volume counters kept by peel_core (see its mvpx_* decl)
#define MVCOVER dut->rootp->frontend_tsp_lp_tb_top__DOT__u_core__DOT__mvpx_cover
#define MVPASS  dut->rootp->frontend_tsp_lp_tb_top__DOT__u_core__DOT__mvpx_pass
#define MVSHADE dut->rootp->frontend_tsp_lp_tb_top__DOT__u_core__DOT__mvpx_shade
static const int MVPX_W = 1280;
static void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

static uint8_t* load(const char* path, long* out_sz){
    FILE* f=fopen(path,"rb");
    if(!f){ printf("cannot open %s\n",path); exit(1); }
    fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);
    uint8_t* buf=(uint8_t*)malloc(sz);
    if(fread(buf,1,sz,f)!=(size_t)sz){ printf("short read %s\n",path); exit(1); }
    fclose(f); if(out_sz)*out_sz=sz; return buf;
}

// minimal 24-bit BMP writer (bottom-up rows); fb holds shaded ARGB words
static void write_bmp(const char* path, int w, int h){
    int rowsz = (w*3 + 3) & ~3;
    uint32_t datasz = rowsz*h, filesz = 54 + datasz;
    uint8_t hdr[54]; memset(hdr,0,54);
    hdr[0]='B'; hdr[1]='M';
    memcpy(hdr+2,  &filesz, 4);
    hdr[10]=54;
    hdr[14]=40;
    memcpy(hdr+18, &w, 4);
    memcpy(hdr+22, &h, 4);
    hdr[26]=1;
    hdr[28]=24;
    memcpy(hdr+34, &datasz, 4);
    FILE* f=fopen(path,"wb");
    if(!f){ printf("cannot write %s\n",path); return; }
    fwrite(hdr,1,54,f);
    uint8_t* row=(uint8_t*)calloc(1,rowsz);
    for(int y=h-1; y>=0; y--){
        for(int x=0; x<w; x++){
            uint32_t c = FB[y*w + x];       // ARGB
            row[x*3+0] =  c        & 0xFF;   // B
            row[x*3+1] = (c >>  8) & 0xFF;   // G
            row[x*3+2] = (c >> 16) & 0xFF;   // R
        }
        fwrite(row,1,rowsz,f);
    }
    free(row); fclose(f);
    printf("wrote %s (%dx%d)\n", path, w, h);
}

// ---- +mvdump : modifier-volume complexity map -------------------------------
// One BMP per render, same geometry as the shaded output:
//   RED   = stencil FLIPS at this pixel (fragments that passed the forced-GE
//           depth test), scaled x64. An ODD flip count is what puts the pixel
//           inside a volume, so red intensity reads as "how contested".
//   GREEN = modvol fragments COVERING this pixel, scaled x32. A closed volume
//           covers every pixel an even number of times.
//   BLUE  = 255 where the shadow was actually APPLIED (shaded with in_vol=1).
// Pixels whose COVER count is ODD - a watertightness failure, i.e. a dropped or
// duplicated face - are flagged pure MAGENTA so they stand out from the heatmap.
static void write_modvol_bmp(const char* path, int w, int h){
    int rowsz = (w*3 + 3) & ~3;
    uint32_t datasz = rowsz*h, filesz = 54 + datasz;
    uint8_t hdr[54]; memset(hdr,0,54);
    hdr[0]='B'; hdr[1]='M';
    memcpy(hdr+2,  &filesz, 4);
    hdr[10]=54; hdr[14]=40;
    memcpy(hdr+18, &w, 4); memcpy(hdr+22, &h, 4);
    hdr[26]=1; hdr[28]=24;
    memcpy(hdr+34, &datasz, 4);
    FILE* f=fopen(path,"wb");
    if(!f){ printf("cannot write %s\n",path); return; }
    fwrite(hdr,1,54,f);
    uint8_t* row=(uint8_t*)calloc(1,rowsz);
    long tot_cover=0, tot_pass=0, odd_cover=0, odd_pass=0, shaded=0;
    for(int y=h-1; y>=0; y--){
        for(int x=0; x<w; x++){
            int i = y*MVPX_W + x;
            int cover = MVCOVER[i], pass = MVPASS[i], shade = MVSHADE[i];
            uint8_t r,g,b;
            if (cover & 1) { r=255; g=0; b=255; }        // not watertight
            else {
                int rv = pass*64;  if(rv>255) rv=255;
                int gv = cover*32; if(gv>255) gv=255;
                r=(uint8_t)rv; g=(uint8_t)gv; b= shade ? 255 : 0;
            }
            row[x*3+0]=b; row[x*3+1]=g; row[x*3+2]=r;
        }
        fwrite(row,1,rowsz,f);
    }
    free(row); fclose(f);
    for(int y=0;y<h;y++) for(int x=0;x<w;x++){
        int i=y*MVPX_W+x;
        tot_cover += MVCOVER[i]; tot_pass += MVPASS[i];
        if (MVCOVER[i] & 1) odd_cover++;
        if (MVPASS[i]  & 1) odd_pass++;
        if (MVSHADE[i]) shaded++;
    }
    printf("wrote %s (%dx%d)\n", path, w, h);
    printf("  modvol: cover=%ld pass=%ld | pixels odd-cover=%ld (NOT watertight) odd-pass=%ld shaded=%ld\n",
           tot_cover, tot_pass, odd_cover, odd_pass, shaded);
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);

    // optional dump-set name (default "menu2")
    const char* name = "menu2";
    for(int i=1;i<argc;i++)
        if(argv[i][0] != '+' && argv[i][0] != '-'){ name = argv[i]; break; }
    // dump data lives in the sibling polly2-data/ repo (see DUMPS_DIR default).
#ifndef DUMPS_DIR
#define DUMPS_DIR "../polly2-data/dumps"
#endif
    char regs_path[256], vram_path[256], out_path[256];
    snprintf(regs_path,sizeof(regs_path),DUMPS_DIR "/pvr_regs_%s.bin",name);
    snprintf(vram_path,sizeof(vram_path),DUMPS_DIR "/vram_%s.bin",name);
    snprintf(out_path, sizeof(out_path), "shaded_lp_%s.bmp",name);
    char mv_path[256];
    snprintf(mv_path, sizeof(mv_path), "modvol_%s.bmp",name);
    bool mvdump = false;
    for(int i=1;i<argc;i++) if(!strcmp(argv[i],"+mvdump")) mvdump = true;
    printf("dump set: %s (%s, %s)\n", name, regs_path, vram_path);

    dut=new Vfrontend_tsp_lp_tb_top;
    dut->clk=0; dut->reset=1; dut->go=0; dut->wr_en=0; dut->wr_addr=0; dut->wr_data=0;

    // ---- load VRAM: dump is the 32-bit VIEW (linear); re-interleave into the
    // physical 64-bit layout (inverse pvr_map32). Texture reads use the 64-bit
    // view = this physical layout directly. ----
    long vsz; uint8_t* v = load(vram_path, &vsz);
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

    for(int i=0;i<640*480;i++) FB[i]=0;

    // ---- reset for 10000 cycles ----
    for(int i=0;i<10000;i++) tick();
    dut->reset=0;
    tick();

    // ---- load PVR regs (low 8 KB of the dump is valid) ----
    long rsz; uint8_t* rg = load(regs_path, &rsz);
    uint32_t nwords = (rsz < 0x2000 ? rsz : 0x2000) / 4;
    for(uint32_t i=0;i<nwords;i++){
        uint32_t val = rg[i*4] | (rg[i*4+1]<<8) | (rg[i*4+2]<<16) | (rg[i*4+3]<<24);
        dut->wr_addr = i*4;
        dut->wr_data = val;
        dut->wr_en   = 1;
        tick();
    }
    dut->wr_en = 0;
    tick();

    printf("REGION_BASE=%08x PARAM_BASE=%08x FPU_PARAM_CFG=%08x ISP_BACKGND_T=%08x\n",
        (uint32_t)(rg[0x2C]|(rg[0x2D]<<8)|(rg[0x2E]<<16)|(rg[0x2F]<<24)),
        (uint32_t)(rg[0x20]|(rg[0x21]<<8)|(rg[0x22]<<16)|(rg[0x23]<<24)),
        (uint32_t)(rg[0x7C]|(rg[0x7D]<<8)|(rg[0x7E]<<16)|(rg[0x7F]<<24)),
        (uint32_t)(rg[0x8C]|(rg[0x8D]<<8)|(rg[0x8E]<<16)|(rg[0x8F]<<24)));
    free(rg);

    // ---- go ----
    dut->go=1; tick(); dut->go=0;
    long cyc=0;
    while(!dut->done){
        tick();
        if(++cyc > 400000000){ printf("TIMEOUT after %ld cycles\n",cyc); break; }
    }
    printf("finished in %ld cycles\n", cyc);

    write_bmp(out_path, 640, 480);
    if (mvdump) write_modvol_bmp(mv_path, 640, 480);
    dut->final();   // flush RTL `final` blocks (TEX$ stats etc.)
    return 0;
}

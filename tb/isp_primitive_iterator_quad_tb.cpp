// isp_primitive_iterator_pf quad-support TB.
// Synthetic vram: word[vw] = 0x0A000000|vw (bit28 clear -> cache_bypass=0 in isp words).
// Drives ENT_QUAD / ENT_TRI / ENT_STRIP entries through a behavioral DDR model and
// checks every emitted trio: vertices, quad flag, v3x/v3y, tag param_offs/tag_offset
// (i.e. the hdr + nverts*stride record advance).
#include "Visp_primitive_iterator_pf.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Visp_primitive_iterator_pf* dut;
static int fails=0;
static uint32_t W(uint32_t vw){ return 0x0A000000u|(vw&0xFFFFFF); }

// ---- port helpers: QData (<=64b) and VlWide (little-endian 32-bit words) ----
static uint32_t getq(uint64_t w,int lsb,int n){
    return (uint32_t)((w>>lsb) & ((n>=64)?~0ull:((1ull<<n)-1))); }
static void setq(uint64_t&w,int lsb,int n,uint64_t v){
    uint64_t m = ((n>=64)?~0ull:((1ull<<n)-1))<<lsb; w = (w&~m)|((v<<lsb)&m); }
template<typename WP> static uint32_t getbits(const WP&w,int lsb,int n){
    uint64_t v=0;
    for(int i=0;i<n;i++){ int b=lsb+i; v |= uint64_t((w[b>>5]>>(b&31))&1)<<i; }
    return (uint32_t)v;
}
template<typename WP> static void setbits(WP&w,int lsb,int n,uint64_t v){
    for(int i=0;i<n;i++){ int b=lsb+i; uint32_t m=1u<<(b&31);
        if((v>>i)&1) w[b>>5]|=m; else w[b>>5]&=~m; }
}

// trio field LSBs (triangle_out_t packed, 420 bits)
enum { TF_PRIMDONE=0, TF_ISPT=1, TF_TAG=2, TF_V3Y=34, TF_V3X=66, TF_QUAD=98,
       TF_V2Z=99, TF_V2Y=131, TF_V2X=163, TF_V1Z=195, TF_V1Y=227, TF_V1X=259,
       TF_V0Z=291, TF_V0Y=323, TF_V0X=355, TF_ISP=387, TF_READY=419 };

// ---- behavioral DDR: latch req, fixed latency, 1 beat/cycle, word[vw]=W(vw) ----
struct Ddr { bool act=false; int lat; uint32_t vw; int beats,i; } ddr;
static void ddr_drive_inputs(){
    // dresp = {busy(65), dout(64:1), dready(0)}
    dut->dresp[0]=dut->dresp[1]=dut->dresp[2]=0;
    if(ddr.act && ddr.lat==0 && ddr.i<ddr.beats){
        uint32_t d = W(ddr.vw + ddr.i);
        setbits(dut->dresp, 1, 32, d);       // dout lo half
        setbits(dut->dresp, 33, 32, d);      // dout hi half (bank-agnostic)
        setbits(dut->dresp, 0, 1, 1);        // dready
    }
}
static void ddr_after_edge(){
    // sample request AFTER the clock edge (registered outputs)
    uint32_t rd    = getq(dut->dreq, 37, 1);
    uint32_t addr  = getq(dut->dreq, 8, 29);
    uint32_t burst = getq(dut->dreq, 0, 8);
    if(ddr.act){ if(ddr.lat>0) ddr.lat--; else if(ddr.i<ddr.beats) ddr.i++; if(ddr.i>=ddr.beats) ddr.act=false; }
    if(rd){ ddr.act=true; ddr.lat=4; ddr.vw=addr&0xFFFFF; ddr.beats=burst; ddr.i=0; }
}
static void tick(){
    ddr_drive_inputs();
    dut->clk=0; dut->eval();
    dut->clk=1; dut->eval();
    ddr_after_edge();
}

struct ExpTri { uint32_t v0x,v0y,v0z,v1x,v1y,v1z,v2x,v2y,v2z; bool quad; uint32_t v3x,v3y;
                uint32_t isp, po; uint32_t toff; };
static std::vector<ExpTri> exp_q;
static int got=0;

static void check_trio(){
    ExpTri e = exp_q[got];
    struct { const char*n; uint32_t g,w; } f[] = {
        {"isp", getbits(dut->trio,TF_ISP,32), e.isp},
        {"v0x", getbits(dut->trio,TF_V0X,32), e.v0x}, {"v0y", getbits(dut->trio,TF_V0Y,32), e.v0y},
        {"v0z", getbits(dut->trio,TF_V0Z,32), e.v0z},
        {"v1x", getbits(dut->trio,TF_V1X,32), e.v1x}, {"v1y", getbits(dut->trio,TF_V1Y,32), e.v1y},
        {"v1z", getbits(dut->trio,TF_V1Z,32), e.v1z},
        {"v2x", getbits(dut->trio,TF_V2X,32), e.v2x}, {"v2y", getbits(dut->trio,TF_V2Y,32), e.v2y},
        {"v2z", getbits(dut->trio,TF_V2Z,32), e.v2z},
        {"quad",getbits(dut->trio,TF_QUAD,1), e.quad},
        {"tag.po", (getbits(dut->trio,TF_TAG,32)>>3)&0x1FFFFF, e.po},
        {"tag.toff", getbits(dut->trio,TF_TAG,32)&7, e.toff},
    };
    for(auto&x:f) if(x.g!=x.w){ printf("FAIL trio %d %s: got %08x want %08x\n",got,x.n,x.g,x.w); fails++; }
    if(e.quad){
        uint32_t g3x=getbits(dut->trio,TF_V3X,32), g3y=getbits(dut->trio,TF_V3Y,32);
        if(g3x!=e.v3x){ printf("FAIL trio %d v3x: got %08x want %08x\n",got,g3x,e.v3x); fails++; }
        if(g3y!=e.v3y){ printf("FAIL trio %d v3y: got %08x want %08x\n",got,g3y,e.v3y); fails++; }
    }
    got++;
}

// build expectation for one ARRAY record (nverts 3 or 4)
static void expect_array_rec(uint32_t pb_vw, uint32_t po, uint32_t stride, bool quad){
    uint32_t b = pb_vw + po, h = 3;
    ExpTri e{};
    e.isp=W(b); e.po=po; e.toff=0; e.quad=quad;
    e.v0x=W(b+h); e.v0y=W(b+h+1); e.v0z=W(b+h+2);
    e.v1x=W(b+h+stride); e.v1y=W(b+h+stride+1); e.v1z=W(b+h+stride+2);
    e.v2x=W(b+h+2*stride); e.v2y=W(b+h+2*stride+1); e.v2z=W(b+h+2*stride+2);
    if(quad){ e.v3x=W(b+h+3*stride); e.v3y=W(b+h+3*stride+1); }
    exp_q.push_back(e);
}
static void expect_strip_tri(uint32_t pb_vw, uint32_t po, uint32_t stride, int i){
    uint32_t b = pb_vw + po, h = 3;
    auto vx=[&](int v){ return b+h+v*stride; };
    int a = i + ((i&1)?1:0), c = i + ((i&1)?0:1);
    ExpTri e{};
    e.isp=W(b); e.po=po; e.toff=i; e.quad=false;
    e.v0x=W(vx(a)); e.v0y=W(vx(a)+1); e.v0z=W(vx(a)+2);
    e.v1x=W(vx(c)); e.v1y=W(vx(c)+1); e.v1z=W(vx(c)+2);
    e.v2x=W(vx(i+2)); e.v2y=W(vx(i+2)+1); e.v2z=W(vx(i+2)+2);
    exp_q.push_back(e);
}

// present one entry and run until iterator consumes it + drains
static void send_entry(int etype, uint32_t po, uint32_t skip, uint32_t mask, uint32_t count){
    uint64_t ent=0;
    setq(ent, 0, 5, count); setq(ent, 5, 6, mask);
    setq(ent, 11, 1, 0); setq(ent, 12, 3, skip); setq(ent, 15, 21, po);
    dut->entry = ent;
    dut->entry_type = etype;
    dut->entry_pt = 0;
    dut->entry_valid = 1;
    for(int t=0;t<20000;t++){
        // consume trios whenever presented
        dut->ack = 0;
        if(getbits(dut->trio,TF_READY,1)){ check_trio(); dut->ack = 1; }
        tick();
        if(dut->entry_ack) { dut->entry_valid = 0; }
        if(!dut->entry_valid && !dut->busy && !getbits(dut->trio,TF_READY,1)) return;
    }
    printf("FAIL: timeout (etype %d)\n",etype); fails++;
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Visp_primitive_iterator_pf;
    dut->reset=1; dut->entry_valid=0; dut->ack=0; dut->intensity_shadow=0;
    for(int i=0;i<8;i++) tick();
    dut->reset=0; tick();

    uint32_t pb = 0x00100000;             // param_base bytes
    uint32_t pb_vw = pb>>2;
    dut->param_base = pb;

    // 1) QUAD array: skip=1 -> stride=4, hdr=3, rec_words = 3+4*4 = 19, count=3
    { uint32_t po=0x100, st=4, rw=3+4*st;
      for(int r=0;r<3;r++) expect_array_rec(pb_vw, po+r*rw, st, true);
      send_entry(2/*ENT_QUAD*/, po, 1, 0, 3); }
    // 2) TRI array: skip=2 -> stride=5, rec_words = 3+3*5 = 18, count=2
    { uint32_t po=0x400, st=5, rw=3+3*st;
      for(int r=0;r<2;r++) expect_array_rec(pb_vw, po+r*rw, st, false);
      send_entry(1/*ENT_TRI*/, po, 2, 0, 2); }
    // 3) STRIP: skip=0 -> stride=3, mask=0b101000 -> tris i=0 and i=2
    { uint32_t po=0x700;
      expect_strip_tri(pb_vw, po, 3, 0);
      expect_strip_tri(pb_vw, po, 3, 2);
      send_entry(0/*ENT_STRIP*/, po, 0, 0b101000, 0); }
    // 4) QUAD array again, skip=0 -> stride=3, count=2 (regression: min stride)
    { uint32_t po=0x900, st=3, rw=3+4*st;
      for(int r=0;r<2;r++) expect_array_rec(pb_vw, po+r*rw, st, true);
      send_entry(2, po, 0, 0, 2); }

    if(got!=(int)exp_q.size()){ printf("FAIL: got %d trios, expected %zu\n",got,exp_q.size()); fails++; }
    printf(fails? "== %d FAILURES (%d trios) ==\n" : "== ALL PASS (%d trios checked) ==\n",
           fails?fails:got, got);
    delete dut; return fails?1:0;
}

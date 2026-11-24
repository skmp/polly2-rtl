// p2_rendercore.cpp: refsw3-offline's RenderCORE() on the RTL (PLAN M12, 1.4; conventions.md 7.4): p2-offline is
// refsw3-offline (nulldc3 refsw3-offline/main.cpp, refsw3-ta, pvr_mem, TexCache, threading: its own sources and flags)
// without refsw_lists.cpp and refsw_tile.cpp, with this file and the Verilated p2_core. The only symbols the rest of
// refsw3-offline takes from refcore are refcore::RenderCORE, refcore::rendlog and refcore::rendlog_tiles; this file has
// them (in the dual mode the L2 glue has the last two, refsw_lists.cpp's own).
//
// One p2_core for the whole process (made, and reset, at the first render): the tile buffers, which is buffer 1,
// offsKept and the ISP's buffers carry from render to render, as refcore's statics do in refsw3-offline. Each render:
//   1. the register block: all 2048 words of pvr_regs (FOG_TABLE and PALETTE_RAM included) through the register port,
//      in address order, STARTRENDER (0x014) left out; then STARTRENDER;
//   2. the core is clocked until ev_isp, ev_tsp and ev_vid have all fired and the VRAM model has nothing in flight; the
//      VRAM model (tb/common/vram_model.h) serves the two halves from emu_vram (64-bit physical order);
//   3. on stderr: "p2: render <n> isp <clk> tsp <clk> video <clk> vramrace <words> [first <32-bit-area address>]", the
//      clocks from STARTRENDER; a render past P2_CLK_LIMIT clocks: "p2: render <n> did not end" (the core is then reset,
//      its state lost: what refsw3-offline does after it is the same as after any render).
// The hazard detector (ARCHITECTURE 3.2.1): a render whose C0-C4 reads touch a 32-bit word its C5 writes is VRAM-race:
// `vramrace` is the number of such words (0: not a race render), `first` the first of them.
// Environment: P2_VR_LAT (the VRAM model's read latency, 8), P2_VRAMVARY=<seed> (+vramvary: random latency, ready drops
// and stalls; 0 off), P2_CLK_LIMIT (clocks a render may take, 2e9), P2_VERBOSE=1 (each render's statistics),
// P2_PLUSARGS (the RTL's plusargs, e.g. +wotrace).
//
// Dual mode (-DP2_DUAL, make p2-offline-dual): the L2 glue is linked too; each render first runs refcore's RenderCORE_sw
// on a copy of video memory, then the RTL on emu_vram, and the two are compared word by word: "p2-dual: render <n>:
// <k> words differ, first at <32-bit-area address> (tile x y, pixel x y)" or "p2-dual: render <n>: equal". The RTL's
// memory is the one kept.
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Vp2_core.h"
#include "verilated.h"

#include "vram_model.h"

extern unsigned char pvr_regs[];
namespace refcore {
extern unsigned char* emu_vram;
void RenderCORE();
#ifdef P2_DUAL
void RenderCORE_sw();
#else
FILE* rendlog;
std::vector<uint32_t> rendlog_tiles;
#endif
}   // namespace refcore

namespace {

constexpr uint32_t kVramSize = 8u << 20;

struct Frame {
    Vp2_core* t = nullptr;
    p2tb::VramModel vm;
    uint64_t cyc = 0;
    long renders = 0;
    uint64_t limit = 2000000000ull;
    bool verbose = false;

    void vram_drive()
    {
        for (int h = 0; h < 2; h++) {
            bool rdy, v;
            uint32_t d, s;
            vm.drive(h, &rdy, &v, &d, &s);
            t->vh_req_rdy = (t->vh_req_rdy & ~(1u << h)) | ((uint32_t)rdy << h);
            t->vh_rsp_v = (t->vh_rsp_v & ~(1u << h)) | ((uint32_t)v << h);
            t->vh_rsp_data = (t->vh_rsp_data & ~(0xFFFFFFFFull << (32 * h))) | ((uint64_t)d << (32 * h));
            t->vh_rsp_src = (t->vh_rsp_src & ~(7u << (3 * h))) | (s << (3 * h));
        }
    }
    void tick()
    {
        vram_drive();
        t->clk = 0;
        t->eval();
        bool rv[2], rwe[2];
        uint32_t ridx[2], rbe[2], rwd[2], rsrc[2];
        for (int h = 0; h < 2; h++) {
            rv[h] = (t->vh_req_v >> h) & 1;
            rwe[h] = (t->vh_req_we >> h) & 1;
            ridx[h] = (t->vh_req_idx >> (20 * h)) & 0xFFFFF;
            rbe[h] = (t->vh_req_be >> (4 * h)) & 15;
            rwd[h] = (uint32_t)(t->vh_req_wdata >> (32 * h));
            rsrc[h] = (t->vh_req_src >> (3 * h)) & 7;
        }
        t->clk = 1;
        t->eval();
        for (int h = 0; h < 2; h++)
            vm.edge(h, rv[h], rwe[h], ridx[h], rbe[h], rwd[h], rsrc[h]);
        vm.tick();
        cyc++;
    }
    void reset()
    {
        t->reg_wr = 0;
        t->reg_rd = 0;
        t->rst = 1;
        for (int i = 0; i < 8; i++)
            tick();
        t->rst = 0;
        tick();
    }
    void init()
    {
        // the RTL's plusargs (+wotrace, ...) from P2_PLUSARGS: refsw3-offline's own arguments are its main's
        static std::vector<std::string> args{ "p2-offline" };
        static std::vector<const char*> argv;
        if (const char* s = getenv("P2_PLUSARGS")) {
            std::string w;
            for (const char* c = s;; c++)
                if (*c == ' ' || !*c) {
                    if (!w.empty()) args.push_back(w);
                    w.clear();
                    if (!*c) break;
                } else
                    w += *c;
        }
        for (const std::string& x : args) argv.push_back(x.c_str());
        Verilated::commandArgs((int)argv.size(), argv.data());
        t = new Vp2_core;
        if (const char* s = getenv("P2_VR_LAT"))
            vm.vrLat = atoi(s);
        if (const char* s = getenv("P2_VRAMVARY"))
            vm.varySeed = strtoull(s, nullptr, 0);
        if (const char* s = getenv("P2_CLK_LIMIT"))
            limit = strtoull(s, nullptr, 0);
        verbose = getenv("P2_VERBOSE") && atoi(getenv("P2_VERBOSE"));
        vm.init(refcore::emu_vram);
        reset();
        fprintf(stderr, "p2: p2_core, VR_LAT %d, vramvary %llu\n", vm.vrLat, (unsigned long long)vm.varySeed);
    }
    void reg_write(uint32_t word, uint32_t v)
    {
        t->reg_wr = 1;
        t->reg_addr = word;
        t->reg_wdata = v;
        tick();
        t->reg_wr = 0;
    }

    void render()
    {
        if (!t)
            init();
        const long n = renders++;
        vm.init(refcore::emu_vram);
        vm.reseed((uint64_t)n, 0);
        vm.begin_render();
        // the register block (STARTRENDER left out), then STARTRENDER
        for (uint32_t w = 0; w < 2048; w++) {
            if (w == 0x014 / 4)
                continue;
            uint32_t v;
            memcpy(&v, pvr_regs + 4 * w, 4);
            reg_write(w, v);
        }
        const uint64_t c0 = cyc;
        reg_write(0x014 / 4, 0xFFFFFFFFu);
        uint64_t tIsp = 0, tTsp = 0, tVid = 0;
        bool hung = false;
        for (;;) {
            if (t->ev_isp && !tIsp) tIsp = cyc - c0;
            if (t->ev_tsp && !tTsp) tTsp = cyc - c0;
            if (t->ev_vid && !tVid) tVid = cyc - c0;
            if (tIsp && tTsp && tVid)
                break;
            if (cyc - c0 > limit) {
                hung = true;
                break;
            }
            tick();
        }
        if (hung) {
            fprintf(stderr, "p2: render %ld did not end\n", n);
            vm.flush();
            reset();
            return;
        }
        // what is still in flight to video memory
        for (int quiet = 0; quiet < 16;) {
            tick();
            quiet = (vm.busy() || t->vh_req_v) ? 0 : quiet + 1;
        }
        const uint64_t race = vm.race_words();
        if (race) {
            // the 32-bit word index (half 0 even) as a 32-bit-area address
            const uint32_t w2 = (uint32_t)vm.firstRace;
            const uint32_t a = ((w2 >> 1) << 2) | ((w2 & 1u) << 22);
            fprintf(stderr, "p2: render %ld isp %" PRIu64 " tsp %" PRIu64 " video %" PRIu64 " vramrace %" PRIu64 " first %06x\n",
                    n, tIsp, tTsp, tVid, race, a);
        } else
            fprintf(stderr, "p2: render %ld isp %" PRIu64 " tsp %" PRIu64 " video %" PRIu64 " vramrace 0\n", n, tIsp, tTsp, tVid);
        if (verbose)
            fprintf(stderr, "p2: render %ld: VRAM grants %" PRIu64 ", reads %" PRIu64 ", writes %" PRIu64 "\n", n, vm.grants,
                    vm.reads, vm.writes);
    }
};

Frame fr;

}   // namespace

#ifdef P2_DUAL
namespace {
// a physical byte address (64-bit order) as a 32-bit-area address (pvr_map32's inverse)
uint32_t Area32(uint32_t p) { return ((p >> 3) << 2) | (((p >> 2) & 1u) << 22) | (p & 3u); }
}   // namespace
#endif

void refcore::RenderCORE()
{
#ifdef P2_DUAL
    static std::vector<uint8_t> ref;
    ref.assign(refcore::emu_vram, refcore::emu_vram + kVramSize);
    uint8_t* const real = refcore::emu_vram;
    refcore::emu_vram = ref.data();
    refcore::RenderCORE_sw();
    refcore::emu_vram = real;
    fr.render();
    long diff = 0;
    int64_t first = -1;
    for (uint32_t i = 0; i < kVramSize; i += 4)
        if (memcmp(real + i, ref.data() + i, 4)) {
            if (first < 0) first = i;
            diff++;
        }
    if (!diff)
        fprintf(stderr, "p2-dual: render %ld: equal\n", fr.renders - 1);
    else {
        // where in the framebuffer: FB_W_SOF1, FB_W_LINESTRIDE, FB_W_CTRL's bytes per pixel (no strips, no scaler)
        uint32_t sof1, stride, wctrl;
        memcpy(&sof1, pvr_regs + 0x60, 4);
        memcpy(&stride, pvr_regs + 0x4C, 4);
        memcpy(&wctrl, pvr_regs + 0x48, 4);
        const int pm = wctrl & 7, bpp = pm <= 3 ? 2 : pm == 4 ? 3 : 4;
        const uint32_t a = Area32((uint32_t)first), lineBytes = (stride & 0x1FF) * 8;
        const uint32_t off = (a - (sof1 & 0xFFFFFF)) & 0xFFFFFF;
        uint32_t real32, ref32;
        memcpy(&real32, real + first, 4);
        memcpy(&ref32, ref.data() + first, 4);
        if (lineBytes && !(sof1 & 0x1000000)) {
            const uint32_t y = off / lineBytes, x = (off % lineBytes) / bpp;
            fprintf(stderr, "p2-dual: render %ld: %ld words differ, first at %06x (%08x, refsw3 %08x; tile %u %u, pixel %u %u)\n",
                    fr.renders - 1, diff, a, real32, ref32, x / 32, y / 32, x % 32, y % 32);
        } else
            fprintf(stderr, "p2-dual: render %ld: %ld words differ, first at %06x (%08x, refsw3 %08x)\n", fr.renders - 1,
                    diff, a, real32, ref32);
    }
#else
    fr.render();
#endif
}

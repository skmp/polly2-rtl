// isp_tile_tb.cpp: the ISP tile testbench in phase-halt mode (PLAN 1.3 "ISP tile testbench", M6; make isp-tile-op).
//
//   tb [--vramvary S | +vramvary=S] [--vrlat N] [--phase-limit CLK] [--shard k/N] [--trace] <case folder> | @<list file> ...
//
// A case folder is a capture (tools/gate/capture_prerender.sh: r0, r1, ... each with the registers and video memory
// before a render). Its renders run in order in one reference core (itref::reset_core first) and one RTL (reset first:
// what a render leaves in the ISP's buffers is the next one's, as on a console).
//
// Each render goes through the M5 phase driver (tb/ref/phase_driver.cpp, through itref: isp_tile_ref.h); at its hooks:
//   Z       the testbench feeds the entry to p2_isp_ctl (from the region array entry the driver read) and lets the RTL
//           run, with the phase halt on, until it halts after its Z; then
//   OP, OP_MOD   the RTL runs on to its next halt;
// and at each of the three it compares depthA (the 64-bit key), tagA (32 bits), stencil and valid of all 1024 pixels
// with the reference's (p2ref's state taps) through p2_isp_buf's debug port, and checks that the RTL halted in the same
// phase. At OP_SHADE the RTL must end the entry (M6 has no later phase). The entry's later phases (punch-through,
// translucent: M7) run on the reference only; after an entry that had one, the next entry's Z first writes the
// reference's state at the end of that entry into the RTL's buffers (a resync, counted), as it does before a case's
// first entry. The ISP state the tests compare carries over from entry to entry and render to render otherwise.
//
// The VRAM model (tb/common/vram_model.h) serves C1 and C2 from refcore's emu_vram; --vramvary S varies its latency and
// readiness at random (seed S): the values must not change (PLAN 1.6), only the clocks.
//
// Reports per case its renders, entries, phases compared and resyncs; the clocks the RTL took per entry (from the
// entry's accept to its end, halts excluded); then "isp_tile: <n> checks, <m> failures" and PASS / FAIL.
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <vector>

#include "Vp2_isp_tile_tb_top.h"
#include "verilated.h"

#include "isp_tile_ref.h"
#include "p2tb.h"
#include "vram_model.h"

namespace {

enum { PH_Z = 0, PH_OP = 1, PH_OP_MOD = 2, PH_OP_SHADE = 3, PH_END = 18 };
const char* const kPhase[] = { "Z", "OP", "OP_MOD", "OP_SHADE", "PT_INIT", "PT_CHUNK", "PT_WALK", "PT_SHADE", "PT_FINAL",
                               "PT_MOD", "PT_MV_SHADE", "TR_PS", "TR_SAVE", "TR_PEEL", "TR_WALK", "TR_MOD", "TR_SHADE",
                               "TR_RESTORE", "END" };

bool IsDir(const std::string& p)
{
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}
bool IsFile(const std::string& p)
{
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

struct Tb {
    Vp2_isp_tile_tb_top* t = nullptr;
    p2tb::VramModel vm;
    p2tb::Fails& f;
    uint64_t cyc = 0;
    uint64_t phaseLimit = 20000000;
    bool trace = false;
    std::string where;                  // the render, for messages

    // the case's state
    bool needSync = true;               // the RTL's buffers do not hold the reference's state before this entry
    bool outOfScope = false;            // the entry ran a phase M6 does not have
    std::vector<itref::Pix> prevRef = std::vector<itref::Pix>(1024);
    bool broken = false;                // the RTL lost step with the reference: the render's later entries are skipped

    // statistics
    long entries = 0, phases = 0, syncs = 0, renders = 0, prims = 0, descs = 0, rowsN = 0;
    long mrows = 0;                     // t_mrow: MODIFIER rows one clock after one of the same row (must stay 0)
    uint64_t entClk = 0, clkSum = 0, clkMax = 0, clkPrim = 0;
    std::vector<uint64_t> clkHist = std::vector<uint64_t>(8, 0);   // < 64, < 128, < 256, < 512, < 1k, < 4k, < 16k, more

    explicit Tb(p2tb::Fails& fl) : f(fl) {}

    void tick()
    {
        for (int h = 0; h < 2; h++) {
            bool rdy, v;
            uint32_t d, s;
            vm.drive(h, &rdy, &v, &d, &s);
            t->vh_req_rdy = (t->vh_req_rdy & ~(1u << h)) | ((uint32_t)rdy << h);
            t->vh_rsp_v = (t->vh_rsp_v & ~(1u << h)) | ((uint32_t)v << h);
            t->vh_rsp_data[h] = d;
            t->vh_rsp_src[h] = s;
        }
        t->clk = 0;
        t->eval();
        bool rv[2], rwe[2];
        uint32_t ridx[2], rbe[2], rwd[2], rsrc[2];
        for (int h = 0; h < 2; h++) {
            rv[h] = t->vh_req_v >> h & 1;
            rwe[h] = t->vh_req_we >> h & 1;
            ridx[h] = t->vh_req_idx[h];
            rbe[h] = t->vh_req_be[h];
            rwd[h] = t->vh_req_wdata[h];
            rsrc[h] = t->vh_req_src[h];
        }
        if (t->busy && !t->halted)
            entClk++;
        prims += t->t_asm;
        descs += t->t_desc;
        rowsN += t->t_row;
        mrows += t->t_mrow;
        t->clk = 1;
        t->eval();
        for (int h = 0; h < 2; h++)
            vm.edge(h, rv[h], rwe[h], ridx[h], rbe[h], rwd[h], rsrc[h]);
        vm.tick();
        cyc++;
    }

    void reset()
    {
        t->rst = 1;
        t->ent_v = 0;
        t->resume = 0;
        t->dbg_we = 0;
        t->halt_en = 1;
        for (int i = 0; i < 4; i++)
            tick();
        t->rst = 0;
        tick();
    }

    void set_regs(const itref::Regs& r)
    {
        t->param_base = r.param_base;
        t->fpu_shad_scale = r.fpu_shad_scale;
        t->fpu_cull_val = r.fpu_cull_val;
        t->fpu_perp_val = r.fpu_perp_val;
        t->half_offset = r.half_offset;
        t->bg_tag = r.bg_tag;
        t->bg_depth = r.bg_depth;
    }

    // the reference's state into the RTL's buffers, a row a clock through the debug port
    void sync(const std::vector<itref::Pix>& p)
    {
        for (int row = 0; row < 32; row++) {
            t->dbg_we = 1;
            t->dbg_row = row;
            uint32_t vmask = 0;
            for (int i = 0; i < 32; i++) {
                const itref::Pix& x = p[row * 32 + i];
                t->dbg_wdepth[i] = (uint64_t)x.depth;
                t->dbg_wtag[i] = x.tag;
                t->dbg_wstencil[i] = x.stencil & 7;
                vmask |= (uint32_t)x.valid << i;
            }
            t->dbg_wvalid = vmask;
            tick();
        }
        t->dbg_we = 0;
        syncs++;
    }

    // every pixel's depthA, tagA, stencil, valid against the reference's
    void compare(int ph, const itref::Entry& e)
    {
        std::vector<itref::Pix> ref(1024);
        itref::pixels(ref.data());
        long bad = 0;
        std::string first;
        for (int row = 0; row < 32; row++) {
            t->dbg_row = row;
            t->eval();
            for (int i = 0; i < 32; i++) {
                const itref::Pix& r = ref[row * 32 + i];
                const int64_t d = (int64_t)t->dbg_depth[i];
                const uint32_t tg = t->dbg_tag[i];
                const uint32_t s = t->dbg_stencil[i];
                const bool v = t->dbg_valid >> i & 1;
                if (d != r.depth || tg != r.tag || s != (uint32_t)(r.stencil & 7) || v != r.valid) {
                    if (!bad++) {
                        char b[400];
                        snprintf(b, sizeof b, "pixel (%d, %d): depth %016llx tag %08x stencil %u valid %d, reference "
                                 "%016llx %08x %u %d", i, row, (unsigned long long)d, tg, s, v,
                                 (unsigned long long)r.depth, r.tag, r.stencil & 7, r.valid);
                        first = b;
                    }
                }
            }
        }
        phases++;
        if (!f.ok(bad == 0, "%s tile (%d, %d) after %s: %ld of 1024 pixels differ; the first %s", where.c_str(), e.tilex,
                  e.tiley, kPhase[ph], bad, first.c_str()))
            broken = true;
    }

    // run until the RTL halts; false (reported) if it does not, or ends the entry first
    bool run_to_halt(int ph, const itref::Entry& e)
    {
        for (uint64_t n = 0; n < phaseLimit; n++) {
            if (t->halted) {
                const int hp = t->halt_phase;
                return f.ok(hp == ph, "%s tile (%d, %d): the RTL halted after %s, the reference after %s", where.c_str(),
                            e.tilex, e.tiley, hp < 19 ? kPhase[hp] : "?", kPhase[ph]) ||
                       (broken = true, false);
            }
            if (!t->busy) {
                f.ok(false, "%s tile (%d, %d): the RTL ended the entry before its %s", where.c_str(), e.tilex, e.tiley,
                     kPhase[ph]);
                broken = true;
                return false;
            }
            tick();
        }
        f.ok(false, "%s tile (%d, %d): the RTL did not finish %s in %llu clocks", where.c_str(), e.tilex, e.tiley,
             kPhase[ph], (unsigned long long)phaseLimit);
        broken = true;
        return false;
    }
    void resume()
    {
        t->resume = 1;
        tick();
        t->resume = 0;
    }
    void end_entry(const itref::Entry& e)
    {
        for (uint64_t n = 0; t->busy && !t->halted && n < phaseLimit; n++)
            tick();
        if (!f.ok(!t->busy, "%s tile (%d, %d): the RTL %s after the reference's OP_SHADE", where.c_str(), e.tilex,
                  e.tiley, t->halted ? "halted again" : "did not end the entry")) {
            broken = true;
            return;
        }
        entries++;
        clkSum += entClk;
        clkMax = std::max(clkMax, entClk);
        static const uint64_t lim[7] = { 64, 128, 256, 512, 1024, 4096, 16384 };
        int b = 0;
        while (b < 7 && entClk >= lim[b])
            b++;
        clkHist[b]++;
        if (trace)
            printf("  entry tile (%d, %d): %llu clocks\n", e.tilex, e.tiley, (unsigned long long)entClk);
    }

    void feed(const itref::Entry& e)
    {
        t->e_tilex = e.tilex;
        t->e_tiley = e.tiley;
        t->e_no_writeout = e.no_writeout;
        t->e_pre_sort = e.pre_sort;
        t->e_z_keep = e.z_keep;
        t->e_last = e.last;
        uint32_t em = 0;
        for (int l = 0; l < 5; l++) {
            t->e_ptr[l] = e.ptr[l];
            em |= (uint32_t)e.empty[l] << l;
        }
        t->e_empty = em;
        t->e_idx = (uint32_t)entries;
        entClk = 0;
        t->ent_v = 1;
        tick();            // ctl is idle: it takes the entry at this edge
        t->ent_v = 0;
    }

    void hook(int ph, const itref::Entry& e)
    {
        if (broken)
            return;
        switch (ph) {
        case PH_Z:
            // CLEAR writes every field compared; only a keep-Z entry reads the state before it
            if (needSync && e.z_keep)
                sync(prevRef);
            needSync = false;
            outOfScope = false;
            if (!f.ok(!t->busy, "%s tile (%d, %d): the RTL is still in the entry before", where.c_str(), e.tilex,
                      e.tiley)) {
                broken = true;
                return;
            }
            feed(e);
            // fall through
        case PH_OP:
        case PH_OP_MOD:
            if (run_to_halt(ph, e)) {
                compare(ph, e);
                resume();
            }
            break;
        case PH_OP_SHADE:
            end_entry(e);
            break;
        case PH_END:
            itref::pixels(prevRef.data());
            needSync = outOfScope;
            break;
        default:
            outOfScope = true;
            break;
        }
    }
};

void Hook(int ph, const itref::Entry& e, void* u) { ((Tb*)u)->hook(ph, e); }

}   // namespace

int main(int argc, char** argv)
{
    p2tb::raise_stack();
    Verilated::commandArgs(argc, argv);
    p2tb::Args a;
    if (!a.parse(argc, argv)) {
        fprintf(stderr, "isp_tile: %s\n", a.error.c_str());
        return 2;
    }
    uint64_t vary = 0, limit = 20000000;
    int lat = 8;
    std::vector<std::string> cases;
    for (size_t i = 0; i < a.rest.size(); i++) {
        const std::string& s = a.rest[i];
        if (s == "--vramvary" && i + 1 < a.rest.size())
            vary = strtoull(a.rest[++i].c_str(), nullptr, 0);
        else if (s == "--vrlat" && i + 1 < a.rest.size())
            lat = atoi(a.rest[++i].c_str());
        else if (s == "--phase-limit" && i + 1 < a.rest.size())
            limit = strtoull(a.rest[++i].c_str(), nullptr, 0);
        else if (s[0] == '@') {
            FILE* lf = fopen(s.c_str() + 1, "r");
            if (!lf) {
                fprintf(stderr, "isp_tile: cannot read %s\n", s.c_str() + 1);
                return 2;
            }
            char line[4096];
            while (fgets(line, sizeof line, lf)) {
                std::string l = line;
                while (!l.empty() && (l.back() == '\n' || l.back() == ' '))
                    l.pop_back();
                if (!l.empty() && l[0] != '#')
                    cases.push_back(l);
            }
            fclose(lf);
        } else if (s.rfind("+vramvary=", 0) == 0)          // PLAN 1.6's spelling
            vary = strtoull(s.c_str() + 10, nullptr, 0);
        else if (s[0] != '+')
            cases.push_back(s);
    }
    p2tb::banner("isp_tile", a);
    printf("isp_tile: vramvary %llu, VR_LAT %d\n", (unsigned long long)vary, lat);
    p2tb::Fails f("isp_tile");
    f.set("phase-halt");

    Vp2_isp_tile_tb_top* top = new Vp2_isp_tile_tb_top;
    Tb tb(f);
    tb.t = top;
    tb.trace = a.trace;
    tb.phaseLimit = limit;
    tb.vm.varySeed = vary;
    tb.vm.vrLat = lat;
    tb.vm.init(itref::vram());

    long nCases = 0, skipped = 0;
    uint64_t totEntries = 0, totClk = 0, totMax = 0;
    for (size_t ci = 0; ci < cases.size(); ci++) {
        if (!a.mine(ci))
            continue;
        const std::string& c = cases[ci];
        nCases++;
        itref::reset_core();
        tb.reset();
        tb.needSync = true;
        tb.broken = false;
        itref::pixels(tb.prevRef.data());
        tb.entries = tb.phases = tb.syncs = tb.renders = 0;
        tb.clkSum = tb.clkMax = 0;
        tb.prims = tb.descs = tb.rowsN = 0;
        std::fill(tb.clkHist.begin(), tb.clkHist.end(), 0);
        const uint64_t c0 = tb.cyc;
        for (int k = 0;; k++) {
            const std::string r = c + "/r" + std::to_string(k);
            if (!IsDir(r))
                break;
            if (IsFile(r + "/skipped")) {
                skipped++;
                continue;
            }
            if (!f.ok(itref::load_state(r.c_str()), "%s: cannot load the capture", r.c_str()))
                break;
            tb.where = r;
            tb.set_regs(itref::regs());
            tb.vm.begin_render();
            tb.broken = false;
            const bool ended = itref::render(Hook, &tb, 1024);
            f.ok(ended, "%s: the reference's render did not end", r.c_str());
            tb.renders++;
            if (tb.broken) {
                // the rest of the render was not compared; the next render starts from the reference's state
                tb.needSync = true;
                if (tb.t->busy)
                    tb.reset();
            }
        }
        const uint64_t mean = tb.entries ? tb.clkSum / tb.entries : 0;
        printf("isp_tile: %s: %ld renders, %ld entries, %ld phases compared, %ld resyncs; %ld primitives, %ld "
               "descriptors, %ld rows; clocks an entry: mean %llu, max %llu; histogram <64 %llu <128 %llu <256 %llu "
               "<512 %llu <1k %llu <4k %llu <16k %llu more %llu; %llu clocks\n",
               c.c_str(), tb.renders, tb.entries, tb.phases, tb.syncs, tb.prims, tb.descs, tb.rowsN,
               (unsigned long long)mean, (unsigned long long)tb.clkMax, (unsigned long long)tb.clkHist[0],
               (unsigned long long)tb.clkHist[1], (unsigned long long)tb.clkHist[2], (unsigned long long)tb.clkHist[3],
               (unsigned long long)tb.clkHist[4], (unsigned long long)tb.clkHist[5], (unsigned long long)tb.clkHist[6],
               (unsigned long long)tb.clkHist[7], (unsigned long long)(tb.cyc - c0));
        totEntries += tb.entries;
        totClk += tb.clkSum;
        totMax = std::max(totMax, tb.clkMax);
    }
    printf("isp_tile: %ld cases, %ld renders not rendered by refsw3-offline; %llu entries, %llu RTL clocks in them "
           "(mean %llu, max %llu an entry)\n", nCases, skipped, (unsigned long long)totEntries,
           (unsigned long long)totClk, (unsigned long long)(totEntries ? totClk / totEntries : 0),
           (unsigned long long)totMax);
    printf("isp_tile: VRAM reads: C1 %llu in half 0, %llu in half 1; C2 %llu, %llu\n",
           (unsigned long long)tb.vm.readsBy[0][1], (unsigned long long)tb.vm.readsBy[1][1],
           (unsigned long long)tb.vm.readsBy[0][2], (unsigned long long)tb.vm.readsBy[1][2]);
    f.ok(tb.mrows == 0, "isp_tile: %ld MODIFIER rows one clock after one of the same row (p2_isp_pix's stencil has no "
         "bypass from R2)", tb.mrows);
    top->final();
    delete top;
    return f.finish();
}

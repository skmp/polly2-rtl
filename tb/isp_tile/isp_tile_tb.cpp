// isp_tile_tb.cpp: the ISP tile testbench (PLAN 1.3 "ISP tile testbench", M6, M7; make isp-tile, isp-tile-op).
//
//   tb [--mode halt|free] [--seed S] [--vramvary S | +vramvary=S] [--vrlat N] [--phase-limit CLK] [--op-only]
//      [--max-fails N] [--shard k/N] [--trace] <case folder> | @<list file> ...
//
// A case folder is a capture (tools/gate/capture_prerender.sh: r0, r1, ... each with the registers and video memory
// before a render). Its renders run in order in one reference core (itref::reset_core first) and one RTL (reset first,
// then the reference's state written into its buffers through the debug port: what a render leaves in the ISP's buffers
// is the next one's, as on a console).
//
// --mode halt (phase-halt mode, PLAN 1.3): each render goes through the M5 phase driver (tb/ref/phase_driver.cpp,
// through itref: isp_tile_ref.h); at each of its hooks (the boundary after a phase, tb/common/isp_live.h) the RTL runs,
// with p2_isp_ctl's phase halt on, to its own halt, which must be the same phase; there every field of all 1024 pixels
// that isp_live.h calls live is compared with the reference's through p2_isp_buf's debug port (depthA, tagA, stencil,
// valid always; depthB / tagB, depthC, refTagC, opTag, everRendered, rendered, resPass as rcur / rlp, resTag and
// resDepth (rsd) in the punch-through passes; savedDepth (rsd) in the sort). Meanwhile the testbench is the TSP: it pops
// the run stream with random back-pressure and checks every item of the phase's SHADE passes against the reference's
// runs (refsw3's SpanGen of that pass, or for the pre-sorted passes, which refsw3 shades inside its walk, the PASS /
// SPAN lines of its render log): tag (32 bits), line, column, length, vmask, pmask, rm, the epoch (the count of passes
// with a run since reset, mod 128), eop on each pass's last run, one eoe per entry on its last item (a null item when
// the entry's end was decided after its last run). In a punch-through pass it answers with the reference's outcome of
// each pixel (run-only, fail, pass: from the reference's state before and after its SHADE) as p2_fb_t messages in the
// RTL's run order, then PASS_DONE. At each entry's end: its record from p2_entq (tile, z_keep, no_writeout, last,
// shaded_any = tilePixelsShaded != 0) and its punch-through chunk / pass and sort pass counts against the reference's.
// --op-only: M6's gate (make isp-tile-op): the phases Z, OP, OP_MOD only are compared (the rest still run).
//
// --mode free (free-running mode): the reference renders first, recording every entry's passes (runs and masks, the
// punch-through outcomes), record and counts, and its state at the render's end; then the RTL runs with no halt, the
// entries fed back to back as fast as it takes them, the run stream popped with random back-pressure (a stall chance
// and burst length per case), the punch-through passes answered after a random delay; the stream, the entry records
// and the counts are checked as above, and the live fields at the render's end. This is the mode that exercises the
// row barrier: the cutter of a pass beside the next pass's or entry's raster and sweeps.
//
// The VRAM model (tb/common/vram_model.h) serves C1 and C2 from refcore's emu_vram; --vramvary S varies its latency and
// readiness at random (seed S): the values must not change (PLAN 1.6), only the clocks.
//
// Reports per case its renders, entries, phases compared, passes and runs checked, the clocks per entry (halt: from the
// entry's accept to its end, halts excluded; free: the render's clocks per entry); then "isp_tile: <n> checks, <m>
// failures" and PASS / FAIL.
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <sys/stat.h>
#include <vector>

#include "Vp2_isp_tile_tb_top.h"
#include "verilated.h"

#include "isp_live.h"
#include "isp_tile_ref.h"
#include "p2tb.h"
#include "vram_model.h"

namespace {

using P = p2live::Phase;
enum { RM_OPAQUE = 0, RM_PT0 = 1, RM_PTN = 2, RM_PTMV = 3, RM_AUTOSORT = 4, RM_PRESORT = 5, RM_MODIFIER = 6 };

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

struct Rng {
    uint64_t s;
    explicit Rng(uint64_t seed = 1) : s(seed * 0x9E3779B97F4A7C15ull + 0x632BE59BD9B4E019ull) {}
    uint32_t u32()
    {
        s ^= s >> 12; s ^= s << 25; s ^= s >> 27;
        return (uint32_t)((s * 0x2545F4914F6CDD1Dull) >> 32);
    }
    uint32_t below(uint32_t n) { return n ? u32() % n : 0; }
};

// a pass the reference shaded (non-empty), with its punch-through outcomes (0 run-only, 1 fail, 2 pass) per pixel
struct Pass {
    int rm;
    std::vector<itref::Run> runs;
    std::vector<uint8_t> outcome;       // PT passes: 1024
};
struct EntryRec {
    itref::Entry e;
    std::vector<Pass> passes;
    bool shadedAny = false;
    int chunks = 0, ptPasses = 0, trPasses = 0, ptShades = 0;
};

// a run item as the RTL emitted it
struct Item {
    bool null_, eop, eoe;
    uint32_t tag, vmask, pmask;
    int y, x, len, rm, epoch;
};

const char* PhName(int p) { return p2live::name((P)p); }

struct Tb {
    Vp2_isp_tile_tb_top* t = nullptr;
    p2tb::VramModel vm;
    p2tb::Fails& f;
    uint64_t cyc = 0;
    uint64_t phaseLimit = 20000000;
    bool trace = false, opOnly = false, freeMode = false;
    std::string where;                  // the render, for messages
    Rng rng;

    // the TSP's side: back-pressure of the run stream, the feedback
    uint32_t stallP = 0, burst = 1;     // a stall chance in 1/256, the longest stall
    uint32_t stallLeft = 0;
    std::vector<Item> got;              // the items popped since the last check
    std::deque<std::pair<int, int>> fbq;   // the feedback to send: pixel, outcome
    bool ptPass = false;                // a punch-through pass is being answered
    bool ptEop = false;                 // ... its eop item has been popped
    const std::vector<uint8_t>* outc = nullptr;
    uint32_t fbDelay = 0;
    int expEpoch = 0;
    long eoeSeen = 0, recsSeen = 0;
    std::deque<std::pair<bool, uint32_t>> recq;   // eoe items popped whose record is due: (valid, tile) for messages

    // the case's state
    bool broken = false;                // the RTL lost step with the reference: the render's later entries are skipped
    bool needSync = true;

    // statistics
    long entries = 0, phases = 0, renders = 0, prims = 0, descs = 0, rowsN = 0, passesN = 0, runsN = 0, nulls = 0;
    long mrows = 0, vby = 0, barStalls = 0, ovfClk = 0, fwClk = 0, replays = 0, holdClk = 0, drops = 0, fbMsgs = 0;
    uint64_t entClk = 0, clkSum = 0, clkMax = 0;
    std::vector<uint64_t> clkHist = std::vector<uint64_t>(8, 0);   // < 64, < 128, < 256, < 512, < 1k, < 4k, < 16k, more

    explicit Tb(p2tb::Fails& fl) : f(fl) {}

    // ------------------------------------------------------------------------------------------------ the clock
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
        // the TSP: back-pressure, the feedback
        if (stallLeft)
            stallLeft--;
        else if (stallP && rng.below(256) < stallP)
            stallLeft = 1 + rng.below(burst);
        t->rs_rdy = stallLeft == 0;
        t->eq_rdy = 0;
        t->fb_v = 0;
        if (ptPass) {
            if (fbDelay)
                fbDelay--;
            else if (!fbq.empty()) {
                const auto m = fbq.front();
                t->fb_v = 1;
                t->fb_kind = 0;
                t->fb_idx = m.first;
                t->fb_ro = m.second == 0;
                t->fb_fail = m.second == 1;
                if (stallP && rng.below(256) < stallP / 2)
                    fbDelay = rng.below(burst);
            } else if (ptEop) {
                t->fb_v = 1;
                t->fb_kind = 1;
                t->fb_idx = 0;
                t->fb_ro = 0;
                t->fb_fail = 0;
            }
        }
        t->clk = 0;
        t->eval();
        // the run item and p2_entq, as the TSP's side takes them
        if (t->rs_v && t->rs_rdy) {
            Item it{ (bool)t->rs_null, (bool)t->rs_eop, (bool)t->rs_eoe, t->rs_tag, t->rs_vmask, t->rs_pmask,
                     (int)t->rs_y, (int)t->rs_x, (int)t->rs_lenm1 + 1, (int)t->rs_rm, (int)t->rs_epoch };
            got.push_back(it);
            if (!freeMode && ptPass && !it.null_) {
                for (int i = 0; i < it.len; i++) {
                    const int px = it.y * 32 + it.x + i;
                    fbq.push_back({ px, outc ? (*outc)[px] : 1 });
                }
                if (it.eop)
                    ptEop = true;
            }
            if (it.eoe)
                eoeSeen++;
        }
        // p2_entq: popped when its eoe item has been popped (p2_tbuf's rule), one record a clock
        if (t->eq_v && eoeSeen > recsSeen) {
            t->eq_rdy = 1;
            t->eval();
        }
        bool fbSent = false, doneSent = false;
        if (t->fb_v && t->fb_rdy) {
            if (t->fb_kind)
                doneSent = true;
            else
                fbSent = true;
        }
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
        if (t->eq_v && t->eq_rdy)
            pop_rec();
        if (t->busy && !t->halted)
            entClk++;
        prims += t->t_asm;
        descs += t->t_desc;
        rowsN += t->t_row;
        mrows += t->t_mrow;
        vby += t->t_vby;
        barStalls += t->t_bar;
        ovfClk += t->t_ovf;
        fwClk += t->t_fw;
        replays += t->t_rp;
        holdClk += t->t_hold;
        drops += t->t_drop;
        t->clk = 1;
        t->eval();
        if (fbSent) {
            fbq.pop_front();
            fbMsgs++;
        }
        if (doneSent) {
            ptPass = false;
            ptEop = false;
        }
        for (int h = 0; h < 2; h++)
            vm.edge(h, rv[h], rwe[h], ridx[h], rbe[h], rwd[h], rsrc[h]);
        vm.tick();
        cyc++;
    }

    // the records p2_entq gives, against the expected ones
    std::deque<itref::Entry> recExp;
    std::deque<bool> recShaded;
    void pop_rec()
    {
        recsSeen++;
        if (recExp.empty()) {
            f.ok(false, "%s: an entry record with no entry", where.c_str());
            broken = true;
            return;
        }
        const itref::Entry e = recExp.front();
        const bool sh = recShaded.front();
        recExp.pop_front();
        recShaded.pop_front();
        if (!f.ok((int)t->eq_tilex == e.tilex && (int)t->eq_tiley == e.tiley && t->eq_z_keep == e.z_keep &&
                  t->eq_no_writeout == e.no_writeout && t->eq_last == e.last && (bool)t->eq_shaded_any == sh,
                  "%s tile (%d, %d): entry record {%d, %d, z_keep %d, no_writeout %d, last %d, shaded_any %d}, "
                  "reference {%d, %d, %d, %d, %d, %d}", where.c_str(), e.tilex, e.tiley, (int)t->eq_tilex,
                  (int)t->eq_tiley, (int)t->eq_z_keep, (int)t->eq_no_writeout, (int)t->eq_last,
                  (int)t->eq_shaded_any, e.tilex, e.tiley, e.z_keep, e.no_writeout, e.last, sh))
            broken = true;
    }

    void reset()
    {
        vm.flush();
        t->rst = 1;
        t->ent_v = 0;
        t->resume = 0;
        t->dbg_we = 0;
        t->fb_v = 0;
        for (int i = 0; i < 4; i++)
            tick();
        vm.flush();
        t->rst = 0;
        tick();
        expEpoch = 0;
        got.clear();
        fbq.clear();
        ptPass = ptEop = false;
        eoeSeen = recsSeen = 0;
        recExp.clear();
        recShaded.clear();
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
        t->isp_feed_cfg = r.isp_feed_cfg;
    }

    // the reference's whole state into the RTL's buffers, a row a clock through the debug port
    void sync()
    {
        std::vector<itref::Pix> p(1024);
        itref::pixels(p.data());
        const int pp = itref::pt_pass();
        for (int row = 0; row < 32; row++) {
            t->dbg_we = 1;
            t->dbg_row = row;
            uint32_t vm_ = 0, rn = 0, rc = 0, rl = 0, ev = 0;
            for (int i = 0; i < 32; i++) {
                const itref::Pix& x = p[row * 32 + i];
                t->dbg_wdepth[i] = (uint64_t)x.depth;
                t->dbg_wtag[i] = x.tag;
                t->dbg_wdepth_b[i] = (uint64_t)x.depthB;
                t->dbg_wtag_b[i] = x.tagB;
                t->dbg_wdepth_c[i] = (uint64_t)x.depthC;
                t->dbg_wreftag_c[i] = x.refTagC;
                t->dbg_woptag[i] = x.opTag;
                t->dbg_wrestag[i] = x.resTag;
                t->dbg_wrsd[i] = (uint64_t)x.resDepth;
                t->dbg_wstencil[i] = x.stencil & 7;
                vm_ |= (uint32_t)x.valid << i;
                rn |= (uint32_t)x.rendered << i;
                rc |= (uint32_t)(x.resPass == pp) << i;
                rl |= (uint32_t)(x.resPass == pp - 1) << i;
                ev |= (uint32_t)x.everRendered << i;
            }
            t->dbg_wvalid = vm_;
            t->dbg_wrendered = rn;
            t->dbg_wrcur = rc;
            t->dbg_wrlp = rl;
            t->dbg_wever = ev;
            tick();
        }
        t->dbg_we = 0;
    }

    // every live field of every pixel against the reference's (tb/common/isp_live.h)
    bool compare(int ph, const itref::Entry& e)
    {
        std::vector<itref::Pix> ref(1024);
        itref::pixels(ref.data());
        const int pp = itref::pt_pass();
        long bad = 0;
        std::string first;
        for (int row = 0; row < 32; row++) {
            t->dbg_row = row;
            t->eval();
            for (int i = 0; i < 32; i++) {
                const itref::Pix& r = ref[row * 32 + i];
                uint32_t m = opOnly ? (p2live::DEPTH_A | p2live::TAG_A | p2live::STENCIL | p2live::VALID)
                                    : p2live::live((P)ph, r.rendered, r.everRendered);
                const char* fld = nullptr;
                char b[200];
                auto chk = [&](uint32_t bit, bool eq, const char* name, unsigned long long g, unsigned long long w) {
                    if (fld || !(m & bit) || eq)
                        return;
                    fld = name;
                    snprintf(b, sizeof b, "%s %llx, reference %llx", name, g, w);
                };
                chk(p2live::DEPTH_A, (int64_t)t->dbg_depth[i] == r.depth, "depthA", t->dbg_depth[i], r.depth);
                chk(p2live::TAG_A, t->dbg_tag[i] == r.tag, "tagA", t->dbg_tag[i], r.tag);
                chk(p2live::STENCIL, t->dbg_stencil[i] == (uint32_t)(r.stencil & 7), "stencil", t->dbg_stencil[i],
                    r.stencil & 7);
                chk(p2live::VALID, (t->dbg_valid >> i & 1) == r.valid, "valid", t->dbg_valid >> i & 1, r.valid);
                chk(p2live::DEPTH_B, (int64_t)t->dbg_depth_b[i] == r.depthB, "depthB", t->dbg_depth_b[i], r.depthB);
                chk(p2live::TAG_B, t->dbg_tag_b[i] == r.tagB, "tagB", t->dbg_tag_b[i], r.tagB);
                chk(p2live::DEPTH_C, (int64_t)t->dbg_depth_c[i] == r.depthC, "depthC", t->dbg_depth_c[i], r.depthC);
                chk(p2live::REFTAG_C, t->dbg_reftag_c[i] == r.refTagC, "refTagC", t->dbg_reftag_c[i], r.refTagC);
                chk(p2live::OPTAG, t->dbg_optag[i] == r.opTag, "opTag", t->dbg_optag[i], r.opTag);
                chk(p2live::EVER_RENDERED, (t->dbg_ever >> i & 1) == r.everRendered, "everRendered",
                    t->dbg_ever >> i & 1, r.everRendered);
                chk(p2live::RENDERED, (t->dbg_rendered >> i & 1) == r.rendered, "rendered", t->dbg_rendered >> i & 1,
                    r.rendered);
                const uint32_t rp = (t->dbg_rcur >> i & 1) | (t->dbg_rlp >> i & 1) << 1;
                const uint32_t rpw = (uint32_t)(r.resPass == pp) | (uint32_t)(r.resPass == pp - 1) << 1;
                chk(p2live::RES_PASS, rp == rpw, "rcur/rlp", rp, rpw);
                chk(p2live::RES_TAG, t->dbg_restag[i] == r.resTag, "resTag", t->dbg_restag[i], r.resTag);
                chk(p2live::RES_DEPTH, (int64_t)t->dbg_rsd[i] == r.resDepth, "resDepth", t->dbg_rsd[i], r.resDepth);
                chk(p2live::SAVED_DEPTH, (int64_t)t->dbg_rsd[i] == r.savedDepth, "savedDepth", t->dbg_rsd[i],
                    r.savedDepth);
                if (fld && !bad++) {
                    char c[300];
                    snprintf(c, sizeof c, "pixel (%d, %d): %s", i, row, b);
                    first = c;
                }
            }
        }
        phases++;
        if (!f.ok(bad == 0, "%s tile (%d, %d) after %s: %ld of 1024 pixels differ; the first %s", where.c_str(),
                  e.tilex, e.tiley, PhName(ph), bad, first.c_str()))
            broken = true;
        return bad == 0;
    }

    // the items popped since the last check against these passes. entryEnd: the entry's eoe is due among them (on the
    // last run of the last pass, or as a null item when there is none)
    bool check_items(const std::vector<Pass>& exp, const itref::Entry& e, bool entryEnd, const char* what)
    {
        size_t k = 0;
        std::string err;
        char b[400];
        long eoes = 0;
        for (const Pass& ps : exp) {
            for (size_t r = 0; r < ps.runs.size(); r++, k++) {
                const itref::Run& w = ps.runs[r];
                if (k >= got.size()) {
                    snprintf(b, sizeof b, "the run stream ends before run %zu of %zu of a pass (rm %d)", r,
                             ps.runs.size(), ps.rm);
                    err = b;
                    goto done;
                }
                const Item& g = got[k];
                const bool lastRun = r + 1 == ps.runs.size();
                if (g.null_ || g.tag != w.tag || g.y != w.y || g.x != w.x || g.len != w.len || g.vmask != w.vmask ||
                    g.pmask != w.pmask || g.rm != ps.rm || g.epoch != (expEpoch & 127) || g.eop != lastRun) {
                    snprintf(b, sizeof b, "run %zu of a pass (rm %d): %s{tag %08x y %d x %d len %d vmask %08x pmask "
                             "%08x rm %d epoch %d eop %d}, reference {%08x %d %d %d %08x %08x %d %d %d}", r, ps.rm,
                             g.null_ ? "a null item " : "", g.tag, g.y, g.x, g.len, g.vmask, g.pmask, g.rm, g.epoch,
                             g.eop, w.tag, w.y, w.x, w.len, w.vmask, w.pmask, ps.rm, expEpoch & 127, lastRun);
                    err = b;
                    goto done;
                }
                if (g.eoe) {
                    eoes++;
                    if (!(entryEnd && &ps == &exp.back() && lastRun)) {
                        err = "an eoe on a run that is not the entry's last";
                        goto done;
                    }
                }
                runsN++;
            }
            passesN++;
            expEpoch++;
        }
        // what may follow: one null eoe item at the entry's end
        if (k < got.size()) {
            const Item& g = got[k];
            if (entryEnd && g.null_ && g.eoe && k + 1 == got.size() && eoes == 0) {
                eoes++;
                nulls++;
                k++;
            } else {
                snprintf(b, sizeof b, "%zu items more than the reference's %zu runs (the first: %s tag %08x y %d x "
                         "%d len %d rm %d eop %d eoe %d)", got.size() - k, k, g.null_ ? "null" : "run", g.tag, g.y,
                         g.x, g.len, g.rm, g.eop, g.eoe);
                err = b;
                goto done;
            }
        }
        if (err.empty() && entryEnd && eoes != 1)
            err = "the entry's items carry no eoe";
        if (err.empty() && !entryEnd && eoes)
            err = "an eoe before the entry's last SHADE";
    done:
        got.clear();
        if (!f.ok(err.empty(), "%s tile (%d, %d) %s: %s", where.c_str(), e.tilex, e.tiley, what, err.c_str())) {
            broken = true;
            return false;
        }
        return true;
    }

    // ------------------------------------------------------------------------------------------------ phase-halt
    // run until the RTL halts; false (reported) if it does not, or ends the entry first
    bool run_to_halt(int ph, const itref::Entry& e)
    {
        for (uint64_t n = 0; n < phaseLimit; n++) {
            if (t->halted) {
                const int hp = t->halt_phase;
                if (hp == ph)
                    return true;
                f.ok(false, "%s tile (%d, %d): the RTL halted after %s, the reference after %s", where.c_str(),
                     e.tilex, e.tiley, hp < 19 ? PhName(hp) : "?", PhName(ph));
                broken = true;
                return false;
            }
            if (!t->busy) {
                f.ok(false, "%s tile (%d, %d): the RTL ended the entry before its %s", where.c_str(), e.tilex,
                     e.tiley, PhName(ph));
                broken = true;
                return false;
            }
            tick();
        }
        f.ok(false, "%s tile (%d, %d): the RTL did not finish %s in %llu clocks", where.c_str(), e.tilex, e.tiley,
             PhName(ph), (unsigned long long)phaseLimit);
        broken = true;
        return false;
    }
    void resume()
    {
        t->resume = 1;
        tick();
        t->resume = 0;
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
    }

    void entry_clocks()
    {
        entries++;
        clkSum += entClk;
        clkMax = std::max(clkMax, entClk);
        static const uint64_t lim[7] = { 64, 128, 256, 512, 1024, 4096, 16384 };
        int b = 0;
        while (b < 7 && entClk >= lim[b])
            b++;
        clkHist[b]++;
    }

    // the entry in progress (phase-halt)
    itref::Entry cur;
    std::vector<itref::Pix> prePt = std::vector<itref::Pix>(1024);
    Pass ptExp;
    bool ptHas = false;
    int hChunks = 0, hPasses = 0, hTr = 0, hShades = 0;
    bool presortOn = false, eoeDone = false;

    void outcomes(const std::vector<itref::Pix>& pre, std::vector<uint8_t>& out)
    {
        std::vector<itref::Pix> post(1024);
        itref::pixels(post.data());
        out.assign(1024, 1);
        for (int i = 0; i < 1024; i++)
            out[i] = pre[i].rendered ? 0 : (post[i].rendered ? 2 : 1);
    }

    void hook(int ph, const itref::Entry& e)
    {
        if (broken)
            return;
        // the pre-sorted passes are shaded inside the TR_PS walk: the render log from the hook before it
        const bool psEntry = e.pre_sort && !e.empty[2];
        if (ph == P::Z) {
            if (needSync)
                sync();
            needSync = false;
            if (!f.ok(!t->busy, "%s tile (%d, %d): the RTL is still in the entry before", where.c_str(), e.tilex,
                      e.tiley)) {
                broken = true;
                return;
            }
            cur = e;
            hChunks = hPasses = hTr = hShades = 0;
            eoeDone = false;
            entClk = 0;
            feed(e);
            t->ent_v = 1;
            tick();            // ctl is idle: it takes the entry at this edge
            t->ent_v = 0;
            recExp.push_back(e);
        }
        std::vector<Pass> exp;
        std::vector<std::vector<itref::Run>> ps;
        // the SHADE ctl knows at its issue to be the entry's last carries the eoe (or a null item when it has no run);
        // otherwise END's null item does (p2_isp_ctl)
        bool entryEnd = false;
        if (ph == P::OP_SHADE)
            entryEnd = e.empty[4] && e.empty[2];
        else if (ph == P::PT_MV_SHADE)
            entryEnd = e.empty[2];
        else if (ph == P::TR_SHADE)
            entryEnd = !itref::more();
        else if (ph == P::END)
            entryEnd = !eoeDone;
        if (entryEnd)
            eoeDone = true;
        switch (ph) {
        case P::OP_SHADE: exp.push_back({ RM_OPAQUE, {}, {} }); itref::spans(RM_OPAQUE, exp.back().runs); break;
        case P::PT_INIT: hChunks = 1; break;
        case P::PT_CHUNK: hChunks++; break;
        case P::PT_WALK:
            hPasses++;
            ptHas = itref::more();
            if (ptHas) {
                itref::pixels(prePt.data());
                ptExp = { RM_PT0, {}, {} };
                itref::spans(RM_PT0, ptExp.runs);
            }
            break;
        case P::PT_SHADE:
            hShades++;
            outcomes(prePt, ptExp.outcome);
            exp.push_back(ptExp);
            break;
        case P::PT_MV_SHADE: exp.push_back({ RM_PTMV, {}, {} }); itref::spans(RM_PTMV, exp.back().runs); break;
        case P::TR_PS:
            itref::presort_end(ps);
            presortOn = false;
            for (auto& r : ps)
                if (!r.empty())
                    exp.push_back({ RM_PRESORT, r, {} });
            break;
        case P::TR_PEEL: hTr++; break;
        case P::TR_SHADE: exp.push_back({ RM_AUTOSORT, {}, {} }); itref::spans(RM_AUTOSORT, exp.back().runs); break;
        default: break;
        }
        for (auto it = exp.begin(); it != exp.end();)
            it = it->runs.empty() ? exp.erase(it) : it + 1;
        // the record's shaded_any: tilePixelsShaded only grows in the entry, and its record is popped with its eoe
        recShaded.resize(recExp.size(), false);
        if (!recShaded.empty())
            recShaded.back() = itref::tile_pixels_shaded() != 0;
        // the TSP's side of a punch-through pass
        if (ph == P::PT_SHADE) {
            ptPass = true;
            ptEop = false;
            outc = &exp.back().outcome;
            fbq.clear();
        }
        if (trace)
            printf("  %s tile (%d, %d) %s: %zu passes expected, clock %llu\n", where.c_str(), e.tilex, e.tiley,
                   PhName(ph), exp.size(), (unsigned long long)cyc);
        if (run_to_halt(ph, e)) {
            if (opOnly) {
                if (ph == P::Z || ph == P::OP || ph == P::OP_MOD)
                    compare(ph, e);
                got.clear();
            } else {
                check_items(exp, e, entryEnd, PhName(ph));
                if (!broken)
                    compare(ph, e);
                if (!broken && ph == P::END) {
                    const int wc = hChunks, wp = hPasses, wt = hTr, ws = hShades;
                    f.ok(t->st_chunks == wc && t->st_passes == wp && t->st_trpasses == wt && t->st_ptshades == ws,
                         "%s tile (%d, %d): punch-through chunks %d, passes %d (SHADEs %d), sort passes %d; reference "
                         "%d, %d (%d), %d", where.c_str(), e.tilex, e.tiley, (int)t->st_chunks, (int)t->st_passes,
                         (int)t->st_ptshades, (int)t->st_trpasses, wc, wp, ws, wt) || (broken = true);
                }
            }
            resume();
            if (ph == P::END) {
                for (uint64_t n = 0; t->busy && n < phaseLimit; n++)
                    tick();
                // the record: the eoe item was popped; p2_entq gives it
                for (int n = 0; n < 8 && recsSeen < eoeSeen; n++)
                    tick();
                if (!opOnly)
                    f.ok(recExp.empty(), "%s tile (%d, %d): p2_entq gave no record for the entry", where.c_str(),
                         e.tilex, e.tiley) || (broken = true);
                recExp.clear();
                recShaded.clear();
                entry_clocks();
                if (trace)
                    printf("  entry tile (%d, %d): %llu clocks\n", e.tilex, e.tiley, (unsigned long long)entClk);
            }
        }
        if (psEntry && !broken && ph != P::TR_PS && ph != P::END) {
            itref::presort_begin();
            presortOn = true;
        }
        if (ph == P::END && presortOn) {
            itref::presort_end(ps);
            presortOn = false;
        }
    }

    // ------------------------------------------------------------------------------------------------ free-running
    std::vector<EntryRec> rec;          // the render's entries as the reference ran them
    std::vector<itref::Pix> preF = std::vector<itref::Pix>(1024);

    void record(int ph, const itref::Entry& e)
    {
        if (ph == P::Z) {
            rec.emplace_back();
            rec.back().e = e;
        }
        EntryRec& r = rec.back();
        std::vector<std::vector<itref::Run>> ps;
        auto add = [&](int rm) {
            Pass p{ rm, {}, {} };
            itref::spans(rm, p.runs);
            if (!p.runs.empty())
                r.passes.push_back(p);
        };
        switch (ph) {
        case P::OP_SHADE: add(RM_OPAQUE); break;
        case P::PT_INIT: r.chunks = 1; break;
        case P::PT_CHUNK: r.chunks++; break;
        case P::PT_WALK:
            r.ptPasses++;
            if (itref::more()) {
                itref::pixels(preF.data());
                Pass p{ RM_PT0, {}, {} };
                itref::spans(RM_PT0, p.runs);
                r.passes.push_back(p);
            }
            break;
        case P::PT_SHADE: r.ptShades++; outcomes(preF, r.passes.back().outcome); break;
        case P::PT_MV_SHADE: add(RM_PTMV); break;
        case P::TR_PS:
            itref::presort_end(ps);
            presortOn = false;
            for (auto& x : ps)
                if (!x.empty())
                    r.passes.push_back({ RM_PRESORT, x, {} });
            break;
        case P::TR_PEEL: r.trPasses++; break;
        case P::TR_SHADE: add(RM_AUTOSORT); break;
        case P::END: r.shadedAny = itref::tile_pixels_shaded() != 0; break;
        default: break;
        }
        const bool psEntry = e.pre_sort && !e.empty[2];
        if (psEntry && ph != P::TR_PS && ph != P::END) {
            itref::presort_begin();
            presortOn = true;
        }
        if (ph == P::END && presortOn) {
            itref::presort_end(ps);
            presortOn = false;
        }
    }

    // the RTL on the recorded render, no halt; the stream checked as it comes
    uint64_t freeClk = 0;
    void run_free()
    {
        t->halt_en = 0;
        size_t fed = 0;                 // entries given to ctl
        size_t ei = 0, pi = 0, ri = 0;  // the cursor in the expected stream: entry, pass, run
        size_t done = 0;                // entries ended (ent_done)
        std::deque<uint64_t> accepted;  // the clock each entry in progress was taken
        uint64_t c0 = cyc;
        std::string err;
        char b[400];
        recExp.clear();
        recShaded.clear();
        while (!broken) {
            // the next entry, as soon as ctl takes one
            if (fed < rec.size() && t->ent_rdy) {
                feed(rec[fed].e);
                t->ent_v = 1;
                accepted.push_back(cyc);
                recExp.push_back(rec[fed].e);
                recShaded.push_back(rec[fed].shadedAny);
                fed++;
            } else
                t->ent_v = 0;
            // an entry's end (ent_done, a registered pulse): its counts, read before ctl takes the next entry
            if (t->ent_done) {
                if (done >= rec.size()) {
                    f.ok(false, "%s: more entries ended than were fed", where.c_str());
                    broken = true;
                    break;
                }
                const EntryRec& r = rec[done];
                if (!f.ok(t->st_chunks == r.chunks && t->st_passes == r.ptPasses && t->st_trpasses == r.trPasses &&
                          t->st_ptshades == r.ptShades,
                          "%s tile (%d, %d): punch-through chunks %d, passes %d (SHADEs %d), sort passes %d; reference "
                          "%d, %d (%d), %d", where.c_str(), r.e.tilex, r.e.tiley, (int)t->st_chunks, (int)t->st_passes,
                          (int)t->st_ptshades, (int)t->st_trpasses, r.chunks, r.ptPasses, r.ptShades, r.trPasses))
                    broken = true;
                done++;
                // the entry's clocks from its accept to its end (entries overlap: the next one starts behind it)
                entClk = accepted.empty() ? 0 : cyc - accepted.front();
                if (!accepted.empty())
                    accepted.pop_front();
                entry_clocks();
            }
            tick();
            t->ent_v = 0;
            // check what came out
            for (const Item& g : got) {
                if (ei >= rec.size()) {
                    err = "an item after the render's last entry";
                    break;
                }
                const EntryRec& r = rec[ei];
                if (g.null_) {
                    if (!(g.eoe && pi == r.passes.size())) {
                        snprintf(b, sizeof b, "tile (%d, %d): a null item (eoe %d) with %zu of %zu passes out",
                                 r.e.tilex, r.e.tiley, g.eoe, pi, r.passes.size());
                        err = b;
                        break;
                    }
                    nulls++;
                    ei++;
                    pi = ri = 0;
                    continue;
                }
                if (pi >= r.passes.size()) {
                    snprintf(b, sizeof b, "tile (%d, %d): a run after the entry's %zu passes", r.e.tilex, r.e.tiley,
                             r.passes.size());
                    err = b;
                    break;
                }
                const Pass& ps = r.passes[pi];
                const itref::Run& w = ps.runs[ri];
                const bool lastRun = ri + 1 == ps.runs.size();
                const bool lastPass = pi + 1 == r.passes.size();
                if (g.tag != w.tag || g.y != w.y || g.x != w.x || g.len != w.len || g.vmask != w.vmask ||
                    g.pmask != w.pmask || g.rm != ps.rm || g.epoch != (expEpoch & 127) || g.eop != lastRun ||
                    (g.eoe && !(lastRun && lastPass))) {
                    snprintf(b, sizeof b, "tile (%d, %d) pass %zu (rm %d) run %zu: {tag %08x y %d x %d len %d vmask "
                             "%08x pmask %08x rm %d epoch %d eop %d eoe %d}, reference {%08x %d %d %d %08x %08x %d %d "
                             "%d}", r.e.tilex, r.e.tiley, pi, ps.rm, ri, g.tag, g.y, g.x, g.len, g.vmask, g.pmask, g.rm,
                             g.epoch, g.eop, g.eoe, w.tag, w.y, w.x, w.len, w.vmask, w.pmask, ps.rm, expEpoch & 127,
                             lastRun);
                    err = b;
                    break;
                }
                runsN++;
                // a punch-through pass: the TSP answers its pixels as their runs come, PASS_DONE after the last
                if (ps.rm == RM_PT0) {
                    if (ri == 0) {
                        ptPass = true;
                        ptEop = false;
                        fbq.clear();
                        fbDelay = stallP ? rng.below(4 * burst + 1) : 0;
                    }
                    for (int i = 0; i < g.len; i++) {
                        const int px = g.y * 32 + g.x + i;
                        fbq.push_back({ px, ps.outcome[px] });
                    }
                    if (lastRun)
                        ptEop = true;
                }
                if (lastRun) {
                    passesN++;
                    expEpoch++;
                    pi++;
                    ri = 0;
                    if (g.eoe) {
                        ei++;
                        pi = 0;
                    }
                } else
                    ri++;
            }
            got.clear();
            if (!err.empty()) {
                f.ok(false, "%s: %s", where.c_str(), err.c_str());
                broken = true;
                break;
            }
            if (fed == rec.size() && done == rec.size() && ei == rec.size() && !t->busy && t->cut_idle &&
                recsSeen == eoeSeen && recExp.empty())
                break;
            if (cyc - c0 > phaseLimit) {
                f.ok(false, "%s: the render did not end in %llu clocks (%zu of %zu entries fed, %zu ended, %zu of the "
                     "stream's entries out)", where.c_str(), (unsigned long long)phaseLimit, fed, rec.size(), done, ei);
                broken = true;
                break;
            }
        }
        freeClk += cyc - c0;
        renders++;
    }
};

Tb* gTb = nullptr;
void Hook(int ph, const itref::Entry& e, void* u) { ((Tb*)u)->hook(ph, e); }
void Record(int ph, const itref::Entry& e, void* u) { ((Tb*)u)->record(ph, e); }

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
    bool freeMode = false, opOnly = false;
    long maxFails = 0;
    std::vector<std::string> cases;
    for (size_t i = 0; i < a.rest.size(); i++) {
        const std::string& s = a.rest[i];
        if (s == "--vramvary" && i + 1 < a.rest.size())
            vary = strtoull(a.rest[++i].c_str(), nullptr, 0);
        else if (s == "--vrlat" && i + 1 < a.rest.size())
            lat = atoi(a.rest[++i].c_str());
        else if (s == "--phase-limit" && i + 1 < a.rest.size())
            limit = strtoull(a.rest[++i].c_str(), nullptr, 0);
        else if (s == "--mode" && i + 1 < a.rest.size())
            freeMode = a.rest[++i] == "free";
        else if (s == "--op-only")
            opOnly = true;
        else if (s == "--max-fails" && i + 1 < a.rest.size())
            maxFails = atol(a.rest[++i].c_str());
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
    printf("isp_tile: mode %s%s, vramvary %llu, VR_LAT %d\n", freeMode ? "free-running" : "phase-halt",
           opOnly ? " (Z, OP, OP_MOD only)" : "", (unsigned long long)vary, lat);
    p2tb::Fails f("isp_tile");
    f.set(freeMode ? "free-running" : "phase-halt");

    Vp2_isp_tile_tb_top* top = new Vp2_isp_tile_tb_top;
    Tb tb(f);
    gTb = &tb;
    tb.t = top;
    tb.trace = a.trace;
    tb.opOnly = opOnly;
    tb.freeMode = freeMode;
    tb.phaseLimit = limit;
    tb.vm.varySeed = vary;
    tb.vm.vrLat = lat;
    tb.vm.init(itref::vram());

    long nCases = 0, skipped = 0;
    uint64_t totEntries = 0, totClk = 0, totMax = 0, totFree = 0;
    for (size_t ci = 0; ci < cases.size(); ci++) {
        if (!a.mine(ci))
            continue;
        if (maxFails && f.n >= maxFails)
            break;
        const std::string& c = cases[ci];
        nCases++;
        // the case's TSP: a stall chance and burst length (none in a third of the cases)
        tb.rng = Rng(a.seed * 1000003ull + ci);
        tb.stallP = tb.rng.below(3) ? tb.rng.below(200) + 8 : 0;
        tb.burst = 1 + tb.rng.below(24);
        itref::reset_core();
        tb.t->halt_en = freeMode ? 0 : 1;
        tb.reset();
        tb.needSync = true;
        tb.broken = false;
        tb.entries = tb.phases = tb.renders = tb.passesN = tb.runsN = tb.nulls = 0;
        tb.clkSum = tb.clkMax = 0;
        tb.prims = tb.descs = tb.rowsN = tb.barStalls = tb.ovfClk = tb.fwClk = tb.replays = tb.holdClk = 0;
        tb.drops = tb.fbMsgs = tb.vby = 0;
        tb.freeClk = 0;
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
            if (!freeMode) {
                const bool ended = itref::render(Hook, &tb, 1024);
                f.ok(ended, "%s: the reference's render did not end", r.c_str());
                tb.renders++;
            } else {
                if (tb.needSync) {
                    tb.sync();
                    tb.needSync = false;
                }
                tb.rec.clear();
                const bool ended = itref::render(Record, &tb, 1024);
                f.ok(ended, "%s: the reference's render did not end", r.c_str());
                if (ended) {
                    tb.run_free();
                    // the live fields at the render's end (after its last entry: depthA, tagA, stencil, valid)
                    if (!tb.broken && !tb.rec.empty())
                        tb.compare(P::END, tb.rec.back().e);
                }
            }
            if (maxFails && f.n >= maxFails)
                break;
            if (tb.broken) {
                // the rest of the render was not compared; the next render starts from the reference's state
                tb.needSync = true;
                tb.t->halt_en = freeMode ? 0 : 1;
                tb.reset();
            }
        }
        const uint64_t mean = tb.entries ? (freeMode ? tb.freeClk : tb.clkSum) / tb.entries : 0;
        printf("isp_tile: %s: %ld renders, %ld entries, %ld phases compared, %ld passes, %ld runs, %ld null items; "
               "%ld primitives, %ld descriptors (%ld replayed), %ld rows (%ld barrier stalls); pcache overflowed "
               "%ld clk, full-walk %ld clk, ptc held %ld clk, dropped %ld; %ld feedback messages; %ld valid bypasses; clocks an entry: "
               "mean %llu, max %llu; histogram <64 %llu <128 %llu <256 %llu <512 %llu <1k %llu <4k %llu <16k %llu "
               "more %llu; %llu clocks\n",
               c.c_str(), tb.renders, tb.entries, tb.phases, tb.passesN, tb.runsN, tb.nulls, tb.prims, tb.descs,
               tb.replays, tb.rowsN, tb.barStalls, tb.ovfClk, tb.fwClk, tb.holdClk, tb.drops, tb.fbMsgs, tb.vby,
               (unsigned long long)mean, (unsigned long long)tb.clkMax, (unsigned long long)tb.clkHist[0],
               (unsigned long long)tb.clkHist[1], (unsigned long long)tb.clkHist[2], (unsigned long long)tb.clkHist[3],
               (unsigned long long)tb.clkHist[4], (unsigned long long)tb.clkHist[5], (unsigned long long)tb.clkHist[6],
               (unsigned long long)tb.clkHist[7], (unsigned long long)(tb.cyc - c0));
        totEntries += tb.entries;
        totClk += tb.clkSum;
        totFree += tb.freeClk;
        totMax = std::max(totMax, tb.clkMax);
    }
    printf("isp_tile: %ld cases, %ld renders not rendered by refsw3-offline; %llu entries, %llu RTL clocks in them "
           "(mean %llu, max %llu an entry)\n", nCases, skipped, (unsigned long long)totEntries,
           (unsigned long long)(freeMode ? totFree : totClk),
           (unsigned long long)(totEntries ? (freeMode ? totFree : totClk) / totEntries : 0),
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

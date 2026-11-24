// tsp_tile_tb.cpp: the TSP tile testbench (PLAN M11, 1.3 "TSP tile testbench"; make tsp-tile, tsp-tile-mutants,
// tsp-tile-full).
//
//   tb [--seed S] [--shard k/N] [--renders A[-B]] [--max-fails N] [--vramvary S] [--stall PM] [--fbstall PM]
//      <case folder> | @<list file> ...
//
// The DUT (p2_tsp_tile_tb_top.sv): the TSP from the sorter's items to the tile buffers: p2_tsp_store, p2_tsp_pfetch,
// p2_tsp_setup on p2_tsp_alu, p2_tsp_rstart, p2_pxq, the pixel pipe P0 - P11 (p2_tsp_pp: texture on C4, shade, fog,
// SupSample, blend, feedback), p2_tbuf; p2_mem with the VRAM model (tb/common/vram_model.h).
//
// The reference (tsp_tile_ref.cpp): each render of a capture (build/pre/<case>/r<k>, tools/gate/capture_prerender.sh)
// rendered through the M5 phase driver, every SHADE pass's runs (refsw3's SpanGen + SpanSort of the state before it, the
// pre-sorted passes too) and every pixel shaded through the verbatim copies of RenderParamTags' loop and PixelFlush_tsp
// recorded. The testbench then feeds the RTL those runs, entry by entry, as the ISP's cutter and the sorter would hand
// them over (p2_rs_t with vmask, pmask, rm, eop on a pass's last run, eoe on the entry's last item or on a null item
// after it, at random), the entries' records, the registers (PALETTE_RAM, FOG_TABLE through their write ports), with
// random gaps on the items, random back-pressure on the feedback and random holds of the pipe (ext_stall), random reads
// of the secondary port, and checks, in the RTL's order:
//   - every pixel leaving P10: its index, run-only, the alpha test's outcome, and its tile-buffer write (buffer, index,
//     value) or that it writes nothing (run-only; SrcSelect && DstSelect);
//   - every feedback message (PIXEL {idx, fail, ro} of the punch-through passes, PASS_DONE {anyfail} after each);
//   - after every pass: every word of both tile buffers (the testbench's shadow of the RTL's buffers, kept from the write
//     tap, against a hash of refsw3's), tspAlphaStuck (as the pass's eop point leaves P10) and offsKept (as it leaves P7);
//   - at every render's end every word of both buffers read back through p2_tbuf's debug port (the shadow is the RAM),
//     and offsKept.
// The buffers swap where the controller swaps them (M12: p2_tbuf_ctl on each entry's record, which the testbench pushes
// into p2_entq with the entry's eoe item, as p2_isp_cut does; the testbench mirrors each swap, t_swap, in its shadow, and
// refsw3's NextTileAccumulationBuffers decide the expected buffers); the write-out (p2_wout, C5) runs as in p2_core: every
// read it makes of buffer 2 is checked, and at every render's end video memory against refsw3-offline's, every word.
// State carries from render to render within a case (the case's first render starts from the reference's buffers and
// offsKept, written in through the debug ports).
// A render whose texture reads (C4) touch a 64-bit word the render's write-out changed is VRAM-race (ARCHITECTURE 3.2.1:
// refsw3 reads the framebuffer as written so far, the RTL the render's start): its differences are counted in their own
// class, never as a pass or a fail.
//
// Work items: --shard i/N with N the list's case count selects case i alone; the generators are seeded from the case's
// index in the list, never from the shard. --renders A-B: the renders before A on the reference only.
#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <sys/stat.h>
#include <vector>

#include "Vp2_tsp_tile_tb_top.h"
#include "verilated.h"

#include "p2tb.h"
#include "tsp_tile_ref.h"
#include "vram_model.h"

namespace {

bool IsDir(const std::string& p)
{
    struct stat s;
    return stat(p.c_str(), &s) == 0 && S_ISDIR(s.st_mode);
}
bool IsFile(const std::string& p)
{
    struct stat s;
    return stat(p.c_str(), &s) == 0 && S_ISREG(s.st_mode);
}

enum { RM_OPAQUE = 0, RM_PT0 = 1, RM_PTN = 2, RM_PTMV = 3, RM_TRA = 4, RM_TRP = 5 };

struct Item {
    bool null_ = false;
    uint32_t tag = 0, vmask = 0, pmask = 0;
    int y = 0, x = 0, len = 1, rm = 0;
    bool eop = false, eoe = false, nd = false;
    int ent = 0;
    // the entry's record (p2_entq, with the eoe item)
    int tx = 0, ty = 0;
    bool zkeep = false, noWo = false, last = false, shaded = false;
};
struct ExpFb {
    bool done;
    int idx;
    bool fail, ro;
};
struct PassEnd {
    const ttref::Pass* p;
    int ent;
};

struct Stats {
    long renders = 0, raceRenders = 0, entries = 0, passes = 0, items = 0, nulls = 0, pixels = 0, writes = 0,
         fbMsgs = 0, swaps = 0, woReads = 0, presortPasses = 0, raceDiffs = 0, vramWords = 0;
    uint64_t clk = 0, texStall = 0, fbBlock = 0, extStall = 0, misses = 0, fillClk = 0, drain = 0, p0 = 0;
};

struct Tb {
    Vp2_tsp_tile_tb_top* t = nullptr;
    p2tb::Fails& f;
    p2tb::VramModel vm;
    p2tb::Rng rng{ 1 };
    Stats st;
    uint64_t cyc = 0;
    bool broken = false;
    std::string where;
    int stallPm = 30, fbPm = 300, woPm = 100;   // per mille: ext_stall, fb back-pressure, secondary-port reads
    // the RTL's buffers as the testbench knows them (logical: [0] buffer 1, [1] buffer 2) and which reference store is
    // its buffer 1
    uint32_t sh[2][1024];
    int rtlSel = 0;
    // the render's VRAM-race state
    const ttref::Render* R = nullptr;
    bool race = false;
    uint64_t ci = 0, rk = 0;            // the case's index in its list, the render (the VRAM model's variation)

    explicit Tb(p2tb::Fails& fl) : f(fl) {}

    // a check of this render: in a VRAM-race render a difference is counted apart
    bool ok(bool c, const char* fmt, ...) __attribute__((format(printf, 3, 4)))
    {
        if (c) {
            f.checks++;
            return true;
        }
        if (race) {
            st.raceDiffs++;
            return false;
        }
        va_list ap;
        va_start(ap, fmt);
        char b[1024];
        vsnprintf(b, sizeof b, fmt, ap);
        va_end(ap);
        f.ok(false, "%s: %s", where.c_str(), b);
        return false;
    }

    void vram_drive()
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
    }
    void edge()
    {
        bool rv[2], rwe[2];
        uint32_t ridx[2], rbe[2], rwd[2], rsrc[2];
        for (int h = 0; h < 2; h++) {
            rv[h] = (t->vh_req_v >> h) & 1;
            rwe[h] = (t->vh_req_we >> h) & 1;
            ridx[h] = t->vh_req_idx[h];
            rbe[h] = t->vh_req_be[h];
            rwd[h] = t->vh_req_wdata[h];
            rsrc[h] = t->vh_req_src[h];
            // a texture read of a word the render's write-out changed: a VRAM-race render
            if (R && rv[h] && ((t->vh_req_rdy >> h) & 1) && !rwe[h] && rsrc[h] == 4 &&
                ((R->wrote[ridx[h] >> 6] >> (ridx[h] & 63)) & 1))
                race = true;
        }
        t->clk = 1;
        t->eval();
        for (int h = 0; h < 2; h++)
            vm.edge(h, rv[h], rwe[h], ridx[h], rbe[h], rwd[h], rsrc[h]);
        vm.tick();
        cyc++;
    }
    void tick()
    {
        vram_drive();
        t->clk = 0;
        t->eval();
        edge();
    }
    void idle_inputs()
    {
        t->in_v = 0;
        t->er_v = 0;
        t->fb_rdy = 0;              // the feedback is taken (and checked) in the clock loop only
        t->ext_stall = 0;
        t->dbg_we = 0;
        t->pal_we = 0;
        t->ft_we = 0;
        t->ok_we = 0;
        t->flush = 0;
    }
    void reset()
    {
        idle_inputs();
        t->rst = 1;
        for (int i = 0; i < 4; i++) tick();
        t->rst = 0;
        tick();
    }

    // the registers and the register port's RAMs of a render
    void set_regs(const ttref::Regs& g)
    {
        t->param_base = g.param_base;
        t->fpu_shad_scale = g.fpu_shad_scale;
        t->fpu_perp_val = g.fpu_perp_val;
        t->half_offset = g.half_offset;
        t->text_control = g.text_control;
        t->pal_ram_ctrl = g.pal_ram_ctrl;
        t->fog_col_ram = g.fog_col_ram;
        t->fog_col_vert = g.fog_col_vert;
        t->fog_density = g.fog_density;
        t->fog_clamp_max = g.fog_clamp_max;
        t->fog_clamp_min = g.fog_clamp_min;
        t->pt_alpha_ref = g.pt_alpha_ref;
        t->fb_w_ctrl = g.fb_w_ctrl;
        t->fb_w_linestride = g.fb_w_linestride;
        t->fb_w_sof1 = g.fb_w_sof1;
        t->fb_w_sof2 = g.fb_w_sof2;
        t->fb_x_clip = g.fb_x_clip;
        t->fb_y_clip = g.fb_y_clip;
        t->fb_r_ctrl = g.fb_r_ctrl;
        t->scaler_ctl = g.scaler_ctl;
        t->y_coeff = g.y_coeff;
        idle_inputs();
        for (int i = 0; i < 1024; i++) {
            t->pal_we = 1;
            t->pal_widx = i;
            t->pal_wdata = g.palette[i];
            tick();
        }
        t->pal_we = 0;
        for (int i = 0; i < 128; i++) {
            t->ft_we = 1;
            t->ft_idx = i;
            t->ft_wdata = g.fog_table[i] & 0xffff;
            tick();
        }
        t->ft_we = 0;
        t->flush = 1;
        tick();
        t->flush = 0;
    }
    // the reference's buffers and offsKept into the RTL (a case's first render)
    void load_state(const ttref::Render& r)
    {
        idle_inputs();
        for (int b = 0; b < 2; b++)
            for (int i = 0; i < 1024; i++) {
                t->dbg_we = 1;
                t->dbg_b2 = b;
                t->dbg_idx = i;
                t->dbg_wdata = r.buf0[b][i];
                tick();
                sh[b][i] = r.buf0[b][i];
            }
        t->dbg_we = 0;
        t->ok_we = 1;
        t->ok_wdata = r.offsKept0;
        tick();
        t->ok_we = 0;
        rtlSel = r.sel0;
    }
    // the controller swapped the buffers (t_swap at the edge just taken): the shadow follows
    void mirror_swap()
    {
        for (int i = 0; i < 1024; i++)
            std::swap(sh[0][i], sh[1][i]);
        rtlSel ^= 1;
        st.swaps++;
    }
    // every word of both buffers through the debug port, against the shadow and the expected words
    void read_back(const uint32_t (*exp)[1024], const char* what)
    {
        int bad = 0, badSh = 0;
        for (int i = 0; i < 1024; i++) {
            t->dbg_idx = i;
            t->clk = 0;
            t->eval();
            const uint32_t w[2] = { t->dbg_b1, t->dbg_b2_data };
            for (int b = 0; b < 2; b++) {
                if (w[b] != sh[b][i] && badSh++ < 4)
                    ok(false, "%s: buffer %d word %d: the RAM has %08x, the write tap's shadow %08x", what, b + 1, i, w[b], sh[b][i]);
                if (w[b] != exp[b][i] && bad++ < 8)
                    ok(false, "%s: buffer %d word %d (x %d y %d): %08x, refsw3 %08x", what, b + 1, i, i & 31, i >> 5, w[b],
                       exp[b][i]);
            }
        }
        ok(bad == 0 && badSh == 0, "%s: %d words differ from refsw3's, %d from the shadow", what, bad, badSh);
    }

    void run_render(const ttref::Render& r, bool first)
    {
        R = &r;
        race = false;
        st.renders++;
        set_regs(r.regs);
        vm.init(const_cast<uint8_t*>(r.vramPre.data()));
        vm.reseed(ci, rk);
        vm.begin_render();
        if (first)
            load_state(r);
        else {
            // the state the RTL ended the last render with is refsw3's at this one's start (the captures chain)
            ok(rtlSel == r.sel0, "the buffers at the render's start: buffer 1 is store %d, refsw3's %d", rtlSel, r.sel0);
            int bad = 0;
            for (int b = 0; b < 2; b++)
                for (int i = 0; i < 1024; i++)
                    bad += sh[b][i] != r.buf0[b][i];
            ok(bad == 0, "the buffers at the render's start: %d words differ from refsw3's", bad);
            ok(t->offs_kept == r.offsKept0, "offsKept at the render's start %08x, refsw3 %08x", t->offs_kept, r.offsKept0);
        }

        // the items, entry by entry; the expectations
        std::vector<Item> items;
        std::vector<int> entFirst;              // the entry's first item
        std::vector<PassEnd> ends;
        std::deque<ExpFb> fbs;
        uint32_t lastTag = ~0u;
        for (size_t e = 0; e < r.ents.size(); e++) {
            const ttref::Entry& en = r.ents[e];
            entFirst.push_back((int)items.size());
            for (const ttref::Pass& p : en.passes) {
                if (p.runs.empty())
                    continue;
                st.passes++;
                if (p.rm == RM_TRP) st.presortPasses++;
                for (size_t k = 0; k < p.runs.size(); k++) {
                    const ttref::Run& rn = p.runs[k];
                    Item it;
                    it.tag = rn.tag;
                    it.y = rn.y;
                    it.x = rn.x;
                    it.len = rn.len;
                    it.rm = p.rm;
                    it.vmask = rn.vmask & (rn.len == 32 ? 0xFFFFFFFFu : ((1u << rn.len) - 1));
                    it.pmask = rn.pmask;
                    it.eop = k + 1 == p.runs.size();
                    it.nd = rn.tag != lastTag;
                    lastTag = rn.tag;
                    it.ent = (int)e;
                    items.push_back(it);
                }
                ends.push_back({ &p, (int)e });
                if (p.rm == RM_PT0 || p.rm == RM_PTN) {
                    bool any = false;
                    for (size_t i = p.pix0; i < p.pix0 + p.npix; i++) {
                        const ttref::Pix& x = r.pix[i];
                        fbs.push_back({ false, x.idx, !x.at, x.ro });
                        any |= !x.at && !x.ro;
                    }
                    fbs.push_back({ true, 0, any, false });
                }
            }
            // the entry's end: on its last item, or a null item after it (at random), with the entry's record
            const bool shaded = (int)items.size() > entFirst.back();
            if (shaded && rng.below(2))
                items.back().eoe = true;
            else {
                Item it;
                it.null_ = true;
                it.eoe = true;
                it.ent = (int)e;
                items.push_back(it);
                st.nulls++;
            }
            Item& ei = items.back();
            ei.tx = en.tx;
            ei.ty = en.ty;
            ei.zkeep = en.zkeep;
            ei.noWo = en.noWriteout;
            ei.last = e + 1 == r.ents.size();
            ei.shaded = shaded;
        }
        st.entries += (long)r.ents.size();
        st.items += (long)items.size();

        // the clock loop
        const uint32_t inGap = rng.below(3) == 0 ? 1 + (uint32_t)rng.below(12) : 0;
        size_t ii = 0, ei = 0, done = 0, px = 0, pe7 = 0, pe10 = 0;
        uint32_t inHold = 0;
        const uint64_t c0 = cyc;
        // a watchdog on progress (an item in, a point out, a write-out's VRAM write): the write-out of a scaled tile takes
        // up to ~60,000 clocks (factor 0x80: eight rows a line)
        const uint64_t limit = 2000000;
        uint64_t lastProg = cyc, lastWr = vm.writes;
        while (!broken) {
            if (ii == items.size() && done == items.size() && fbs.empty() && t->t_idle)
                break;
            if (vm.writes != lastWr) {
                lastWr = vm.writes;
                lastProg = cyc;
            }
            if (cyc - lastProg > limit) {
                ok(false, "no progress in %" PRIu64 " clocks (%zu of %zu items in, %zu out, %zu of %zu pixels, %zu feedback "
                   "messages left; stall %d tex %d fb %d, pinned %d, srq %d, pxq %d)", limit, ii, items.size(), done, px,
                   r.pix.size(), fbs.size(), t->t_stall, t->t_tex_stall, t->t_fb_block, t->t_pinned, t->t_srq,
                   t->t_pxq_runs);
                broken = true;
                break;
            }
            vram_drive();
            t->in_v = 0;
            if (inHold)
                inHold--;
            else if (ii < items.size()) {
                const Item& it = items[ii];
                t->in_v = 1;
                t->in_null = it.null_;
                t->in_tag = it.tag;
                t->in_y = it.y;
                t->in_x = it.x;
                t->in_lenm1 = it.len - 1;
                t->in_rm = it.rm;
                t->in_vmask = it.vmask;
                t->in_pmask = it.pmask;
                t->in_eop = it.eop;
                t->in_eoe = it.eoe;
                t->in_nd = it.nd;
                t->in_rec_tilex = it.tx;
                t->in_rec_tiley = it.ty;
                t->in_rec_z_keep = it.zkeep;
                t->in_rec_no_writeout = it.noWo;
                t->in_rec_last = it.last;
                t->in_rec_shaded_any = it.shaded;
            }
            t->er_v = ei < r.ents.size();
            if (t->er_v) {
                t->er_tilex = r.ents[ei].tx;
                t->er_tiley = r.ents[ei].ty;
            }
            t->fb_rdy = rng.below(1000) >= (uint64_t)fbPm;
            t->ext_stall = rng.below(1000) < (uint64_t)stallPm;
            t->clk = 0;
            t->eval();

            const bool inTake = t->in_v && t->in_rdy;
            const bool erTake = t->er_v && t->er_rdy;
            const bool p10Now = t->t_p10;
            // a pixel leaving P10, its write
            bool wr = false;
            int wb = 0, wi = 0;
            uint32_t wd = 0;
            if (t->wr_en) {
                wr = true;
                wb = t->wr_b2;
                wi = t->wr_idx;
                wd = t->wr_data;
            }
            bool p10end = false, p7end = false;
            const ttref::Pass* p10p = nullptr;
            if (t->t_p10) {
                if (t->t_p10_last) done++;
                if (!t->t_p10_null) {
                    if (px >= r.pix.size()) {
                        ok(false, "a pixel (index %d) after refsw3's last", t->t_p10_idx);
                        broken = true;
                    } else {
                        const ttref::Pix& x = r.pix[px++];
                        st.pixels++;
                        ok(t->t_p10_idx == x.idx && t->t_p10_ro == x.ro, "pixel %zu: index %d ro %d, refsw3 index %d ro %d",
                           px - 1, t->t_p10_idx, t->t_p10_ro, x.idx, x.ro);
                        ok(t->t_at == x.at, "pixel %zu (index %d, TSP %08x): the alpha test %d, refsw3 %d", px - 1, x.idx,
                           x.tsp, t->t_at, x.at);
                        if (x.wr)
                            ok(wr && wi == x.idx && wb == (int)x.wb2 && wd == x.w,
                               "pixel %zu (index %d x %d y %d, TSP %08x): the write %s buffer %d %08x, refsw3 buffer %d %08x",
                               px - 1, x.idx, x.idx & 31, x.idx >> 5, x.tsp, wr ? "to" : "(none)", wb + 1, wd, x.wb2 + 1, x.w);
                        else
                            ok(!wr, "pixel %zu (index %d): a write (buffer %d %08x) where refsw3 writes nothing (ro %d, TSP %08x)",
                               px - 1, x.idx, wb + 1, wd, x.ro, x.tsp);
                    }
                }
                if (t->t_p10_eop) {
                    if (pe10 >= ends.size()) {
                        ok(false, "an eop leaving P10 after the last pass");
                        broken = true;
                    } else {
                        p10p = ends[pe10++].p;
                        p10end = true;
                        ok(t->t_stuck == p10p->stuck, "pass %zu (rm %d): tspAlphaStuck %d after it, refsw3 %d", pe10 - 1,
                           p10p->rm, t->t_stuck, p10p->stuck);
                    }
                }
            } else
                ok(!wr, "a write without a pixel leaving P10");
            const ttref::Pass* p7p = nullptr;
            if (t->t_p7 && t->t_p7_eop && !t->t_p7_null) {
                if (pe7 >= ends.size()) {
                    ok(false, "an eop leaving P7 after the last pass");
                    broken = true;
                } else {
                    p7p = ends[pe7++].p;
                    p7end = true;
                }
            }
            // the feedback
            if (t->fb_v && t->fb_rdy) {
                st.fbMsgs++;
                if (fbs.empty()) {
                    ok(false, "a feedback message (kind %d idx %d) after the last expected", t->fb_kind, t->fb_idx);
                    broken = true;
                } else {
                    const ExpFb m = fbs.front();
                    fbs.pop_front();
                    if (m.done)
                        ok(t->fb_kind == 1 && t->fb_fail == m.fail, "feedback message %ld: kind %d fail %d, refsw3 PASS_DONE anyfail %d",
                           st.fbMsgs - 1, t->fb_kind, t->fb_fail, m.fail);
                    else
                        ok(t->fb_kind == 0 && t->fb_idx == m.idx && t->fb_fail == m.fail && t->fb_ro == m.ro,
                           "feedback message %ld: kind %d idx %d fail %d ro %d, refsw3 PIXEL idx %d fail %d ro %d", st.fbMsgs - 1, t->fb_kind, t->fb_idx,
                           t->fb_fail, t->fb_ro, m.idx, m.fail, m.ro);
                }
            }
            // the secondary port's read for the write-out: buffer 2's word before this clock's write
            const bool woNow = t->wo_re && t->wo_gnt;
            const uint32_t woE = woNow ? sh[1][t->wo_idx] : 0;
            const int woI = t->wo_idx;
            const bool swapNow = t->t_swap;
            ok(!swapNow || !t->t_p10, "the buffers swapped with a point leaving P10");
            if (t->t_tex_stall) st.texStall++;
            if (t->t_fb_block) st.fbBlock++;
            if (t->ext_stall) st.extStall++;
            if (t->t_miss) st.misses++;
            if (t->t_fill) st.fillClk++;
            if (t->t_drain) st.drain++;
            if (t->t_p0) st.p0++;
            edge();
            if (woNow) {
                ok(t->wo_data == woE, "the write-out's read of buffer 2 word %d: %08x, %08x expected", woI, t->wo_data, woE);
                st.woReads++;
            }
            if (wr) {
                sh[wb][wi] = wd;
                st.writes++;
            }
            if (swapNow)
                mirror_swap();
            if (p10end && p10p)
                ok(ttref::hash_buffers(sh[0], sh[1]) == p10p->hash,
                   "pass %zu (rm %d, %zu runs): the tile buffers after it differ from refsw3's", pe10 - 1, p10p->rm,
                   p10p->runs.size());
            if (p7end && p7p)
                ok(t->offs_kept == p7p->offsKept, "pass %zu (rm %d): offsKept %08x after it, refsw3 %08x", pe7 - 1, p7p->rm,
                   t->offs_kept, p7p->offsKept);
            if (inTake || p10Now)
                lastProg = cyc;
            if (inTake) {
                ii++;
                if (inGap && rng.below(4) == 0) inHold = (uint32_t)rng.below(inGap);
            }
            if (erTake) ei++;
        }
        idle_inputs();
        for (int k = 0; k < 8; k++) tick();
        // the write-out's last writes still on their way to video memory
        for (int quiet = 0; quiet < 16 && !broken;) {
            tick();
            quiet = (vm.busy() || t->vh_req_v) ? 0 : quiet + 1;
        }
        if (broken)
            return;
        ok(px == r.pix.size(), "%zu pixels left P10, refsw3 shaded %zu", px, r.pix.size());
        ok(pe10 == ends.size() && pe7 == ends.size(), "%zu / %zu pass ends at P10 / P7, %zu passes", pe10, pe7, ends.size());
        ok(t->t_pinned == 0 && t->t_srq == 0 && t->t_pxq_runs == 0, "at the end %d entries pinned, SRQ %d, pixel queue %d",
           t->t_pinned, t->t_srq, t->t_pxq_runs);
        // the render's end: the buffers as the controller left them, then every word; video memory after the write-out
        ok(rtlSel == r.selEnd, "the render's end: buffer 1 is store %d, refsw3's %d", rtlSel, r.selEnd);
        read_back(r.bufEnd, "the render's end");
        {
            const uint32_t* a = (const uint32_t*)r.vramPre.data();      // the VRAM model's memory: the RTL's writes
            const uint32_t* b = (const uint32_t*)r.vramPost.data();
            long bad = 0;
            int64_t first = -1;
            for (uint32_t w = 0; w < (8u << 20) / 4; w++)
                if (a[w] != b[w]) {
                    if (first < 0) first = w;
                    bad++;
                }
            st.vramWords += (8u << 20) / 4;
            ok(bad == 0, "video memory after the render: %ld 32-bit words differ from refsw3-offline's, the first at physical "
               "byte %06llx (%08x, refsw3 %08x)", bad, (long long)(first < 0 ? 0 : 4 * first), first < 0 ? 0 : a[first],
               first < 0 ? 0 : b[first]);
        }
        ok(t->offs_kept == r.offsKeptEnd, "offsKept at the render's end %08x, refsw3 %08x", t->offs_kept, r.offsKeptEnd);
        st.clk += cyc - c0;
        if (race) st.raceRenders++;
        R = nullptr;
    }
};

}   // namespace

int main(int argc, char** argv)
{
    p2tb::raise_stack();
    Verilated::commandArgs(argc, argv);
    p2tb::Args a;
    if (!a.parse(argc, argv)) {
        fprintf(stderr, "tsp_tile: %s\n", a.error.c_str());
        return 2;
    }
    uint64_t vary = 0;
    long maxFails = 0;
    long rFirst = 0, rLast = -1;
    int stallPm = -1, fbPm = -1;
    std::vector<std::string> cases;
    for (size_t i = 0; i < a.rest.size(); i++) {
        const std::string& s = a.rest[i];
        if (s == "--vramvary" && i + 1 < a.rest.size())
            vary = strtoull(a.rest[++i].c_str(), nullptr, 0);
        else if (s == "--max-fails" && i + 1 < a.rest.size())
            maxFails = atol(a.rest[++i].c_str());
        else if (s == "--stall" && i + 1 < a.rest.size())
            stallPm = atoi(a.rest[++i].c_str());
        else if (s == "--fbstall" && i + 1 < a.rest.size())
            fbPm = atoi(a.rest[++i].c_str());
        else if (s == "--renders" && i + 1 < a.rest.size()) {
            const std::string v = a.rest[++i];
            char* end = nullptr;
            rFirst = strtol(v.c_str(), &end, 10);
            rLast = *end == '-' ? strtol(end + 1, &end, 10) : rFirst;
            if (*end || rFirst < 0 || rLast < rFirst) {
                fprintf(stderr, "tsp_tile: --renders A or A-B (0 <= A <= B): %s\n", v.c_str());
                return 2;
            }
        } else if (s[0] == '@') {
            FILE* lf = fopen(s.c_str() + 1, "r");
            if (!lf) {
                fprintf(stderr, "tsp_tile: cannot read %s\n", s.c_str() + 1);
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
        } else if (s.rfind("+vramvary=", 0) == 0)
            vary = strtoull(s.c_str() + 10, nullptr, 0);
        else if (s[0] != '+')
            cases.push_back(s);
    }
    p2tb::banner("tsp_tile", a);
    printf("tsp_tile: vramvary %llu\n", (unsigned long long)vary);
    p2tb::Fails f("tsp_tile");
    f.set("tile");

    Vp2_tsp_tile_tb_top* top = new Vp2_tsp_tile_tb_top;
    Tb tb(f);
    tb.t = top;
    tb.vm.varySeed = vary;
    static ttref::Render R;
    Stats tot;
    long nCases = 0, skipped = 0;
    for (size_t ci = 0; ci < cases.size(); ci++) {
        if (!a.mine(ci))
            continue;
        if (maxFails && f.n >= maxFails)
            break;
        const std::string& c = cases[ci];
        nCases++;
        const uint64_t caseSeed = a.seed * 1000003ull + ci;
        tb.rng = p2tb::Rng(caseSeed);
        tb.stallPm = stallPm >= 0 ? stallPm : (tb.rng.below(3) ? (int)tb.rng.below(60) : 0);
        tb.fbPm = fbPm >= 0 ? fbPm : (int)tb.rng.below(600);
        ttref::reset_core();
        tb.reset();
        tb.st = Stats();
        tb.broken = false;
        const long f0 = f.n;
        bool first = true;
        for (int k = 0;; k++) {
            const std::string r = c + "/r" + std::to_string(k);
            if (!IsDir(r))
                break;
            if (rLast >= 0 && k > rLast)
                break;
            const bool refOnly = k < rFirst;
            if (IsFile(r + "/skipped")) {
                if (!refOnly) skipped++;
                continue;
            }
            if (!f.ok(ttref::load_state(r.c_str()), "%s: cannot load the capture", r.c_str()))
                break;
            ttref::render(R, 1024);
            if (!f.ok(R.ended, "%s: the reference's render did not end", r.c_str()))
                break;
            if (refOnly)
                continue;
            // the generators of the render (seeded from the case and the render: where a case is cut into items does not
            // change a render's stimulus)
            tb.rng = p2tb::Rng(caseSeed * 0x100000001B3ull + (uint64_t)k);
            tb.ci = ci;
            tb.rk = (uint64_t)k;
            tb.where = r;
            tb.run_render(R, first);
            first = false;
            if (tb.broken)
                break;
        }
        const Stats& s = tb.st;
        printf("tsp_tile: case %s: %ld renders (%ld VRAM-race, %ld differences there), %ld entries, %ld passes (%ld pre-sorted), "
               "%ld items (%ld null), %ld pixels, %ld writes, %ld feedback messages, %ld swaps, %ld write-out reads; %" PRIu64
               " clk (%.3f a pixel), texture stall %" PRIu64 ", misses %" PRIu64 ", fill %" PRIu64 ", feedback block %" PRIu64
               ", held %" PRIu64 ", pass drain %" PRIu64 ": %s\n",
               c.c_str(), s.renders, s.raceRenders, s.raceDiffs, s.entries, s.passes, s.presortPasses, s.items, s.nulls,
               s.pixels, s.writes, s.fbMsgs, s.swaps, s.woReads, s.clk, s.pixels ? (double)s.clk / (double)s.pixels : 0.0,
               s.texStall, s.misses, s.fillClk, s.fbBlock, s.extStall, s.drain, f.n == f0 ? "ok" : "FAIL");
        tot.renders += s.renders; tot.raceRenders += s.raceRenders; tot.raceDiffs += s.raceDiffs; tot.entries += s.entries;
        tot.passes += s.passes; tot.presortPasses += s.presortPasses; tot.items += s.items; tot.nulls += s.nulls;
        tot.pixels += s.pixels; tot.writes += s.writes; tot.fbMsgs += s.fbMsgs; tot.swaps += s.swaps; tot.woReads += s.woReads;
        tot.clk += s.clk; tot.texStall += s.texStall; tot.misses += s.misses; tot.fillClk += s.fillClk;
        tot.fbBlock += s.fbBlock; tot.extStall += s.extStall; tot.drain += s.drain;
        fflush(stdout);
    }
    printf("tsp_tile: totals: %ld cases, %ld renders (%ld skipped; %ld VRAM-race, %ld differences there), %ld entries, %ld passes "
           "(%ld pre-sorted), %ld items (%ld null), %ld pixels, %ld writes, %ld feedback messages, %ld swaps, %ld write-out reads; "
           "%" PRIu64 " clk (%.3f a pixel), texture stall %" PRIu64 ", misses %" PRIu64 ", fill %" PRIu64 ", feedback block %"
           PRIu64 ", held %" PRIu64 ", pass drain %" PRIu64 "\n",
           nCases, tot.renders, skipped, tot.raceRenders, tot.raceDiffs, tot.entries, tot.passes, tot.presortPasses, tot.items,
           tot.nulls, tot.pixels, tot.writes, tot.fbMsgs, tot.swaps, tot.woReads, tot.clk,
           tot.pixels ? (double)tot.clk / (double)tot.pixels : 0.0, tot.texStall, tot.misses, tot.fillClk, tot.fbBlock,
           tot.extStall, tot.drain);
    top->final();
    delete top;
    return f.finish();
}

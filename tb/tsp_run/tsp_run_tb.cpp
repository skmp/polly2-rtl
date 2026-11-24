// tsp_run_tb.cpp: the TSP run-start and pixel-value testbench (PLAN M10; make tsp-run, tsp-run-mutants, tsp-run-full).
//
//   tb [--only random,super,console] [--n N] [--seed S] [--shard k/N] [--batch B] [--max-fails N] [--vramvary S]
//      [--dcts <dreamcast-tests>] [--set <family>[/<set>]] [--stride D] [--stall PM] [--gap PM]
//
// The DUT (p2_tsp_run_tb_top.sv): p2_tsp_store, p2_tsp_pfetch, p2_tsp_setup on p2_tsp_alu, p2_mem with the VRAM model
// (tb/common/vram_model.h), p2_tsp_rstart, p2_pxq and the pixel pipe's P0-P3 (p2_pp_issue, p2_pp_plane, p2_pp_div,
// p2_pp_col, p2_pp_mip). The testbench is the sorter and the entries' queue on one side (it pushes run items with random
// gaps, and an entry record, the tile, for each entry) and the pixel pipe's later stages on the other: it takes P3's
// points with random back-pressure (the pipe's global stall: no value may change) and compares every point.
//
// The reference (tsp_run_ref.cpp): refsw3's own GetFpuEntry for the tile, PlaneStepper3::Val (PlaneT::Value) with
// SpanStart = the run's first column and the SupSample statics as PixelFlush_tsp sets them, PlaneStepper3::Quot
// (Divide), InterpolateBase / InterpolateOffs, MipSelect (L1) and the verbatim copy of mipChoose. Compared per point, as
// tuples (neg, mant, exp when mant != 0): W and every live attribute value (the colours always; U, V when textured; the
// offset colours when Texture && Offset && not a bump map: the planes the entry sets up), every live quotient and the mip
// w = Divide(1.0, W), the base colour (always) and the offset colour (when live), MipSelect's level and k (Texture &&
// TCW MipMapped) and mipChoose's level and k (always); and the point's place, volume, flags and order (the run's pixels
// in order, four points a SupSample pixel, null items, eop / eoe on an item's last point).
//
// Sections (PLAN M10's gate), each a list of batches (one register set, the batch the work item: --shard over batches):
//   random   N random pixels (2M quick): tsp_cases.h's random primitives (every input class, flat and Gouraud, two
//            volumes, intensity, DCalcCtrl, mipmaps, SupSample at random), runs of 1-32 pixels on random tiles (near the
//            triangle, and anywhere to tile 63, 63), random vmask (mixed volumes), pmask, rm, HALF_OFFSET, null items
//   super    SupSample points (supsample-style, num H7b's classes): the same primitives with TSP bit 12 set in both
//            volumes, steep and far planes; the half-line classes counted (tsp_run_ref h7b)
//   console  dreamcast-tests' archived sets (tsp_sets.h): every uvmeas (36), uvspan (4), uvrun (1), wmeas (4), cmeas (3)
//            and mipmeas (10) set; each reading at its pixel of its run (the triangle's first covered pixel on the line in
//            the tile, cut at the bands), turned into the console's number by the reading's decoder and compared with
//            the console's: equal wherever refsw3's is (PLAN 0 rule 4: where refsw3 differs the RTL must equal refsw3,
//            which the per-point comparison checks). --stride D: every D-th run of a set (the quick gate's uvmeas,
//            mipmeas); --set family[/set]: those sets only.
#include <algorithm>
#include <cinttypes>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include <vector>

#include "Vp2_tsp_run_tb_top.h"
#include "verilated.h"

#include "p2tb.h"
#include "tsp_cases.h"
#include "tsp_run_ref.h"
#include "tsp_sets.h"
#include "vram_model.h"

using p2tspcase::Case;

namespace {

static int Sx10(uint32_t e) { return (int16_t)(uint16_t)(e << 6) >> 6; }

// a run item as the sorter gives it; for the console sets, its readings
struct Item {
    bool null_ = false;
    uint32_t tag = 0, vmask = 0, pmask = 0;
    int ci = -1, x = 0, y = 0, len = 1, rm = 0;
    bool eop = false, eoe = false, nd = false;
    int ent = 0;                                  // its entry (tile)
    const std::vector<std::pair<int, int>>* rd = nullptr;   // console: (pixel n, reading index)
};
struct Ent { int tx = 0, ty = 0; };

struct Job {
    std::vector<Case> cs;
    std::vector<Ent> ents;
    std::vector<Item> items;
    uint32_t shad = 1, perp = 0, half = 7;
    const p2tspset::Set* set = nullptr;           // console: the readings' set
    bool wmeas = false;
    const char* pitch = nullptr;                  // pitch: the clocks between the runs' points, reported under this name
};

struct Stats {
    long jobs = 0, items = 0, nulls = 0, pixels = 0, points = 0, superPts = 0, mixedRuns = 0, mipPts = 0, ofsPts = 0;
    long valChecks = 0;
    uint64_t clk = 0, rsBusy = 0, rsReload = 0, rsMul = 0, drain = 0, p0 = 0, stallClk = 0, setupBusy = 0;
    long pxqRunsMax = 0, pxqPixMax = 0, pinnedMax = 0, srqMax = 0;
    long h7b[4] = {};                              // SupSample's half lines (num H7b): a carry, the window, the truncation, C' < 0
    long h7bPlanes = 0, h7bNegCarry = 0;
};
struct SetScore { long readings = 0, rtl = 0, ref = 0, known = 0, skipped = 0; };

struct Tb {
    Vp2_tsp_run_tb_top* t = nullptr;
    p2tb::Fails& f;
    p2tb::VramModel vm;
    Stats st;
    uint64_t cyc = 0;
    uint64_t vramVary = 0;
    int stallPm = 200, gapPm = 200;
    bool broken = false;
    std::map<std::string, SetScore> scores;

    explicit Tb(p2tb::Fails& fl) : f(fl) {}

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
    void reset()
    {
        t->rst = 1;
        t->flush = 0;
        t->in_v = 0;
        t->er_v = 0;
        t->o_rdy = 0;
        for (int i = 0; i < 4; i++) tick();
        t->rst = 0;
        tick();
    }

    // ---- the expected points, item by item
    struct Exp {
        size_t item = 0;
        int n = 0, pt = 0;
        bool have = false;        // the pixel's reference is in `ref`
        trref::Pt ref;
        int vsel = 0;
    };

    static bool SameT(const trref::T& r, bool neg, int exp, uint64_t mant)
    {
        return r.neg == neg && !r.bad && r.mant == mant && (mant == 0 || r.exp == exp);
    }

    void run(Job& jb, uint64_t seed, const char* sect)
    {
        p2tb::Rng r(seed);
        st.jobs++;
        const bool intensity = (jb.shad >> 8) & 1;
        const uint32_t pbase = ((uint32_t)r.below(6) << 20) | (r.below(3) == 0 ? (uint32_t)r.below(0x8000) * 4u : 0u);
        // the blocks
        std::vector<uint32_t> tags(jb.cs.size());
        uint32_t offs = (uint32_t)r.below(64);
        for (size_t i = 0; i < jb.cs.size(); i++) {
            const Case& c = jb.cs[i];
            const bool two = c.p.shadow && !intensity;
            const std::vector<uint32_t> w = c.p.Words(two);
            for (size_t k = 0; k < w.size(); k++)
                trref::set_vram32((pbase + (offs + (uint32_t)k) * 4u) & 0x7FFFFCu, w[k]);
            tags[i] = (r.below(4) == 0 ? (1u << 28) : 0u) | ((uint32_t)c.p.shadow << 27) | ((uint32_t)(c.p.skip & 7) << 24) |
                      ((offs & 0x1FFFFF) << 3) | (uint32_t)(c.p.tagOffset & 7);
            offs += (uint32_t)w.size() + (uint32_t)r.below(4);
        }
        for (Item& it : jb.items)
            if (!it.null_) it.tag = tags[it.ci];
        trref::set_regs(pbase, jb.shad, jb.perp, jb.half);
        if (jb.wmeas) trref::wmeas_regs();
        t->param_base = pbase;
        t->fpu_shad_scale = jb.shad;
        t->fpu_perp_val = jb.perp;
        t->half = (jb.half >> 1) & 1;
        vm.init(trref::vram());
        if (vramVary) vm.reseed(vramVary, seed);
        t->flush = 1;
        tick();
        t->flush = 0;

        const uint32_t inGap = r.below(3) == 0 ? 1 + (uint32_t)r.below(30) : 0;
        const uint32_t outStall = (stallPm && r.below(3)) ? 1 + (uint32_t)r.below(20) : 0;
        size_t ii = 0, ei = 0;
        uint32_t inHold = 0, outHold = 0;
        Exp ex;
        const uint64_t c0 = cyc, limit = 200000 + 400ull * jb.items.size() + 20ull * 32 * 4 * jb.items.size();
        long pts = 0;
        uint64_t tFirst = 0, tLast = 0;
        bool done = false;
        while (!broken && !done) {
            if (cyc - c0 > limit) {
                f.ok(false, "%s: job %" PRIu64 ": no progress in %" PRIu64 " clocks (%zu of %zu items in, expecting item %zu; setup idle %d, "
                     "fetch idle %d, rstart busy %d, pxq runs %d, srq %d, pinned %d)", sect, seed, limit, ii, jb.items.size(), ex.item,
                     t->t_setup_idle, t->t_fetch_idle, t->t_rs_busy, t->t_pxq_runs, t->t_srq, t->t_pinned);
                broken = true;
                break;
            }
            vram_drive();
            // the items
            t->in_v = 0;
            if (inHold) inHold--;
            else if (ii < jb.items.size()) {
                const Item& it = jb.items[ii];
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
            }
            // the entries' records, in order
            t->er_v = ei < jb.ents.size();
            if (t->er_v) { t->er_tilex = jb.ents[ei].tx; t->er_tiley = jb.ents[ei].ty; }
            // P3's points, with back-pressure
            if (outHold) { outHold--; t->o_rdy = 0; }
            else t->o_rdy = 1;
            t->clk = 0;
            t->eval();
            const bool inTake = t->in_v && t->in_rdy;
            const bool erTake = t->er_v && t->er_rdy;
            if (t->o_take) {
                check_point(jb, ex, sect, seed);
                if (!pts) tFirst = cyc;
                tLast = cyc;
                pts++;
                if (outStall && r.below(1000) < (uint64_t)stallPm) outHold = (uint32_t)r.below(outStall);
                if (ex.item >= jb.items.size()) done = true;
            }
            if (t->o_v && !t->o_rdy) st.stallClk++;
            if (t->t_rs_busy) st.rsBusy++;
            if (t->t_rs_reload) st.rsReload++;
            if (t->t_rs_mul) st.rsMul++;
            if (t->t_drain) st.drain++;
            if (t->t_p0) st.p0++;
            if (!t->t_setup_idle) st.setupBusy++;
            st.pxqRunsMax = std::max<long>(st.pxqRunsMax, t->t_pxq_runs);
            st.pxqPixMax = std::max<long>(st.pxqPixMax, t->t_pxq_pix);
            st.pinnedMax = std::max<long>(st.pinnedMax, t->t_pinned);
            st.srqMax = std::max<long>(st.srqMax, t->t_srq);
            edge();
            if (inTake) {
                ii++;
                if (gapPm && inGap && r.below(1000) < (uint64_t)gapPm) inHold = (uint32_t)r.below(inGap);
            }
            if (erTake) ei++;
            if (broken) break;
        }
        // nothing may be offered into the next job's flush
        t->in_v = 0;
        t->er_v = 0;
        t->o_rdy = 0;
        // the pipe empties and every pin goes: since M11 the last points still go through P4 - P10 (the pins go at P10,
        // a texture miss can hold them there), then a few clocks more; then the pins must be 0
        for (int k = 0; k < 100000 && t->t_pinned != 0; k++) tick();
        for (int k = 0; k < 16; k++) tick();
        if (!broken)
            f.ok(t->t_pinned == 0 && t->t_srq == 0 && t->t_pxq_runs == 0, "%s: job %" PRIu64 ": at the end %d entries pinned, SRQ %d, "
                 "pixel queue %d runs", sect, seed, t->t_pinned, t->t_srq, t->t_pxq_runs);
        st.clk += cyc - c0;
        st.items += (long)jb.items.size();
        if (jb.pitch && pts > 1)
            printf("tsp_run: pitch %s: %.2f clk a run (%ld runs, the output never held, no gaps)\n", jb.pitch,
                   (double)(tLast - tFirst) / (double)(pts - 1), pts);
    }

    void check_point(Job& jb, Exp& ex, const char* sect, uint64_t seed)
    {
        if (ex.item >= jb.items.size()) {
            f.ok(false, "%s: job %" PRIu64 ": a point after the last item", sect, seed);
            broken = true;
            return;
        }
        const Item& it = jb.items[ex.item];
        const Case* cp = it.null_ ? nullptr : &jb.cs[it.ci];
        char where[200];
        snprintf(where, sizeof where, "%s job %" PRIu64 " item %zu%s%s (tag %08x tile %d,%d y %d x %d len %d rm %d) pixel %d point %d", sect,
                 seed, ex.item, cp && !cp->set.empty() ? " " : "", cp ? cp->set.c_str() : "", it.tag, jb.ents[it.ent].tx,
                 jb.ents[it.ent].ty, it.y, it.x, it.len, it.rm, ex.n, ex.pt);
        if (it.null_) {
            st.nulls++;
            f.ok(t->o_null && t->o_last && (bool)t->o_eop == it.eop && (bool)t->o_eoe == it.eoe, "%s: a null item's point: null %d last %d "
                 "eop %d eoe %d, expected null, eop %d eoe %d", where, t->o_null, t->o_last, t->o_eop, t->o_eoe, it.eop, it.eoe);
            ex.item++;
            ex.n = ex.pt = 0;
            ex.have = false;
            return;
        }
        // the pixel's volume (RenderParamTags: volHit && t.shadow; PT passes InVolume false)
        const bool pt = it.rm == 1 || it.rm == 2;
        const bool shadow = (it.tag >> 27) & 1;
        const int vsel = (shadow && !pt && ((it.vmask >> ex.n) & 1)) ? 1 : 0;
        const Ent& en = jb.ents[it.ent];
        trref::Pt& R = ex.ref;
        ex.vsel = vsel;
        {
            trref::Pt tmp;
            trref::point(it.tag, vsel, 32 * en.tx, 32 * en.ty, it.x, it.y, ex.n, ex.pt & 1, ex.pt >> 1, &tmp);
            R = tmp;
        }
        const bool sup = R.super;
        const bool pxlast = !sup || ex.pt == 3;
        const bool last = pxlast && ex.n == it.len - 1;
        const bool ro = pt && ((it.pmask >> ex.n) & 1);
        const bool atest = pt || (it.rm == 3 && ((it.pmask >> ex.n) & 1));
        bool ok = !t->o_null && (bool)t->o_last == last && (bool)t->o_eop == (last && it.eop) && (bool)t->o_eoe == (last && it.eoe) &&
                  t->o_tag == it.tag && (int)t->o_x == it.x + ex.n && (int)t->o_y == it.y && (int)t->o_n == ex.n &&
                  (int)t->o_vsel == vsel && (bool)t->o_ro == ro && (bool)t->o_atest == atest && (bool)t->o_super == sup &&
                  (int)t->o_hx == (sup ? (ex.pt & 1) : 0) && (int)t->o_hy == (sup ? (ex.pt >> 1) : 0) &&
                  (int)t->o_tilex == en.tx && (int)t->o_tiley == en.ty;
        if (!f.ok(ok, "%s: the point {null %d last %d eop %d eoe %d tag %08x x %d y %d n %d vsel %d ro %d atest %d super %d hx %d hy %d "
                  "tile %d,%d} is not the expected {last %d eop %d eoe %d vsel %d ro %d atest %d super %d}", where, t->o_null, t->o_last,
                  t->o_eop, t->o_eoe, t->o_tag, t->o_x, t->o_y, t->o_n, t->o_vsel, t->o_ro, t->o_atest, t->o_super, t->o_hx, t->o_hy,
                  t->o_tilex, t->o_tiley, last, last && it.eop, last && it.eoe, vsel, ro, atest, sup)) {
            broken = true;
            return;
        }
        st.points++;
        if (pxlast) st.pixels++;
        // SupSample: num H7b's classes of the run's half lines (coverage, at the run's first point)
        if (sup && ex.n == 0 && ex.pt == 0)
            for (int p = 0; p < 11; p++) {
                const bool live = p == 0 || (p >= 3 && p <= 6) || ((p == 1 || p == 2) && R.tex) || (p >= 7 && R.ofs);
                if (!live) continue;
                const int m = trref::h7b(it.tag, vsel, 32 * en.tx, 32 * en.ty, p);
                st.h7bPlanes++;
                for (int b = 0; b < 4; b++) if ((m >> b) & 1) st.h7b[b]++;
                if ((m & 9) == 9) st.h7bNegCarry++;
            }
        if (sup) st.superPts++;
        if (R.mip) st.mipPts++;
        if (R.ofs) st.ofsPts++;
        static const char* const pn[11] = {"W", "U", "V", "colB", "colG", "colR", "colA", "ofsB", "ofsG", "ofsR", "ofsA"};
        for (int p = 0; p < 11; p++) {
            const bool live = p == 0 || (p >= 3 && p <= 6) || ((p == 1 || p == 2) && R.tex) || (p >= 7 && R.ofs);
            if (!live) continue;
            st.valChecks++;
            const bool vn = (t->o_vneg >> p) & 1;
            if (!f.ok(SameT(R.val[p], vn, Sx10(t->o_vexp[p]), t->o_vmant[p]), "%s: value %s {%d %d %05x}, refsw3 {%d %d %" PRIx64 "}", where,
                 pn[p], vn, Sx10(t->o_vexp[p]), t->o_vmant[p], R.val[p].neg, R.val[p].exp, R.val[p].mant) && getenv("P2_TERMS")) {
                char b[400];
                trref::terms(it.tag, vsel, 32 * en.tx, 32 * en.ty, it.x, it.y, p, b, sizeof b);
                printf("    refsw3's terms: %s\n", b);
            }
            const int qp = p == 0 ? 0 : p;     // q[0]: the mip w = Divide(1.0, W)
            const bool qn = (t->o_qneg >> qp) & 1;
            f.ok(SameT(R.q[qp], qn, Sx10(t->o_qexp[qp]), t->o_qmant[qp]), "%s: quotient %s {%d %d %05x}, refsw3 {%d %d %" PRIx64 "}",
                 where, p == 0 ? "1/W" : pn[p], qn, Sx10(t->o_qexp[qp]), t->o_qmant[qp], R.q[qp].neg, R.q[qp].exp, R.q[qp].mant);
        }
        f.ok(t->o_base == R.base, "%s: base colour %08x, refsw3 %08x", where, t->o_base, R.base);
        if (R.ofs) f.ok(t->o_offs == R.offs, "%s: offset colour %08x, refsw3 %08x", where, t->o_offs, R.offs);
        if (R.mip) {
            const int rl = (int32_t)(t->o_rl << 14) >> 14;
            f.ok(rl == R.rl && (int)t->o_rk == R.rk, "%s: MipSelect level %d k %d, refsw3 %d %d", where, rl, t->o_rk, R.rl, R.rk);
        }
        // mipChoose: PixelFlush_tsp calls it for a textured volume only (pp_Texture)
        if (R.tex)
            f.ok((int)t->o_level == R.level && (int)t->o_k == R.k, "%s: mipChoose level %d k %d, refsw3 %d %d", where, t->o_level,
                 t->o_k, R.level, R.k);
        // the console's readings at this pixel (its last point: the pixel as the framebuffer has it)
        if (it.rd && jb.set) {
            for (const auto& q : *it.rd) {
                if (q.first != ex.n) continue;
                SetScore& sc = scores[jb.set->family + " " + jb.set->name];
                const int32_t want = jb.set->want[q.second];
                int32_t rtl = -1, ref = -1;
                switch (jb.set->kind) {
                case p2tspset::K_UV:
                    rtl = p2tspset::ReadingUV(p2tspset::ToDouble((t->o_qneg >> 1) & 1, Sx10(t->o_qexp[1]), t->o_qmant[1]));
                    ref = p2tspset::ReadingUV(p2tspset::ToDouble(R.q[1].neg, R.q[1].exp, R.q[1].mant));
                    break;
                case p2tspset::K_W: {
                    trref::T w;
                    w.neg = t->o_vneg & 1; w.exp = Sx10(t->o_vexp[0]); w.mant = t->o_vmant[0];
                    rtl = trref::wmeas_green(w);
                    ref = trref::wmeas_green(R.val[0]);
                    break;
                }
                case p2tspset::K_C:
                    rtl = p2tspset::ReadingC((t->o_base >> 16) & 255, (t->o_base >> 8) & 255, t->o_base & 255);
                    ref = p2tspset::ReadingC((R.base >> 16) & 255, (R.base >> 8) & 255, R.base & 255);
                    break;
                case p2tspset::K_MIP: {
                    const int mode = (t->o_tsp >> 13) & 3;
                    rtl = p2tspset::ReadingMip(t->o_level, t->o_k, mode);
                    ref = p2tspset::ReadingMip(R.level, R.k, mode);
                    break;
                }
                }
                sc.readings++;
                sc.rtl += rtl == want;
                sc.ref += ref == want;
                if (ref != want) sc.known++;
                // refsw3-known (PLAN 0 rule 4): where refsw3 is the console's, the RTL must be
                if (ref == want)
                    f.ok(rtl == want, "%s: reading %d: the RTL's %06x, the console's (and refsw3's) %06x", where, q.second, rtl, want);
            }
        }
        // the next point
        if (pxlast) {
            ex.pt = 0;
            ex.n++;
            if (ex.n == it.len) { ex.item++; ex.n = 0; }
        } else {
            ex.pt++;
        }
        (void)sect;
    }
};

// ---- the random runs of a batch of primitives: entries (tiles), passes, null items
void RandomItems(p2tb::Rng& r, Job& jb, long* pixels, bool forceSuper)
{
    const size_t nc = jb.cs.size();
    if (forceSuper)
        for (Case& c : jb.cs) { c.p.tsp[0] |= 1u << 12; c.p.tsp[1] |= 1u << 12; }
    const int nEnt = 1 + (int)r.below(4);
    for (int e = 0; e < nEnt; e++) {
        Ent en;
        // near a triangle of the batch (its first corner's tile, when it is on the screen), or anywhere
        const Case& c0 = jb.cs[r.below(nc)];
        const float fx = p2tspcase::BF(c0.p.v[0].x), fy = p2tspcase::BF(c0.p.v[0].y);
        if (r.below(3) && fx >= 0 && fx < 2048 && fy >= 0 && fy < 2048) { en.tx = (int)(fx / 32) & 63; en.ty = (int)(fy / 32) & 63; }
        else if (r.below(4) == 0) { en.tx = r.below(2) ? 63 : 0; en.ty = r.below(2) ? 63 : 0; }
        else { en.tx = (int)r.below(64); en.ty = (int)r.below(64); }
        jb.ents.push_back(en);
        const int nPass = 1 + (int)r.below(3);
        for (int ps = 0; ps < nPass; ps++) {
            const int rm = (int)r.below(7);
            const int nRun = (int)r.below(10);
            for (int k = 0; k < nRun; k++) {
                if (r.below(20) == 0) { Item n; n.null_ = true; n.ent = e; jb.items.push_back(n); }
                Item it;
                it.ci = (int)r.below(nc);
                it.ent = e;
                it.rm = rm;
                it.len = 1 + (int)r.below(r.below(3) ? 8 : 32);
                it.x = (int)r.below(33 - it.len);
                it.y = (int)r.below(32);
                const uint32_t lm = it.len == 32 ? 0xFFFFFFFFu : ((1u << it.len) - 1);
                switch (r.below(4)) {
                case 0: it.vmask = 0; break;
                case 1: it.vmask = lm; break;
                default: it.vmask = r.u32() & lm; break;
                }
                if (r.below(8) == 0) it.vmask |= r.u32() & ~lm;     // bits past the run: read by nothing
                it.pmask = (rm == 1 || rm == 2 || rm == 3) ? (r.u32() & lm) : 0;
                it.nd = r.below(3) == 0;
                const bool sh = jb.cs[it.ci].p.shadow;
                const uint32_t inv = (sh && !(rm == 1 || rm == 2)) ? (it.vmask & lm) : 0;
                (void)inv;
                *pixels += it.len;
                jb.items.push_back(it);
            }
            // the pass's last item: eop (a null item if the pass has no run, or now and then)
            if (jb.items.empty() || jb.items.back().ent != e || jb.items.back().eop || r.below(6) == 0) {
                Item n; n.null_ = true; n.ent = e; jb.items.push_back(n);
            }
            jb.items.back().eop = true;
        }
        jb.items.back().eoe = true;
    }
}

}   // namespace

int main(int argc, char** argv)
{
    p2tb::raise_stack();
    Verilated::commandArgs(argc, argv);
    p2tb::Args a;
    if (!a.parse(argc, argv)) {
        fprintf(stderr, "tsp_run: %s\n", a.error.c_str());
        return 2;
    }
    long batchN = 32, maxFails = 0;
    int stride = 1, stallPm = 200, gapPm = 200;
    uint64_t vary = 0;
    std::string dcts = getenv("DCTESTS") ? getenv("DCTESTS") : "../dreamcast-tests";
    for (size_t i = 0; i < a.rest.size(); i++) {
        const std::string& s = a.rest[i];
        auto next = [&]() { return i + 1 < a.rest.size() ? a.rest[++i] : std::string(); };
        if (s == "--batch") batchN = std::max(1L, atol(next().c_str()));
        else if (s == "--max-fails") maxFails = atol(next().c_str());
        else if (s == "--vramvary") vary = strtoull(next().c_str(), nullptr, 0);
        else if (s == "--dcts") dcts = next();
        else if (s == "--stride") stride = std::max(1, atoi(next().c_str()));
        else if (s == "--stall") stallPm = atoi(next().c_str());
        else if (s == "--gap") gapPm = atoi(next().c_str());
        else if (s[0] != '+') { fprintf(stderr, "tsp_run: unknown argument %s\n", s.c_str()); return 2; }
    }
    p2tb::banner("tsp_run", a);
    p2tb::Fails f("tsp_run");
    Vp2_tsp_run_tb_top* top = new Vp2_tsp_run_tb_top;
    Tb tb(f);
    tb.t = top;
    tb.vramVary = vary;
    tb.stallPm = stallPm;
    tb.gapPm = gapPm;
    trref::reset();
    tb.vm.init(trref::vram());
    tb.reset();
    uint64_t jobIdx = 0;
    auto stop = [&]() { return tb.broken || (maxFails && f.n >= maxFails); };

    // ---- random and super: N pixels in batches of batchN primitives
    for (const char* sect : {"random", "super"}) {
        if (!a.want(sect) || stop()) continue;
        f.set(sect);
        const bool sup = !strcmp(sect, "super");
        const long want = (long)a.count(sup ? 500000 : 2000000);
        // the batches are made in order until the pixels are reached: the same list for every shard
        long px = 0, here = 0;
        for (uint64_t b = 0; px < want && !stop(); b++, jobIdx++) {
            p2tb::Rng r = p2tb::Rng::of(a.seed + (sup ? 101 : 0), b);
            Job jb;
            jb.shad = (r.below(2) ? 0x100u : 0u) | (r.below(3) == 0 ? (r.below(2) ? 0x80u : 0xffu) : (uint32_t)r.below(256));
            jb.perp = r.below(6) == 0 ? 0x3c000000u : r.below(20) == 0 ? r.u32() : 0u;
            jb.half = r.below(4) == 0 ? (uint32_t)r.below(8) : 7u;
            for (long q = 0; q < batchN; q++) {
                p2tb::Rng rc = p2tb::Rng::of(a.seed + (sup ? 107 : 7), b * (uint64_t)batchN + (uint64_t)q);
                Case c = p2tspcase::RandomCase(rc);
                jb.cs.push_back(c);
            }
            long jp = 0;
            RandomItems(r, jb, &jp, sup);
            px += jp;
            if (!a.mine(b)) continue;
            tb.run(jb, a.seed * 1000003ull + jobIdx, sect);
            here += jp;
        }
        printf("tsp_run: section %s %ld pixels here (of %ld)\n", sect, here, px);
    }

    // ---- pitch (reported, not gated: MT5's T7): run start's clocks a run of one pixel, within one triangle and across two
    // (every run a reload: the coefficient cache holds one entry a volume), for the three classes' plane counts
    if (a.want("pitch") && !stop() && a.mine(0)) {
        f.set("pitch");
        const int saveStall = tb.stallPm, saveGap = tb.gapPm;
        tb.stallPm = 0;
        tb.gapPm = 0;
        static const char* const names[6] = {"untextured (5 planes), one triangle", "textured (7 planes), one triangle",
                                             "offset (11 planes), one triangle", "untextured, two triangles alternating",
                                             "textured, two triangles alternating", "offset, two triangles alternating"};
        for (int m = 0; m < 6; m++) {
            Job jb;
            jb.pitch = names[m];
            const int cls = m % 3;
            for (int q = 0; q < 2; q++) {
                Case c;
                c.p.isp = p2tspcase::ISP_GOURAUD | (cls ? p2tspcase::ISP_TEX : 0) | (cls == 2 ? p2tspcase::ISP_OFS : 0);
                c.p.tsp[0] = c.p.tsp[1] = (3u << 3) | 3u | (1u << 20);
                c.p.tcw[0] = c.p.tcw[1] = 1u << 27;
                c.p.skip = 7;
                const float xs[3] = {33.0f + q, 60.0f, 40.0f}, ys[3] = {34.0f, 40.0f + q, 62.0f};
                for (int k = 0; k < 3; k++) {
                    c.p.v[k].x = p2tspcase::FB(xs[k]); c.p.v[k].y = p2tspcase::FB(ys[k]); c.p.v[k].z = p2tspcase::FB(1.0f + 0.25f * k);
                    c.p.v[k].u = p2tspcase::FB(0.5f * k); c.p.v[k].v = p2tspcase::FB(0.25f * k);
                    c.p.v[k].col = 0xff102030u + 0x01010101u * (uint32_t)k; c.p.v[k].spc = 0x40302010u + 0x01010101u * (uint32_t)k;
                }
                jb.cs.push_back(c);
            }
            jb.ents.push_back({1, 1});
            for (int k = 0; k < 400; k++) {
                Item it;
                it.ci = m < 3 ? 0 : (k & 1);
                it.ent = 0;
                it.x = k % 32;
                it.y = (k / 32) % 32;
                it.len = 1;
                it.rm = 0;
                jb.items.push_back(it);
            }
            jb.items.back().eop = jb.items.back().eoe = true;
            tb.run(jb, a.seed * 1000003ull + 999000 + (uint64_t)m, "pitch");
        }
        tb.stallPm = saveStall;
        tb.gapPm = saveGap;
    }

    // ---- console: the archived sets
    if (a.want("console") && !stop()) {
        f.set("console");
        std::string famOnly, setOnly;
        if (!a.set.empty()) {
            const size_t sl = a.set.find('/');
            famOnly = a.set.substr(0, sl);
            if (sl != std::string::npos) setOnly = a.set.substr(sl + 1);
        }
        uint64_t unit = 0;            // the work unit: a group (tile) range of a set, the same cut for every shard
        for (const char* fam : p2tspset::kFamilies) {
            if (!famOnly.empty() && famOnly != fam) continue;
            for (const std::string& name : p2tspset::Names(fam)) {
                if (!setOnly.empty() && setOnly != name) continue;
                p2tspset::Set s;
                std::string err;
                if (!p2tspset::Load(dcts, fam, name, &s, &err)) { f.ok(false, "console set %s %s: %s", fam, name.c_str(), err.c_str()); continue; }
                tb.scores[s.family + " " + s.name].skipped = s.skipped;
                // the runs in units of about 3000 runs (whole groups), every stride-th run
                size_t r0 = 0;
                while (r0 < s.runs.size() && !stop()) {
                    size_t r1 = std::min(s.runs.size(), r0 + 3000);
                    while (r1 < s.runs.size() && s.runs[r1].grp == s.runs[r1 - 1].grp) r1++;
                    const uint64_t u = unit++;
                    if (a.mine(u)) {
                        Job jb;
                        jb.cs = s.tris;
                        jb.set = &s;
                        jb.wmeas = s.kind == p2tspset::K_W;
                        jb.shad = 1;                // pvrsetup.h: FPU_SHAD_SCALE 1, FPU_PERP_VAL 0, HALF_OFFSET 7
                        jb.perp = 0;
                        jb.half = 7;
                        int lastGrp = -1;
                        for (size_t k = r0; k < r1; k++) {
                            const p2tspset::Run& rn = s.runs[k];
                            if (stride > 1 && (k % (size_t)stride) != 0) continue;
                            if (rn.grp != lastGrp) {
                                if (!jb.items.empty()) { jb.items.back().eop = true; jb.items.back().eoe = true; }
                                jb.ents.push_back({rn.tx, rn.ty});
                                lastGrp = rn.grp;
                            }
                            Item it;
                            it.ci = rn.tri;
                            it.ent = (int)jb.ents.size() - 1;
                            it.x = rn.x; it.y = rn.y; it.len = rn.len;
                            it.rm = 5;              // a translucent list in the order sent (TR_PRESORT)
                            it.rd = &rn.rd;
                            jb.items.push_back(it);
                        }
                        if (!jb.items.empty()) {
                            jb.items.back().eop = true;
                            jb.items.back().eoe = true;
                            tb.run(jb, a.seed * 1000003ull + jobIdx, "console");
                        }
                    }
                    jobIdx++;
                    r0 = r1;
                }
            }
        }
    }

    const Stats& s = tb.st;
    printf("tsp_run: %ld jobs, %ld items (%ld null), %ld pixels, %ld points (%ld SupSample), %ld value checks; %ld points mipmapped, "
           "%ld with the offset planes\n", s.jobs, s.items, s.nulls, s.pixels, s.points, s.superPts, s.valChecks, s.mipPts, s.ofsPts);
    printf("tsp_run: clocks %" PRIu64 ", %.3f a pixel, %.3f a point; run start busy %.1f %% (row reads %" PRIu64 ", product clocks %" PRIu64
           "), P0 issuing %.1f %%, the pass drain %" PRIu64 " clk, P3 stalled %" PRIu64 " clk, setup busy %.1f %%; pixel queue at most %ld "
           "runs / %ld pixels, at most %ld entries pinned, SRQ at most %ld\n", s.clk, s.pixels ? (double)s.clk / s.pixels : 0.0,
           s.points ? (double)s.clk / s.points : 0.0, s.clk ? 100.0 * s.rsBusy / s.clk : 0.0, s.rsReload, s.rsMul,
           s.clk ? 100.0 * s.p0 / s.clk : 0.0, s.drain, s.stallClk, s.clk ? 100.0 * s.setupBusy / s.clk : 0.0, s.pxqRunsMax,
           s.pxqPixMax, s.pinnedMax, s.srqMax);
    if (s.h7bPlanes)
        printf("tsp_run: SupSample half lines (num H7b), at runs' starts: %ld planes, %ld where the fractions carry (hyd = F(B'/2) + 1), "
               "%ld beyond the 90 window, %ld with the 62-bit truncation, %ld with C' < 0 (%ld of them carrying)\n", s.h7bPlanes, s.h7b[0],
               s.h7b[1], s.h7b[2], s.h7b[3], s.h7bNegCarry);
    for (const auto& kv : tb.scores)
        printf("tsp_run: console %s: %ld readings, the RTL the console's on %ld, refsw3's on %ld (%ld refsw3-known), %ld not a reading\n",
               kv.first.c_str(), kv.second.readings, kv.second.rtl, kv.second.ref, kv.second.known, kv.second.skipped);
    top->final();
    delete top;
    return f.finish();
}

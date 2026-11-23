// tsp_setup_tb.cpp: the TSP set-up testbench (PLAN M9; make tsp-setup, tsp-setup-mutants).
//
//   tb [--only named,a3,console,random] [--n N] [--seed S] [--shard k/N] [--batch B] [--max-fails N] [--hold PM]
//      [--vramvary S] [--dcts <dreamcast-tests>] [--set <console set>]
//
// The DUT (p2_tsp_setup_tb_top.sv) is p2_tsp_store with p2_tsp_pfetch, p2_tsp_setup and p2_tsp_alu behind it and p2_mem
// with the VRAM model (tb/common/vram_model.h) under it. The testbench is the sorter on one side (it pushes run items
// with random gaps) and run start / the pixel pipe on the other: it pops the SRQ's head with random stalls, reads every
// live word of each entry the run references through the store's read port, compares, and releases the run's pins after
// a random delay (in the order the runs left); and it holds the ALU on random clocks (run start's use of it).
//
// The reference: refsw3's own GetFpuEntry (tsp_setup_ref.cpp: p2ref::fpu_entry on the same video memory and registers),
// its volume vsel's words (InVolume: Col[1], Ofs[1], and with two volumes the second TSP, TCW, U, V), and K from the
// copies of MipSelect's K part (tb/tsp_setup/ref_copies_tsp.h) on that entry's planes. Compared, per needed volume of
// every run, as tuples (neg, bad, mant, exp when mant != 0): every live plane's A, B, C (invW and the colours always; U, V
// when textured; the offset colours when Texture && Offset && not a bump map, the only case PixelFlush_tsp reads them),
// the header's ISP / TSP / TCW words and fallbacks (the colour's always, the offset colour's when Texture && Offset), K8
// and dz when textured and mipmapped. Also: the SRQ's order and items, the volumes each run needs, and per job its setup
// class (the one tsp_cases.h's ClassOf gives: the offset predicate on the scaled colours) and its program length
// (p2_tsp_prog_pkg's, by the issue clocks: the program consistency check).
//
// Sections (PLAN M9 gate items 3-7), each a list of cases (tsp_cases.h) run in batches of B (64) with one set of
// registers, the batch the work item (--shard over batches):
//   named    item 3: slivers_detzero, slivers_dzzero, perpmean_uv, perpmean_ovf, modvol intensity
//   a3       item 4: the dropped-offset class in full
//   console  item 5: dreamcast-tests fit/cmeas_data (c1, cwext1, cwsum1), the mipk sets (fit/mipk_data: the console's K8
//            per cell, against which the RTL's K8 is checked where refsw3's equals it; where refsw3 differs the RTL must
//            equal refsw3: PLAN 0 rule 4), fit/mipmeas_data (10 sets: K against refsw3, which is the console's there)
//   random   item 6: N random primitives (1M), every input class
// Mipmapped primitives with Sdet == 0 (item 7) are counted; refsw3 defines them since 2bee80f2 (MipSelect's dzForce,
// tsp2_mipdz): they are compared like the others.
#include <algorithm>
#include <cinttypes>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <array>
#include <deque>
#include <map>
#include <string>
#include <vector>

#include "Vp2_tsp_setup_tb_top.h"
#include "verilated.h"

#include "p2tb.h"
#include "p2_tsp_prog.h"
#include "tsp_cases.h"
#include "tsp_setup_ref.h"
#include "vram_model.h"

using p2tspcase::Case;

namespace {

struct Item {
    bool null_ = false;
    uint32_t tag = 0, vmask = 0;
    int x = 0, len = 1, rm = 0, y = 0;
    bool nd = false;
    int need = 0;                 // the volumes the testbench expects the run to need
    int ci = -1;                  // the case of the batch (the tag's)
};

struct Stats {
    long clsSkip = 0;
    long batches = 0, cases = 0, jobs = 0, runs = 0, nulls = 0, reads = 0, hits = 0, dzMip = 0, kChecked = 0;
    long cls[p2tspprog::kNCls] = {};
    uint64_t clk = 0, setupBusy = 0, laWait = 0, holdClk = 0, jobClk = 0;
    long pinnedMax = 0, srqMax = 0;
    // the console's K
    long kcCells = 0, kcRtl = 0, kcRef = 0, kcKnown = 0;
};

struct Tb {
    Vp2_tsp_setup_tb_top* t = nullptr;
    p2tb::Fails& f;
    p2tb::VramModel vm;
    Stats st;
    uint64_t cyc = 0;
    int holdPm = 150;
    uint64_t vramVary = 0;
    bool broken = false;

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
    void reset()
    {
        t->rst = 1;
        t->flush = 0;
        t->in_v = 0;
        t->out_rdy = 0;
        t->rel_v = 0;
        t->rd_v = 0;
        t->hold = 0;
        for (int i = 0; i < 4; i++) tick();
        t->rst = 0;
        tick();
    }

    struct Rd { int vsel, word, idx; };
    // ---- one batch: the cases' blocks in video memory, the runs through the DUT
    struct Exp {
        bool have = false;
        tsref::Entry e;
    };
    void batch(const std::vector<Case>& cs, uint64_t seed, const char* sect)
    {
        p2tb::Rng r(seed);
        st.batches++;
        const uint32_t shad = cs[0].shadScale, perp = cs[0].perp;
        const bool intensity = (shad >> 8) & 1;
        const uint32_t pbase = ((uint32_t)r.below(6) << 20) | (r.below(3) == 0 ? (uint32_t)r.below(0x8000) * 4u : 0u);
        // the blocks
        std::vector<uint32_t> tags(cs.size());
        uint32_t offs = (uint32_t)r.below(64);
        for (size_t i = 0; i < cs.size(); i++) {
            const Case& c = cs[i];
            const bool two = c.p.shadow && !intensity;
            const std::vector<uint32_t> w = c.p.Words(two);
            for (size_t k = 0; k < w.size(); k++)
                tsref::set_vram32((pbase + (offs + (uint32_t)k) * 4u) & 0x7FFFFCu, w[k]);
            tags[i] = (r.below(4) == 0 ? (1u << 28) : 0u) | ((uint32_t)c.p.shadow << 27) | ((uint32_t)(c.p.skip & 7) << 24) |
                      ((offs & 0x1FFFFF) << 3) | (uint32_t)(c.p.tagOffset & 7);
            offs += (uint32_t)w.size() + (uint32_t)r.below(4);
        }
        tsref::set_regs(pbase, shad, perp);
        t->param_base = pbase;
        t->fpu_shad_scale = shad;
        t->fpu_perp_val = perp;
        vm.init(tsref::vram());
        if (vramVary) vm.reseed(vramVary, seed);
        // a fresh store: the render's start
        t->flush = 1;
        tick();
        t->flush = 0;
        // the runs: each case once in its own volume, then references to the batch's cases in mixed volumes, nulls
        std::vector<Item> in;
        auto run = [&](int ci, int vsel, bool mixed) {
            Item it;
            const Case& c = cs[ci];
            it.tag = tags[ci];
            it.ci = ci;
            it.len = 1 + (int)r.below(r.below(3) ? 8 : 32);
            it.x = (int)r.below(33 - it.len);
            it.y = (int)r.below(32);
            const uint32_t lm = it.len == 32 ? 0xFFFFFFFFu : ((1u << it.len) - 1);
            it.rm = (int)r.below(7);
            const bool pt = it.rm == 1 || it.rm == 2;
            if (mixed) it.vmask = r.u32() & lm;
            else if (vsel) { it.vmask = (r.below(3) ? lm : (r.u32() | 1u)) & lm; if (pt) it.rm = 0; }
            else it.vmask = pt ? (r.u32() & lm) : 0;
            if (!c.p.shadow && r.below(2)) it.vmask = r.u32() & lm;       // no shadow bit: the mask counts for nothing
            const bool vol = c.p.shadow && !(it.rm == 1 || it.rm == 2);
            const uint32_t inv = vol ? (it.vmask & lm) : 0;
            it.need = (inv ? 2 : 0) | (inv != lm ? 1 : 0);
            it.nd = r.below(3) == 0;
            in.push_back(it);
        };
        for (size_t i = 0; i < cs.size(); i++) run((int)i, cs[i].vsel, false);
        const int extra = (int)r.below(cs.size() + 1);
        for (int k = 0; k < extra; k++) {
            if (r.below(16) == 0) { Item n; n.null_ = true; in.push_back(n); }
            const int ci = (int)r.below(cs.size());
            run(ci, (int)r.below(2), r.below(3) == 0);
        }
        // the order: mostly as made, some swapped
        for (size_t k = 1; k < in.size(); k++)
            if (r.below(4) == 0) std::swap(in[k], in[r.below(k + 1)]);
        // the references
        std::map<std::pair<uint32_t, int>, Exp> ref;
        auto expOf = [&](uint32_t tag, int vsel) -> const tsref::Entry& {
            Exp& e = ref[{tag, vsel}];
            if (!e.have) { tsref::entry(tag, vsel, &e.e); e.have = true; }
            return e.e;
        };
        // ---- the DUT
        const uint32_t inGap = r.below(3) == 0 ? 1 + (uint32_t)r.below(40) : 0;
        const uint32_t outStall = r.below(3) == 0 ? 1 + (uint32_t)r.below(60) : 0;
        size_t ii = 0;
        uint32_t inHold = 0, outHold = 0, holdLeft = 0;
        std::deque<Item> sent;                       // in the SRQ, in order
        struct Rel { uint64_t at; int need, i0, i1; };
        std::deque<Rel> rel;
        // the reader: the popped run's words, one a clock
        std::deque<Rd> rdq;
        Item cur;
        int curIdx[2] = {0, 0};
        bool rdPend = false;
        Rd rdLast{};
        long accepts = 0, dones = 0;
        int jobIssues = 0;
        bool jobAct = false;
        uint64_t jobT0 = 0;
        const uint64_t c0 = cyc, limit = 400000 + 2000ull * in.size();
        while (!broken && (ii < in.size() || !sent.empty() || !rdq.empty() || rdPend || !rel.empty())) {
            if (cyc - c0 > limit) {
                f.ok(false, "%s: batch %" PRIu64 ": no progress in %" PRIu64 " clocks (%zu items in, %zu in the SRQ, %zu reads, "
                     "%zu releases; fetch idle %d, setup idle %d, %d pinned, out_v %d, need %d idx %d %d; %ld accepts)", sect, seed, limit, in.size() - ii,
                     sent.size(), rdq.size(), rel.size(), t->t_fetch_idle, t->t_setup_idle, t->t_pinned, t->out_v, t->out_need,
                     t->out_idx0, t->out_idx1, accepts);
                broken = true;
                break;
            }
            for (int h = 0; h < 2; h++) {
                bool rdy, v;
                uint32_t d, s2;
                vm.drive(h, &rdy, &v, &d, &s2);
                t->vh_req_rdy = (t->vh_req_rdy & ~(1u << h)) | ((uint32_t)rdy << h);
                t->vh_rsp_v = (t->vh_rsp_v & ~(1u << h)) | ((uint32_t)v << h);
                t->vh_rsp_data[h] = d;
                t->vh_rsp_src[h] = s2;
            }
            // the input
            t->in_v = 0;
            if (inHold) inHold--;
            else if (ii < in.size()) {
                const Item& it = in[ii];
                t->in_v = 1;
                t->in_null = it.null_;
                t->in_tag = it.tag;
                t->in_y = it.y;
                t->in_x = it.x;
                t->in_lenm1 = it.len - 1;
                t->in_rm = it.rm;
                t->in_epoch = 0;
                t->in_vmask = it.vmask;
                t->in_pmask = 0;
                t->in_eop = 0;
                t->in_eoe = 0;
                t->in_nd = it.nd;
            }
            // run start's use of the ALU
            if (holdLeft) { holdLeft--; t->hold = 1; }
            else if (holdPm && r.below(1000) < (uint64_t)holdPm) { holdLeft = (uint32_t)r.below(3); t->hold = 1; }
            else t->hold = 0;
            // the releases
            t->rel_v = 0;
            if (!rel.empty() && rel.front().at <= cyc) {
                t->rel_v = 1;
                t->rel_need = rel.front().need;
                t->rel_idx0 = rel.front().i0;
                t->rel_idx1 = rel.front().i1;
            }
            // the reader
            t->rd_v = 0;
            if (!rdq.empty()) {
                t->rd_v = 1;
                t->rd_idx = rdq.front().idx;
                t->rd_word = rdq.front().word;
            }
            // the head: pop when the reader is free
            t->out_rdy = 0;
            if (outHold) outHold--;
            else if (rdq.empty() && !rdPend) t->out_rdy = 1;
            t->clk = 0;
            t->eval();
            // this clock's handshakes, from the DUT's state
            const bool inTake = t->in_v && t->in_rdy;
            const bool outTake = t->out_v && t->out_rdy;
            // the read's data (the word asked for last clock)
            if (rdPend) {
                check_word(rdLast, cur, curIdx, expOf, cs, sect, seed);
                rdPend = false;
            }
            if (t->rd_v) { rdLast = rdq.front(); rdq.pop_front(); rdPend = true; }
            if (t->rel_v) rel.pop_front();
            if (outTake) {
                if (sent.empty()) { f.ok(false, "%s: an item out of an empty SRQ", sect); broken = true; break; }
                cur = sent.front();
                sent.pop_front();
                st.runs++;
                if (cur.null_) st.nulls++;
                const bool same = t->out_null == cur.null_ && (cur.null_ || (t->out_tag == cur.tag && (int)t->out_x == cur.x &&
                                  (int)t->out_lenm1 == cur.len - 1 && t->out_vmask == cur.vmask)) && (bool)t->out_nd == cur.nd;
                if (!f.ok(same, "%s: batch %" PRIu64 ": the SRQ's head {null %d tag %08x x %d len %d} is not the item pushed "
                          "{null %d tag %08x x %d len %d}", sect, seed, t->out_null, t->out_tag, t->out_x, t->out_lenm1 + 1,
                          cur.null_, cur.tag, cur.x, cur.len)) { broken = true; break; }
                if (!cur.null_) {
                    f.ok((int)t->out_need == cur.need, "%s: batch %" PRIu64 ": run of tag %08x needs volumes %d, the store says %d",
                         sect, seed, cur.tag, cur.need, (int)t->out_need);
                    curIdx[0] = t->out_idx0;
                    curIdx[1] = t->out_idx1;
                    for (int v = 0; v < 2; v++) {
                        if (!((cur.need >> v) & 1)) continue;
                        const tsref::Entry& e = expOf(cur.tag, v);
                        const bool tex = e.isp & p2tspcase::ISP_TEX;
                        const bool ofsLive = tex && (e.isp & p2tspcase::ISP_OFS) && p2tspcase::TcwFmt(e.tcw) != 4;
                        rdq.push_back({v, 0, curIdx[v]});
                        if (e.kHave) rdq.push_back({v, 1, curIdx[v]});
                        for (int p = 0; p < 11; p++) {
                            const bool live = p == 0 || (p >= 3 && p <= 6) || ((p == 1 || p == 2) && tex) || (p >= 7 && ofsLive);
                            if (live) rdq.push_back({v, 2 + p, curIdx[v]});
                        }
                    }
                    // released after the reads and a random delay (the pixel pipe), in order
                    const uint64_t at = std::max<uint64_t>(rel.empty() ? 0 : rel.back().at, cyc + rdq.size() + 1 + r.below(40));
                    rel.push_back({at, cur.need, curIdx[0], curIdx[1]});
                }
                outHold = outStall ? (r.below(4) == 0 ? (uint32_t)r.below(outStall) : 0) : 0;
            }
            // the jobs: class and program length (the last step of a job and the next one's accept share a clock)
            if (t->t_issue) jobIssues++;
            if (t->t_done) {
                dones++;
                const int c = t->t_cls;
                if (c < p2tspprog::kNCls) {
                    st.cls[c]++;
                    f.ok(jobAct && jobIssues == p2tspprog::kLen[c], "%s: batch %" PRIu64 ": a %s job issued %d steps, its program has %d",
                         sect, seed, p2tspprog::kClsName[c], jobIssues, p2tspprog::kLen[c]);
                }
                st.jobClk += cyc - jobT0 + 1;
                jobAct = false;
            }
            if (t->t_accept) { accepts++; jobAct = true; jobIssues = 0; jobT0 = cyc; }
            if (!t->t_setup_idle) st.setupBusy++;
            if (t->hold) st.holdClk++;
            if (t->t_la_wait) st.laWait++;
            if (t->t_hit) st.hits++;
            if (t->t_job) st.jobs++;
            st.pinnedMax = std::max<long>(st.pinnedMax, t->t_pinned);
            st.srqMax = std::max<long>(st.srqMax, t->t_srq);
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
            if (inTake) {
                sent.push_back(in[ii]);
                ii++;
                inHold = inGap ? (r.below(3) == 0 ? (uint32_t)r.below(inGap) : 0) : 0;
            }
        }
        (void)jobAct;
        // the handshakes of the last clock are done: nothing may be offered into the next batch's flush
        t->in_v = 0;
        t->out_rdy = 0;
        t->rel_v = 0;
        t->rd_v = 0;
        t->hold = 0;
        st.clk += cyc - c0;
        st.cases += (long)cs.size();
        f.ok(accepts == dones, "%s: batch %" PRIu64 ": %ld jobs accepted, %ld done", sect, seed, accepts, dones);
    }

    static bool SameT(const tsref::T& r, bool neg, bool bad, int exp, uint64_t mant)
    {
        return r.neg == neg && r.bad == bad && r.mant == mant && (mant == 0 || r.exp == exp);
    }
    template<class F>
    void check_word(const Rd& rd, const Item& run, const int* idx, F& expOf, const std::vector<Case>& cs, const char* sect,
                    uint64_t seed)
    {
        (void)idx;
        st.reads++;
        const tsref::Entry& e = expOf(run.tag, rd.vsel);
        const Case& c = cs[run.ci];
        char where[160];
        snprintf(where, sizeof where, "%s%s%s batch %" PRIu64 " case %d (%s page %d cell %d) tag %08x vsel %d", sect,
                 c.set.empty() ? "" : " ", c.set.c_str(), seed, run.ci, c.src == p2tspcase::SRC_RANDOM ? "random" : "set",
                 c.page, c.cell, run.tag, rd.vsel);
        if (rd.word == 0) {
            f.ok(t->rh_isp == e.isp && t->rh_tsp == e.tsp && t->rh_tcw == e.tcw, "%s: header words %08x %08x %08x, refsw3 %08x %08x %08x",
                 where, t->rh_isp, t->rh_tsp, t->rh_tcw, e.isp, e.tsp, e.tcw);
            const uint32_t cfb = (uint32_t)e.colFb[0] | (uint32_t)e.colFb[1] << 8 | (uint32_t)e.colFb[2] << 16 | (uint32_t)e.colFb[3] << 24;
            const uint32_t ofb = (uint32_t)e.ofsFb[0] | (uint32_t)e.ofsFb[1] << 8 | (uint32_t)e.ofsFb[2] << 16 | (uint32_t)e.ofsFb[3] << 24;
            f.ok(t->rh_colfb == cfb, "%s: colour fallback %08x, refsw3 %08x", where, t->rh_colfb, cfb);
            if ((e.isp & p2tspcase::ISP_TEX) && (e.isp & p2tspcase::ISP_OFS))
                f.ok(t->rh_ofsfb == ofb, "%s: offset fallback (the bump light, offsKept) %08x, refsw3 %08x", where, t->rh_ofsfb, ofb);
            // the class (where the block's vertices do not overlap: there the colours are what Vtx says)
            const bool ovl = c.p.Overlaps(c.p.shadow && !((cs[0].shadScale >> 8) & 1));
            bool tex;
            int ofs, mip;
            p2tspcase::ClassOf(c.p, rd.vsel, (cs[0].shadScale >> 8) & 1, (uint8_t)cs[0].shadScale, &tex, &ofs, &mip);
            int want = 0;
            if (tex) want = 1 + ofs * 3 + mip;
            if (ovl) st.clsSkip++;
            else f.ok((int)t->rh_cls == want, "%s: setup class %s, expected %s", where,
                 t->rh_cls < p2tspprog::kNCls ? p2tspprog::kClsName[t->rh_cls] : "?", p2tspprog::kClsName[want]);
        } else if (rd.word == 1) {
            st.kChecked++;
            if (e.dz) st.dzMip++;
            const bool ok = SameT(e.k8, t->rk_neg, t->rk_bad, (int16_t)(t->rk_exp << 6) >> 6, t->rk_mant) && (bool)t->rk_dz == e.dz;
            f.ok(ok, "%s: K8 {%d %d %d %02x} dz %d, refsw3 {%d %d %d %02" PRIx64 "} dz %d", where, t->rk_neg, t->rk_bad,
                 (int16_t)(t->rk_exp << 6) >> 6, t->rk_mant, t->rk_dz, e.k8.neg, e.k8.bad, e.k8.exp, e.k8.mant, e.dz);
            // the console's K (the mipk sets), once a case
            if (c.kHave && rd.vsel == c.vsel && !kSeen.count({seed, run.ci})) {
                kSeen[{seed, run.ci}] = 1;
                pvrfp::Fp g;
                g.mant = t->rk_mant;
                g.exp = (int16_t)(t->rk_exp << 6) >> 6;
                pvrfp::Fp rf;
                rf.mant = e.k8.mant;
                rf.exp = e.k8.exp;
                bool rtlOk, refOk;
                if (c.kHave == 1) {
                    const int want = e.kOld + c.kObs;
                    rtlOk = p2tspcase::K8Index(g) == want;
                    refOk = p2tspcase::K8Index(rf) == want;
                } else {
                    rtlOk = (ldexp((double)g.mant, g.exp) >= c.kStep) == (c.kReached == 1);
                    refOk = (ldexp((double)rf.mant, rf.exp) >= c.kStep) == (c.kReached == 1);
                }
                st.kcCells++;
                auto& ps = kPerSet[c.set];
                ps[0]++; ps[1] += rtlOk; ps[2] += refOk;
                st.kcRtl += rtlOk;
                st.kcRef += refOk;
                if (!refOk) st.kcKnown++;
                // refsw3-known: where refsw3 is not the console the RTL must be refsw3 (the K8 check above)
                if (refOk) f.ok(rtlOk, "%s: the console's K (%s %d), the RTL's K8 not", where, c.kHave == 1 ? "delta" : "reached",
                                c.kHave == 1 ? c.kObs : c.kReached);
            }
        } else {
            const int p = rd.word - 2;
            const tsref::Plane& q = e.pl[p];
            const int ex[3] = {(int16_t)(t->rp_exp[0] << 6) >> 6, (int16_t)(t->rp_exp[1] << 6) >> 6, (int16_t)(t->rp_exp[2] << 6) >> 6};
            const tsref::T* rt[3] = {&q.a, &q.b, &q.c};
            for (int k = 0; k < 3; k++) {
                const bool ok = SameT(*rt[k], (t->rp_neg >> k) & 1, (t->rp_bad >> k) & 1, ex[k], t->rp_mant[k]);
                static const char* const pn[11] = {"invW", "U", "V", "colB", "colG", "colR", "colA", "ofsB", "ofsG", "ofsR", "ofsA"};
                f.ok(ok, "%s: plane %s %c {%d %d %d %04x}, refsw3 {%d %d %d %06" PRIx64 "}", where, pn[p], "ABC"[k],
                     (t->rp_neg >> k) & 1, (t->rp_bad >> k) & 1, ex[k], t->rp_mant[k], rt[k]->neg, rt[k]->bad, rt[k]->exp,
                     rt[k]->mant);
            }
        }
    }
    std::map<std::pair<uint64_t, int>, int> kSeen;
    std::map<std::string, std::array<long, 3>> kPerSet;
};

}   // namespace

int main(int argc, char** argv)
{
    p2tb::raise_stack();
    Verilated::commandArgs(argc, argv);
    p2tb::Args a;
    if (!a.parse(argc, argv)) {
        fprintf(stderr, "tsp_setup: %s\n", a.error.c_str());
        return 2;
    }
    long batchN = 64, maxFails = 0;
    int holdPm = 100;
    uint64_t vary = 0;
    std::string dcts = getenv("DCTESTS") ? getenv("DCTESTS") : "../dreamcast-tests";
    for (size_t i = 0; i < a.rest.size(); i++) {
        const std::string& s = a.rest[i];
        auto next = [&]() { return i + 1 < a.rest.size() ? a.rest[++i] : std::string(); };
        if (s == "--batch") batchN = std::max(1L, atol(next().c_str()));
        else if (s == "--max-fails") maxFails = atol(next().c_str());
        else if (s == "--hold") holdPm = atoi(next().c_str());
        else if (s == "--vramvary") vary = strtoull(next().c_str(), nullptr, 0);
        else if (s == "--dcts") dcts = next();
        else if (s[0] != '+') { fprintf(stderr, "tsp_setup: unknown argument %s\n", s.c_str()); return 2; }
    }
    p2tb::banner("tsp_setup", a);
    p2tb::Fails f("tsp_setup");
    Vp2_tsp_setup_tb_top* top = new Vp2_tsp_setup_tb_top;
    Tb tb(f);
    tb.t = top;
    tb.holdPm = holdPm;
    tb.vramVary = vary;
    tsref::reset();
    tb.vm.init(tsref::vram());
    tb.reset();

    // the sections' cases, grouped into batches of one register set (FPU_SHAD_SCALE, FPU_PERP_VAL)
    struct Sect { const char* name; std::vector<Case> cs; };
    std::vector<Sect> sects;
    std::vector<std::string> setNames;
    if (a.want("named")) { Sect s{"named", {}}; p2tspcase::DirectedNamed(&s.cs); sects.push_back(s); }
    if (a.want("a3")) { Sect s{"a3", {}}; p2tspcase::DirectedA3(&s.cs); sects.push_back(s); }
    if (a.want("console")) {
        Sect s{"console", {}};
        std::string err;
        if (!p2tspcase::ConsoleSets(dcts, &s.cs, &setNames, &err)) {
            f.ok(false, "console sets: %s", err.c_str());
            return f.finish();
        }
        // --set <name>: the console sets whose name contains it (a mutant's probe)
        if (!a.set.empty()) {
            std::vector<Case> keep;
            for (const Case& c : s.cs)
                if (c.set.find(a.set) != std::string::npos) keep.push_back(c);
            s.cs.swap(keep);
        }
        sects.push_back(s);
    }
    const uint64_t nRandom = a.count(1000000);
    uint64_t batchIdx = 0;
    for (const Sect& s : sects) {
        f.set(s.name);
        std::map<std::pair<uint32_t, uint32_t>, std::vector<size_t>> by;
        for (size_t i = 0; i < s.cs.size(); i++) by[{s.cs[i].shadScale, s.cs[i].perp}].push_back(i);
        long nb = 0;
        for (auto& kv : by)
            for (size_t k = 0; k < kv.second.size(); k += (size_t)batchN, batchIdx++) {
                if (!a.mine(batchIdx)) continue;
                std::vector<Case> cs;
                for (size_t q = k; q < kv.second.size() && q < k + (size_t)batchN; q++) cs.push_back(s.cs[kv.second[q]]);
                tb.batch(cs, a.seed * 1000003ull + batchIdx, s.name);
                nb++;
                if (tb.broken || (maxFails && f.n >= maxFails)) break;
            }
        printf("tsp_setup: section %s %zu cases (%ld batches here)\n", s.name, s.cs.size(), nb);
        if (tb.broken || (maxFails && f.n >= maxFails)) break;
    }
    if (a.want("random") && !tb.broken && !(maxFails && f.n >= maxFails)) {
        f.set("random");
        const uint64_t nb = (nRandom + batchN - 1) / batchN;
        long here = 0;
        for (uint64_t b = 0; b < nb; b++, batchIdx++) {
            if (!a.mine(batchIdx)) continue;
            p2tb::Rng r = p2tb::Rng::of(a.seed, b);
            std::vector<Case> cs;
            const uint32_t shad = (r.below(2) ? 0x100u : 0u) | (r.below(3) == 0 ? (r.below(2) ? 0x80u : 0xffu) : (uint32_t)r.below(256));
            const uint32_t perp = r.below(6) == 0 ? 0x3c000000u : r.below(20) == 0 ? r.u32() : r.below(20) == 0 ? 0x7f800000u : 0u;
            for (uint64_t q = b * batchN; q < nRandom && q < (b + 1) * batchN; q++) {
                p2tb::Rng rc = p2tb::Rng::of(a.seed + 7, q);
                Case c = p2tspcase::RandomCase(rc);
                c.shadScale = shad;
                c.perp = perp;
                cs.push_back(c);
            }
            tb.batch(cs, a.seed * 1000003ull + batchIdx, "random");
            here += (long)cs.size();
            if (tb.broken || (maxFails && f.n >= maxFails)) break;
        }
        printf("tsp_setup: section random %ld cases\n", here);
    }
    for (const std::string& s : setNames) printf("tsp_setup: console set %s\n", s.c_str());
    const Stats& s = tb.st;
    printf("tsp_setup: %ld batches, %ld cases, %ld runs (%ld null), %ld setup jobs, %ld store hits, %ld words read; %ld K "
           "checked, %ld of them mipmapped with Sdet 0 (refsw3's dzForce, compared); the setup class checked on every header read "
           "but %ld (blocks whose vertices overlap)\n", s.batches, s.cases, s.runs, s.nulls, s.jobs, s.hits, s.reads, s.kChecked,
           s.dzMip, s.clsSkip);
    printf("tsp_setup: jobs a class:");
    for (int c = 0; c < p2tspprog::kNCls; c++) printf(" %s %ld", p2tspprog::kClsName[c], s.cls[c]);
    printf("\n");
    long nj = 0;
    for (int c = 0; c < p2tspprog::kNCls; c++) nj += s.cls[c];
    printf("tsp_setup: clocks %" PRIu64 ", %.2f a job (accept to the last store write %.2f), setup busy %.1f %%, ALU held by run "
           "start %.1f %%, look-ahead waiting %" PRIu64 " clk, at most %ld entries pinned, SRQ at most %ld\n", s.clk,
           nj ? (double)s.clk / nj : 0.0, nj ? (double)s.jobClk / nj : 0.0, s.clk ? 100.0 * s.setupBusy / s.clk : 0.0,
           s.clk ? 100.0 * s.holdClk / s.clk : 0.0, s.laWait, s.pinnedMax, s.srqMax);
    if (s.kcCells)
        printf("tsp_setup: the console's K (mipk sets): %ld cells observed, the RTL's K8 the console's on %ld, refsw3's on %ld (%ld "
               "refsw3-known: the RTL compared with refsw3 there)\n", s.kcCells, s.kcRtl, s.kcRef, s.kcKnown);
    for (const auto& kv : tb.kPerSet)
        printf("tsp_setup: the console's K, %s: %ld cells observed, the RTL's K8 the console's on %ld, refsw3's on %ld\n",
               kv.first.c_str(), kv.second[0], kv.second[1], kv.second[2]);
    top->final();
    delete top;
    return f.finish();
}

// isp_setup_tb.cpp: make isp-setup. M4, the ISP setup sequencer and row stepper (PLAN M4; ARCHITECTURE 3.4.4, 3.4.5):
// p2_isp_setup (the generated microprograms on p2_isp_alu, the hand-off step's fixed logic, the 1-deep hand-off, kill
// descriptors) and p2_isp_raster (one row a clock, jf .. jl; 0 .. 31 for MODIFIER and kill), in lockstep with the
// composition of M2's and M3's references at refsw3 4f3efe15:
//   edges, culls, rows   RasterizeTriangle's setup (tb/isp_edge/ref_copies_edge.h, verbatim) and EdgeTile::Inside
//   depth                pvrisp::DepthTileT<DepthHW>::Setup / At (asked at the sample point Setup used) and StoredDepth
//
// Every job is a (primitive, tile) pair fed on the asm stream; the testbench gives each a unique tag and finds its
// descriptor (at the raster's take) and its rows by it. Compared: whether it is handed over (refsw3 reached the row loop,
// or a MODIFIER closing triangle that is culled or bad: kill), the ptc strobe's culled flag, every p2_rdesc_t field (tag,
// rm, DepthMode, ZWriteDis, quad, sum_op, kill; each edge against refsw3's EdgeTile; jf, jl, rows_v; the depth regime and
// its fields against DepthTileT in the G form), and every row (exactly jf .. jl in order, row_last on the last, the
// descriptor's fields beside it): the inside mask against Inside of all edges, the 32 keys against At.
//
// Sections (--only), in PLAN M4's gate order (item 1, the graph check, is tools/gen/gen_setup_prog.cpp --check):
//   directed  literal primitives: an ordinary triangle and quad, a point, culled ones (size, facing), bad corners, every
//             VolumeMode of a MODIFIER triangle culled and not (the kill descriptor), determinants of 2^126 and zero
//   tria      the console pages' own triangles (build/vec/<test>.trz with FPU_CULL_VAL from <test>.tri; quick one in eight)
//   random    random primitives in random tiles: tb/isp_edge's coordinate classes with tb/isp_depth's depths, and
//             tb/isp_depth's plane classes; quads, MODIFIER triangles of every VolumeMode, CullMode, FPU_CULL_VAL,
//             FPU_PERP_VAL, HALF_OFFSET[0] at random (PLAN M4 item 2: 500k quick, 5M full)
//   stream    random again (a quarter of the count) with gaps on the asm stream and back-pressure on the rows
//   (prog)    the program consistency (PLAN M4 item 3) is checked on every clock of every section: each issued step's
//             micro-word, unit by unit, against the generator's schedule (build/gen/p2_isp_prog.h, the same run as
//             rtl/v1/pkg/p2_isp_prog_pkg.sv), every register write at issue + L, the steps of a program on consecutive
//             clocks from the one after its accept, only the hand-off step waiting
//   cycle     unit-level cycle checks (PLAN M4 item 4; shard 0): the period of a stream of one primitive (TRI, QUAD,
//             culled, bad: the scheduler's lengths, against the measured 16 / 19 / 15 reported), back-to-back
//             primitives of 1 .. 32 rows (max(len, rows)), MODIFIER triangles and kill descriptors (32), and random mixed
//             streams against the recurrence of the 1-deep hand-off (every take on its clock)
// Arguments: p2tb.h's; --vec <folder> (default build/vec); --full: every tria record, the full random count.
#include <dirent.h>

#include <algorithm>
#include <cinttypes>
#include <cmath>
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "Vp2_isp_setup_tb_top.h"
#include "p2_isp_prog.h"
#include "p2tb.h"
#include "pvr_isp_depth.h"
#include "ref_copies_edge.h"
#include "tri_rec.h"
#include "triz_rec.h"
#include "verilated.h"
#include "zkey.h"

using pvrfp::Fp;
using pvrfp::i128;
typedef Vp2_isp_setup_tb_top Top;
typedef pvrisp::DepthTileT<pvrisp::DepthHW> DepthHWTile;

namespace {

p2tb::Fails* F;
const p2tb::Args* A;
const size_t kBatch = 2048;
enum { RM_OPAQUE = 0, RM_MODIFIER = 6 };
enum { Z_CONST = 0, Z_REG = 1, Z_BLOCK = 2 };

uint32_t fb(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
float bf(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
int64_t sext(uint64_t v, int bits)
{
    const uint64_t m = 1ull << (bits - 1);
    v &= (bits >= 64) ? ~0ull : ((1ull << bits) - 1);
    return (int64_t)((v ^ m) - m);
}
int64_t iabs64(int64_t v) { return v < 0 ? -v : v; }

// ---------------------------------------------------------------------------------------------------------------
// a job and what the DUT gave for it
struct Job {
    uint32_t x[4] = {}, y[4] = {}, z[3] = {};
    bool quad = false, half = true;
    int rm = RM_OPAQUE;
    uint32_t isp = 0;             // DepthMode / VolumeMode 31:29, CullMode 28:27, ZWriteDis 26
    uint32_t tag = 0;             // set by the runner: unique in its batch
    int tileX = 0, tileY = 0;
    uint32_t cullVal = 0, perp = 0;
};

struct EdgeOut { bool cv = false, ci = false, big = false; int64_t t0 = 0, tx = 0, ty = 0; int zsh = 0; uint32_t far32 = 0; };
struct ZDesc {
    int regime = Z_CONST;
    int64_t key = 0, r0 = 0, fa = 0, fb = 0, S = 0, DX = 0, DY = 0;
    int sa = 0, sb = 0, gexp = 0, E = 0, nsh = 0;
    bool fbw = false;
};

struct Out {
    long acceptAt = -1, endAt = -1, takeAt = -1;
    bool ended = false, culled = false, quadFlag = false;
    // the descriptor
    bool taken = false;
    uint32_t tag = 0;
    int rm = 0, dm = 0, sum = 0;
    bool zwdis = false, quad = false, kill = false, rowsV = false;
    int jf = 0, jl = 0;
    EdgeOut e[4];
    ZDesc z;
    // the rows
    uint32_t rowsSeen = 0;
    int lastRow = -1;
    uint32_t mask[32] = {};
    int64_t key[32][32] = {};
    int orderErrors = 0, fieldErrors = 0;
    // the program
    int issued = 0, waits = 0, traceErrors = 0;
};

// ---------------------------------------------------------------------------------------------------------------
// the DUT: jobs fed in order on the asm stream; descriptors and rows found by tag; the program trace checked every clock
struct Dut {
    Top* t;
    p2tb::Rng rng{1};
    unsigned gap = 0, stall = 0;  // per mille
    long cycles = 0;
    long traceChecks = 0;
    // the expected register writes still on their way: (clock, port, register)
    std::deque<std::pair<long, std::pair<int, int>>> pendingW;
    std::vector<std::vector<const p2prog::Issue*>> sched[3];

    explicit Dut(Top* top) : t(top)
    {
        for (int c = 0; c < 3; c++)
            sched[c].assign(p2prog::kLen[c], {});
        for (int i = 0; i < p2prog::kNIssues; i++) {
            const p2prog::Issue& s = p2prog::kIssues[i];
            sched[s.cls][s.step].push_back(&s);
        }
    }
    void clock()
    {
        t->clk = 1;
        t->eval();
        t->clk = 0;
        t->eval();
        cycles++;
    }
    void reset()
    {
        t->rst = 1;
        t->asm_v = 0;
        t->out_rdy = 1;
        t->clk = 0;
        t->eval();
        clock();
        clock();
        t->rst = 0;
        t->eval();
        pendingW.clear();
    }
    void drive(const Job& j)
    {
        t->a_isp = j.isp;
        t->a_tag = j.tag;
        t->a_rm = j.rm;
        t->a_quad = j.quad;
        for (int k = 0; k < 4; k++) {
            t->a_x[k] = j.x[k];
            t->a_y[k] = j.y[k];
        }
        for (int k = 0; k < 3; k++)
            t->a_z[k] = j.z[k];
        t->a_tilex = j.tileX;
        t->a_tiley = j.tileY;
        t->fpu_cull_val = j.cullVal;
        t->fpu_perp_val = j.perp;
        t->half = j.half;
    }

    // the micro-word of this clock against the schedule; the writes of this clock against those expected now
    void trace(Out* cur, int cls, int pc)
    {
        const int NW = p2prog::kNM + p2prog::kNA + 1;
        // the issued step: its micro-word, and the writes it will make
        if (t->t_issue)
            issued(cur, cls, pc, NW);
        // this clock's writes against those expected now
        bool want[8] = {};
        int wantRd[8] = {};
        while (!pendingW.empty() && pendingW.front().first < cycles) {
            if (cur) cur->traceErrors++;
            F->ok(false, "trace: clock %ld: a write to register %d (port %d) expected at clock %ld did not happen", cycles,
                  pendingW.front().second.second, pendingW.front().second.first, pendingW.front().first);
            pendingW.pop_front();
        }
        while (!pendingW.empty() && pendingW.front().first == cycles) {
            want[pendingW.front().second.first] = true;
            wantRd[pendingW.front().second.first] = pendingW.front().second.second;
            pendingW.pop_front();
        }
        for (int p = 0; p < NW; p++) {
            const bool v = t->t_wv[p];
            traceChecks++;
            if (v != want[p] || (v && (int)t->t_wrd[p] != wantRd[p])) {
                if (cur) cur->traceErrors++;
                F->ok(false, "trace: clock %ld port %d: write %d to %d, the schedule %d to %d", cycles, p, v,
                      (int)t->t_wrd[p], want[p], wantRd[p]);
            }
        }
    }

    void issued(Out* cur, int cls, int pc, int NW)
    {
        if (cls < 0 || cls > 2 || pc < 0 || pc >= p2prog::kLen[cls]) {
            if (cur) cur->traceErrors++;
            F->ok(false, "trace: clock %ld: class %d step %d issued", cycles, cls, pc);
            return;
        }
        bool mv[8] = {}, av[8] = {}, rv = false;
        for (const p2prog::Issue* s : sched[cls][pc]) {
            traceChecks++;
            bool ok;
            if (s->unit == 0) {
                const int q = s->slot;
                mv[q] = true;
                ok = t->t_m_v[q] && (int)t->t_m_op[q] == s->op && (int)t->t_m_swa[q] == s->swa && (int)t->t_m_ra[q] == s->ra &&
                     (int)t->t_m_rb[q] == s->rb && (int)t->t_m_rd[q] == s->rd;
                pendingW.push_back({cycles + p2prog::kLMul - 1, {q, s->rd}});
            } else if (s->unit == 1) {
                const int q = s->slot;
                av[q] = true;
                ok = t->t_a_v[q] && (int)t->t_a_op[q] == s->op && (int)t->t_a_sub[q] == s->sub &&
                     (int)t->t_a_post[q] == s->post && (int)t->t_a_ra[q] == s->ra && (int)t->t_a_rb[q] == s->rb &&
                     (int)t->t_a_rd[q] == s->rd;
                pendingW.push_back({cycles + p2prog::kLAdd - 1, {p2prog::kNM + q, s->rd}});
            } else {
                rv = true;
                ok = t->t_r_v && (int)t->t_r_ra == s->ra && (int)t->t_r_rd == s->rd;
                pendingW.push_back({cycles + p2prog::kLRcp - 1, {NW - 1, s->rd}});
            }
            if (!ok) {
                if (cur) cur->traceErrors++;
                F->ok(false, "trace: clock %ld: class %d step %d: %s (unit %d slot %d) not issued as scheduled", cycles,
                      cls, pc, s->name, s->unit, s->slot);
            }
        }
        for (int q = 0; q < p2prog::kNM; q++)
            if (t->t_m_v[q] && !mv[q]) {
                if (cur) cur->traceErrors++;
                F->ok(false, "trace: clock %ld: class %d step %d: multiplier %d issues, unscheduled", cycles, cls, pc, q);
            }
        for (int q = 0; q < p2prog::kNA; q++)
            if (t->t_a_v[q] && !av[q]) {
                if (cur) cur->traceErrors++;
                F->ok(false, "trace: clock %ld: class %d step %d: adder %d issues, unscheduled", cycles, cls, pc, q);
            }
        if (t->t_r_v && !rv) {
            if (cur) cur->traceErrors++;
            F->ok(false, "trace: clock %ld: class %d step %d: the reciprocal issues, unscheduled", cycles, cls, pc);
        }
        std::sort(pendingW.begin(), pendingW.end());
    }

    void readDesc(Out& o)
    {
        o.taken = true;
        o.takeAt = cycles;
        o.tag = t->d_tag;
        o.rm = t->d_rm;
        o.dm = t->d_dm;
        o.zwdis = t->d_zwdis;
        o.quad = t->d_quad;
        o.sum = t->d_sum_op;
        o.kill = t->d_kill;
        for (int k = 0; k < 4; k++) {
            EdgeOut& e = o.e[k];
            e.cv = t->d_const_v[k];
            e.ci = t->d_const_in[k];
            e.t0 = sext(t->d_t0[k], 31);
            e.tx = sext(t->d_tx[k], 28);
            e.ty = sext(t->d_ty[k], 28);
            e.zsh = t->d_zsh[k];
            e.big = t->d_big[k];
            e.far32 = t->d_far32[k];
        }
        o.jf = t->d_jf;
        o.jl = t->d_jl;
        o.rowsV = t->d_rows_v;
        ZDesc& z = o.z;
        z.regime = t->d_regime;
        z.key = (int64_t)t->d_key;
        z.r0 = sext(t->d_r0, 30);
        z.sa = (int)sext(t->d_sa, 2);
        z.sb = (int)sext(t->d_sb, 2);
        z.fa = sext(t->d_fa, 31);
        z.fb = sext(t->d_fb, 31);
        z.S = sext(t->d_S, 28);
        z.DX = sext(t->d_DX, 23);
        z.DY = sext(t->d_DY, 23);
        z.gexp = (int)sext(t->d_gexp, 10);
        z.E = (int)sext(t->d_E, 9);
        z.nsh = (int)sext(t->d_nsh, 5);
        z.fbw = t->d_fbw;
    }

    // run a batch to its end. The jobs' tags are set here (param_offs = the index in the batch)
    void run(std::vector<Job>& jobs, std::vector<Out>& outs)
    {
        outs.assign(jobs.size(), Out());
        for (size_t i = 0; i < jobs.size(); i++)
            jobs[i].tag = (jobs[i].tag & 0x1F000007u) | ((uint32_t)i << 3);
        size_t next = 0, ended = 0;
        std::deque<size_t> inProg;          // accepted, program not ended (at most one)
        long idle = 0;
        int curCls = -1, curPc = -1;        // the program step the trace expects next
        size_t curJob = (size_t)-1;
        long lastIssueAt = -1;
        auto byTag = [&](uint32_t tag) -> Out* {
            const size_t i = (tag >> 3) & 0x1FFFFF;
            return i < outs.size() ? &outs[i] : nullptr;
        };
        long lastProgress = cycles;
        while (true) {
            const bool feed = next < jobs.size() && !(gap && rng.chance(gap));
            if (feed)
                drive(jobs[next]);
            t->asm_v = feed;
            t->out_rdy = !(stall && rng.chance(stall));
            t->eval();
            // this clock's events, sampled before the edge
            const bool accept = feed && t->asm_rdy;
            const bool pcv = t->pc_v;
            const bool pcCulled = t->pc_culled, pcQuad = t->pc_quad;
            const bool take = t->d_take;
            const bool rowX = t->row_v && t->out_rdy;
            // the trace: the step issued now belongs to the job in its program
            Out* cur = curJob < outs.size() ? &outs[curJob] : nullptr;
            if (t->t_issue) {
                if (!cur || (int)t->t_cls != curCls || (int)t->t_pc != curPc) {
                    if (cur) cur->traceErrors++;
                    F->ok(false, "trace: clock %ld: step %d of class %d issued, expected step %d of class %d", cycles,
                          (int)t->t_pc, (int)t->t_cls, curPc, curCls);
                }
                if (cur) {
                    cur->issued++;
                    // consecutive clocks from the one after the accept, a wait only before the hand-off step
                    if (lastIssueAt >= 0 && cycles != lastIssueAt + 1 && curPc != p2prog::kLen[curCls] - 1) {
                        cur->traceErrors++;
                        F->ok(false, "trace: clock %ld: step %d issued %ld clocks after the step before", cycles, curPc,
                              cycles - lastIssueAt);
                    }
                    if (lastIssueAt >= 0 && cycles != lastIssueAt + 1)
                        cur->waits += (int)(cycles - lastIssueAt - 1);
                }
                lastIssueAt = cycles;
            }
            trace(cur, (int)t->t_cls, (int)t->t_pc);
            if (t->t_issue)
                curPc++;
            if (take) {
                Out* o = byTag(t->d_tag);
                if (!o || o->taken) {
                    F->ok(false, "clock %ld: a descriptor of tag %08x nobody expected", cycles, (uint32_t)t->d_tag);
                } else
                    readDesc(*o);
            }
            if (rowX) {
                Out* o = byTag(t->row_tag);
                if (!o || !o->taken) {
                    F->ok(false, "clock %ld: a row of tag %08x before its descriptor", cycles, (uint32_t)t->row_tag);
                } else {
                    const int j = t->row_j;
                    const int expect = o->lastRow < 0 ? o->jf : o->lastRow + 1;
                    if (j != expect || (o->rowsSeen >> j & 1) || (bool)t->row_last != (j == o->jl))
                        o->orderErrors++;
                    if ((int)t->row_rm != o->rm || (int)t->row_dm != o->dm || (bool)t->row_zwdis != o->zwdis ||
                        (int)t->row_sum_op != o->sum)
                        o->fieldErrors++;
                    o->rowsSeen |= 1u << j;
                    o->lastRow = j;
                    o->mask[j] = t->in_mask;
                    for (int i = 0; i < 32; i++)
                        o->key[j][i] = (int64_t)t->zk[i];
                }
            }
            if (pcv) {
                if (inProg.empty())
                    F->ok(false, "clock %ld: a program ended with none running", cycles);
                else {
                    Out& o = outs[inProg.front()];
                    inProg.pop_front();
                    o.ended = true;
                    o.endAt = cycles;
                    o.culled = pcCulled;
                    o.quadFlag = pcQuad;
                    ended++;
                }
                curJob = (size_t)-1;
                lastIssueAt = -1;
            }
            if (accept) {
                outs[next].acceptAt = cycles;
                inProg.push_back(next);
                curJob = next;
                curCls = jobs[next].quad ? 1 : jobs[next].rm == RM_MODIFIER ? 2 : 0;
                curPc = 0;
                lastIssueAt = cycles;      // step 0 is the clock after the accept
                next++;
            }
            clock();
            if (accept || pcv || take || rowX)
                lastProgress = cycles;
            // done: every job ended, the hand-off and the raster drained
            if (ended == jobs.size() && next == jobs.size() && !t->row_v && !take && !rowX && cycles - lastProgress > 40)
                break;
            if (++idle > 0 && cycles - lastProgress > 5000) {
                F->ok(false, "the DUT hung (%zu of %zu programs ended)", ended, jobs.size());
                for (auto& o : outs) o.orderErrors++;
                return;
            }
        }
        // writes still expected after the last clock
        while (!pendingW.empty()) {
            F->ok(false, "trace: a write to register %d expected at clock %ld never happened", pendingW.front().second.second,
                  pendingW.front().first);
            pendingW.pop_front();
        }
    }
};

// ---------------------------------------------------------------------------------------------------------------
// the reference: M2's and M3's composed
struct Ref {
    p2edgeref::Result r;
    bool bad = false, culled = false, kill = false, handed = false;
    int sum = 0;
    int nEdges = 3;
    uint32_t rows = 0;
    int jf = 0, jl = 31;
    bool rowsV = true;
    uint32_t mask[32] = {};
    DepthHWTile Z;
    ZDesc d;
    bool floatForm = false, offGrid = false;
};

void RefOf(const Job& j, Ref& f)
{
    // edges, culls, rows: RasterizeTriangle's setup
    p2edgeref::HALF_OFFSET.fpu_pixel_half_offset = j.half;
    p2edgeref::fpuCullVal = j.cullVal;
    p2edgeref::Vertex v[4];
    for (int k = 0; k < 4; k++) {
        v[k].x = j.x[k];
        v[k].y = j.y[k];
    }
    p2edgeref::DrawParameters p;
    p.isp.CullMode = (j.isp >> 27) & 3;
    p2edgeref::taRECT a;
    a.left = 32 * j.tileX;
    a.top = 32 * j.tileY;
    const bool modvol = j.rm == RM_MODIFIER;
    p2edgeref::Setup(modvol ? p2edgeref::RM_MODIFIER : p2edgeref::RM_OPAQUE, &p, v[0], v[1], v[2], j.quad ? &v[3] : nullptr,
                     &a, &f.r);
    f.culled = f.r.culled;
    f.bad = !f.r.reached && !f.r.culled;
    const int vm = (j.isp >> 29) & 7;
    f.sum = modvol ? (vm == 1 ? 1 : vm == 2 ? 2 : 0) : 0;
    f.kill = (f.bad || f.culled) && f.sum != 0;
    f.handed = f.r.reached || f.kill;
    f.nEdges = j.quad ? 4 : 3;
    if (f.kill) {
        f.jf = 0;
        f.jl = 31;
        f.rowsV = true;
        f.rows = 0xFFFFFFFFu;
    } else if (f.r.reached) {
        if (modvol) {
            f.jf = 0;
            f.jl = 31;
            f.rowsV = true;
        } else {
            const int64_t rf = f.r.rowFirst - a.top, rl = f.r.rowLast - a.top;
            f.rowsV = rf <= 31 && rl >= 0;
            f.jf = (int)std::clamp<int64_t>(rf, 0, 31);
            f.jl = (int)std::clamp<int64_t>(rl, 0, 31);
        }
        if (f.rowsV)
            for (int y = f.jf; y <= f.jl; y++) {
                f.rows |= 1u << y;
                uint32_t m = 0;
                for (int x = 0; x < 32; x++) {
                    bool in = true;
                    for (int k = 0; k < f.nEdges && in; k++)
                        in = f.r.E[k].Inside(x, y);
                    if (in)
                        m |= 1u << x;
                }
                f.mask[y] = m;
            }
    }
    // the depth: DepthTileT, the descriptor in the G form (tb/isp_depth/isp_depth_ref.h RefSetup)
    static const pvrisp::DepthHW cfg;
    pvrfp::perpVal = Fp::FromBits(j.perp & 0x7fffffffu);
    f.Z.Setup(j.x, j.y, j.z, 32 * j.tileX, 32 * j.tileY, cfg, j.half);
    const DepthHWTile& Z = f.Z;
    ZDesc& d = f.d;
    if (Z.ovf == 2) {
        d.regime = Z_REG;
        d.r0 = Z.r0; d.sa = Z.sa; d.sb = Z.sb; d.fa = Z.fa; d.fb = Z.fb;
        return;
    }
    if (!Z.valid) {
        d.regime = Z_CONST;
        d.key = Z.first_z.k;
        return;
    }
    d.regime = Z_BLOCK;
    if (!Z.block) {
        f.floatForm = true;
        return;
    }
    const bool pairV = !Z.A.zero() || !Z.B.zero();
    const int pair = !pairV ? 0 : Z.A.zero() ? Z.B.top() : Z.B.zero() ? Z.A.top() : std::max(Z.A.top(), Z.B.top());
    const int e = Z.unit + 26;
    const int gx = (pairV && pair + 5 > e) ? pair + 5 : e;
    d.gexp = gx - 26;
    const int g = d.gexp - Z.unit;
    if (g < 0 || g > 100) {
        f.offGrid = true;
        return;
    }
    const i128 G = (i128)1 << g;
    auto onGrid = [&](i128 v) { return v - (v / G) * G == 0; };
    if (!onGrid(Z.d0) || !onGrid(Z.dx) || !onGrid(Z.dy) || (Z.d0 / G) % 2 != 0) {
        f.offGrid = true;
        return;
    }
    d.S = (int64_t)(Z.d0 / G);
    d.DX = (int64_t)(Z.dx / G);
    d.DY = (int64_t)(Z.dy / G);
    d.E = Z.E;
    d.nsh = Z.E - 15 - d.gexp;
    d.fbw = Z.d0 == 0 && d.nsh < 0;
}

std::string JobStr(const Job& j)
{
    char b[400];
    snprintf(b, sizeof b, "(%a,%a %a,%a %a,%a%s) z %08x %08x %08x isp %08x rm %d tile %d,%d half %d cull %08x perp %08x",
             bf(j.x[0]), bf(j.y[0]), bf(j.x[1]), bf(j.y[1]), bf(j.x[2]), bf(j.y[2]), j.quad ? " quad" : "", j.z[0], j.z[1],
             j.z[2], j.isp, j.rm, j.tileX, j.tileY, j.half, j.cullVal, j.perp);
    if (j.quad) {
        char c[64];
        snprintf(c, sizeof c, " c4 %a,%a", bf(j.x[3]), bf(j.y[3]));
        strncat(b, c, sizeof b - strlen(b) - 1);
    }
    return b;
}

// one edge against refsw3's EdgeTile (tb/isp_edge CheckEdge, without the width claims: M2 asserts them)
bool EdgeSame(const EdgeOut& o, const pvrisp::EdgeTile& e)
{
    if (e.constant)
        return o.cv && o.ci == e.constantInside;
    const int d = Fp::Bits((uint64_t)e.zero2) - 1 + pvrisp::EdgeHW::zeroShift - 1;
    if (!e.big && d >= 30) {
        // isp 8.5: the whole tile has the start's sign; refsw3 evaluates it, the RTL has it constant
        return o.cv && o.ci == (e.t0 >= 0);
    }
    const int64_t far32 = e.tx > 0 ? (32 * e.tx) % ((int64_t)1 << 30)
                        : (e.tx < 0 && (-32 * e.tx) % ((int64_t)1 << 30) == 0) ? ((int64_t)1 << 30) : 0;
    return !o.cv && o.t0 == e.t0 && o.tx == e.tx && o.ty == e.ty && ((int64_t)1 << o.zsh) == e.zero2 && o.big == e.big &&
           o.far32 == (uint64_t)far32;
}

struct Counts {
    long jobs = 0, handed = 0, culled = 0, bad = 0, kill = 0, modvol = 0, quads = 0, rows = 0, pixels = 0;
    long regimes[3] = {};
};

void Check(const char* ctx, const Job& j, const Out& o, Counts& n, long id)
{
    Ref f;
    RefOf(j, f);
    n.jobs++;
    const std::string js = JobStr(j);
    F->ok(o.ended && o.traceErrors == 0, "%s %ld: %s: program ended %d, %d trace errors", ctx, id, js.c_str(), o.ended,
          o.traceErrors);
    if (!f.bad)
        F->ok(o.culled == f.culled, "%s %ld: %s: ptc culled %d, refsw3 %d", ctx, id, js.c_str(), o.culled, f.culled);
    else
        F->ok(!o.culled, "%s %ld: %s: a bad corner counts as stored, ptc culled %d", ctx, id, js.c_str(), o.culled);
    F->ok(o.quadFlag == j.quad, "%s %ld: ptc quad %d", ctx, id, o.quadFlag);
    n.culled += f.culled;
    n.bad += f.bad;
    n.kill += f.kill;
    n.modvol += j.rm == RM_MODIFIER;
    n.quads += j.quad;
    if (!F->ok(o.taken == f.handed, "%s %ld: %s: handed over %d, refsw3 %d (reached %d culled %d bad %d kill %d)", ctx, id,
               js.c_str(), o.taken, f.handed, f.r.reached, f.culled, f.bad, f.kill) || !f.handed)
        return;
    n.handed++;
    // the descriptor's own fields
    F->ok(o.tag == j.tag && o.rm == j.rm && o.dm == (int)(j.isp >> 29) && o.zwdis == ((j.isp >> 26) & 1) &&
              o.quad == j.quad && o.sum == f.sum && o.kill == f.kill,
          "%s %ld: %s: tag %08x rm %d dm %d zwdis %d quad %d sum_op %d kill %d; want %08x %d %d %d %d %d %d", ctx, id,
          js.c_str(), o.tag, o.rm, o.dm, o.zwdis, o.quad, o.sum, o.kill, j.tag, j.rm, j.isp >> 29, (j.isp >> 26) & 1,
          j.quad, f.sum, f.kill);
    F->ok(o.rowsV == f.rowsV && (!f.rowsV || (o.jf == f.jf && o.jl == f.jl)), "%s %ld: %s: rows_v %d jf %d jl %d; refsw3 %d %d %d",
          ctx, id, js.c_str(), o.rowsV, o.jf, o.jl, f.rowsV, f.jf, f.jl);
    if (f.kill) {
        F->ok(o.rowsSeen == 0xFFFFFFFFu && o.orderErrors == 0, "%s %ld: kill: rows %08x (%d order errors)", ctx, id,
              o.rowsSeen, o.orderErrors);
        for (int y = 0; y < 32; y++)
            F->ok(o.mask[y] == 0, "%s %ld: kill: row %d mask %08x", ctx, id, y, o.mask[y]);
        n.rows += 32;
        return;
    }
    for (int k = 0; k < f.nEdges; k++) {
        const pvrisp::EdgeTile& e = f.r.E[k];
        const EdgeOut& q = o.e[k];
        F->ok(EdgeSame(q, e), "%s %ld: %s: edge %d RTL const %d in %d t0 %lld tx %lld ty %lld zsh %d big %d far32 %u; refsw3 "
              "const %d in %d t0 %lld tx %lld ty %lld zero2 %lld big %d", ctx, id, js.c_str(), k, q.cv, q.ci, (long long)q.t0,
              (long long)q.tx, (long long)q.ty, q.zsh, q.big, q.far32, e.constant, e.constantInside, (long long)e.t0,
              (long long)e.tx, (long long)e.ty, (long long)e.zero2, e.big);
    }
    if (!j.quad)
        F->ok(o.e[3].cv && o.e[3].ci, "%s %ld: a triangle's fourth edge not a constant inside", ctx, id);
    // the depth
    const ZDesc& d = f.d;
    const ZDesc& z = o.z;
    F->ok(!f.floatForm && !f.offGrid, "%s %ld: %s: refsw3's float form or off the G grid (isp 9.4a)", ctx, id, js.c_str());
    n.regimes[d.regime]++;
    if (F->ok(z.regime == d.regime, "%s %ld: %s: regime RTL %d refsw3 %d", ctx, id, js.c_str(), z.regime, d.regime)) {
        if (d.regime == Z_CONST)
            F->ok(z.key == d.key, "%s %ld: %s: CONST key RTL %016" PRIx64 " refsw3 %016" PRIx64, ctx, id, js.c_str(),
                  (uint64_t)z.key, (uint64_t)d.key);
        else if (d.regime == Z_REG)
            F->ok(z.r0 == d.r0 && z.sa == d.sa && z.sb == d.sb && z.fa == d.fa && z.fb == d.fb,
                  "%s %ld: %s: REG RTL r0 %" PRId64 " sa %d sb %d fa %" PRId64 " fb %" PRId64 "; refsw3 r0 %" PRId64
                  " sa %d sb %d fa %" PRId64 " fb %" PRId64, ctx, id, js.c_str(), z.r0, z.sa, z.sb, z.fa, z.fb, d.r0, d.sa,
                  d.sb, d.fa, d.fb);
        else if (!f.floatForm && !f.offGrid)
            F->ok(z.S == d.S && z.DX == d.DX && z.DY == d.DY && z.gexp == d.gexp && z.E == d.E && z.fbw == d.fbw &&
                      (d.fbw || z.nsh == d.nsh),
                  "%s %ld: %s: BLOCK RTL S %" PRId64 " DX %" PRId64 " DY %" PRId64 " gexp %d E %d nsh %d fbw %d; refsw3 S %"
                  PRId64 " DX %" PRId64 " DY %" PRId64 " gexp %d E %d nsh %d fbw %d", ctx, id, js.c_str(), z.S, z.DX, z.DY,
                  z.gexp, z.E, z.nsh, z.fbw, d.S, d.DX, d.DY, d.gexp, d.E, d.nsh, d.fbw);
    }
    // the rows: exactly jf .. jl, in order; masks against Inside, keys against At
    F->ok(o.orderErrors == 0 && o.fieldErrors == 0, "%s %ld: %s: %d row order errors, %d row field errors", ctx, id,
          js.c_str(), o.orderErrors, o.fieldErrors);
    F->ok(o.rowsSeen == f.rows, "%s %ld: %s: rows %08x out of the raster, refsw3 rasterizes %08x", ctx, id, js.c_str(),
          o.rowsSeen, f.rows);
    long wrongM = 0, wrongK = 0;
    int shown = 0;
    for (int y = 0; y < 32; y++) {
        if (!(f.rows >> y & 1))
            continue;
        n.rows++;
        if (o.mask[y] != f.mask[y]) {
            wrongM++;
            if (shown++ < 2)
                F->ok(false, "%s %ld: %s: row %d mask %08x, refsw3 %08x", ctx, id, js.c_str(), y, o.mask[y], f.mask[y]);
        }
        for (int i = 0; i < 32; i++) {
            n.pixels++;
            const pvrisp::StoredDepth s = f.Z.At(i, y, j.half);
            if (o.key[y][i] != s.k) {
                wrongK++;
                if (shown++ < 2)
                    F->ok(false, "%s %ld: %s: pixel (%d, %d) key RTL %016" PRIx64 " refsw3 %016" PRIx64 " (%08x)", ctx, id,
                          js.c_str(), i, y, (uint64_t)o.key[y][i], (uint64_t)s.k, s.bits);
            }
        }
    }
    F->ok(wrongM == 0 && wrongK == 0, "%s %ld: %ld masks and %ld keys differ", ctx, id, wrongM, wrongK);
}

void PrintCounts(const char* sec, const Counts& n)
{
    printf("isp_setup: %s: %ld jobs: %ld handed over (%ld kill), %ld culled, %ld bad, %ld MODIFIER, %ld quads; %ld rows, %ld "
           "keys; regimes CONST %ld REG %ld BLOCK %ld\n", sec, n.jobs, n.handed, n.kill, n.culled, n.bad, n.modvol, n.quads,
           n.rows, n.pixels, n.regimes[0], n.regimes[1], n.regimes[2]);
}

void RunChecked(Dut& dut, std::vector<Job>& jobs, const char* ctx, Counts& n, long* id)
{
    std::vector<Out> outs;
    dut.run(jobs, outs);
    for (size_t i = 0; i < jobs.size(); i++)
        Check(ctx, jobs[i], outs[i], n, (*id)++);
    jobs.clear();
}

// ---------------------------------------------------------------------------------------------------------------
// random primitives: tb/isp_edge's RandomJob coordinate classes and tb/isp_depth's RandomJob plane classes (copied)
float Pow2f(int e) { return ldexpf(1.0f, e); }

float RndCoord(p2tb::Rng& r)
{
    switch (r.below(8)) {
    case 0: return (float)r.below(2048) * 0.5f + (float)r.below(16) / 16.0f;
    case 1: return bf(fb((float)r.below(1280)) + (uint32_t)r.range(-12, 12));
    case 2: return ldexpf((float)r.below(0xffffff), (int)r.range(-40, 19)) * (r.below(2) ? -1 : 1);
    case 3: return (float)r.below(640) + ldexpf((float)r.below(1000), -(int)r.below(30));
    case 4: return ldexpf(1.0f + r.below(1000) / 1000.0f, (int)r.below(128)) * (r.below(2) ? -1 : 1);
    case 5: return ldexpf(1.0f + r.below(0x800000) / 8388608.0f, 118 + (int)r.below(10)) * (r.below(2) ? -1 : 1);
    case 6: return bf((uint32_t)r.below(0x800000) | (r.below(2) ? 0x80000000u : 0));
    default: return (float)((int)r.below(4000) - 2000) / 7.0f;
    }
}

void FarTri(p2tb::Rng& r, float* x, float* y, int tx, int ty)
{
    const float nx = 32.0f * tx + (float)r.below(3200) / 100.0f, ny = 32.0f * ty + (float)r.below(3200) / 100.0f;
    for (int c = 0; c < 3; c++) {
        x[c] = nx + (float)r.range(-40, 40) / (r.below(2) ? 1.0f : 7.0f);
        y[c] = ny + (float)r.range(-40, 40) / (r.below(2) ? 1.0f : 7.0f);
    }
    const int far = (int)r.below(3);
    const float sg = r.below(2) ? -1.0f : 1.0f;
    float big;
    switch (r.below(7)) {
    case 0: big = ldexpf(1.0f + r.below(0x800000) / 8388608.0f, 118 + (int)r.below(10)); break;
    case 1: big = ldexpf((float)r.range(1, 15), 124); break;
    case 2: big = bf(fb(Pow2f(126 + (int)r.below(2))) + (uint32_t)r.range(-4, 4)); break;
    case 3: big = bf(fb(Pow2f(127)) + (uint32_t)r.below(0x100000)); break;
    case 4: big = Pow2f(127); break;
    case 5: big = ldexpf(1.0f + r.below(8) / 8.0f, 123 + (int)r.below(5)); break;
    default: big = bf(fb(Pow2f(118 + (int)r.below(10))) + (uint32_t)r.range(-3, 3)); break;
    }
    if (r.below(2))
        y[far] = sg * big;
    else
        x[far] = sg * big;
    if (r.below(4) == 0) {
        const int o = (far + 1) % 3;
        y[o] = -y[far] * (1.0f + r.below(16) / 64.0f);
        if (r.below(2))
            x[o] = x[far];
    }
    if (r.below(8) == 0) {
        const int a = 60 + (int)r.below(40);
        x[far] = sg * Pow2f(a);
        y[far] = Pow2f(128 - a);
    }
}

// tb/isp_edge's coordinate classes (pixel grid, ulp-perturbed, wide exponents, far, slivers, points and tiny triangles in
// rows 28 .. 31, first row 28 .. 31, bad corners, screen-sized)
void EdgeCoords(p2tb::Rng& r, Job& j)
{
    float x[4], y[4];
    const int cls = (int)r.below(10);
    const float cx = 32.0f * j.tileX, cy = 32.0f * j.tileY;
    switch (cls) {
    case 0:
        for (int c = 0; c < 4; c++) {
            x[c] = cx + (float)r.range(-24, 56) + (r.below(2) ? 0.5f : 0.0f) + (r.below(4) ? 0 : r.below(16) / 16.0f);
            y[c] = cy + (float)r.range(-24, 56) + (r.below(2) ? 0.5f : 0.0f) + (r.below(4) ? 0 : r.below(16) / 16.0f);
        }
        break;
    case 1:
        for (int c = 0; c < 4; c++) {
            x[c] = bf(fb(cx + (float)r.range(-8, 40) + 0.5f) + (uint32_t)r.range(-12, 12));
            y[c] = bf(fb(cy + (float)r.range(-8, 40) + 0.5f) + (uint32_t)r.range(-12, 12));
        }
        break;
    case 2:
        for (int c = 0; c < 4; c++) {
            x[c] = RndCoord(r);
            y[c] = RndCoord(r);
        }
        break;
    case 3:
    case 4:
        FarTri(r, x, y, j.tileX, j.tileY);
        x[3] = x[0] + (float)r.range(-30, 30);
        y[3] = y[2] + (float)r.range(-30, 30);
        break;
    case 5: {
        const float ax = cx + (float)r.below(32) + 0.5f, ay = cy + (float)r.below(32) + 0.5f;
        const float dx = (float)r.range(-6, 6), dy = (float)r.range(-6, 6);
        const float t = (float)r.range(1, 7) / 2.0f, off = r.below(4) ? 0.0f : ldexpf(1.0f, -(int)r.range(5, 17));
        x[0] = ax; y[0] = ay;
        x[1] = ax + dx * 4; y[1] = ay + dy * 4;
        x[2] = ax + dx * t + off; y[2] = ay + dy * t - off;
        x[3] = x[1]; y[3] = y[2];
        break;
    }
    case 6: {
        const float px = cx + (float)r.below(32 * 64) / 64.0f;
        const float py = cy + (r.below(2) ? 28.0f + (float)r.below(4 * 64) / 64.0f : (float)r.below(32 * 64) / 64.0f);
        for (int c = 0; c < 4; c++) {
            x[c] = px;
            y[c] = py;
            if (r.below(2) && c) {
                x[c] = bf(fb(px) + (uint32_t)r.range(-2, 2));
                y[c] = bf(fb(py) + (uint32_t)r.range(0, 2));
                if (r.below(3) == 0)
                    x[c] += (float)r.range(1, 100) / 1024.0f;
            }
        }
        break;
    }
    case 7: {
        if (r.below(2))
            FarTri(r, x, y, j.tileX, j.tileY);
        else
            for (int c = 0; c < 3; c++) {
                x[c] = cx + (float)r.range(-20, 50) + r.below(64) / 64.0f;
                y[c] = cy + (float)r.range(29, 60) + r.below(64) / 64.0f;
            }
        int top = 0;
        for (int c = 1; c < 3; c++)
            if (y[c] < y[top]) top = c;
        y[top] = cy + 28.0f + (float)r.below(4 * 256) / 256.0f;
        x[3] = x[1];
        y[3] = y[2] + (float)r.range(0, 20);
        break;
    }
    case 8:
        for (int c = 0; c < 4; c++) {
            x[c] = cx + (float)r.range(-8, 40);
            y[c] = cy + (float)r.range(-8, 40);
        }
        (r.below(2) ? x : y)[r.below(4)] = bf(r.below(2) ? 0x7F800000u | (uint32_t)r.below(4) : 0xFF800000u);
        break;
    default:
        for (int c = 0; c < 4; c++) {
            x[c] = cx + (float)r.range(-300, 300) + r.below(256) / 256.0f;
            y[c] = cy + (float)r.range(-300, 300) + r.below(256) / 256.0f;
        }
        break;
    }
    if (r.below(2)) {
        std::swap(x[1], x[2]);
        std::swap(y[1], y[2]);
    }
    for (int c = 0; c < 4; c++) {
        j.x[c] = fb(x[c]);
        j.y[c] = fb(y[c]);
    }
}

// tb/isp_depth's depth classes
uint32_t RndDepth(p2tb::Rng& g)
{
    auto frac = [&](int den) { return (float)g.below((uint64_t)den) / (float)den; };
    auto sgn = [&]() { return (g.u64() & 1) ? -1.0f : 1.0f; };
    switch (g.below(11)) {
    case 0: return fb(ldexpf(1.0f + frac(100000), (int)g.below(40) - 20) * (g.below(3) ? 1.0f : -1.0f));
    case 1: return fb(0.5f + g.below(1000) * 1e-6f);
    case 2: return fb(ldexpf((float)g.below(0xffffff), -(int)g.below(60)) * sgn());
    case 3: return fb((float)g.below(1000) / 997.0f - 0.3f);
    case 4: return fb(ldexpf(1.0f + frac(1 << 23), -126 + (int)g.below(4)) * sgn());
    case 5: return fb(ldexpf(1.0f + frac(1 << 23), 100 + (int)g.below(28)) * sgn());
    case 6: return (g.u64() & 1) ? 0u : 0x80000000u;
    case 7: return g.u32();
    case 8: return fb(-ldexpf(1.0f + frac(1000), (int)g.below(20)));
    case 9: { const uint32_t s[6] = {0x7f800000u, 0xff800000u, 0x7f7fffffu, 0xff7fffffu, 0x7f000000u, 0xff000000u};
              return s[g.below(6)]; }
    default: return fb(ldexpf(1.0f + frac(1 << 23), 124 + (int)g.below(4)) * sgn());
    }
}

// tb/isp_depth's plane classes (three corners): depthgaps' zero starts, near 2^126, zcoord / zedge at tile (0, 0), REG,
// overflowing constants, huge slopes at the origin, tiny triangles, near-2^-126 depths
void DepthPlane(p2tb::Rng& rng, Job& j)
{
    auto coin = [&]() { return (rng.u64() & 1) != 0; };
    auto frac = [&](int den) { return (float)rng.below((uint64_t)den) / (float)den; };
    auto sgn = [&]() { return coin() ? -1.0f : 1.0f; };
    const int c = 6 + (int)rng.below(10);
    const float bx = 32.0f * j.tileX + (float)rng.below(48) - 8, by = 32.0f * j.tileY + (float)rng.below(48) - 8;
    if (c == 6) {
        const float A0 = ldexpf(1.0f + frac(64), -(int)rng.below(14)) * sgn();
        const float C0 = rng.below(3) ? 0.0f : ldexpf(1.0f, -(int)rng.below(100) - 20) * sgn();
        const float x0 = 32.0f * j.tileX, y0 = 32.0f * j.tileY;
        const float L = (float)(4 + rng.below(60));
        const float xs[3] = {x0, x0 + L, x0}, ys[3] = {y0, y0, y0 + L};
        for (int k = 0; k < 3; k++) {
            j.x[k] = fb(xs[k]);
            j.y[k] = fb(ys[k]);
            j.z[k] = fb(C0 + A0 * ((xs[k] - x0) - (ys[k] - y0)));
        }
    } else if (c == 7) {
        uint32_t lm = 0x800000u | (rng.u32() & 0x7fffffu);
        const int le = 62 + (int)rng.below(3), me = 125 - le;
        uint64_t mm = (uint64_t)((((unsigned __int128)1 << 47) + lm - 1) / lm) + (uint64_t)rng.range(-4, 4);
        if (rng.below(4) == 0) {
            mm = 0x800000u;
            lm = 0x800000u;
        }
        if (mm < 0x800000u || mm > 0xffffffu)
            mm = 0x800000u;
        float L = ldexpf((float)lm, le - 23), M = ldexpf((float)mm, me - 23);
        if (rng.below(6) == 0) {
            L = ldexpf(1.0f, 64 + (int)rng.below(60));
            M = ldexpf(1.0f, 64 + (int)rng.below(60));
        }
        const float ox = (float)rng.below(640), oy = (float)rng.below(480);
        j.x[0] = fb(ox); j.y[0] = fb(oy);
        j.x[1] = fb(ox + L); j.y[1] = fb(oy);
        j.x[2] = fb(ox); j.y[2] = fb(oy + M);
        if (coin()) {
            std::swap(j.x[1], j.x[2]);
            std::swap(j.y[1], j.y[2]);
        }
        for (int k = 0; k < 3; k++)
            j.z[k] = rng.below(3) ? fb(1.0f + frac(1000)) : RndDepth(rng);
    } else if (c <= 9) {
        j.tileX = j.tileY = 0;
        auto cc = [&]() -> float {
            switch (rng.below(4)) {
            case 0: return coin() ? 0.0f : -0.0f;
            case 1: return ldexpf(1.0f + (float)rng.below(5) / 8.0f, -126) * sgn();
            case 2: return coin() ? (coin() ? 1.0f : -1.0f) : (float)rng.below(64);
            default: return (float)rng.below(4) + 0.5f;
            }
        };
        const uint32_t zs[6] = {0x7f800000u, 0xff800000u, fb(ldexpf(1.0f, 126)), fb(ldexpf(1.0f, 127)), 0x3f800000u,
                                fb(-ldexpf(1.0f, 127))};
        for (int k = 0; k < 3; k++) {
            j.x[k] = fb(cc());
            j.y[k] = fb(cc());
            j.z[k] = zs[rng.below(6)];
        }
    } else if (c == 10) {
        const float x0 = 32.0f * j.tileX + (float)rng.below(32), y0 = 32.0f * j.tileY + (float)rng.below(32);
        const float L = (float)(1 + rng.below(64));
        const float xs[3] = {x0, x0 + L, x0}, ys[3] = {y0, y0, y0 + L};
        const int bad = (int)rng.below(3);
        const uint32_t sp[6] = {0x7f800000u, 0xff800000u, 0x7fc00000u, 0x7f7fffffu, 0x7f000000u, 0x7b000000u};
        for (int k = 0; k < 3; k++) {
            j.x[k] = fb(xs[k]);
            j.y[k] = fb(ys[k]);
            j.z[k] = k == bad ? sp[rng.below(6)] : (coin() ? fb(ldexpf(1.0f + frac(1 << 20), 90 + (int)rng.below(36)) * sgn())
                                                         : RndDepth(rng));
        }
        if (coin())
            std::swap(j.x[1], j.x[2]), std::swap(j.y[1], j.y[2]);
    } else if (c == 11) {
        for (int k = 0; k < 3; k++) {
            const bool far = rng.below(3) == 0;
            j.x[k] = fb(far ? ldexpf(1.0f + frac(1 << 23), 100 + (int)rng.below(28)) * sgn() : bx + (float)rng.below(64));
            j.y[k] = fb(far ? ldexpf(1.0f + frac(1 << 23), 100 + (int)rng.below(28)) * sgn() : by + (float)rng.below(64));
            j.z[k] = coin() ? RndDepth(rng) : fb(ldexpf(1.0f + frac(1 << 23), 110 + (int)rng.below(18)) * sgn());
        }
    } else if (c == 12) {
        j.tileX = j.tileY = 0;
        const float L = (float)(2 + rng.below(6));
        const float xs[3] = {0, L, 0}, ys[3] = {0, 0, L};
        for (int k = 0; k < 3; k++) {
            j.x[k] = fb(xs[k] + (coin() ? 0.0f : frac(16)));
            j.y[k] = fb(ys[k] + (coin() ? 0.0f : frac(16)));
            j.z[k] = rng.below(4) ? fb(ldexpf(1.0f + frac(16), 120 + (int)rng.below(8)) * sgn()) : 0u;
        }
    } else if (c == 13) {
        const float cx = (float)rng.below(64) + 0.5f, cy = (float)rng.below(64) + 0.5f;
        const float s = ldexpf(1.0f, -(int)rng.below(7) - 4);
        j.tileX = (int)(cx / 32);
        j.tileY = (int)(cy / 32);
        const float xs[3] = {cx - s, cx + s, cx}, ys[3] = {cy - s, cy - s, cy + s};
        for (int k = 0; k < 3; k++) {
            j.x[k] = fb(xs[k]);
            j.y[k] = fb(ys[k]);
            j.z[k] = rng.below(3) ? fb(-ldexpf(1.0f + frac(1 << 16), (int)rng.below(30) - 10)) : RndDepth(rng);
        }
    } else {
        const float x0 = 32.0f * j.tileX, y0 = 32.0f * j.tileY;
        const float xs[3] = {x0, x0 + 32, x0}, ys[3] = {y0, y0, y0 + 32};
        for (int k = 0; k < 3; k++) {
            j.x[k] = fb(xs[k] + (coin() ? 0.0f : frac(4)));
            j.y[k] = fb(ys[k] + (coin() ? 0.0f : frac(4)));
            j.z[k] = fb(ldexpf(1.0f + frac(1 << 23), -126 + (int)rng.below(6)) * (rng.below(4) ? 1.0f : -1.0f));
            if (rng.below(6) == 0)
                j.z[k] = rng.u32() & 0x807fffffu;
        }
    }
    // a fourth corner for a quad: near the third
    j.x[3] = fb(bf(j.x[2]) + (float)rng.range(-30, 30));
    j.y[3] = fb(bf(j.y[0]) + (float)rng.range(-30, 30));
}

Job RandomJob(p2tb::Rng& r)
{
    Job j;
    j.tileX = (int)r.below(64);
    j.tileY = (int)r.below(64);
    if (r.below(3) != 0) {
        EdgeCoords(r, j);
        for (int k = 0; k < 3; k++)
            j.z[k] = RndDepth(r);
        if (r.below(3) == 0)
            j.z[1] = fb(bf(j.z[0]) + ldexpf((float)((int)r.below(2001) - 1000), -(int)r.below(40)));
    } else {
        j.tileX = (int)r.below(20);
        j.tileY = (int)r.below(15);
        DepthPlane(r, j);
    }
    j.quad = r.below(5) == 0;
    j.rm = r.below(5) == 0 ? RM_MODIFIER : (int)r.below(6);
    j.half = r.below(4) != 0;
    const uint32_t cull = r.below(3) == 0 ? (uint32_t)r.below(4) : 0;
    j.isp = (uint32_t)r.below(8) << 29 | cull << 27 | (uint32_t)r.below(2) << 26 | (r.u32() & 0x03FFFFFFu);
    static const uint32_t vals[] = {0, 0x3F800000, 0x3F000000, 0x40000000, 0xBF800000, 0x00000001, 0x7F800000,
                                    0x7FC00000, 0xFFC00001, 0x7149F2CA, 0x00800000, 0x80000000};
    j.cullVal = r.below(8) ? vals[r.below(sizeof vals / 4)] : r.u32();
    j.perp = r.below(10) == 0 ? 0x3c000000u : 0;
    j.tag = (uint32_t)r.below(2) << 28 | (uint32_t)r.below(2) << 27 | (uint32_t)r.below(8) << 24 | (uint32_t)r.below(8);
    return j;
}

void Random(Dut& dut, uint64_t n, const char* sec, uint64_t salt)
{
    F->set(sec);
    std::vector<Job> jobs;
    Counts c;
    long id = 0;
    for (uint64_t i = 0; i < n; i++) {
        if (!A->mine(i))
            continue;
        p2tb::Rng r = p2tb::Rng::of(A->seed ^ salt, i);
        jobs.push_back(RandomJob(r));
        if (jobs.size() >= kBatch)
            RunChecked(dut, jobs, sec, c, &id);
    }
    RunChecked(dut, jobs, sec, c, &id);
    PrintCounts(sec, c);
    printf("isp_setup: section %s %ld cases\n", sec, c.jobs);
}

// ---------------------------------------------------------------------------------------------------------------
// directed: literal primitives
Job Lit(float x0, float y0, float x1, float y1, float x2, float y2, uint32_t isp = 0, int rm = RM_OPAQUE)
{
    Job j;
    j.x[0] = fb(x0); j.y[0] = fb(y0); j.x[1] = fb(x1); j.y[1] = fb(y1); j.x[2] = fb(x2); j.y[2] = fb(y2);
    j.x[3] = fb(x2 + 4); j.y[3] = fb(y0 + 6);
    for (int k = 0; k < 3; k++)
        j.z[k] = fb(0.5f + 0.125f * k);
    j.isp = isp;
    j.rm = rm;
    j.cullVal = 0x3f800000u;      // FPU_CULL_VAL 1.0: CullMode 1 culls a determinant of 1 or less
    return j;
}

void Directed(Dut& dut)
{
    F->set("directed");
    std::vector<Job> jobs;
    const float t63 = ldexpf(1.0f, 63);
    jobs.push_back(Lit(2.5f, 1.5f, 28.5f, 4.5f, 9.5f, 26.5f));                           // ordinary
    {
        Job q = Lit(2, 2, 20, 2, 20, 20);
        q.quad = true;
        q.x[3] = fb(2);
        q.y[3] = fb(20);
        jobs.push_back(q);                                                               // a quad (a sprite)
    }
    jobs.push_back(Lit(5.25f, 7.75f, 5.25f, 7.75f, 5.25f, 7.75f));                      // a point: fills its rows
    jobs.push_back(Lit(0, 0, 1, 0, 0, 1, 1u << 27));                                     // culled by size (CullMode 1)
    jobs.push_back(Lit(0, 0, 9, 0, 0, 9, 2u << 27));                                     // by facing, one way
    jobs.push_back(Lit(0, 0, 9, 0, 0, 9, 3u << 27));                                     // the other facing
    jobs.push_back(Lit(0, 0, bf(0x7f800000u), 0, 0, 9));                                 // a bad corner: not drawn
    for (uint32_t vm = 0; vm < 8; vm++) {
        jobs.push_back(Lit(1, 1, 30, 3, 4, 29, vm << 29, RM_MODIFIER));                  // a volume's triangle
        jobs.push_back(Lit(0, 0, 1, 0, 0, 1, vm << 29 | 1u << 27, RM_MODIFIER));         // culled: kill with VM 1, 2
        jobs.push_back(Lit(0, 0, 9, 0, bf(0xffc00000u), 9, vm << 29, RM_MODIFIER));      // bad: kill with VM 1, 2
    }
    jobs.push_back(Lit(0, 0, t63, 0, 0, t63));                                           // det 2^126: depth key 0
    jobs.push_back(Lit(1, 1, 9, 9, 17, 17));                                             // det 0: the mean
    {
        Job j = Lit(0, 0, 64, 0.001f, 0.001f, 64);
        j.perp = 0x4a800000u;                                                            // perpendicular: the mean
        jobs.push_back(j);
        Job k = Lit(3, 3, 20, 5, 6, 22);
        k.z[0] = 0x7f800000u;                                                            // REG
        jobs.push_back(k);
    }
    for (Job& j : jobs) {
        j.cullVal = 0x3f800000u;
        j.tileX = 0;
        j.tileY = 0;
    }
    Counts c;
    long id = 0;
    const size_t n = jobs.size();
    // the culled and the kill cases must be what they say
    std::vector<Job> copy = jobs;
    std::vector<Out> outs;
    dut.run(copy, outs);
    for (size_t i = 0; i < n; i++)
        Check("directed", copy[i], outs[i], c, id++);
    long kills = 0, culledN = 0, badN = 0, handed = 0;
    for (size_t i = 0; i < n; i++) {
        Ref f;
        RefOf(copy[i], f);
        kills += f.kill;
        culledN += f.culled;
        badN += f.bad;
        handed += outs[i].taken;
    }
    F->ok(kills == 4 && culledN >= 10 && badN == 9 && handed > 0, "directed: %ld kill (want 4), %ld culled (want 10 or "
          "more), %ld bad (want 9), %ld handed over", kills, culledN, badN, handed);
    PrintCounts("directed", c);
    printf("isp_setup: section directed %zu cases\n", n);
}

// ---------------------------------------------------------------------------------------------------------------
// tria: the console pages' own triangles (build/vec/<test>.trz; FPU_CULL_VAL from the edge records of <test>.tri)
std::vector<std::string> ListTests(const std::string& dir)
{
    std::vector<std::string> out;
    if (DIR* d = opendir(dir.c_str())) {
        while (dirent* e = readdir(d)) {
            const std::string n = e->d_name;
            if (n.size() > 4 && n.compare(n.size() - 4, 4, ".trz") == 0)
                out.push_back(n.substr(0, n.size() - 4));
        }
        closedir(d);
    }
    std::sort(out.begin(), out.end());
    return out;
}

void Tria(Dut& dut, const std::string& dir)
{
    F->set("tria");
    const std::vector<std::string> names = ListTests(dir);
    F->ok(!names.empty(), "tria: no .trz files in %s", dir.c_str());
    Counts c;
    long id = 0, recs = 0, used = 0, quads = 0, noCull = 0;
    std::vector<Job> jobs;
    uint64_t k = 0;
    for (const std::string& n : names) {
        std::vector<uint8_t> raw, rawE;
        uint64_t cnt = 0, cntE = 0;
        if (!F->ok(p2tb::VecFile::read(dir + "/" + n + ".trz", p2tri::kTriZMagic, sizeof(p2tri::TriZRec), &raw, &cnt),
                   "tria: %s.trz unreadable", n.c_str()))
            continue;
        // FPU_CULL_VAL by primitive and tile (the depth records do not hold it)
        std::map<std::string, uint32_t> cullOf;
        if (p2tb::VecFile::read(dir + "/" + n + ".tri", p2tri::kTriMagic, sizeof(p2tri::TriRec), &rawE, &cntE))
            for (uint64_t r = 0; r < cntE; r++) {
                p2tri::TriRec e;
                memcpy(&e, rawE.data() + r * sizeof e, sizeof e);
                uint32_t key[10] = {e.x[0], e.x[1], e.x[2], e.y[0], e.y[1], e.y[2], e.isp, e.halfOffset,
                                    (uint32_t)e.tileX | (uint32_t)e.tileY << 8, e.modvol};
                cullOf[std::string((const char*)key, sizeof key)] = e.cullVal;
            }
        for (uint64_t r = 0; r < cnt; r++) {
            p2tri::TriZRec q;
            memcpy(&q, raw.data() + r * sizeof q, sizeof q);
            recs++;
            if (q.quad) {
                quads++;            // corner 4 is not in the render log's TRIA line (tools/gate/tria_conv.cpp)
                continue;
            }
            uint32_t key[10] = {q.x[0], q.x[1], q.x[2], q.y[0], q.y[1], q.y[2], q.isp, q.halfOffset,
                                (uint32_t)q.tileX | (uint32_t)q.tileY << 8, q.modvol};
            auto it = cullOf.find(std::string((const char*)key, sizeof key));
            if (it == cullOf.end() && ((q.isp >> 27) & 3) != 0) {
                noCull++;           // culling, and no edge record to give FPU_CULL_VAL
                continue;
            }
            const uint64_t idx = k++;
            if (!A->full && idx % 8 != 0)
                continue;                   // quick: one record in eight
            if (!A->mine(A->full ? idx : idx / 8))
                continue;
            Job j;
            for (int c3 = 0; c3 < 3; c3++) {
                j.x[c3] = q.x[c3];
                j.y[c3] = q.y[c3];
                j.z[c3] = q.z[c3];
            }
            j.isp = q.isp;
            j.rm = q.modvol ? RM_MODIFIER : RM_OPAQUE;
            j.half = q.halfOffset & 1;
            j.perp = q.perpVal;
            j.cullVal = it == cullOf.end() ? 0 : it->second;
            j.tileX = q.tileX;
            j.tileY = q.tileY;
            jobs.push_back(j);
            used++;
            if (jobs.size() >= kBatch)
                RunChecked(dut, jobs, "tria", c, &id);
        }
    }
    RunChecked(dut, jobs, "tria", c, &id);
    PrintCounts("tria", c);
    printf("isp_setup: tria: %zu tests, %ld records, %ld quads and %ld culling ones without FPU_CULL_VAL left out\n",
           names.size(), recs, quads, noCull);
    printf("isp_setup: section tria %ld cases\n", used);
}

// ---------------------------------------------------------------------------------------------------------------
// cycle: unit-level timing (PLAN M4 item 4)
struct Timed { std::vector<Out> outs; };

Timed RunTimed(Dut& dut, std::vector<Job>& jobs)
{
    Timed t;
    dut.gap = dut.stall = 0;
    dut.run(jobs, t.outs);
    return t;
}

// a triangle of r rows (1 .. 32) in tile (0, 0): corners at y = 0.25 and r - 0.75 (floor(y) .. floor(y + 1/2))
Job Rows(int r, bool quad, int rm = RM_OPAQUE, uint32_t isp = 0)
{
    Job j = Lit(0.5f, 0.25f, 31.5f, 0.25f, 0.5f, (float)r - 0.75f, isp, rm);
    j.quad = quad;
    if (quad) {
        // a rectangle 1 -> 2 -> 3 -> 4
        j.x[2] = fb(31.5f);
        j.x[3] = fb(0.5f);
        j.y[3] = fb((float)r - 0.75f);
    }
    j.cullVal = 0;
    return j;
}

// the recurrence of the 1-deep hand-off (asm always valid, rows never held): returns each job's take clock (-1: none)
// a_k     the accept;   P_k = max(a_k + LEN_k, T_prev) the hand-off write (one at a time: the descriptor before must be
// taken first), the next accept in the same clock; a skipped job ends at a_k + LEN_k - 1, the next accept there;
// T_k = max(P_k + 1, Rfree) the raster's take, Rfree = T_prev + max(rows_prev, 1)
std::vector<long> Recurrence(const std::vector<Job>& jobs, long a0)
{
    std::vector<long> take(jobs.size(), -1);
    long a = a0, Tprev = -1000000, Rfree = -1000000;
    for (size_t k = 0; k < jobs.size(); k++) {
        Ref f;
        RefOf(jobs[k], f);
        const int cls = jobs[k].quad ? 1 : jobs[k].rm == RM_MODIFIER ? 2 : 0;
        const int len = p2prog::kLen[cls];
        if (!f.handed) {
            a = a + len - 1;
            continue;
        }
        const long P = std::max(a + len, Tprev);
        const long T = std::max(P + 1, Rfree);
        int rows = 0;
        if (f.rowsV)
            rows = f.jl - f.jf + 1;
        take[k] = T;
        Tprev = T;
        Rfree = T + std::max(rows, 1);
        a = P;
    }
    return take;
}

void Cycle(Dut& dut)
{
    F->set("cycle");
    const int L[3] = {p2prog::kLen[0], p2prog::kLen[1], p2prog::kLen[2]};
    // the period of a stream of one primitive: accept to accept, in its steady state
    auto period = [&](const Job& proto, int n, bool byTake) -> double {
        std::vector<Job> jobs(n, proto);
        Timed t = RunTimed(dut, jobs);
        const int a = n / 2, b = n - 2;
        const long A0 = byTake ? t.outs[a].takeAt : t.outs[a].acceptAt;
        const long B0 = byTake ? t.outs[b].takeAt : t.outs[b].acceptAt;
        return (double)(B0 - A0) / (b - a);
    };
    const Job tri = Rows(4, false), quad = Rows(4, true);
    const double pTri = period(tri, 24, false), pQuad = period(quad, 24, false);
    const double pCulled = period(Lit(0, 0, 1, 0, 0, 1, 1u << 27), 24, false);
    const double pBad = period(Lit(0, 0, bf(0x7fc00000u), 0, 0, 9), 24, false);
    F->ok(pTri == L[0] && pQuad == L[1] && pCulled == L[0] - 1 && pBad == L[0] - 1,
          "cycle: periods TRI %.2f QUAD %.2f culled %.2f bad %.2f; the scheduler's TRI %d QUAD %d, skipped %d", pTri, pQuad,
          pCulled, pBad, L[0], L[1], L[0] - 1);
    printf("isp_setup: cycle: setup periods TRI %.1f, QUAD %.1f, culled %.1f, bad %.1f clocks (the scheduler's lengths %d, %d, "
           "skipped %d); measured [M tim 3.2] 16.0, 19.0 (18.9), 15.05 - 15.1: TRI %s, QUAD %s, culled %s (reported: the "
           "parameters were fitted on the triangle, ARCHITECTURE 6)\n", pTri, pQuad, pCulled, pBad, L[0], L[1], L[0] - 1,
           L[0] == 16 ? "agrees" : "DIFFERS", L[1] == 19 ? "agrees" : "DIFFERS", L[0] - 1 == 15 ? "agrees" : "DIFFERS");
    // back-to-back: max(len, rows), by the raster's takes
    int bad = 0;
    std::string tbl;
    for (int r = 1; r <= 32; r++) {
        for (int q = 0; q < 2; q++) {
            const double p = period(Rows(r, q), 24, true);
            const double want = std::max(L[q], r);
            if (p != want) bad++;
            if (q == 0 && (r == 1 || r == 16 || r == 17 || r == 20 || r == 24 || r == 28 || r == 32)) {
                char b[48];
                snprintf(b, sizeof b, " %d:%.0f", r, p);
                tbl += b;
            }
        }
    }
    F->ok(bad == 0, "cycle: %d row counts whose back-to-back period is not max(len, rows)", bad);
    printf("isp_setup: cycle: back-to-back triangles, rows:clocks%s (max(%d, rows) for every row count 1 .. 32, triangles "
           "and quads; measured +1 a line past 16)\n", tbl.c_str(), L[0]);
    // MODIFIER triangles and kill descriptors: 32 rows each
    const double pMod = period(Lit(1, 1, 30, 3, 4, 29, 0, RM_MODIFIER), 24, true);
    const double pModSmall = period(Lit(1, 1, 3, 1, 1, 3, 1u << 29, RM_MODIFIER), 24, true);
    const double pKill = period(Lit(0, 0, 1, 0, 0, 1, 1u << 29 | 1u << 27, RM_MODIFIER), 24, true);
    F->ok(pMod == 32 && pModSmall == 32 && pKill == 32, "cycle: MODIFIER %.2f (small %.2f), kill %.2f; want 32", pMod,
          pModSmall, pKill);
    printf("isp_setup: cycle: MODIFIER triangles %.1f (a small one %.1f), kill descriptors %.1f clocks (32 rows; the "
           "2-triangle volume's 65th clock is GAP T2, MV_GAP not modelled)\n", pMod, pModSmall, pKill);
    // mixed streams against the recurrence of the 1-deep hand-off
    long checked = 0, wrong = 0;
    for (int s = 0; s < 40; s++) {
        p2tb::Rng r = p2tb::Rng::of(A->seed ^ 0xC1C1Eull, s);
        std::vector<Job> jobs;
        const int n = 30 + (int)r.below(30);
        for (int k = 0; k < n; k++) {
            switch (r.below(6)) {
            case 0: jobs.push_back(Rows(1 + (int)r.below(32), r.below(3) == 0)); break;
            case 1: jobs.push_back(Lit(0, 0, 1, 0, 0, 1, 1u << 27)); break;                                // culled
            case 2: jobs.push_back(Lit(1, 1, 30, 3, 4, 29, (uint32_t)r.below(3) << 29, RM_MODIFIER)); break;
            case 3: jobs.push_back(Lit(0, 0, 1, 0, 0, 1, (1u + (uint32_t)r.below(2)) << 29 | 1u << 27, RM_MODIFIER)); break;
            case 4: jobs.push_back(Rows(32, false)); break;
            default: jobs.push_back(Rows(1 + (int)r.below(8), false)); break;
            }
        }
        Timed t = RunTimed(dut, jobs);
        const std::vector<long> want = Recurrence(jobs, t.outs[0].acceptAt);
        for (size_t k = 0; k < jobs.size(); k++) {
            checked++;
            if (t.outs[k].takeAt != want[k]) {
                wrong++;
                if (wrong <= 5)
                    F->ok(false, "cycle: mixed stream %d job %zu: taken at clock %ld, the 1-deep hand-off's recurrence %ld",
                          s, k, t.outs[k].takeAt, want[k]);
            }
        }
    }
    F->ok(wrong == 0, "cycle: %ld of %ld takes of the mixed streams off the recurrence", wrong, checked);
    printf("isp_setup: cycle: mixed streams: %ld primitives' takes (or none) on the 1-deep hand-off's recurrence, %ld off\n",
           checked - wrong, wrong);
    printf("isp_setup: cycle: strip alternation 19 / 15 (GAP T2): reported, not gated; the setup has no strip state, every "
           "strip triangle costs TRI's %d\n", L[0]);
    printf("isp_setup: section cycle 1 cases\n");
}

}   // namespace

int main(int argc, char** argv)
{
    p2tb::raise_stack();
    p2tb::Args args;
    if (!args.parse(argc, argv)) {
        fprintf(stderr, "isp_setup: %s\n", args.error.c_str());
        return 2;
    }
    A = &args;
    p2tb::banner("isp_setup", args);
    p2tb::Fails fails("isp_setup");
    F = &fails;
    const std::string vecDir = !args.vec.empty() ? args.vec : "build/vec";

    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(1, argv);
    auto top = std::make_unique<Top>(ctx.get());
    Dut dut(top.get());
    dut.rng = p2tb::Rng(args.seed ^ 0x5E7ull);
    dut.reset();

    const uint64_t nRandom = args.count(args.full ? 5000000 : 500000);
    if (args.want("directed") && args.shardK == 0)
        Directed(dut);
    if (args.want("tria"))
        Tria(dut, vecDir);
    if (args.want("random"))
        Random(dut, nRandom, "random", 0);
    if (args.want("stream")) {
        dut.gap = 300;
        dut.stall = 300;
        Random(dut, nRandom / 4, "stream", 0x5157ull);
        dut.gap = dut.stall = 0;
    }
    if (args.want("cycle") && args.shardK == 0)
        Cycle(dut);
    printf("isp_setup: program trace: %ld checks\n", dut.traceChecks);
    printf("isp_setup: %ld clocks\n", dut.cycles);
    return fails.finish();
}

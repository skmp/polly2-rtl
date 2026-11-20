// isp_edge_tb.cpp: make isp-edge. M2, the ISP edge path (PLAN M2; ARCHITECTURE 3.4.4 steps 1-5, 3.4.5 edge lanes and
// walk; isp 7.1, 7.2, 8.1-8.6 at refsw3 4f3efe15): p2_isp_edge_setup and p2_isp_edge_raster in lockstep with refsw3's
// RasterizeTriangle setup (tb/isp_edge/ref_copies_edge.h, verbatim) and pvrisp::EdgeTile::Inside.
//
// Every job is a (primitive, tile) pair through the setup, whose result the testbench carries into the raster. Compared:
// bad, culled, the winding, EdgeWinding's determinant (the tuple), every edge's p2_edge_t against refsw3's EdgeTile
// (constant and its answer; else t0, tx, ty, zero2 = 2^zsh, big, far32; an edge refsw3 evaluates with d >= 30 must be
// constant in the RTL, every one of its 1,024 pixels of the start's sign), jf / jl / rows_v against RowRange and the
// row-31 shift, and every row the raster gives (exactly the rasterized rows, in order) against Inside of all edges.
// The width claims of isp 8.5 are asserted on refsw3's values of every job (section summaries print the maxima).
//
// Sections (--only), in PLAN M2's gate order:
//   directed  console facts as literals, independent of refsw3 (and checked against it too): the top-left rule and the
//             row-zero rule (covmeas rules 6-8), a point filling its rows (degen40), the row range (rule 10), the
//             row-31 shift for every polygon (edge2_walk page 6, edge2_row31), equal culled by size and the facings
//             (raster page 4, cullval, faredge_cull), a bad corner neither drawn nor culled (huge); the walk on given
//             descriptors: -2^131 not pushed and +2^131 pushed (faredge_m131), R wrapping by 2^132 and the end after it
//             (hugepos_rules), the far value R + 2^131 for a column step that is a multiple of 2^126 against R alone
//             for an odd multiple of 2^124 (edge2_walk pages 0-2, edge2_end, edge2_mult), the end against ZERO
//             (edge2_walk pages 3-5); and at setup level against the console's own pixels (ConsolePages): hugepos_a's
//             15,019 / 705 / 15 / 2 pixels at 2^118 .. 2^124, faredge_cmax's 2^128 products and cancelling pairs,
//             faredge_k132's RV tiles, faredge_ecap's cap at 129 (pages 0-5) and its ends at R = -2^131 (pages 7, 9),
//             faredge_m131, faredge_walk (pages 0-3 the row-31 shift), edge2_walk, edge2_end (pages 3, 4: R alone near
//             -2^127 and for +2^127), edge2_mult, edge2_row31, each counting the mechanism it is about
//   covmeas   every archived covmeas set (dreamcast-tests fit/covmeas_data/*.npz + .cases.json, enumerated): the
//             RTL's inside masks composed into pages as dreamcast-tests model/covprobe composes them (refsw3's depth
//             and TSP colour per pixel, read as read.py reads a console page), against the console's record
//   tria      the console pages' own primitives, build/vec/<test>.tri (tools/gate/tria_extract.sh), per tile
//   random    random triangles, quads and modifier volumes of every class (num 7.2; PLAN M2 item 4)
//   rdesc     raster-only: random descriptors around the walk's boundaries (R at +-2^131, R + 16 sx at +-2^131, the
//             far value at ZERO, column steps at multiples of 2^124 .. 2^126) against EdgeTile::Walk / Inside
//   stream    random and rdesc again (a quarter of their counts, at most 2M / 500k) with random gaps on both inputs
//             and random back-pressure on the rows
// Arguments: p2tb.h's; --vec <folder> (default build/vec), --set <folder> (default $DCTESTS/fit/covmeas_data);
// --full: every covmeas set (quick: one in four and the first of each prim / HALF_OFFSET class), every tria record
// (quick: one in eight), the full random counts (random 400M edges, rdesc 20M; quick 2M and 100k).
#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <memory>
#include <string>
#include <dirent.h>

#include "isp_edge_dut.h"
#include "isp_edge_ref.h"
#include "npz.h"
#include "pvr_isp_depth.h"
#include "pvr_tsp_plane.h"
#include "tri_rec.h"
#include "verilated.h"

using namespace edgetb;
using pvrfp::Fp;
typedef Vp2_isp_edge_tb_top Top;

namespace {

p2tb::Fails* F;
Widths W;
const p2tb::Args* A;

uint32_t fb(float f)
{
    uint32_t u;
    memcpy(&u, &f, 4);
    return u;
}
float bf(uint32_t u)
{
    float f;
    memcpy(&f, &u, 4);
    return f;
}

// ---------------------------------------------------------------------------------------------------------------
// compare one job (setup or raster-only) with refsw3, and check the widths; ctx names it in a failure
void CheckEdge(const EdgeOut& o, const pvrisp::EdgeTile& e, int k, const char* ctx, long id)
{
    if (e.constant) {
        F->ok(o.cv && o.ci == e.constantInside, "%s %ld edge %d: constant %d inside %d, refsw3 constant inside %d", ctx,
              id, k, o.cv, o.ci, e.constantInside);
        return;
    }
    const int d = DOf(e);
    F->ok(e.tie2 == e.zero2, "%s %ld edge %d: tie2 %lld != zero2 %lld", ctx, id, k, (long long)e.tie2,
          (long long)e.zero2);
    if (!e.big && d >= 30) {
        // isp 8.5: the whole tile has the start's sign; refsw3 evaluates it, the RTL has it constant
        W.constD30++;
        const bool s = e.t0 >= 0;
        bool all = true;
        for (int j = 0; j < 32 && all; j++)
            for (int i = 0; i < 32 && all; i++)
                all = e.Inside(i, j) == s;
        F->ok(all, "%s %ld edge %d: d %d >= 30 and not every pixel of the start's sign (width claim)", ctx, id, k, d);
        F->ok(o.cv && o.ci == s, "%s %ld edge %d: d %d: RTL constant %d inside %d, the start's sign %d", ctx, id, k, d,
              o.cv, o.ci, s);
        return;
    }
    const int64_t far32 = e.tx > 0 ? (32 * e.tx) % ((int64_t)1 << 30)
                        : (e.tx < 0 && (-32 * e.tx) % ((int64_t)1 << 30) == 0) ? ((int64_t)1 << 30) : 0;
    F->ok(!o.cv && o.t0 == e.t0 && o.tx == e.tx && o.ty == e.ty && ((int64_t)1 << o.zsh) == e.zero2 && o.big == e.big &&
              o.far32 == (uint64_t)far32,
          "%s %ld edge %d: RTL const %d t0 %lld tx %lld ty %lld zero2 2^%d big %d far32 %u; refsw3 t0 %lld tx %lld ty "
          "%lld zero2 %lld big %d far32 %lld", ctx, id, k, o.cv, (long long)o.t0, (long long)o.tx, (long long)o.ty,
          o.zsh, o.big, o.far32, (long long)e.t0, (long long)e.tx, (long long)e.ty, (long long)e.zero2, e.big,
          (long long)far32);
    // the width claims (isp 8.5)
    if (!e.big) {
        W.ordEdges++;
        W.dMinOrd = std::min(W.dMinOrd, d);
        W.dMaxOrd = std::max(W.dMaxOrd, d);
        W.maxT0Ord = std::max(W.maxT0Ord, iabs64(e.t0));
        W.maxStepOrd = std::max({W.maxStepOrd, iabs64(e.tx), iabs64(e.ty)});
        F->ok(d >= 27 && d <= 29 && iabs64(e.t0) < ((int64_t)1 << 29) && iabs64(e.tx) < ((int64_t)1 << 22) &&
                  iabs64(e.ty) < ((int64_t)1 << 22),
              "%s %ld edge %d: ordinary d %d |t0| %lld |tx| %lld |ty| %lld outside isp 8.5 (width claim)", ctx, id, k, d,
              (long long)iabs64(e.t0), (long long)iabs64(e.tx), (long long)iabs64(e.ty));
        int64_t mx = 0;
        for (int j = 0; j < 32; j++)
            for (int i = 0; i <= 32; i++)
                mx = std::max(mx, iabs64(e.t0 + e.ty * j + e.tx * i));
        W.maxOrd = std::max(W.maxOrd, mx);
        F->ok(mx < ((int64_t)1 << 30), "%s %ld edge %d: an ordinary value 2^%.2f: past the 31-bit accumulator (width "
              "claim)", ctx, id, k, log2((double)mx));
    } else {
        W.bigEdges++;
        W.maxT0Big = std::max(W.maxT0Big, iabs64(e.t0));
        W.maxStepBig = std::max({W.maxStepBig, iabs64(e.tx), iabs64(e.ty)});
        F->ok(d == 27 && e.zero2 == 128 && e.h == ((int64_t)1 << 30) && e.f0 == e.t0 && e.fx == e.tx && e.fy == e.ty &&
                  e.z == e.zero2 && iabs64(e.t0) < ((int64_t)1 << 27) && iabs64(e.tx) < ((int64_t)1 << 27) &&
                  iabs64(e.ty) < ((int64_t)1 << 27),
              "%s %ld edge %d: big d %d zero2 %lld h %lld f0/fx/fy %lld/%lld/%lld t0/tx/ty %lld/%lld/%lld (width claim)",
              ctx, id, k, d, (long long)e.zero2, (long long)e.h, (long long)e.f0, (long long)e.fx, (long long)e.fy,
              (long long)e.t0, (long long)e.tx, (long long)e.ty);
        const int64_t mx = WalkMax(e, e.firstRow);
        W.walks++;
        W.maxWalk = std::max(W.maxWalk, mx);
        W.maxFar = std::max(W.maxFar, far32);
        F->ok(mx < ((int64_t)1 << 33) && far32 >= 0 && far32 <= ((int64_t)1 << 30),
              "%s %ld edge %d: a walk value 2^%.2f or far32 %lld past the 34-bit lanes (width claim)", ctx, id, k,
              log2((double)mx), (long long)far32);
    }
}

void CheckRows(const Ref& f, const Out& o, const char* ctx, long id)
{
    F->ok(o.orderErrors == 0, "%s %ld: %d row order errors", ctx, id, o.orderErrors);
    F->ok(o.rowsSeen == f.rows, "%s %ld: rows %08x out of the raster, refsw3 rasterizes %08x", ctx, id, o.rowsSeen,
          f.rows);
    for (int y = 0; y < 32; y++)
        if (f.rows >> y & 1)
            F->ok(o.mask[y] == f.mask[y], "%s %ld: row %d mask %08x, refsw3 %08x", ctx, id, y, o.mask[y], f.mask[y]);
}

// a setup job: everything, against refsw3; returns the reference for the caller's own use
void CheckSetup(const Job& j, const Out& o, Ref& f, const char* ctx, long id)
{
    RefSetup(j, f);
    F->ok(o.bad == f.bad, "%s %ld: bad %d, refsw3 %d", ctx, id, o.bad, f.bad);
    if (!f.bad)
        F->ok(o.culled == f.r.culled, "%s %ld: culled %d, refsw3 %d", ctx, id, o.culled, f.r.culled);
    F->ok(o.flip == (f.sgn < 0), "%s %ld: flip %d, refsw3 sgn %d", ctx, id, o.flip, f.sgn);
    const bool dm = o.detNeg == f.det.neg && o.detBad == f.det.bad && o.detMant == f.det.mant &&
                    (f.det.mant == 0 || o.detExp == f.det.exp);
    F->ok(dm, "%s %ld: det {%d %d %d %06x}, refsw3 {%d %d %d %06llx}", ctx, id, o.detNeg, o.detBad, o.detExp, o.detMant,
          f.det.neg, f.det.bad, f.det.exp, (unsigned long long)f.det.mant);
    if (j.kill) {
        // a summary-only descriptor: its rows, every one empty
        uint32_t all = 0;
        for (int y = o.jf; y <= o.jl && o.rowsV; y++)
            all |= 1u << y;
        F->ok(o.fed && o.rowsSeen == all, "%s %ld: kill: rows %08x, want %08x", ctx, id, o.rowsSeen, all);
        for (int y = 0; y < 32; y++)
            F->ok(o.mask[y] == 0, "%s %ld: kill: row %d mask %08x", ctx, id, y, o.mask[y]);
        return;
    }
    if (!f.r.reached) {
        F->ok(!o.fed, "%s %ld: refsw3 drew nothing (bad %d culled %d), the RTL rasterized it", ctx, id, f.bad,
              f.r.culled);
        return;
    }
    for (int k = 0; k < f.nEdges; k++)
        CheckEdge(o.e[k], f.r.E[k], k, ctx, id);
    if (!j.modvol) {
        const int64_t top = 32 * (int64_t)j.tileY;
        const int64_t rf = f.r.rowFirst - top, rl = f.r.rowLast - top;
        const bool rv = rf <= 31 && rl >= 0;
        F->ok(o.rowsV == rv && (!rv || (o.jf == std::clamp<int64_t>(rf, 0, 31) && o.jl == std::clamp<int64_t>(rl, 0, 31))),
              "%s %ld: rows_v %d jf %d jl %d; refsw3 rows %lld .. %lld in the tile", ctx, id, o.rowsV, o.jf, o.jl,
              (long long)rf, (long long)rl);
    } else
        F->ok(o.rowsV && o.jf == 0 && o.jl == 31, "%s %ld: MODIFIER rows_v %d jf %d jl %d", ctx, id, o.rowsV, o.jf, o.jl);
    CheckRows(f, o, ctx, id);
}

void CheckRaster(const Job& j, const Out& o, Ref& f, const char* ctx, long id)
{
    RefRaster(j, f);
    CheckRows(f, o, ctx, id);
}

void CheckAny(const Job& j, const Out& o, Ref& f, const char* ctx, long id)
{
    if (j.rasterOnly)
        CheckRaster(j, o, f, ctx, id);
    else
        CheckSetup(j, o, f, ctx, id);
}

void PrintWidths(const char* sec)
{
    printf("isp_edge: %s widths: ordinary edges %ld (d %d..%d, |t0| 2^%.2f, |steps| 2^%.2f, values 2^%.2f), d >= 30 "
           "constant %ld; big edges %ld (|t0| 2^%.2f, |steps| 2^%.2f), walks %ld (values 2^%.2f, far32 2^%.2f)\n",
           sec, W.ordEdges, W.dMinOrd, W.dMaxOrd, log2((double)W.maxT0Ord + 1), log2((double)W.maxStepOrd + 1),
           log2((double)W.maxOrd + 1), W.constD30, W.bigEdges, log2((double)W.maxT0Big + 1),
           log2((double)W.maxStepBig + 1), W.walks, log2((double)W.maxWalk + 1), log2((double)W.maxFar + 1));
    W = Widths();
}

// run jobs in batches through the DUT and check each
void RunChecked(Dut& dut, std::vector<Job>& jobs, const char* ctx, long* id)
{
    std::vector<Out> outs;
    dut.run(jobs, outs);
    for (size_t i = 0; i < jobs.size(); i++) {
        Ref f;
        CheckAny(jobs[i], outs[i], f, ctx, (*id)++);
    }
    jobs.clear();
}

// ---------------------------------------------------------------------------------------------------------------
// directed: console facts as literals
struct RowWant { int row; uint32_t mask, care; };

Job Tri(float x0, float y0, float x1, float y1, float x2, float y2, int tx = 0, int ty = 0)
{
    Job j;
    j.x[0] = fb(x0); j.y[0] = fb(y0);
    j.x[1] = fb(x1); j.y[1] = fb(y1);
    j.x[2] = fb(x2); j.y[2] = fb(y2);
    j.tileX = tx;
    j.tileY = ty;
    return j;
}

EdgeOut BigEdge(int64_t t0, int64_t tx, int64_t ty)
{
    EdgeOut e;
    e.big = true;
    e.t0 = t0;
    e.tx = tx;
    e.ty = ty;
    e.zsh = 7;
    e.far32 = tx > 0 ? (uint32_t)(((tx & ((1 << 25) - 1)) << 5)) : (tx < 0 && (tx & ((1 << 25) - 1)) == 0) ? (1u << 30) : 0;
    return e;
}

Job Desc(const EdgeOut& e, int jf = 0, int jl = 31)
{
    Job j;
    j.rasterOnly = true;
    j.de[0] = e;
    for (int k = 1; k < 4; k++) {
        j.de[k].cv = true;
        j.de[k].ci = true;
    }
    j.djf = jf;
    j.djl = jl;
    return j;
}

void Directed(Dut& dut)
{
    F->set("directed");
    struct Case {
        const char* what;
        Job j;
        int bad, culled;                  // -1: not checked
        uint32_t rows;                    // the rows that come out (bit j), or ~0u: not checked
        std::vector<RowWant> want;
    };
    std::vector<Case> cs;
    auto rowsBits = [](int a, int b) { uint32_t m = 0; for (int y = a; y <= b; y++) m |= 1u << y; return m; };
    auto bits = [](int a, int b) { uint32_t m = 0; for (int x = a; x <= b; x++) m |= 1u << x; return m; };
    // covmeas rules 6-8, 10: edges through pixel centres. Row 2 starts at zero on the top edge (whole row by the row
    // step: in); the left edge x = 2.5 is a tie, the next pixel positive (in); the hypotenuse x + y = 23 a tie, the next
    // pixel negative (out); rows floor(2.5) .. floor(20.5 + 1/2) = 2 .. 21
    for (int w = 0; w < 2; w++) {
        Case c{w ? "top-left rule, other winding" : "top-left rule (covmeas 6-8, 10)",
               w ? Tri(2.5f, 2.5f, 2.5f, 20.5f, 20.5f, 2.5f) : Tri(2.5f, 2.5f, 20.5f, 2.5f, 2.5f, 20.5f), 0, 0,
               rowsBits(2, 21), {}};
        for (int y = 2; y <= 21; y++)
            c.want.push_back({y, y <= 19 ? bits(2, 21 - y) : 0u, ~0u});
        cs.push_back(c);
    }
    // degen40: three equal corners fill the tile's width on the rows of their row range (5 .. floor(6.25) = 6)
    {
        Case c{"point fills its rows (degen40)", Tri(10.25f, 5.75f, 10.25f, 5.75f, 10.25f, 5.75f), 0, 0, rowsBits(5, 6),
               {{5, ~0u, ~0u}, {6, ~0u, ~0u}}};
        cs.push_back(c);
    }
    // edge2_walk page 6, edge2_row31: a point in row 31 of its tile fills rows 30 and 31; in row 30 it starts there
    cs.push_back({"row-31 shift of a point (edge2_row31)", Tri(7.5f, 31.25f, 7.5f, 31.25f, 7.5f, 31.25f), 0, 0,
                  rowsBits(30, 31), {{30, ~0u, ~0u}, {31, ~0u, ~0u}}});
    cs.push_back({"a point in row 30: no shift", Tri(7.5f, 30.25f, 7.5f, 30.25f, 7.5f, 30.25f), 0, 0, rowsBits(30, 30),
                  {{30, ~0u, ~0u}}});
    cs.push_back({"row 31 + 3/4: rows 30, 31 here", Tri(7.5f, 31.75f, 7.5f, 31.75f, 7.5f, 31.75f), 0, 0,
                  rowsBits(30, 31), {{30, ~0u, ~0u}, {31, ~0u, ~0u}}});
    cs.push_back({"row 31 + 3/4: row 0 of the tile below", Tri(7.5f, 31.75f, 7.5f, 31.75f, 7.5f, 31.75f, 0, 1), 0, 0,
                  rowsBits(0, 0), {{0, ~0u, ~0u}}});
    {
        Case c{"a modifier volume point: every row (sliver36)", Tri(7.5f, 31.25f, 7.5f, 31.25f, 7.5f, 31.25f), 0, 0,
               ~0u, {}};
        c.j.modvol = true;
        for (int y = 0; y < 32; y++)
            c.want.push_back({y, ~0u, ~0u});
        cs.push_back(c);
    }
    // a tiny triangle with its top corner in row 31 starts at row 30 too: rows 30 .. 31 rasterized (edge2_walk page 6)
    cs.push_back({"row-31 shift of a tiny triangle", Tri(7.5f, 31.5f, 7.5009765625f, 31.5f, 7.5f, 31.5009765625f), 0, 0,
                  rowsBits(30, 31), {}});
    // column 31 by the column step (covmeas rule 8): a left edge x = 31.5 through column 31's centres is in there
    // (rows 2 .. 19; row 20 is the corner, out by the hypotenuse's step), a right edge there out
    {
        Case c{"column 31, left edge (covmeas 8)", Tri(31.5f, 2.5f, 50.5f, 2.5f, 31.5f, 20.5f), 0, 0, rowsBits(2, 21),
               {}};
        for (int y = 2; y <= 21; y++)
            c.want.push_back({y, y <= 19 ? 0x80000000u : 0u, ~0u});
        cs.push_back(c);
        Case d{"column 31, right edge (covmeas 8)", Tri(31.5f, 2.5f, 12.5f, 2.5f, 31.5f, 20.5f), 0, 0, rowsBits(2, 21),
               {}};
        for (int y = 2; y <= 19; y++)
            d.want.push_back({y, 0u, 0x80000000u});
        cs.push_back(d);
    }
    // the culls on det = 1 (legs of one pixel): raster page 4 (equal is culled), cullval (the register's size only:
    // -1 is 1; NaN and infinity cull every triangle; 2^-149 culls nothing), the facings on the swamped determinant
    struct CullCase { const char* what; uint32_t val; int mode; bool flipW; int culled; };
    const CullCase cc[] = {
        {"cull equal (raster page 4)", 0x3F800000, 1, false, 1}, {"cull just below (raster page 4)", 0x3F7FFFFF, 1, false, 0},
        {"cull -1 as 1 (cullval)", 0xBF800000, 1, false, 1},      {"cull NaN culls all (cullval)", 0x7FC00000, 1, false, 1},
        {"cull -inf culls all (cullval)", 0xFF800000, 1, false, 1}, {"cull 2^-149 (cullval)", 0x00000001, 1, false, 0},
        {"facing 3 culls det > 0", 0, 3, false, 1},               {"facing 2 keeps det > 0", 0, 2, false, 0},
        {"facing 2 culls det < 0", 0, 2, true, 1},                {"facing 3 keeps det < 0", 0, 3, true, 0},
        {"mode 0 culls nothing", 0x7F800000, 0, false, 0},
    };
    for (const CullCase& q : cc) {
        Case c{q.what, q.flipW ? Tri(0, 0, 0, 1, 1, 0) : Tri(0, 0, 1, 0, 0, 1), 0, q.culled, ~0u, {}};
        c.j.cull = q.mode;
        c.j.cullVal = q.val;
        cs.push_back(c);
    }
    // huge: an infinity or a NaN among the corners draws nothing and is not culled
    {
        Case c{"bad corner (huge)", Tri(0, 0, 1, 0, 0, 1), 1, 0, ~0u, {}};
        c.j.x[1] = 0x7F800000;
        c.j.cull = 1;
        c.j.cullVal = 0x7F800000;
        cs.push_back(c);
        Case d{"bad 4th corner of a quad (huge)", Tri(0, 0, 8, 0, 8, 8), 1, 0, ~0u, {}};
        d.j.quad = true;
        d.j.x[3] = fb(0);
        d.j.y[3] = 0x7FC00000;
        cs.push_back(d);
    }

    // the walk on given descriptors (half units of 2^102: H = 2^30 = 2^131, Z = 2^7 = 2^108)
    struct DCase { const char* what; Job j; std::vector<RowWant> want; };
    std::vector<DCase> ds;
    {
        // faredge_m131: R + 16 sx at exactly -2^131 is not pushed (row = lanes(R): pixel 0 only), 2 units below it is
        // (R + 2^132: all 32); at exactly +2^131 it is pushed (R - 2^132: none), 2 units below not (all but pixel 0)
        const int64_t a = (int64_t)1 << 24, s = ((int64_t)1 << 26) + ((int64_t)1 << 20);
        ds.push_back({"-2^131 not pushed (faredge_m131)", Desc(BigEdge(a, -s, 0), 0, 0), {{0, 0x1u, ~0u}}});
        ds.push_back({"below -2^131 pushed", Desc(BigEdge(a - 2, -s, 0), 0, 0), {{0, ~0u, ~0u}}});
        ds.push_back({"+2^131 pushed (faredge_m131)", Desc(BigEdge(-a, s, 0), 0, 0), {{0, 0u, ~0u}}});
        ds.push_back({"below +2^131 not pushed", Desc(BigEdge(-a - 2, s, 0), 0, 0), {{0, ~1u, ~0u}}});
        // hugepos_rules: R wraps by 2^132; a column step of 0: rows 0 .. 14 inside, row 15 wraps to -2^131 (none) and
        // ends the edge (the far value falls from above ZERO), so rows 16 .. 31 stay outside
        std::vector<RowWant> w;
        for (int y = 0; y < 32; y++)
            w.push_back({y, y <= 14 ? ~0u : 0u, ~0u});
        ds.push_back({"R wraps, then the end (hugepos_rules)", Desc(BigEdge((int64_t)1 << 26, 0, (int64_t)1 << 26)), w});
        // edge2_walk pages 0-2, edge2_end, edge2_mult: a column step of -2^126 (a multiple of 2^126): the far value is
        // R + 2^131 and the edge does not end where R turns negative; it is inside again where R has wrapped (row j >=
        // 17: the first 2 (33 - j) pixels, at most 32). A column step of -3 2^124 (an odd multiple of 2^124): R alone, the
        // edge ends after row 1 and every later row is outside. Row 0: pixels 0, 1 / 0 .. 2
        const int64_t ty = -(((int64_t)1 << 26) + 1024);
        std::vector<RowWant> m126, m124;
        for (int y = 0; y < 32; y++) {
            const int n = y == 0 ? 2 : y < 17 ? 0 : std::min(32, 2 * (33 - y));
            m126.push_back({y, n >= 32 ? ~0u : ((1u << n) - 1), ~0u});
            m124.push_back({y, y == 0 ? 0x7u : 0u, ~0u});
        }
        ds.push_back({"far value R + 2^131: sx = -2^126 (edge2_end)", Desc(BigEdge((int64_t)1 << 26, -((int64_t)1 << 25), ty)),
                      m126});
        ds.push_back({"far value R: sx = -3 2^124 (edge2_mult)", Desc(BigEdge((int64_t)1 << 26, -3 * ((int64_t)1 << 23), ty)),
                      m124});
        // edge2_walk pages 3-5: a start of 0 and a column step of one unit, R + 32 sx = 2^107 in the first row, not above
        // ZERO: the edge does not end in the next row, and where R has wrapped (rows 17 .. 31) the rows are inside
        std::vector<RowWant> z;
        for (int y = 0; y < 32; y++)
            z.push_back({y, y >= 17 ? ~0u : 0u, ~0u});
        ds.push_back({"the end against ZERO (edge2_walk 3-5)", Desc(BigEdge(0, 2, -((int64_t)1 << 26))), z});
    }

    std::vector<Job> jobs;
    for (auto& c : cs)
        jobs.push_back(c.j);
    for (auto& d : ds)
        jobs.push_back(d.j);
    std::vector<Out> outs;
    dut.run(jobs, outs);
    long id = 0;
    for (size_t i = 0; i < cs.size(); i++, id++) {
        const Case& c = cs[i];
        const Out& o = outs[i];
        if (c.bad >= 0)
            F->ok(o.bad == (c.bad != 0), "%s: bad %d, want %d", c.what, o.bad, c.bad);
        if (c.culled >= 0 && !c.bad)
            F->ok(o.culled == (c.culled != 0), "%s: culled %d, want %d", c.what, o.culled, c.culled);
        if (c.rows != ~0u)
            F->ok(o.rowsSeen == c.rows, "%s: rows %08x, want %08x", c.what, o.rowsSeen, c.rows);
        for (const RowWant& r : c.want)
            F->ok(((o.mask[r.row] ^ r.mask) & r.care) == 0, "%s: row %d mask %08x, want %08x (care %08x)", c.what, r.row,
                  o.mask[r.row], r.mask, r.care);
        // the literals are refsw3's too
        Ref f;
        RefSetup(c.j, f);
        if (c.rows != ~0u)
            F->ok(f.rows == c.rows, "%s: refsw3's rows %08x differ from the literal %08x", c.what, f.rows, c.rows);
        for (const RowWant& r : c.want)
            F->ok(((f.mask[r.row] ^ r.mask) & r.care) == 0, "%s: refsw3's row %d %08x differs from the literal", c.what,
                  r.row, f.mask[r.row]);
        if (c.culled >= 0 && !c.bad)
            F->ok(f.r.culled == (c.culled != 0), "%s: refsw3's cull %d differs from the literal", c.what, f.r.culled);
        if (c.bad >= 0)
            F->ok(f.bad == (c.bad != 0), "%s: refsw3's bad %d differs from the literal", c.what, f.bad);
        Ref g;
        CheckSetup(c.j, o, g, c.what, 0);
    }
    for (size_t i = 0; i < ds.size(); i++) {
        const DCase& d = ds[i];
        const Out& o = outs[cs.size() + i];
        for (const RowWant& r : d.want)
            F->ok(((o.mask[r.row] ^ r.mask) & r.care) == 0, "%s: row %d mask %08x, want %08x", d.what, r.row,
                  o.mask[r.row], r.mask);
        Ref f;
        RefRaster(d.j, f);
        for (const RowWant& r : d.want)
            F->ok(((f.mask[r.row] ^ r.mask) & r.care) == 0, "%s: refsw3's row %d %08x differs from the literal %08x",
                  d.what, r.row, f.mask[r.row], r.mask);
        CheckRows(f, o, d.what, 0);
    }
    printf("isp_edge: section directed %zu cases\n", cs.size() + ds.size());
}

// ---------------------------------------------------------------------------------------------------------------
// covmeas: the archived console sets, composed as dreamcast-tests model/covprobe composes a page (its renderPage,
// trianglePage and run, with the RTL's masks where covprobe calls EdgeTile::Inside)
struct Poly { int page = 0, n = 3; float x[4] = {}, y[4] = {}; };
struct CovSet {
    std::string name;
    int prim = 0, halfofs = 7, pages = 0;
    float zs[3] = {1, 1, 1}, probez = 0.5f;
    std::vector<Poly> polys;
    std::vector<uint8_t> cov;
};

bool LoadSet(const std::string& dir, const std::string& name, CovSet& s, std::string* err)
{
    p2npz::Npz z;
    if (!z.open(dir + "/" + name + ".npz")) {
        *err = z.error;
        return false;
    }
    std::vector<uint8_t> jt;
    if (!p2npz::ReadFile(dir + "/" + name + ".cases.json", &jt)) {
        *err = "no " + name + ".cases.json";
        return false;
    }
    p2npz::JsonTop j;
    if (!j.parse(std::string(jt.begin(), jt.end()))) {
        *err = "bad json";
        return false;
    }
    static const char* const kPrims[] = {"tri", "strip", "sprite", "modvol", "zprobe"};
    const std::string prim = j.str("prim", "tri");
    s.prim = -1;
    for (int k = 0; k < 5; k++)
        if (prim == kPrims[k])
            s.prim = k;
    if (s.prim < 0) {
        *err = "prim " + prim;
        return false;
    }
    s.name = name;
    s.halfofs = (int)j.num("halfofs", 7);
    s.probez = (float)j.num("probez", 0.5);
    const float z1 = (float)j.num("z", 1.0);
    std::string zs = j.str("zs", "");
    for (int k = 0; k < 3; k++)
        s.zs[k] = z1;
    if (!zs.empty()) {
        float a, b, c;
        if (sscanf(zs.c_str(), "%f,%f,%f", &a, &b, &c) == 3)
            s.zs[0] = a, s.zs[1] = b, s.zs[2] = c;
    }
    p2npz::Array tx, ty, pg, cv;
    if (!z.array("tx", &tx) || !z.array("ty", &ty) || !z.array("page", &pg) ||
        !z.array(s.prim == 4 ? "isp" : "cov", &cv)) {
        *err = z.error;
        return false;
    }
    const int n = (int)tx.shape[1];
    s.polys.resize(tx.shape[0]);
    for (size_t k = 0; k < s.polys.size(); k++) {
        Poly& p = s.polys[k];
        p.page = (int)pg.i64(k);
        p.n = n;
        for (int c = 0; c < n; c++) {
            p.x[c] = (float)tx.f64(k * n + c);
            p.y[c] = (float)ty.f64(k * n + c);
        }
    }
    s.pages = (int)cv.shape[0];
    s.cov.resize(cv.count());
    for (size_t k = 0; k < s.cov.size(); k++)
        s.cov[k] = cv.u8(k) != 0;
    return true;
}

// one polygon of a page as the core takes it (covprobe's Prim)
struct Prim { float x[4], y[4], z[3]; int n; uint32_t argb; bool greater, zwrite, modvol; };

// the RTL's inside masks of every polygon in every tile its corners' bounding box touches on the 640 x 480 screen
// (covprobe's raster(): the TA's tiles): masks[p] holds (tile, 32 rows) pairs
struct TileMask { int tx, ty; uint32_t m[32]; };
void RtlRaster(Dut& dut, const std::vector<Prim>& prims, int half, std::vector<std::vector<TileMask>>& masks)
{
    std::vector<Job> jobs;
    std::vector<std::pair<int, int>> who;       // (prim, tile index)
    masks.assign(prims.size(), {});
    for (size_t p = 0; p < prims.size(); p++) {
        const Prim& q = prims[p];
        float xmin = 1e30f, xmax = -1e30f, ymin = 1e30f, ymax = -1e30f;
        for (int i = 0; i < q.n; i++) {
            xmin = std::min(xmin, q.x[i]); xmax = std::max(xmax, q.x[i]);
            ymin = std::min(ymin, q.y[i]); ymax = std::max(ymax, q.y[i]);
        }
        if (xmax < 0 || ymax < 0 || xmin >= 640 || ymin >= 480)
            continue;
        const int tx0 = xmin < 0 ? 0 : (int)(xmin / 32), tx1 = xmax >= 640 ? 19 : (int)(xmax / 32);
        const int ty0 = ymin < 0 ? 0 : (int)(ymin / 32), ty1 = ymax >= 480 ? 14 : (int)(ymax / 32);
        for (int ty = ty0; ty <= ty1; ty++)
            for (int tx = tx0; tx <= tx1; tx++) {
                Job j;
                for (int i = 0; i < q.n; i++) {
                    j.x[i] = fb(q.x[i]);
                    j.y[i] = fb(q.y[i]);
                }
                j.quad = q.n == 4;
                j.modvol = q.modvol;
                j.half = half;
                j.tileX = tx;
                j.tileY = ty;
                jobs.push_back(j);
                TileMask t;
                t.tx = tx;
                t.ty = ty;
                masks[p].push_back(t);
                who.push_back({(int)p, (int)masks[p].size() - 1});
            }
    }
    std::vector<Out> outs;
    dut.run(jobs, outs);
    for (size_t i = 0; i < jobs.size(); i++) {
        TileMask& t = masks[who[i].first][who[i].second];
        for (int y = 0; y < 32; y++)
            t.m[y] = (outs[i].rowsSeen >> y & 1) ? outs[i].mask[y] : 0;
        F->ok(outs[i].orderErrors == 0, "covmeas: row order errors");
    }
}

// covprobe renderPage: the ISP in list order (depth compare ALWAYS or GREATER, StoredDepth order), then the TSP's
// colour of every pixel per span (refsw3's planes, Divide, ColorRounded)
void RenderPage(Dut& dut, const std::vector<Prim>& prims, int halfofs, uint32_t* rgb)
{
    const int half = halfofs & 1;
    std::vector<std::vector<TileMask>> masks;
    RtlRaster(dut, prims, half, masks);
    const pvrisp::StoredDepth background = pvrisp::StoredDepth::Bits(0x38d1b717u & ~0x1ffffu);
    std::vector<pvrisp::StoredDepth> z(480 * 640, background);
    std::vector<int> tag(480 * 640, -1);
    static const pvrisp::DepthHW dcfg;
    for (size_t k = 0; k < prims.size(); k++) {
        const Prim& q = prims[k];
        for (const TileMask& t : masks[k]) {
            pvrisp::DepthTileT<pvrisp::DepthHW> depth;
            const bool needZ = q.greater || q.zwrite;
            if (needZ) {
                const uint32_t zx[3] = {fb(q.x[0]), fb(q.x[1]), fb(q.x[2])}, zy[3] = {fb(q.y[0]), fb(q.y[1]), fb(q.y[2])},
                               zz[3] = {fb(q.z[0]), fb(q.z[1]), fb(q.z[2])};
                depth.Setup(zx, zy, zz, t.tx * 32, t.ty * 32, dcfg, half != 0);
            }
            for (int j = 0; j < 32; j++)
                for (int i = 0; i < 32; i++) {
                    if (!(t.m[j] >> i & 1))
                        continue;
                    const int at = (t.ty * 32 + j) * 640 + t.tx * 32 + i;
                    if (needZ) {
                        const pvrisp::StoredDepth d = depth.At(i, j, half != 0);
                        if (q.greater && !(d > z[at]))
                            continue;
                        if (q.zwrite)
                            z[at] = d;
                    }
                    tag[at] = (int)k;
                }
        }
    }
    for (int at = 0; at < 480 * 640; at++)
        rgb[at] = tag[at] < 0 ? 0 : prims[tag[at]].argb & 0xffffff;
    static const pvrtsp::PlaneHW pcfg;
    const int th = (halfofs >> 2) & 1;
    for (int ty = 0; ty < 15; ty++)
        for (int tx = 0; tx < 20; tx++) {
            const int left = tx * 32, top = ty * 32;
            std::map<int, std::vector<pvrtsp::PlaneT<pvrtsp::PlaneHW>>> planes;
            for (int j = 0; j < 32; j++)
                for (int i = 0; i < 32;) {
                    const int at0 = (top + j) * 640 + left + i, k = tag[at0];
                    int len = 1;
                    while (i + len < 32 && tag[at0 + len] == k)
                        len++;
                    if (k >= 0) {
                        const Prim& q = prims[k];
                        const uint32_t px3[3] = {fb(q.x[0]), fb(q.x[1]), fb(q.x[2])},
                                       py3[3] = {fb(q.y[0]), fb(q.y[1]), fb(q.y[2])},
                                       pz3[3] = {fb(q.z[0]), fb(q.z[1]), fb(q.z[2])};
                        auto& pl = planes[k];
                        if (pl.empty()) {
                            pl.resize(4);
                            pl[0].Setup(px3, py3, pz3, nullptr, pcfg);
                            for (int c = 0; c < 3; c++) {
                                const uint32_t a = pvrfp::SingleBits((q.argb >> (16 - 8 * c)) & 255, -8),
                                               at3[3] = {a, a, a};
                                pl[1 + c].Setup(px3, py3, pz3, at3, pcfg);
                            }
                        }
                        const int64_t x0h = 2 * (int64_t)(left + i) + th, yh = 2 * (int64_t)(top + j) + th;
                        for (int n = 0; n < len; n++) {
                            const Fp w = pl[0].Value(x0h, yh, n, left, top);
                            uint32_t px = 0;
                            for (int c = 0; c < 3; c++) {
                                const int fbk = (q.argb >> (16 - 8 * c)) & 255;
                                const int v = pvrtsp::ColorRounded(pvrtsp::Divide(pl[1 + c].Value(x0h, yh, n, left, top), w),
                                                                   -8, 65535, fbk);
                                px |= (uint32_t)(v > 255 ? 255 : v) << (16 - 8 * c);
                            }
                            rgb[at0 + n] = px;
                        }
                    }
                    i += len;
                }
        }
}

// one page of a set as the console drew it, read as covmeas read.py reads it
void CovPage(Dut& dut, const CovSet& s, int pageNo, uint8_t* page)
{
    std::vector<Prim> prims;
    if (s.prim == 2 || s.prim == 3) {
        // sprites and modifier volumes: the ISP alone (covprobe), the union of the polygons' insides
        for (const Poly& p : s.polys) {
            if (p.page != pageNo)
                continue;
            Prim q = {};
            q.n = s.prim == 2 ? 4 : 3;
            for (int i = 0; i < q.n; i++) {
                q.x[i] = p.x[i];
                q.y[i] = p.y[i];
            }
            q.modvol = s.prim == 3;
            prims.push_back(q);
        }
        std::vector<std::vector<TileMask>> masks;
        RtlRaster(dut, prims, s.halfofs & 1, masks);
        memset(page, 0, 480 * 640);
        for (const auto& ts : masks)
            for (const TileMask& t : ts)
                for (int j = 0; j < 32; j++)
                    for (int i = 0; i < 32; i++)
                        if (t.m[j] >> i & 1)
                            page[(t.ty * 32 + j) * 640 + t.tx * 32 + i] = 1;
        return;
    }
    static const int tris[2][3] = {{0, 1, 2}, {2, 1, 3}};       // a strip's second triangle as refsw3 takes it
    for (const Poly& p : s.polys) {
        if (p.page != pageNo)
            continue;
        for (int t = 0; t < (s.prim == 1 ? 2 : 1); t++) {
            Prim q = {};
            q.n = 3;
            for (int i = 0; i < 3; i++) {
                q.x[i] = p.x[tris[t][i]];
                q.y[i] = p.y[tris[t][i]];
                q.z[i] = s.prim == 1 ? s.zs[0] : s.zs[i];
            }
            q.argb = s.prim == 4 ? 0xffff0000u : 0xffffffffu;
            q.zwrite = s.prim == 4;
            prims.push_back(q);
        }
    }
    if (s.prim == 4) {
        const float qx[2][3] = {{0, 640, 0}, {0, 640, 640}}, qy[2][3] = {{0, 0, 480}, {480, 0, 480}};
        for (int t = 0; t < 2; t++) {
            Prim q = {};
            q.n = 3;
            for (int i = 0; i < 3; i++) {
                q.x[i] = qx[t][i];
                q.y[i] = qy[t][i];
                q.z[i] = s.probez;
            }
            q.argb = 0xff00ff00u;
            q.greater = true;
            prims.push_back(q);
        }
    }
    std::vector<uint32_t> rgb(480 * 640);
    RenderPage(dut, prims, s.halfofs, rgb.data());
    for (int at = 0; at < 480 * 640; at++)
        page[at] = s.prim == 4 ? ((rgb[at] >> 8) & 255) < 128 : (rgb[at] & 0xffffff) != 0;
}

std::vector<std::string> ListDir(const std::string& dir, const std::string& suffix)
{
    std::vector<std::string> v;
    DIR* d = opendir(dir.c_str());
    if (!d)
        return v;
    while (dirent* e = readdir(d)) {
        const std::string n = e->d_name;
        if (n.size() > suffix.size() && n.compare(n.size() - suffix.size(), suffix.size(), suffix) == 0)
            v.push_back(n.substr(0, n.size() - suffix.size()));
    }
    closedir(d);
    std::sort(v.begin(), v.end());
    return v;
}

void Covmeas(Dut& dut, const std::string& dir)
{
    F->set("covmeas");
    const std::vector<std::string> names = ListDir(dir, ".npz");
    F->ok(!names.empty(), "covmeas: no sets in %s", dir.c_str());
    long sets = 0, pixels = 0, drawn = 0, wrong = 0;
    // quick: one set in four, and the first of every (prim, halfofs) class among the others
    std::vector<bool> pick(names.size(), A->full);
    std::map<std::string, bool> classSeen;
    for (size_t k = 0; k < names.size() && !A->full; k++) {
        std::vector<uint8_t> jt;
        p2npz::JsonTop j;
        if (p2npz::ReadFile(dir + "/" + names[k] + ".cases.json", &jt))
            j.parse(std::string(jt.begin(), jt.end()));
        const std::string cls = j.str("prim", "tri") + "/" + j.str("halfofs", "7");
        pick[k] = k % 4 == 0 || !classSeen[cls];
        classSeen[cls] = true;
    }
    for (size_t k = 0; k < names.size(); k++) {
        if (!pick[k])
            continue;
        if (!A->mine(k))
            continue;
        CovSet s;
        std::string err;
        if (!F->ok(LoadSet(dir, names[k], s, &err), "covmeas %s: %s", names[k].c_str(), err.c_str()))
            continue;
        std::vector<uint8_t> page(480 * 640);
        long setWrong = 0;
        for (int pg = 0; pg < s.pages; pg++) {
            CovPage(dut, s, pg, page.data());
            const uint8_t* c = s.cov.data() + (size_t)pg * 480 * 640;
            long w = 0;
            int first = -1;
            for (int at = 0; at < 480 * 640; at++) {
                drawn += c[at];
                if (page[at] != c[at]) {
                    if (first < 0)
                        first = at;
                    w++;
                }
            }
            pixels += 480 * 640;
            setWrong += w;
            F->ok(w == 0, "covmeas %s page %d: %ld pixels differ from the console (first (%d, %d): console %d)",
                  s.name.c_str(), pg, w, first % 640, first / 640, first >= 0 ? c[first] : 0);
        }
        wrong += setWrong;
        sets++;
        printf("isp_edge: covmeas %-16s prim %d halfofs %d pages %d polygons %5zu: %ld pixels differ\n", s.name.c_str(),
               s.prim, s.halfofs, s.pages, s.polys.size(), setWrong);
    }
    printf("isp_edge: section covmeas %ld cases (%zu sets in %s; %ld pixels, %ld drawn on the console, %ld differ)\n",
           sets, names.size(), dir.c_str(), pixels, drawn, wrong);
}

// ---------------------------------------------------------------------------------------------------------------
// tria: the console pages' own primitives
void Tria(Dut& dut, const std::string& dir)
{
    F->set("tria");
    const std::vector<std::string> names = ListDir(dir, ".tri");
    F->ok(!names.empty(), "tria: no .tri files in %s (tools/gate/tria_extract.sh)", dir.c_str());
    long id = 0, recs = 0, global = 0;
    std::vector<Job> jobs;
    for (const std::string& n : names) {
        std::vector<uint8_t> raw;
        uint64_t count = 0;
        if (!F->ok(p2tb::VecFile::read(dir + "/" + n + ".tri", p2tri::kTriMagic, sizeof(p2tri::TriRec), &raw, &count),
                   "tria %s: cannot read", n.c_str()))
            continue;
        const p2tri::TriRec* r = (const p2tri::TriRec*)raw.data();
        long used = 0;
        for (uint64_t i = 0; i < count; i++, global++) {
            if (!A->full && i % 8 != 0)
                continue;
            if (!A->mine(global))
                continue;
            Job j;
            for (int c = 0; c < 4; c++) {
                j.x[c] = r[i].x[c];
                j.y[c] = r[i].y[c];
            }
            j.quad = r[i].quad;
            j.modvol = r[i].modvol;
            j.cull = (r[i].isp >> 27) & 3;
            j.cullVal = r[i].cullVal;
            j.half = r[i].halfOffset & 1;
            j.tileX = r[i].tileX;
            j.tileY = r[i].tileY;
            jobs.push_back(j);
            used++;
            if (jobs.size() >= 4096) {
                std::string ctx = "tria " + n;
                RunChecked(dut, jobs, ctx.c_str(), &id);
            }
        }
        std::string ctx = "tria " + n;
        RunChecked(dut, jobs, ctx.c_str(), &id);
        recs += used;
        printf("isp_edge: tria %-16s %6lu records, %6ld here\n", n.c_str(), (unsigned long)count, used);
    }
    printf("isp_edge: section tria %ld cases (%zu tests)\n", recs, names.size());
    PrintWidths("tria");
}

// ---------------------------------------------------------------------------------------------------------------
// directed, setup level: the console's own pixels as the literal. The tiles of given pages of the faredge_*, hugepos_a
// and edge2_* tests (one triangle per tile, user-clipped to it, untextured, depth always, on a known background) go
// through p2_isp_edge_setup and p2_isp_edge_raster from their corners (build/vec/<test>.tri), and every row of every
// such tile must equal the console's page (dreamcast-tests fit/hw/<test>/page<n>.hw.raw.gz: 640 x 480 words 0x00RRGGBB;
// a pixel is drawn where it is not the background, or, for hugepos_a, where it is white). refsw3 is checked against
// the same pixels (it has no residual on these pages at 4f3efe15) and CheckSetup compares the RTL with it on the way.
// Each entry also counts, from the corners alone and from the RTL's descriptors, the mechanism its fact is about, and
// fails if that count is zero (the case would not exercise the rule):
//   swamp   a start product xb ya or xa yb of 2^128 or more (the swamp); x128: one of exactly 2^128 after the cut to
//           24 bits; cancel: both of one sign (they cancel in c = xb ya - xa yb); sat: a coordinate difference of
//           2^128 or more (stepping by +-2^127); big: an edge whose E was cut to 129 (the RTL's descriptor);
//           row31: a polygon whose first row in the tile is 31, started at row 30 (the RTL's jf)
struct ConsolePage {
    const char* test;
    const char* fact;
    std::vector<int> pages;
    std::vector<std::pair<int, int>> tiles;     // (tx, ty); empty: every tile with a record
    uint32_t bg;                                // the background; 0xFFFFFFFF: drawn = white (hugepos_a)
    std::vector<long> drawn;                    // per page: the console's drawn pixels in the compared tiles (-1: any)
    const char* need;                           // the mechanism counter that must be non-zero
};

bool ReadPage(const std::string& path, std::vector<uint32_t>& px)
{
    px.assign(640 * 480, 0);
    gzFile g = gzopen(path.c_str(), "rb");
    if (!g)
        return false;
    const int want = 640 * 480 * 4;
    const int got = gzread(g, px.data(), want);
    gzclose(g);
    return got == want;
}

void ConsolePages(Dut& dut, const std::string& vecDir, const std::string& dct)
{
    F->set("directed");
    const ConsolePage list[] = {
        {"hugepos_a", "isp 8.3 the saturation at 2^127: triangle a at M = 2^118 .. 2^124, 15,019 / 705 / 15 / 2 pixels",
         {11, 12, 13, 14}, {}, 0xFFFFFFFF, {15019, 705, 15, 2}, "swamp"},
        {"faredge_cmax", "the swamp: products of exactly 2^128 (group A) saturate; two of one sign cancel (pages 11, 14, 15)",
         {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {}, 0x204060, {}, "x128"},
        {"faredge_cmax", "two swamped products of one sign cancel exactly (pages 11, 14, 15)", {11, 14, 15}, {}, 0x204060,
         {}, "cancel"},
        {"faredge_k132", "RV tiles: swamped products of opposite signs cancel, the start 0, the rows j dx (+ the push, K)",
         {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {}, 0x204060, {}, "swamp"},
        {"faredge_ecap", "E capped at 129 (EC, pages 0-5: E 130 .. 133 before the cut)", {0, 1, 2, 3, 4, 5}, {}, 0x204060,
         {}, "big"},
        {"faredge_ecap", "R reaches -2^131 exactly and the edge ends (pages 7, 9 tiles (0,4), (0,9))", {7, 9},
         {{0, 4}, {0, 9}}, 0x204060, {}, "big"},
        {"faredge_m131", "-2^131 not pushed, +2^131 pushed (pages 0-5); 32 sx = 2^132 + rho (pages 6-15)",
         {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {}, 0x204060, {}, "big"},
        {"faredge_walk", "the row-31 shift (pages 0-3: top corners in rows 28 .. 31 of the tile)", {0, 1, 2, 3}, {},
         0x204060, {}, "row31"},
        {"faredge_walk", "the end with 32 sx mod 2^131, from the polygon's first row (pages 4-15)",
         {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {}, 0x204060, {}, "big"},
        {"edge2_walk", "sx = -2^127 saturated or not: R + 2^131 (pages 0-2); the 2^102 grid and the end against ZERO "
         "(pages 3-5); the row-31 shift without a big edge (page 6)", {0, 1, 2, 3, 4, 5, 6}, {}, 0x204060, {}, "big"},
        {"edge2_walk", "the row-31 shift of every polygon (page 6)", {6}, {}, 0x204060, {}, "row31"},
        {"edge2_end", "the far value with sx < 0: R + 2^131 for -2^127 (page 0) and -2^126 / -1.5 2^127 (page 2); rows "
         "reaching -2^131 exactly or nearly end (page 1)", {0, 1, 2}, {}, 0x204060, {}, "big"},
        {"edge2_end", "R alone near -2^127 (page 3: -2^127 (1 +- 2^-19 .. 2^-8)) and for +2^127 (page 4)", {3, 4}, {},
         0x204060, {}, "big"},
        {"edge2_mult", "odd multiples of 2^125 and 2^124: R alone", {0, 1}, {}, 0x204060, {}, "big"},
        {"edge2_row31", "the row-31 shift of points and tiny triangles, with and without a clip", {0}, {}, 0x204060, {},
         "row31"},
    };
    const double P128 = ldexp(1.0, 128);
    long cases = 0;
    for (const ConsolePage& cp : list) {
        std::vector<uint8_t> raw;
        uint64_t count = 0;
        if (!F->ok(p2tb::VecFile::read(vecDir + "/" + cp.test + ".tri", p2tri::kTriMagic, sizeof(p2tri::TriRec), &raw,
                                       &count),
                   "directed console %s: cannot read %s/%s.tri (tools/gate/tria_extract.sh)", cp.test, vecDir.c_str(),
                   cp.test))
            continue;
        const p2tri::TriRec* r = (const p2tri::TriRec*)raw.data();
        std::map<std::string, long> mech;
        long tilesCmp = 0, rtlWrong = 0, refWrong = 0, recs = 0;
        for (size_t pi = 0; pi < cp.pages.size(); pi++) {
            const int page = cp.pages[pi];
            std::vector<uint32_t> px;
            const std::string path = dct + "/fit/hw/" + cp.test + "/page" + std::to_string(page) + ".hw.raw.gz";
            if (!F->ok(ReadPage(path, px), "directed console: cannot read %s", path.c_str()))
                continue;
            auto drawnAt = [&](int x, int y) {
                const uint32_t v = px[y * 640 + x] & 0xFFFFFF;
                return cp.bg == 0xFFFFFFFF ? v == 0xFFFFFF : v != cp.bg;
            };
            std::vector<Job> jobs;
            for (uint64_t i = 0; i < count; i++) {
                if (r[i].render != page)
                    continue;
                if (!cp.tiles.empty() &&
                    std::find(cp.tiles.begin(), cp.tiles.end(), std::make_pair((int)r[i].tileX, (int)r[i].tileY)) ==
                        cp.tiles.end())
                    continue;
                Job j;
                for (int c = 0; c < 4; c++) {
                    j.x[c] = r[i].x[c];
                    j.y[c] = r[i].y[c];
                }
                j.quad = r[i].quad;
                j.modvol = r[i].modvol;
                j.cull = (r[i].isp >> 27) & 3;
                j.cullVal = r[i].cullVal;
                j.half = r[i].halfOffset & 1;
                j.tileX = r[i].tileX;
                j.tileY = r[i].tileY;
                jobs.push_back(j);
            }
            F->ok(!jobs.empty(), "directed console %s page %d: no records", cp.test, page);
            std::vector<Out> outs;
            dut.run(jobs, outs);
            recs += (long)jobs.size();
            // per tile: the RTL's and refsw3's union of masks
            std::map<std::pair<int, int>, std::pair<std::array<uint32_t, 32>, std::array<uint32_t, 32>>> tm;
            for (size_t i = 0; i < jobs.size(); i++) {
                const Job& j = jobs[i];
                const Out& o = outs[i];
                Ref f;
                std::string ctx = std::string("directed console ") + cp.test + " page " + std::to_string(page);
                CheckSetup(j, o, f, ctx.c_str(), (long)i);
                auto& t = tm[{j.tileX, j.tileY}];
                for (int y = 0; y < 32; y++) {
                    t.first[y] |= o.mask[y];
                    t.second[y] |= f.mask[y];
                }
                // the mechanisms, from the corners
                const int n = j.quad ? 4 : 3;
                bool sw = false, x128 = false, cancel = false, sat = false, big = false;
                for (int k = 0; k < n; k++) {
                    const double xa = bf(j.x[k]), ya = bf(j.y[k]), xb = bf(j.x[(k + 1) % n]), yb = bf(j.y[(k + 1) % n]);
                    const double p1 = xb * ya, p2 = xa * yb;     // exact: 24 x 24 bits in a double
                    const bool s1 = fabs(p1) >= P128, s2 = fabs(p2) >= P128;
                    sw |= s1 || s2;
                    x128 |= (s1 && fabs(p1) < P128 + ldexp(1.0, 105)) || (s2 && fabs(p2) < P128 + ldexp(1.0, 105));
                    cancel |= s1 && s2 && ((p1 < 0) == (p2 < 0));
                    sat |= fabs(xa - xb) >= P128 || fabs(ya - yb) >= P128;
                    big |= o.e[k].big && !o.e[k].cv;
                }
                double ymin = 1e300;
                for (int k = 0; k < n; k++)
                    ymin = std::min(ymin, (double)bf(j.y[k]));
                const bool row31 = !j.modvol && o.rowsV && o.jf == 30 && floor(ymin) - 32.0 * j.tileY == 31;
                mech["swamp"] += sw;
                mech["x128"] += x128;
                mech["cancel"] += cancel;
                mech["sat"] += sat;
                mech["big"] += big;
                mech["row31"] += row31;
            }
            long drawn = 0;
            for (auto& [tile, masks] : tm) {
                tilesCmp++;
                bool rtlOk = true, refOk = true;
                for (int y = 0; y < 32; y++) {
                    uint32_t want = 0;
                    for (int x = 0; x < 32; x++)
                        if (drawnAt(32 * tile.first + x, 32 * tile.second + y))
                            want |= 1u << x;
                    drawn += __builtin_popcount(want);
                    rtlOk &= masks.first[y] == want;
                    refOk &= masks.second[y] == want;
                    F->ok(masks.first[y] == want, "directed console %s page %d tile (%d,%d) row %d: RTL %08x, the console "
                          "%08x (%s)", cp.test, page, tile.first, tile.second, y, masks.first[y], want, cp.fact);
                    F->ok(masks.second[y] == want, "directed console %s page %d tile (%d,%d) row %d: refsw3 %08x, the "
                          "console %08x", cp.test, page, tile.first, tile.second, y, masks.second[y], want);
                }
                rtlWrong += !rtlOk;
                refWrong += !refOk;
            }
            if (pi < cp.drawn.size()) {
                // the page's literal pixel count: every pixel of the page (no tile is left out: the triangle's bbox)
                long all = 0;
                for (int y = 0; y < 480; y++)
                    for (int x = 0; x < 640; x++)
                        all += drawnAt(x, y);
                F->ok(all == cp.drawn[pi] && drawn == cp.drawn[pi],
                      "directed console %s page %d: the console draws %ld pixels (%ld in the tiles with records), the "
                      "literal %ld", cp.test, page, all, drawn, cp.drawn[pi]);
            }
        }
        cases += recs;
        F->ok(mech[cp.need] > 0, "directed console %s: no record exercises '%s' (%s)", cp.test, cp.need, cp.fact);
        printf("isp_edge: directed console %-13s pages %2zu: %5ld records, %4ld tiles, RTL %ld / refsw3 %ld tiles off the "
               "console; swamp %ld x128 %ld cancel %ld sat %ld big %ld row31 %ld [%s > 0]: %s\n",
               cp.test, cp.pages.size(), recs, tilesCmp, rtlWrong, refWrong, mech["swamp"], mech["x128"],
               mech["cancel"], mech["sat"], mech["big"], mech["row31"], cp.need, cp.fact);
    }
    printf("isp_edge: section directed console %ld cases\n", cases);
    PrintWidths("directed console");
}

// ---------------------------------------------------------------------------------------------------------------
// random: triangles, quads and modifier volume triangles of every class
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
    case 6: return bf((uint32_t)r.below(0x800000) | (r.below(2) ? 0x80000000u : 0));     // a denormal or a zero
    default: return (float)((int)r.below(4000) - 2000) / 7.0f;
    }
}

// the far class: one corner near the tile, the other with a coordinate of 2^118 .. 2^127 (steps of 2^123 and more);
// column steps at and near multiples of 2^124 .. 2^126 (32 sx at 2^131, 2^132), saturated differences, products of
// exactly 2^128
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
    case 1: big = ldexpf((float)r.range(1, 15), 124); break;                                  // k 2^124
    case 2: big = bf(fb(Pow2f(126 + (int)r.below(2))) + (uint32_t)r.range(-4, 4)); break;      // 32 sx near 2^131, 2^132
    case 3: big = bf(fb(Pow2f(127)) + (uint32_t)r.below(0x100000)); break;                     // |y| past 2^127
    case 4: big = Pow2f(127); break;
    case 5: big = ldexpf(1.0f + r.below(8) / 8.0f, 123 + (int)r.below(5)); break;
    default: big = bf(fb(Pow2f(118 + (int)r.below(10))) + (uint32_t)r.range(-3, 3)); break;
    }
    if (r.below(2))
        y[far] = sg * big;
    else
        x[far] = sg * big;
    if (r.below(4) == 0) {
        // two far corners on opposite sides: differences past 2^128 (the steps saturate)
        const int o = (far + 1) % 3;
        y[o] = -y[far] * (1.0f + r.below(16) / 64.0f);
        if (r.below(2))
            x[o] = x[far];
    }
    if (r.below(8) == 0) {
        // a product of exactly 2^128: x 2^a, y 2^(128 - a)
        const int a = 60 + (int)r.below(40);
        x[far] = sg * Pow2f(a);
        y[far] = Pow2f(128 - a);
    }
}

Job RandomJob(p2tb::Rng& r)
{
    Job j;
    j.tileX = (uint8_t)r.below(64);
    j.tileY = (uint8_t)r.below(64);
    float x[4], y[4];
    const int cls = (int)r.below(10);
    const float cx = 32.0f * j.tileX, cy = 32.0f * j.tileY;
    switch (cls) {
    case 0:     // pixel-grid corners, edges through centres or corners
        for (int c = 0; c < 4; c++) {
            x[c] = cx + (float)r.range(-24, 56) + (r.below(2) ? 0.5f : 0.0f) + (r.below(4) ? 0 : r.below(16) / 16.0f);
            y[c] = cy + (float)r.range(-24, 56) + (r.below(2) ? 0.5f : 0.0f) + (r.below(4) ? 0 : r.below(16) / 16.0f);
        }
        break;
    case 1:     // ulp-perturbed grid corners
        for (int c = 0; c < 4; c++) {
            x[c] = bf(fb(cx + (float)r.range(-8, 40) + 0.5f) + (uint32_t)r.range(-12, 12));
            y[c] = bf(fb(cy + (float)r.range(-8, 40) + 0.5f) + (uint32_t)r.range(-12, 12));
        }
        break;
    case 2:     // a wide mix of exponents, huge and denormal values, zeros
        for (int c = 0; c < 4; c++) {
            x[c] = RndCoord(r);
            y[c] = RndCoord(r);
        }
        break;
    case 3:
    case 4:     // the far class
        FarTri(r, x, y, j.tileX, j.tileY);
        x[3] = x[0] + (float)r.range(-30, 30);
        y[3] = y[2] + (float)r.range(-30, 30);
        break;
    case 5: {   // slivers: the third corner off the line through the first two by 1e-5 .. 0.05 pixel, or on it
        const float ax = cx + (float)r.below(32) + 0.5f, ay = cy + (float)r.below(32) + 0.5f;
        const float dx = (float)r.range(-6, 6), dy = (float)r.range(-6, 6);
        const float t = (float)r.range(1, 7) / 2.0f, off = r.below(4) ? 0.0f : ldexpf(1.0f, -(int)r.range(5, 17));
        x[0] = ax; y[0] = ay;
        x[1] = ax + dx * 4; y[1] = ay + dy * 4;
        x[2] = ax + dx * t + off; y[2] = ay + dy * t - off;
        x[3] = x[1]; y[3] = y[2];
        break;
    }
    case 6: {   // points and tiny triangles, the top corner anywhere in the tile (rows 28 .. 31 often)
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
    case 7: {   // first row 28 .. 31 for any shape, small or far
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
    case 8:     // bad corners: an infinity or a NaN
        for (int c = 0; c < 4; c++) {
            x[c] = cx + (float)r.range(-8, 40);
            y[c] = cy + (float)r.range(-8, 40);
        }
        (r.below(2) ? x : y)[r.below(4)] = bf(r.below(2) ? 0x7F800000u | (uint32_t)r.below(4) : 0xFF800000u);
        break;
    default:    // screen-sized triangles near the tile
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
    j.quad = r.below(5) == 0;
    j.modvol = r.below(7) == 0;
    j.half = r.below(4) != 0;
    j.cull = r.below(3) == 0 ? (uint8_t)r.below(4) : 0;
    static const uint32_t vals[] = {0, 0x3F800000, 0x3F000000, 0x40000000, 0xBF800000, 0x00000001, 0x7F800000,
                                    0x7FC00000, 0xFFC00001, 0x7149F2CA, 0x00800000, 0x80000000};
    j.cullVal = r.below(8) ? vals[r.below(sizeof vals / 4)] : r.u32();
    j.kill = j.modvol && r.below(40) == 0;
    return j;
}

void Random(Dut& dut, uint64_t n, const char* sec)
{
    F->set(sec);
    std::vector<Job> jobs;
    long id = 0, used = 0;
    for (uint64_t i = 0; i < n; i++) {
        if (!A->mine(i))
            continue;
        p2tb::Rng r = p2tb::Rng::of(A->seed, i);
        jobs.push_back(RandomJob(r));
        used++;
        if (jobs.size() >= 4096)
            RunChecked(dut, jobs, sec, &id);
    }
    RunChecked(dut, jobs, sec, &id);
    printf("isp_edge: section %s %ld cases (%ld edges)\n", sec, used, 3 * used);
    PrintWidths(sec);
}

// ---------------------------------------------------------------------------------------------------------------
// rdesc: raster-only descriptors around the walk's boundaries (half units: H = 2^30, Z = 2^7)
int64_t Even(int64_t v) { return v & ~(int64_t)1; }

EdgeOut RandomBig(p2tb::Rng& r, int jf)
{
    const int64_t H = (int64_t)1 << 30, L = ((int64_t)1 << 27) - 2;
    int64_t t0 = Even(r.range(-L, L)), tx = Even(r.range(-L, L)), ty = Even(r.range(-L, L));
    switch (r.below(8)) {
    case 0: {   // R at a wrap boundary in row j0: t0 + j0 ty = +-H + small
        const int j0 = (int)r.range(std::max(jf, 1), 31);
        const int64_t target = (r.below(2) ? H : -H) + 2 * r.range(-2, 2) + (r.below(2) ? 0 : 2 * H * (r.below(2) ? 1 : -1));
        ty = Even(target / j0);
        t0 = target - j0 * ty;
        if (t0 > L || t0 < -L) t0 = Even(r.range(-L, L));
        break;
    }
    case 1: {   // R + 16 sx at +-H in row jf
        const int64_t rj = t0 + jf * ty;
        int64_t rw = rj % (2 * H);
        if (rw >= H) rw -= 2 * H; else if (rw < -H) rw += 2 * H;
        const int64_t target = (rw > 0 ? -H : H) + 2 * r.range(-1, 1);
        tx = Even((target - rw) / 16);
        if (tx > L || tx < -L) tx = Even(r.range(-L, L));
        break;
    }
    case 2:     // column steps at and near multiples of 2^126, 2^125, 2^124 (2^25, 2^24, 2^23 half units), both signs
        tx = (r.below(2) ? -1 : 1) * (int64_t)r.range(1, 3) * ((int64_t)1 << (23 + r.below(3))) + 2 * r.range(-1, 1) * r.below(2);
        break;
    case 3: {   // the far value at ZERO in row jf + 1: rw + far32 = Z + small, tx > 0
        tx = Even(r.range(2, L));
        const int64_t far = (tx & (((int64_t)1 << 25) - 1)) << 5;
        const int64_t target = 128 + 2 * r.range(-2, 2) - far;
        ty = Even(r.range(-L, L) >> r.below(20));
        t0 = target - (jf + 1) * ty;
        if (t0 > L || t0 < -L) t0 = Even(r.range(-L, L));
        break;
    }
    case 4:     // small values, zero steps, starts of 0
        t0 = Even(r.range(-1024, 1024)) * r.below(2);
        tx = Even(r.range(-512, 512)) * r.below(2);
        ty = Even(r.range(-512, 512)) * (r.below(2) ? 1 : ((int64_t)1 << r.below(20)));
        break;
    case 5:     // the rows' starts at the ZERO band
        ty = Even(r.range(-1024, 1024));
        t0 = Even(r.range(-300, 300));
        break;
    default:
        break;
    }
    return BigEdge(Even(std::clamp(t0, -L, L)), Even(std::clamp(tx, -L, L)), Even(std::clamp(ty, -L, L)));
}

EdgeOut RandomOrdinary(p2tb::Rng& r)
{
    EdgeOut e;
    e.zsh = 7 + (int)r.below(3);
    const int64_t L = ((int64_t)1 << 22) - 2;
    e.tx = Even(r.range(-L, L) >> r.below(22));
    e.ty = Even(r.range(-L, L) >> r.below(22));
    e.t0 = r.range(-((int64_t)1 << (e.zsh + 20 - 1)), (int64_t)1 << (e.zsh + 20 - 1)) >> r.below(28);
    if (r.below(4) == 0)
        e.t0 = r.range(-((int64_t)1 << e.zsh) - 3, ((int64_t)1 << e.zsh) + 3);
    e.far32 = e.tx > 0 ? (uint32_t)((e.tx & ((1 << 25) - 1)) << 5) : (e.tx < 0 && (e.tx & ((1 << 25) - 1)) == 0) ? (1u << 30) : 0;
    return e;
}

Job RandomDesc(p2tb::Rng& r)
{
    Job j;
    j.rasterOnly = true;
    j.djf = (int)r.below(32);
    j.djl = r.below(4) ? 31 : (int)r.range(j.djf, 31);
    j.drowsV = r.below(32) != 0;
    const int act = 1 + (int)r.below(4) * (r.below(3) == 0);
    for (int k = 0; k < 4; k++) {
        if (k >= act) {
            j.de[k].cv = true;
            j.de[k].ci = r.below(16) != 0;
            continue;
        }
        if (r.below(8) == 0) {
            j.de[k].cv = true;
            j.de[k].ci = r.below(2);
        } else
            j.de[k] = r.below(4) ? RandomBig(r, j.djf) : RandomOrdinary(r);
    }
    j.kill = r.below(64) == 0;
    return j;
}

void Rdesc(Dut& dut, uint64_t n, const char* sec)
{
    F->set(sec);
    std::vector<Job> jobs;
    long id = 0, used = 0;
    for (uint64_t i = 0; i < n; i++) {
        if (!A->mine(i))
            continue;
        p2tb::Rng r = p2tb::Rng::of(A->seed ^ 0x5DE5C0DEull, i);
        jobs.push_back(RandomDesc(r));
        used++;
        if (jobs.size() >= 4096)
            RunChecked(dut, jobs, sec, &id);
    }
    RunChecked(dut, jobs, sec, &id);
    printf("isp_edge: section %s %ld cases\n", sec, used);
}

}   // namespace

int main(int argc, char** argv)
{
    p2tb::raise_stack();
    p2tb::Args args;
    if (!args.parse(argc, argv)) {
        fprintf(stderr, "isp_edge: %s\n", args.error.c_str());
        return 2;
    }
    A = &args;
    p2tb::banner("isp_edge", args);
    p2tb::Fails fails("isp_edge");
    F = &fails;
    const char* dct = getenv("DCTESTS");
    const std::string setDir = !args.set.empty() ? args.set : std::string(dct ? dct : "../dreamcast-tests") + "/fit/covmeas_data";
    const std::string vecDir = !args.vec.empty() ? args.vec : "build/vec";

    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(1, argv);
    auto top = std::make_unique<Top>(ctx.get());
    Dut dut(top.get());
    dut.rng = p2tb::Rng(args.seed ^ 0xD07ull);
    dut.reset();

    const uint64_t nRandom = args.count(args.full ? 133333334 : 666667);    // 400M / 2M edges
    const uint64_t nDesc = args.count(args.full ? 20000000 : 100000);
    if (args.want("directed") && args.shardK == 0) {
        Directed(dut);
        ConsolePages(dut, vecDir, std::string(dct ? dct : "../dreamcast-tests"));
    }
    if (args.want("covmeas"))
        Covmeas(dut, setDir);
    if (args.want("tria"))
        Tria(dut, vecDir);
    if (args.want("random"))
        Random(dut, nRandom, "random");
    if (args.want("rdesc"))
        Rdesc(dut, nDesc, "rdesc");
    if (args.want("stream")) {
        dut.gapSu = 300;
        dut.gapRa = 250;
        dut.stall = 300;
        // the handshakes under gaps and stalls: a quarter of the quick counts, at most 2M jobs in full
        Random(dut, std::min<uint64_t>(nRandom / 4, 2000000), "stream");
        Rdesc(dut, std::min<uint64_t>(nDesc / 4, 500000), "stream");
        dut.gapSu = dut.gapRa = dut.stall = 0;
    }
    printf("isp_edge: %llu clocks\n", (unsigned long long)dut.cycles);
    return fails.finish();
}

// isp_depth_tb.cpp: make isp-depth. M3, the ISP depth path (PLAN M3; ARCHITECTURE 3.4.4 steps 6-7, 3.4.5 depth lanes,
// 2.4 p2_ztile_t; isp 6.3, 9.1-9.7 at refsw3 4f3efe15): p2_isp_depth_setup and p2_isp_depth_raster in lockstep with
// refsw3's pvrisp::DepthTileT<DepthHW>::Setup / At (asked with the same `centers` as Setup: h = 0, as RasterizeTriangle
// asks) and StoredDepth, and with the verbatim copy of the plane setup (tb/isp_depth/ref_copies_depth.h).
//
// Every job is a (primitive, tile) pair through the setup, whose result the testbench carries into the raster with the
// job's rows. Compared: the plane a, b, c, det (tuples), the regime and the descriptor's fields against refsw3's values
// in the G form (CONST key; REG r0, sa, sb, fa, fb; BLOCK S, DX, DY, gexp, E, nsh, fbw, and A, B), and every key of every
// row the raster gives (exactly the asked rows, in order) against DepthTileT::At. PLAN M3 item 5 is asserted on every
// pixel of every job: |t| < 2^29, refsw3's tu within 64 bits (A2), nsh in -14 .. 14 where a start is left, the fallback
// word only with fbw (its pixels reported with whether they are covered), never the float form, every key back to a
// StoredDepth through zkey.h; REG |r0| <= 2^25, |fa|, |fb| < 2^30.
//
// Sections (--only), in PLAN M3's gate order:
//   directed  console facts as literals, independent of refsw3 (and checked against it too): zword's register words at
//             every whole step and depthgaps_mm's order (raster descriptors); depth2_halfc's start at the corner (zword's
//             TL +inf at +1 step, zovf_creg's C0 at -1 step) and at the centre; trsort_recip's determinants f 2^126
//             (key 0 from f = 1, 2^126 included), page 10's infinite one, trsort_recipovf's corner depths at f = 1;
//             the determinant-zero means of perpmean_bg and depthgaps_detneg as words, depthgaps_dzinf's infinities;
//             zspec pages 3-6 (a plane under 2^-126 a pixel: its start everywhere, or 0)
//   zmeas     the 13 archived zmeas sets (dreamcast-tests fit/zmeas_data/*.zme: 89,801 brackets): the RTL's key at each
//             pixel inside the console's bracket, and equal to refsw3's
//   covmeas   the archived covmeas zprobe sets (fit/covmeas_data: zprobe*, *zprobe): pages composed as dreamcast-tests
//             model/covprobe composes them, with the RTL's keys in the depth compare, against the console's record
//   tria      the console pages' own primitives with their depths, build/vec/<test>.trz (tools/gate/tria_extract.sh):
//             depthgaps_*, zovf*, nantr_*, perpmean_*, zword, zbad*, zspec, zsign, bg*, depth2_*, trsort_*
//   random    random planes of every regime (num 7.2; PLAN M3 item 4): the classes of widths4f3d, depthgaps' (negative
//             starts, starts of exactly 0, slopes 2^50 and more times the start, products at 2^128, operands near
//             2^-126), near 2^126 (determinants within a few units of it, exactly 2^126 too, and infinite ones),
//             zcoord / zedge (tile (0, 0), +-0, +-(1 .. 1.5) 2^-126, huge and infinite depths), HALF_OFFSET[0] at random
//   rdesc     raster-only: random BLOCK / REG / CONST descriptors and row ranges against the lane formula of isp 9.6
//             (RegDepth, StoredDepth::FromFp / Big / Neg)
//   stream    random and rdesc again (a quarter of their counts) with random gaps on both inputs and back-pressure
// Arguments: p2tb.h's; --vec <folder> (default build/vec), --set <folder> (default $DCTESTS/fit). --full: every tria
// record (quick: one in eight, at least the first of each test), the full random counts (random 100M planes, rdesc 4M;
// quick 1M and 100k).
#include <dirent.h>

#include <algorithm>
#include <array>
#include <cinttypes>
#include <cmath>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "Vp2_isp_depth_tb_top.h"
#include "isp_depth_dut.h"
#include "isp_depth_ref.h"
#include "npz.h"
#include "p2tb.h"
#include "pvr_tsp_plane.h"
#include "triz_rec.h"
#include "verilated.h"
#include "zkey.h"

using namespace depthtb;
using pvrisp::StoredDepth;

static p2tb::Fails* F;
static p2tb::Args* A;

// ---------------------------------------------------------------------------------------------------------------
// the width claims (PLAN M3 item 5), on refsw3's values of every job
struct Widths {
    long jobs = 0, block = 0, reg = 0, cnst = 0, corner = 0, pixels = 0, negPixels = 0, bigPixels = 0;
    long fbwPixels = 0, fbwCovered = 0, fbwUnknown = 0, nshNegPixels = 0;
    double maxT = 0;
    int maxTuBits = 0, nshMin = 99, nshMax = -99, gexpMin = 999, gexpMax = -999, Emin = 999, Emax = -999;
    int64_t maxS = 0, maxStep = 0, maxR0 = 0, maxF = 0;
    void print(const char* sec) const
    {
        printf("isp_depth: widths: %s: %ld jobs (BLOCK %ld, REG %ld, CONST %ld; HALF_OFFSET[0] = 0 in %ld): max |t| 2^%.2f "
               "half-G units (< 2^29), refsw3 tu <= %d bits (<= 64), |S| < 2^%.2f, |DX|,|DY| < 2^%.2f, nsh with a start "
               "%d..%d, gexp %d..%d, E %d..%d; REG |r0| 2^%.2f, |fa|,|fb| 2^%.2f; pixels %ld (below zero %ld, Big %ld, "
               "nsh < 0 %ld); fallback words %ld (covered %ld, quads not known %ld)\n",
               sec, jobs, block, reg, cnst, corner, maxT > 0 ? log2(maxT) : -1, maxTuBits,
               maxS ? log2((double)maxS) : -1, maxStep ? log2((double)maxStep) : -1, nshMin, nshMax, gexpMin, gexpMax,
               Emin, Emax, maxR0 ? log2((double)maxR0) : -1, maxF ? log2((double)maxF) : -1, pixels, negPixels,
               bigPixels, nshNegPixels, fbwPixels, fbwCovered, fbwUnknown);
    }
};

static bool TupEq(const Tup& t, const Fp& v)
{
    if (t.neg != v.neg || t.bad != v.bad || t.mant != (uint32_t)v.mant)
        return false;
    return v.mant == 0 || t.exp == v.exp;
}

static std::string TupStr(const Tup& t)
{
    char b[96];
    snprintf(b, sizeof b, "{%c%s %06x e%d}", t.neg ? '-' : '+', t.bad ? " bad" : "", t.mant, t.exp);
    return b;
}
static std::string FpStr(const Fp& v)
{
    char b[96];
    snprintf(b, sizeof b, "{%c%s %06llx e%d}", v.neg ? '-' : '+', v.bad ? " bad" : "", (unsigned long long)v.mant,
             v.exp);
    return b;
}
static std::string JobStr(const Job& j)
{
    char b[400];
    snprintf(b, sizeof b, "x %08x %08x %08x y %08x %08x %08x z %08x %08x %08x perp %08x half %d tile (%d, %d)", j.x[0],
             j.x[1], j.x[2], j.y[0], j.y[1], j.y[2], j.z[0], j.z[1], j.z[2], j.perp, j.half, j.tileX, j.tileY);
    return b;
}

// how a job is checked (and what it reports)
struct CheckOpt {
    bool pixels = true;        // every key of the asked rows against At
    bool widths = true;        // item 5 on every pixel (all 1,024, asked or not)
    bool cover = false;        // a fallback pixel's coverage (pvr_isp_edge.h): known for triangles
};

// one setup job against refsw3; returns false on any difference (the first few are shown)
static bool CheckSetup(const char* ctx, const Job& j, const Out& o, Ref& r, Widths& w, const CheckOpt& opt)
{
    const long before = F->n;
    const std::string js = JobStr(j);
    const DepthHWTile& Z = r.Z;
    F->ok(o.orderErrors == 0, "%s: %s: rows out of order or missing (%d)", ctx, js.c_str(), o.orderErrors);
    // the plane
    const Fp* pv[4] = {&r.pl.a, &r.pl.b, &r.pl.c, &r.pl.det};
    static const char* const pn[4] = {"a", "b", "c", "det"};
    for (int k = 0; k < 4; k++)
        F->ok(TupEq(o.dbg[k], *pv[k]), "%s: %s: plane %s RTL %s refsw3 %s", ctx, js.c_str(), pn[k],
              TupStr(o.dbg[k]).c_str(), FpStr(*pv[k]).c_str());
    // the descriptor
    F->ok(!r.floatForm, "%s: %s: refsw3 took the float form (isp 9.4a: unreachable)", ctx, js.c_str());
    F->ok(!r.offGrid, "%s: %s: refsw3's d0, dx, dy are not on the G grid (isp 9.4a)", ctx, js.c_str());
    const ZDesc& d = r.d;
    const ZDesc& z = o.z;
    w.jobs++;
    if (!j.half)
        w.corner++;
    if (F->ok(z.regime == d.regime, "%s: %s: regime RTL %d refsw3 %d", ctx, js.c_str(), z.regime, d.regime)) {
        if (d.regime == Z_CONST) {
            w.cnst++;
            F->ok(z.key == d.key, "%s: %s: CONST key RTL %016" PRIx64 " refsw3 %016" PRIx64, ctx, js.c_str(),
                  (uint64_t)z.key, (uint64_t)d.key);
        } else if (d.regime == Z_REG) {
            w.reg++;
            F->ok(z.r0 == d.r0 && z.sa == d.sa && z.sb == d.sb && z.fa == d.fa && z.fb == d.fb,
                  "%s: %s: REG RTL r0 %" PRId64 " sa %d sb %d fa %" PRId64 " fb %" PRId64 " refsw3 r0 %" PRId64
                  " sa %d sb %d fa %" PRId64 " fb %" PRId64,
                  ctx, js.c_str(), z.r0, z.sa, z.sb, z.fa, z.fb, d.r0, d.sa, d.sb, d.fa, d.fb);
            // first0 is below 2^128 (ranged) or one step: cut20 on 2^102, |r0| < 2^26
            F->ok(iabs64(d.r0) < ((int64_t)1 << 26), "%s: %s: refsw3 |r0| %" PRId64 " from 2^26", ctx, js.c_str(), d.r0);
            F->ok(iabs64(d.fa) < ((int64_t)1 << 30) && iabs64(d.fb) < ((int64_t)1 << 30), "%s: %s: |fa|, |fb| >= 2^30",
                  ctx, js.c_str());
            w.maxR0 = std::max(w.maxR0, iabs64(d.r0));
            w.maxF = std::max(w.maxF, std::max(iabs64(d.fa), iabs64(d.fb)));
        } else if (!r.floatForm && !r.offGrid) {
            w.block++;
            const bool fieldsOk = z.S == d.S && z.DX == d.DX && z.DY == d.DY && z.gexp == d.gexp && z.E == d.E &&
                                  z.fbw == d.fbw && (d.fbw || z.nsh == d.nsh);
            F->ok(fieldsOk,
                  "%s: %s: BLOCK RTL S %" PRId64 " DX %" PRId64 " DY %" PRId64 " gexp %d E %d nsh %d fbw %d refsw3 S %" PRId64
                  " DX %" PRId64 " DY %" PRId64 " gexp %d E %d nsh %d fbw %d",
                  ctx, js.c_str(), z.S, z.DX, z.DY, z.gexp, z.E, z.nsh, z.fbw, d.S, d.DX, d.DY, d.gexp, d.E, d.nsh,
                  d.fbw);
            F->ok(TupEq(o.dbg[5], Z.A) && TupEq(o.dbg[6], Z.B), "%s: %s: A, B RTL %s %s refsw3 %s %s", ctx, js.c_str(),
                  TupStr(o.dbg[5]).c_str(), TupStr(o.dbg[6]).c_str(), FpStr(Z.A).c_str(), FpStr(Z.B).c_str());
            // the field widths (ARCHITECTURE 2.4)
            F->ok(iabs64(d.S) < ((int64_t)1 << 27) && iabs64(d.DX) < ((int64_t)1 << 21) && iabs64(d.DY) < ((int64_t)1 << 21),
                  "%s: %s: |S| %" PRId64 " >= 2^27 or |DX| %" PRId64 ", |DY| %" PRId64 " >= 2^21", ctx, js.c_str(), d.S,
                  d.DX, d.DY);
            F->ok(d.gexp >= -512 && d.gexp < 512 && d.E >= -122 && d.E <= 128, "%s: %s: gexp %d / E %d out of range", ctx,
                  js.c_str(), d.gexp, d.E);
            if (!r.startZero)
                F->ok(d.nsh >= -14 && d.nsh <= 14, "%s: %s: nsh %d with a start (isp 9.6: -14 .. 14)", ctx, js.c_str(),
                      d.nsh);
            w.maxS = std::max(w.maxS, iabs64(d.S));
            w.maxStep = std::max(w.maxStep, std::max(iabs64(d.DX), iabs64(d.DY)));
            if (!r.startZero) {
                w.nshMin = std::min(w.nshMin, d.nsh);
                w.nshMax = std::max(w.nshMax, d.nsh);
            }
            w.gexpMin = std::min(w.gexpMin, d.gexp);
            w.gexpMax = std::max(w.gexpMax, d.gexp);
            w.Emin = std::min(w.Emin, d.E);
            w.Emax = std::max(w.Emax, d.E);
            if (opt.widths) {
                bool tOk = true, tuOk = true, haveCover = false;
                uint32_t cover[32];
                for (int jj = 0; jj < 32; jj++)
                    for (int i = 0; i < 32; i++) {
                        const int64_t t = d.S + 2 * (int64_t)i * d.DX + 2 * (int64_t)jj * d.DY;
                        const double at = (double)iabs64(t);
                        if (at > w.maxT)
                            w.maxT = at;
                        if (iabs64(t) >= ((int64_t)1 << 29))
                            tOk = false;
                        const i128 tu = Z.d0 + (i128)(2 * i) * Z.dx + (i128)(2 * jj) * Z.dy;
                        const int nb = bitlen128((u128)(tu < 0 ? -tu : tu));
                        w.maxTuBits = std::max(w.maxTuBits, nb);
                        if (nb > 64)
                            tuOk = false;
                        w.pixels++;
                        if (t < 0) {
                            w.negPixels++;
                            if (d.fbw) {
                                w.fbwPixels++;
                                if (opt.cover) {
                                    if (!haveCover) {
                                        CoverMask(j.x, j.y, 32 * j.tileX, 32 * j.tileY, j.half, false, cover);
                                        haveCover = true;
                                    }
                                    if (cover[jj] >> i & 1)
                                        w.fbwCovered++;
                                } else
                                    w.fbwUnknown++;
                            } else if (d.nsh < 0)
                                w.nshNegPixels++;
                        } else {
                            Fp v;
                            v.mant = (uint64_t)t;
                            v.exp = d.gexp - 1;
                            const Fp s = v.cut(19);
                            if (!s.zero() && s.top() - 1 >= 128)
                                w.bigPixels++;
                        }
                    }
                F->ok(tOk, "%s: %s: |t| >= 2^29 at a pixel (isp 9.4a)", ctx, js.c_str());
                F->ok(tuOk, "%s: %s: refsw3's tu above 64 bits (A2: At's truncation would act)", ctx, js.c_str());
            }
        }
    }
    // the pixels: exactly the asked rows, every key equal to At(i, j, centers) (Setup's centers)
    if (opt.pixels && j.rowsV) {
        uint32_t want = 0;
        for (int jj = j.jf; jj <= j.jl; jj++)
            want |= 1u << jj;
        F->ok(o.rowsSeen == want, "%s: %s: rows %08x, asked %08x", ctx, js.c_str(), o.rowsSeen, want);
        int shown = 0;
        long wrong = 0;
        for (int jj = j.jf; jj <= j.jl; jj++)
            for (int i = 0; i < 32; i++) {
                const StoredDepth s = Z.At(i, jj, j.half);
                const int64_t k = o.key[jj][i];
                if (k != s.k) {
                    wrong++;
                    if (shown++ < 2)
                        F->ok(false, "%s: %s: pixel (%d, %d) key RTL %016" PRIx64 " (%08x) refsw3 %016" PRIx64 " (%08x)", ctx,
                              js.c_str(), i, jj, (uint64_t)k, p2tb::zkey_bits(k), (uint64_t)s.k, s.bits);
                } else {
                    StoredDepth back;
                    if (!p2tb::zkey_stored(k, &back))
                        F->ok(false, "%s: %s: pixel (%d, %d) key %016" PRIx64 " does not round-trip through zkey.h", ctx,
                              js.c_str(), i, jj, (uint64_t)k);
                }
            }
        F->ok(wrong == 0, "%s: %s: %ld keys differ", ctx, js.c_str(), wrong);
    }
    return F->n == before;
}

// a raster-only job against the lane formula
static bool CheckRaster(const char* ctx, const Job& j, const Out& o)
{
    const long before = F->n;
    F->ok(o.orderErrors == 0, "%s: rows out of order or missing (%d)", ctx, o.orderErrors);
    if (!j.rowsV) {
        F->ok(o.rowsSeen == 0, "%s: rows from a descriptor without rows", ctx);
        return F->n == before;
    }
    uint32_t want = 0;
    for (int jj = j.jf; jj <= j.jl; jj++)
        want |= 1u << jj;
    F->ok(o.rowsSeen == want, "%s: rows %08x, asked %08x", ctx, o.rowsSeen, want);
    int shown = 0;
    for (int jj = j.jf; jj <= j.jl; jj++)
        for (int i = 0; i < 32; i++) {
            const int64_t e = LaneKey(j.d, i, jj);
            if (o.key[jj][i] != e && shown++ < 2)
                F->ok(false,
                      "%s: regime %d S %" PRId64 " DX %" PRId64 " DY %" PRId64 " gexp %d E %d nsh %d fbw %d r0 %" PRId64
                      " sa %d sb %d fa %" PRId64 " fb %" PRId64 ": pixel (%d, %d) RTL %016" PRIx64 " model %016" PRIx64,
                      ctx, j.d.regime, j.d.S, j.d.DX, j.d.DY, j.d.gexp, j.d.E, j.d.nsh, j.d.fbw, j.d.r0, j.d.sa, j.d.sb,
                      j.d.fa, j.d.fb, i, jj, (uint64_t)o.key[jj][i], (uint64_t)e);
        }
    F->ok(shown == 0, "%s: %d keys differ", ctx, shown);
    return F->n == before;
}

// run jobs in batches through the DUT and check each
static const size_t kBatch = 4096;
static void RunChecked(Dut& dut, const char* ctx, std::vector<Job>& jobs, Widths& w, const CheckOpt& opt)
{
    std::vector<Out> outs;
    dut.run(jobs, outs);
    for (size_t i = 0; i < jobs.size(); i++) {
        if (jobs[i].rasterOnly) {
            CheckRaster(ctx, jobs[i], outs[i]);
        } else {
            Ref r;
            RefSetup(jobs[i], r);
            CheckSetup(ctx, jobs[i], outs[i], r, w, opt);
        }
    }
    jobs.clear();
}

// ---------------------------------------------------------------------------------------------------------------
// directed: console facts as literals
static int64_t K(uint32_t w) { return StoredDepth::Bits(w).k; }

// zword: the word at whole step m of the register (m = r / 2^127 mod 32), as the console's background probes pin it
// (pvr-tests/zword: every word to 19 bits; depth.h RegDepth's comment, isp 9.5): the exact words, and for the others the
// two float words they lie between in the ISP's order
static bool ZwordFact(int m, int64_t k, std::string* why)
{
    m &= 31;
    auto between = [&](uint32_t lo, uint32_t hi) { return k > K(lo) && k < K(hi); };
    bool ok;
    switch (m) {
    case 0: ok = k == 0; break;
    case 1: ok = k == K(0x7f000000u); break;              // equal to 2^127
    case 16: ok = k == K(0x807fffffu); break;             // below every probe: the lowest word
    case 17: ok = between(0xfd000000u, 0xfdffffffu); break;   // between field 250's top and 251's bottom
    case 18: case 19: ok = between(0xfd800000u, 0xfe7fffffu); break;
    case 20: case 21: case 22: ok = between(0xfe000000u, 0xfeffffffu); break;
    case 23: ok = k == K(0xfeffffe0u); break;             // the bottom of field 253
    case 30: ok = k == K(0xff7fffe0u); break;             // the bottom of field 254
    case 31: ok = k == K(0xff000000u); break;             // -2^127
    default:
        if (m >= 2 && m <= 15)
            ok = k > K(0x7f7fffe0u);                      // above every probe (the largest positive 0x7f7fffe0)
        else
            ok = between(0xfe800000u, 0xff7fffffu);       // 24 .. 29: between 253's top and 254's bottom
    }
    if (!ok) {
        char b[96];
        snprintf(b, sizeof b, "m %d key %016" PRIx64, m, (uint64_t)k);
        *why = b;
    }
    return ok;
}

static Job Tri(float x0, float y0, uint32_t z0, float x1, float y1, uint32_t z1, float x2, float y2, uint32_t z2,
               int tx, int ty, bool half)
{
    Job j;
    j.x[0] = fb(x0); j.y[0] = fb(y0); j.z[0] = z0;
    j.x[1] = fb(x1); j.y[1] = fb(y1); j.z[1] = z1;
    j.x[2] = fb(x2); j.y[2] = fb(y2); j.z[2] = z2;
    j.tileX = (uint8_t)tx;
    j.tileY = (uint8_t)ty;
    j.half = half;
    return j;
}

static void Directed(Dut& dut)
{
    F->set("directed");
    Widths w;
    CheckOpt opt;
    opt.cover = true;
    long cases = 0;

    // ---- zword's 32 words and depthgaps_mm's order: REG descriptors r0 = 0, steps of one whole step a column and a row
    //      (m = i + j), and the mirror (m = -(i + j))
    {
        std::vector<Job> jobs;
        for (int s = 0; s < 2; s++) {
            Job j;
            j.rasterOnly = true;
            j.d.regime = Z_REG;
            j.d.sa = j.d.sb = s ? -1 : 1;
            jobs.push_back(j);
        }
        std::vector<Out> outs;
        dut.run(jobs, outs);
        for (int s = 0; s < 2; s++) {
            CheckRaster("directed zword", jobs[s], outs[s]);
            for (int jj = 0; jj < 32; jj++)
                for (int i = 0; i < 32; i++) {
                    std::string why;
                    const int m = s ? -(i + jj) : i + jj;
                    F->ok(ZwordFact(m, outs[s].key[jj][i], &why), "directed zword: pixel (%d, %d): %s", i, jj, why.c_str());
                }
            // depthgaps_mm: -16 < -15 < .. < -1 < 0 < 1 < .. < 15, no two equal (row 0 holds m = 0 .. 31 or 0, -1 .. -31)
            for (int a = -16; a < 15; a++) {
                const int ia = s ? (32 - a) & 31 : a & 31, ib = s ? (32 - (a + 1)) & 31 : (a + 1) & 31;
                F->ok(outs[s].key[0][ia] < outs[s].key[0][ib], "directed depthgaps_mm: m %d not below m %d", a, a + 1);
            }
            cases += 2;
        }
    }

    std::vector<Job> jobs;
    auto run = [&](const char* ctx) {
        std::vector<Out> outs;
        dut.run(jobs, outs);
        for (size_t i = 0; i < jobs.size(); i++) {
            Ref r;
            RefSetup(jobs[i], r);
            CheckSetup(ctx, jobs[i], outs[i], r, w, opt);
        }
        cases += (long)jobs.size();
        return outs;
    };

    // ---- depth2_halfc: zword's TL +inf triangle (corner (x, y) at +inf, legs 32 at 0.5) and zovf_creg's C0; in tile
    //      (0, 0) at the corner (HALF_OFFSET 6) the start is +1 step (m = 1 - (i + j)) and -1 step; at the centre and in
    //      tile (2, 0) at either sample point 0 (m = -(i + j))
    {
        const uint32_t half5 = 0x3f000000u, inf = 0x7f800000u;
        jobs.clear();
        for (int h = 0; h < 2; h++) {
            jobs.push_back(Tri(0, 0, inf, 32, 0, half5, 0, 32, half5, 0, 0, h));
            jobs.push_back(Tri(64, 0, inf, 96, 0, half5, 64, 32, half5, 2, 0, h));
            jobs.push_back(Tri(0, 0, 0xfa800000u, 32, 0, 0x7d000000u, 0, 32, 0x7be00000u, 0, 0, h));
        }
        const std::vector<Out> outs = run("directed depth2_halfc");
        for (int h = 0; h < 2; h++) {
            for (int v = 0; v < 2; v++) {
                const Out& o = outs[3 * h + v];
                const int64_t r0 = (v == 0 && h == 0) ? ((int64_t)1 << 25) : 0;
                F->ok(o.z.regime == Z_REG && o.z.r0 == r0 && o.z.sa == -1 && o.z.sb == -1 && o.z.fa == 0 && o.z.fb == 0,
                      "directed depth2_halfc: zword TL +inf in tile (%d, 0) HALF_OFFSET[0] %d: r0 %" PRId64 " (want %" PRId64
                      ") sa %d sb %d", v ? 2 : 0, h, o.z.r0, r0, o.z.sa, o.z.sb);
                for (int jj = 0; jj < 32; jj++)
                    for (int i = 0; i < 32; i++) {
                        std::string why;
                        F->ok(ZwordFact((r0 ? 1 : 0) - (i + jj), o.key[jj][i], &why),
                              "directed depth2_halfc: zword TL +inf tile (%d, 0) HALF_OFFSET[0] %d pixel (%d, %d): %s",
                              v ? 2 : 0, h, i, jj, why.c_str());
                    }
            }
            if (h == 0) {
                const Out& o = outs[2];
                F->ok(o.z.regime == Z_REG && o.z.r0 == -((int64_t)1 << 25),
                      "directed depth2_halfc: zovf_creg C0 at the corner: r0 %" PRId64 " (want -2^25)", o.z.r0);
            }
        }
    }

    // ---- trsort_recip: one triangle of determinant exactly f 2^126 (legs 2^63 and f 2^63), corners at depth d: f < 1
    //      an ordinary depth d, f >= 1 key 0 (2^126 included; f = 4 is an infinite determinant); both windings;
    //      page 10: corners of 2^116 (an infinite determinant); trsort_recipovf: corner depths inf 1 1, 1 2^127 1,
    //      2^120 x3, -inf 1 1 at f = 1: key 0
    {
        const double fs[] = {0.5, 0.75, 1 - ldexp(1, -24), 1, 1 + ldexp(1, -23), 1.25, 1.5, 2, 3, 4 - ldexp(1, -22), 4};
        const float ds[] = {1.0f, 0.5f, 0.25f};
        const int tiles[3][2] = {{0, 0}, {5, 3}, {19, 14}};
        jobs.clear();
        std::vector<std::pair<double, float>> what;
        for (double f : fs)
            for (float dz : ds)
                for (int wind = 0; wind < 2; wind++)
                    for (int t = 0; t < 3; t++) {
                        const float L = ldexpf(1.0f, 63), Lf = (float)(f * ldexp(1, 63));
                        Job j = wind ? Tri(0, 0, fb(dz), 0, Lf, fb(dz), L, 0, fb(dz), tiles[t][0], tiles[t][1], t & 1)
                                     : Tri(0, 0, fb(dz), L, 0, fb(dz), 0, Lf, fb(dz), tiles[t][0], tiles[t][1], t & 1);
                        jobs.push_back(j);
                        what.push_back({f, dz});
                    }
        const float big = ldexpf(1.0f, 116);
        jobs.push_back(Tri(0, 0, fb(1.0f), big, 0, fb(1.0f), 0, big, fb(1.0f), 3, 2, true));
        what.push_back({1e9, 1.0f});
        const uint32_t ovf[4][3] = {{0x7f800000u, 0x3f800000u, 0x3f800000u}, {0x3f800000u, 0x7f000000u, 0x3f800000u},
                                    {0x7b800000u, 0x7b800000u, 0x7b800000u}, {0xff800000u, 0x3f800000u, 0x3f800000u}};
        for (int k = 0; k < 4; k++) {
            const float L = ldexpf(1.0f, 63);
            jobs.push_back(Tri(0, 0, ovf[k][0], L, 0, ovf[k][1], 0, L, ovf[k][2], 1, 1, true));
            what.push_back({1, -1.0f});
        }
        const std::vector<Out> outs = run("directed trsort_recip");
        for (size_t i = 0; i < jobs.size(); i++) {
            const double f = what[i].first;
            const float dz = what[i].second;
            const bool zero = f >= 1;
            for (int jj = 0; jj < 32; jj++)
                for (int c = 0; c < 32; c++) {
                    const int64_t k = outs[i].key[jj][c];
                    const bool ok = zero ? k == 0 : (k <= K(fb(dz)) && k > K(fb(dz * 0.999f)));
                    if (!ok) {
                        F->ok(false, "directed trsort_recip: f %.9g depth %g job %zu pixel (%d, %d): key %016" PRIx64
                              " (want %s)", f, dz, i, c, jj, (uint64_t)k, zero ? "0" : "the corners' depth");
                        jj = 32;
                        break;
                    }
                }
        }
    }

    // ---- determinant-zero means (three corners at one point): perpmean_bg, depthgaps_detneg, depthgaps_dzinf
    {
        struct Mean { uint32_t z[3]; int kind; uint32_t word; const char* name; };   // kind 0 word, 1 between +-2^127
        std::vector<Mean> ms = {
            {{0x42c80000u, 0x42c80000u, 0x42c80000u}, 0, 0x42c80000u, "detneg 100"},
            {{0x3fc00000u, 0x3fc00000u, 0x3fc00000u}, 0, 0x3fc00000u, "detneg 1.5"},
            {{0x42c80020u, 0x42c80020u, 0x42c80020u}, 0, 0x42c80020u, "detneg 100 + 2^-12"},
            {{0x7f000000u, 0x7f000000u, 0x7f000000u}, 0, 0x7f000000u, "perpmean_bg 3 x 2^127"},
            {{0x7f7fffffu, 0x7f7fffffu, 0x7f7fffffu}, 0, 0x7f000000u, "perpmean_bg 3 x max"},
            {{0x7f000000u, 0x7f000000u, 0xff000000u}, 0, 0x7f000000u, "perpmean_bg 2^127 + 2^127 - 2^127"},
            {{0xff000000u, 0xff000000u, 0xff000000u}, 0, 0xff000000u, "perpmean_bg 3 x -2^127"},
            {{0xff7fffffu, 0xff7fffffu, 0xff7fffffu}, 0, 0xff000000u, "perpmean_bg 3 x -max"},
            {{0xff000000u, 0xff000000u, 0x7f000000u}, 0, 0xff000000u, "perpmean_bg -2^127 - 2^127 + 2^127"},
            {{0x7f800000u, 0x3f800000u, 0x3f800000u}, 0, 0x7f000000u, "dzinf +inf 1 1"},
            {{0x3f800000u, 0x3f800000u, 0x7f800000u}, 0, 0x7f000000u, "dzinf 1 1 +inf"},
            {{0x7f800001u, 0x3f800000u, 0x3f800000u}, 0, 0x7f000000u, "dzinf 7f800001 1 1"},
            {{0x7f000000u, 0x7f000000u, 0x00000000u}, 0, 0x7f000000u, "dzinf 2^127 2^127 0"},
            {{0x7149f2cau, 0x7149f2cau, 0x7f800000u}, 0, 0x7f000000u, "dzinf 1e30 1e30 +inf"},
            {{0x7fc00000u, 0xff800000u, 0x3f800000u}, 0, 0x7f000000u, "dzinf NaN 7fc00000 -inf 1"},
            {{0xff800000u, 0x7fffffffu, 0x3f800000u}, 0, 0x7f000000u, "dzinf -inf NaN 7fffffff 1"},
            {{0x7fc00000u, 0xff800001u, 0x3f800000u}, 0, 0x7f000000u, "dzinf NaN 7fc00000 NaN ff800001 1"},
            {{0x7f800002u, 0xff800001u, 0x3f800000u}, 0, 0x7f000000u, "dzinf NaN 7f800002 NaN ff800001 1"},
            {{0x7f800001u, 0xff800001u, 0x3f800000u}, 1, 0, "dzinf NaN 7f800001 NaN ff800001 1"},
            {{0x7f800000u, 0xff800000u, 0x3f800000u}, 1, 0, "dzinf +inf -inf 1"},
            {{0x7fc00000u, 0x3f800000u, 0xff800000u}, 1, 0, "dzinf NaN 7fc00000 1 -inf"},
            {{0x7fc00000u, 0x7fc00000u, 0xff800000u}, 1, 0, "dzinf NaN 7fc00000 x2 -inf"},
        };
        // depthgaps_detneg: -100 - d ulp as -100 for d = 1 .. 15, as -100 - 0x100 ulp for d = 16 .. 0x10f
        static char names[0x110][40];
        for (int dd = 1; dd < 0x110; dd++) {
            snprintf(names[dd], sizeof names[dd], "detneg -100 - %d ulp", dd);
            const uint32_t v = 0xc2c80000u + (uint32_t)dd;
            ms.push_back({{v, v, v}, 0, dd < 16 ? 0xc2c80000u : 0xc2c80100u, names[dd]});
        }
        jobs.clear();
        for (size_t k = 0; k < ms.size(); k++)
            jobs.push_back(Tri(10.25f, 10.25f, ms[k].z[0], 10.25f, 10.25f, ms[k].z[1], 10.25f, 10.25f, ms[k].z[2], 0, 0,
                               k & 1));
        const std::vector<Out> outs = run("directed perpmean");
        for (size_t k = 0; k < ms.size(); k++) {
            const int64_t key = outs[k].key[5][7];
            const bool ok = ms[k].kind == 0 ? key == K(ms[k].word)
                                            : (key > K(0xff000000u) && key < K(0x7f000000u));
            F->ok(ok && outs[k].z.regime == Z_CONST, "directed perpmean: %s: key %016" PRIx64 " (%08x)", ms[k].name,
                  (uint64_t)key, p2tb::zkey_bits(key));
        }
    }

    // ---- zspec pages 3-6: a plane over a cell from v to -v (slopes of 2v / 32 a pixel): v = 2^-124 is its start at
    //      every pixel (the slopes below 2^-126 are 0), v = 2^-126 is 0 (the start below 2^-126 too)
    {
        jobs.clear();
        for (int k = 0; k < 2; k++) {
            const float v = ldexpf(1.0f, k ? -126 : -124);
            jobs.push_back(Tri(0, 0, fb(v), 32, 0, fb(-v), 0, 32, fb(v), 0, 0, true));
            jobs.push_back(Tri(64, 32, fb(v), 96, 32, fb(-v), 64, 64, fb(v), 2, 1, true));
        }
        const std::vector<Out> outs = run("directed zspec");
        for (size_t k = 0; k < jobs.size(); k++) {
            const int64_t k0 = outs[k].key[0][0];
            bool flat = true;
            for (int jj = 0; jj < 32; jj++)
                for (int i = 0; i < 32; i++)
                    flat = flat && outs[k].key[jj][i] == k0;
            F->ok(flat && (k < 2 ? k0 > 0 : k0 == 0), "directed zspec: plane %zu: %s, key %016" PRIx64, k,
                  flat ? "flat" : "not flat", (uint64_t)k0);
        }
    }
    w.print("directed");
    printf("isp_depth: section directed %ld cases\n", cases);
}

// ---------------------------------------------------------------------------------------------------------------
// zmeas: the archived brackets (dreamcast-tests model/export_z.py's .zme: "PVRZME1\0", int32 count, per record float32
// x[3], y[3], z[3], px, py, float64 lo, hi): the console's stored depth at pixel (px, py) is at least lo and below hi
// (NaN: no bound), the depths compared as the ISP compares them (model/depthprobe: StoredDepth order); every pixel
// sampled at its centre
static std::vector<std::string> ListDir(const std::string& dir, const std::string& suffix)
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

struct ZmeRec { float x[3], y[3], z[3], px, py; double lo, hi; };

static bool LoadZme(const std::string& path, std::vector<ZmeRec>& out)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f)
        return false;
    char magic[8];
    int32_t n = 0;
    bool ok = fread(magic, 1, 8, f) == 8 && !memcmp(magic, "PVRZME1", 7) && fread(&n, 4, 1, f) == 1;
    for (int i = 0; ok && i < n; i++) {
        ZmeRec r;
        ok = fread(r.x, 4, 3, f) == 3 && fread(r.y, 4, 3, f) == 3 && fread(r.z, 4, 3, f) == 3 && fread(&r.px, 4, 1, f) == 1 &&
             fread(&r.py, 4, 1, f) == 1 && fread(&r.lo, 8, 1, f) == 1 && fread(&r.hi, 8, 1, f) == 1;
        if (ok)
            out.push_back(r);
    }
    fclose(f);
    return ok;
}

static void Zmeas(Dut& dut, const std::string& dir)
{
    F->set("zmeas");
    const std::vector<std::string> names = ListDir(dir, ".zme");
    F->ok(names.size() == 13, "zmeas: %zu sets in %s (13 expected)", names.size(), dir.c_str());
    Widths w;
    CheckOpt opt;
    opt.widths = false;
    long brackets = 0, inside = 0, both = 0;
    uint64_t idx = 0;
    for (const std::string& n : names) {
        std::vector<ZmeRec> recs;
        if (!F->ok(LoadZme(dir + "/" + n + ".zme", recs), "zmeas: cannot read %s.zme", n.c_str()))
            continue;
        long setIn = 0, setN = 0;
        std::vector<Job> jobs;
        std::vector<const ZmeRec*> who;
        auto flush = [&]() {
            std::vector<Out> outs;
            dut.run(jobs, outs);
            for (size_t k = 0; k < jobs.size(); k++) {
                const ZmeRec& r = *who[k];
                Ref ref;
                RefSetup(jobs[k], ref);
                CheckSetup("zmeas", jobs[k], outs[k], ref, w, opt);
                const int i = (int)(r.px - 32 * jobs[k].tileX), jj = jobs[k].jf;
                const int64_t m = outs[k].key[jj][i];
                auto end = [](double v) { return StoredDepth::Bits(fb((float)v)).k; };
                const bool ok = (std::isnan(r.lo) || m >= end(r.lo)) && (std::isnan(r.hi) || m < end(r.hi));
                setIn += ok;
                setN++;
                if (!std::isnan(r.lo) && !std::isnan(r.hi))
                    both++;
                F->ok(ok, "zmeas %s: pixel (%.1f, %.1f): console in [%.9g, %.9g), RTL key %016" PRIx64 " (%08x)", n.c_str(),
                      r.px, r.py, r.lo, r.hi, (uint64_t)m, p2tb::zkey_bits(m));
            }
            jobs.clear();
            who.clear();
        };
        for (const ZmeRec& r : recs) {
            if (!A->mine(idx++))
                continue;
            const int tx = (int)floor(r.px / 32), ty = (int)floor(r.py / 32);
            Job j;
            for (int k = 0; k < 3; k++) {
                j.x[k] = fb(r.x[k]);
                j.y[k] = fb(r.y[k]);
                j.z[k] = fb(r.z[k]);
            }
            j.tileX = (uint8_t)tx;
            j.tileY = (uint8_t)ty;
            j.half = true;
            j.jf = j.jl = (int)(r.py - 32 * ty);
            jobs.push_back(j);
            who.push_back(&r);
            if (jobs.size() >= kBatch)
                flush();
        }
        flush();
        brackets += setN;
        inside += setIn;
        printf("isp_depth: zmeas %-10s %6ld brackets (this shard), %6ld inside\n", n.c_str(), setN, setIn);
    }
    w.print("zmeas");
    printf("isp_depth: section zmeas %ld cases (%zu sets in %s; %ld brackets inside the console's, %ld with both ends)\n",
           brackets, names.size(), dir.c_str(), inside, both);
}

// ---------------------------------------------------------------------------------------------------------------
// covmeas zprobe: the archived console sets whose primitives are depth probes (covmeas --prim zprobe: triangles at the
// set's depths, z written, then a full-screen probe at probez drawn with Greater; the console's record `isp` is where
// the probe was not drawn), composed as dreamcast-tests model/covprobe composes a page (tb/isp_edge's Covmeas): the
// coverage from refsw3's edge unit (M2's gate checks the RTL's), the depth of every covered pixel from the RTL
struct Poly { int page = 0; float x[3] = {}, y[3] = {}; };
struct ZSet {
    std::string name;
    int halfofs = 7, pages = 0;
    float zs[3] = {1, 1, 1}, probez = 0.5f;
    std::vector<Poly> polys;
    std::vector<uint8_t> isp;
};

static bool LoadZSet(const std::string& dir, const std::string& name, ZSet& s, std::string* err)
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
    if (j.str("prim", "tri") != "zprobe") {
        *err = "prim " + j.str("prim", "tri") + ", not zprobe";
        return false;
    }
    s.name = name;
    s.halfofs = (int)j.num("halfofs", 7);
    s.probez = (float)j.num("probez", 0.5);
    const float z1 = (float)j.num("z", 1.0);
    const std::string zs = j.str("zs", "");
    for (int k = 0; k < 3; k++)
        s.zs[k] = z1;
    if (!zs.empty()) {
        float a, b, c;
        if (sscanf(zs.c_str(), "%f,%f,%f", &a, &b, &c) == 3)
            s.zs[0] = a, s.zs[1] = b, s.zs[2] = c;
    }
    p2npz::Array tx, ty, pg, cv;
    if (!z.array("tx", &tx) || !z.array("ty", &ty) || !z.array("page", &pg) || !z.array("isp", &cv)) {
        *err = z.error;
        return false;
    }
    const int n = (int)tx.shape[1];
    if (n != 3) {
        *err = "not triangles";
        return false;
    }
    s.polys.resize(tx.shape[0]);
    for (size_t k = 0; k < s.polys.size(); k++) {
        Poly& p = s.polys[k];
        p.page = (int)pg.i64(k);
        for (int c = 0; c < 3; c++) {
            p.x[c] = (float)tx.f64(k * 3 + c);
            p.y[c] = (float)ty.f64(k * 3 + c);
        }
    }
    s.pages = (int)cv.shape[0];
    s.isp.resize(cv.count());
    for (size_t k = 0; k < s.isp.size(); k++)
        s.isp[k] = cv.u8(k) != 0;
    return true;
}

struct Prim { float x[3], y[3], z[3]; uint32_t argb; bool greater, zwrite; };

// covprobe renderPage with the RTL's depth: the ISP in list order (depth compare ALWAYS or GREATER, the keys' order),
// then the TSP's colour of every pixel per span (refsw3's planes, Divide, ColorRounded)
static void RenderPage(Dut& dut, const std::vector<Prim>& prims, int halfofs, uint32_t* rgb, Widths& w, long* jobsRun)
{
    const bool half = halfofs & 1;
    // every (polygon, tile) of its corners' bounding box on the 640 x 480 screen: coverage and the RTL's keys
    struct PT { int p, tx, ty; uint32_t m[32]; };
    std::vector<PT> pts;
    std::vector<Job> jobs;
    for (size_t p = 0; p < prims.size(); p++) {
        const Prim& q = prims[p];
        float xmin = 1e30f, xmax = -1e30f, ymin = 1e30f, ymax = -1e30f;
        for (int i = 0; i < 3; i++) {
            xmin = std::min(xmin, q.x[i]); xmax = std::max(xmax, q.x[i]);
            ymin = std::min(ymin, q.y[i]); ymax = std::max(ymax, q.y[i]);
        }
        if (xmax < 0 || ymax < 0 || xmin >= 640 || ymin >= 480)
            continue;
        const int tx0 = xmin < 0 ? 0 : (int)(xmin / 32), tx1 = xmax >= 640 ? 19 : (int)(xmax / 32);
        const int ty0 = ymin < 0 ? 0 : (int)(ymin / 32), ty1 = ymax >= 480 ? 14 : (int)(ymax / 32);
        for (int ty = ty0; ty <= ty1; ty++)
            for (int tx = tx0; tx <= tx1; tx++) {
                PT t;
                t.p = (int)p;
                t.tx = tx;
                t.ty = ty;
                Job j;
                for (int i = 0; i < 3; i++) {
                    j.x[i] = fb(q.x[i]);
                    j.y[i] = fb(q.y[i]);
                    j.z[i] = fb(q.z[i]);
                }
                j.half = half;
                j.tileX = (uint8_t)tx;
                j.tileY = (uint8_t)ty;
                bool any = false;
                CoverMask(j.x, j.y, 32 * tx, 32 * ty, half, false, t.m);
                for (int jj = 0; jj < 32; jj++)
                    any = any || t.m[jj];
                if (!any)
                    continue;
                pts.push_back(t);
                jobs.push_back(j);
            }
    }
    std::vector<Out> outs;
    dut.run(jobs, outs);
    CheckOpt opt;
    opt.cover = true;
    for (size_t k = 0; k < jobs.size(); k++) {
        Ref r;
        RefSetup(jobs[k], r);
        CheckSetup("covmeas", jobs[k], outs[k], r, w, opt);
    }
    *jobsRun += (long)jobs.size();
    std::vector<int64_t> z(480 * 640, StoredDepth::Bits(0x38d1b717u & ~0x1ffffu).k);
    std::vector<int> tag(480 * 640, -1);
    // in list order: the pairs are in polygon order already
    for (size_t k = 0; k < pts.size(); k++) {
        const PT& t = pts[k];
        const Prim& q = prims[t.p];
        for (int jj = 0; jj < 32; jj++)
            for (int i = 0; i < 32; i++) {
                if (!(t.m[jj] >> i & 1))
                    continue;
                const int at = (t.ty * 32 + jj) * 640 + t.tx * 32 + i;
                const int64_t d = outs[k].key[jj][i];
                if (q.greater && !(d > z[at]))
                    continue;
                if (q.zwrite)
                    z[at] = d;
                tag[at] = t.p;
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
                            const Fp wv = pl[0].Value(x0h, yh, n, left, top);
                            uint32_t px = 0;
                            for (int c = 0; c < 3; c++) {
                                const int fbk = (q.argb >> (16 - 8 * c)) & 255;
                                const int v = pvrtsp::ColorRounded(pvrtsp::Divide(pl[1 + c].Value(x0h, yh, n, left, top), wv),
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

static void Covmeas(Dut& dut, const std::string& dir)
{
    F->set("covmeas");
    std::vector<std::string> names;
    for (const std::string& n : ListDir(dir, ".npz"))
        if (n.find("zprobe") != std::string::npos)
            names.push_back(n);
    F->ok(!names.empty(), "covmeas: no zprobe sets in %s", dir.c_str());
    Widths w;
    long sets = 0, pixels = 0, drawn = 0, wrong = 0, jobsRun = 0;
    for (size_t k = 0; k < names.size(); k++) {
        if (!A->mine(k))
            continue;
        ZSet s;
        std::string err;
        if (!F->ok(LoadZSet(dir, names[k], s, &err), "covmeas %s: %s", names[k].c_str(), err.c_str()))
            continue;
        long setWrong = 0;
        for (int pg = 0; pg < s.pages; pg++) {
            std::vector<Prim> prims;
            for (const Poly& p : s.polys) {
                if (p.page != pg)
                    continue;
                Prim q = {};
                for (int i = 0; i < 3; i++) {
                    q.x[i] = p.x[i];
                    q.y[i] = p.y[i];
                    q.z[i] = s.zs[i];
                }
                q.argb = 0xffff0000u;
                q.zwrite = true;
                prims.push_back(q);
            }
            const float qx[2][3] = {{0, 640, 0}, {0, 640, 640}}, qy[2][3] = {{0, 0, 480}, {480, 0, 480}};
            for (int t = 0; t < 2; t++) {
                Prim q = {};
                for (int i = 0; i < 3; i++) {
                    q.x[i] = qx[t][i];
                    q.y[i] = qy[t][i];
                    q.z[i] = s.probez;
                }
                q.argb = 0xff00ff00u;
                q.greater = true;
                prims.push_back(q);
            }
            std::vector<uint32_t> rgb(480 * 640);
            RenderPage(dut, prims, s.halfofs, rgb.data(), w, &jobsRun);
            const uint8_t* c = s.isp.data() + (size_t)pg * 480 * 640;
            long wpg = 0;
            int first = -1;
            for (int at = 0; at < 480 * 640; at++) {
                const uint8_t mine = ((rgb[at] >> 8) & 255) < 128;
                drawn += c[at];
                if (mine != c[at]) {
                    if (first < 0)
                        first = at;
                    wpg++;
                }
            }
            pixels += 480 * 640;
            setWrong += wpg;
            F->ok(wpg == 0, "covmeas %s page %d: %ld pixels differ from the console (first (%d, %d))", s.name.c_str(), pg,
                  wpg, first % 640, first / 640);
        }
        wrong += setWrong;
        sets++;
        printf("isp_depth: covmeas %-16s halfofs %d pages %d polygons %5zu zs %g,%g,%g probez %g: %ld pixels differ\n",
               s.name.c_str(), s.halfofs, s.pages, s.polys.size(), s.zs[0], s.zs[1], s.zs[2], s.probez, setWrong);
    }
    w.print("covmeas");
    printf("isp_depth: section covmeas %ld cases (%zu zprobe sets in %s; %ld jobs, %ld pixels, %ld probe-hidden on the "
           "console, %ld differ)\n", sets, names.size(), dir.c_str(), jobsRun, pixels, drawn, wrong);
}

// ---------------------------------------------------------------------------------------------------------------
// tria: the console pages' own primitives with their depths (build/vec/<test>.trz), per tile, every pixel
static void Tria(Dut& dut, const std::string& dir)
{
    F->set("tria");
    const std::vector<std::string> names = ListDir(dir, ".trz");
    F->ok(!names.empty(), "tria: no .trz files in %s (make isp-depth-vec)", dir.c_str());
    Widths w;
    long recs = 0, used = 0, quads = 0;
    uint64_t idx = 0;
    std::map<std::string, std::array<long, 4>> per;     // records, used, keys wrong, jobs wrong
    for (const std::string& n : names) {
        std::vector<uint8_t> raw;
        uint64_t count = 0;
        if (!F->ok(p2tb::VecFile::read(dir + "/" + n + ".trz", p2tri::kTriZMagic, sizeof(p2tri::TriZRec), &raw, &count),
                   "tria: cannot read %s.trz", n.c_str()))
            continue;
        const p2tri::TriZRec* rs = (const p2tri::TriZRec*)raw.data();
        recs += (long)count;
        std::vector<Job> jobs;
        std::vector<bool> isQuad;
        long jobsWrong = 0, nUsed = 0;
        auto flush = [&]() {
            std::vector<Out> outs;
            dut.run(jobs, outs);
            for (size_t k = 0; k < jobs.size(); k++) {
                Ref r;
                RefSetup(jobs[k], r);
                CheckOpt opt;
                opt.cover = !isQuad[k];
                std::string ctx = "tria " + n;
                if (!CheckSetup(ctx.c_str(), jobs[k], outs[k], r, w, opt))
                    jobsWrong++;
            }
            jobs.clear();
            isQuad.clear();
        };
        for (uint64_t k = 0; k < count; k++) {
            // quick: one record in eight and the first of each test
            const bool pick = A->full || k == 0 || (k % 8) == 0;
            if (!pick)
                continue;
            if (!A->mine(idx++))
                continue;
            const p2tri::TriZRec& q = rs[k];
            Job j;
            for (int c = 0; c < 3; c++) {
                j.x[c] = q.x[c];
                j.y[c] = q.y[c];
                j.z[c] = q.z[c];
            }
            j.perp = q.perpVal;
            j.half = q.halfOffset & 1;
            j.tileX = q.tileX;
            j.tileY = q.tileY;
            jobs.push_back(j);
            isQuad.push_back(q.quad != 0);
            quads += q.quad != 0;
            nUsed++;
            if (jobs.size() >= kBatch)
                flush();
        }
        flush();
        used += nUsed;
        printf("isp_depth: tria %-20s %7" PRIu64 " records, %6ld checked here, %ld differ\n", n.c_str(), count, nUsed,
               jobsWrong);
    }
    w.print("tria");
    printf("isp_depth: section tria %ld cases (%zu tests, %ld records, %ld quads)\n", used, names.size(), recs, quads);
}

// ---------------------------------------------------------------------------------------------------------------
// random: planes of every class (PLAN M3 item 4)
struct Gen {
    p2tb::Rng& g;
    explicit Gen(p2tb::Rng& r) : g(r) {}
    bool coin() { return g.u64() & 1; }
    float sgn() { return coin() ? -1.0f : 1.0f; }
    float frac(int den) { return (float)g.below((uint64_t)den) / (float)den; }
    // widths4f3d's coordinate classes
    float coord()
    {
        switch (g.below(9)) {
        case 0: return (float)g.below(2048) * 0.5f + (float)g.below(16) / 16.0f;
        case 1: { uint32_t u = fb((float)g.below(1280)); u += (int)g.below(25) - 12; return fl(u); }
        case 2: return ldexpf((float)g.below(0xffffff), (int)g.below(60) - 40) * sgn();
        case 3: return (float)g.below(640) + ldexpf((float)g.below(1000), -(int)g.below(30));
        case 4: return ldexpf(1.0f + frac(1000), (int)g.below(128)) * sgn();
        case 5: return ldexpf(1.0f + frac(1 << 23), 118 + (int)g.below(10)) * sgn();
        case 6: return ldexpf(1.0f + frac(1 << 23), 58 + (int)g.below(8)) * sgn();
        case 7: return ldexpf(1.0f + frac(1 << 23), -126 + (int)g.below(3)) * sgn();
        default: return (float)((int)g.below(4000) - 2000) / 7.0f;
        }
    }
    // depths: widths4f3d's, and depthgaps' (starts of exactly 0, below zero, near 2^-126, 2^126 .. 2^128)
    uint32_t depth()
    {
        switch (g.below(11)) {
        case 0: return fb(ldexpf(1.0f + frac(100000), (int)g.below(40) - 20) * (g.below(3) ? 1.0f : -1.0f));
        case 1: return fb(0.5f + g.below(1000) * 1e-6f);
        case 2: return fb(ldexpf((float)g.below(0xffffff), -(int)g.below(60)) * sgn());
        case 3: return fb((float)g.below(1000) / 997.0f - 0.3f);
        case 4: return fb(ldexpf(1.0f + frac(1 << 23), -126 + (int)g.below(4)) * sgn());
        case 5: return fb(ldexpf(1.0f + frac(1 << 23), 100 + (int)g.below(28)) * sgn());
        case 6: return coin() ? 0u : 0x80000000u;
        case 7: return g.u32();                                     // any word: NaN, infinities, denormals
        case 8: return fb(-ldexpf(1.0f + frac(1000), (int)g.below(20)));
        case 9: { const uint32_t s[6] = {0x7f800000u, 0xff800000u, 0x7f7fffffu, 0xff7fffffu, 0x7f000000u, 0xff000000u};
                  return s[g.below(6)]; }
        default: return fb(ldexpf(1.0f + frac(1 << 23), 124 + (int)g.below(4)) * sgn());
        }
    }
};

static Job RandomJob(p2tb::Rng& rng, int* cls)
{
    Gen G(rng);
    Job j;
    j.half = G.coin();                                              // HALF_OFFSET[0]: the corner half the time
    j.tileX = (uint8_t)rng.below(20);
    j.tileY = (uint8_t)rng.below(15);
    j.perp = rng.below(10) == 0 ? 0x3c000000u : 0;                  // FPU_PERP_VAL 1/128 now and then
    const int c = (int)rng.below(16);
    *cls = c;
    const float bx = 32.0f * j.tileX + (float)rng.below(48) - 8, by = 32.0f * j.tileY + (float)rng.below(48) - 8;
    if (c <= 5) {
        // ordinary planes near the tile: pixel-size, tile-size, sub-pixel, wild (widths4f3d)
        const int scale = (int)rng.below(4);
        for (int k = 0; k < 3; k++) {
            float sx, sy;
            if (scale == 3 || rng.below(8) == 0) {
                sx = G.coord();
                sy = G.coord();
            } else {
                const float r = scale == 0 ? 4.0f : scale == 1 ? 64.0f : ldexpf(1.0f, -(int)rng.below(40));
                sx = bx + r * ((float)((int)rng.below(2001) - 1000) / 1000.0f);
                sy = by + r * ((float)((int)rng.below(2001) - 1000) / 1000.0f);
            }
            j.x[k] = fb(sx);
            j.y[k] = fb(sy);
            j.z[k] = G.depth();
            if (rng.below(3) == 0 && k > 0)
                j.z[k] = fb(fl(j.z[0]) + ldexpf((float)((int)rng.below(2001) - 1000), -(int)rng.below(40)));
        }
        if (rng.below(50) == 0) {                                   // determinant zero
            j.x[2] = j.x[0];
            j.y[2] = j.y[0];
        }
    } else if (c == 6) {
        // depthgaps: a plane crossing zero near the tile's first pixel, or a start of exactly 0 (z = C + A (x - y)),
        // slopes 2^50 and more times the start
        const float A0 = ldexpf(1.0f + G.frac(64), -(int)rng.below(14)) * G.sgn();
        const float C0 = rng.below(3) ? 0.0f : ldexpf(1.0f, -(int)rng.below(100) - 20) * G.sgn();
        const float x0 = 32.0f * j.tileX, y0 = 32.0f * j.tileY;
        const float L = (float)(4 + rng.below(60));
        const float xs[3] = {x0, x0 + L, x0}, ys[3] = {y0, y0, y0 + L};
        for (int k = 0; k < 3; k++) {
            j.x[k] = fb(xs[k]);
            j.y[k] = fb(ys[k]);
            j.z[k] = fb(C0 + A0 * ((xs[k] - x0) - (ys[k] - y0)));
        }
    } else if (c == 7) {
        // near 2^126: a right triangle of legs about 2^63 whose determinant is within a few units of 2^126 (exactly too),
        // either winding, any tile; or an infinite one (corners from 2^64)
        uint32_t lm = 0x800000u | (rng.u32() & 0x7fffffu);
        const int le = 62 + (int)rng.below(3), me = 125 - le;
        uint64_t mm = (uint64_t)((((unsigned __int128)1 << 47) + lm - 1) / lm) + (uint64_t)rng.range(-4, 4);
        if (rng.below(4) == 0) {
            mm = 0x800000u;                                         // a product of exactly 2^126 (2^63 2^63)
            lm = 0x800000u;
        }
        if (mm < 0x800000u || mm > 0xffffffu)
            mm = 0x800000u;
        float L = ldexpf((float)lm, le - 23), M = ldexpf((float)mm, me - 23);
        if (rng.below(6) == 0) {
            L = ldexpf(1.0f, 64 + (int)rng.below(60));              // infinite
            M = ldexpf(1.0f, 64 + (int)rng.below(60));
        }
        const float ox = (float)rng.below(640), oy = (float)rng.below(480);
        j.x[0] = fb(ox); j.y[0] = fb(oy);
        j.x[1] = fb(ox + L); j.y[1] = fb(oy);
        j.x[2] = fb(ox); j.y[2] = fb(oy + M);
        if (G.coin()) {
            std::swap(j.x[1], j.x[2]);
            std::swap(j.y[1], j.y[2]);
        }
        for (int k = 0; k < 3; k++)
            j.z[k] = rng.below(3) ? fb(1.0f + G.frac(1000)) : G.depth();
    } else if (c <= 9) {
        // zcoord / zedge: tile (0, 0), coordinates among +-0, +-(1 .. 1.5) 2^-126, +-1, small integers; depths huge or
        // infinite
        j.tileX = j.tileY = 0;
        auto cc = [&]() -> float {
            switch (rng.below(4)) {
            case 0: return G.coin() ? 0.0f : -0.0f;
            case 1: return ldexpf(1.0f + (float)rng.below(5) / 8.0f, -126) * G.sgn();
            case 2: return G.coin() ? (G.coin() ? 1.0f : -1.0f) : (float)rng.below(64);
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
        // REG: an infinite or overflowing corner (zword, nantr_*, zovf_creg) near the tile, the other slope finite
        const float x0 = 32.0f * j.tileX + (float)rng.below(32), y0 = 32.0f * j.tileY + (float)rng.below(32);
        const float L = (float)(1 + rng.below(64));
        const float xs[3] = {x0, x0 + L, x0}, ys[3] = {y0, y0, y0 + L};
        const int bad = (int)rng.below(3);
        const uint32_t sp[6] = {0x7f800000u, 0xff800000u, 0x7fc00000u, 0x7f7fffffu, 0x7f000000u, 0x7b000000u};
        for (int k = 0; k < 3; k++) {
            j.x[k] = fb(xs[k]);
            j.y[k] = fb(ys[k]);
            j.z[k] = k == bad ? sp[rng.below(6)] : (G.coin() ? fb(ldexpf(1.0f + G.frac(1 << 20), 90 + (int)rng.below(36)) * G.sgn())
                                                            : G.depth());
        }
        if (G.coin())
            std::swap(j.x[1], j.x[2]), std::swap(j.y[1], j.y[2]);
    } else if (c == 11) {
        // products at 2^128 and constants overflowing: corners far away with ordinary depths (depthgaps_infstart,
        // zovf_lim, zovf_c, depthgaps_edges, depthgaps_bigpos)
        for (int k = 0; k < 3; k++) {
            const bool far = rng.below(3) == 0;
            j.x[k] = fb(far ? ldexpf(1.0f + G.frac(1 << 23), 100 + (int)rng.below(28)) * G.sgn() : bx + (float)rng.below(64));
            j.y[k] = fb(far ? ldexpf(1.0f + G.frac(1 << 23), 100 + (int)rng.below(28)) * G.sgn() : by + (float)rng.below(64));
            j.z[k] = G.coin() ? G.depth() : fb(ldexpf(1.0f + G.frac(1 << 23), 110 + (int)rng.below(18)) * G.sgn());
        }
    } else if (c == 12) {
        // small triangles at the origin with huge depths (depthgaps_bigslope, _bigpair): slopes of 2^123 and more
        j.tileX = j.tileY = 0;
        const float L = (float)(2 + rng.below(6));
        const float xs[3] = {0, L, 0}, ys[3] = {0, 0, L};
        for (int k = 0; k < 3; k++) {
            j.x[k] = fb(xs[k] + (G.coin() ? 0.0f : G.frac(16)));
            j.y[k] = fb(ys[k] + (G.coin() ? 0.0f : G.frac(16)));
            j.z[k] = rng.below(4) ? fb(ldexpf(1.0f + G.frac(16), 120 + (int)rng.below(8)) * G.sgn()) : 0u;
        }
    } else if (c == 13) {
        // tiny triangles (2^-10 .. 2^-4 a side) around a pixel centre near the origin (depth2_regbelow), and slivers
        const float cx = (float)rng.below(64) + 0.5f, cy = (float)rng.below(64) + 0.5f;
        const float s = ldexpf(1.0f, -(int)rng.below(7) - 4);
        j.tileX = (uint8_t)(cx / 32);
        j.tileY = (uint8_t)(cy / 32);
        const float xs[3] = {cx - s, cx + s, cx}, ys[3] = {cy - s, cy - s, cy + s};
        for (int k = 0; k < 3; k++) {
            j.x[k] = fb(xs[k]);
            j.y[k] = fb(ys[k]);
            j.z[k] = rng.below(3) ? fb(-ldexpf(1.0f + G.frac(1 << 16), (int)rng.below(30) - 10)) : G.depth();
        }
    } else {
        // denormal and near-2^-126 depths over a tile (depth2_denorm, depthgaps_tiny, depthgaps_tinyramp, zspec)
        const float x0 = 32.0f * j.tileX, y0 = 32.0f * j.tileY;
        const float xs[3] = {x0, x0 + 32, x0}, ys[3] = {y0, y0, y0 + 32};
        for (int k = 0; k < 3; k++) {
            j.x[k] = fb(xs[k] + (G.coin() ? 0.0f : G.frac(4)));
            j.y[k] = fb(ys[k] + (G.coin() ? 0.0f : G.frac(4)));
            j.z[k] = fb(ldexpf(1.0f + G.frac(1 << 23), -126 + (int)rng.below(6)) * (rng.below(4) ? 1.0f : -1.0f));
            if (rng.below(6) == 0)
                j.z[k] = rng.u32() & 0x807fffffu;                  // a denormal word (a zero to the setup)
        }
    }
    return j;
}

static void Random(Dut& dut, const char* sec, uint64_t n, bool stream)
{
    F->set(sec);
    Widths w;
    CheckOpt opt;
    opt.cover = true;
    std::vector<Job> jobs;
    long used = 0, classes[16] = {};
    long regimes[3] = {}, byHalf[2][3] = {};
    for (uint64_t i = 0; i < n; i++) {
        if (!A->mine(i))
            continue;
        p2tb::Rng rng = p2tb::Rng::of(A->seed ^ (stream ? 0x5157ull : 0), i);
        int c = 0;
        Job j = RandomJob(rng, &c);
        if (stream) {
            j.jf = (int)rng.below(32);
            j.jl = j.jf + (int)rng.below(32 - j.jf);
            j.rowsV = rng.below(16) != 0;
        }
        classes[c]++;
        jobs.push_back(j);
        used++;
        if (jobs.size() >= kBatch) {
            std::vector<Out> outs;
            dut.run(jobs, outs);
            for (size_t k = 0; k < jobs.size(); k++) {
                Ref r;
                RefSetup(jobs[k], r);
                CheckSetup(sec, jobs[k], outs[k], r, w, opt);
                regimes[r.d.regime]++;
                byHalf[jobs[k].half ? 1 : 0][r.d.regime]++;
            }
            jobs.clear();
        }
    }
    if (!jobs.empty()) {
        std::vector<Out> outs;
        dut.run(jobs, outs);
        for (size_t k = 0; k < jobs.size(); k++) {
            Ref r;
            RefSetup(jobs[k], r);
            CheckSetup(sec, jobs[k], outs[k], r, w, opt);
            regimes[r.d.regime]++;
            byHalf[jobs[k].half ? 1 : 0][r.d.regime]++;
        }
    }
    if (used >= 2000)
        F->ok(byHalf[0][0] && byHalf[0][1] && byHalf[0][2] && byHalf[1][0] && byHalf[1][1] && byHalf[1][2],
              "%s: a regime not represented at a sample point (corner: CONST %ld REG %ld BLOCK %ld; centre: CONST %ld "
              "REG %ld BLOCK %ld)", sec, byHalf[0][0], byHalf[0][1], byHalf[0][2], byHalf[1][0], byHalf[1][1],
              byHalf[1][2]);
    w.print(sec);
    printf("isp_depth: %s regimes CONST %ld REG %ld BLOCK %ld (at the corner: CONST %ld REG %ld BLOCK %ld); classes", sec,
           regimes[0], regimes[1], regimes[2], byHalf[0][0], byHalf[0][1], byHalf[0][2]);
    for (int c = 0; c < 16; c++)
        printf(" %ld", classes[c]);
    printf("\n");
    printf("isp_depth: section %s %ld cases\n", sec, used);
}

// ---------------------------------------------------------------------------------------------------------------
// rdesc: raster-only descriptors around the lanes' boundaries, against the lane formula (isp 9.6)
static Job RandomDesc(p2tb::Rng& rng)
{
    Job j;
    j.rasterOnly = true;
    ZDesc& d = j.d;
    const int kind = (int)rng.below(8);
    if (kind == 0) {
        d.regime = Z_CONST;
        d.key = (int64_t)rng.u64();
    } else if (kind <= 2) {
        d.regime = Z_REG;
        d.r0 = rng.range(-((int64_t)1 << 29), ((int64_t)1 << 29) - 1);
        if (rng.below(3) == 0)
            d.r0 = (int64_t)rng.range(-16, 15) << 25;                 // whole steps
        d.sa = (int)rng.range(-1, 1);
        d.sb = (int)rng.range(-1, 1);
        const int fsh = (int)rng.below(31);
        d.fa = rng.range(-((int64_t)1 << fsh) + 1, ((int64_t)1 << fsh) - 1);
        d.fb = rng.range(-((int64_t)1 << fsh) + 1, ((int64_t)1 << fsh) - 1);
        if (rng.below(3) == 0)
            d.fa = d.fb = 0;
    } else {
        d.regime = Z_BLOCK;
        // a block exponent and its grid as the setup makes them: gexp = gx - 26, E = clamp(gx), nsh = E - 15 - gexp
        const int gx = (int)rng.range(-130, 259);
        d.gexp = gx - 26;
        d.E = gx < -122 ? -122 : gx > 128 ? 128 : gx;
        d.nsh = d.E - 15 - d.gexp;
        // values: |t| < 2^29 over the tile (|S| < 2^27, |DX|, |DY| < 2^21 as the setup has them), near 0 often
        const int ssh = (int)rng.below(28), xsh = (int)rng.below(22), ysh = (int)rng.below(22);
        d.S = rng.range(-((int64_t)1 << ssh) + 1, ((int64_t)1 << ssh) - 1) * 2;
        if (d.S <= -((int64_t)1 << 27) || d.S >= ((int64_t)1 << 27))
            d.S /= 2;
        d.DX = rng.range(-((int64_t)1 << xsh) + 1, ((int64_t)1 << xsh) - 1);
        d.DY = rng.range(-((int64_t)1 << ysh) + 1, ((int64_t)1 << ysh) - 1);
        if (rng.below(4) == 0)
            d.S = -(d.DX * 2 * (int64_t)rng.below(32) + d.DY * 2 * (int64_t)rng.below(32));     // t crossing 0
        if (d.nsh < -14 || (d.nsh < 0 && rng.below(2) == 0)) {
            d.fbw = d.nsh < 0;                                       // the start cut to zero (num A5)
            if (d.fbw)
                d.S = 0;
        }
        if (d.nsh < -16 || d.nsh > 15) {
            // nsh outside the field only with fbw (then it is not read): the setup saturates it
            d.nsh = d.nsh < 0 ? -16 : 15;
            if (!d.fbw) {
                d.E = 128;
                d.gexp = 128 - 15 - 14;
                d.nsh = 14;
            }
        }
    }
    j.jf = (int)rng.below(32);
    j.jl = j.jf + (int)rng.below(32 - j.jf);
    if (rng.below(2) == 0) {
        j.jf = 0;
        j.jl = 31;
    }
    j.rowsV = rng.below(32) != 0;
    return j;
}

static void Rdesc(Dut& dut, const char* sec, uint64_t n)
{
    F->set(sec);
    std::vector<Job> jobs;
    long used = 0;
    Widths w;
    CheckOpt opt;
    for (uint64_t i = 0; i < n; i++) {
        if (!A->mine(i))
            continue;
        p2tb::Rng rng = p2tb::Rng::of(A->seed ^ 0xde5cull, i);
        jobs.push_back(RandomDesc(rng));
        used++;
        if (jobs.size() >= kBatch)
            RunChecked(dut, sec, jobs, w, opt);
    }
    if (!jobs.empty())
        RunChecked(dut, sec, jobs, w, opt);
    printf("isp_depth: section %s %ld cases\n", sec, used);
}

// ---------------------------------------------------------------------------------------------------------------
int main(int argc, char** argv)
{
    p2tb::raise_stack();
    Verilated::commandArgs(argc, argv);
    p2tb::Args args;
    if (!args.parse(argc, argv)) {
        fprintf(stderr, "isp_depth: %s\n", args.error.c_str());
        return 2;
    }
    A = &args;
    p2tb::Fails fails("isp_depth");
    F = &fails;
    p2tb::banner("isp_depth", args);
    const char* dct = getenv("DCTESTS");
    const std::string fit = !args.set.empty() ? args.set : std::string(dct ? dct : "../dreamcast-tests") + "/fit";
    const std::string vec = !args.vec.empty() ? args.vec : "build/vec";

    std::unique_ptr<Vp2_isp_depth_tb_top> top(new Vp2_isp_depth_tb_top);
    Dut dut(top.get());
    dut.rng = p2tb::Rng(args.seed ^ 0x51a11ull);
    dut.reset();

    const uint64_t nRandom = args.count(args.full ? 100000000ull : 1000000ull);
    const uint64_t nDesc = args.full ? 4000000ull : std::min<uint64_t>(100000ull, std::max<uint64_t>(nRandom / 10, 1000));
    if (args.want("directed") && args.mine(0))
        Directed(dut);
    if (args.want("zmeas"))
        Zmeas(dut, fit + "/zmeas_data");
    if (args.want("covmeas"))
        Covmeas(dut, fit + "/covmeas_data");
    if (args.want("tria"))
        Tria(dut, vec);
    if (args.want("random"))
        Random(dut, "random", nRandom, false);
    if (args.want("rdesc"))
        Rdesc(dut, "rdesc", nDesc);
    if (args.want("stream")) {
        dut.gapSu = 300;
        dut.gapRa = 300;
        dut.stall = 300;
        Random(dut, "stream", std::min<uint64_t>(nRandom / 4, 2000000ull), true);
        Rdesc(dut, "stream-rdesc", std::min<uint64_t>(nDesc / 4, 500000ull));
        dut.gapSu = dut.gapRa = dut.stall = 0;
    }
    printf("isp_depth: %" PRIu64 " clocks\n", dut.cycles);
    top->final();
    return fails.finish();
}

// isp_depth_dut.h: the DUT driver of tb/isp_depth (PLAN M3): (primitive, tile) jobs through p2_isp_depth_setup, each
// result carried by the testbench into p2_isp_depth_raster with the job's rows, its rows of 32 keys collected; random
// gaps on both inputs and random back-pressure on the rows (PLAN 1.2 section 4) when asked. Also raster-only jobs: a
// descriptor given directly.
#pragma once
#include <cstdint>
#include <cstdio>
#include <deque>
#include <vector>

#include "Vp2_isp_depth_tb_top.h"
#include "p2tb.h"

namespace depthtb {

enum { Z_CONST = 0, Z_REG = 1, Z_BLOCK = 2 };

// p2_ztile_t (rtl/v1/pkg/p2_pkg.sv)
struct ZDesc {
    int regime = Z_CONST;
    int64_t key = 0;
    int64_t r0 = 0, fa = 0, fb = 0;
    int sa = 0, sb = 0;
    int64_t S = 0, DX = 0, DY = 0;
    int gexp = 0, E = 0, nsh = 0;
    bool fbw = false;
};

// a tuple as the DUT's debug taps give it
struct Tup { bool neg = false, bad = false; int exp = 0; uint32_t mant = 0; };

struct Job {
    // setup input (unused for a raster-only job)
    uint32_t x[3] = {}, y[3] = {}, z[3] = {};
    uint32_t perp = 0;
    bool half = true;
    uint8_t tileX = 0, tileY = 0;
    // the rows the raster steps
    int jf = 0, jl = 31;
    bool rowsV = true;
    // raster-only: this descriptor instead of the setup's
    bool rasterOnly = false;
    ZDesc d;
};

struct Out {
    ZDesc z;
    Tup dbg[7];                   // a, b, c, det, first0, A, B
    bool fed = false;
    uint32_t rowsSeen = 0;
    int64_t key[32][32] = {};     // [row][column]
    int orderErrors = 0;
};

static inline int64_t sext(uint64_t v, int bits)
{
    const uint64_t m = 1ull << (bits - 1);
    v &= (bits >= 64) ? ~0ull : ((1ull << bits) - 1);
    return (int64_t)((v ^ m) - m);
}

struct Dut {
    typedef Vp2_isp_depth_tb_top Top;
    Top* t;
    p2tb::Rng rng{1};
    unsigned gapSu = 0, gapRa = 0, stall = 0;      // per mille
    uint64_t cycles = 0;

    explicit Dut(Top* top) : t(top) {}

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
        t->su_in_v = 0;
        t->ra_in_v = 0;
        t->ra_out_rdy = 1;
        t->clk = 0;
        t->eval();
        clock();
        clock();
        t->rst = 0;
        t->eval();
    }
    void driveSetup(const Job& j)
    {
        for (int k = 0; k < 3; k++) {
            t->su_x[k] = j.x[k];
            t->su_y[k] = j.y[k];
            t->su_z[k] = j.z[k];
        }
        t->su_perp = j.perp;
        t->su_half = j.half;
        t->su_tile_x = j.tileX;
        t->su_tile_y = j.tileY;
    }
    void readSetup(Out& o)
    {
        ZDesc& z = o.z;
        z.regime = t->su_regime;
        z.key = (int64_t)t->su_key;
        z.r0 = sext(t->su_r0, 30);
        z.sa = (int)sext(t->su_sa, 2);
        z.sb = (int)sext(t->su_sb, 2);
        z.fa = sext(t->su_fa, 31);
        z.fb = sext(t->su_fb, 31);
        z.S = sext(t->su_S, 28);
        z.DX = sext(t->su_DX, 23);
        z.DY = sext(t->su_DY, 23);
        z.gexp = (int)sext(t->su_gexp, 10);
        z.E = (int)sext(t->su_E, 9);
        z.nsh = (int)sext(t->su_nsh, 5);
        z.fbw = t->su_fbw;
        for (int k = 0; k < 7; k++) {
            const uint64_t w = t->su_dbg[k];
            o.dbg[k].mant = (uint32_t)(w & 0xffffff);
            o.dbg[k].exp = (int)sext(w >> 24, 10);
            o.dbg[k].bad = (w >> 34) & 1;
            o.dbg[k].neg = (w >> 35) & 1;
        }
    }
    void driveRaster(const ZDesc& z, const Job& j)
    {
        t->ra_regime = z.regime;
        t->ra_key = (uint64_t)z.key;
        t->ra_r0 = (uint32_t)z.r0 & 0x3FFFFFFFu;
        t->ra_sa = (uint32_t)z.sa & 3;
        t->ra_sb = (uint32_t)z.sb & 3;
        t->ra_fa = (uint32_t)z.fa & 0x7FFFFFFFu;
        t->ra_fb = (uint32_t)z.fb & 0x7FFFFFFFu;
        t->ra_S = (uint32_t)z.S & 0x0FFFFFFFu;
        t->ra_DX = (uint32_t)z.DX & 0x7FFFFFu;
        t->ra_DY = (uint32_t)z.DY & 0x7FFFFFu;
        t->ra_gexp = (uint32_t)z.gexp & 0x3FF;
        t->ra_E = (uint32_t)z.E & 0x1FF;
        t->ra_nsh = (uint32_t)z.nsh & 0x1F;
        t->ra_fbw = z.fbw;
        t->ra_jf = j.jf;
        t->ra_jl = j.jl;
        t->ra_rows_v = j.rowsV;
    }

    // run a batch to its end: outs[i] for jobs[i]
    void run(const std::vector<Job>& jobs, std::vector<Out>& outs)
    {
        outs.assign(jobs.size(), Out());
        size_t next = 0, done = 0, lastDone = 0;
        std::deque<size_t> suPipe, raQ, raRows;
        std::vector<int> lastRow(jobs.size(), -1);
        uint64_t idle = 0;
        while (done < jobs.size()) {
            bool feed = false;
            if (next < jobs.size() && raQ.size() < 16 && !(gapSu && rng.chance(gapSu))) {
                const Job& j = jobs[next];
                if (j.rasterOnly) {
                    outs[next].z = j.d;
                    outs[next].fed = true;
                    raQ.push_back(next);
                    next++;
                } else {
                    driveSetup(j);
                    feed = true;
                }
            }
            t->su_in_v = feed;
            const bool raV = !raQ.empty() && !(gapRa && rng.chance(gapRa));
            t->ra_in_v = raV;
            if (raV)
                driveRaster(outs[raQ.front()].z, jobs[raQ.front()]);
            t->ra_out_rdy = !(stall && rng.chance(stall));
            t->eval();
            const bool raTake = raV && t->ra_in_rdy;
            const bool rowX = t->ra_row_v && t->ra_out_rdy;
            const int rowJ = t->ra_row_j;
            const bool rowLast = t->ra_row_last;
            int64_t rowK[32];
            if (rowX)
                for (int i = 0; i < 32; i++)
                    rowK[i] = (int64_t)t->ra_zk[i];
            clock();
            if (feed)
                suPipe.push_back(next++);
            if (raTake) {
                const size_t i = raQ.front();
                raQ.pop_front();
                if (jobs[i].rowsV)
                    raRows.push_back(i);
                else
                    done++;
            }
            if (rowX) {
                if (raRows.empty()) {
                    outs[0].orderErrors++;
                } else {
                    const size_t i = raRows.front();
                    Out& o = outs[i];
                    const Job& j = jobs[i];
                    const int expect = lastRow[i] < 0 ? j.jf : lastRow[i] + 1;
                    if (rowJ != expect || (o.rowsSeen >> rowJ & 1))
                        o.orderErrors++;
                    o.rowsSeen |= 1u << rowJ;
                    for (int c = 0; c < 32; c++)
                        o.key[rowJ][c] = rowK[c];
                    lastRow[i] = rowJ;
                    if (rowLast != (rowJ == j.jl))
                        o.orderErrors++;
                    if (rowLast || rowJ == 31) {
                        raRows.pop_front();
                        done++;
                    }
                }
            }
            if (done != lastDone) {
                lastDone = done;
                idle = 0;
            } else if (++idle > 100000) {
                for (size_t i = 0; i < jobs.size(); i++)
                    outs[i].orderErrors++;
                fprintf(stderr, "isp_depth: the DUT hung (%zu of %zu jobs done)\n", done, jobs.size());
                return;
            }
            if (t->su_out_v) {
                const size_t i = suPipe.front();
                suPipe.pop_front();
                readSetup(outs[i]);
                outs[i].fed = true;
                raQ.push_back(i);
            }
        }
    }
};

}   // namespace depthtb

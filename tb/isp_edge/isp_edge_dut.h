// isp_edge_dut.h: the DUT driver of tb/isp_edge (PLAN M2): (primitive, tile) jobs through p2_isp_edge_setup, each result
// carried by the testbench into p2_isp_edge_raster, its rows collected; random gaps on both inputs and random
// back-pressure on the rows (PLAN 1.2 section 4) when asked. Also raster-only jobs: a descriptor given directly.
#pragma once
#include <cstdint>
#include <cstdio>
#include <deque>
#include <vector>

#include "Vp2_isp_edge_tb_top.h"
#include "p2tb.h"

namespace edgetb {

struct EdgeOut {
    bool cv = false, ci = false, big = false;
    int64_t t0 = 0, tx = 0, ty = 0;
    int zsh = 0;
    uint32_t far32 = 0;
};

struct Job {
    // setup input (unused for a raster-only job)
    uint32_t x[4] = {}, y[4] = {};
    bool quad = false, modvol = false, half = true;
    uint8_t cull = 0, tileX = 0, tileY = 0;
    uint32_t cullVal = 0;
    bool kill = false;            // hand the descriptor to the raster with kill, whatever the setup says
    // raster-only: this descriptor instead of the setup's
    bool rasterOnly = false;
    EdgeOut de[4];
    int djf = 0, djl = 31;
    bool drowsV = true;
};

struct Out {
    // setup
    bool bad = false, culled = false, flip = false;
    bool detNeg = false, detBad = false;
    int detExp = 0;
    uint32_t detMant = 0;
    EdgeOut e[4];
    int jf = 0, jl = 0;
    bool rowsV = false;
    // raster
    bool fed = false;             // the descriptor went to the raster
    uint32_t rowsSeen = 0;        // bit j: row j came out
    uint32_t mask[32] = {};
    int orderErrors = 0;          // rows out of order, a row twice, row_last not on the last
};

static inline int64_t sext(uint64_t v, int bits)
{
    const uint64_t m = 1ull << (bits - 1);
    v &= (bits >= 64) ? ~0ull : ((1ull << bits) - 1);
    return (int64_t)((v ^ m) - m);
}

struct Dut {
    typedef Vp2_isp_edge_tb_top Top;
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
        for (int k = 0; k < 4; k++) {
            t->su_x[k] = j.x[k];
            t->su_y[k] = j.y[k];
        }
        t->su_quad = j.quad;
        t->su_modvol = j.modvol;
        t->su_cull_mode = j.cull;
        t->su_cull_val = j.cullVal;
        t->su_half = j.half;
        t->su_tile_x = j.tileX;
        t->su_tile_y = j.tileY;
    }
    void readSetup(Out& o)
    {
        o.bad = t->su_bad;
        o.culled = t->su_culled;
        o.flip = t->su_flip;
        o.detNeg = t->su_det_neg;
        o.detBad = t->su_det_bad;
        o.detExp = (int)sext(t->su_det_exp, 10);
        o.detMant = t->su_det_mant;
        for (int k = 0; k < 4; k++) {
            EdgeOut& e = o.e[k];
            e.cv = t->su_const_v[k];
            e.ci = t->su_const_in[k];
            e.t0 = sext(t->su_t0[k], 31);
            e.tx = sext(t->su_tx[k], 28);
            e.ty = sext(t->su_ty[k], 28);
            e.zsh = t->su_zsh[k];
            e.big = t->su_big[k];
            e.far32 = t->su_far32[k];
        }
        o.jf = t->su_jf;
        o.jl = t->su_jl;
        o.rowsV = t->su_rows_v;
    }
    void driveRaster(const Out& o, bool kill)
    {
        for (int k = 0; k < 4; k++) {
            const EdgeOut& e = o.e[k];
            t->ra_const_v[k] = e.cv;
            t->ra_const_in[k] = e.ci;
            t->ra_t0[k] = (uint32_t)e.t0 & 0x7FFFFFFFu;
            t->ra_tx[k] = (uint32_t)e.tx & 0x0FFFFFFFu;
            t->ra_ty[k] = (uint32_t)e.ty & 0x0FFFFFFFu;
            t->ra_zsh[k] = e.zsh;
            t->ra_big[k] = e.big;
            t->ra_far32[k] = e.far32;
        }
        t->ra_jf = o.jf;
        t->ra_jl = o.jl;
        t->ra_rows_v = o.rowsV;
        t->ra_kill = kill;
    }

    // run a batch to its end: outs[i] for jobs[i]
    void run(const std::vector<Job>& jobs, std::vector<Out>& outs)
    {
        outs.assign(jobs.size(), Out());
        size_t next = 0, done = 0;
        std::deque<size_t> suPipe, raQ, raRows;
        std::vector<int> lastRow(jobs.size(), -1);
        size_t lastDone = 0;
        uint64_t idle = 0;
        auto finish = [&](size_t) { done++; };
        // raster-only jobs skip the setup: their descriptor is the job's
        while (done < jobs.size()) {
            // inputs for this clock
            bool feed = false;
            if (next < jobs.size() && raQ.size() < 16 && !(gapSu && rng.chance(gapSu))) {
                const Job& j = jobs[next];
                if (j.rasterOnly) {
                    Out& o = outs[next];
                    for (int k = 0; k < 4; k++) o.e[k] = j.de[k];
                    o.jf = j.djf; o.jl = j.djl; o.rowsV = j.drowsV;
                    o.fed = true;
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
                driveRaster(outs[raQ.front()], jobs[raQ.front()].kill);
            t->ra_out_rdy = !(stall && rng.chance(stall));
            t->eval();
            const bool raTake = raV && t->ra_in_rdy;
            const bool rowX = t->ra_row_v && t->ra_out_rdy;
            const int rowJ = t->ra_row_j;
            const uint32_t rowM = t->ra_in_mask;
            const bool rowLast = t->ra_row_last;
            clock();
            if (feed)
                suPipe.push_back(next++);
            if (raTake) {
                const size_t i = raQ.front();
                raQ.pop_front();
                if (outs[i].rowsV)
                    raRows.push_back(i);
                else
                    finish(i);
            }
            if (rowX) {
                if (raRows.empty()) {
                    // a row nobody asked for: charge it to nothing, but make the run fail
                    outs[0].orderErrors++;
                } else {
                    const size_t i = raRows.front();
                    Out& o = outs[i];
                    const int expect = lastRow[i] < 0 ? o.jf : lastRow[i] + 1;
                    if (rowJ != expect || (o.rowsSeen >> rowJ & 1))
                        o.orderErrors++;
                    o.rowsSeen |= 1u << rowJ;
                    o.mask[rowJ] = rowM;
                    lastRow[i] = rowJ;
                    if (rowLast != (rowJ == o.jl))
                        o.orderErrors++;
                    if (rowLast || rowJ == 31) {
                        raRows.pop_front();
                        finish(i);
                    }
                }
            }
            if (done != lastDone) {
                lastDone = done;
                idle = 0;
            } else if (++idle > 100000) {
                // nothing finished for 100,000 clocks: a hung raster; fail every job still open
                for (size_t i = 0; i < jobs.size(); i++)
                    outs[i].orderErrors++;
                fprintf(stderr, "isp_edge: the DUT hung (%zu of %zu jobs done)\n", done, jobs.size());
                return;
            }
            if (t->su_out_v) {
                const size_t i = suPipe.front();
                suPipe.pop_front();
                Out& o = outs[i];
                readSetup(o);
                const Job& j = jobs[i];
                if ((!o.bad && !o.culled) || j.kill) {
                    o.fed = true;
                    raQ.push_back(i);
                } else
                    finish(i);
            }
        }
    }
};

}   // namespace edgetb

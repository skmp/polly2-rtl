// tsp_unit_tb.cpp: make tsp-tile's unit sections (PLAN M11 "unit sections for p2_tex_filter and p2_pp_shade ... on random
// inputs"), on p2_tsp_unit_tb_top.sv.
//
//   tb [--only tex,shade] [--n N] [--seed S] [--shard k/N] [--max-fails N]
//
// Sections (each a list of jobs: one register set and its points; --shard over jobs):
//   tex    the texture path P3 - P6 (p2_tex_coord, p2_tex_addr, p2_tex_cache with C4 on p2_mem and the VRAM model,
//          p2_tex_decode with p2_tex_pal, p2_tex_filter): random points (every TCW format, VQ, mipmaps and their levels,
//          raster and strided, every filter, clamp / flip, IgnoreTexA; quotients near the texture and far out, zeros) on
//          random video memory, TEXT_CONTROL (stride, bank bits, index swap, byte swap), PAL_RAM_CTRL, palette and
//          HALF_OFFSET; each texel against refsw3's TextureFilter through its dispatch tables (p2ref::texture_filter).
//          The testbench holds the output at random (the pipe's stall: no value may change).
//   shade  P7 - P10 (p2_pp_shade, p2_pp_fog, p2_pp_ss, p2_pp_blend with p2_tbuf): random points (TSP, TCW with bump maps,
//          ISP Texture / Offset, base, offset and texel colours, 1/w across the fog's range, trilinear k, SupSample's
//          four points, run-only and alpha-tested pixels, null items with eop / eoe, a pixel's place repeated right after
//          it: the P10 forward) under random fog registers and table, PT_ALPHA_REF, offsKept and tile-buffer words;
//          against refsw3: P7 the copy of PixelFlush_tsp's `shade` (ColorCombiner, BumpMapper) on the offset colour
//          PixelFlush_tsp gives it (the copy of `bumpLight`, InterpolateOffs's, or offsKept), P8 the copy of `fade` of
//          FogUnit (p2ref::fog), P9 the copy of the SupSample average, P10 tspAlphaStuck (PixelFlush_tsp's rule) and
//          BlendingUnit (p2ref::blend) on the testbench's model of the buffers: the write, or none.
#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#include "Vp2_tsp_unit_tb_top.h"
#include "verilated.h"

#include "p2tb.h"
#include "tsp_unit_ref.h"
#include "vram_model.h"

namespace {

struct Tb {
    Vp2_tsp_unit_tb_top* t = nullptr;
    p2tb::Fails& f;
    p2tb::VramModel vm;
    uint64_t cyc = 0;
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
    void pre()
    {
        vram_drive();
        t->clk = 0;
    }
    void tick()
    {
        pre();
        t->eval();
        edge();
    }
    void idle()
    {
        t->a_v = 0;
        t->b_v = 0;
        t->a_hold = 0;
        t->b_hold = 0;
        t->pal_we = 0;
        t->ft_we = 0;
        t->ok_we = 0;
        t->dbg_we = 0;
        t->flush = 0;
        t->fb_rdy = 1;
    }
    void reset()
    {
        idle();
        t->rst = 1;
        for (int i = 0; i < 4; i++) tick();
        t->rst = 0;
        tick();
    }
};

// ---------------------------------------------------------------------------------------------------------------
// tex
struct TexPt {
    uint32_t tsp, tcw, level;
    bool uneg, vneg;
    int uexp, vexp;
    uint32_t umant, vmant;
    uint32_t exp;
};

void RandQuot(p2tb::Rng& r, int sizeLog2, bool* neg, int* e, uint32_t* m)
{
    *neg = r.below(3) == 0;
    if (r.below(40) == 0) {         // a zero quotient (U or V exactly 0)
        *m = 0;
        *e = 0;
        return;
    }
    *m = (1u << 15) + (uint32_t)r.below((1u << 17) - (1u << 15) + 1);
    // top(q) + sizeLog2: the coordinate in texels near the texture (-4 .. +4 repeats), sometimes far out (up to 2^40)
    int top = r.below(8) ? (int)r.below(8) - 5 : (int)r.below(48) - 8;
    const int bits = 32 - __builtin_clz(*m);
    *e = top - sizeLog2 - bits;
    if (r.below(16) == 0) *e = -(int)r.below(150);
}

long RunTex(Tb& tb, p2tb::Fails& f, uint64_t seed, long nPts)
{
    p2tb::Rng r(seed);
    Vp2_tsp_unit_tb_top* t = tb.t;
    // the video memory: random words, a few regions of small values (palette indices that repeat, YUV near grey)
    uint8_t* vram = turef::vram();
    for (uint32_t i = 0; i < (8u << 20); i += 8) {
        const uint64_t w = r.u64();
        memcpy(vram + i, &w, 8);
    }
    // the registers
    uint32_t tc = (uint32_t)r.below(32);
    if (r.below(2)) tc |= (uint32_t)r.below(32) << 8;      // bank bits
    if (r.below(3) == 0) tc |= 1u << 16;
    if (r.below(3) == 0) tc |= 1u << 17;
    const uint32_t prc = (uint32_t)r.below(4), half = (uint32_t)r.below(8);
    turef::set_reg(0xE4, tc);
    turef::set_reg(0x108, prc);
    turef::set_reg(0x80, half);
    t->text_control = tc;
    t->pal_ram_ctrl = prc;
    t->half_offset = half;
    tb.idle();
    for (int i = 0; i < 1024; i++) {
        const uint32_t w = (uint32_t)r.u64();
        turef::set_reg(0x1000 + 4 * i, w);
        t->pal_we = 1;
        t->pal_widx = i;
        t->pal_wdata = w;
        tb.tick();
    }
    t->pal_we = 0;
    t->flush = 1;
    tb.tick();
    t->flush = 0;
    tb.vm.init(vram);
    tb.vm.begin_render();

    // the points
    std::vector<TexPt> pts((size_t)nPts);
    for (TexPt& p : pts) {
        uint32_t tsp = (uint32_t)r.u64();
        const uint32_t texu = (uint32_t)r.below(8), texv = (uint32_t)r.below(8);
        tsp = (tsp & ~0x3Fu) | (texu << 3) | texv;
        uint32_t tcw = (uint32_t)r.u64();
        const uint32_t fmt = (uint32_t)r.below(8);
        tcw = (tcw & ~(7u << 27)) | (fmt << 27);
        if (r.below(2)) tcw &= ~(1u << 26);                  // twiddled more often
        // half the textures start in one 64 KB window (the same in every job: lines a job finds in the cache are the
        // last job's, whose video memory was other words: the cache's invalidation at a render's start shows)
        if (r.below(2)) tcw = (tcw & ~0x1FFFFFu) | 0x40000u | (uint32_t)r.below(0x2000);
        const bool pal = fmt == 5 || fmt == 6;
        const bool raster = ((tcw >> 26) & 1) && !pal;
        const bool vq = ((tcw >> 30) & 1) && !raster;
        if (vq && ((tcw & 0x1FFFFF) << 3 & 0x7FFFF8) >= 0x7FF000)     // the code book past 8 MB: refsw3 reads outside emu_vram
            tcw &= ~(1u << 19);
        const bool mip = ((tcw >> 31) & 1) && !raster;
        p.tsp = tsp;
        p.tcw = tcw;
        p.level = mip ? (uint32_t)r.below(texu + 4) : 0;
        int su = 3 + (int)texu, sv = 3 + (int)texv;
        if (mip) su = sv = 3 + (int)texu - (int)p.level;
        RandQuot(r, su, &p.uneg, &p.uexp, &p.umant);
        RandQuot(r, sv, &p.vneg, &p.vexp, &p.vmant);
        p.exp = turef::texture_filter(p.tsp, p.tcw, p.uneg, p.uexp, p.umant, p.vneg, p.vexp, p.vmant, p.level);
    }
    const int holdPm = (int)r.below(300);
    size_t in = 0, out = 0;
    const uint64_t c0 = tb.cyc, limit = 2000 + 200ull * (uint64_t)nPts;
    long checks = 0;
    while (out < pts.size()) {
        if (tb.cyc - c0 > limit) {
            f.ok(false, "tex job %" PRIu64 ": no progress (%zu in, %zu out)", seed, in, out);
            break;
        }
        tb.pre();
        t->a_v = in < pts.size() && r.below(5) != 0;
        if (t->a_v) {
            const TexPt& p = pts[in];
            t->a_tsp = p.tsp;
            t->a_tcw = p.tcw;
            t->a_level = p.level;
            t->a_uneg = p.uneg;
            t->a_uexp = (uint32_t)p.uexp & 0x3FF;
            t->a_umant = p.umant;
            t->a_vneg = p.vneg;
            t->a_vexp = (uint32_t)p.vexp & 0x3FF;
            t->a_vmant = p.vmant;
            t->a_tag = (uint32_t)(in & 0xFFFF);
        }
        t->a_hold = r.below(1000) < (uint64_t)holdPm;
        t->eval();
        const bool take = t->a_v && t->a_rdy;
        if (t->a_o_v) {
            const TexPt& p = pts[out];
            checks++;
            f.ok(t->a_o_tag == (out & 0xFFFF) && t->a_o_tex == p.exp,
                 "tex job %" PRIu64 " point %zu: TSP %08x TCW %08x level %u U %s%u 2^%d V %s%u 2^%d (TEXT_CONTROL %08x PAL %u half "
                 "%u): texel %08x (tag %u), refsw3 %08x", seed, out, p.tsp, p.tcw, p.level, p.uneg ? "-" : "", p.umant, p.uexp,
                 p.vneg ? "-" : "", p.vmant, p.vexp, tc, prc, half, t->a_o_tex, t->a_o_tag, p.exp);
            out++;
        }
        tb.edge();
        if (take) in++;
    }
    tb.idle();
    for (int k = 0; k < 4; k++) tb.tick();
    return checks;
}

// ---------------------------------------------------------------------------------------------------------------
// shade
struct ShPt {
    bool null_, eop, eoe, last, ro, atest, super_, hx, hy;
    int rm, idx;
    uint32_t isp, tsp, tcw, ofsfb, base, offs, tex, k;
    bool wneg;
    int wexp;
    uint32_t wmant;
    uint32_t tag;
    // expected
    uint32_t e7, fa7, e8;
};
struct ShPx {     // a pixel at P10 (a super pixel's last point)
    uint32_t tag;
    bool null_;
    uint32_t e9;
    bool hasWrite, at;
    int wb2, idx;
    uint32_t w;
    bool stuck;
};

long RunShade(Tb& tb, p2tb::Fails& f, uint64_t seed, long nPx)
{
    p2tb::Rng r(seed);
    Vp2_tsp_unit_tb_top* t = tb.t;
    // registers
    const uint32_t fcr = (uint32_t)r.u64(), fcv = (uint32_t)r.u64(), fmax = (uint32_t)r.u64(), fmin = (uint32_t)r.u64();
    uint32_t fd = (uint32_t)r.below(0x10000);
    if (r.below(8) == 0) fd &= 0xFF;                     // a zero density mantissa
    const uint32_t ptr = r.below(6) ? (uint32_t)r.below(256) : (uint32_t)r.u64();
    turef::set_reg(0xB0, fcr);
    turef::set_reg(0xB4, fcv);
    turef::set_reg(0xB8, fd);
    turef::set_reg(0xBC, fmax);
    turef::set_reg(0xC0, fmin);
    turef::set_reg(0x11C, ptr);
    t->fog_col_ram = fcr;
    t->fog_col_vert = fcv;
    t->fog_density = fd;
    t->fog_clamp_max = fmax;
    t->fog_clamp_min = fmin;
    t->pt_alpha_ref = ptr;
    tb.idle();
    for (int i = 0; i < 128; i++) {
        const uint32_t w = (uint32_t)r.u64();
        turef::set_reg(0x200 + 4 * i, w);
        t->ft_we = 1;
        t->ft_idx = i;
        t->ft_wdata = w & 0xFFFF;
        tb.tick();
    }
    t->ft_we = 0;
    static uint32_t buf[2][1024];
    for (int b = 0; b < 2; b++)
        for (int i = 0; i < 1024; i++) {
            buf[b][i] = (uint32_t)r.u64();
            t->dbg_we = 1;
            t->dbg_b2 = b;
            t->dbg_idx = i;
            t->dbg_wdata = buf[b][i];
            tb.tick();
        }
    t->dbg_we = 0;
    uint32_t okModel = (uint32_t)r.u64();
    t->ok_we = 1;
    t->ok_wdata = okModel;
    tb.tick();
    t->ok_we = 0;

    // the points and their expected values, in order
    std::vector<ShPt> pts;
    std::vector<ShPx> pxs;
    struct Fb { bool done; int idx; bool fail, ro; };
    std::deque<Fb> fbs;
    bool anyfail = false;
    bool stuck = false;
    int lastIdx = (int)r.below(1024);
    for (long n = 0; n < nPx; n++) {
        ShPt p{};
        const bool lastOne = n + 1 == nPx;        // the job ends with a null eop + eoe item: the next starts clear
        p.null_ = lastOne || r.below(30) == 0;
        p.rm = lastOne ? 1 : (int)r.below(6);    // (a punch-through pass's end: its PASS_DONE clears anyfail too)
        p.idx = r.below(3) == 0 ? lastIdx : (int)r.below(1024);
        lastIdx = p.idx;
        p.eop = lastOne || r.below(10) == 0;
        p.eoe = p.eop && (lastOne || r.below(3) == 0);
        p.last = true;
        const bool pt = p.rm == 1 || p.rm == 2;
        p.ro = pt && r.below(4) == 0;
        p.atest = pt || (p.rm == 3 && r.below(2));
        p.isp = (uint32_t)r.u64();
        p.tsp = (uint32_t)r.u64();
        if (r.below(8) == 0) p.tsp = (p.tsp & 0x00FFFFFFu) | 0x27000000u;   // ONE / ZERO with SrcSelect && DstSelect: a stuck setter
        p.tcw = (uint32_t)r.u64();
        if (r.below(4) == 0) p.tcw = (p.tcw & ~(7u << 27)) | (4u << 27);     // a bump map
        p.ofsfb = (uint32_t)r.u64();
        p.super_ = !p.null_ && r.below(4) == 0;
        const int npts = p.super_ ? 4 : 1;
        uint32_t e8[4];
        for (int k = 0; k < npts; k++) {
            ShPt q = p;
            q.hx = p.super_ && (k & 1);
            q.hy = p.super_ && (k >> 1);
            q.last = !p.super_ || k == 3;
            q.eop = p.eop && q.last;
            q.eoe = p.eoe && q.last;
            q.base = (uint32_t)r.u64();
            q.offs = (uint32_t)r.u64();
            q.tex = (uint32_t)r.u64();
            q.k = r.below(4) ? (uint32_t)r.below(257) : (r.below(2) ? 0u : 256u);
            q.wneg = r.below(10) == 0;
            q.wmant = r.below(20) == 0 ? 0u : (uint32_t)r.below(1u << 17);
            q.wexp = (int)r.below(60) - 50;
            q.tag = (uint32_t)(pts.size() & 0xFFFF);
            // the reference
            const bool tex = (q.isp >> 25) & 1, ofs = (q.isp >> 24) & 1;
            const bool bump = tex && ((q.tcw >> 27) & 7) == 4;
            const uint32_t offs = tex && ofs ? (bump ? turef::bump_light(q.ofsfb) : q.offs) : okModel;
            if (!q.null_ && tex && ofs)
                okModel = turef::bump_light(q.ofsfb);
            q.e7 = turef::shade(q.isp, q.tsp, q.tcw, q.base, q.tex, offs);
            q.fa7 = bump ? 0 : offs >> 24;
            q.e8 = turef::fade(q.isp, q.tsp, q.tcw,
                               turef::fog(ofs, (q.tsp >> 21) & 1, (q.tsp >> 22) & 3, q.e7, q.wneg, q.wexp, q.wmant, (uint8_t)q.fa7),
                               (int)q.k);
            e8[k] = q.e8;
            pts.push_back(q);
        }
        ShPx x{};
        x.tag = pts.back().tag;
        x.null_ = p.null_;
        x.idx = p.idx;
        x.e9 = p.super_ ? turef::super_avg(e8) : e8[0];
        if (!p.null_) {
            uint32_t col = x.e9;
            if (stuck) col = (col & 0x00FFFFFFu) | ((col >> 24) == 255 ? 0xFF000000u : 0u);
            const int ss = (p.tsp >> 25) & 1, ds = (p.tsp >> 24) & 1;
            uint32_t b1 = buf[0][p.idx], b2 = buf[1][p.idx];
            x.at = turef::blend(ss, ds, (p.tsp >> 29) & 7, (p.tsp >> 26) & 7, p.atest, (uint32_t)p.idx, col, &b1, &b2);
            x.hasWrite = !p.ro && !(ss && ds);
            x.wb2 = ds;
            x.w = ds ? b2 : b1;
            if (x.hasWrite) buf[ds][p.idx] = x.w;
            const uint32_t si = (p.tsp >> 29) & 7, di = (p.tsp >> 26) & 7;
            if (ss && ds && di == 0 && (si == 1 || si == 4)) stuck = true;
        }
        x.stuck = stuck;
        if (p.eoe) stuck = false;
        // the feedback of the punch-through passes: PIXEL a pixel, PASS_DONE {anyfail of the pixels not run-only} on eop
        if (p.rm == 1 || p.rm == 2) {
            if (!p.null_) {
                fbs.push_back({ false, p.idx, !x.at, p.ro });
                anyfail |= !x.at && !p.ro;
            }
            if (p.eop) {
                fbs.push_back({ true, 0, anyfail, false });
                anyfail = false;
            }
        }
        pxs.push_back(x);
    }

    const int holdPm = (int)r.below(300), fbPm = (int)r.below(500);
    size_t in = 0, o7 = 0, o8 = 0, o9 = 0, o10 = 0;
    std::deque<size_t> w7, w8;
    const uint64_t c0 = tb.cyc, limit = 2000 + 100ull * (uint64_t)pts.size();
    long checks = 0;
    while (o10 < pxs.size() || !fbs.empty()) {
        if (tb.cyc - c0 > limit) {
            f.ok(false, "shade job %" PRIu64 ": no progress (%zu of %zu points in, %zu of %zu pixels out)", seed, in, pts.size(),
                 o10, pxs.size());
            break;
        }
        tb.pre();
        t->b_v = in < pts.size() && r.below(6) != 0;
        if (t->b_v) {
            const ShPt& q = pts[in];
            t->b_null = q.null_;
            t->b_eop = q.eop;
            t->b_eoe = q.eoe;
            t->b_last = q.last;
            t->b_rm = q.rm;
            t->b_x = q.idx & 31;
            t->b_y = q.idx >> 5;
            t->b_ro = q.ro;
            t->b_atest = q.atest;
            t->b_super = q.super_;
            t->b_hx = q.hx;
            t->b_hy = q.hy;
            t->b_isp = q.isp;
            t->b_tsp = q.tsp;
            t->b_tcw = q.tcw;
            t->b_ofs_fb = q.ofsfb;
            t->b_base = q.base;
            t->b_offs = q.offs;
            t->b_wneg = q.wneg;
            t->b_wexp = (uint32_t)q.wexp & 0x3FF;
            t->b_wmant = q.wmant;
            t->b_k = q.k;
            t->b_tex = q.tex;
            t->b_tag = q.tag;
        }
        t->b_hold = r.below(1000) < (uint64_t)holdPm;
        t->fb_rdy = r.below(1000) >= (uint64_t)fbPm;
        t->eval();
        if (t->fb_v && t->fb_rdy) {
            if (fbs.empty())
                f.ok(false, "shade job %" PRIu64 ": a feedback message after the last expected", seed);
            else {
                const Fb m = fbs.front();
                fbs.pop_front();
                checks++;
                if (m.done)
                    f.ok(t->fb_kind == 1 && t->fb_fail == m.fail, "shade job %" PRIu64 ": feedback kind %d fail %d, PASS_DONE "
                         "anyfail %d expected", seed, t->fb_kind, t->fb_fail, m.fail);
                else
                    f.ok(t->fb_kind == 0 && t->fb_idx == m.idx && t->fb_fail == m.fail && t->fb_ro == m.ro,
                         "shade job %" PRIu64 ": feedback kind %d idx %d fail %d ro %d, PIXEL idx %d fail %d ro %d expected", seed,
                         t->fb_kind, t->fb_idx, t->fb_fail, t->fb_ro, m.idx, m.fail, m.ro);
            }
        }
        const bool take = t->b_v && t->b_rdy;
        const bool p7 = t->b_p7_v, p8 = t->b_p8_v;
        const uint32_t t7 = t->b_p7_tag, t8 = t->b_p8_tag;
        if (t->b_p9_v) {
            const ShPx& x = pxs[o9];
            if (!x.null_) {
                checks++;
                f.ok(t->b_p9_tag == x.tag && t->b_p9_col == x.e9, "shade job %" PRIu64 " pixel %zu: P9 %08x (tag %u), refsw3 %08x",
                     seed, o9, t->b_p9_col, t->b_p9_tag, x.e9);
            }
            o9++;
        }
        if (t->b_p10_v) {
            const ShPx& x = pxs[o10];
            checks++;
            f.ok(t->b_p10_tag == x.tag, "shade job %" PRIu64 " pixel %zu: tag %u at P10, %u expected", seed, o10, t->b_p10_tag,
                 x.tag);
            if (!x.null_) {
                checks += 2;
                f.ok(t->b_at == x.at, "shade job %" PRIu64 " pixel %zu: the alpha test %d, refsw3 %d", seed, o10, t->b_at, x.at);
                f.ok(t->b_stuck == x.stuck, "shade job %" PRIu64 " pixel %zu: tspAlphaStuck %d after it, refsw3 %d", seed, o10,
                     t->b_stuck, x.stuck);
                if (x.hasWrite)
                    f.ok(t->wr_en && t->wr_b2 == x.wb2 && t->wr_idx == x.idx && t->wr_data == x.w,
                         "shade job %" PRIu64 " pixel %zu (index %d): the write %d buffer %d %08x, refsw3 buffer %d %08x", seed,
                         o10, x.idx, t->wr_en, t->wr_b2 + 1, t->wr_data, x.wb2 + 1, x.w);
                else
                    f.ok(!t->wr_en, "shade job %" PRIu64 " pixel %zu: a write where refsw3 writes nothing", seed, o10);
            } else
                f.ok(!t->wr_en, "shade job %" PRIu64 " pixel %zu: a null item writes", seed, o10);
            o10++;
        }
        tb.edge();
        if (p7) {
            const ShPt& q = pts[o7++];
            if (!q.null_) {
                checks++;
                f.ok(t7 == q.tag && t->b_p7_col == q.e7 && t->b_p7_fa == q.fa7,
                     "shade job %" PRIu64 " point %zu (ISP %08x TSP %08x TCW %08x base %08x offs %08x tex %08x): P7 %08x fa %02x, "
                     "refsw3 %08x fa %02x", seed, o7 - 1, q.isp, q.tsp, q.tcw, q.base, q.offs, q.tex, t->b_p7_col, t->b_p7_fa,
                     q.e7, q.fa7);
            }
        }
        if (p8) {
            const ShPt& q = pts[o8++];
            if (!q.null_) {
                checks++;
                f.ok(t8 == q.tag && t->b_p8_col == q.e8,
                     "shade job %" PRIu64 " point %zu (TSP %08x W %s%u 2^%d k %u, FOG_DENSITY %04x): P8 %08x, refsw3 %08x", seed,
                     o8 - 1, q.tsp, q.wneg ? "-" : "", q.wmant, q.wexp, q.k, fd, t->b_p8_col, q.e8);
            }
        }
        if (take) in++;
    }
    tb.idle();
    for (int k = 0; k < 4; k++) tb.tick();
    return checks;
}

}   // namespace

int main(int argc, char** argv)
{
    p2tb::raise_stack();
    Verilated::commandArgs(argc, argv);
    p2tb::Args a;
    if (!a.parse(argc, argv)) {
        fprintf(stderr, "tsp_unit: %s\n", a.error.c_str());
        return 2;
    }
    long maxFails = 0;
    for (size_t i = 0; i < a.rest.size(); i++)
        if (a.rest[i] == "--max-fails" && i + 1 < a.rest.size())
            maxFails = atol(a.rest[++i].c_str());
    p2tb::banner("tsp_unit", a);
    p2tb::Fails f("tsp_unit");
    Vp2_tsp_unit_tb_top* top = new Vp2_tsp_unit_tb_top;
    Tb tb(f);
    tb.t = top;
    turef::init();
    tb.vm.init(turef::vram());
    tb.reset();
    const long n = a.n ? (long)a.n : 400000;
    const long perJob = 4000;
    const long jobs = (n + perJob - 1) / perJob;
    if (a.want("tex")) {
        f.set("tex");
        long checks = 0, pts = 0;
        for (long j = 0; j < jobs; j++) {
            if (!a.mine((uint64_t)j)) continue;
            if (maxFails && f.n >= maxFails) break;
            checks += RunTex(tb, f, a.seed * 1000003ull + (uint64_t)j, perJob);
            pts += perJob;
        }
        printf("tsp_unit: tex: %ld points, %ld texel checks\n", pts, checks);
    }
    if (a.want("shade")) {
        f.set("shade");
        long checks = 0, pxs = 0;
        for (long j = 0; j < jobs; j++) {
            if (!a.mine((uint64_t)j)) continue;
            if (maxFails && f.n >= maxFails) break;
            checks += RunShade(tb, f, a.seed * 2000003ull + (uint64_t)j, perJob);
            pxs += perJob;
        }
        printf("tsp_unit: shade: %ld pixels, %ld checks\n", pxs, checks);
    }
    top->final();
    delete top;
    return f.finish();
}

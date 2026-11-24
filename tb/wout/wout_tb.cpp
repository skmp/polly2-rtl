// wout_tb.cpp: the write-out testbench (PLAN M12 "make wout"; make wout, wout-mutants).
//
//   tb [--seed S] [--n FRAMES] [--shard k/N] [--vramvary S] [--max-fails N] [--frame I]
//
// The DUT (p2_wout_tb_top.sv): p2_tbuf, p2_tbuf_ctl (the actions on eoe), p2_wout and p2_wout_put on C5 of p2_mem, the VRAM
// model behind it (tb/common/vram_model.h, with --vramvary). The reference (wout_ref.cpp): RenderCORE's frame from its
// verbatim copies (p2ref::copy::RenderFrame: put, the scaler, putRow, filtered, emitRows, endStream, the entries'
// write-out and the frame's end), each entry's ISP / TSP work replaced by the testbench's tile.
//
// A frame is random, seeded by its index (Rng::of(seed, frame): where a shard cuts does not change a frame):
//   - the registers: every pack mode 0-6 (frame index mod 7), dither, fb_kval, the alpha threshold; FB_W_SOF1 / SOF2 (now
//     and then unaligned, render to texture with SOF1[24]); FB_W_LINESTRIDE; the pixel clip (full, or a random window);
//     the strip buffer (FB_R_CTRL[22], 16 x 0..8 lines); SCALER_CTL: vscalefactor 0x400, 0x401, 0x800, 0x6532, 0x80, 0x3FF,
//     0x200, 0x1000, 0 and random, hscale, interlace and fieldselect; Y_COEFF 0x8040, 0x6532, 0x4020, 0xFFFF, 0, 0x80FF
//     and random;
//   - the entries: 1-40 tiles in column order (KallistiOS's), row order or at random, now and then the same tile again;
//     z_keep, no_writeout, "shaded nothing" at random; each shaded entry a random tile (random words, or a few random
//     colours);
//   - the buffers' contents at the start, the video memory (one random image, the region array written into it).
// The RTL: the buffers loaded through the debug port; per entry: wait for the controller's action before (hold, as P10
// does), write the tile into buffer 1, push the record, send the eoe point, with random gaps; random reads of buffer 2 by
// "P10" (the shared secondary port). Compared: every word of video memory after the frame (8 MB), both buffers and which
// is buffer 1 (the number of swaps) at the end.
#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Vp2_wout_tb_top.h"
#include "verilated.h"

#include "p2tb.h"
#include "vram_model.h"
#include "wout_ref.h"

namespace {

constexpr uint32_t kVram = 8u << 20;

struct Stats {
    long frames = 0, entries = 0, writes = 0, swaps = 0, starts = 0, steals = 0;
    uint64_t clk = 0;
    long byPm[8] = {}, byMode[4] = {};      // pack mode; 0x400 / stream / 0 / with hscale
    long rtt = 0, strip = 0, clip = 0, dither = 0, unaligned = 0;
};

struct Tb {
    Vp2_wout_tb_top* t = nullptr;
    p2tb::Fails& f;
    p2tb::VramModel vm;
    p2tb::Rng rng{ 1 };
    Stats st;
    uint64_t cyc = 0;
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
        const bool sw = t->swap, ws = t->wo_start;
        t->clk = 1;
        t->eval();
        for (int h = 0; h < 2; h++)
            vm.edge(h, rv[h], rwe[h], ridx[h], rbe[h], rwd[h], rsrc[h]);
        vm.tick();
        cyc++;
        st.swaps += sw;
        st.starts += ws;
    }
    void idle()
    {
        t->eq_push = 0;
        t->p10_eoe = 0;
        t->dbg_we = 0;
        t->flush = 0;
    }
    // one clock with the random steals of the secondary port
    int stealPm = 0;
    void step()
    {
        t->p10_re = rng.below(1000) < (uint64_t)stealPm;
        t->p10_idx = (uint32_t)rng.below(1024);
        st.steals += t->p10_re;
        tick();
        t->p10_re = 0;
    }
};

uint32_t RandTileWord(p2tb::Rng& r, const uint32_t* pal, int mode)
{
    if (mode == 0) return (uint32_t)r.u64();
    return pal[r.below(4)];
}

}   // namespace

int main(int argc, char** argv)
{
    p2tb::raise_stack();
    Verilated::commandArgs(argc, argv);
    p2tb::Args a;
    if (!a.parse(argc, argv)) {
        fprintf(stderr, "wout: %s\n", a.error.c_str());
        return 2;
    }
    uint64_t vary = 0;
    long maxFails = 0, only = -1;
    for (size_t i = 0; i < a.rest.size(); i++) {
        const std::string& s = a.rest[i];
        if (s == "--vramvary" && i + 1 < a.rest.size())
            vary = strtoull(a.rest[++i].c_str(), nullptr, 0);
        else if (s == "--max-fails" && i + 1 < a.rest.size())
            maxFails = atol(a.rest[++i].c_str());
        else if (s == "--frame" && i + 1 < a.rest.size())
            only = atol(a.rest[++i].c_str());
        else if (s.rfind("+vramvary=", 0) == 0)
            vary = strtoull(s.c_str() + 10, nullptr, 0);
    }
    const long nFrames = a.n ? (long)a.n : 400;
    p2tb::banner("wout", a);
    printf("wout: %ld frames, vramvary %llu\n", nFrames, (unsigned long long)vary);
    p2tb::Fails f("wout");
    f.set("frames");

    Vp2_wout_tb_top* top = new Vp2_wout_tb_top;
    Tb tb(f);
    tb.t = top;
    tb.vm.varySeed = vary;

    // one random video memory image (64-bit order); each frame starts from it
    std::vector<uint8_t> img(kVram), rtl(kVram), ref(kVram);
    {
        p2tb::Rng r(a.seed * 7919 + 17);
        for (uint32_t i = 0; i < kVram; i += 8) {
            const uint64_t v = r.u64();
            memcpy(&img[i], &v, 8);
        }
    }
    static const uint32_t factors[] = { 0x400, 0x401, 0x800, 0x6532, 0x80, 0x3FF, 0x200, 0x1000, 0, 0x400, 0x401, 0x800 };
    static const uint32_t coeffs[] = { 0x8040, 0x6532, 0x4020, 0xFFFF, 0x0000, 0x80FF, 0x4040 };
    tb.idle();
    top->rst = 1;
    for (int i = 0; i < 4; i++) tb.tick();
    top->rst = 0;
    tb.tick();

    for (long fi = 0; fi < nFrames; fi++) {
        if (!a.mine((size_t)fi) || (only >= 0 && fi != only))
            continue;
        if (maxFails && f.n >= maxFails)
            break;
        p2tb::Rng& r = tb.rng;
        r = p2tb::Rng::of(a.seed, (uint64_t)fi);
        tb.vm.reseed((uint64_t)fi, 1);
        woref::Frame fr;
        // ---- the registers
        const int pm = (int)(fi % 7);
        const bool dither = r.below(2);
        fr.fb_w_ctrl = (uint32_t)pm | (uint32_t)dither << 3 | (uint32_t)r.below(256) << 8 | (uint32_t)r.below(256) << 16;
        const bool unaligned = r.below(10) == 0;
        const bool rtt = r.below(8) == 0;
        // below 1 MB: a frame reaches at most 1023 rows of 2560 bytes past its base (2.6 MB), and an unaligned 16- or 32-bit
        // pixel's bytes past a word run on into the other half (pvr_map32 then the physical order: up to 4 MB higher), so
        // nothing reaches the region array at 0x7F0000 (refsw3 reads each entry after the ones before are written out)
        uint32_t sof1 = (uint32_t)r.below(0x100000) & (unaligned ? ~0u : ~3u);
        uint32_t sof2 = (uint32_t)r.below(0x100000) & (unaligned ? ~0u : ~3u);
        if (rtt) sof1 |= 0x1000000;
        fr.fb_w_sof1 = sof1;
        fr.fb_w_sof2 = sof2;
        fr.fb_w_linestride = r.below(8) == 0 ? (uint32_t)r.below(0x141) : 0x50u * (uint32_t)(1 + r.below(4));
        const bool clip = r.below(3) == 0;
        if (clip) {
            const uint32_t x0 = (uint32_t)r.below(700), x1 = x0 + (uint32_t)r.below(700);
            const uint32_t y0 = (uint32_t)r.below(600), y1 = y0 + (uint32_t)r.below(600);
            fr.fb_x_clip = std::min(x1, 0x7FFu) << 16 | x0;
            fr.fb_y_clip = std::min(y1, 0x3FFu) << 16 | y0;
        } else {
            fr.fb_x_clip = 0x7FFu << 16;
            fr.fb_y_clip = 0x3FFu << 16;
        }
        const bool strip = r.below(6) == 0;
        fr.fb_r_ctrl = strip ? (1u << 22 | (uint32_t)r.below(9) << 16) : 0;
        uint32_t fac = factors[(fi / 7) % (sizeof factors / sizeof factors[0])];
        if (r.below(6) == 0) fac = 1 + (uint32_t)r.below(0x1FFF);
        const bool hscale = r.below(3) == 0;
        fr.scaler_ctl = fac | (uint32_t)hscale << 16 | (uint32_t)r.below(4) << 17 | (uint32_t)r.below(1 << 13) << 19;
        fr.y_coeff = r.below(4) ? coeffs[r.below(sizeof coeffs / sizeof coeffs[0])] : (uint32_t)r.u64();
        fr.region_base = 0x7F0000u + 4 * (uint32_t)r.below(256);
        // ---- the entries
        const int n = 1 + (int)r.below(40);
        const int order = (int)r.below(3);         // 0 columns (KallistiOS), 1 rows, 2 random
        const int cols = 1 + (int)r.below(20), rows = 1 + (int)r.below(15);
        uint32_t pal[4];
        for (uint32_t& p : pal) p = (uint32_t)r.u64();
        for (int k = 0; k < n; k++) {
            woref::Ent e;
            if (order == 0) { e.tx = (k / rows) % cols; e.ty = k % rows; }
            else if (order == 1) { e.tx = k % cols; e.ty = (k / cols) % rows; }
            else { e.tx = (int)r.below(20); e.ty = (int)r.below(15); }
            if (k && r.below(8) == 0) { e.tx = fr.ents.back().tx; e.ty = fr.ents.back().ty; }
            e.zkeep = r.below(4) == 0;
            e.noWo = r.below(8) == 0;
            e.shaded = !(e.zkeep && r.below(2)) && r.below(16) != 0;
            e.last = k + 1 == n;
            if (e.shaded) {
                const int mode = (int)r.below(2);
                e.tile.resize(1024);
                for (uint32_t& w : e.tile) w = RandTileWord(r, pal, mode);
            }
            fr.ents.push_back(e);
        }
        for (int b = 0; b < 2; b++)
            for (int i = 0; i < 1024; i++)
                fr.buf0[b][i] = (uint32_t)r.u64();
        tb.stealPm = r.below(3) ? (int)r.below(300) : 0;
        const int gapMax = (int)r.below(4) * 600;

        // ---- the reference
        memcpy(ref.data(), img.data(), kVram);
        woref::write_region_array(fr, ref.data());
        memcpy(rtl.data(), ref.data(), kVram);
        uint32_t bufEnd[2][1024];
        int selEnd = 0;
        woref::run(fr, ref.data(), bufEnd, &selEnd);

        // ---- the RTL
        Stats& s = tb.st;
        s.frames++;
        s.byPm[pm]++;
        s.byMode[fac == 0x400 ? 0 : fac == 0 ? 2 : 1]++;
        if (hscale) s.byMode[3]++;
        s.rtt += rtt;
        s.strip += strip;
        s.clip += clip;
        s.dither += dither;
        s.unaligned += unaligned;
        tb.vm.init(rtl.data());
        tb.vm.begin_render();
        top->fb_w_ctrl = fr.fb_w_ctrl;
        top->fb_w_linestride = fr.fb_w_linestride;
        top->fb_w_sof1 = fr.fb_w_sof1;
        top->fb_w_sof2 = fr.fb_w_sof2;
        top->fb_x_clip = fr.fb_x_clip;
        top->fb_y_clip = fr.fb_y_clip;
        top->fb_r_ctrl = fr.fb_r_ctrl;
        top->scaler_ctl = fr.scaler_ctl;
        top->y_coeff = fr.y_coeff;
        tb.idle();
        top->flush = 1;
        tb.tick();
        top->flush = 0;
        const long swaps0 = s.swaps;
        for (int b = 0; b < 2; b++)
            for (int i = 0; i < 1024; i++) {
                top->dbg_we = 1;
                top->dbg_b2 = b;
                top->dbg_idx = i;
                top->dbg_wdata = fr.buf0[b][i];
                tb.tick();
            }
        top->dbg_we = 0;
        const uint64_t c0 = tb.cyc;
        bool hung = false;
        for (const woref::Ent& e : fr.ents) {
            s.entries++;
            // the controller's action on the entry before (P10 waits for it)
            for (uint64_t w = 0; top->hold || top->eq_full; w++) {
                if (w > 4000000) { hung = true; break; }
                tb.step();
            }
            if (hung) break;
            if (gapMax)
                for (int g = (int)r.below((uint64_t)gapMax + 1); g > 0; g--)
                    tb.step();
            if (e.shaded)
                for (int i = 0; i < 1024; i++) {
                    top->dbg_we = 1;
                    top->dbg_b2 = 0;
                    top->dbg_idx = i;
                    top->dbg_wdata = e.tile[i];
                    tb.step();
                }
            top->dbg_we = 0;
            top->eq_push = 1;
            top->eq_tilex = e.tx;
            top->eq_tiley = e.ty;
            top->eq_z_keep = e.zkeep;
            top->eq_no_writeout = e.noWo;
            top->eq_last = e.last;
            top->eq_shaded_any = e.shaded;
            tb.step();
            top->eq_push = 0;
            top->p10_eoe = 1;
            tb.step();
            top->p10_eoe = 0;
        }
        bool tsp = false;
        for (uint64_t w = 0; !hung && !tsp; w++) {
            if (w > 40000000) { hung = true; break; }
            tsp = top->ev_tsp;
            tb.step();
        }
        for (int quiet = 0; quiet < 16 && !hung;) {
            tb.tick();
            quiet = (tb.vm.busy() || top->vh_req_v) ? 0 : quiet + 1;
        }
        s.clk += tb.cyc - c0;
        char what[256];
        snprintf(what, sizeof what, "frame %ld (pack %d, dither %d, sof1 %08x, sof2 %08x, stride %03x, clip %08x %08x, strips %08x, "
                 "scaler %08x, y_coeff %08x, %zu entries)", fi, pm, dither, fr.fb_w_sof1, fr.fb_w_sof2, fr.fb_w_linestride,
                 fr.fb_x_clip, fr.fb_y_clip, fr.fb_r_ctrl, fr.scaler_ctl, fr.y_coeff, fr.ents.size());
        if (!f.ok(!hung, "%s: the write-out did not end", what)) {
            tb.vm.flush();
            top->rst = 1;
            for (int i = 0; i < 4; i++) tb.tick();
            top->rst = 0;
            tb.tick();
            continue;
        }
        // video memory, every word
        long bad = 0;
        int64_t first = -1;
        for (uint32_t i = 0; i < kVram; i += 4)
            if (memcmp(&rtl[i], &ref[i], 4)) {
                if (first < 0) first = i;
                bad++;
            }
        f.checks += kVram / 4 - 1;
        uint32_t wr = 0, wf = 0;
        if (first >= 0) {
            memcpy(&wr, &rtl[first], 4);
            memcpy(&wf, &ref[first], 4);
        }
        f.ok(bad == 0, "%s: %ld words of video memory differ, the first at physical byte %06llx (%08x, refsw3 %08x)", what, bad,
             (long long)(first < 0 ? 0 : first), wr, wf);
        if (bad && getenv("WOUT_DUMP")) {
            const std::string d = getenv("WOUT_DUMP");
            FILE* o;
            if ((o = fopen((d + "/rtl.bin").c_str(), "wb"))) { fwrite(rtl.data(), 1, kVram, o); fclose(o); }
            if ((o = fopen((d + "/ref.bin").c_str(), "wb"))) { fwrite(ref.data(), 1, kVram, o); fclose(o); }
            if ((o = fopen((d + "/img.bin").c_str(), "wb"))) {
                std::vector<uint8_t> im(img);
                woref::write_region_array(fr, im.data());
                fwrite(im.data(), 1, kVram, o);
                fclose(o);
            }
            if ((o = fopen((d + "/ents.txt").c_str(), "w"))) {
                for (const woref::Ent& e : fr.ents)
                    fprintf(o, "%d %d zkeep %d nowo %d shaded %d last %d\n", e.tx, e.ty, e.zkeep, e.noWo, e.shaded, e.last);
                fclose(o);
            }
        }
        if (bad && a.trace) {
            int shown = 0;
            for (uint32_t i = 0; i < kVram && shown < 16; i += 4)
                if (memcmp(&rtl[i], &ref[i], 4)) {
                    uint32_t x, y, z;
                    memcpy(&x, &rtl[i], 4);
                    memcpy(&y, &ref[i], 4);
                    memcpy(&z, &img[i], 4);
                    printf("    physical %06x (area %06x): rtl %08x refsw3 %08x before %08x\n", i,
                           ((i >> 3) << 2) | (((i >> 2) & 1u) << 22), x, y, z);
                    shown++;
                }
        }
        // the buffers and which is buffer 1
        int bb = 0;
        for (int i = 0; i < 1024; i++) {
            top->dbg_idx = i;
            top->clk = 0;
            top->eval();
            bb += top->dbg_b1 != bufEnd[0][i];
            bb += top->dbg_b2_data != bufEnd[1][i];
        }
        f.ok(bb == 0, "%s: %d buffer words differ from refsw3's at the end", what, bb);
        f.ok(((s.swaps - swaps0) & 1) == selEnd, "%s: %ld swaps, refsw3's buffer 1 is store %d", what, s.swaps - swaps0, selEnd);
        s.writes += 0;
    }
    const Stats& s = tb.st;
    printf("wout: %ld frames, %ld entries, %ld swaps, %ld write-outs, %" PRIu64 " VRAM writes, %ld secondary-port steals; %" PRIu64
           " clk\n", s.frames, s.entries, s.swaps, s.starts, tb.vm.writes, s.steals, s.clk);
    printf("wout: pack modes 0-6: %ld %ld %ld %ld %ld %ld %ld; factor 0x400 %ld, a stream %ld, 0 %ld, hscale %ld; render to "
           "texture %ld, strips %ld, clip %ld, dither %ld, unaligned %ld\n", s.byPm[0], s.byPm[1], s.byPm[2], s.byPm[3], s.byPm[4],
           s.byPm[5], s.byPm[6], s.byMode[0], s.byMode[1], s.byMode[2], s.byMode[3], s.rtt, s.strip, s.clip, s.dither,
           s.unaligned);
    top->final();
    delete top;
    return f.finish();
}

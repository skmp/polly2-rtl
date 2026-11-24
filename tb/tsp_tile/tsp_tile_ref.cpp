// tsp_tile_ref.cpp: ttref (tsp_tile_ref.h) on the p2ref API and the M5 phase driver. Compiled with refsw3-offline's
// FLAGS / INC / DEF (P2REF_CXXFLAGS, tb/mk/tsp_tile.mk) and linked with the L2 glue objects, its lists half being
// tb/tsp_tile/refcore_glue_lists_rpt.cpp (every RenderParamTags call through p2ref::render_param_tags).
#include "tsp_tile_ref.h"
#include "phase_driver.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "hw/pvr/pvr_regs.h"

namespace ttref {

namespace {
struct Ctx {
    Render* r = nullptr;
    Pass* pass = nullptr;
    int rm = 0;
};
Ctx ctx;

void PhaseHook(p2live::Phase ph, const p2ref::RegionArrayEntry& e, const p2ref::taRECT&, void*)
{
    if (ph == p2live::Z) {
        Entry en;
        en.tx = e.control.tilex;
        en.ty = e.control.tiley;
        en.sel = p2ref::tile_buffer_sel();
        en.zkeep = e.control.z_keep;
        en.noWriteout = e.control.no_writeout;
        en.presort = e.control.pre_sort;
        ctx.r->ents.push_back(en);
    }
}

void PassHook(bool after, refcore::RenderMode rm, int, int, void*)
{
    Render& R = *ctx.r;
    if (R.ents.empty())
        return;
    if (!after) {
        static p2ref::SpanRec s[1024];
        static uint16_t order[1024];
        static p2ref::IspPix px[1024];
        const int n = p2ref::span_gen(rm, s);
        const int m = p2ref::span_sort(s, n, order);
        for (int i = 0; i < 1024; i++)
            px[i] = p2ref::isp_pixel(i);
        const bool pm = rm == refcore::RM_PUNCHTHROUGH_PASS0 || rm == refcore::RM_PUNCHTHROUGH_PASSN ||
                        rm == refcore::RM_PUNCHTHROUGH_MV;
        R.ents.back().passes.emplace_back();
        Pass& p = R.ents.back().passes.back();
        p.rm = (int)rm;
        p.pix0 = R.pix.size();
        for (int k = 0; k < m; k++) {
            const p2ref::SpanRec& sp = s[order[k]];
            Run r{ sp.tag, sp.y, sp.x, sp.len, 0, 0 };
            for (int i = 0; i < r.len; i++) {
                const p2ref::IspPix& q = px[r.y * 32 + r.x + i];
                r.vmask |= (uint32_t)(q.stencil & 1) << i;
                if (pm)
                    r.pmask |= (uint32_t)q.rendered << i;
            }
            p.runs.push_back(r);
        }
        ctx.pass = &p;
        ctx.rm = (int)rm;
    } else {
        Pass& p = *ctx.pass;
        p.npix = R.pix.size() - p.pix0;
        p.offsKept = p2ref::offs_kept().raw;
        p.stuck = p2ref::alpha_stuck();
        static uint32_t b1[1024], b2[1024];
        for (int i = 0; i < 1024; i++) {
            b1[i] = p2ref::color(1, i);
            b2[i] = p2ref::color(2, i);
        }
        p.hash = hash_buffers(b1, b2);
        ctx.pass = nullptr;
    }
}

bool PixelHook(bool atest, const refcore::FpuEntry* e, refcore::PixPos p, uint32_t idx, const pvrfp::Fp& invW, bool inVol,
               uint32_t tag)
{
    Render& R = *ctx.r;
    const bool ptPass = ctx.rm == refcore::RM_PUNCHTHROUGH_PASS0 || ctx.rm == refcore::RM_PUNCHTHROUGH_PASSN;
    Pix x;
    x.idx = (uint16_t)idx;
    x.ro = ptPass && p2ref::isp_pixel((int)idx).rendered;
    const uint32_t tvi = inVol && !FPU_SHAD_SCALE.intensity_shadow ? 1 : 0;
    const refcore::TSP tsp = e->params.tsp[tvi];
    x.tsp = tsp.full;
    const bool at = p2ref::pixel_flush_tsp(atest, e, p, idx, invW, inVol, tag);
    x.at = at;
    x.wr = !x.ro && !(tsp.SrcSelect && tsp.DstSelect);
    x.wb2 = tsp.DstSelect;
    x.w = p2ref::color(x.wb2 ? 2 : 1, (int)idx);
    R.pix.push_back(x);
    return at;
}
}   // namespace

uint64_t hash_buffers(const uint32_t* b1, const uint32_t* b2)
{
    uint64_t h = 1469598103934665603ull;
    for (int i = 0; i < 1024; i++) h = (h ^ b1[i]) * 1099511628211ull;
    for (int i = 0; i < 1024; i++) h = (h ^ b2[i]) * 1099511628211ull;
    return h;
}

void reset_core() { p2ref::reset_core(); }
bool load_state(const char* dir) { return p2ref::load_state(dir); }

void render(Render& R, int maxPasses)
{
    R = Render();
    Regs& g = R.regs;
    g.param_base = PARAM_BASE;
    g.fpu_shad_scale = FPU_SHAD_SCALE.full;
    g.fpu_perp_val = FPU_PERP_VAL;
    g.half_offset = HALF_OFFSET.full;
    g.text_control = TEXT_CONTROL;
    g.pal_ram_ctrl = PAL_RAM_CTRL;
    g.fog_col_ram = FOG_COL_RAM;
    g.fog_col_vert = FOG_COL_VERT;
    g.fog_density = FOG_DENSITY;
    g.fog_clamp_max = FOG_CLAMP_MAX;
    g.fog_clamp_min = FOG_CLAMP_MIN;
    g.pt_alpha_ref = PT_ALPHA_REF;
    g.span_sort_cfg = SPAN_SORT_CFG;
    for (int i = 0; i < 128; i++) g.fog_table[i] = FOG_TABLE[i];
    for (int i = 0; i < 1024; i++) g.palette[i] = PALETTE_RAM[i];
    for (int i = 0; i < 1024; i++) {
        R.buf0[0][i] = p2ref::color(1, i);
        R.buf0[1][i] = p2ref::color(2, i);
    }
    R.sel0 = p2ref::tile_buffer_sel();
    R.offsKept0 = p2ref::offs_kept().raw;
    uint8_t* vram = p2ref::vram();
    R.vramPre.assign(vram, vram + 8 * 1024 * 1024);

    ctx.r = &R;
    ctx.pass = nullptr;
    p2ref::set_pass_hook(PassHook, nullptr);
    p2ref::set_pixel_hook(PixelHook);
    p2drv::Options o;
    o.maxPasses = maxPasses;
    R.ended = p2drv::render(o, PhaseHook, nullptr);
    p2ref::set_pass_hook(nullptr, nullptr);
    p2ref::set_pixel_hook(nullptr);
    ctx.r = nullptr;

    for (int i = 0; i < 1024; i++) {
        R.bufEnd[0][i] = p2ref::color(1, i);
        R.bufEnd[1][i] = p2ref::color(2, i);
    }
    R.selEnd = p2ref::tile_buffer_sel();
    R.offsKeptEnd = p2ref::offs_kept().raw;
    // the 64-bit words the render changed (its write-out)
    R.wrote.assign((8u << 20) / 8 / 64, 0);
    const uint64_t* a = (const uint64_t*)R.vramPre.data();
    const uint64_t* b = (const uint64_t*)vram;
    for (uint32_t w = 0; w < (8u << 20) / 8; w++)
        if (a[w] != b[w]) {
            R.wrote[w >> 6] |= 1ull << (w & 63);
            R.changedWords++;
        }
}

}   // namespace ttref

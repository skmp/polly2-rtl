// tsp_run_ref.cpp: tsp_run_ref.h on the p2ref API (L2: refsw3-offline's flags, -DRenderCORE=RenderCORE_sw).
#include "tsp_run_ref.h"
#include <cstring>
#include <map>
#include <tuple>
#include "p2ref.h"

namespace trref {

static T Tup(const pvrfp::Fp& v)
{
    T t;
    t.neg = v.neg; t.bad = v.bad; t.exp = v.exp; t.mant = v.mant;
    return t;
}
static uint32_t Reg(uint32_t a) { uint32_t v; memcpy(&v, p2ref::regs() + a, 4); return v; }
static void SetReg(uint32_t a, uint32_t v) { memcpy(p2ref::regs() + a, &v, 4); }

// the entries, set up in their tiles: refsw3's GetFpuEntry with its cache cleared first (as RenderCORE's ClearFpuCache
// at every region array entry), kept here by (tag, tile)
static std::map<std::tuple<uint32_t, int, int>, refcore::FpuEntry> entries;

void reset() { p2ref::reset_core(); entries.clear(); }
uint8_t* vram() { return p2ref::vram(); }
void set_vram32(uint32_t addr, uint32_t w) { p2ref::set_vram32(addr, w); }

void set_regs(uint32_t paramBase, uint32_t shadScale, uint32_t perpVal, uint32_t halfOffset)
{
    SetReg(0x20, paramBase);        // PARAM_BASE_addr
    SetReg(0x74, shadScale);        // FPU_SHAD_SCALE_addr
    SetReg(0x84, perpVal);          // FPU_PERP_VAL_addr
    SetReg(0x80, halfOffset);       // HALF_OFFSET_addr
    p2ref::begin_render();
    entries.clear();
}

void wmeas_regs()
{
    for (int i = 0; i < 128; i++) SetReg(0x200 + 4 * i, 0x00ff);    // FOG_TABLE: every pair (0, 255)
    SetReg(0xB8, 0x8000);           // FOG_DENSITY 1.0
    SetReg(0xB0, 0x00ffffff);       // FOG_COL_RAM white
}
int wmeas_green(const T& w)
{
    pvrfp::Fp W;
    W.neg = w.neg; W.bad = w.bad; W.exp = w.exp; W.mant = w.mant;
    refcore::Color black;
    black.raw = 0xff000000u;
    // FogCtrl table (0), no offset bit, no colour clamp (pvr-tests/wmeas/main.c), UseAlpha; blend ONE / ZERO: the
    // framebuffer holds the fogged colour
    const refcore::Color c = p2ref::fog(false, false, 0, black, W, 0);
    return c.g;
}

static const refcore::FpuEntry& EntryOf(uint32_t tag, int left, int top)
{
    const auto key = std::make_tuple(tag, left, top);
    auto it = entries.find(key);
    if (it != entries.end()) return it->second;
    p2ref::begin_entry();
    // a tag of 0x00000000 right after ClearFpuCache finds slot 0's zeroed entry (tsp_setup_ref.cpp, PLAN 4): another tag
    // of slot 0 first, so that refsw3 sets tag 0 up
    if (tag == 0)
        (void)p2ref::fpu_entry(left, top, refcore::RM_OPAQUE, 32u << 3);
    const refcore::FpuEntry& e = p2ref::fpu_entry(left, top, refcore::RM_OPAQUE, tag);
    return entries.emplace(key, e).first->second;
}

void point(uint32_t tag, int inVol, int left, int top, int x0, int y, int n, int hx, int hy, Pt* out)
{
    using refcore::PlaneStepper3;
    const refcore::FpuEntry& e = EntryOf(tag, left, top);
    const bool intensity = (Reg(0x74) >> 8) & 1;
    const int tv = (inVol && !intensity) ? 1 : 0;
    const int cv = inVol ? 1 : 0;
    const auto& tsp = e.params.tsp[tv];
    const auto& tcw = e.params.tcw[tv];
    out->super = tsp.SupSample;
    out->tex = e.params.isp.Texture;
    out->ofs = e.params.isp.Texture && e.params.isp.Offset && tcw.PixelFmt != refcore::PixelBumpMap;
    out->mip = e.params.isp.Texture && tcw.MipMapped;
    // RenderParamTags: SpanStart = span.x, PixPos {x, y, HALF_OFFSET.tsp_pixel_half_offset}; PixelFlush_tsp's SupSample
    // loop: superActive, superHx = k & 1, superHy = k >> 1
    PlaneStepper3::SpanStart = x0;
    const refcore::PixPos p = { x0 + n, y, (bool)((Reg(0x80) >> 1) & 1) };
    if (out->super) {
        PlaneStepper3::superActive = true;
        PlaneStepper3::superHx = hx;
        PlaneStepper3::superHy = hy;
    }
    const auto& ips = e.ips;
    const PlaneStepper3* ps[11] = {&ips.invW, &ips.U[tv], &ips.V[tv], &ips.Col[cv][0], &ips.Col[cv][1], &ips.Col[cv][2],
                                   &ips.Col[cv][3], &ips.Ofs[cv][0], &ips.Ofs[cv][1], &ips.Ofs[cv][2], &ips.Ofs[cv][3]};
    const pvrfp::Fp W = ips.invW.Val(p);
    for (int k = 0; k < 11; k++) {
        out->val[k] = Tup(ps[k]->Val(p));
        if (k) out->q[k] = Tup(ps[k]->Quot(p, W));
    }
    pvrfp::Fp w = pvrtsp::Divide(pvrfp::Fp::FromHalves(2), W);
    w.neg = false;
    out->q[0] = Tup(w);
    out->base = p2ref::interpolate_base(&e, p, W, inVol, tsp.UseAlpha).raw;
    out->offs = p2ref::interpolate_offs(&e, p, W, inVol).raw;
    out->rl = out->rk = out->level = out->k = 0;
    if (out->mip) {
        // MipSelect as mipChoose calls it (refsw_tile.cpp L1948-1953)
        const pvrtsp::MipChoice c = pvrtsp::MipSelect(ips.U[tv].soft, ips.V[tv].soft, ips.invW.soft, W, 3 + tsp.TexU,
                                                      tsp.MipMapD ? (int)tsp.MipMapD : 4,
                                                      e.params.isp.DCalcCtrl ? ips.first[tv] : nullptr);
        out->rl = c.level;
        out->rk = c.k;
    }
    uint32_t level = 0;
    int dTri = 0;
    p2ref::mip_choose(&e, inVol, W, out->super, &level, &dTri);
    out->level = (int)level;
    out->k = dTri;
    PlaneStepper3::superActive = false;
    PlaneStepper3::superHx = 0;
    PlaneStepper3::superHy = 0;
}

int h7b(uint32_t tag, int inVol, int left, int top, int pl)
{
    using pvrfp::Fp;
    const refcore::FpuEntry& e = EntryOf(tag, left, top);
    const bool intensity = (Reg(0x74) >> 8) & 1;
    const int tv = (inVol && !intensity) ? 1 : 0, cv = inVol ? 1 : 0;
    const auto& ips = e.ips;
    const refcore::PlaneStepper3* ps[11] = {&ips.invW, &ips.U[tv], &ips.V[tv], &ips.Col[cv][0], &ips.Col[cv][1], &ips.Col[cv][2],
                                            &ips.Col[cv][3], &ips.Ofs[cv][0], &ips.Ofs[cv][1], &ips.Ofs[cv][2], &ips.Ofs[cv][3]};
    const auto& P = ps[pl]->soft;
    auto seen = [](const Fp& v) { if (v.bad) return Fp::Pow2(-128, v.neg); if (v.zero()) return Fp::Pow2(-127, v.neg); return v; };
    const Fp a = seen(P.A), b = seen(P.B), c = seen(P.C);
    const int ex = Fp::FromHalves(2 * (int64_t)(left + 16)).top(), ey = Fp::FromHalves(2 * (int64_t)(top + 16)).top();
    int eu = c.top();
    if (a.top() + ex - 1 > eu) eu = a.top() + ex - 1;
    if (b.top() + ey - 1 > eu) eu = b.top() + ey - 1;
    const int unit = eu - 22;
    Fp bh = pvrfp::Mul(b, Fp::FromHalves(1), 62);
    if (bh.zero()) bh.neg = b.neg;
    const int64_t dk = pvrtsp::FloorUnits(pvrfp::Add(c, bh, 62, 400), unit) - pvrtsp::FloorUnits(c, unit);
    int m = 0;
    if (dk != pvrtsp::FloorUnits(bh, unit)) m |= 1;
    if (abs(c.exp - bh.exp) > 90) m |= 2;
    else if (std::max(c.top(), bh.top()) + 1 - std::min(c.exp, bh.exp) > 62) m |= 4;
    if (c.neg) m |= 8;
    return m;
}

void terms(uint32_t tag, int inVol, int left, int top, int x0, int y, int pl, char* out, int outN)
{
    using pvrfp::Fp;
    const refcore::FpuEntry& e = EntryOf(tag, left, top);
    const bool intensity = (Reg(0x74) >> 8) & 1;
    const int tv = (inVol && !intensity) ? 1 : 0, cv = inVol ? 1 : 0;
    const auto& ips = e.ips;
    const refcore::PlaneStepper3* ps[11] = {&ips.invW, &ips.U[tv], &ips.V[tv], &ips.Col[cv][0], &ips.Col[cv][1], &ips.Col[cv][2],
                                            &ips.Col[cv][3], &ips.Ofs[cv][0], &ips.Ofs[cv][1], &ips.Ofs[cv][2], &ips.Ofs[cv][3]};
    const auto& P = ps[pl]->soft;
    auto seen = [](const Fp& v) { if (v.bad) return Fp::Pow2(-128, v.neg); if (v.zero()) return Fp::Pow2(-127, v.neg); return v; };
    const Fp a = seen(P.A), b = seen(P.B), c = seen(P.C);
    const int ex = Fp::FromHalves(2 * (int64_t)(left + 16)).top(), ey = Fp::FromHalves(2 * (int64_t)(top + 16)).top();
    int eu = c.top();
    if (a.top() + ex - 1 > eu) eu = a.top() + ex - 1;
    if (b.top() + ey - 1 > eu) eu = b.top() + ey - 1;
    const int unit = eu - 22;
    const int64_t x0h = 2 * (int64_t)(left + x0) + ((Reg(0x80) >> 1) & 1), yh = 2 * (int64_t)(top + y) + ((Reg(0x80) >> 1) & 1);
    Fp ax = pvrfp::Mul(a, Fp::FromHalves(x0h), 62), by = pvrfp::Mul(b, Fp::FromHalves(yh), 62);
    if (ax.zero()) ax.neg = a.neg;
    if (by.zero()) by.neg = b.neg;
    snprintf(out, outN, "A {%d %d %llx} B {%d %d %llx} C {%d %d %llx} unit %d x0h %lld yh %lld Fc %lld Fax %lld Fby %lld step %lld",
             a.neg, a.exp, (unsigned long long)a.mant, b.neg, b.exp, (unsigned long long)b.mant, c.neg, c.exp, (unsigned long long)c.mant,
             unit, (long long)x0h, (long long)yh, (long long)pvrtsp::FloorUnits(c, unit), (long long)pvrtsp::FloorUnits(ax, unit),
             (long long)pvrtsp::FloorUnits(by, unit), (long long)pvrtsp::FloorUnits(a, unit));
}

}   // namespace trref

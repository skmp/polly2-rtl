// tsp_setup_ref.cpp: tsp_setup_ref.h on the p2ref API (L2: refsw3-offline's flags, -DRenderCORE=RenderCORE_sw).
#include "tsp_setup_ref.h"
#include <cstring>
#include "p2ref.h"
#include "ref_copies_tsp.h"

namespace tsref {

static T Tup(const pvrfp::Fp& v)
{
    T t;
    t.neg = v.neg; t.bad = v.bad; t.exp = v.exp; t.mant = v.mant;
    return t;
}

void reset() { p2ref::reset_core(); }
uint8_t* vram() { return p2ref::vram(); }
void set_vram32(uint32_t addr, uint32_t w) { p2ref::set_vram32(addr, w); }

void set_regs(uint32_t paramBase, uint32_t shadScale, uint32_t perpVal)
{
    uint8_t* r = p2ref::regs();
    memcpy(r + 0x20, &paramBase, 4);        // PARAM_BASE_addr
    memcpy(r + 0x74, &shadScale, 4);        // FPU_SHAD_SCALE_addr
    memcpy(r + 0x84, &perpVal, 4);          // FPU_PERP_VAL_addr
    p2ref::begin_render();
}

static int K8Int(const pvrfp::Fp& k8)
{
    if (k8.mant == 0) return -100000;
    const int b = pvrfp::Fp::Bits(k8.mant);
    return (k8.exp + b) * 128 + ((int)(k8.mant << (8 - b)) - 128);
}

void entry(uint32_t tag, int vsel, Entry* out)
{
    p2ref::begin_entry();                   // ClearFpuCache
    // GetFpuEntry's cache is direct mapped (slot param_offs & 31) and compares the full tag; ClearFpuCache zeroes it,
    // tags included, so a tag of 0x00000000 (param_offs 0, skip 0, no shadow, tag_offset 0) right after a clear finds
    // slot 0's zeroed entry and is never set up: an artifact of the cache's initial tag, not a setup rule (OPEN_ITEMS:
    // unreachable in practice, skip is at least 1 in every list and background tag captured). The reference takes
    // refsw3's own setup of it: another tag of slot 0 first (param_offs 32), so that tag 0 misses.
    if (tag == 0)
        (void)p2ref::fpu_entry(0, 0, refcore::RM_OPAQUE, 32u << 3);
    const refcore::FpuEntry& e = p2ref::fpu_entry(0, 0, refcore::RM_OPAQUE, tag);
    const uint32_t scale = *(uint32_t*)(p2ref::regs() + 0x74);
    const bool intensity = (scale >> 8) & 1;
    const int tv = (vsel && !intensity) ? 1 : 0;
    const int cv = vsel ? 1 : 0;
    const auto& ips = e.ips;
    out->isp = e.params.isp.full;
    out->tsp = e.params.tsp[tv].full;
    out->tcw = e.params.tcw[tv].full;
    for (int i = 0; i < 4; i++) {
        out->colFb[i] = (uint8_t)ips.Col[cv][i].fallback;
        out->ofsFb[i] = (uint8_t)ips.Ofs[cv][i].fallback;
    }
    const refcore::PlaneStepper3* ps[11] = {&ips.invW, &ips.U[tv], &ips.V[tv], &ips.Col[cv][0], &ips.Col[cv][1], &ips.Col[cv][2],
                                            &ips.Col[cv][3], &ips.Ofs[cv][0], &ips.Ofs[cv][1], &ips.Ofs[cv][2], &ips.Ofs[cv][3]};
    for (int p = 0; p < 11; p++) {
        out->pl[p].a = Tup(ps[p]->soft.A);
        out->pl[p].b = Tup(ps[p]->soft.B);
        out->pl[p].c = Tup(ps[p]->soft.C);
    }
    out->kHave = e.params.isp.Texture && e.params.tcw[tv].MipMapped;
    if (out->kHave) {
        // MipSelect's arguments as mipChoose passes them (refsw_tile.cpp L1948-1953): the volume's U and V, invW, size
        // 3 + TexU, D adjust 0 read as 4, the first vertex with DCalcCtrl
        const auto& tsp = e.params.tsp[tv];
        const int bias = tsp.MipMapD ? (int)tsp.MipMapD : 4;
        const uint32_t* first = e.params.isp.DCalcCtrl ? ips.first[tv] : nullptr;
        const p2tspref::MipKOut k = p2tspref::MipKOf(ips.U[tv].soft, ips.V[tv].soft, ips.invW.soft, 3 + tsp.TexU, bias, first);
        out->kHave = !k.ret;
        out->k8 = Tup(k.k8);
        out->dz = k.dzForce;
        // the old model (MIP_K 1, pvr_tsp_plane.h: a generator sets mipKVariant; the environment's MIP_K stays unset)
        const int saved = pvrtsp::mipKVariant;
        pvrtsp::mipKVariant = 1;
        const p2tspref::MipKOut ko = p2tspref::MipKOf(ips.U[tv].soft, ips.V[tv].soft, ips.invW.soft, 3 + tsp.TexU, bias, first);
        pvrtsp::mipKVariant = saved;
        out->kOld = ko.ret ? -100000 : K8Int(ko.k8);
    }
}

}   // namespace tsref

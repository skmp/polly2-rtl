// wout_ref.cpp: woref (wout_ref.h) on the p2ref API and RenderCORE's frame from its verbatim copies (tb/ref/ref_copies.h
// section A: p2ref::copy::RenderFrame). Compiled with refsw3-offline's FLAGS / INC / DEF (P2REF_CXXFLAGS), linked with
// the L2 glue objects.
#include "wout_ref.h"

#include <cstring>

#include "p2ref.h"
#include "ref_copies.h"
#include "hw/pvr/pvr_regs.h"

namespace woref {

namespace {
void Set(uint32_t off, uint32_t v) { memcpy(p2ref::regs() + off, &v, 4); }
// a word at a 32-bit-area address of a 64-bit-order image (pvr_map32)
void Put32(uint8_t* vram, uint32_t a, uint32_t w)
{
    const uint32_t p = ((a & 0x3FFFFCu) << 1) | (((a >> 22) & 1u) << 2);
    memcpy(vram + p, &w, 4);
}
}   // namespace

void write_region_array(const Frame& f, uint8_t* vram)
{
    uint32_t a = f.region_base;
    for (const Ent& e : f.ents) {
        const uint32_t ctl = (uint32_t)e.tx << 2 | (uint32_t)e.ty << 8 | (uint32_t)e.noWo << 28 | (uint32_t)e.zkeep << 30 |
                             (uint32_t)e.last << 31;
        Put32(vram, a, ctl);
        for (int l = 1; l < 6; l++)
            Put32(vram, a + 4 * l, 0x80000000u);
        a += 24;
    }
}

void run(const Frame& f, uint8_t* vram, uint32_t bufEnd[2][1024], int* selEnd)
{
    p2ref::reset_core();
    memset(p2ref::regs(), 0, 0x2000);
    Set(FB_W_CTRL_addr, f.fb_w_ctrl);
    Set(FB_W_LINESTRIDE_addr, f.fb_w_linestride);
    Set(FB_W_SOF1_addr, f.fb_w_sof1);
    Set(FB_W_SOF2_addr, f.fb_w_sof2);
    Set(FB_X_CLIP_addr, f.fb_x_clip);
    Set(FB_Y_CLIP_addr, f.fb_y_clip);
    Set(FB_R_CTRL_addr, f.fb_r_ctrl);
    Set(SCALER_CTL_addr, f.scaler_ctl);
    Set(Y_COEFF_addr, f.y_coeff);
    Set(REGION_BASE_addr, f.region_base);
    Set(FPU_PARAM_CFG_addr, 1u << 21);
    for (int b = 0; b < 2; b++)
        for (int i = 0; i < 1024; i++)
            p2ref::set_color(b + 1, i, f.buf0[b][i]);
    memcpy(p2ref::vram(), vram, 8u << 20);
    size_t k = 0;
    p2ref::copy::RenderFrame([&](p2ref::RegionArrayEntry&, p2ref::taRECT&) {
        const Ent& e = f.ents[k++];
        if (e.shaded)
            for (int i = 0; i < 1024; i++)
                p2ref::set_color(1, i, e.tile[i]);
        refcore::tilePixelsShaded = e.shaded ? 1 : 0;
    });
    memcpy(vram, p2ref::vram(), 8u << 20);
    for (int i = 0; i < 1024; i++) {
        bufEnd[0][i] = p2ref::color(1, i);
        bufEnd[1][i] = p2ref::color(2, i);
    }
    *selEnd = p2ref::tile_buffer_sel();
}

}   // namespace woref

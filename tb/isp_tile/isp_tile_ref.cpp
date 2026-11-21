// isp_tile_ref.cpp: itref (isp_tile_ref.h) on the p2ref API and the M5 phase driver. Compiled with refsw3-offline's
// FLAGS / INC / DEF (P2REF_CXXFLAGS, tb/mk/isp_tile.mk) and linked with the L2 glue objects (build/ref/lib).
#include "isp_tile_ref.h"
#include "phase_driver.h"

#include "hw/pvr/pvr_regs.h"

namespace itref {

namespace {
struct Ctx {
    Hook h;
    void* user;
};
void Thunk(p2live::Phase ph, const p2ref::RegionArrayEntry& re, const p2ref::taRECT&, void* user)
{
    const Ctx& c = *(const Ctx*)user;
    Entry e;
    e.tilex = re.control.tilex;
    e.tiley = re.control.tiley;
    e.no_writeout = re.control.no_writeout;
    e.pre_sort = re.control.pre_sort;
    e.z_keep = re.control.z_keep;
    e.last = re.control.last_region;
    const refcore::ListPointer* l[5] = { &re.opaque, &re.opaque_mod, &re.trans, &re.trans_mod, &re.puncht };
    for (int i = 0; i < 5; i++) {
        e.ptr[i] = l[i]->ptr_in_words;
        e.empty[i] = l[i]->empty;
    }
    c.h((int)ph, e, c.user);
}
}   // namespace

void reset_core() { p2ref::reset_core(); }
bool load_state(const char* dir) { return p2ref::load_state(dir); }
uint8_t* vram() { return p2ref::vram(); }

Regs regs()
{
    Regs r;
    r.param_base = PARAM_BASE;
    r.fpu_shad_scale = FPU_SHAD_SCALE.full;
    r.fpu_cull_val = PvrReg(FPU_CULL_VAL_addr, u32);
    r.fpu_perp_val = FPU_PERP_VAL;
    r.half_offset = HALF_OFFSET.full;
    r.bg_tag = ISP_BACKGND_T.full;
    r.bg_depth = ISP_BACKGND_D.i;
    return r;
}

void pixels(Pix* out)
{
    for (int i = 0; i < 1024; i++) {
        const p2ref::IspPix p = p2ref::isp_pixel(i);
        out[i].depth = p.depthA.k;
        out[i].tag = p.tagA;
        out[i].stencil = p.stencil;
        out[i].valid = p.valid;
    }
}

bool render(Hook h, void* user, int maxPasses)
{
    Ctx c{ h, user };
    p2drv::Options o;
    o.maxPasses = maxPasses;
    return p2drv::render(o, Thunk, &c);
}

}   // namespace itref

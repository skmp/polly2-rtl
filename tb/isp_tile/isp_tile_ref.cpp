// isp_tile_ref.cpp: itref (isp_tile_ref.h) on the p2ref API and the M5 phase driver. Compiled with refsw3-offline's
// FLAGS / INC / DEF (P2REF_CXXFLAGS, tb/mk/isp_tile.mk) and linked with the L2 glue objects (build/ref/lib).
#include "isp_tile_ref.h"
#include "phase_driver.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "hw/pvr/pvr_regs.h"

namespace refcore {
extern FILE* rendlog;       // refsw_lists.cpp: the render log (RENDLOG)
}

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

// the masks of a run from the state now
void Masks(Run& r, int rm, const p2ref::IspPix* px)
{
    r.vmask = r.pmask = 0;
    const bool pm = rm == refcore::RM_PUNCHTHROUGH_PASS0 || rm == refcore::RM_PUNCHTHROUGH_PASSN ||
                    rm == refcore::RM_PUNCHTHROUGH_MV;
    for (int i = 0; i < r.len; i++) {
        const p2ref::IspPix& p = px[r.y * 32 + r.x + i];
        r.vmask |= (uint32_t)(p.stencil & 1) << i;
        if (pm)
            r.pmask |= (uint32_t)p.rendered << i;
    }
}

char* logBuf = nullptr;
size_t logLen = 0;
FILE* logFile = nullptr;
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
    r.isp_feed_cfg = ISP_FEED_CFG.full;
    r.span_sort_cfg = SPAN_SORT_CFG;
    return r;
}

void pixels(Pix* out)
{
    for (int i = 0; i < 1024; i++) {
        const p2ref::IspPix p = p2ref::isp_pixel(i);
        out[i].depth = p.depthA.k;
        out[i].depthB = p.depthB.k;
        out[i].depthC = p.depthC.k;
        out[i].resDepth = p.resDepth.k;
        out[i].savedDepth = p.savedDepth.k;
        out[i].tag = p.tagA;
        out[i].tagB = p.tagB;
        out[i].opTag = p.opTag;
        out[i].refTagC = p.refTagC;
        out[i].resTag = p.resTag;
        out[i].stencil = p.stencil;
        out[i].valid = p.valid;
        out[i].rendered = p.rendered;
        out[i].everRendered = p.everRendered;
        out[i].resPass = p.resPass;
    }
}

int pt_pass() { return p2ref::pt_pass(); }
bool opinpt() { return p2ref::opinpt(); }
bool more() { return p2ref::more(); }
uint32_t tile_pixels_shaded() { return p2ref::tile_pixels_shaded(); }

void spans(int rm, std::vector<Run>& out)
{
    static p2ref::SpanRec s[1024];
    static p2ref::IspPix px[1024];
    const int n = p2ref::span_gen((refcore::RenderMode)rm, s);
    for (int i = 0; i < 1024; i++)
        px[i] = p2ref::isp_pixel(i);
    out.clear();
    for (int i = 0; i < n; i++) {
        Run r{ s[i].tag, s[i].y, s[i].x, s[i].len, 0, 0 };
        Masks(r, rm, px);
        out.push_back(r);
    }
}

void presort_begin()
{
    if (logFile)
        fclose(logFile);
    free(logBuf);
    logBuf = nullptr;
    logLen = 0;
    logFile = open_memstream(&logBuf, &logLen);
    refcore::rendlog = logFile;
}

void presort_end(std::vector<std::vector<Run>>& passes)
{
    passes.clear();
    refcore::rendlog = nullptr;
    if (!logFile)
        return;
    fclose(logFile);
    logFile = nullptr;
    static p2ref::IspPix px[1024];
    for (int i = 0; i < 1024; i++)
        px[i] = p2ref::isp_pixel(i);
    const char* p = logBuf ? logBuf : "";
    std::vector<Run>* cur = nullptr;
    while (*p) {
        const char* nl = strchr(p, '\n');
        const size_t n = nl ? (size_t)(nl - p) : strlen(p);
        if (n > 6 && !strncmp(p, "PASS: ", 6)) {
            passes.emplace_back();
            cur = &passes.back();
        } else if (n > 6 && !strncmp(p, "SPAN: ", 6) && cur) {
            int y, x, len, rm;
            unsigned tag;
            if (sscanf(p + 6, "%d %d %d %x %d", &y, &x, &len, &tag, &rm) == 5) {
                Run r{ tag, y, x, len, 0, 0 };
                Masks(r, rm, px);
                cur->push_back(r);
            }
        }
        p += n + (nl ? 1 : 0);
    }
    free(logBuf);
    logBuf = nullptr;
    // SpanSort's order back to SpanGen's (raster order: spans never overlap)
    for (auto& ps : passes)
        std::sort(ps.begin(), ps.end(), [](const Run& a, const Run& b) { return a.y != b.y ? a.y < b.y : a.x < b.x; });
}

bool render(Hook h, void* user, int maxPasses)
{
    Ctx c{ h, user };
    p2drv::Options o;
    o.maxPasses = maxPasses;
    return p2drv::render(o, Thunk, &c);
}

}   // namespace itref

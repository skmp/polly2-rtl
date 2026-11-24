// refcore_glue.cpp: the L2 glue (PLAN 1.1, conventions.md 7.3), refsw_tile.cpp's half. refsw3's core is two
// translation units here, as in refsw3-offline: this one #includes refsw_tile.cpp, tb/ref/refcore_glue_lists.cpp
// #includes refsw_lists.cpp. (PLAN 1.1 had both in one; they cannot be: both include refcore's TexUtils.h, which has
// no include guard, and two translation units also inline exactly as refsw3-offline's two objects do.) Each has the
// p2ref wrappers (tb/ref/p2ref.h) of the statics in its scope, and its section of tb/ref/ref_copies.h: here B2, the
// RenderParamTags body and PixelFlush_tsp, which p2ref::render_param_tags and p2ref::pixel_flush_tsp run. Compiled
// into build/ref/lib/refcore_glue.o with refsw3-offline's FLAGS / INC / DEF (tb/mk/refglue.mk parses them from
// $(NULLDC3)/refsw3-offline/build.sh) and -DRenderCORE=RenderCORE_sw.
//
// The host environment refcore needs (pvr_regs, emu_vram, f16, refsw3_offline_read, msgboxf, os_DebugBreak) is
// tb/ref/refcore_env.cpp's; the background key (tb/fp's copy fp-bgkey, which cannot see pvr_regs.h's macros) is
// tb/ref/refcore_bgkey.cpp's.
#include "refcore/refsw_tile.cpp"

#define P2REF_GLUE_TILE
#include "ref_copies.h"

pvrisp::StoredDepth p2ref_bgkey(uint32_t isp_backgnd_d);   // refcore_bgkey.cpp

namespace p2ref {
using namespace refcore;

// ---- the core between renders ---------------------------------------------------------------------------------------
void reset_core_lists();     // refcore_glue_lists.cpp

void reset_core()
{
    memset(colorBufferStore, 0, sizeof(colorBufferStore));
    colorBuffer1 = colorBufferStore[0];
    colorBuffer2 = colorBufferStore[1];
    tilePixelsShaded = 0;
    for (int i = 0; i < MAX_RENDER_PIXELS; i++) {
        tagStatus[i].raw = 0;
        tagBuffer[0][i] = tagBuffer[1][i] = 0;
        stencilBuffer[i] = 0;
        depthBuffer[0][i] = depthBuffer[1][i] = depthBuffer[2][i] = ZType();
        opTag[i] = refTagC[i] = resTag[i] = 0;
        resPass[i] = 0;
        resDepth[i] = savedDepth[i] = ZType();
        everRendered[i] = false;
    }
    OpInPt = false;
    PtPass = 0;
    MoreToDraw = false;
    memset(fpuCache, 0, sizeof(fpuCache));
    tspAlphaStuck = false;
    offsKept = { 0 };
    PlaneStepper3::SpanStart = 0;
    PlaneStepper3::superActive = false;
    PlaneStepper3::superHx = PlaneStepper3::superHy = 0;
    pvrfp::perpVal = pvrfp::Fp();
    texture_dumps.clear();
    reset_core_lists();
}

// ---- a render -------------------------------------------------------------------------------------------------------
void begin_entry()
{
    ClearFpuCache();
    tilePixelsShaded = 0;
}
ZType bg_key() { return p2ref_bgkey(ISP_BACKGND_D.i); }
uint32_t bg_tag() { return ISP_BACKGND_T.full; }
void clear_buffers(uint32_t bgtag, ZType bgkey) { ClearBuffers(bgtag, bgkey, 0); }
void clear_status() { ClearParamStatusBuffer(); }
void set_opinpt(bool v) { OpInPt = v; }
bool opinpt() { return OpInPt; }
void pt_initial() { PeelBuffersPTInitial(); }
int pt_pass() { return PtPass; }
void save_depth() { SaveDepth(); }
void restore_depth() { RestoreDepth(); }
void peel(ZType k) { PeelBuffers(k, 0); }
bool more() { return GetMoreToDraw(); }
void clear_more() { ClearMoreToDraw(); }

// ---- SHADE ----------------------------------------------------------------------------------------------------------
template <RenderMode rm>
static int SpanGenAt(p2ref::SpanRec* out)
{
    static refcore::Span s[32 * 32];
    const int n = SpanGen<rm>(s);
    for (int i = 0; i < n; i++)
        out[i] = { s[i].tag, s[i].y, s[i].x, s[i].len };
    return n;
}
int span_gen(RenderMode rm, p2ref::SpanRec* out)
{
    switch (rm) {
    case RM_OPAQUE: return SpanGenAt<RM_OPAQUE>(out);
    case RM_PUNCHTHROUGH_PASS0: return SpanGenAt<RM_PUNCHTHROUGH_PASS0>(out);
    case RM_PUNCHTHROUGH_PASSN: return SpanGenAt<RM_PUNCHTHROUGH_PASSN>(out);
    case RM_PUNCHTHROUGH_MV: return SpanGenAt<RM_PUNCHTHROUGH_MV>(out);
    case RM_TRANSLUCENT_AUTOSORT: return SpanGenAt<RM_TRANSLUCENT_AUTOSORT>(out);
    case RM_TRANSLUCENT_PRESORT: return SpanGenAt<RM_TRANSLUCENT_PRESORT>(out);
    case RM_MODIFIER: return SpanGenAt<RM_MODIFIER>(out);
    }
    return 0;
}
int span_sort(const p2ref::SpanRec* in, int n, uint16_t* order)
{
    static refcore::Span s[32 * 32];
    for (int i = 0; i < n; i++)
        s[i] = { in[i].tag, in[i].y, in[i].x, in[i].len };
    return SpanSort(s, n, order);
}
static PassHook passHook = nullptr;
static void* passUser = nullptr;
void set_pass_hook(PassHook h, void* user)
{
    passHook = h;
    passUser = user;
}
void render_param_tags(RenderMode rm, int left, int top)
{
    if (passHook)
        passHook(false, rm, left, top, passUser);
    switch (rm) {
    case RM_OPAQUE: copy::loop::RenderParamTags<RM_OPAQUE>(left, top); break;
    case RM_PUNCHTHROUGH_PASS0: copy::loop::RenderParamTags<RM_PUNCHTHROUGH_PASS0>(left, top); break;
    case RM_PUNCHTHROUGH_PASSN: copy::loop::RenderParamTags<RM_PUNCHTHROUGH_PASSN>(left, top); break;
    case RM_PUNCHTHROUGH_MV: copy::loop::RenderParamTags<RM_PUNCHTHROUGH_MV>(left, top); break;
    case RM_TRANSLUCENT_AUTOSORT: copy::loop::RenderParamTags<RM_TRANSLUCENT_AUTOSORT>(left, top); break;
    case RM_TRANSLUCENT_PRESORT: copy::loop::RenderParamTags<RM_TRANSLUCENT_PRESORT>(left, top); break;
    case RM_MODIFIER: copy::loop::RenderParamTags<RM_MODIFIER>(left, top); break;
    }
    if (passHook)
        passHook(true, rm, left, top, passUser);
}
void render_param_tags_core(RenderMode rm, int left, int top)
{
    switch (rm) {
    case RM_OPAQUE: RenderParamTags<RM_OPAQUE>(left, top); break;
    case RM_PUNCHTHROUGH_PASS0: RenderParamTags<RM_PUNCHTHROUGH_PASS0>(left, top); break;
    case RM_PUNCHTHROUGH_PASSN: RenderParamTags<RM_PUNCHTHROUGH_PASSN>(left, top); break;
    case RM_PUNCHTHROUGH_MV: RenderParamTags<RM_PUNCHTHROUGH_MV>(left, top); break;
    case RM_TRANSLUCENT_AUTOSORT: RenderParamTags<RM_TRANSLUCENT_AUTOSORT>(left, top); break;
    case RM_TRANSLUCENT_PRESORT: RenderParamTags<RM_TRANSLUCENT_PRESORT>(left, top); break;
    case RM_MODIFIER: RenderParamTags<RM_MODIFIER>(left, top); break;
    }
}
uint32_t tile_pixels_shaded() { return tilePixelsShaded; }

static PixelHook pixelHook = nullptr;
void set_pixel_hook(PixelHook h) { pixelHook = h; }
static ISP_BACKGND_T_type TagOf(uint32_t tag)
{
    ISP_BACKGND_T_type t;
    t.full = tag;
    return t;
}
bool pixel_flush_tsp(bool atest, const FpuEntry* e, PixPos p, uint32_t idx, const pvrfp::Fp& invW, bool inVol, uint32_t tag)
{
    return copy::PixelFlush_tsp(atest, e, p, idx, invW, inVol, TagOf(tag));
}
bool pixel_flush_tsp_core(bool atest, const FpuEntry* e, PixPos p, uint32_t idx, const pvrfp::Fp& invW, bool inVol,
                          uint32_t tag)
{
    return refcore::PixelFlush_tsp(atest, e, p, idx, invW, inVol, TagOf(tag));
}
namespace copy {
namespace loop {
bool PixelFlush_tsp(bool pp_AlphaTest, const FpuEntry* entry, PixPos p, int index, const pvrfp::Fp& invW, bool InVolume, ISP_BACKGND_T_type core_tag)
{
    if (pixelHook)
        return pixelHook(pp_AlphaTest, entry, p, index, invW, InVolume, core_tag.full);
    return copy::PixelFlush_tsp(pp_AlphaTest, entry, p, index, invW, InVolume, core_tag);
}
}   // namespace loop
}   // namespace copy

const FpuEntry& fpu_entry(int left, int top, RenderMode rm, uint32_t tag)
{
    taRECT rect = { left, top, left + 32, top + 32 };
    return GetFpuEntry(&rect, rm, TagOf(tag));
}

// the texture filter as PixelFlush_tsp chooses it (the dispatch's selection)
Color texture_filter(TSP tsp, TCW tcw, const pvrfp::Fp& u, const pvrfp::Fp& v, uint32_t level)
{
    const bool raster = TcwRaster(tcw);
    auto fetch = TextureFetch_table[tcw.VQ_Comp && !raster][tcw.MipMapped && !raster][tcw.ScanOrder][tcw.StrideSel]
                                   [tcw.PixelFmt];
    auto filter = TextureFilter_table[tsp.IgnoreTexA][tsp.ClampU][tsp.ClampV][tsp.FlipU][tsp.FlipV]
                                     [tsp.FilterMode >= 2 && !tcw.MipMapped ? 0 : tsp.FilterMode];
    return filter(tsp, tcw, u, v, level, fetch);
}
Color combiner(bool texture, bool offset, int shadInstr, Color base, Color tex, Color offs)
{
    return ColorCombiner_table[texture][offset][shadInstr & 3](base, tex, offs);
}
Color bump(Color t, Color o) { return BumpMapper(t, o); }
template <int I>
static Color FogAt(Color c, const pvrfp::Fp& w, u8 a) { return FogUnit<(I >> 3) & 1, (I >> 2) & 1, I & 3>(c, w, a); }
Color fog(bool offset, bool colorClamp, int fogCtrl, Color c, const pvrfp::Fp& invW, uint8_t offsA)
{
    typedef Color (*F)(Color, const pvrfp::Fp&, u8);
    static const F t[16] = { FogAt<0>, FogAt<1>, FogAt<2>, FogAt<3>, FogAt<4>, FogAt<5>, FogAt<6>, FogAt<7>,
                             FogAt<8>, FogAt<9>, FogAt<10>, FogAt<11>, FogAt<12>, FogAt<13>, FogAt<14>, FogAt<15> };
    return t[(offset ? 8 : 0) | (colorClamp ? 4 : 0) | (fogCtrl & 3)](c, invW, offsA);
}
// M10: the pixel's colours as PixelFlush_tsp makes them (refcore's InterpolateBase / InterpolateOffs on the volume's planes;
// pp_CheapShadows FPU_SHAD_SCALE.intensity_shadow, as the dispatch chooses it), and the mip level through the verbatim
// copy of PixelFlush_tsp's mipChoose (tb/tsp_run/ref_copies_run.h, copy tsp-mip-choose)
Color interpolate_base(const FpuEntry* entry, PixPos p, const pvrfp::Fp& W, bool InVolume, bool useAlpha)
{
    const PlaneStepper3* col = entry->ips.Col[InVolume ? 1 : 0];
    if (FPU_SHAD_SCALE.intensity_shadow)
        return useAlpha ? InterpolateBase<true, true>(col, p, W, InVolume) : InterpolateBase<false, true>(col, p, W, InVolume);
    return useAlpha ? InterpolateBase<true, false>(col, p, W, InVolume) : InterpolateBase<false, false>(col, p, W, InVolume);
}
Color interpolate_offs(const FpuEntry* entry, PixPos p, const pvrfp::Fp& W, bool InVolume)
{
    const PlaneStepper3* ofs = entry->ips.Ofs[InVolume ? 1 : 0];
    if (FPU_SHAD_SCALE.intensity_shadow)
        return InterpolateOffs<true>(ofs, p, W, InVolume);
    return InterpolateOffs<false>(ofs, p, W, InVolume);
}
void mip_choose(const FpuEntry* entry, bool InVolume, const pvrfp::Fp& q, bool finer, uint32_t* levelOut, int* dTriOut)
{
    // PixelFlush_tsp's names, as the dispatch binds them (pp_CheapShadows is FPU_SHAD_SCALE.intensity_shadow)
    const u32 two_voume_index = InVolume & !FPU_SHAD_SCALE.intensity_shadow;
#include "../tsp_run/ref_copies_run.h"
    u32 level = 0;
    int dTri = 0;
    mipChoose(q, finer, level, dTri);
    *levelOut = level;
    *dTriOut = dTri;
}

bool blend(int srcSel, int dstSel, int srcInstr, int dstInstr, bool atest, uint32_t idx, Color c)
{
    return BlendingUnit_table[srcSel & 1][dstSel & 1][srcInstr & 7][dstInstr & 7][atest](idx, c);
}
void next_tile_buffers() { NextTileAccumulationBuffers(); }

// ---- state taps -----------------------------------------------------------------------------------------------------
IspPix isp_pixel(int i)
{
    IspPix p;
    p.depthA = depthBuffer[depthBufferA][i];
    p.depthB = depthBuffer[depthBufferB][i];
    p.depthC = depthBuffer[depthBufferC][i];
    p.resDepth = resDepth[i];
    p.savedDepth = savedDepth[i];
    p.tagA = tagBuffer[tagBufferA][i];
    p.tagB = tagBuffer[tagBufferB][i];
    p.opTag = opTag[i];
    p.refTagC = refTagC[i];
    p.resTag = resTag[i];
    p.stencil = stencilBuffer[i];
    p.valid = tagStatus[i].valid;
    p.rendered = tagStatus[i].rendered;
    p.everRendered = everRendered[i];
    p.resPass = resPass[i];
    return p;
}
void set_isp_pixel(int i, const IspPix& p)
{
    depthBuffer[depthBufferA][i] = p.depthA;
    depthBuffer[depthBufferB][i] = p.depthB;
    depthBuffer[depthBufferC][i] = p.depthC;
    resDepth[i] = p.resDepth;
    savedDepth[i] = p.savedDepth;
    tagBuffer[tagBufferA][i] = p.tagA;
    tagBuffer[tagBufferB][i] = p.tagB;
    opTag[i] = p.opTag;
    refTagC[i] = p.refTagC;
    resTag[i] = p.resTag;
    stencilBuffer[i] = p.stencil;
    tagStatus[i].valid = p.valid;
    tagStatus[i].rendered = p.rendered;
    everRendered[i] = p.everRendered;
    resPass[i] = p.resPass;
}
uint32_t color(int buffer, int idx) { return buffer == 2 ? colorBuffer2[idx] : colorBuffer1[idx]; }
void set_color(int buffer, int idx, uint32_t w) { (buffer == 2 ? colorBuffer2 : colorBuffer1)[idx] = w; }
int tile_buffer_sel() { return colorBuffer1 == colorBufferStore[0] ? 0 : 1; }
Color offs_kept() { return offsKept; }
void set_offs_kept(Color c) { offsKept = c; }

// ---- M11: PixelFlush_tsp's lambdas through their verbatim copies (tb/tsp_tile/ref_copies_tile.h), on an entry made of
// the volume's words (volume 0: InVolume false, two_voume_index 0), as the dispatch would bind PixelFlush_tsp's names
static FpuEntry& WordsEntry(uint32_t isp, uint32_t tsp, uint32_t tcw, uint32_t ofsFallback)
{
    static FpuEntry e;
    e.params.isp.full = isp;
    e.params.tsp[0].full = tsp;
    e.params.tcw[0].full = tcw;
    for (int i = 0; i < 4; i++)
        e.ips.Ofs[0][i].fallback = (ofsFallback >> (8 * i)) & 0xff;
    return e;
}
Color bump_light_copy(uint32_t ofsFallback)
{
    const FpuEntry* entry = &WordsEntry(0, 0, 0, ofsFallback);
    const bool InVolume = false;
#define P2REF_TILE_BUMPLIGHT
#include "../tsp_tile/ref_copies_tile.h"
#undef P2REF_TILE_BUMPLIGHT
    return bumpLight();
}
Color shade_copy(uint32_t isp, uint32_t tsp, uint32_t tcw, Color b, Color t, Color o)
{
    const FpuEntry* entry = &WordsEntry(isp, tsp, tcw, 0);
    const u32 two_voume_index = 0;
    const bool pp_Texture = entry->params.isp.Texture;
    const bool bump = pp_Texture && entry->params.tcw[two_voume_index].PixelFmt == PixelBumpMap;
    auto combiner = ColorCombiner_table[entry->params.isp.Texture][entry->params.isp.Offset]
                                       [entry->params.tsp[two_voume_index].ShadInstr];
#define P2REF_TILE_SHADE
#include "../tsp_tile/ref_copies_tile.h"
#undef P2REF_TILE_SHADE
    return shade(b, t, o);
}
Color fade_copy(uint32_t isp, uint32_t tsp, uint32_t tcw, Color c, int dTri)
{
    const FpuEntry* entry = &WordsEntry(isp, tsp, tcw, 0);
    const u32 two_voume_index = 0;
    const bool pp_Texture = entry->params.isp.Texture;
#define P2REF_TILE_FADE
#include "../tsp_tile/ref_copies_tile.h"
#undef P2REF_TILE_FADE
    return fade(c, dTri);
}
Color super_avg_copy(const Color* c4)
{
    Color col;
#define P2REF_TILE_SUPER_AVG
#include "../tsp_tile/ref_copies_tile.h"
#undef P2REF_TILE_SUPER_AVG
    return col;
}
bool alpha_stuck() { return tspAlphaStuck; }

}   // namespace p2ref

// refcore_glue_lists_rpt.cpp: the L2 glue's lists half (tb/ref/refcore_glue_lists.cpp) for make tsp-tile, with every
// RenderParamTags call of refsw_lists.cpp routed to p2ref::render_param_tags: the pre-sorted translucent passes, which
// refcore's walk shades after every triangle (RenderTriangle: RenderParamTags<RM_TRANSLUCENT_PRESORT>), then go through
// the verbatim copies of RenderParamTags' loop and PixelFlush_tsp (tb/ref/ref_copies.h, the frames self-test's proof of
// them) and through the pass hook (p2ref::set_pass_hook), as every other pass of the phase driver does. The TSP tile
// testbench links this object in place of refcore_glue_lists.o (tb/mk/tsp_tile.mk); nothing else changes.
#define RenderParamTags P2RenderParamTagsRpt
#include "../ref/refcore_glue_lists.cpp"
#undef RenderParamTags

namespace refcore {
template <RenderMode rm>
void P2RenderParamTagsRpt(int tileX, int tileY)
{
    p2ref::render_param_tags(rm, tileX, tileY);
}
template void P2RenderParamTagsRpt<RM_OPAQUE>(int tileX, int tileY);
template void P2RenderParamTagsRpt<RM_PUNCHTHROUGH_PASS0>(int tileX, int tileY);
template void P2RenderParamTagsRpt<RM_PUNCHTHROUGH_PASSN>(int tileX, int tileY);
template void P2RenderParamTagsRpt<RM_PUNCHTHROUGH_MV>(int tileX, int tileY);
template void P2RenderParamTagsRpt<RM_TRANSLUCENT_AUTOSORT>(int tileX, int tileY);
template void P2RenderParamTagsRpt<RM_TRANSLUCENT_PRESORT>(int tileX, int tileY);
template void P2RenderParamTagsRpt<RM_MODIFIER>(int tileX, int tileY);
}   // namespace refcore

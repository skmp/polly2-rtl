// ref_copies_tile.h: refsw3's PixelFlush_tsp lambdas bumpLight, shade and fade and the SupSample block's average
// (refsw_tile.cpp at refsw3 4f3efe15), copied VERBATIM (PLAN 1.1 "copies", the ref_copies table's bumpLight, shade, fade
// and SupSample rows: M11's; num 7.1; the marker format is tb/ref/ref_copies.h's; tools/check_ref_copies.sh re-extracts
// them on every gate run). They are local to PixelFlush_tsp, which no wrapper reaches: tb/ref/refcore_glue.cpp's
// p2ref::bump_light_copy, shade_copy, fade_copy and super_avg_copy include this file INSIDE a function of the translation
// unit that includes refsw_tile.cpp (ColorCombiner, BumpMapper, PixelBumpMap in scope), each with one P2REF_TILE_* macro
// defined, PixelFlush_tsp's names (`entry`, `two_voume_index`, `bump`, `combiner`, `pp_Texture`, `col`, `c4`) bound as
// there, and calls it. The make tsp-tile unit sections (tb/tsp_tile/tsp_unit_tb.cpp) run them on random inputs against
// p2_pp_shade, p2_pp_fog and p2_pp_ss. Not a header to include anywhere else.
#ifdef P2REF_TILE_BUMPLIGHT
// P2REF-COPY tsp-bump-light refsw_tile.cpp auto bumpLight = [&]() {
    auto bumpLight = [&]() {
        Color l;
        for (int i = 0; i < 4; i++)
            l.bgra[i] = (u8)entry->ips.Ofs[InVolume ? 1 : 0][i].fallback;
        return l;
    };
// P2REF-END tsp-bump-light
#endif
#ifdef P2REF_TILE_SHADE
// P2REF-COPY tsp-shade refsw_tile.cpp auto shade = [&](Color b, Color t, Color o) {
    auto shade = [&](Color b, Color t, Color o) {
        if (!bump)
            return combiner(b, t, o);
        Color none = { 0 };
        switch (entry->params.tsp[two_voume_index].ShadInstr) {
            case 1: return ColorCombiner<true, false, 1>(b, BumpMapper(t, o), none);
            case 2: return ColorCombiner<true, false, 2>(b, BumpMapper(t, o), none);
            case 3: return ColorCombiner<true, false, 3>(b, BumpMapper(t, o), none);
            default: return ColorCombiner<true, false, 0>(b, BumpMapper(t, o), none);
        }
    };
// P2REF-END tsp-shade
#endif
#ifdef P2REF_TILE_FADE
// P2REF-COPY tsp-fade refsw_tile.cpp auto fade = [&](Color c, int dTri) {
    auto fade = [&](Color c, int dTri) {
        if (!pp_Texture || entry->params.tsp[two_voume_index].FilterMode < 2 || !entry->params.tcw[two_voume_index].MipMapped)
            return c;
        int k = dTri;
        if (k < 0) k = 0;
        if (k > 256) k = 256;
        const u32 w = entry->params.tsp[two_voume_index].FilterMode == 2 ? 256 - k : k;
        for (int i = 0; i < 4; i++)
            c.bgra[i] = (c.bgra[i] * w) >> 8;
        return c;
    };
// P2REF-END tsp-fade
#endif
#ifdef P2REF_TILE_SUPER_AVG
// P2REF-COPY tsp-super-avg refsw_tile.cpp for (int c = 0; c < 4; c++)
        for (int c = 0; c < 4; c++)
            col.bgra[c] = (((c4[0].bgra[c] + c4[1].bgra[c]) >> 1) + ((c4[2].bgra[c] + c4[3].bgra[c]) >> 1)) >> 1;
// P2REF-END tsp-super-avg
#endif

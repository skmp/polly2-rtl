// ref_copies_run.h: refsw3's mipChoose (refsw_tile.cpp PixelFlush_tsp's lambda at refsw3 4f3efe15), copied VERBATIM
// (PLAN 1.1 "copies", the ref_copies table's mipChoose row: M10's; num 7.1; the marker format is tb/ref/ref_copies.h's;
// tools/check_ref_copies.sh re-extracts it on every gate run). It is a lambda local to PixelFlush_tsp, which no wrapper
// reaches: tb/ref/refcore_glue.cpp's p2ref::mip_choose includes this file INSIDE a function of the translation unit that
// includes refsw_tile.cpp (TcwRaster and MipSelect in scope), with PixelFlush_tsp's names (`entry`, `two_voume_index`)
// bound as there, and calls it. Not a header to include anywhere else.
// P2REF-COPY tsp-mip-choose refsw_tile.cpp auto mipChoose = [&](const pvrfp::Fp& q, bool finer, u32& level, int& dTri) {
    auto mipChoose = [&](const pvrfp::Fp& q, bool finer, u32& level, int& dTri) {
        level = 0;
        dTri = 0;
        if (entry->params.tcw[two_voume_index].MipMapped) {
            // The level and the trilinear coefficient come from the polygon's planes and the pixel's 1/w
            // (pvr_tsp_plane.h, MipSelect; measured with dreamcast-tests/pvr-tests/mipmeas).
            const auto& ips = entry->ips;
            auto choice = pvrtsp::MipSelect(ips.U[two_voume_index].soft, ips.V[two_voume_index].soft, ips.invW.soft,
                                            q, 3 + entry->params.tsp[two_voume_index].TexU,
                                            // D adjust 0 (the manual: "illegal") is 4/4 on a console: Berserk's
                                            // ground (polly2-data berserk_*), dreamcast-tests mipmeas --bias0
                                            entry->params.tsp[two_voume_index].MipMapD ? (int)entry->params.tsp[two_voume_index].MipMapD : 4,
                                            entry->params.isp.DCalcCtrl ? ips.first[two_voume_index] : nullptr);
            if (finer) {
                // half a pixel apart, as if the texels a pixel were halved (pvr-tests/supsample2: every mipmapped
                // page, flat and perspective, every filter); what would be below the largest map is the largest
                // map without blending
                if (choice.level == 0)
                    choice.k = 0;
                else
                    choice.level--;
            }
            // Trilinear pass B samples the next smaller level. Neither goes past the 1x1 level (3 + TexU: a
            // mipmapped texture is square), and the fraction fades both passes all the same: a level past it reads
            // the 1x1 level, and so does pass B at the 1x1 level (dreamcast-tests/pvr-tests/trimin: levels 1x1 - 1
            // .. 20 of 8 x 8 and 64 x 64 textures, fractions 0, 1/2 and the last, passes A, B, both, bilinear,
            // point, VQ, SupSample: 180 of 180 cells; the texels in front of the 1x1 level are never read).
            const u32 last = 3 + entry->params.tsp[two_voume_index].TexU;
            const bool passB = entry->params.tsp[two_voume_index].FilterMode == 3;
            level = (u32)choice.level + (passB ? 1 : 0);
            if (level > last)
                level = last;
            dTri = choice.k;
            if (TcwRaster(entry->params.tcw[two_voume_index]))
                level = 0;       // no levels to choose from; the fraction still fades the trilinear passes
        }
    };
// P2REF-END tsp-mip-choose

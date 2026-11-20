// ref_copies.h: refcore rules that no wrapper reaches (local lambdas, statics, template bodies), copied VERBATIM
// (PLAN 1.1 "copies", num 7.1). tools/check_ref_copies.sh re-extracts every copy from $(REFCORE) and fails on drift;
// every gate runs it.
//
// A copy is a block of lines between two marker lines:
//
//   // P2REF-COPY <id> <file under refcore> <anchor: the rest of the line>
//   ...the source lines, byte for byte...
//   // P2REF-END <id>
//
// The anchor is text that occurs on exactly one line of <file>, and that line is the copy's first line. The copy has
// as many lines as the block; they must equal the source's lines from the anchor's on. <id> is unique across all
// ref_copies*.h files. Code around the blocks (a wrapper function, the captures a lambda needs) is ours and is not
// checked.
//
// PLAN 1.1's table, at refsw3 4f3efe15, and where each copy is:
//   the setup part of RasterizeTriangle, CulledBySize / CulledByFacing (M2)    tb/isp_edge/ref_copies_edge.h (edge-setup,
//                                       edge-rows, edge-cull), tb/fp/ref_copies.h (fp-cull); M4's tb/isp_setup copies
//   the background key block of RenderCORE (M1)                             tb/fp/ref_copies.h fp-bgkey (p2ref::bg_key)
//   PtChunkTake and the PT loop of RenderCORE (M7)                          here: core-pt-take, core-pt-loop
//   the RenderParamTags loop (M5)                                           here: core-rpt (the whole body)
//   MipSelect's K part (M9)                                                 here: tsp-mip-k
//   the PixelFlush_tsp lambdas bumpLight, shade, mipChoose, fade and the
//   SupSample block (M10, M11)                                              here: tsp-lambdas, tsp-super; with tsp-head,
//                                       tsp-texture, tsp-tail and tsp-dispatch the whole of PixelFlush_tsp is copies
//   the put / scaler lambdas of RenderCORE (M5, M12)                        here: core-put; with core-prev,
//                                       core-writeout and core-endframe the write-out of every entry and of the frame;
//                                       core-perp: RenderCORE's first lines (FPU_PERP_VAL)
//
// Three sections. Section A (every L2 translation unit): p2ref::copy::RenderFrame, RenderCORE's frame around the phase
// driver's entries (tb/ref/phase_driver.cpp), and the K part of MipSelect. Sections B1 and B2 name refcore's statics
// and are compiled only in the glue's translation unit of their file: B1 (P2REF_GLUE_LISTS, tb/ref/refcore_glue_lists.cpp,
// which #includes refsw_lists.cpp) PtChunkTake, which p2ref::check_pt_take drives beside refcore's own, the PT loop
// (p2ref::pt_phase_copy) and RenderCORE's first lines; B2 (P2REF_GLUE_TILE, tb/ref/refcore_glue.cpp, which #includes
// refsw_tile.cpp) the RenderParamTags body and PixelFlush_tsp, which p2ref::render_param_tags and
// p2ref::pixel_flush_tsp run: every pixel the phase driver shades goes through them, so the self-test (make
// refglue-selftest) proves these copies against refsw3-offline, word for word.
#pragma once
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <array>
#include <utility>
#include "p2ref.h"
#include "hw/pvr/pvr_mem.h"

namespace refcore {
extern u8* emu_vram;
}

// ==================================================================================================================
// Section A
namespace p2ref {
namespace copy {
using namespace refcore;

// RenderCORE's frame: the write-out set-up (the put lambda and the scaler), the region array walk and each entry's
// write-out are refsw_lists.cpp's, verbatim; the entry's ISP and TSP work in between is phases(entry, rect), the phase
// driver's. The lines outside the copies are RenderCORE's own too, without the render log.
template <class Phases>
inline void RenderFrame(Phases phases)
{
    u32 base = REGION_BASE;
    p2ref::begin_render();

    RegionArrayEntry entry;

// P2REF-COPY core-put refsw_lists.cpp // ---- writing the picture to the framebuffer ----
    // ---- writing the picture to the framebuffer ----
    // What the hardware adds to a channel before cutting it to 4 bits, by pixel position; half of it for 5
    // bits and a quarter for 6. Measured on a console, every entry exactly (dreamcast-tests/pvr-tests/fbpack; fb555,
    // fb565).
    static const int ditherAdd[4][4] = {
        {  5, 13,  7, 15 },
        {  9,  1, 11,  3 },
        {  6, 14,  4, 12 },
        { 10,  2,  8,  0 }
    };
    // Always FB_W_SOF1: on a console nothing reaches FB_W_SOF2, whatever the interlace and field bits of
    // SCALER_CTL and the display's mode and field are (dreamcast-tests/pvr-tests/sof2probe, sof2field, scalermeas);
    // those bits only choose which lines the scaler takes. FB_W_SOF2 is the second strip buffer: with FB_R_CTRL
    // bit 22 the picture goes out in strips of 16 * size lines (size 0: nothing is written). The write-out keeps a
    // strip number that only grows: a line at or below the next strip's first line moves it on; the line goes to
    // FB_W_SOF1 for an even strip, FB_W_SOF2 for an odd one, at its distance from the strip's first line
    // (dreamcast-tests/pvr-tests/sof2sweep: every line of both buffers on 10 of its 11 strip pages, tiles row by row
    // and column by column; with half-tile strips the later tiles of a row fall before the buffer). Not modelled:
    // where those lines before a buffer go (they are not written here), the one pixel of a strip's first line that
    // lands in the other buffer, half-tile strips with the tiles column by column (the console swaps the buffers
    // for the later columns), the scaler with strips (scrambled on a console).
    const u32 fbBase = FB_W_SOF1;
    const bool stripBuf = FB_R_CTRL.fb_strip_buf_en;
    const int stripLines = 16 * FB_R_CTRL.fb_stripsize;
    int strip = 0;
    const bool rtt = fbBase & 0x1000000;
    const auto fb_packmode = FB_W_CTRL.fb_packmode;
    verify(fb_packmode != 0x7);
    const bool dither = FB_W_CTRL.fb_dither;
    const int bpp = fb_packmode <= 0x3 ? 2 : fb_packmode == 0x4 ? 3 : 4;   // 16 bit formats: 2, 888 packed: 3, 0888 and 8888: 4
    // One pixel of the framebuffer, if the pixel clip (FB_X_CLIP, FB_Y_CLIP: framebuffer coordinates, both ends
    // included) lets it through.
    auto put = [&](int X, int Y, int b8, int g8, int r8, int a8) {
        if (X < (int)FB_X_CLIP.min || X > (int)FB_X_CLIP.max || Y < (int)FB_Y_CLIP.min || Y > (int)FB_Y_CLIP.max)
            return;
        u32 base = fbBase;
        int line = Y;
        if (stripBuf) {
            if (stripLines == 0)
                return;
            while (Y >= (strip + 1) * stripLines)
                strip++;
            line = Y - strip * stripLines;
            if (line < 0)
                return;
            base = (strip & 1) ? FB_W_SOF2 : FB_W_SOF1;
        }
        const u32 dst = base + (u32)line * FB_W_LINESTRIDE.stride * 8 + (u32)X * bpp;
        const int add = dither ? ditherAdd[Y & 3][X & 3] : 0;
        // a channel cut to `bits` bits: add the dither value, drop the low bits, saturate
        auto cut = [add](int v, int bits) {
            int q = (v + (add >> (bits - 4))) >> (8 - bits);
            int top = (1 << bits) - 1;
            return q > top ? top : q;
        };
        if (bpp == 2) {
            u32 pixel;
            if (fb_packmode == 0x0)         // 0555 KRGB: the top bit is the top bit of fb_kval
                pixel = cut(b8, 5) | (cut(g8, 5) << 5) | (cut(r8, 5) << 10) | ((FB_W_CTRL.fb_kval & 0x80) << 8);
            else if (fb_packmode == 0x1)    // 565 RGB
                pixel = cut(b8, 5) | (cut(g8, 6) << 5) | (cut(r8, 5) << 11);
            else if (fb_packmode == 0x2)    // 4444 ARGB: alpha is dithered like the colours
                pixel = cut(b8, 4) | (cut(g8, 4) << 4) | (cut(r8, 4) << 8) | (cut(a8, 4) << 12);
            else                            // 1555 ARGB: the top bit is "alpha is at least the threshold"
                pixel = cut(b8, 5) | (cut(g8, 5) << 5) | (cut(r8, 5) << 10) | ((a8 >= (int)FB_W_CTRL.fb_alpha_threshold) << 15);
            if (rtt)
                (u16&)emu_vram[dst & VRAM_MASK] = pixel;
            else
                pvr_write_area1_16(emu_vram, dst, pixel);
        }
        else if (bpp == 3) {                // 888 RGB, packed
            if (rtt) {
                emu_vram[(dst + 0) & VRAM_MASK] = b8;
                emu_vram[(dst + 1) & VRAM_MASK] = g8;
                emu_vram[(dst + 2) & VRAM_MASK] = r8;
            }
            else {
                emu_vram[pvr_map32(dst + 0)] = b8;
                emu_vram[pvr_map32(dst + 1)] = g8;
                emu_vram[pvr_map32(dst + 2)] = r8;
            }
        }
        else {                              // 0888 KRGB: the top byte is fb_kval; 8888 ARGB: alpha
            u32 top = fb_packmode == 0x5 ? (u32)FB_W_CTRL.fb_kval : (u32)a8;
            u32 pixel = b8 + g8 * 256U + r8 * 256U * 256U + top * 256U * 256U * 256U;
            if (rtt)
                (u32&)emu_vram[dst & VRAM_MASK] = pixel;
            else
                pvr_write_area1_32(emu_vram, dst, pixel);
        }
    };
    // ---- the scaler (SCALER_CTL) ----
    // Measured on a console, every pixel of 77 pictures (dreamcast-tests/pvr-tests/scalermeas: 43 settings; scalertile:
    // the tiles of the region array in six orders, two frames in a row, 1024 lines). The scaler is not a pass
    // over the finished picture: the tiles go through it one after the other, in the order of the region
    // array, and what it keeps between them does not know where a tile is.
    //
    //   factor 0x400 (the low 16 bits): no vertical scaling; a tile's lines go to the tile's own place.
    //
    //   Any other factor: the lines of the tiles are one stream. A tile with y = 0 starts a new stream (the
    //   stream before it is ended first), and so does a frame. Output row j of a stream is taken at
    //   pos = j * factor (+ 1024 in a stream that a tile with y = 0 started, when the picture shrinks and both
    //   the interlace and the field bit are set), in units of 1/1024 line: line k = pos >> 10 and the next one,
    //   weighted with the top 4 bits of the fraction, (a * (16 - f) + b * f) >> 4. When the picture shrinks
    //   (factor above 0x400) the lines are filtered first with Y_COEFF, c1 = bits 15..8 for the line and
    //   c0 = bits 7..0 for the lines above and below: ((c0 * above) >> 4) + ((c1 * line) >> 4) + ((c0 * below)
    //   >> 4), all >> 4, kept to 8 bits (weights summing above 256 wrap, each channel on its own; 0x8040 is
    //   (above + 2 * line + below) >> 2), with the stream's first line repeated above it. Bits 31..16 do
    //   nothing. Pinned by Under Defeat's 0x6532 (polly2-data underdefeat_*: 5 frames = the console's; whole
    //   products >> 8, or the products cut by 3 or 5 bits, miss 2,000-5,000 pixels a frame) and by
    //   dreamcast-tests pvr-tests/ycoeff (18 pages, 14 values, factors 0x401 / 0x400 / 0x800 = the console's).
    //   A row is written when the stream has reached line k + 1 (k + 2 with the filter), at the x of the tile
    //   being worked on then and at row j & 1023 -- the row counter has 10 bits and belongs to the stream,
    //   not to the tile. In the order KallistiOS uses (column by column, top to bottom) that is the picture
    //   one expects; row by row, every tile lands somewhere else.
    //   When a stream ends, at the x of its last tile: with the filter, the last line counts once more as the
    //   line below it; then the rows that need nothing after the last line are written (a row at the last
    //   line itself only when the fraction of pos is 0, all 10 bits).
    //   At the end of the frame the filtered last line is stuck at the value of the tile's first pixel for
    //   the whole width of the tile (a row that uses it shows that pixel 31 times over).
    //
    //   Bit 16: pairs of pixels are averaged, (a + b) >> 1, after the above, and x is halved.
    //   FB_X_CLIP and FB_Y_CLIP are applied to what comes out, in framebuffer coordinates.
    //   Not measured: factor 0 (nothing is written here).
    const int vfactor = SCALER_CTL.vscalefactor;
    const bool vfilter = vfactor > 0x400, halve = SCALER_CTL.hscale;
    const int fieldStart = (vfilter && SCALER_CTL.interlace && SCALER_CTL.fieldselect) ? 1024 : 0;
    struct ScalerLine { u8 p[32][4]; };          // blue, green, red, alpha
    ScalerLine ring[8];                          // the stream's last lines; line i is ring[i & 7]
    s64 streamLines = 0, streamRow = 0;          // lines taken in, rows written
    int streamStart = 0, streamX = -1;           // pos of row 0; x of the last tile (-1: no tile yet)
    auto putRow = [&](int X, int Y, const int row[32][4]) {
        if (halve) {
            for (int x = 0; x < 16; x++)
                put(X / 2 + x, Y, (row[2 * x][0] + row[2 * x + 1][0]) >> 1, (row[2 * x][1] + row[2 * x + 1][1]) >> 1,
                    (row[2 * x][2] + row[2 * x + 1][2]) >> 1, (row[2 * x][3] + row[2 * x + 1][3]) >> 1);
        } else {
            for (int x = 0; x < 32; x++)
                put(X + x, Y, row[x][0], row[x][1], row[x][2], row[x][3]);
        }
    };
    const int yc0 = Y_COEFF & 0xff, yc1 = (Y_COEFF >> 8) & 0xff;
    auto filtered = [&](s64 i, int x, int c) -> int {
        const int v = ring[i & 7].p[x][c];
        if (!vfilter)
            return v;
        const int a = ring[(i > 0 ? i - 1 : 0) & 7].p[x][c], b = ring[(i + 1) & 7].p[x][c];
        return ((((yc0 * a) >> 4) + ((yc1 * v) >> 4) + ((yc0 * b) >> 4)) >> 4) & 0xff;
    };
    // write the rows that can be written. end: the stream is over (with the filter the last line has been
    // taken in once more); stuck: the end of the frame
    auto emitRows = [&](int X, bool end, bool stuck) {
        const s64 last = (end && vfilter ? streamLines - 1 : streamLines) - 1;      // the last line of the tiles
        for (;;) {
            const s64 pos = streamRow * vfactor + streamStart, k = pos >> 10;
            const int f = (int)(pos >> 6) & 15;
            if (end) {
                if (!(k + 1 <= last || (k == last && (pos & 1023) == 0)))
                    return;
            } else if (k + (vfilter ? 2 : 1) > streamLines - 1)
                return;
            int row[32][4];
            for (int x = 0; x < 32; x++)
                for (int c = 0; c < 4; c++) {
                    int a = filtered(k, stuck && vfilter && k == last ? 0 : x, c);
                    if (f)
                        a = (a * (16 - f) + filtered(k + 1, stuck && vfilter && k + 1 == last ? 0 : x, c) * f) >> 4;
                    row[x][c] = a;
                }
            putRow(X, (int)(streamRow & 1023), row);
            streamRow++;
        }
    };
    auto endStream = [&](bool stuck) {
        if (streamX < 0 || streamLines == 0)
            return;
        if (vfilter) {
            ring[streamLines & 7] = ring[(streamLines - 1) & 7];
            streamLines++;
        }
        emitRows(streamX, true, stuck);
    };
// P2REF-END core-put

// P2REF-COPY core-prev refsw_lists.cpp bool prevWrittenOut = false;        // the entry before this one was written out to the framebuffer
    bool prevWrittenOut = false;        // the entry before this one was written out to the framebuffer
    bool havePrev = false;              // there was an entry before this one
    int prevTileX = 0, prevTileY = 0;   // its tile
// P2REF-END core-prev
    do {
        auto step = ReadRegionArrayEntry(base, &entry);
        base += step;

        taRECT rect;
        rect.top = entry.control.tiley * 32;
        rect.left = entry.control.tilex * 32;

        rect.bottom = rect.top + 32;
        rect.right = rect.left + 32;

        phases(entry, rect);

// P2REF-COPY core-writeout refsw_lists.cpp // Copy to vram. A keep Z tile that shades nothing ends at once, while the tile before it is still being
        // Copy to vram. A keep Z tile that shades nothing ends at once, while the tile before it is still being
        // written out, and is itself never written to the framebuffer; the buffers still change places
        // (dreamcast-tests/pvr-tests/accbuf, pages 0 and 3: the tiles after it alternate as if it had been written
        // out). What else that collision does depends on its timing (README, accbuf) and is not modelled here.
        // Only after a tile that is written out. After one that is not, the keep Z entry writes the tile buffer
        // out at the place of the entry before it, with what that entry drew (dreamcast-tests/pvr-tests/keepz:
        // page 1, an entry not written out at one cell and an empty keep Z entry at the next: the first cell
        // gets its picture, the second nothing). Games give both entries the same tile (polly2-data logo, mem,
        // menu2, menu3, thps2_menu): it looks like an ordinary write-out (keepz page 0).
        const bool emptyKeepZ = entry.control.z_keep && tilePixelsShaded == 0 && prevWrittenOut;
        const bool emptyAfterNoWrite = entry.control.z_keep && tilePixelsShaded == 0 && !prevWrittenOut && havePrev;
        const int tileX = emptyAfterNoWrite ? prevTileX : entry.control.tilex;
        const int tileY = emptyAfterNoWrite ? prevTileY : entry.control.tiley;
        prevWrittenOut = !entry.control.no_writeout && !emptyKeepZ;
        prevTileX = entry.control.tilex; prevTileY = entry.control.tiley; havePrev = true;
        if (!entry.control.no_writeout && emptyKeepZ)
            NextTileAccumulationBuffers();
        else if (!entry.control.no_writeout)
        {
            auto src = GetColorOutputBuffer();      // blue, green, red, alpha
            const int X0 = tileX * 32, Y0 = tileY * 32;
            if (vfactor == 0x400) {
                for (int y = 0; y < 32; y++) {
                    int row[32][4];
                    for (int x = 0; x < 32; x++, src += 4)
                        for (int c = 0; c < 4; c++)
                            row[x][c] = src[c];
                    putRow(X0, Y0 + y, row);
                }
            } else if (vfactor != 0) {
                if (tileY == 0) {
                    endStream(false);
                    streamLines = streamRow = 0;
                    streamStart = fieldStart;
                }
                for (int y = 0; y < 32; y++, src += 32 * 4) {
                    memcpy(ring[streamLines & 7].p, src, 32 * 4);
                    streamLines++;
                    emitRows(X0, false, false);
                }
                streamX = X0;
            }
            // the buffer that is written out stays behind as the next tile's secondary buffer; an entry
            // that is not written out (KallistiOS's first one) leaves the buffers where they are
            NextTileAccumulationBuffers();
        }
// P2REF-END core-writeout
    } while (!entry.control.last_region);

// P2REF-COPY core-endframe refsw_lists.cpp if (vfactor != 0x400 && vfactor != 0)
    if (vfactor != 0x400 && vfactor != 0)
        endStream(true);
// P2REF-END core-endframe
}

// MipSelect's K part (pvr_tsp_plane.h): K from the longer length `best` (after its product with 1/det^2), the texture's
// size and the bias. ret: MipSelect returns r there (no level).
struct MipKOut { pvrtsp::MipChoice r; pvrfp::Fp k8, kFull; bool ret; };
inline MipKOut MipKPart(pvrfp::Fp best, bool ranged, int sizeLog2, int biasQuarters)
{
    using namespace pvrfp;
    using pvrtsp::MipChoice;
    using pvrtsp::MipK;
    MipKOut out;
    out.ret = true;
    auto body = [&]() -> MipChoice {
        MipChoice r = { 0, 0, Fp() };
// P2REF-COPY tsp-mip-k pvr_tsp_plane.h Fp k8, kFull;
    Fp k8, kFull;
    if (best.bad) {
        if (!ranged) return r;
        k8 = Fp::Pow2(-128 + sizeLog2, false);          // field 255 plus the size, wrapped
        kFull = k8;
    } else if (best.zero()) {
        if (!ranged) return r;
        k8 = Fp::Pow2(-127 + sizeLog2, false);          // field 0 plus the size
        kFull = k8;
    } else {
        k8 = Mul(best, Fp::FromHalves(2 * (int64_t)biasQuarters), 62);
        k8.exp += sizeLog2 - 2;
        kFull = k8;
        k8 = k8.cut(8);
        r.kFull = kFull;
        if (MipK() == 98 || MipK() == 99) {                 // one step of 8 bits more, less
            const int b = Fp::Bits(k8.mant), sh = b > 8 ? b - 8 : 0;
            uint64_t m = (k8.mant >> sh) + (MipK() == 98 ? 1 : -1);
            k8.mant = m << sh;
        }
    }
// P2REF-END tsp-mip-k
        out.k8 = k8;
        out.kFull = kFull;
        out.ret = false;
        return r;
    };
    out.r = body();
    return out;
}

}   // namespace copy
}   // namespace p2ref

// ==================================================================================================================
// Section B1: in the glue's translation unit of refsw_lists.cpp only (tb/ref/refcore_glue_lists.cpp)
#ifdef P2REF_GLUE_LISTS

// PtChunkTake with its counters, in a namespace of their own (p2ref::check_pt_take runs it beside refcore's)
namespace p2ref {
namespace copy_take {
// P2REF-COPY core-pt-take refsw_lists.cpp static bool ptChunking = false;
static bool ptChunking = false;
static int ptChunk, ptChunkSize, ptChunkAt, ptChunkFill, ptChunks;
static bool ptChunkPrevQuad = false;
static int ptChunkCulled;               // the vertices of a culled primitive right before: counted in the next check only
static bool PtChunkTake(int nv) {       // the next nv vertices of the list: in the chunk being peeled?
    if (ptChunkFill > 0 && (ptChunkFill - (ptChunkPrevQuad ? 1 : 0)) + ptChunkCulled + nv > ptChunkSize - 2) {
        ptChunkAt++;
        ptChunkFill = 0;
    }
    ptChunkFill += nv;
    ptChunkPrevQuad = nv == 4;
    ptChunkCulled = 0;
    ptChunks = ptChunkAt + 1;
    return ptChunkAt == ptChunk;
}
// P2REF-END core-pt-take
}   // namespace copy_take
}   // namespace p2ref

// The PT loop of RenderCORE. In namespace refcore: its block-scope extern declarations (PeelBuffersPTChunk, PtPass)
// name refcore's. It shades with refcore's RenderParamTags.
namespace refcore {
inline void P2PtPhaseCopy(RegionArrayEntry& entry, taRECT& rect)
{
// P2REF-COPY core-pt-loop refsw_lists.cpp RENDLOG("PT");
            RENDLOG("PT");

            PeelBuffersPTInitial();
            ptChunking = true;
            ptChunkSize = ISP_FEED_CFG.full >> 4 & 0x3ff;
            ptChunks = 1;
            for (ptChunk = 0; ptChunk < ptChunks; ptChunk++) {
                if (ptChunk) {
                    RENDLOG("PT_CHUNK");
                    extern void PeelBuffersPTChunk();
                    PeelBuffersPTChunk();
                }
                // one pass after the other until no pixel failed the alpha test (or nothing is left to try)
                for (int pass = 0; ; pass++) {
                    if (pass)
                        RENDLOG("PT_N");
                    ClearMoreToDraw();
                    { extern int PtPass; PtPass = pass; }
                    ptChunkAt = 0;
                    ptChunkFill = 0;
                    ptChunkPrevQuad = false;
                    ptChunkCulled = 0;
                    RenderObjectList(pass ? RM_PUNCHTHROUGH_PASSN : RM_PUNCHTHROUGH_PASS0, entry.puncht.ptr_in_words * 4, &rect);
                    if (!GetMoreToDraw())
                        break;
                    if (pass)
                        RENDLOG("PT_N_PARAMS");
                    else
                        RENDLOG("PT_PARAMS");
                    ClearMoreToDraw();
                    RenderParamTags<RM_PUNCHTHROUGH_PASS0>(rect.left, rect.top);
                    if (!GetMoreToDraw())
                        break;
                }
            }
            ptChunking = false;
            PeelBuffersPTFinal();
// P2REF-END core-pt-loop
}
}   // namespace refcore

namespace p2ref {
namespace copy {
using namespace refcore;

// the first lines of RenderCORE: FPU_PERP_VAL (p2ref::begin_render)
inline void BeginRender()
{
// P2REF-COPY core-perp refsw_lists.cpp const u32 pv = FPU_PERP_VAL & 0x7fffffff;
        const u32 pv = FPU_PERP_VAL & 0x7fffffff;
        pvrfp::perpVal = pvrfp::Fp::FromBits(pv);
// P2REF-END core-perp
}
}   // namespace copy
}   // namespace p2ref

#endif  // P2REF_GLUE_LISTS

// ==================================================================================================================
// Section B2: in the glue's translation unit of refsw_tile.cpp only (tb/ref/refcore_glue.cpp)
#ifdef P2REF_GLUE_TILE

namespace p2ref {
namespace copy {
using namespace refcore;

// PixelFlush_tsp, the template body (every piece a copy; between them only blank lines and the commented-out debug
// colour of the source)
template<bool pp_UseAlpha, bool pp_Texture, bool pp_Offset, bool pp_ColorClamp, u32 pp_FogCtrl, bool pp_CheapShadows>
static bool PixelFlush_tsp(const FpuEntry *entry, PixPos p, const pvrfp::Fp& W, bool InVolume, u32 index, TextureFetch_fp fetch, TextureFilter_fp filter, ColorCombiner_fp combiner, BlendingUnit_fp blending)
{
// P2REF-COPY tsp-head refsw_tile.cpp u32 two_voume_index = InVolume & !pp_CheapShadows;
    u32 two_voume_index = InVolume & !pp_CheapShadows;
    auto cb = (Color*)colorBuffer1 + index;
  
    Color base = { 0 }, textel = { 0 };

    base = InterpolateBase<pp_UseAlpha, pp_CheapShadows>(entry->ips.Col[InVolume ? 1 : 0], p, W, InVolume);

    int dTrilinear = 0;             // of 256: the share of the next level (MipSelect's k)
    u32 MipLevel = 0;
    const bool bump = pp_Texture && entry->params.tcw[two_voume_index].PixelFmt == PixelBumpMap;
    // SupSample: the pixel is made at four points and averaged (below)
    const bool super = entry->params.tsp[two_voume_index].SupSample;
    Color col;
// P2REF-END tsp-head
// P2REF-COPY tsp-lambdas refsw_tile.cpp // A bump map's light (K1 K2 K3 Q, the offset colour) is the last vertex's offset colour as it is: not
    // A bump map's light (K1 K2 K3 Q, the offset colour) is the last vertex's offset colour as it is: not
    // interpolated on a Gouraud polygon, and not through the 1/w planes on a flat one (pvr-tests/supsample2 page 30
    // and its control: interpolated, 123,578 pixels miss; flat through the planes, 15 and the 6 of pages 29 and 31,
    // next to a corner of large w; pvr-tests/bumplight, strips of four triangles at depths 2^-8 .. 4, with
    // SupSample, fog and an intensity shadow). The planes' fallback is that colour (with an intensity shadow's
    // scaling). Nor is it a fog: vertex fog does nothing to a bump map (bumplight page 5: K1 as the fog's alpha
    // misses every cell).
    auto bumpLight = [&]() {
        Color l;
        for (int i = 0; i < 4; i++)
            l.bgra[i] = (u8)entry->ips.Ofs[InVolume ? 1 : 0][i].fallback;
        return l;
    };
    // the texture environment: the texel t with the base colour b and the offset colour o. A bump map's result takes
    // the texel's place (with modulate, hardware multiplies it by the base color, dreamcast-tests/pvr-tests/bump); the
    // offset color holds the light and is not added.
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

    // the level and the trilinear coefficient where 1/w is q; `finer`: a SupSample point's, one level finer
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
    // Trilinear: pass A (mode 2) draws this level fading out toward the next one, pass B (mode 3) the next level
    // fading in; the two passes are added by the blend unit. The fade is of the finished colour, after the
    // shading, the offset colour, the colour clamp and the fog, alpha too, bump maps too (pvr-tests/supsample2 page
    // 21 and its control: of the texel, as it was, misses 149,148 of 153,600 pixels; pvr-tests/trifade, 22 pages of
    // flat cells). A texture without mipmaps is not faded (pvr-tests/mip, "565 without mipmaps").
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
// P2REF-END tsp-lambdas

// P2REF-COPY tsp-texture refsw_tile.cpp Color offs = offsKept;      // this pixel's offset colour (without the offset bit: the kept one, for a bump map)
    Color offs = offsKept;      // this pixel's offset colour (without the offset bit: the kept one, for a bump map)
    if (pp_Texture) {
        if (dump_textures) {

            u64 uid = entry->params.tsp[two_voume_index].full;
            uid = (uid << 32) | entry->params.tcw[two_voume_index].full;

            if (texture_dumps.count(uid) == 0) {
                texture_dumps.insert(uid);
                DumpTexture(entry->params.tsp[two_voume_index],  entry->params.tcw[two_voume_index], fetch);
            }
        }
        if (!super) {
            const pvrfp::Fp u = entry->ips.U[two_voume_index].Quot(p, W);
            const pvrfp::Fp v = entry->ips.V[two_voume_index].Quot(p, W);
            mipChoose(W, false, MipLevel, dTrilinear);
            textel = filter(entry->params.tsp[two_voume_index], entry->params.tcw[two_voume_index], u, v, MipLevel, fetch);
        }
        if (pp_Offset) {
            offs = bump ? bumpLight() : InterpolateOffs<pp_CheapShadows>(entry->ips.Ofs[InVolume ? 1 : 0], p, W, InVolume);
            offsKept = bumpLight();
        }
    }
// P2REF-END tsp-texture

// P2REF-COPY tsp-super refsw_tile.cpp if (super) {
    if (super) {
        // SupSample (dreamcast-tests/pvr-tests/supsample, supsample2, ssmip, sscolor; polly2-data outtrigger_menu,
        // mrdriller_*): the pixel is made at four points, its centre and half a pixel right, down and both. The planes
        // are evaluated for them in half pixel steps (pvr_tsp_plane.h), and each point has everything of its own: its
        // 1/w, coordinates, level and trilinear coefficient (one level finer than the pixel's would be), texel, base
        // and offset colours, shading, fog (with its own 1/w, or its own offset alpha) and trilinear fade. The four
        // colours are then averaged per channel, each row's two and then the rows. (The base and offset colours of
        // the centre: 125k pixels of supsample2's Gouraud pages miss; the fog of the average: every fog page misses;
        // the texels averaged before they are shaded: 56k pixels of supsample page 18.)
        using Stepper = std::remove_reference_t<decltype(entry->ips.invW)>;
        Color c4[4];
        for (int k = 0; k < 4; k++) {
            Stepper::superActive = true;
            Stepper::superHx = k & 1;
            Stepper::superHy = k >> 1;
            const pvrfp::Fp ws = entry->ips.invW.Val(p);
            const pvrfp::Fp us = pp_Texture ? entry->ips.U[two_voume_index].Quot(p, ws) : pvrfp::Fp(), vs = pp_Texture ? entry->ips.V[two_voume_index].Quot(p, ws) : pvrfp::Fp();
            RENDLOG("SS%d: w %a u %a v %a", k, ws.toDouble(), us.toDouble(), vs.toDouble());
            const Color bk = InterpolateBase<pp_UseAlpha, pp_CheapShadows>(entry->ips.Col[InVolume ? 1 : 0], p, ws, InVolume);
            const Color ok = pp_Texture && pp_Offset && !bump ? InterpolateOffs<pp_CheapShadows>(entry->ips.Ofs[InVolume ? 1 : 0], p, ws, InVolume) : offs;
            Stepper::superActive = false;
            Stepper::superHx = 0;
            Stepper::superHy = 0;
            u32 level = 0;
            int dTri = 0;
            Color t = { 0 };
            if (pp_Texture) {
                mipChoose(ws, true, level, dTri);
                t = filter(entry->params.tsp[two_voume_index], entry->params.tcw[two_voume_index], us, vs, level, fetch);
            }
            c4[k] = fade(FogUnit<pp_Offset, pp_ColorClamp, pp_FogCtrl>(shade(bk, t, ok), ws, bump ? 0 : ok.a), dTri);
        }
        for (int c = 0; c < 4; c++)
            col.bgra[c] = (((c4[0].bgra[c] + c4[1].bgra[c]) >> 1) + ((c4[2].bgra[c] + c4[3].bgra[c]) >> 1)) >> 1;
    } else {
        col = shade(base, textel, offs);
        // the fog table is indexed with the TSP's own 1/w (dreamcast-tests/pvr-tests/tspw)
        col = FogUnit<pp_Offset, pp_ColorClamp, pp_FogCtrl>(col, entry->ips.invW.Val(p), bump ? 0 : offs.a);
        col = fade(col, dTrilinear);
    }
// P2REF-END tsp-super

// P2REF-COPY tsp-tail refsw_tile.cpp if (tspAlphaStuck)
    if (tspAlphaStuck)
        col.a = col.a == 255 ? 255 : 0;

	return blending(index, col);
// P2REF-END tsp-tail
}
using PixelFlush_tsp_fp = decltype(&PixelFlush_tsp<0,0,0,0,0,0>);

// the dispatch table of the copy (gentable.h's PixelFlush_tsp_table, of these instances)
template <int I>
constexpr PixelFlush_tsp_fp PixelFlushTspAt()
{
    return &PixelFlush_tsp<(I >> 6) & 1, (I >> 5) & 1, (I >> 4) & 1, (I >> 3) & 1, (I >> 1) & 3, I & 1>;
}
template <int... I>
constexpr std::array<PixelFlush_tsp_fp, sizeof...(I)> PixelFlushTspAll(std::integer_sequence<int, I...>)
{
    return { PixelFlushTspAt<I>()... };
}
struct PixelFlushTable {
    std::array<PixelFlush_tsp_fp, 128> all = PixelFlushTspAll(std::make_integer_sequence<int, 128>());
    struct D5 { const PixelFlush_tsp_fp* p; PixelFlush_tsp_fp operator[](int i) const { return p[i]; } };
    struct D4 { const PixelFlush_tsp_fp* p; D5 operator[](int i) const { return { p + 2 * i }; } };
    struct D3 { const PixelFlush_tsp_fp* p; D4 operator[](int i) const { return { p + 8 * i }; } };
    struct D2 { const PixelFlush_tsp_fp* p; D3 operator[](int i) const { return { p + 16 * i }; } };
    struct D1 { const PixelFlush_tsp_fp* p; D2 operator[](int i) const { return { p + 32 * i }; } };
    D1 operator[](int i) const { return { all.data() + 64 * i }; }
};
static const PixelFlushTable PixelFlush_tsp_table;

// PixelFlush_tsp, the dispatch
bool PixelFlush_tsp(bool pp_AlphaTest, const FpuEntry* entry, PixPos p, u32 index, const pvrfp::Fp& invW, bool InVolume, ISP_BACKGND_T_type core_tag)
{
// P2REF-COPY tsp-dispatch refsw_tile.cpp u32 two_voume_index = InVolume & !FPU_SHAD_SCALE.intensity_shadow;
    u32 two_voume_index = InVolume & !FPU_SHAD_SCALE.intensity_shadow;

    RENDLOG("TSP: %d %f %f %d %f %d %08X %08X %08X %08X", index, p.x + (p.half ? 0.5 : 0.0), p.y + (p.half ? 0.5 : 0.0), InVolume, invW.toDouble(), pp_AlphaTest, entry->params.isp.full, entry->params.tsp[two_voume_index].full, entry->params.tcw[two_voume_index].full, core_tag.full);

    const bool raster = TcwRaster(entry->params.tcw[two_voume_index]);
    auto fetch = TextureFetch_table
        [entry->params.tcw[two_voume_index].VQ_Comp && !raster]
        [entry->params.tcw[two_voume_index].MipMapped && !raster]
        [entry->params.tcw[two_voume_index].ScanOrder]
        [entry->params.tcw[two_voume_index].StrideSel]
        [entry->params.tcw[two_voume_index].PixelFmt];

    auto filter = TextureFilter_table
        [entry->params.tsp[two_voume_index].IgnoreTexA]
        [entry->params.tsp[two_voume_index].ClampU]
        [entry->params.tsp[two_voume_index].ClampV]
        [entry->params.tsp[two_voume_index].FlipU]
        [entry->params.tsp[two_voume_index].FlipV]
        // a trilinear pass on a texture without mipmaps samples a single texel, at full strength (polly2-data
        // shenmue_intro: a 4444 texture with alpha, every pixel's alpha one texel's; a flat texture showed nothing)
        [entry->params.tsp[two_voume_index].FilterMode >= 2 && !entry->params.tcw[two_voume_index].MipMapped ? 0
                                                                                                  : entry->params.tsp[two_voume_index].FilterMode];

    auto combiner = ColorCombiner_table
        [entry->params.isp.Texture]
        [entry->params.isp.Offset]
        [entry->params.tsp[two_voume_index].ShadInstr];

    auto blending = BlendingUnit_table
        [entry->params.tsp[two_voume_index].SrcSelect]
        [entry->params.tsp[two_voume_index].DstSelect]
        [entry->params.tsp[two_voume_index].SrcInstr]
        [entry->params.tsp[two_voume_index].DstInstr]
        [pp_AlphaTest];
    
    auto pixel = PixelFlush_tsp_table
        [entry->params.tsp[two_voume_index].UseAlpha]
        [entry->params.isp.Texture]
        [entry->params.isp.Offset]
        [entry->params.tsp[two_voume_index].ColorClamp]
        [entry->params.tsp[two_voume_index].FogCtrl]
        [FPU_SHAD_SCALE.intensity_shadow];

    const bool rv = pixel(entry, p, invW, InVolume, index, fetch, filter, combiner, blending);

    const auto& tsp = entry->params.tsp[two_voume_index];
    if (tsp.SrcSelect && tsp.DstSelect && tsp.DstInstr == 0 && (tsp.SrcInstr == 1 || tsp.SrcInstr == 4))
        tspAlphaStuck = true;       // see tspAlphaStuck

    return rv;
// P2REF-END tsp-dispatch
}

// RenderParamTags, the whole body. Its pixels go to PixelFlush_tsp below: the hook (p2ref::set_pixel_hook), by
// default the copy above. Its index is an int, as the copy's `auto index = y * 32 + x` is: an exact match, so that
// the call picks it over refcore::PixelFlush_tsp, which argument-dependent lookup also finds (u32 index).
namespace loop {
bool PixelFlush_tsp(bool pp_AlphaTest, const FpuEntry* entry, PixPos p, int index, const pvrfp::Fp& invW, bool InVolume, ISP_BACKGND_T_type core_tag);

template<RenderMode rm>
void RenderParamTags(int tileX, int tileY) {
// P2REF-COPY core-rpt refsw_tile.cpp const bool halfpixel = HALF_OFFSET.tsp_pixel_half_offset;
    const bool halfpixel = HALF_OFFSET.tsp_pixel_half_offset;
    taRECT rect;
    rect.left = tileX;
    rect.top = tileY;
    rect.bottom = rect.top + 32;
    rect.right = rect.left + 32;

    static Span spans[32 * 32];
    static u16 order[32 * 32];
    const int n = SpanSort(spans, SpanGen<rm>(spans), order);
    RENDLOG("PASS: %d %d %d", (int)rm, tileX, tileY);

    for (int s = 0; s < n; s++) {
        const Span& span = spans[order[s]];
        const int y = span.y;
        PlaneStepper3::SpanStart = span.x;
        RENDLOG("SPAN: %d %d %d %08X %d", y, span.x, span.len, span.tag, (int)rm);
        for (int x = span.x; x < span.x + span.len; x++) {
            auto index = y * 32 + x;
            ISP_BACKGND_T_type t { .full = span.tag };
            // inside a modifier volume, whatever the polygon's shadow bit; the volume's parameters (or its intensity)
            // only for a polygon with the bit
            const bool volHit = (stencilBuffer[index] & 0b001) == 0b001;
            bool InVolume = volHit && t.shadow;
            if (rm == RM_PUNCHTHROUGH_PASS0 || rm == RM_PUNCHTHROUGH_PASSN) {
                InVolume = false;
            }

            tilePixelsShaded++;
            const auto& Entry = GetFpuEntry(&rect, rm, t);
            const PixPos pp = { x, y, halfpixel };
            const pvrfp::Fp invW = Entry.ips.invW.Val(pp);
            // Punch through shaded again inside a modifier volume is alpha tested too: its colour replaces the
            // pixel's, not blended with its alpha (dreamcast-tests/pvr-tests/dumprules, cell 22)
            // a pixel resolved in the pass before: shaded for the run, keeps its colour, goes on below
            const bool keepRes = (rm == RM_PUNCHTHROUGH_PASS0 || rm == RM_PUNCHTHROUGH_PASSN) && tagStatus[index].rendered;
            const u32 keep1 = colorBuffer1[index], keep2 = colorBuffer2[index];
            bool AlphaTestPassed = PixelFlush_tsp(rm == RM_PUNCHTHROUGH_PASS0 || rm == RM_PUNCHTHROUGH_PASSN || (rm == RM_PUNCHTHROUGH_MV && tagStatus[index].rendered), &Entry, pp, index, invW, InVolume, t);
            if (keepRes) {
                colorBuffer1[index] = keep1; colorBuffer2[index] = keep2;
                depthBuffer[depthBufferB][index] = depthBuffer[depthBufferA][index];
                tagBuffer[tagBufferB][index] = tagBuffer[tagBufferA][index];
                tagStatus[index].valid = false;
                continue;
            }

            if (rm == RM_PUNCHTHROUGH_PASS0 || rm == RM_PUNCHTHROUGH_PASSN) {
                // can only happen when rm == RM_PUNCHTHROUGH
                if (!AlphaTestPassed) {
                    // the next pass looks below this fragment's key; the pixel is shaded again only if that pass
                    // draws a polygon there (shading the same one again with another run start could pass:
                    // dreamcast-tests/pvr-tests/ptruns; polly2-data jgr_tree_shadows2)
                    MoreToDraw = true;
                    depthBuffer[depthBufferB][index] = depthBuffer[depthBufferA][index];
                    tagBuffer[tagBufferB][index] = tagBuffer[tagBufferA][index];
                    tagStatus[index].valid = false;
                } else {
                    tagStatus[index].rendered = true;
                    tagStatus[index].valid = false;
                    resPass[index] = PtPass;
                    resTag[index] = tagBuffer[tagBufferA][index];
                    resDepth[index] = depthBuffer[depthBufferA][index];
                    depthBuffer[depthBufferB][index] = depthBuffer[depthBufferA][index];      // the next pass looks below it
                    tagBuffer[tagBufferB][index] = tagBuffer[tagBufferA][index];
                }
            }

            if (rm == RM_TRANSLUCENT_PRESORT) {
                tagStatus[index].valid = false;
            }
            // a sorted translucent layer leaves its depth for a keep Z entry after this one, whether it writes depth
            // or not; drawn back to front, so the nearest stays (dreamcast-tests/pvr-tests/keepz page 3; as
            // polly2-rtl's z_keep restore)
            if (rm == RM_TRANSLUCENT_AUTOSORT)
                SaveDepthAt(index, depthBuffer[depthBufferA][index]);     // the ISP's depth of the layer drawn
        }
    }
// P2REF-END core-rpt
}
}   // namespace loop

}   // namespace copy
}   // namespace p2ref

#endif  // P2REF_GLUE_TILE

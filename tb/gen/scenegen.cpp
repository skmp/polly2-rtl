// scenegen.cpp: generated scenes for the tile-level testbenches (PLAN 1.3 "Generated scenes", M5). C++ on the refcore
// headers (the register and list types) and the L2 environment (tb/ref/refcore_env.cpp: pvr_regs, emu_vram, the
// 32-bit-area mapping): it writes a region array, object lists and parameter blocks straight into video memory, and the
// registers, as the TA and a game's driver would leave them, and saves them as a capture's input.
//
//   build/tools/scenegen <seed> <folder>      <folder>/r<k>/{vram.bin, pvr_regs.bin}, one per render (1 or 2)
//   build/tools/scenegen --classes <seed>     the classes the seed draws, on standard output
//
// tools/gate/capture_prerender.sh gen:<seed> loads each into refsw3-offline (`regs`, `vram`, `render`) and saves before
// and after; tb/tile/subset_seeds.txt lists the seeds of the subset (conventions.md 7.8).
//
// Each seed draws a mix of the classes of PLAN 1.3, each with a chance of 28 % (every scene has opaque primitives):
//   STRIPS     strips with masks (also all-zero masks), triangle and quad arrays, links between list blocks
//   MODVOL     modifier volumes: inside and outside, chains of volumes, culled and bad-corner closing triangles,
//              shadow polygons (two volumes, or intensity mode with FPU_SHAD_SCALE)
//   PT         punch-through lists at chunk sizes 0, 1, 2, 0x20 .. 0x40 and 0x3ff, with culled primitives
//   SHARED     the same parameter block in the opaque and the punch-through list; ISP_BACKGND_T pointing at a PT
//              block (PT_MV runs with mixed `rendered`)
//   BGTAG      ISP_BACKGND_T with bits 31:29 set, and 0xFFFFFFFF
//   TRANS      presorted and autosorted translucent lists with ties (coplanar primitives), autosort lists longer than
//              the translucent cache (64 and more primitives in a tile), translucent modifier volumes
//   KEEPZ      keep-Z chains (several entries a tile), no-writeout entries, empty keep-Z entries spaced far apart
//   EDGES      corners of +-0, denormals, 2^127, +-inf, NaN, slivers, points; far corners (steps of 2^123 and more,
//              first row 28 .. 31, 32 sx near 2^131 and 2^132); column steps below zero at multiples of 2^124 .. 2^127;
//              points and tiny triangles with the top corner in row 31
//   ROWS       back-to-back small primitives on the same rows (the RTL's row bypass)
//   TSP        textures of every format (VQ, mipmaps, palettes, bump maps, YUV), filters, SupSample, fog, blend modes,
//              the secondary buffer, depths across the range (the TSP's planes)
//   FRAME      the write-out: pack modes, dither, clips, render to texture, the scaler, strip buffers; a second render
//              (the tile buffers and offsKept carry over)
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <vector>

#include "p2ref.h"
#include "p2tb.h"

namespace {

using p2tb::Rng;
typedef uint32_t u32;

enum Class { STRIPS, MODVOL, PT, SHARED, BGTAG, TRANS, KEEPZ, EDGES, ROWS, TSP, FRAME, NCLASSES };
const char* const kClassName[NCLASSES] = { "strips", "modvol", "pt", "shared", "bgtag", "trans", "keepz", "edges",
                                           "rows", "tsp", "frame" };

// ---- video memory layout (32-bit-area addresses; textures in the 64-bit area at 0x600000 .. 0x800000, which is the
// 32-bit area's 0x300000 .. 0x400000 and 0x700000 .. 0x800000: nothing else is put there) -------------------------
// parameter blocks: (PARAM_BASE & 0xF00000) .. + 0xF0000, PARAM_BASE 0 or 0x100000 (or 0x40: the ISP's 0)
const u32 kListArea = 0x200000;         // object lists, 0x200000 .. 0x260000
const u32 kRegionArea = 0x268000;       // the region array
const u32 kFbArea = 0x500000;           // the framebuffer, 0x500000 .. 0x6c0000
const u32 kRttArea = 0x5c0000;          // render to texture: physical 0x5c0000 .. 0x600000 (32-bit 0x2e0000 .., 0x6e0000 ..)
const u32 kTexLo = 0x600000, kTexHi = 0x800000;   // 64-bit area

u32 F(float f)
{
    u32 b;
    memcpy(&b, &f, 4);
    return b;
}
float Fl(u32 b)
{
    float f;
    memcpy(&f, &b, 4);
    return f;
}
void W32(u32 a, u32 w) { p2ref::set_vram32(a, w); }
void Reg(u32 addr, u32 v) { memcpy(p2ref::regs() + addr, &v, 4); }

struct Vtx { u32 x, y, z, u, v, col, offs, u1, v1, col1, offs1; };

// one primitive of a list: its parameter block, the object list entry's kind and the tag
struct Obj {
    int kind;               // 0 strip, 1 triangle array, 2 quad array
    u32 paramAddr;          // 32-bit area
    u32 skip;
    bool shadow;
    int prims;              // strip: vertices 3 .. 8; arrays: primitives 1 .. 16
    float x0, y0, x1, y1;   // the bounding box of its corners (for the tiles it is listed in; +-inf: all tiles)
};

struct Scene {
    Rng rng;
    bool cls[NCLASSES] = {};
    int tw = 2, th = 2;                 // tiles
    u32 paramBase = 0;                  // PARAM_BASE
    u32 paramNext = 0x100;              // the next free parameter word
    u32 listNext = kListArea;
    bool regionV2 = true;               // FPU_PARAM_CFG bit 21: 6-word entries with the punch-through list
    bool intensity = false;             // FPU_SHAD_SCALE bit 8
    explicit Scene(uint64_t seed) : rng(Rng::of(seed, 0)) {}

    int R(int a, int b) { return (int)rng.range(a, b); }
    bool C(unsigned perMille) { return rng.chance(perMille); }
    float U(float a, float b) { return a + (b - a) * (float)(rng.u32() >> 8) * (1.0f / 16777216.0f); }

    // ---- registers ----
    u32 isp(int depthMode, int cull, bool zwd, bool tex, bool offs, bool gouraud, bool uv16, bool bypass, bool dcalc)
    {
        return (u32)depthMode << 29 | (u32)cull << 27 | (u32)zwd << 26 | (u32)tex << 25 | (u32)offs << 24 |
               (u32)gouraud << 23 | (u32)uv16 << 22 | (u32)bypass << 21 | (u32)dcalc << 20;
    }
    u32 tspWord(bool translucent)
    {
        u32 srcI = R(0, 7), dstI = R(0, 7);
        if (!translucent && C(700)) { srcI = 1; dstI = 0; }                 // ONE, ZERO
        if (translucent && C(600)) { srcI = 4; dstI = 5; }                  // SRC_A, 1-SRC_A
        const bool sel = cls[TSP] && C(150);
        u32 t = srcI << 29 | dstI << 26 | (u32)(sel && C(500)) << 25 | (u32)(sel && C(500)) << 24;
        t |= (u32)(cls[TSP] ? R(0, 3) : (C(800) ? 2 : R(0, 3))) << 22;     // FogCtrl (2: none)
        t |= (u32)C(300) << 21 | (u32)C(translucent ? 900 : 300) << 20 | (u32)C(200) << 19;   // clamp, alpha, ignore tex a
        t |= (u32)R(0, 15) << 15;                                           // flip / clamp UV
        t |= (u32)R(0, 3) << 13;                                            // filter
        t |= (u32)(cls[TSP] && C(150)) << 12;                               // SupSample
        t |= (u32)R(0, 15) << 8;                                            // MipMapD
        t |= (u32)R(0, 3) << 6;                                             // ShadInstr
        t |= (u32)R(0, 3) << 3 | (u32)R(0, 3);                              // TexU, TexV: 8 .. 64
        return t;
    }
    u32 tcwWord(u32 tsp)
    {
        const int fmt = cls[TSP] ? R(0, 6) : R(0, 2);
        const bool vq = C(cls[TSP] ? 250 : 50), mip = C(cls[TSP] ? 350 : 100), scan = C(150), stride = scan && C(300);
        const u32 size = (8u << ((tsp >> 3) & 7)) * (8u << (tsp & 7)) * 2 * 2;     // bytes, with mipmaps' room
        const u32 a = kTexLo + (u32)rng.below(kTexHi - kTexLo - size - 0x1000) ;
        u32 w = (a >> 3) & 0x1fffff;
        if (fmt == 5 || fmt == 6)
            w |= (u32)R(0, 63) << 21;                                       // palette select
        else
            w |= (u32)stride << 25 | (u32)scan << 26;
        return w | (u32)fmt << 27 | (u32)vq << 30 | (u32)mip << 31;
    }

    // ---- corners ----
    // an ordinary corner near the screen
    u32 cx() { return F(U(-24.0f, tw * 32 + 24.0f)); }
    u32 cy() { return F(U(-24.0f, th * 32 + 24.0f)); }
    u32 depth()
    {
        switch (R(0, 9)) {
        case 0: return F(U(0.0001f, 0.001f));
        case 1: return F(U(100.0f, 10000.0f));
        case 2: return F(0.5f);                         // ties
        case 3: return F(ldexpf(1.0f, R(-40, 40)));
        default: return F(U(0.01f, 2.0f));
        }
    }
    // an edge-case corner coordinate (EDGES)
    u32 odd(bool y)
    {
        static const u32 specials[] = { 0x80000000, 0x00000000, 0x00000001, 0x80000001, 0x007fffff, 0x7f000000,
                                        0xff000000, 0x7f800000, 0xff800000, 0x7fc00000, 0x7f7fffff, 0xfeffffff };
        switch (R(0, 7)) {
        case 0: return specials[R(0, 11)];
        case 1: return F((C(500) ? 1 : -1) * ldexpf(1.0f, R(100, 127)) * U(1.0f, 1.99f));   // far
        case 2: return F((C(500) ? 1 : -1) * ldexpf(1.0f, R(123, 127)));                    // multiples of 2^123 ..
        case 3: return F((float)((y ? R(0, th - 1) : R(0, tw - 1)) * 32 + R(28, 31)) + U(0.0f, 0.999f));   // rows 28 .. 31
        default: return y ? cy() : cx();
        }
    }

    Vtx vtx(bool edges)
    {
        Vtx v;
        v.x = edges && C(300) ? odd(false) : cx();
        v.y = edges && C(300) ? odd(true) : cy();
        v.z = edges && C(150) ? odd(false) : depth();
        v.u = F(U(-2.0f, 3.0f));
        v.v = F(U(-2.0f, 3.0f));
        if (cls[TSP] && C(100)) { v.u = F(U(-1000.0f, 1000.0f)); v.v = F(ldexpf(1.0f, R(-30, 30))); }
        v.col = rng.u32();
        v.offs = rng.u32();
        v.u1 = F(U(-1.0f, 2.0f));
        v.v1 = F(U(-1.0f, 2.0f));
        v.col1 = rng.u32();
        v.offs1 = rng.u32();
        return v;
    }

    // ---- parameter blocks ----
    u32 alloc(u32 words)
    {
        const u32 a = paramNext;
        paramNext += words * 4;
        if (paramNext > (paramBase & 0xF00000) + 0xF0000) {
            fprintf(stderr, "scenegen: out of parameter memory\n");
            exit(1);
        }
        return a;
    }
    // the words a vertex takes beyond x, y, z, per volume, with these ISP bits
    static u32 skipOf(u32 ispw) { return (ispw >> 25 & 1 ? (ispw >> 22 & 1 ? 1 : 2) : 0) + 1 + (ispw >> 24 & 1); }
    void writeVtx(u32& a, u32 ispw, bool two, const Vtx& v)
    {
        W32(a, v.x); W32(a + 4, v.y); W32(a + 8, v.z); a += 12;
        const bool tex = ispw >> 25 & 1, offs = ispw >> 24 & 1, uv16 = ispw >> 22 & 1;
        for (int vol = 0; vol < (two ? 2 : 1); vol++) {
            const u32 uu = vol ? v.u1 : v.u, vv = vol ? v.v1 : v.v;
            if (tex) {
                if (uv16) { W32(a, (uu & 0xffff0000) | vv >> 16); a += 4; }
                else { W32(a, uu); W32(a + 4, vv); a += 8; }
            }
            W32(a, vol ? v.col1 : v.col); a += 4;
            if (offs) { W32(a, vol ? v.offs1 : v.offs); a += 4; }
        }
    }
    // a parameter block of n corners; returns the block's address
    u32 block(u32 ispw, bool two, int n, const std::vector<Vtx>& vs, bool translucent)
    {
        const u32 per = 3 + skipOf(ispw) * (two ? 2 : 1);
        const u32 a0 = alloc(3 + (two ? 2 : 0) + per * n);
        u32 a = a0;
        const u32 t0 = tspWord(translucent);
        W32(a, ispw); W32(a + 4, t0); W32(a + 8, tcwWord(t0)); a += 12;
        if (two) { const u32 t1 = tspWord(translucent); W32(a, t1); W32(a + 4, tcwWord(t1)); a += 8; }
        for (int i = 0; i < n; i++)
            writeVtx(a, ispw, two, vs[i]);
        return a0;
    }

    // ---- primitives ----
    std::vector<Obj> objs[5];           // per list: 0 opaque, 1 opaque modvol, 2 translucent, 3 translucent modvol, 4 PT
    void bbox(Obj& o, const std::vector<Vtx>& vs)
    {
        o.x0 = o.y0 = INFINITY;
        o.x1 = o.y1 = -INFINITY;
        for (const Vtx& v : vs) {
            float x = Fl(v.x), y = Fl(v.y);
            if (!std::isfinite(x) || !std::isfinite(y) || fabsf(x) > 4096 || fabsf(y) > 4096) {
                o.x0 = o.y0 = -INFINITY; o.x1 = o.y1 = INFINITY;
                return;
            }
            o.x0 = std::min(o.x0, x); o.x1 = std::max(o.x1, x);
            o.y0 = std::min(o.y0, y); o.y1 = std::max(o.y1, y);
        }
    }
    u32 polyIsp(bool translucent, bool pt)
    {
        const bool tex = C(cls[TSP] ? 700 : 300), offs = C(400), uv16 = tex && C(300);
        int dm = translucent || pt ? R(0, 7) : (C(700) ? R(1, 3) : R(0, 7));
        if (pt && C(500)) dm = 6;
        const int cull = C(700) ? 0 : R(1, 3);
        return isp(dm, cull, C(150), tex, offs, C(700), uv16, C(100), C(200));
    }
    void poly(int list, bool translucent, bool pt)
    {
        Obj o;
        const u32 ispw = polyIsp(translucent, pt);
        // Translucent primitives keep their depth planes in range: a fragment whose stored depth is above the
        // largest finite float (a steep plane extrapolated: an overflow key) is above the autosort's empty reference
        // (PeelBuffers' 0x7f7fffff) every other pass, and refsw3's passes never end (nor, presumably, a console's).
        // So no edge-case corners, no tiny primitives and depths within 10 % of one another there.
        const bool edges = cls[EDGES] && C(300) && !translucent;
        const bool tame = translucent;
        // the shadow bit: two volumes, or with FPU_SHAD_SCALE bit 8 the intensity shadow (one volume)
        o.shadow = cls[MODVOL] && C(500);
        const bool two = o.shadow && !intensity;
        const int kind = R(0, 9) < (cls[STRIPS] ? 4 : 1) ? 0 : (C(600) ? 1 : 2);
        o.kind = kind;
        o.skip = skipOf(ispw);
        if (cls[STRIPS] && C(50)) o.skip = R(0, 7);    // a skip that does not match the ISP word
        std::vector<Vtx> vs;
        if (kind == 0) {
            o.prims = R(3, 8);
            Vtx v = vtx(edges);
            const float sx = U(6.0f, 32.0f), sy = U(6.0f, 40.0f);
            for (int i = 0; i < o.prims; i++) {
                Vtx w = vtx(edges);
                if (!edges || C(500)) {         // a strip that goes somewhere
                    w.x = F(Fl(v.x) + (i >> 1) * sx + U(-2, 2));
                    w.y = F(Fl(v.y) + (i & 1) * sy + U(-2, 2));
                    if (C(800) || tame) w.z = tame ? F(Fl(v.z) * U(0.95f, 1.05f)) : v.z;
                }
                vs.push_back(w);
            }
            o.paramAddr = block(ispw, two, o.prims, vs, translucent);
        } else {
            const int n = kind == 1 ? 3 : 4;
            o.prims = R(1, cls[ROWS] && !tame ? 16 : 4);
            // each primitive has its own block: the blocks are back to back (the TA's array)
            o.paramAddr = 0;
            for (int p = 0; p < o.prims; p++) {
                std::vector<Vtx> pv;
                Vtx c = vtx(edges);
                const float s = !tame && C(cls[ROWS] ? 600 : 200) ? U(0.5f, 4.0f) : U(8.0f, 64.0f);
                for (int i = 0; i < n; i++) {
                    Vtx w = vtx(edges);
                    if (!edges || C(500)) {
                        static const float qx[4] = { 0, 1, 1, 0 }, qy[4] = { 0, 0, 1, 1 };
                        w.x = F(Fl(c.x) + (n == 4 ? qx[i] : (i == 1)) * s + U(-0.5f, 0.5f));
                        w.y = F(Fl(c.y) + (n == 4 ? qy[i] : (i == 2)) * s + U(-0.5f, 0.5f));
                        if (C(700) || tame) w.z = tame ? F(Fl(c.z) * U(0.95f, 1.05f)) : c.z;
                    }
                    if (cls[ROWS] && !tame && p > 0) w.y = F(Fl(w.y) - Fl(c.y) + Fl(vs[0].y));     // the same rows
                    pv.push_back(w);
                }
                if (p == 0)
                    vs = pv;
                // the same ISP word for every primitive of the array (the list entry's skip walks the blocks)
                const u32 a = block(ispw, two, n, pv, translucent);
                if (p == 0)
                    o.paramAddr = a;
            }
        }
        bbox(o, vs);
        objs[list].push_back(o);
    }
    // a modifier volume: closed or not, inside or outside, a chain of volumes
    void volume(int list)
    {
        const int tris = R(1, 8);
        const float cx0 = U(-8, tw * 32 + 8), cy0 = U(-8, th * 32 + 8), r = U(4, 48);
        const u32 zf = depth(), zb = depth();
        Obj o;
        o.kind = 1;
        o.skip = 0;
        o.shadow = false;
        o.prims = tris;
        o.paramAddr = 0;
        std::vector<Vtx> all;
        for (int t = 0; t < tris; t++) {
            const bool last = t == tris - 1;
            const int mode = last ? (C(500) ? 1 : 2) : (C(30) ? R(1, 2) : 0);
            int cull = C(700) ? 0 : R(1, 3);
            if (last && C(200)) cull = 3;               // a culled closing triangle (often)
            const u32 ispw = (u32)mode << 29 | (u32)cull << 27;
            std::vector<Vtx> vs;
            for (int i = 0; i < 3; i++) {
                Vtx v = vtx(false);
                const float a = U(0, 6.2832f);
                v.x = F(cx0 + r * cosf(a));
                v.y = F(cy0 + r * sinf(a));
                v.z = i == t % 3 ? zb : zf;
                if (last && cls[EDGES] && C(200)) v.x = 0x7f800000;    // a bad-corner closing triangle
                vs.push_back(v);
                all.push_back(v);
            }
            const u32 a = alloc(3 + 9);
            u32 p = a;
            W32(p, ispw); W32(p + 4, rng.u32()); W32(p + 8, rng.u32()); p += 12;
            for (const Vtx& v : vs) { W32(p, v.x); W32(p + 4, v.y); W32(p + 8, v.z); p += 12; }
            if (!t) o.paramAddr = a;
        }
        // one triangle array; its primitives are the volume's triangles (at most 16 an entry)
        bbox(o, all);
        objs[list].push_back(o);
    }

    // ---- object lists ----
    u32 listWord(const Obj& o, u32 mask)
    {
        const u32 offs = ((o.paramAddr - (paramBase & 0xF00000)) / 4) & 0x1fffff;
        const u32 base = offs | (o.skip & 7) << 21 | (u32)o.shadow << 24;
        if (o.kind == 0)
            return base | (mask & 63) << 25;
        return base | (u32)((o.prims - 1) & 15) << 25 | (o.kind == 1 ? 0x80000000u : 0xA0000000u);
    }
    // the list of one tile: the objects that touch it (or all of them, or a random subset); links between blocks
    u32 writeList(const std::vector<Obj>& v, int tx, int ty, bool all)
    {
        const u32 a0 = listNext;
        u32 a = a0;
        int inBlock = 0, blockLen = cls[STRIPS] ? R(2, 12) : 1000;
        for (const Obj& o : v) {
            const bool touches = o.x1 >= tx * 32 - 1 && o.x0 <= tx * 32 + 33 && o.y1 >= ty * 32 - 1 && o.y0 <= ty * 32 + 33;
            if (!all && !touches && !C(100))
                continue;
            u32 mask = 63;
            if (o.kind == 0) {
                mask = (63u << (8 - o.prims)) & 63;      // the strip's triangles
                if (cls[STRIPS] && C(400)) mask &= rng.u32();
            }
            if (inBlock == blockLen) {                   // a link to the next block, some way off
                const u32 next = a + 4 + 4 * R(0, 16);
                W32(a, 0xE0000000u | (next & 0xfffffc));
                a = next;
                inBlock = 0;
            }
            W32(a, listWord(o, mask));
            a += 4;
            inBlock++;
        }
        W32(a, 0xF0000000u);                             // link, end of list
        listNext = a + 4 + 4 * R(0, 4);
        if (listNext > kListArea + 0x60000) {
            fprintf(stderr, "scenegen: out of list memory\n");
            exit(1);
        }
        return a0;
    }

    // ---- textures, palette, fog ----
    void fillTextures()
    {
        // physical bytes 0x600000 .. 0x800000: random, with runs of a few values (VQ indices, flat texels)
        uint8_t* m = p2ref::vram();
        for (u32 i = kTexLo; i < kTexHi; i += 4) {
            u32 w = rng.u32();
            if ((i >> 10) & 1)
                w &= 0x0f0f0f0f;
            memcpy(m + i, &w, 4);
        }
    }

    // ---- the scene ----
    void build(int render)
    {
        memset(p2ref::vram(), 0, VRAM_SIZE);
        memset(p2ref::regs(), 0, 0x2000);
        for (auto& o : objs)
            o.clear();
        listNext = kListArea;
        tw = R(1, 4);
        th = R(1, 3);
        fillTextures();
        // PARAM_BASE: the ISP takes bits 23:20, the TSP all of it (a base with low bits: the TSP reads elsewhere)
        paramBase = C(900) ? 0 : (C(500) ? 0x000040 : 0x100000);
        paramNext = (paramBase & 0xF00000) + 0x100;
        regionV2 = cls[PT] || cls[SHARED] || C(700);

        // registers
        Reg(PARAM_BASE_addr, paramBase);
        Reg(REGION_BASE_addr, kRegionArea);
        Reg(SPAN_SORT_CFG_addr, C(600) ? 0x101 : (C(500) ? 0x001 : 0x000));
        const int pm = cls[FRAME] ? R(0, 6) : (C(500) ? 1 : 6);
        Reg(FB_W_CTRL_addr, (u32)pm | (u32)C(500) << 3 | (u32)R(0, 255) << 8 | (u32)R(0, 255) << 16);
        const u32 bpp = pm <= 3 ? 2 : pm == 4 ? 3 : 4;
        const u32 width = cls[FRAME] && C(200) ? 640 : tw * 32 + 32;
        Reg(FB_W_LINESTRIDE_addr, (width * bpp + 7) / 8);
        const bool rtt = cls[FRAME] && C(150);
        Reg(FB_W_SOF1_addr, rtt ? 0x1000000 | kRttArea : kFbArea + 4 * R(0, 3));
        Reg(FB_W_SOF2_addr, kFbArea + 0x100000);
        Reg(FB_X_CLIP_addr, cls[FRAME] && C(300) ? (u32)R(0, 40) | (u32)R(40, 200) << 16 : 0x07ff0000);
        Reg(FB_Y_CLIP_addr, cls[FRAME] && C(300) ? (u32)R(0, 40) | (u32)R(40, 200) << 16 : 0x03ff0000);
        Reg(FB_R_CTRL_addr, cls[FRAME] && C(100) ? (1u << 22 | (u32)R(0, 3) << 23) : 0);
        intensity = cls[MODVOL] && C(400);
        Reg(FPU_SHAD_SCALE_addr, (u32)intensity << 8 | (u32)R(0, 255));
        Reg(FPU_CULL_VAL_addr, C(700) ? F(0.0f) : F(ldexpf(1.0f, R(-4, 4))));
        Reg(FPU_PARAM_CFG_addr, (u32)regionV2 << 21 | 0x0007df77);
        Reg(HALF_OFFSET_addr, (u32)R(0, 7));
        Reg(FPU_PERP_VAL_addr, C(800) ? 0 : F(ldexpf(1.0f, R(-30, 4))));
        Reg(ISP_FEED_CFG_addr, ptChunkReg() << 4 | (u32)C(300));
        Reg(TEXT_CONTROL_addr, (u32)R(0, 31) | (u32)R(0, 3) << 16);
        Reg(PAL_RAM_CTRL_addr, (u32)R(0, 3));
        Reg(PT_ALPHA_REF_addr, (u32)R(0, 255));
        Reg(FOG_COL_RAM_addr, rng.u32() & 0xffffff);
        Reg(FOG_COL_VERT_addr, rng.u32() & 0xffffff);
        Reg(FOG_DENSITY_addr, (u32)R(0, 0xffff));
        Reg(FOG_CLAMP_MAX_addr, rng.u32());
        Reg(FOG_CLAMP_MIN_addr, rng.u32());
        Reg(Y_COEFF_addr, C(500) ? 0x8040 : (u32)R(0, 0xffff));
        u32 sc = 0x400;
        if (cls[FRAME] && C(300))
            sc = (C(500) ? 0x401 : (C(500) ? 0x800 : (u32)R(0x200, 0x800))) | (u32)C(300) << 16 | (u32)C(200) << 17 |
                 (u32)C(200) << 18;
        Reg(SCALER_CTL_addr, sc);
        for (u32 i = 0; i < 128; i++)
            Reg(FOG_TABLE_START_addr + 4 * i, (u32)R(0, 0xffff));
        for (u32 i = 0; i < 1024; i++)
            Reg(PALETTE_RAM_START_addr + 4 * i, rng.u32());

        // primitives
        const int nOp = R(cls[ROWS] ? 6 : 3, 14);
        for (int i = 0; i < nOp; i++) poly(0, false, false);
        if (cls[MODVOL]) { const int n = R(1, 4); for (int i = 0; i < n; i++) volume(1); }
        if (cls[PT] || cls[SHARED]) {
            const int n = R(1, 12);
            for (int i = 0; i < n; i++) poly(4, false, true);
            if (cls[SHARED] && !objs[0].empty())
                objs[4].push_back(objs[0][rng.below(objs[0].size())]);          // the same block in both lists
        }
        if (cls[TRANS]) {
            const int n = C(300) ? R(64, 90) : R(2, 16);
            for (int i = 0; i < n; i++) poly(2, true, false);
            if (C(400) && !objs[2].empty())
                for (int i = 0; i < 3; i++) objs[2].push_back(objs[2][rng.below(objs[2].size())]);   // ties
            if (cls[MODVOL] && C(500)) { const int k = R(1, 3); for (int i = 0; i < k; i++) volume(3); }
        }

        // the background: a block of 3 corners; its tag
        std::vector<Vtx> bg(3);
        for (int i = 0; i < 3; i++) bg[i] = vtx(false);
        bg[0].x = F(0); bg[0].y = F(0); bg[1].x = F(640); bg[1].y = F(0); bg[2].x = F(0); bg[2].y = F(480);
        const u32 bgIsp = isp(0, 0, false, C(300), C(300), C(500), false, false, false);
        const u32 bgA = block(bgIsp, false, 3, bg, false);
        u32 bgTag = ((bgA - (paramBase & 0xF00000)) / 4) << 3 | skipOf(bgIsp) << 24;
        if (cls[SHARED] && !objs[4].empty() && C(500)) {
            const Obj& o = objs[4][rng.below(objs[4].size())];
            bgTag = ((o.paramAddr - (paramBase & 0xF00000)) / 4) << 3 | (o.skip & 7) << 24 | (u32)o.shadow << 27;
        }
        if (cls[BGTAG])
            bgTag = C(300) ? 0xFFFFFFFFu : (bgTag | (u32)R(1, 7) << 29);
        Reg(ISP_BACKGND_T_addr, bgTag);
        Reg(ISP_BACKGND_D_addr, C(800) ? F(U(0.00001f, 0.5f)) : (C(500) ? F(-U(0.1f, 100.0f)) : rng.u32()));

        // the region array
        u32 ra = kRegionArea;
        std::vector<std::pair<int, int>> order;
        for (int y = 0; y < th; y++)
            for (int x = 0; x < tw; x++)
                order.push_back({ x, y });
        if (C(300))                                       // column by column
            std::stable_sort(order.begin(), order.end(), [](auto a, auto b) { return a.first < b.first; });
        if (cls[KEEPZ] && C(500)) {
            // empty keep-Z entries spaced far apart: a second pass over the tiles
            auto again = order;
            for (auto& t : again) order.push_back(t);
        }
        for (size_t i = 0; i < order.size(); i++) {
            const int tx = order[i].first, ty = order[i].second;
            const int entries = cls[KEEPZ] && C(400) ? R(2, 3) : 1;
            for (int e = 0; e < entries; e++) {
                const bool last = i + 1 == order.size() && e + 1 == entries;
                const bool zkeep = e > 0 || (cls[KEEPZ] && C(200)) || i >= (size_t)tw * th;
                const bool nowo = cls[KEEPZ] && C(250) && !last;
                const bool emptyEntry = cls[KEEPZ] && C(200);
                const bool presort = cls[TRANS] && C(400);
                u32 ctl = (u32)tx << 2 | (u32)ty << 8 | (u32)nowo << 28 | (u32)presort << 29 | (u32)zkeep << 30 |
                          (u32)last << 31;
                auto lp = [&](int list) -> u32 {
                    if (emptyEntry || objs[list].empty() || C(50))
                        return 0x80000000u;
                    return writeList(objs[list], tx, ty, C(150));
                };
                const u32 op = lp(0), opm = (op & 0x80000000u) && C(800) ? 0x80000000u : lp(1);
                const u32 tr = lp(2), trm = lp(3), pt = regionV2 ? lp(4) : 0x80000000u;
                W32(ra, ctl); W32(ra + 4, op); W32(ra + 8, opm); W32(ra + 12, tr); W32(ra + 16, trm);
                if (regionV2) { W32(ra + 20, pt); ra += 24; } else ra += 20;
            }
        }
        (void)render;
    }
    int prims(int list) const
    {
        int n = 0;
        for (const Obj& o : objs[list]) n += o.kind == 0 ? o.prims - 2 : o.prims;
        return n;
    }
    u32 ptChunkReg()
    {
        if (!cls[PT]) return 0x40;
        static const u32 sizes[] = { 0, 1, 2, 0x20, 0x23, 0x25, 0x40, 0x3ff };
        return C(800) ? sizes[R(0, 7)] : (u32)R(0x20, 0x40);
    }
};

bool Save(const std::string& dir)
{
    mkdir(dir.c_str(), 0755);
    if (!p2ref::save_vram((dir + "/vram.bin").c_str()))
        return false;
    FILE* f = fopen((dir + "/pvr_regs.bin").c_str(), "wb");
    if (!f) return false;
    const bool ok = fwrite(p2ref::regs(), 1, 0x2000, f) == 0x2000;
    return fclose(f) == 0 && ok;
}

}   // namespace

int main(int argc, char** argv)
{
    if (argc == 3 && std::string(argv[1]) == "--classes") {
        Scene s(strtoull(argv[2], nullptr, 0));
        for (int c = 0; c < NCLASSES; c++) s.cls[c] = s.rng.chance(280);
        for (int c = 0; c < NCLASSES; c++) if (s.cls[c]) printf("%s ", kClassName[c]);
        printf("\n");
        return 0;
    }
    if (argc != 3) {
        fprintf(stderr, "usage: scenegen <seed> <folder> | scenegen --classes <seed>\n");
        return 2;
    }
    const uint64_t seed = strtoull(argv[1], nullptr, 0);
    const std::string out = argv[2];
    mkdir(out.c_str(), 0755);
    Scene s(seed);
    for (int c = 0; c < NCLASSES; c++) s.cls[c] = s.rng.chance(280);
    const int renders = s.cls[FRAME] && s.rng.chance(500) ? 2 : 1;
    for (int r = 0; r < renders; r++) {
        s.build(r);
        if (!Save(out + "/r" + std::to_string(r))) {
            fprintf(stderr, "scenegen: cannot write %s\n", out.c_str());
            return 1;
        }
    }
    printf("scenegen %llu:", (unsigned long long)seed);
    for (int c = 0; c < NCLASSES; c++) if (s.cls[c]) printf(" %s", kClassName[c]);
    printf("; %d render%s; %dx%d tiles; primitives op %d, op mod %d, tr %d, tr mod %d, pt %d\n", renders,
           renders > 1 ? "s" : "", s.tw, s.th, s.prims(0), s.prims(1), s.prims(2), s.prims(3), s.prims(4));
    return 0;
}

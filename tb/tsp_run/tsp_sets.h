// tsp_sets.h: the console sets of M10's gate (PLAN M10), read in place from dreamcast-tests (PLAN 1.2 section 2: npz.h,
// the sets' .cases.json), as triangles (p2tspcase::Case: the parameter block the RTL fetches and sets up) and the runs the
// TSP shades them in, each reading of the set at its pixel of a run. L1: refcore's pvr_softfp.h, pvr_isp_edge.h,
// pvr_tsp_plane.h only.
//
// A reading is what the console showed at a pixel; the testbench turns the TSP's numbers at that pixel into the same
// kind of number with the reading's own decoder (ReadingUV / ReadingC / ReadingMip here; wmeas's fog in the reference's
// translation unit, refsw3's FogUnit on the pixel's W) and compares it with the console's. The run a pixel belongs to
// (its first pixel is the plane's start, dreamcast-tests README "uvspan") is the triangle's first covered pixel on the
// line in the tile (dreamcast-tests model/tspprobe, which reproduces every uvmeas reading so: README "uvmeas, cmeas"
// point 4, "uvspan" rule 1; the sets are translucent lists in the order sent, each triangle whole in its pass), from
// refsw3's own edge setup (pvr_isp_edge.h EdgeWinding / EdgeTile at the tile's sample points, HALF_OFFSET 7: pvrsetup.h);
// and where the set has bands (uvspan's opaque list, uvrun's kinds 1, 2, 4, 5: pvr-tests/uvrun/main.c) a run also
// starts anew after each band edge (README "uvspan", "A run is a stretch of pixels of one triangle in the pass being
// shaded"; refsw_tile.cpp SpanGen: a span ends where the volume state changes).
//
//   family uv   uvmeas (36 sets), uvspan (4), uvrun (1): fit/<family>_data/<set>.npz tx, ty, tu, tz (tzbits), ti, px,
//               py, t: the texel number of the 1024-wide number texture, point sampled (ReadingUV: tspprobe's texel())
//   family w    wmeas (4): tx, ty, tz, ti, px, py, g: the green of the fog readout (pvr-tests/wmeas/main.c: black
//               polygons, table fog, every table pair (0, 255), density 1.0, fog colour white)
//   family c    cmeas (3): tx, ty, tc (corner colours R, G, B), tzbits, ti, px, py, rgb: Gouraud colours, 0888
//   family mip  mipmeas (10): cases.json's cells (quads as two strip triangles, or one triangle), rgb (24 x 24 from (4, 4)
//               of the cell), corner (6 x 6 from (2, 2)), tip (2 x 2 from (1, 1)): one trilinear pass of a 64 x 64
//               texture whose every level is one colour (pvr-tests/mipmeas/main.c), decal, blend ONE / ZERO: the level's
//               colour times the pass's coefficient (ReadingMip); a pixel no triangle covers is not a reading
#pragma once
#include <algorithm>
#include <cstdint>
#include <map>
#include <string>
#include <vector>
#include "npz.h"
#include "pvr_isp_edge.h"
#include "pvr_softfp.h"
#include "pvr_tsp_plane.h"
#include "tsp_cases.h"

namespace p2tspset {

using p2tspcase::Case;
using p2tspcase::FB;
using p2tspcase::BF;
using pvrfp::Fp;

enum Kind { K_UV = 0, K_W, K_C, K_MIP };

// one run: the triangle (Case index), the tile, the line, the first column and the length; its readings (pixel n of the
// run, the reading's index in Set::want)
struct Run {
    int tri = 0, tx = 0, ty = 0, y = 0, x = 0, len = 1;
    int grp = 0;                  // the (page, tile) group: one region array entry of the testbench
    std::vector<std::pair<int, int>> rd;
};

struct Set {
    std::string family, name;     // e.g. "uvmeas", "urfull_3"
    Kind kind = K_UV;
    std::vector<Case> tris;
    std::vector<Run> runs;        // grouped by tile (runs of one tile together, tiles in the order first met)
    std::vector<int32_t> want;    // the console's reading
    long skipped = 0;             // readings that are not a value (uv: t < 0, "not a texel's colour", tspprobe)
};

// ---------------------------------------------------------------------------------------------------------------
// the decoders: the console's number from the TSP's numbers at the pixel

// uv: the texel of the 1024-wide repeating number texture, point sampled (dreamcast-tests model/tspprobe.cpp texel(): its
// definition of a reading, copied as it is there; the quotient u is the TSP's U)
inline int ReadingUV(double u)
{
    double uf = (double)(float)u;
    if (uf == 0 && u < 0)
        uf = -1e-30;                 // a quotient below zero stays below zero however small: the texel before 0
    double f = floor(uf * 1024.0 * 256.0);
    if (f >= 1073741824.0)
        f = 1073741824.0 + fmod(f, 67108864.0);
    else if (f < -1073741824.0)
        f = -1073741824.0 + fmod(fmod(f, 67108864.0) + 67108864.0, 67108864.0);
    if (!(f == f))
        f = 0;                       // a quotient that is not a number, or too large to wrap: texel 0
    return (((int)f) >> 8) & 1023;
}
inline double ToDouble(bool neg, int exp, uint64_t mant) { return (neg ? -1.0 : 1.0) * ldexp((double)mant, exp); }

// c: the colour as the framebuffer (0888) holds it, R << 16 | G << 8 | B
inline int32_t ReadingC(int r, int g, int b) { return r << 16 | g << 8 | b; }

// mip: level L's colour (RGB565 level_color[6 - L] of pvr-tests/mipmeas/main.c, expanded as ExpandToARGB8888: 5 bits
// c << 3 | c >> 2, 6 bits c << 2 | c >> 4) times the pass's coefficient (refsw_tile.cpp PixelFlush_tsp fade: pass A
// 256 - k, pass B k, (c w) >> 8)
inline int32_t ReadingMip(int level, int k, int mode)
{
    static const uint16_t lc[7] = {0xffff, 0xf81f, 0x07ff, 0xffe0, 0x001f, 0x07e0, 0xf800};   // 1x1 .. 64x64
    const int li = 6 - std::min(std::max(level, 0), 6);
    const uint16_t c = lc[li];
    const int r5 = c >> 11, g6 = (c >> 5) & 63, b5 = c & 31;
    int rgb[3] = {r5 << 3 | r5 >> 2, g6 << 2 | g6 >> 4, b5 << 3 | b5 >> 2};
    const int kk = std::min(std::max(k, 0), 256);
    const int w = mode == 2 ? 256 - kk : kk;
    for (int& ch : rgb) ch = (ch * w) >> 8;
    return ReadingC(rgb[0], rgb[1], rgb[2]);
}

// ---------------------------------------------------------------------------------------------------------------
// coverage: refsw3's edge setup of the triangle in a tile (RasterizeTriangle: EdgeWinding, the three EdgeTile at the
// tile's first sample point, HALF_OFFSET bit 0 set)
struct Cover {
    pvrisp::EdgeTile e[3];
    bool ok = false;
    void setup(const Case& c, int tx, int ty)
    {
        static const pvrisp::EdgeHW cfg;
        Fp fx[3], fy[3];
        for (int k = 0; k < 3; k++) { fx[k] = Fp::FromBits(c.p.v[k].x); fy[k] = Fp::FromBits(c.p.v[k].y); }
        const int sgn = pvrisp::EdgeWinding(fx, fy, cfg);
        const int64_t x0h = 2 * (int64_t)(32 * tx) + 1, y0h = 2 * (int64_t)(32 * ty) + 1;
        for (int k = 0; k < 3; k++)
            e[k].Setup(fx[k], fy[k], fx[(k + 1) % 3], fy[(k + 1) % 3], x0h, y0h, sgn, cfg);
        ok = true;
    }
    bool in(int i, int j) const { return e[0].Inside(i, j) && e[1].Inside(i, j) && e[2].Inside(i, j); }
};

// the readings of a (triangle, tile, line), as runs: cut[] the columns (tile-local) at which a run starts anew; a run
// starts at the first covered pixel at or after the last cut at or before the reading
inline void MakeRuns(const Case& c, int tri, int tx, int ty, int j, const std::vector<std::pair<int, int>>& rd /* (col, idx) */,
                     const std::vector<int>& cuts, std::vector<Run>* out)
{
    Cover cv;
    cv.setup(c, tx % 1000, ty);
    std::map<int, Run> byStart;
    for (const auto& q : rd) {
        const int i = q.first;
        int seg = 0;
        for (int b : cuts) if (b <= i && b > seg) seg = b;
        int s0 = i;
        for (int k = seg; k < i; k++) if (cv.in(k, j)) { s0 = k; break; }
        Run& r = byStart[s0];
        r.tri = tri; r.tx = tx % 1000; r.ty = ty; r.y = j; r.x = s0;
        r.len = std::max(r.len, i - s0 + 1);
        r.rd.push_back({i - s0, q.second});
    }
    for (auto& kv : byStart) out->push_back(kv.second);
}

// readings grouped (triangle, tile, line) -> runs, tiles kept together in the order first met
struct Grouper {
    std::map<std::tuple<int, int, int>, std::vector<std::tuple<int, int, int, int>>> byTile;   // (ty, tx, order) -> (tri, j, col, idx)
    std::map<std::pair<int, int>, int> tileOrder;
    void add(int tri, int px, int py, int idx)
    {
        const int tx = px / 32, ty = py / 32;
        auto it = tileOrder.find({tx, ty});
        const int o = it == tileOrder.end() ? (tileOrder[{tx, ty}] = (int)tileOrder.size()) : it->second;
        byTile[{o, tx, ty}].push_back({tri, py % 32, px % 32, idx});
    }
    template<class CutsOf>
    void runs(const std::vector<Case>& tris, CutsOf cutsOf, std::vector<Run>* out)
    {
        int grp = 0;
        for (auto& kv : byTile) {
            const int tx = std::get<1>(kv.first), ty = std::get<2>(kv.first);
            const size_t first = out->size();
            std::map<std::pair<int, int>, std::vector<std::pair<int, int>>> lines;      // (tri, j) -> (col, idx)
            for (const auto& r : kv.second) lines[{std::get<0>(r), std::get<1>(r)}].push_back({std::get<2>(r), std::get<3>(r)});
            for (auto& l : lines)
                MakeRuns(tris[l.first.first], l.first.first, tx, ty, l.first.second, l.second, cutsOf(l.first.first, tx), out);
            for (size_t k = first; k < out->size(); k++) (*out)[k].grp = grp;
            grp++;
        }
    }
};

// ---------------------------------------------------------------------------------------------------------------
// the sets
inline std::vector<std::string> Names(const std::string& family)
{
    if (family == "uvmeas")
        return {"dump_gundam1", "dump_jgr2a", "dump_rayman1", "dump_rayman2", "reach1", "uflat2", "ugen5", "urecip6",
                "urfull_0", "urfull_1", "urfull_10", "urfull_11", "urfull_12", "urfull_13", "urfull_2", "urfull_3", "urfull_4",
                "urfull_5", "urfull_6", "urfull_7", "urfull_8", "urfull_9", "urrow9", "urrown10", "urscan7", "urscan8",
                "usteep3", "uv1", "uwflat4", "wexp1", "whuge1", "wneg1", "wspec1", "wtiny1", "wzero1", "wzero2"};
    if (family == "uvspan") return {"cspan31", "cspan32tr", "span1", "span2tr"};
    if (family == "uvrun") return {"run2"};
    if (family == "wmeas") return {"flat2", "scan3", "slopes4", "w1"};
    if (family == "cmeas") return {"c1", "cwext1", "cwsum1"};
    if (family == "mipmeas") return {"d0dcalc", "d0first", "dcalc5", "det3", "det4", "first1", "mpos1", "mwext1", "mwextd1", "w2"};
    return {};
}
inline const char* const kFamilies[] = {"uvmeas", "uvspan", "uvrun", "wmeas", "cmeas", "mipmeas"};

inline bool ReadJson(const std::string& path, p2tspcase::Json* j, std::string* err)
{
    std::string t;
    if (!p2tspcase::ReadText(path, &t) || !p2tspcase::Json::Parse(t, j)) { *err = "cannot read " + path; return false; }
    return true;
}
inline bool Arr(p2npz::Npz& z, const char* name, p2npz::Array* a, std::string* err)
{
    if (!z.array(name, a)) { *err = z.error; return false; }
    return true;
}

// a textured triangle (U through the number texture; V = U), untextured Gouraud ones (w, c)
inline Case TriCase(const float x[3], const float y[3], const uint32_t zb[3])
{
    Case c;
    c.p.isp = p2tspcase::ISP_GOURAUD;
    c.p.skip = 1;
    for (int k = 0; k < 3; k++) { c.p.v[k].x = FB(x[k]); c.p.v[k].y = FB(y[k]); c.p.v[k].z = zb[k]; c.p.v[k].col = 0xff000000u; }
    return c;
}

inline bool Load(const std::string& dcts, const std::string& family, const std::string& name, Set* s, std::string* err)
{
    s->family = family;
    s->name = name;
    s->tris.clear();
    s->runs.clear();
    s->want.clear();
    s->skipped = 0;
    const std::string base = dcts + "/fit/" + family + "_data/" + name;
    p2tspcase::Json js;
    if (!ReadJson(base + ".cases.json", &js, err)) return false;
    if (family == "mipmeas") {
        s->kind = K_MIP;
        p2npz::Npz z;
        if (!z.open(base + ".npz")) { *err = z.error; return false; }
        p2npz::Array rgb, corner, tip;
        // corner and tip are in the later sets only (det3: corner; det4 on: both)
        const bool hasCorner = z.has("corner"), hasTip = z.has("tip");
        if (!Arr(z, "rgb", &rgb, err) || (hasCorner && !Arr(z, "corner", &corner, err)) || (hasTip && !Arr(z, "tip", &tip, err)))
            return false;
        const p2tspcase::Json& pages = js.at("pages");
        Grouper g;
        std::vector<std::vector<int>> cellTris;
        size_t qi = 0;
        for (size_t pg = 0; pg < pages.size(); pg++)
            for (size_t ci = 0; ci < pages[pg].size(); ci++, qi++) {
                const p2tspcase::Json& q = pages[pg][ci];
                const float cx = (float)(ci % 20) * 32.0f, cy = (float)(ci / 20) * 32.0f;
                float z4[4], u4[4], v4[4];
                for (int k = 0; k < 4; k++) {
                    z4[k] = q.at("z").t == p2tspcase::Json::Arr ? (float)q.at("z")[k].n : (float)q.at("z").n;
                    u4[k] = (float)q.at("uv")[k][0].n;
                    v4[k] = (float)q.at("uv")[k][1].n;
                }
                const int dc = q.has("dcalc") ? (int)q.at("dcalc").n : 0, bias = (int)q.at("bias").n, mode = (int)q.at("mode").n;
                // every cell its own page in the tile list: the triangles of page pg are a separate render; the runs carry
                // the triangle, the tile is the cell's (pages share tiles: grouped by (page, tile) through the triangle)
                std::vector<int> mine;
                auto push = [&](const float x[3], const float y[3], const float zz[3], const float u[3], const float v[3]) {
                    Case c = p2tspcase::MipCase(x, y, zz, u, v, dc, bias, mode);
                    c.src = p2tspcase::SRC_MIPMEAS;
                    c.set = "mipmeas " + name;
                    c.page = (int)pg;
                    c.cell = (int)ci;
                    mine.push_back((int)s->tris.size());
                    s->tris.push_back(c);
                };
                if (q.has("legs") || q.has("tri")) {
                    float x[3], y[3];
                    if (q.has("tri"))
                        for (int k = 0; k < 3; k++) { x[k] = cx + (float)q.at("tri")[k][0].n; y[k] = cy + (float)q.at("tri")[k][1].n; }
                    else {
                        const float a = (float)q.at("legs")[0].n, b = (float)q.at("legs")[1].n;
                        x[0] = cx; y[0] = cy; x[1] = cx + a; y[1] = cy; x[2] = cx; y[2] = cy + b;
                    }
                    push(x, y, z4, u4, v4);
                } else {
                    const float X[4] = {cx, cx + 32, cx, cx + 32}, Y[4] = {cy, cy, cy + 32, cy + 32};
                    const int tr[2][3] = {{0, 1, 2}, {2, 1, 3}};
                    for (int t2 = 0; t2 < 2; t2++) {
                        float x[3], y[3], zz[3], u[3], v[3];
                        for (int k = 0; k < 3; k++) {
                            const int i = tr[t2][k];
                            x[k] = X[i]; y[k] = Y[i]; zz[k] = z4[i]; u[k] = u4[i]; v[k] = v4[i];
                        }
                        push(x, y, zz, u, v);
                    }
                }
                // the cell's readings: rgb (24 x 24 at 4), corner (6 x 6 at 2), tip (2 x 2 at 1); the owner the last
                // triangle drawn that covers the pixel (ONE / ZERO replaces)
                const int tx = (int)(ci % 20), ty = (int)(ci / 20);
                std::vector<Cover> cv(mine.size());
                for (size_t m = 0; m < mine.size(); m++) cv[m].setup(s->tris[mine[m]], tx, ty);
                auto reading = [&](const p2npz::Array& a, size_t n, int x0, int side) {
                    for (int k = 0; k < side * side; k++) {
                        const int i = x0 + k % side, j = x0 + k / side;
                        int owner = -1;
                        for (size_t m = 0; m < mine.size(); m++) if (cv[m].in(i, j)) owner = mine[m];
                        const size_t o = (n * (size_t)(side * side) + (size_t)k) * 3;
                        if (owner < 0) { s->skipped++; continue; }
                        const int idx = (int)s->want.size();
                        s->want.push_back(ReadingC(a.u8(o), a.u8(o + 1), a.u8(o + 2)));
                        // pages are separate renders: the tile key carries the page (tx + 20 * 1000 * page keeps them apart)
                        g.add(owner, 32 * tx + i + 32 * 1000 * (int)pg, 32 * ty + j, idx);
                    }
                };
                reading(rgb, qi, 4, 24);
                if (hasCorner) reading(corner, qi, 2, 6);
                if (hasTip) reading(tip, qi, 1, 2);
            }
        g.runs(s->tris, [](int, int) { return std::vector<int>(); }, &s->runs);
        return true;
    }
    p2npz::Npz z;
    if (!z.open(base + ".npz")) { *err = z.error; return false; }
    p2npz::Array tx, ty, ti, px, py;
    if (!Arr(z, "tx", &tx, err) || !Arr(z, "ty", &ty, err) || !Arr(z, "ti", &ti, err) || !Arr(z, "px", &px, err) ||
        !Arr(z, "py", &py, err))
        return false;
    const size_t nt = (size_t)tx.shape[0];
    p2npz::Array tz, tzb, tu, tc, val;
    const bool hasZ = z.has("tz"), hasZb = z.has("tzbits");
    if (hasZ && !Arr(z, "tz", &tz, err)) return false;
    if (hasZb && !Arr(z, "tzbits", &tzb, err)) return false;
    if (family == "wmeas") s->kind = K_W;
    else if (family == "cmeas") s->kind = K_C;
    else s->kind = K_UV;
    if (s->kind == K_UV && (!Arr(z, "tu", &tu, err) || !Arr(z, "t", &val, err))) return false;
    if (s->kind == K_W && !Arr(z, "g", &val, err)) return false;
    if (s->kind == K_C && (!Arr(z, "tc", &tc, err) || !Arr(z, "rgb", &val, err))) return false;
    // the triangles, page by page (cases.json's pages of the set: the bands, the page's kind)
    const p2tspcase::Json& pages = js.at("pages");
    std::vector<int> pageOf(nt, 0);
    std::vector<std::vector<int>> cutsOf(nt);
    {
        size_t t = 0;
        const bool opList = js.at("list").t == p2tspcase::Json::Str && js.at("list").s == "op";
        for (size_t pg = 0; pg < pages.size(); pg++)
            for (size_t ci = 0; ci < pages[pg].size() && t < nt; ci++, t++) {
                pageOf[t] = (int)pg;
                const p2tspcase::Json& q = pages[pg][ci];
                // uvspan's opaque list: the bands in front cut the runs (the translucent list: whole)
                if (family == "uvspan" && opList && q.has("bands"))
                    for (size_t b = 0; b < q.at("bands").size(); b++) {
                        // columns a .. b - 1 of the cell (pvr-tests/uvspan/gen.cpp band_t)
                        cutsOf[t].push_back((int)q.at("bands")[b][0].n);
                        cutsOf[t].push_back((int)q.at("bands")[b][1].n);
                    }
                // uvrun (KINDS 6 when run2 was taken): kinds 1, 2 (volumes), 4 (punch-through passes), 5 (per-pixel sort) cut at
                // the bands' columns 8-11 and 18-23 of the cell; kinds 0 and 3 do not
                if (family == "uvrun") {
                    const int kind = (int)pg / 2;
                    if (kind == 1 || kind == 2 || kind == 4 || kind == 5) cutsOf[t] = {8, 12, 18, 24};
                }
            }
    }
    for (size_t t = 0; t < nt; t++) {
        float x[3], y[3];
        uint32_t zb[3];
        for (int k = 0; k < 3; k++) {
            x[k] = (float)tx.f64(3 * t + k);
            y[k] = (float)ty.f64(3 * t + k);
            zb[k] = hasZb ? (uint32_t)tzb.i64(3 * t + k) : hasZ ? FB((float)tz.f64(3 * t + k)) : 0x3f800000u;
        }
        Case c = TriCase(x, y, zb);
        if (s->kind == K_UV) {
            // textured, U = V the set's u; a 1024 x 8 texture, point sampled, no mipmaps (pvr-tests/uvmeas/main.c)
            c.p.isp |= p2tspcase::ISP_TEX;
            c.p.tsp[0] = c.p.tsp[1] = (7u << 3) | 0u;
            c.p.tcw[0] = c.p.tcw[1] = (1u << 27);
            c.p.skip = 3;
            for (int k = 0; k < 3; k++) { c.p.v[k].u = c.p.v[k].v = FB((float)tu.f64(3 * t + k)); c.p.v[k].col = 0xffffffffu; }
        } else if (s->kind == K_C) {
            for (int k = 0; k < 3; k++)
                c.p.v[k].col = 0xff000000u | (uint32_t)tc.i64(9 * t + 3 * k) << 16 | (uint32_t)tc.i64(9 * t + 3 * k + 1) << 8 |
                               (uint32_t)tc.i64(9 * t + 3 * k + 2);
        }
        c.set = family + " " + name;
        c.page = pageOf[t];
        c.cell = (int)t;
        s->tris.push_back(c);
    }
    // the readings
    Grouper g;
    const size_t nr = (size_t)ti.count();
    for (size_t r = 0; r < nr; r++) {
        const int t = (int)ti.i64(r);
        int32_t w;
        if (s->kind == K_C) w = ReadingC((int)val.i64(3 * r), (int)val.i64(3 * r + 1), (int)val.i64(3 * r + 2));
        else w = (int32_t)val.i64(r);
        if (s->kind == K_UV && w < 0) { s->skipped++; continue; }
        const int idx = (int)s->want.size();
        s->want.push_back(w);
        // pages are separate renders: the tile key carries the page
        g.add(t, (int)floor(px.f64(r)) + 32 * 1000 * pageOf[t], (int)floor(py.f64(r)), idx);
    }
    g.runs(s->tris, [&](int tri, int) { return cutsOf[tri]; }, &s->runs);
    return true;
}

}   // namespace p2tspset

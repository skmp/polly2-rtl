// tsp_cases.h: the primitives of M9's TSP setup gate (PLAN M9), shared by the graph check (tools/gen/gen_tsp_prog.cpp
// --check) and the RTL testbench (tb/tsp_setup). L1: refcore's pvr_softfp.h only.
//
//   Prim          a primitive as its parameter block holds it: the ISP/TSP, TSP and TCW words, three vertices as
//                 decode_pvr_vertex reads them (refsw_tile.cpp L417-490), the tag's shadow, skip and tag_offset; Words()
//                 lays the block out (header, tag_offset vertices before it, stride 3 + skip (1 + two volumes))
//   Case          a Prim with the job's volume (vsel), FPU_SHAD_SCALE and FPU_PERP_VAL, and where it came from
//   RandomCase    the random class (PLAN M9 item 6): every input class, flat and Gouraud, two volumes, intensity,
//                 DCalcCtrl 0 / 1, the coordinate and depth classes of tb/isp_setup (grid, huge, denormal, far, the
//                 determinant zero and near 2^126, infinities and NaNs), attributes of every magnitude and specials
//   DirectedA3    PLAN M9 item 4, the dropped-offset class in full: all-zero offsets x {det 0, perpendicular, det
//                 infinite, |det| > 2^126, ordinary} x {1/w terms of every sign, zero, infinite} x {Gouraud, flat} x
//                 {intensity off, on, on with non-zero colours that scale to 0}
//   DirectedNamed PLAN M9 item 3: slivers_detzero / slivers_dzzero (the mean's withZero), perpmean_uv, perpmean_ovf
//                 (perpendicular, sums at 2^128), modvol intensity (0x80 halves, 0xFF one level)
//   ConsoleSets   PLAN M9 item 5 and the cmeas sets: dreamcast-tests fit/cmeas_data (c1, cwext1, cwsum1: Gouraud
//                 colour triangles at extreme depths), the mipk sets (pvr-tests/mipk*/cases.h with
//                 fit/mipk_data/*.observed.txt: the console's K8 per cell) and fit/mipmeas_data (10 sets: the K of every
//                 triangle), each Case with its K observation
//   SetupInOf     the setup's inputs of a Case, for the graph check only (the RTL testbench's reference is
//                 p2ref::fpu_entry, refsw3's own fetch and IPs3::Setup)
#pragma once
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include "p2tb.h"
#include "pvr_softfp.h"

namespace p2tspcase {

// ---------------------------------------------------------------------------------------------------------------
// a small JSON reader: objects, arrays, numbers (Infinity, -Infinity, NaN as Python writes them), strings
struct Json {
    enum T { Null, Num, Str, Arr, Obj } t = Null;
    double n = 0;
    std::string s;
    std::vector<Json> a;
    std::map<std::string, Json> o;
    bool has(const std::string& k) const { return t == Obj && o.count(k); }
    const Json& at(const std::string& k) const { static const Json nil; auto it = o.find(k); return it == o.end() ? nil : it->second; }
    const Json& operator[](size_t i) const { static const Json nil; return i < a.size() ? a[i] : nil; }
    size_t size() const { return t == Arr ? a.size() : 0; }
    static bool Parse(const std::string& x, Json* out)
    {
        size_t i = 0;
        return Val(x, i, out);
    }
    static void Ws(const std::string& x, size_t& i) { while (i < x.size() && strchr(" \t\r\n", x[i])) i++; }
    static bool Val(const std::string& x, size_t& i, Json* v)
    {
        Ws(x, i);
        if (i >= x.size()) return false;
        const char c = x[i];
        if (c == '{') {
            v->t = Obj;
            i++;
            for (;;) {
                Ws(x, i);
                if (i < x.size() && x[i] == '}') { i++; return true; }
                Json k;
                if (!Val(x, i, &k) || k.t != Str) return false;
                Ws(x, i);
                if (i >= x.size() || x[i++] != ':') return false;
                Json e;
                if (!Val(x, i, &e)) return false;
                v->o[k.s] = std::move(e);
                Ws(x, i);
                if (i < x.size() && x[i] == ',') i++;
            }
        }
        if (c == '[') {
            v->t = Arr;
            i++;
            for (;;) {
                Ws(x, i);
                if (i < x.size() && x[i] == ']') { i++; return true; }
                Json e;
                if (!Val(x, i, &e)) return false;
                v->a.push_back(std::move(e));
                Ws(x, i);
                if (i < x.size() && x[i] == ',') i++;
            }
        }
        if (c == '"') {
            v->t = Str;
            i++;
            while (i < x.size() && x[i] != '"') {
                if (x[i] == '\\' && i + 1 < x.size()) i++;
                v->s += x[i++];
            }
            i++;
            return true;
        }
        if (x.compare(i, 8, "Infinity") == 0) { v->t = Num; v->n = INFINITY; i += 8; return true; }
        if (x.compare(i, 9, "-Infinity") == 0) { v->t = Num; v->n = -INFINITY; i += 9; return true; }
        if (x.compare(i, 3, "NaN") == 0) { v->t = Num; v->n = NAN; i += 3; return true; }
        if (x.compare(i, 4, "null") == 0 || x.compare(i, 4, "true") == 0) { v->t = Num; v->n = x[i] == 't'; i += 4; return true; }
        if (x.compare(i, 5, "false") == 0) { v->t = Num; v->n = 0; i += 5; return true; }
        char* e = nullptr;
        v->t = Num;
        v->n = strtod(x.c_str() + i, &e);
        if (e == x.c_str() + i) return false;
        i = (size_t)(e - x.c_str());
        return true;
    }
};
inline bool ReadText(const std::string& path, std::string* out)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    char b[65536];
    size_t n;
    out->clear();
    while ((n = fread(b, 1, sizeof b, f)) > 0) out->append(b, n);
    fclose(f);
    return true;
}

// ---------------------------------------------------------------------------------------------------------------
inline uint32_t FB(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
inline float BF(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

// the planes of a store entry (gen_tsp_prog.cpp's order; p2_tsp_prog_pkg's P2_TSP_PL_*)
enum { P_W = 0, P_U, P_V, P_C0, P_C1, P_C2, P_C3, P_O0, P_O1, P_O2, P_O3, P_N };

// ISP/TSP word bits (core_structs.h ISP_TSP), TSP, TCW
constexpr uint32_t ISP_TEX = 1u << 25, ISP_OFS = 1u << 24, ISP_GOURAUD = 1u << 23, ISP_UV16 = 1u << 22, ISP_DCALC = 1u << 20;
inline int TspMipD(uint32_t t) { return (t >> 8) & 15; }
inline int TspTexU(uint32_t t) { return (t >> 3) & 7; }
inline bool TcwMip(uint32_t t) { return (t >> 31) & 1; }
inline int TcwFmt(uint32_t t) { return (t >> 27) & 7; }

struct Vtx { uint32_t x = 0, y = 0, z = 0, u = 0, v = 0, col = 0, spc = 0, u1 = 0, v1 = 0, col1 = 0, spc1 = 0, uv16 = 0, uv16b = 0; };
struct Prim {
    uint32_t isp = 0, tsp[2] = {}, tcw[2] = {};
    Vtx v[3];                 // in memory order (before the odd triangle's swap)
    int skip = 1, tagOffset = 0;
    bool shadow = false;
    // one vertex's words as decode_pvr_vertex reads them; the vertex's stride is 3 + skip (1 + two volumes) words
    std::vector<uint32_t> VtxWords(const Vtx& q, bool two) const
    {
        std::vector<uint32_t> w = {q.x, q.y, q.z};
        const bool tex = isp & ISP_TEX, ofs = isp & ISP_OFS, uv16 = isp & ISP_UV16;
        if (tex) { if (uv16) w.push_back(q.uv16); else { w.push_back(q.u); w.push_back(q.v); } }
        w.push_back(q.col);
        if (ofs) w.push_back(q.spc);
        if (two) {
            if (tex) { if (uv16) w.push_back(q.uv16b); else { w.push_back(q.u1); w.push_back(q.v1); } }
            w.push_back(q.col1);
            if (ofs) w.push_back(q.spc1);
        }
        return w;
    }
    // a vertex's fields run into the next vertex's words (skip smaller than the fields): what is read is not Vtx
    bool Overlaps(bool two) const { return VtxWords(v[0], two).size() > 3 + (size_t)skip * (two ? 2 : 1); }
    // the parameter block: header, tag_offset vertices (copies of the first) and the three, each at its stride; a
    // vertex whose fields are longer than its stride runs into the next one's words (written later), as in memory
    std::vector<uint32_t> Words(bool two) const
    {
        std::vector<uint32_t> w = {isp, tsp[0], tcw[0]};
        if (two) { w.push_back(tsp[1]); w.push_back(tcw[1]); }
        const size_t stride = 3 + (size_t)skip * (two ? 2 : 1), base = w.size();
        const int nv = tagOffset + 3;
        for (int i = 0; i < nv; i++) {
            const std::vector<uint32_t> f = VtxWords(i < tagOffset ? v[0] : v[i - tagOffset], two);
            if (w.size() < base + stride * i + f.size()) w.resize(base + stride * i + f.size(), 0);
            for (size_t k = 0; k < f.size(); k++) w[base + stride * i + k] = f[k];
        }
        return w;
    }
};

// where a case came from, and what the console says about its K (ConsoleSets)
enum Src { SRC_RANDOM = 0, SRC_A3, SRC_NAMED, SRC_CMEAS, SRC_MIPK, SRC_MIPMEAS };
struct Case {
    Prim p;
    int vsel = 0;
    uint32_t shadScale = 0;   // FPU_SHAD_SCALE
    uint32_t perp = 0;        // FPU_PERP_VAL
    int src = SRC_RANDOM;
    std::string set;          // the console set
    int page = 0, cell = 0;
    // the console's K: kObs 0, -1, +1 (the console's K8 against MIP_K 1's, kBase 1) or the reached mode (kReached 1 / 0
    // whether the console's K8 reaches kStep; 9 unknown); kHave 0: none
    int kHave = 0, kObs = 0, kReached = 9;
    double kStep = 0;
};

// ---------------------------------------------------------------------------------------------------------------
// the setup's inputs of one (tag, vsel) as refsw3 forms them (GetFpuEntry, IPs3::Setup, SetupIntensity): FOR THE GRAPH
// CHECK ONLY, which compares the graph with PlaneT::Setup on the same inputs (the RTL testbench takes refsw3's own
// fpu_entry)
struct SetupIn {
    uint32_t x[3], y[3], z[3];
    uint32_t at[P_N][3];
    bool tex = false;
    int ofs = 0, mip = 0;       // the class (gen_tsp_prog.cpp): offset planes 0 none, 1 computed, 2 dropped; mip 0, 1, 2
    int bias = 4, texU = 3;
    uint32_t perp = 0;
};
inline uint8_t Ch(uint32_t c, int i) { return (uint8_t)(c >> (8 * i)); }
// the class of a job (p2_tsp_setup's choice): from the ISP word, the volume's TCW and the used offset colours
inline void ClassOf(const Prim& p, int vsel, bool intensity, uint8_t scale, bool* tex, int* ofs, int* mip)
{
    const int tv = (vsel && !intensity) ? 1 : 0;
    *tex = p.isp & ISP_TEX;
    *ofs = 0;
    *mip = 0;
    if (!*tex) return;
    const bool two = vsel && !intensity;
    if ((p.isp & ISP_OFS) && TcwFmt(p.tcw[tv]) != 4) {
        // dropped: every offset colour the entry uses is 0 (Gouraud: the three corners; flat: v3; intensity: scaled)
        bool any = false;
        const int i0 = (p.isp & ISP_GOURAUD) ? 0 : 2;
        for (int k = i0; k < 3; k++) {
            const int m = (p.tagOffset & 1) ? (k == 0 ? 1 : k == 1 ? 0 : 2) : k;
            const uint32_t c = two ? p.v[m].spc1 : p.v[m].spc;
            for (int ch = 0; ch < 4; ch++) {
                uint32_t q = Ch(c, ch);
                if (vsel && intensity && ch < 3) q = (q * scale) >> 8;
                any = any || q != 0;
            }
        }
        *ofs = any ? 1 : 2;
    }
    if (TcwMip(p.tcw[tv])) *mip = (p.isp & ISP_DCALC) ? 2 : 1;
}
inline SetupIn SetupInOf(const Case& c)
{
    const Prim& p = c.p;
    const bool intensity = (c.shadScale >> 8) & 1;
    const uint8_t scale = (uint8_t)c.shadScale;
    const bool two = c.vsel && !intensity;
    const int tv = two ? 1 : 0;
    SetupIn s;
    Vtx v[3] = {p.v[0], p.v[1], p.v[2]};
    if (p.tagOffset & 1) std::swap(v[0], v[1]);
    const bool uv16 = p.isp & ISP_UV16;
    for (int k = 0; k < 3; k++) {
        s.x[k] = v[k].x; s.y[k] = v[k].y; s.z[k] = v[k].z;
        uint32_t u = two ? v[k].u1 : v[k].u, vv = two ? v[k].v1 : v[k].v;
        if (uv16) { const uint32_t w = two ? v[k].uv16b : v[k].uv16; u = w & 0xffff0000u; vv = w << 16; }
        s.at[P_U][k] = u;
        s.at[P_V][k] = vv;
    }
    const bool gour = p.isp & ISP_GOURAUD;
    for (int k = 0; k < 3; k++) {
        const int src = gour ? k : 2;
        uint32_t col = two ? v[src].col1 : v[src].col, spc = two ? v[src].spc1 : v[src].spc;
        for (int ch = 0; ch < 4; ch++) {
            uint32_t a = Ch(col, ch), o = Ch(spc, ch);
            if (c.vsel && intensity && ch < 3) { a = (a * scale) >> 8; o = (o * scale) >> 8; }
            s.at[P_C0 + ch][k] = pvrfp::SingleBits(a, -8);
            s.at[P_O0 + ch][k] = pvrfp::SingleBits(o, -8);
        }
    }
    ClassOf(p, c.vsel, intensity, scale, &s.tex, &s.ofs, &s.mip);
    s.bias = TspMipD(p.tsp[tv]);
    s.texU = TspTexU(p.tsp[tv]);
    s.perp = c.perp;
    return s;
}

// ---------------------------------------------------------------------------------------------------------------
// random
inline float RndCoord(p2tb::Rng& r)
{
    switch (r.below(10)) {
    case 0: return (float)r.below(2048) * 0.5f + (float)r.below(16) / 16.0f;
    case 1: return BF(FB((float)r.below(1280)) + (uint32_t)r.range(-12, 12));
    case 2: return ldexpf((float)r.below(0xffffff), (int)r.range(-40, 19)) * (r.below(2) ? -1 : 1);
    case 3: return (float)r.below(640) + ldexpf((float)r.below(1000), -(int)r.below(30));
    case 4: return ldexpf(1.0f + r.below(1000) / 1000.0f, (int)r.below(128)) * (r.below(2) ? -1 : 1);
    case 5: return ldexpf(1.0f + r.below(0x800000) / 8388608.0f, 118 + (int)r.below(10)) * (r.below(2) ? -1 : 1);
    case 6: return BF((uint32_t)r.below(0x800000) | (r.below(2) ? 0x80000000u : 0));
    case 7: return ldexpf(1.0f + (float)r.below(5) / 8.0f, -126) * (r.below(2) ? -1 : 1);
    case 8: return ldexpf(1.0f + r.below(0x800000) / 8388608.0f, 58 + (int)r.below(8)) * (r.below(2) ? -1 : 1);
    default: return (float)((int)r.below(4000) - 2000) / 7.0f;
    }
}
inline uint32_t RndDepth(p2tb::Rng& r)
{
    auto frac = [&](int den) { return (float)r.below((uint64_t)den) / (float)den; };
    auto sgn = [&]() { return r.below(2) ? -1.0f : 1.0f; };
    switch (r.below(12)) {
    case 0: return FB(ldexpf(1.0f + frac(100000), (int)r.below(40) - 20) * (r.below(3) ? 1.0f : -1.0f));
    case 1: return FB(0.5f + r.below(1000) * 1e-6f);
    case 2: return FB(ldexpf((float)r.below(0xffffff), -(int)r.below(60)) * sgn());
    case 3: return FB((float)r.below(1000) / 997.0f - 0.3f);
    case 4: return FB(ldexpf(1.0f + frac(1 << 23), -126 + (int)r.below(4)) * sgn());
    case 5: return FB(ldexpf(1.0f + frac(1 << 23), 100 + (int)r.below(28)) * sgn());
    case 6: return r.below(2) ? 0u : 0x80000000u;
    case 7: return r.u32();
    case 8: return FB(-ldexpf(1.0f + frac(1000), (int)r.below(20)));
    case 9: { const uint32_t s[8] = {0x7f800000u, 0xff800000u, 0x7f7fffffu, 0xff7fffffu, 0x7f000000u, 0xff000000u, 0x7fc00000u, 0xffc00001u};
              return s[r.below(8)]; }
    case 10: return (uint32_t)r.below(0x800000) | (r.below(2) ? 0x80000000u : 0);    // a denormal: field 0
    default: return FB(ldexpf(1.0f + frac(1 << 23), 124 + (int)r.below(4)) * sgn());
    }
}
inline uint32_t RndAttr(p2tb::Rng& r)
{
    switch (r.below(9)) {
    case 0: return FB((float)r.below(1024) / 64.0f);
    case 1: return FB(ldexpf(1.0f + r.below(0x800000) / 8388608.0f, (int)r.range(-30, 30)) * (r.below(2) ? -1 : 1));
    case 2: return 0;
    case 3: return r.below(2) ? 0x80000000u : 0x3f800000u;
    case 4: return r.u32();
    case 5: { const uint32_t s[6] = {0x7f800000u, 0xff800000u, 0x7fc00000u, 0x00000001u, 0x7f7fffffu, 0x00800000u}; return s[r.below(6)]; }
    case 6: return FB(ldexpf(1.0f + r.below(0x800000) / 8388608.0f, (int)r.range(-127, 127)) * (r.below(2) ? -1 : 1));
    default: return FB((float)r.range(-4000, 4000) / 1024.0f);
    }
}
inline uint32_t RndColour(p2tb::Rng& r, int zeroPm)
{
    uint32_t c = 0;
    for (int ch = 0; ch < 4; ch++) {
        const uint32_t k = r.below(1000) < (uint64_t)zeroPm ? 0 : r.below(5) == 0 ? 255 : r.below(5) == 0 ? (uint32_t)r.below(3) : (uint32_t)r.below(256);
        c |= k << (8 * ch);
    }
    return c;
}
// a random primitive and job
inline Case RandomCase(p2tb::Rng& r)
{
    Case c;
    Prim& p = c.p;
    p.isp = (r.u32() & ~(ISP_TEX | ISP_OFS | ISP_GOURAUD | ISP_UV16 | ISP_DCALC)) & 0x0000ffffu;
    if (r.below(5)) p.isp |= ISP_TEX;
    if (r.below(2)) p.isp |= ISP_OFS;
    if (r.below(3)) p.isp |= ISP_GOURAUD;
    if (r.below(4) == 0) p.isp |= ISP_UV16;
    if (r.below(2)) p.isp |= ISP_DCALC;
    p.isp |= (r.u32() & 0xff) << 24 & 0xfc000000u;     // DepthMode, CullMode, ZWriteDis: random, not read by the TSP
    for (int v = 0; v < 2; v++) {
        p.tsp[v] = r.u32();
        p.tcw[v] = r.u32() & ~(0x80000000u | (7u << 27));
        if (r.below(3)) p.tcw[v] |= 0x80000000u;        // mipmapped
        p.tcw[v] |= (uint32_t)(r.below(8) == 0 ? 4 : r.below(8)) << 27;     // a bump map now and then
    }
    p.shadow = r.below(3) == 0;
    p.skip = (int)r.below(8);
    if (r.below(4)) {     // a stride the fields fit in
        const bool tex = p.isp & ISP_TEX;
        const int need = (tex ? ((p.isp & ISP_UV16) ? 1 : 2) : 0) + 1 + ((p.isp & ISP_OFS) ? 1 : 0);
        if (p.skip < need) p.skip = need;
    }
    p.tagOffset = r.below(3) == 0 ? (int)r.below(4) : (int)r.below(2);
    const float cx = 32.0f * (float)r.below(40), cy = 32.0f * (float)r.below(30);
    const int cls = (int)r.below(9);
    for (int k = 0; k < 3; k++) {
        float x, y;
        switch (cls) {
        case 0: x = cx + (float)r.range(-24, 56) + r.below(16) / 16.0f; y = cy + (float)r.range(-24, 56) + r.below(16) / 16.0f; break;
        case 1: x = BF(FB(cx + (float)r.range(-8, 40) + 0.5f) + (uint32_t)r.range(-12, 12));
                y = BF(FB(cy + (float)r.range(-8, 40) + 0.5f) + (uint32_t)r.range(-12, 12)); break;
        case 2: x = cx + (float)r.range(-300, 300) + r.below(256) / 256.0f; y = cy + (float)r.range(-300, 300) + r.below(256) / 256.0f; break;
        case 3: x = (float)r.below(4) * (r.below(2) ? 1 : -1) * ldexpf(1.0f, -126 + (int)r.below(2)); y = (float)r.below(3); break;
        default: x = RndCoord(r); y = RndCoord(r); break;
        }
        p.v[k].x = FB(x);
        p.v[k].y = FB(y);
    }
    if (r.below(12) == 0) { Vtx& q = p.v[r.below(3)]; (r.below(2) ? q.x : q.y) = r.below(2) ? 0x7f800000u | (uint32_t)r.below(4) : 0xff800000u; }
    if (r.below(20) == 0) { p.v[2].x = p.v[0].x; p.v[2].y = p.v[0].y; }         // the determinant zero
    if (r.below(20) == 0) { p.v[1] = p.v[0]; p.v[2] = p.v[0]; }                    // a point
    if (r.below(16) == 0) {                                                       // a determinant near 2^126
        const float L = ldexpf(1.0f + r.below(64) / 64.0f, 62 + (int)r.below(3)), M = ldexpf(1.0f, 63) * (r.below(2) ? 1.0f : 0.999f);
        p.v[1].x = FB(BF(p.v[0].x) + L); p.v[1].y = p.v[0].y; p.v[2].x = p.v[0].x; p.v[2].y = FB(BF(p.v[0].y) + M);
    }
    const int zcls = (int)r.below(4);
    const uint32_t z0 = RndDepth(r);
    const int ucls = (int)r.below(4);
    const int zeroPm = r.below(4) == 0 ? 1000 : r.below(3) == 0 ? 300 : 30;     // offset colours zero (the dropped class)
    for (int k = 0; k < 3; k++) {
        Vtx& q = p.v[k];
        q.z = zcls == 0 ? z0 : zcls == 1 ? FB(BF(z0) * (1.0f + (float)r.below(64) / 256.0f)) : RndDepth(r);
        if (zcls == 1 && (z0 & 0x7f800000u) == 0x7f800000u) q.z = z0;
        auto attr = [&]() { return ucls == 0 ? FB((float)r.below(256) / 16.0f) : ucls == 1 ? FB(ldexpf(1.0f + r.below(4096) / 4096.0f, (int)r.range(-8, 8))) : RndAttr(r); };
        q.u = attr(); q.v = attr(); q.u1 = attr(); q.v1 = attr();
        q.uv16 = r.u32(); q.uv16b = r.u32();
        if (ucls < 2) { q.uv16 = (q.u & 0xffff0000u) | (q.v >> 16); q.uv16b = (q.u1 & 0xffff0000u) | (q.v1 >> 16); }
        q.col = RndColour(r, 30); q.col1 = RndColour(r, 30);
        q.spc = RndColour(r, zeroPm); q.spc1 = RndColour(r, zeroPm);
    }
    if (r.below(4) == 0) { p.v[1].col = p.v[2].col = p.v[0].col; p.v[1].u = p.v[2].u = p.v[0].u; }
    c.shadScale = (r.below(2) ? 0x100u : 0u) | (r.below(3) == 0 ? (r.below(2) ? 0x80u : 0xffu) : (uint32_t)r.below(256));
    const bool intensity = (c.shadScale >> 8) & 1;
    c.vsel = p.shadow && r.below(2) ? 1 : 0;
    if (c.vsel && intensity && r.below(3) == 0)                                   // colours that scale to 0
        for (int k = 0; k < 3; k++) p.v[k].spc = (p.v[k].spc & 0xff000000u) | (uint32_t)(r.below(2) ? 0x010101 : 0);
    c.perp = r.below(10) == 0 ? 0x3c000000u : r.below(30) == 0 ? r.u32() : r.below(40) == 0 ? 0x7f800000u : 0;
    c.src = SRC_RANDOM;
    return c;
}

// ---------------------------------------------------------------------------------------------------------------
// PLAN M9 item 4: the dropped-offset class A3, in full. Textured (bilinear, no mip) offset polygons with every offset
// colour zero; the 1/w plane's per-corner terms of every sign, zero and infinite (through the corners' depths and the
// triangle's orientation); the determinant 0, perpendicular, infinite, above 2^126, ordinary; Gouraud and flat;
// intensity off, on, on with colours that scale to 0
inline void DirectedA3(std::vector<Case>* out)
{
    struct Geo { float x[3], y[3]; uint32_t perp; const char* what; };
    const float t63 = ldexpf(1.0f, 63), t64 = ldexpf(1.0f, 64);
    const Geo geo[] = {
        {{5, 5, 5}, {5, 5, 5}, 0, "det 0 (a point)"},
        {{1, 9, 17}, {1, 9, 17}, 0, "det 0 (a line)"},
        {{0, 64, 0.001f}, {0, 0.001f, 64}, 0x4a800000u, "perpendicular (FPU_PERP_VAL 2^22)"},
        {{0, 8, 0}, {0, 0, 8}, 0x7f800000u, "perpendicular (FPU_PERP_VAL infinite)"},
        {{0, t64, 0}, {0, 0, t64}, 0, "det infinite"},
        {{0, t63, 0}, {0, 0, t63 * 2}, 0, "|det| 2^127"},
        {{0, t63, 0}, {0, 0, t63}, 0, "|det| exactly 2^126"},
        {{0, 8, 0}, {0, 0, 8}, 0, "ordinary"},
        {{0, 0, 8}, {0, 8, 0}, 0, "ordinary, the other winding"},
        {{3.5f, 40.25f, 7}, {2, 9.5f, 30}, 0, "ordinary, sloped"},
    };
    // depths: every sign, zero (field 0 with and without a fraction), infinite, NaN, tiny, huge
    const uint32_t zs[][3] = {
        {0x3f800000u, 0x3f800000u, 0x3f800000u}, {0xbf800000u, 0xbf800000u, 0xbf800000u}, {0x3f800000u, 0xbf800000u, 0x40000000u},
        {0, 0, 0}, {0x80000000u, 0x80000000u, 0x80000000u}, {0, 0x3f800000u, 0x80000000u}, {0x00000005u, 0x80700000u, 0x3f800000u},
        {0x7f800000u, 0x3f800000u, 0x3f800000u}, {0xff800000u, 0x7f800000u, 0xbf800000u}, {0x7fc00000u, 0x3f800000u, 0x3f800000u},
        {0x00800000u, 0x80800001u, 0x00c00000u}, {0x7f7fffffu, 0x7f7fffffu, 0xff7fffffu}, {0x3f800000u, 0x7f800000u, 0xff800000u},
        {0x80800000u, 0x00800000u, 0x00800000u},
    };
    const uint32_t intens[] = {0x000u, 0x180u, 0x1ffu, 0x101u};
    for (const Geo& g : geo)
        for (const auto& z : zs)
            for (int gouraud = 0; gouraud < 2; gouraud++)
                for (uint32_t sh : intens)
                    for (int cs = 0; cs < (sh & 0x100 ? 2 : 1); cs++) {
                        Case c;
                        Prim& p = c.p;
                        p.isp = ISP_TEX | ISP_OFS | (gouraud ? ISP_GOURAUD : 0);
                        p.tsp[0] = p.tsp[1] = (4u << 8) | (3u << 3) | 3u | (1u << 13);
                        p.tcw[0] = p.tcw[1] = 1u << 27;
                        p.skip = 4;
                        p.shadow = (sh & 0x100) != 0;
                        for (int k = 0; k < 3; k++) {
                            Vtx& q = p.v[k];
                            q.x = FB(g.x[k]); q.y = FB(g.y[k]); q.z = z[k];
                            q.u = FB(0.25f * (float)k); q.v = FB(0.5f + 0.125f * (float)k);
                            q.col = 0x80ff4020u + (uint32_t)k;
                            // offsets zero; cs: non-zero colours that scale to 0 (the intensity entry's are then 0)
                            q.spc = cs ? ((sh & 0xff) == 1 ? 0x00ff7f3fu : 0x00010101u) & 0x00ffffffu : 0;
                            q.u1 = q.u; q.v1 = q.v; q.col1 = q.col; q.spc1 = 0;
                        }
                        c.shadScale = sh;
                        c.vsel = p.shadow ? 1 : 0;
                        c.perp = g.perp;
                        c.src = SRC_A3;
                        c.set = g.what;
                        out->push_back(c);
                        if (p.shadow && !cs) {           // the same outside the volume
                            Case d = c;
                            d.vsel = 0;
                            out->push_back(d);
                        }
                    }
}

// PLAN M9 item 3: the directed console facts' primitives (their pages are dreamcast-tests'; the triangles below are of
// their classes, the readings themselves are M10's)
inline void DirectedNamed(std::vector<Case>* out)
{
    auto tri = [&](const char* name, const float x[3], const float y[3], const uint32_t z[3], uint32_t isp, uint32_t perp,
                   uint32_t col[3], uint32_t shad, int vsel) {
        Case c;
        Prim& p = c.p;
        p.isp = isp;
        p.tsp[0] = p.tsp[1] = (4u << 8) | (3u << 3) | 3u;
        p.tcw[0] = p.tcw[1] = 1u << 27;
        p.skip = 4;
        p.shadow = vsel != 0 || (shad & 0x100);
        for (int k = 0; k < 3; k++) {
            p.v[k].x = FB(x[k]); p.v[k].y = FB(y[k]); p.v[k].z = z[k];
            p.v[k].u = FB(64.0f + 16.0f * (float)k); p.v[k].v = FB(1.0f);
            p.v[k].col = col[k]; p.v[k].spc = col[(k + 1) % 3]; p.v[k].col1 = col[k]; p.v[k].spc1 = col[k];
        }
        c.shadScale = shad;
        c.vsel = vsel;
        c.perp = perp;
        c.src = SRC_NAMED;
        c.set = name;
        out->push_back(c);
    };
    const float lx[3] = {1, 9, 17}, ly[3] = {1, 9, 17}, px[3] = {0, 64, 0.001f}, py[3] = {0, 0.001f, 64};
    const float qx[3] = {0, 32, 0}, qy[3] = {0, 0, 32};
    uint32_t col[3] = {0xff4080c0u, 0xff102030u, 0xffff0001u};
    const uint32_t G = ISP_GOURAUD, T = ISP_TEX;
    p2tb::Rng r(77);
    for (int i = 0; i < 400; i++) {
        // slivers_detzero: three depths where ways of taking the mean differ; slivers_dzzero: a corner of field 0
        // against one of 2^-126 .. 2^-125 of the other sign (withZero), on the boundary and off it
        uint32_t z[3] = {FB(ldexpf(1.0f + (float)r.below(1 << 20) / 1048576.0f, (int)r.range(-20, 20))),
                         FB(ldexpf(1.0f + (float)r.below(1 << 20) / 1048576.0f, (int)r.range(-20, 20))),
                         FB(ldexpf(1.0f + (float)r.below(1 << 20) / 1048576.0f, (int)r.range(-20, 20)))};
        tri("slivers_detzero", lx, ly, z, G | T, 0, col, 0, 0);
        const uint32_t m = (uint32_t)r.below(0x800000);
        uint32_t zz[3] = {(r.below(2) ? 0x80000000u : 0) | (uint32_t)r.below(0x800000), (r.below(2) ? 0x80000000u : 0) | 0x00800000u | m,
                          FB(ldexpf(1.0f, -(int)r.below(130)))};
        if (r.below(2)) std::swap(zz[0], zz[1]);
        tri("slivers_dzzero", lx, ly, zz, G | T, 0, col, 0, 0);
        // perpmean_uv: perpendicular triangles, 1/w of 2^-20 .. 2^20 or one 12 .. 30 binades below the others, U 64 .. 128
        const int e = (int)r.range(-20, 20);
        uint32_t zp[3] = {FB(ldexpf(1.0f + (float)r.below(256) / 256.0f, e)), FB(ldexpf(1.0f + (float)r.below(256) / 256.0f, e)),
                          FB(ldexpf(1.0f, e - (int)(r.below(2) ? r.range(12, 30) : 0)))};
        tri("perpmean_uv", px, py, zp, G | T, 0x7f800000u, col, 0, 0);
    }
    // perpmean_ovf: FPU_PERP_VAL infinite, 1/w sums at 2^128 and just under it, ten colour sets
    const uint32_t zo[][3] = {{0x7f000000u, 0x7f000000u, 0x7f000000u}, {0x7f7fffffu, 0x7f7fffffu, 0x7f7fffffu},
                              {0x7effffffu, 0x7f000000u, 0x7f000000u}, {0x7f000000u, 0x7f000000u, 0x3f800000u}};
    for (const auto& z : zo)
        for (int cs = 0; cs < 10; cs++) {
            uint32_t cc[3] = {0xff000000u * (cs & 1) + 0x010101u * (uint32_t)(cs * 25), 0xff000000u + 0x102030u * (uint32_t)cs, 0u};
            tri("perpmean_ovf", qx, qy, z, (cs & 2 ? G : 0) | (cs & 4 ? T : 0), 0x7f800000u, cc, 0, 0);
        }
    // modvol intensity: 0x80 halves exactly, 0xFF darkens by one level; Gouraud and flat
    for (uint32_t s : {0x180u, 0x1ffu, 0x100u, 0x101u})
        for (uint32_t isp : {G, 0u, G | T, T | ISP_OFS | G}) {
            uint32_t cc[3] = {0xff4080c0u, 0xff3f7fbfu, 0x80ffffffu};
            uint32_t z[3] = {0x3f800000u, 0x3f000000u, 0x3e800000u};
            tri("modvol", qx, qy, z, isp, 0, cc, s, 1);
            tri("modvol", qx, qy, z, isp, 0, cc, s, 0);
        }
}

// ---------------------------------------------------------------------------------------------------------------
// the console sets
// a pvr-tests/mipk*/cases.h quad_t: page, bias, mode, dcalc, tri[3][2], cell, z[4], uv[4][2]
struct MipkCell { int page, bias, mode, dcalc, tri[3][2], cell; uint32_t z[4], uv[4][2]; };
inline bool ReadMipkCases(const std::string& path, std::vector<MipkCell>* out)
{
    std::string t;
    if (!ReadText(path, &t)) return false;
    size_t i = t.find("quads[NUM_QUADS] = {");
    if (i == std::string::npos) return false;
    i += 20;
    for (;;) {
        const size_t a = t.find("\n    {", i);
        if (a == std::string::npos) break;
        const size_t b = t.find('\n', a + 1);
        const std::string line = t.substr(a + 1, b - a - 1);
        i = b;
        std::vector<uint64_t> v;
        for (size_t k = 0; k < line.size();) {
            if (isdigit((unsigned char)line[k])) {
                char* e = nullptr;
                v.push_back(strtoull(line.c_str() + k, &e, 0));
                k = (size_t)(e - line.c_str());
            } else k++;
        }
        if (v.size() != 23) continue;
        MipkCell c;
        c.page = (int)v[0]; c.bias = (int)v[1]; c.mode = (int)v[2]; c.dcalc = (int)v[3];
        for (int k = 0; k < 3; k++) { c.tri[k][0] = (int)v[4 + 2 * k]; c.tri[k][1] = (int)v[5 + 2 * k]; }
        c.cell = (int)v[10];
        for (int k = 0; k < 4; k++) c.z[k] = (uint32_t)v[11 + k];
        for (int k = 0; k < 4; k++) { c.uv[k][0] = (uint32_t)v[15 + 2 * k]; c.uv[k][1] = (uint32_t)v[16 + 2 * k]; }
        out->push_back(c);
    }
    return !out->empty();
}
// a mipmapped textured triangle as kfit makes it (pvr-tests/mipk/kfit.cpp: the cell's corner plus the corners in pixels, the
// texture 64 x 64: size 6, TexU 3)
inline Case MipCase(const float x[3], const float y[3], const float z[3], const float u[3], const float v[3], int dcalc, int bias,
                    int mode)
{
    Case c;
    Prim& p = c.p;
    p.isp = ISP_TEX | ISP_GOURAUD | (dcalc ? ISP_DCALC : 0);
    p.tsp[0] = p.tsp[1] = ((uint32_t)(mode & 3) << 13) | ((uint32_t)(bias & 15) << 8) | (3u << 3) | 3u;
    p.tcw[0] = p.tcw[1] = 0x80000000u | (1u << 27);
    p.skip = 3;
    for (int k = 0; k < 3; k++) {
        p.v[k].x = FB(x[k]); p.v[k].y = FB(y[k]); p.v[k].z = FB(z[k]);
        p.v[k].u = FB(u[k]); p.v[k].v = FB(v[k]);
        p.v[k].col = 0xffffffffu;
    }
    return c;
}
// cases: every console set; err: what is missing
inline bool ConsoleSets(const std::string& dcts, std::vector<Case>* out, std::vector<std::string>* names, std::string* err)
{
    // cmeas: Gouraud colour triangles, the depth's bits (1.0 when not given)
    for (const char* s : {"c1", "cwext1", "cwsum1"}) {
        std::string t;
        Json j;
        const std::string path = dcts + "/fit/cmeas_data/" + s + ".cases.json";
        if (!ReadText(path, &t) || !Json::Parse(t, &j)) { *err = "cannot read " + path; return false; }
        const Json& pages = j.at("pages");
        long n = 0;
        for (size_t pg = 0; pg < pages.size(); pg++)
            for (size_t ci = 0; ci < pages[pg].size(); ci++) {
                const Json& q = pages[pg][ci];
                Case c;
                c.p.isp = ISP_GOURAUD;
                c.p.skip = 1;
                for (int k = 0; k < 3; k++) {
                    c.p.v[k].x = FB((float)q.at("x")[k].n);
                    c.p.v[k].y = FB((float)q.at("y")[k].n);
                    c.p.v[k].z = q.has("zbits") ? (uint32_t)q.at("zbits")[k].n : 0x3f800000u;
                    const Json& cl = q.at("col")[k];
                    c.p.v[k].col = 0xff000000u | ((uint32_t)cl[0].n << 16) | ((uint32_t)cl[1].n << 8) | (uint32_t)cl[2].n;
                }
                c.src = SRC_CMEAS;
                c.set = std::string("cmeas ") + s;
                c.page = (int)pg;
                c.cell = (int)ci;
                out->push_back(c);
                n++;
            }
        if (names) names->push_back(std::string("cmeas ") + s + ": " + std::to_string(n) + " triangles");
    }
    // mipk: the cells of pvr-tests/mipk*/cases.h, with fit/mipk_data's observations
    struct MipkSet { const char* name; const char* cases; const char* obs; bool reached; };
    const MipkSet ms[] = {{"mipk", "mipk", "seed1", false}, {"mipk2", "mipk2", "mipk2-seed2", false},
                          {"mipk3", "mipk3", "mipk3-seed3", false}, {"mipk5", "mipk5", "mipk5-seed5", true}};
    for (const MipkSet& m : ms) {
        std::vector<MipkCell> cells;
        const std::string ch = dcts + "/pvr-tests/" + m.cases + "/cases.h";
        if (!ReadMipkCases(ch, &cells)) { *err = "cannot read " + ch; return false; }
        std::map<std::pair<int, int>, int> obs;
        {
            std::string t;
            const std::string path = dcts + "/fit/mipk_data/" + m.obs + ".observed.txt";
            if (!ReadText(path, &t)) { *err = "cannot read " + path; return false; }
            int p, cl;
            char o[8];
            const char* s = t.c_str();
            int used = 0;
            while (sscanf(s, "%d %d %7s%n", &p, &cl, o, &used) == 3) {
                s += used;
                obs[{p, cl}] = !strcmp(o, "0") ? 0 : !strcmp(o, "-1") ? -1 : !strcmp(o, "+1") ? 1 : !strcmp(o, "1") ? 1 : 9;
            }
        }
        std::map<std::pair<int, int>, double> step;
        if (m.reached) {
            std::string t;
            const std::string path = dcts + "/pvr-tests/" + m.cases + "/cases.txt";
            if (!ReadText(path, &t)) { *err = "cannot read " + path; return false; }
            size_t i = 0;
            while (i < t.size()) {
                size_t e = t.find('\n', i);
                if (e == std::string::npos) e = t.size();
                const std::string line = t.substr(i, e - i);
                i = e + 1;
                if (line.empty() || line[0] == '#') continue;
                int pg = 0, c = 0;
                sscanf(line.c_str(), "%d %d", &pg, &c);
                const size_t last = line.find_last_of(' ');
                step[{pg, c}] = atof(line.c_str() + last + 1);
            }
        }
        long n = 0, nobs = 0;
        for (const MipkCell& q : cells) {
            const float cx = (float)(q.cell % 20) * 32.0f, cy = (float)(q.cell / 20) * 32.0f;
            float x[3], y[3], z[3], u[3], v[3];
            for (int k = 0; k < 3; k++) {
                x[k] = cx + (float)q.tri[k][0]; y[k] = cy + (float)q.tri[k][1];
                z[k] = BF(q.z[k]); u[k] = BF(q.uv[k][0]); v[k] = BF(q.uv[k][1]);
            }
            Case c = MipCase(x, y, z, u, v, q.dcalc, q.bias, q.mode);
            c.src = SRC_MIPK;
            c.set = m.name;
            c.page = q.page;
            c.cell = q.cell;
            const auto it = obs.find({q.page, q.cell});
            if (it != obs.end() && it->second != 9) {
                if (m.reached) { c.kHave = 2; c.kReached = it->second; c.kStep = step[{q.page, q.cell}]; }
                else { c.kHave = 1; c.kObs = it->second; }
                nobs++;
            }
            out->push_back(c);
            n++;
        }
        if (names) names->push_back(std::string(m.name) + ": " + std::to_string(n) + " cells, " + std::to_string(nobs) + " observed");
    }
    // mipmeas: every set of fit/mipmeas_data, the triangles kfit makes of its cells
    const char* mm[] = {"d0dcalc", "d0first", "dcalc5", "det3", "det4", "first1", "mpos1", "mwext1", "mwextd1", "w2"};
    for (const char* s : mm) {
        std::string t;
        Json j;
        const std::string path = dcts + "/fit/mipmeas_data/" + s + ".cases.json";
        if (!ReadText(path, &t) || !Json::Parse(t, &j)) { *err = "cannot read " + path; return false; }
        const Json& pages = j.at("pages");
        long n = 0;
        for (size_t pg = 0; pg < pages.size(); pg++)
            for (size_t ci = 0; ci < pages[pg].size(); ci++) {
                const Json& q = pages[pg][ci];
                const float cx = (float)(ci % 20) * 32.0f, cy = (float)(ci / 20) * 32.0f;
                float z4[4], u4[4], v4[4];
                for (int k = 0; k < 4; k++) {
                    z4[k] = q.at("z").t == Json::Arr ? (float)q.at("z")[k].n : (float)q.at("z").n;
                    u4[k] = (float)q.at("uv")[k][0].n;
                    v4[k] = (float)q.at("uv")[k][1].n;
                }
                const int dc = q.has("dcalc") ? (int)q.at("dcalc").n : 0, bias = (int)q.at("bias").n, mode = (int)q.at("mode").n;
                auto push = [&](const float x[3], const float y[3], const float z[3], const float u[3], const float v[3]) {
                    Case c = MipCase(x, y, z, u, v, dc, bias, mode);
                    c.src = SRC_MIPMEAS;
                    c.set = std::string("mipmeas ") + s;
                    c.page = (int)pg;
                    c.cell = (int)ci;
                    out->push_back(c);
                    n++;
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
                        float x[3], y[3], z[3], u[3], v[3];
                        for (int k = 0; k < 3; k++) {
                            const int i = tr[t2][k];
                            x[k] = X[i]; y[k] = Y[i]; z[k] = z4[i]; u[k] = u4[i]; v[k] = v4[i];
                        }
                        push(x, y, z, u, v);
                    }
                }
            }
        if (names) names->push_back(std::string("mipmeas ") + s + ": " + std::to_string(n) + " triangles");
    }
    return true;
}

// the 8-bit K as one integer (pvr-tests/mipk/kfit.cpp K8Of): its steps are those of the observations
inline int K8Index(const pvrfp::Fp& k8)
{
    if (k8.mant == 0) return -100000;
    const int b = pvrfp::Fp::Bits(k8.mant);
    return (k8.exp + b) * 128 + ((int)(k8.mant << (8 - b)) - 128);
}

}   // namespace p2tspcase

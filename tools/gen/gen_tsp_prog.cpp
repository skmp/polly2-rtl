// gen_tsp_prog.cpp: the TSP setup's microprograms (PLAN M9; ARCHITECTURE 3.7.3 "Programs, generated as in 3.4.4"). C++ on
// the refcore headers (conventions.md 5: hardware arithmetic is never written in Python).
//
// What it holds, per setup class (below), is the OPERATION GRAPH of refsw3's plane setup at 4f3efe15 for one (tag, vsel)
// store entry: nodes are pvr_softfp operations in the flavours p2_tsp_alu has, edges are data dependencies:
//   the 1/w plane (pvr_tsp_plane.h PlaneT::Setup with attr = null): the edges e_k, the terms ta_k, tb_k, tc_k, the sums
//     Sa, Sb, Sc = (tc0 + tc2) + tc1, Sdet; the reciprocal inv; A0, B0, C0; the determinant-zero mean (withZero in the
//     first addition, OneThird);
//   every attribute plane of the class (U, V, the colours B, G, R, A and the offset colours): the 1/w plane's terms times
//     the corner's attribute, a_k (w_k d) (uvmeas wflat), the sums (Sc = (t0 + t1) + t2), A0, B0, C0, and the flat C =
//     attr_3 x mean;
//   MipSelect's K part (tb/tsp_setup/ref_copies_tsp.h, copies tsp-mip-num, tsp-mip-k) when the class is mipmapped: the
//     numerators of the undivided sums (kind, the 24-bit products, their difference), the quotient check against 1/det^2,
//     the two lengths (0x95F612), the longer, once times 1/det^2; with DCalcCtrl 1 the sums at the first vertex (radd).
// The graph's OUTPUTS are the store writes (p2_tsp_store's words): W_PL writes a plane's A, B, C (cut to 16 bits; the
// flat branch's +0, +0, C when the determinant is zero or perpendicular), W_DR a dropped offset plane (no multiply: the
// signs of ARCHITECTURE 3.7.3's table), W_K the 8-bit K (the size, the bias, the infinite / zero / determinant-zero
// cases). Their fixed logic is in p2_tsp_setup; the evaluation below has the same logic, so the graph check proves the
// graph AND the write logic against refsw3's own PlaneT::Setup and the K copies.
//
// Setup classes (p2_tsp_setup chooses one per job from the fetched words, ARCHITECTURE 3.7.3):
//   untex                      the 1/w plane and the four colour planes (an untextured polygon reads no other plane:
//                              refsw_tile.cpp PixelFlush_tsp)
//   tex[_o|_d][_m0|_m1]        textured: also U and V; _o the four offset planes (Texture && Offset && not a bump map:
//                              the only case PixelFlush_tsp interpolates them), _d the same planes DROPPED (every offset
//                              colour the entry uses is 0: written without a multiply); _m0 / _m1 mipmapped, DCalcCtrl 0 / 1:
//                              K. A bump map (and Offset without Texture) has no offset planes: its light is the fallback.
//
// Modes:
//   gen_tsp_prog [params] --sv <file> --hdr <file> [--report <file>]
//        schedules every class's graph and writes rtl/v1/pkg/p2_tsp_prog_pkg.sv (GENERATED), the testbench's copy of the
//        schedule (a C++ header: the program consistency check) and a readable report
//   gen_tsp_prog [params] --sweep
//        the program lengths over the free parameters (TSP_NM, TSP_NA, L_MUL, L_ADD, L_RCP), against the measured 39
//        (untextured), 48 (textured), 64 (offset), 49 (bump), +5 (DCalcCtrl 1) [M tim 3.7]: a check, not an input
//   gen_tsp_prog --check [--n N] [--seed S] [--threads T] [--dcts <dreamcast-tests>]
//        THE GRAPH CHECK (PLAN M9 item 1): every class's graph evaluated with pvr_softfp, its store words against
//        PlaneT<PlaneHW>::Setup (pvr_tsp_plane.h) and the K copies, on N random primitives (1M) and the directed ones
//        (the dropped-offset class A3 in full, the cmeas sets' triangles, the mipk and mipmeas sets' cells). Ends
//        "graph-check: PASS" / "FAIL".
// params: --nm N --na N --lm N --la N --lr N (defaults: ARCHITECTURE 6's TSP_NM 4, TSP_NA 4; the latencies M4's).
//
// The scheduler is M4's (gen_setup_prog.cpp): list scheduling by the longest latency-weighted path to the program's end, at
// most TSP_NM multiplies, TSP_NA additions, one reciprocal and one store write a step, a node when its operands are
// readable. Every value has its own register (single assignment, as M4: a step held by run start's use of the ALU
// cannot let a later write overtake a read). The program's length is its last store write's step + 1.
#include <algorithm>
#include <cinttypes>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

#include "p2tb.h"
#include "pvr_tsp_plane.h"
#include "ref_copies_tsp.h"
#include "tsp_cases.h"

using pvrfp::Fp;

namespace {

// ---------------------------------------------------------------------------------------------------------------
// the classes
struct ClsDef { const char* name; bool tex; int ofs; int mip; };   // ofs 0 none, 1 computed, 2 dropped; mip 0, 1 (DCalc 0), 2 (DCalc 1)
static const ClsDef kCls[] = {
    {"UNTEX", false, 0, 0},
    {"TEX", true, 0, 0},     {"TEX_M0", true, 0, 1},   {"TEX_M1", true, 0, 2},
    {"TEX_O", true, 1, 0},   {"TEX_O_M0", true, 1, 1}, {"TEX_O_M1", true, 1, 2},
    {"TEX_D", true, 2, 0},   {"TEX_D_M0", true, 2, 1}, {"TEX_D_M1", true, 2, 2},
};
constexpr int C_N = (int)(sizeof kCls / sizeof kCls[0]);
static int ClsOf(bool tex, int ofs, int mip)
{
    for (int c = 0; c < C_N; c++)
        if (kCls[c].tex == tex && kCls[c].ofs == (tex ? ofs : 0) && kCls[c].mip == (tex ? mip : 0))
            return c;
    return -1;
}

// the planes of a store entry, in store order (p2_tsp_store's plane index)
enum Plane { P_W = 0, P_U, P_V, P_C0, P_C1, P_C2, P_C3, P_O0, P_O1, P_O2, P_O3, P_N };
static const char* const kPlaneName[P_N] = {"W", "U", "V", "CB", "CG", "CR", "CA", "OB", "OG", "OR", "OA"};

enum Kind { K_IN, K_MUL, K_ADD, K_RCP, K_W };
// operations, as p2_tsp_alu's units have them (the codes are the package's)
enum Op {
    O_IN,
    MUL_T,     // the TSP setup's ranged `mul` (PlaneT::Setup L178-190; MipSelect's rmul is the same rule)
    MUL_K,     // MipSelect's `kind` with its product: Mul 24; INF -> bad, ZERO -> a zero; the sign the operands' xor
    MUL_Q,     // the numerator's check against 1/det^2: Mul(n, inv2) below -> +0, above -> inf; inv2 "not undivided" -> +0
    MUL_I2,    // inv2 = Mul(inv, inv, 24), below -> +0; inv = 0 (no undivided path): the marker {bad}
    MUL_B,     // best times 1/det^2 (when undivided, best a number): above -> inf, below -> +0
    MUL_P,     // plain Mul 24 (the length's shorter times 0x95F612)
    ADD_T,     // the TSP setup's addTerm (P2_RNG_ADD_TSP: the zero rule in every addition, every zero sum +0)
    ADD_W,     // the mean's first addition: withZero against a corner of exponent field 0, else addTerm
    ADD_R,     // MipSelect's radd (reach 53, no zero rule)
    ADD_N,     // the numerator: Sub(q1, q2).cut(24) as a magnitude (mip_minor), the infinite products' rule
    ADD_LX,    // the length's longer (AtMost), or {bad} when either is
    ADD_LN,    // the length's shorter, or {bad}
    ADD_BS,    // the longer of the two lengths (lx.bad || AtMost(ly, lx) ? lx : ly)
    ADD_P,     // plain Add 24 / 25 (the length's sum and difference)
    RCP_T,     // the plane's reciprocal (P2_FP rng_recip, TSP)
    RCP_M,     // MipSelect's (rng_recip, mip)
    W_PL,      // store write: a plane
    W_DR,      // store write: a dropped offset plane
    W_K        // store write: K
};
static Kind KindOf(Op o)
{
    switch (o) {
    case O_IN: return K_IN;
    case MUL_T: case MUL_K: case MUL_Q: case MUL_I2: case MUL_B: case MUL_P: return K_MUL;
    case RCP_T: case RCP_M: return K_RCP;
    case W_PL: case W_DR: case W_K: return K_W;
    default: return K_ADD;
    }
}
static int OpNum(Op o)
{
    switch (o) {
    case MUL_T: return 0; case MUL_K: return 1; case MUL_Q: return 2; case MUL_I2: return 3; case MUL_B: return 4; case MUL_P: return 5;
    case ADD_T: return 0; case ADD_W: return 1; case ADD_R: return 2; case ADD_N: return 3; case ADD_LX: return 4;
    case ADD_LN: return 5; case ADD_BS: return 6; case ADD_P: return 7;
    case RCP_T: return 0; case RCP_M: return 1;
    case W_PL: return 0; case W_DR: return 1; case W_K: return 2;
    default: return 0;
    }
}
static const char* OpName(Op o)
{
    static const char* const n[] = {"IN", "MUL_T", "MUL_K", "MUL_Q", "MUL_I2", "MUL_B", "MUL_P", "ADD_T", "ADD_W", "ADD_R",
                                    "ADD_N", "ADD_LX", "ADD_LN", "ADD_BS", "ADD_P", "RCP_T", "RCP_M", "W_PL", "W_DR", "W_K"};
    return n[o];
}

struct Node {
    std::string name;
    Op op = O_IN;
    int src[4] = {-1, -1, -1, -1};    // operands (W_PL: A0, B0, C0, the flat C; W_K: best)
    bool sub = false;                 // an addition's b negated
    int plane = -1;                   // a store write's plane
    std::vector<int> deps;            // read by the write's fixed logic (the determinant, the mean)
};

struct Graph {
    int cls = 0;
    std::vector<Node> n;
    std::map<std::string, int> idx;
    std::vector<int> outputs;

    int find(const std::string& s) const
    {
        auto it = idx.find(s);
        return it == idx.end() ? -1 : it->second;
    }
    int put(const Node& v)
    {
        const int h = find(v.name);
        if (h >= 0) {
            const Node& o = n[h];
            if (o.op != v.op || memcmp(o.src, v.src, sizeof o.src) || o.sub != v.sub) {
                fprintf(stderr, "gen_tsp_prog: two different values named %s\n", v.name.c_str());
                exit(2);
            }
            return h;
        }
        n.push_back(v);
        idx[v.name] = (int)n.size() - 1;
        return (int)n.size() - 1;
    }
    int in(const std::string& s) { Node v; v.name = s; return put(v); }
    int op2(const std::string& s, Op op, int a, int b, bool sub = false)
    {
        Node v;
        v.name = s; v.op = op; v.src[0] = a; v.src[1] = b; v.sub = sub;
        return put(v);
    }
    int op1(const std::string& s, Op op, int a) { Node v; v.name = s; v.op = op; v.src[0] = a; return put(v); }
    int w(const std::string& s, Op op, int plane, std::vector<int> srcs, std::vector<int> deps)
    {
        Node v;
        v.name = s; v.op = op; v.plane = plane;
        for (size_t k = 0; k < srcs.size() && k < 4; k++) v.src[k] = srcs[k];
        v.deps = deps;
        const int h = put(v);
        outputs.push_back(h);
        return h;
    }
};

static std::string S(const char* p, int k) { return std::string(p) + std::to_string(k); }

// The operation graph of one class (refsw3 4f3efe15). Inputs, as p2_tsp_setup loads them at a job's start: X0..2,
// Y0..2, Z0..2 the corners FromSingle(., 1) (after the odd strip triangle's swap: GetFpuEntry L533-534), AT_<plane>0..2
// the attribute at each corner FromSingle(., 1) (u, v as the TA wrote them, UV_16b expanded; a colour SingleBits(c, -8);
// flat shading v3's at all three; the intensity entry's colours scaled), THIRD OneThird(), K2 0x95F612 2^-24.
Graph Build(int cls)
{
    const ClsDef& D = kCls[cls];
    Graph g;
    g.cls = cls;
    int X[3], Y[3], Z[3];
    for (int k = 0; k < 3; k++) { X[k] = g.in(S("X", k)); Y[k] = g.in(S("Y", k)); Z[k] = g.in(S("Z", k)); }
    const int THIRD = g.in("THIRD");
    // ---- the 1/w plane (PlaneT::Setup L236-256)
    auto pxy = [&](int j, int k) { return g.op2("pxy" + std::to_string(j) + std::to_string(k), MUL_T, X[j], Y[k]); };
    int e[3], wa[3], wb[3], wc[3];
    for (int k = 0; k < 3; k++) {
        const int j = (k + 1) % 3, l = (k + 2) % 3;
        // edge(j, l) = sub(mul(X[j], Y[l]), mul(X[l], Y[j])) (L236-237: e0 = edge(1, 2), e1 = edge(2, 0), e2 = edge(0, 1))
        e[k] = g.op2(S("e", k), ADD_T, pxy(j, l), pxy(l, j), true);
    }
    for (int k = 0; k < 3; k++) {
        const int j = (k + 1) % 3, l = (k + 2) % 3;
        const int dy = g.op2(S("dy", k), ADD_T, Y[j], Y[l], true);      // sub(Y[j], Y[l])
        const int dx = g.op2(S("dx", k), ADD_T, X[l], X[j], true);      // sub(X[l], X[j])
        wa[k] = g.op2(S("wa", k), MUL_T, Z[k], dy);
        wb[k] = g.op2(S("wb", k), MUL_T, Z[k], dx);
        wc[k] = g.op2(S("wc", k), MUL_T, Z[k], e[k]);
    }
    // sum3: (t0 + t1) + t2 (sumW 0); the 1/w constant (t0 + t2) + t1 (L252-254)
    const int SaW = g.op2("SaW", ADD_T, g.op2("SaW01", ADD_T, wa[0], wa[1]), wa[2]);
    const int SbW = g.op2("SbW", ADD_T, g.op2("SbW01", ADD_T, wb[0], wb[1]), wb[2]);
    const int ScW = g.op2("ScW", ADD_T, g.op2("ScW02", ADD_T, wc[0], wc[2]), wc[1]);
    const int SDET = g.op2("Sdet", ADD_T, g.op2("Sdet01", ADD_T, e[0], e[1]), e[2]);
    const int INV = g.op1("inv", RCP_T, SDET);                          // L335-337
    // the determinant-zero mean (L300-319): first = withZero / addTerm, (first + Z2) the last addition, times OneThird
    const int MEAN = g.op2("mean", MUL_T, g.op2("msum", ADD_T, g.op2("m01", ADD_W, Z[0], Z[1]), Z[2]), THIRD);
    auto plane = [&](int p, const std::string& nm, int Sa, int Sb, int Sc, int Cf) {
        const int A0 = g.op2("A0" + nm, MUL_T, Sa, INV), B0 = g.op2("B0" + nm, MUL_T, Sb, INV), C0 = g.op2("C0" + nm, MUL_T, Sc, INV);
        g.w("w" + nm, W_PL, p, {A0, B0, C0, Cf}, {SDET});
    };
    plane(P_W, "W", SaW, SbW, ScW, MEAN);
    // ---- the attribute planes (L244-248: ta[k] = mul(AT[k], ta[k]) of the 1/w plane's terms; Sc = (t0 + t1) + t2)
    struct Sums { int Sa = -1, Sb = -1, Sc = -1; } sums[P_N];
    sums[P_W] = {SaW, SbW, ScW};
    auto attr = [&](int p) {
        const std::string nm = kPlaneName[p];
        int AT[3], ta[3], tb[3], tc[3];
        for (int k = 0; k < 3; k++) {
            AT[k] = g.in("AT" + nm + std::to_string(k));
            ta[k] = g.op2("ta" + nm + std::to_string(k), MUL_T, AT[k], wa[k]);
            tb[k] = g.op2("tb" + nm + std::to_string(k), MUL_T, AT[k], wb[k]);
            tc[k] = g.op2("tc" + nm + std::to_string(k), MUL_T, AT[k], wc[k]);
        }
        Sums s;
        s.Sa = g.op2("Sa" + nm, ADD_T, g.op2("Sa01" + nm, ADD_T, ta[0], ta[1]), ta[2]);
        s.Sb = g.op2("Sb" + nm, ADD_T, g.op2("Sb01" + nm, ADD_T, tb[0], tb[1]), tb[2]);
        s.Sc = g.op2("Sc" + nm, ADD_T, g.op2("Sc01" + nm, ADD_T, tc[0], tc[1]), tc[2]);
        sums[p] = s;
        // the flat branch's C: mul(AT[2], mean) (L320)
        plane(p, nm, s.Sa, s.Sb, s.Sc, g.op2("Cf" + nm, MUL_T, AT[2], MEAN));
    };
    if (D.tex) { attr(P_U); attr(P_V); }
    for (int p = P_C0; p <= P_C3; p++) attr(p);
    if (D.ofs == 1)
        for (int p = P_O0; p <= P_O3; p++) attr(p);
    else if (D.ofs == 2)
        for (int p = P_O0; p <= P_O3; p++)       // ARCHITECTURE 3.7.3's table: no multiply, the signs of Sdet and mean
            g.w(std::string("w") + kPlaneName[p], W_DR, p, {}, {SDET, MEAN});
    // ---- MipSelect's K part (tb/tsp_setup/ref_copies_tsp.h)
    if (D.mip) {
        const int K2 = g.in("K2");
        const int MINV = g.op1("minv", RCP_M, SDET);                    // inv = Recip(det, 24), below -> +0
        const int INV2 = g.op2("inv2", MUL_I2, MINV, MINV);             // inv2 = Mul(inv, inv, 24), below -> +0
        int su = sums[P_U].Sc, sv = sums[P_V].Sc, sw = ScW;
        if (D.mip == 2) {
            // DCalcCtrl 1: at1(pl) = radd(radd(rmul(pl.Sa, x1), rmul(pl.Sb, y1)), pl.Sc), x1 = X0, y1 = Y0 (load(first[3]),
            // load(first[4]): the first vertex after the swap, IPs3::Setup's first[vol])
            auto at1 = [&](const char* nm, const Sums& s) {
                const int a = g.op2(std::string("d1a") + nm, MUL_T, s.Sa, X[0]), b = g.op2(std::string("d1b") + nm, MUL_T, s.Sb, Y[0]);
                return g.op2(std::string("d1") + nm, ADD_R, g.op2(std::string("d1ab") + nm, ADD_R, a, b), s.Sc);
            };
            su = at1("U", sums[P_U]); sv = at1("V", sums[P_V]); sw = at1("W", sums[P_W]);
        }
        // minor(sa1, sb1, sa2, sb2): q1 = kind / Mul(sa1, sb2), q2 = kind / Mul(sb1, sa2), n = |q1 - q2|, the quotient check
        auto minor = [&](const char* nm, int sa1, int sb1, int sa2, int sb2) {
            const int q1 = g.op2(std::string("q1") + nm, MUL_K, sa1, sb2), q2 = g.op2(std::string("q2") + nm, MUL_K, sb1, sa2);
            const int n = g.op2(std::string("n") + nm, ADD_N, q1, q2);
            return g.op2(std::string("nq") + nm, MUL_Q, n, INV2);
        };
        // along x: minor(pu, u.A0, pw, w.A0, su, u.Sa, sw, w.Sa); along y: minor(u.B0, pu, w.B0, pw, u.Sb, su, w.Sb, sw)
        const int mux = minor("ux", su, sums[P_U].Sa, sw, SaW), mvx = minor("vx", sv, sums[P_V].Sa, sw, SaW);
        const int muy = minor("uy", sums[P_U].Sb, su, SbW, sw), mvy = minor("vy", sums[P_V].Sb, sv, SbW, sw);
        auto length = [&](const char* nm, int p, int q) {
            const int hi = g.op2(std::string("lhi") + nm, ADD_LX, p, q), lo = g.op2(std::string("llo") + nm, ADD_LN, p, q);
            const int sum = g.op2(std::string("lsum") + nm, ADD_P, hi, lo), less = g.op2(std::string("lless") + nm, MUL_P, lo, K2);
            return g.op2(std::string("len") + nm, ADD_P, sum, less, true);
        };
        const int lx = length("x", mux, mvx), ly = length("y", muy, mvy);
        const int best = g.op2("best", MUL_B, g.op2("best0", ADD_BS, lx, ly), INV2);
        g.w("wK", W_K, -1, {best}, {SDET});
    }
    return g;
}

// ---------------------------------------------------------------------------------------------------------------
// evaluation with pvr_softfp: each operation as p2_tsp_alu does it, and the store writes as p2_tsp_setup does them
struct Job {
    uint32_t x[3] = {}, y[3] = {}, z[3] = {};
    uint32_t at[P_N][3] = {};     // attribute corner words, as loaded (planes U .. OA)
    int cls = 0;
    int bias = 4;                  // the TSP word's MipMapD (0: read as 4)
    int texU = 3;                  // size = 3 + TexU
    uint32_t perp = 0;             // FPU_PERP_VAL
};
struct Store {
    Fp A[P_N], B[P_N], C[P_N];
    bool have[P_N] = {};
    Fp k8;
    bool dz = false, haveK = false;
};
static Fp Inf(bool neg) { Fp r; r.bad = true; r.neg = neg; return r; }
static Fp Zero(bool neg) { Fp r; r.neg = neg; return r; }
static bool Above(const Fp& v) { return !v.zero() && v.top() - 1 > 127; }
static bool Below(const Fp& v) { return !v.zero() && v.top() - 1 < -126; }

static Fp TMul(const Fp& p, const Fp& q)
{
    const bool neg = p.neg != q.neg;
    if (p.bad || q.bad) {
        const Fp& other = p.bad ? q : p;
        return (!other.bad && other.zero()) ? Zero(neg) : Inf(neg);
    }
    Fp r = pvrfp::Mul(p, q, 24);
    if (Above(r)) return Inf(neg);
    if (Below(r)) return Zero(neg);
    return r;
}
static Fp TAdd(const Fp& p, const Fp& q)
{
    if (p.bad || q.bad) {
        if (p.bad && q.bad && p.neg != q.neg) return Zero(false);
        return Inf(p.bad ? p.neg : q.neg);
    }
    if (p.zero() != q.zero()) {
        const Fp& v = p.zero() ? q : p;
        const bool zneg = p.zero() ? p.neg : q.neg;
        const int n = Fp::Bits(v.mant);
        const bool half = n >= 2 && ((v.mant >> (n - 2)) & 1);
        if (v.top() - 1 < -127 + 2 && zneg != v.neg && !half)
            return Zero(false);
    }
    Fp r = pvrfp::Add(p, q, 24, 25);
    if (Above(r)) return Inf(r.neg);
    if (Below(r) || r.zero()) return Zero(false);
    return r;
}
static Fp WithZero(const Fp& p, uint32_t zeroBits)
{
    const bool zneg = (zeroBits >> 31) != 0;
    if (p.zero() || p.bad || p.top() - 1 != -126 || p.neg == zneg)
        return p;
    Fp zv;
    zv.mant = (1u << 23) | (zeroBits & 0x7fffffu);
    zv.exp = -150;
    zv.neg = zneg;
    const Fp r = pvrfp::Add(p, zv, 62, 400);
    return (r.zero() || r.top() - 1 < -126) ? Fp() : p;
}
static Fp RAdd(const Fp& x, const Fp& y)
{
    if (x.bad || y.bad) {
        if (x.bad && y.bad && x.neg != y.neg) return Fp();
        return Inf(x.bad ? x.neg : y.neg);
    }
    Fp m = pvrfp::Add(x, y, 24, 53);
    if (Above(m)) return Inf(m.neg);
    if (Below(m)) return Fp();
    return m;
}
static Fp Bad() { Fp r; r.bad = true; return r; }
static Fp CutN(Fp v, int n) { return v.cut(n); }

static Fp Op1(const Node& nd, const std::vector<Fp>& v, const Job& j)
{
    const Fp a = nd.src[0] >= 0 ? v[nd.src[0]] : Fp();
    Fp b = nd.src[1] >= 0 ? v[nd.src[1]] : Fp();
    if (nd.sub) b = -b;
    switch (nd.op) {
    case MUL_T: return TMul(a, b);
    case MUL_K: {
        // kind(x, y) and q = Mul(x, y, 24): INF -> {bad}, ZERO -> a zero, a number -> the product; the sign the xor
        Fp r;
        r.neg = a.neg != b.neg;
        if (a.bad || b.bad) {
            const bool z = (!a.bad && a.zero()) || (!b.bad && b.zero());
            r.bad = !z;
            return r;
        }
        if (a.zero() || b.zero()) return r;
        Fp m = pvrfp::Mul(a, b, 24);
        if (Above(m)) { r.bad = true; return r; }
        if (Below(m)) return r;
        return m;
    }
    case MUL_Q: {
        if (a.bad) return a;
        if (b.bad) return Fp();                 // inv2's marker: no undivided path, the numerator is 0 (divided: zeros)
        const Fp nq = pvrfp::Mul(a, b, 24);
        if (Below(nq)) return Fp();
        if (Above(nq)) return Bad();
        return a;
    }
    case MUL_I2: {
        if (a.zero()) return Bad();             // det zero, infinite or its reciprocal below the range: not undivided
        Fp r = pvrfp::Mul(a, a, 24);
        if (Below(r)) r = Fp();
        return r;
    }
    case MUL_B: {
        if (b.bad || a.bad || a.zero()) return a;
        Fp r = pvrfp::Mul(a, b, 24);
        if (Above(r)) return Bad();
        if (Below(r)) return Fp();
        return r;
    }
    case MUL_P: return pvrfp::Mul(a, b, 24);
    case ADD_T: return TAdd(a, b);
    case ADD_W: {
        const bool f0 = ((j.z[0] >> 23) & 0xff) == 0, f1 = ((j.z[1] >> 23) & 0xff) == 0;
        if (f0 && !f1) return WithZero(b, j.z[0]);
        if (f1 && !f0) return WithZero(a, j.z[1]);
        return TAdd(a, b);
    }
    case ADD_R: return RAdd(a, b);
    case ADD_N: {
        const Fp q2 = nd.sub ? -b : b;          // (never: no sub on ADD_N)
        if (a.bad || q2.bad) {
            if (a.bad && q2.bad && a.neg == q2.neg) return Fp();
            return Bad();
        }
        const Fp q1 = a.zero() ? Fp() : a, q2b = q2.zero() ? Fp() : q2;
        Fp n = pvrfp::Sub(q1, q2b, 62, 200).cut(24);
        n.neg = false;
        n.bad = false;
        return n;
    }
    case ADD_LX: case ADD_LN: {
        if (a.bad || b.bad) return Bad();
        const bool aLonger = pvrfp::AtMost(b, a);
        return (nd.op == ADD_LX) == aLonger ? a : b;
    }
    case ADD_BS: return (a.bad || (!b.bad && pvrfp::AtMost(b, a))) ? a : b;
    case ADD_P: return pvrfp::Add(a, b, 24, 25);
    case RCP_T: {
        // a determinant of zero has the flat branch: no write reads inv then (p2_fp_recip24 makes some value)
        if (a.zero() && !a.bad) return Fp();
        Fp inv = a.bad ? Zero(a.neg) : pvrfp::Recip(a, 24);
        if (Below(inv) || (!a.bad && !a.zero() && a.top() - 1 >= 126)) inv = Zero(inv.neg);
        return inv;
    }
    case RCP_M: {
        Fp inv = (a.bad || a.zero()) ? Fp() : pvrfp::Recip(a, 24);
        if (Below(inv)) inv = Fp();
        return inv;
    }
    default: return Fp();
    }
}

// the store writes' fixed logic (p2_tsp_setup): from the determinant Sdet, the mean, the job's TSP word
static void Write(const Node& nd, const std::vector<Fp>& v, const Job& j, const Graph& g, Store& st)
{
    const Fp& det = v[g.find("Sdet")];
    const bool flat = (det.zero() && !det.bad) || pvrfp::Perpendicular(det);
    if (nd.op == W_PL) {
        const int p = nd.plane;
        if (flat) {
            st.A[p] = Fp(); st.B[p] = Fp(); st.C[p] = CutN(v[nd.src[3]], 16);
        } else {
            st.A[p] = CutN(v[nd.src[0]], 16); st.B[p] = CutN(v[nd.src[1]], 16); st.C[p] = CutN(v[nd.src[2]], 16);
        }
        st.have[p] = true;
    } else if (nd.op == W_DR) {
        const int p = nd.plane;
        const Fp& mean = v[g.find("mean")];
        if (flat) {
            st.A[p] = Fp(); st.B[p] = Fp(); st.C[p] = Zero(mean.neg);
        } else {
            st.A[p] = st.B[p] = st.C[p] = Zero(det.neg);
        }
        st.have[p] = true;
    } else if (nd.op == W_K) {
        const int size = 3 + j.texU, bias = j.bias ? j.bias : 4;
        st.dz = det.zero() && !det.bad;
        Fp best = v[nd.src[0]];
        if (st.dz) { best = Fp(); best.mant = 0xffffff; best.exp = -23; }
        if (best.bad) st.k8 = Fp::Pow2(-128 + size, false);
        else if (best.zero()) st.k8 = Fp::Pow2(-127 + size, false);
        else {
            Fp k = pvrfp::Mul(best, Fp::FromHalves(2 * (int64_t)bias), 62);
            k.exp += size - 2;
            st.k8 = k.cut(8);
        }
        st.haveK = true;
    }
}

static void Inputs(const Graph& g, const Job& j, std::vector<Fp>& v)
{
    v.assign(g.n.size(), Fp());
    for (int k = 0; k < 3; k++) {
        v[g.find(S("X", k))] = Fp::FromSingle(j.x[k], true);
        v[g.find(S("Y", k))] = Fp::FromSingle(j.y[k], true);
        v[g.find(S("Z", k))] = Fp::FromSingle(j.z[k], true);
    }
    v[g.find("THIRD")] = pvrfp::OneThird();
    if (g.find("K2") >= 0) { Fp k2; k2.mant = 0x95F612; k2.exp = -24; v[g.find("K2")] = k2; }
    for (int p = P_U; p < P_N; p++)
        for (int k = 0; k < 3; k++) {
            const int h = g.find(std::string("AT") + kPlaneName[p] + std::to_string(k));
            if (h >= 0) v[h] = Fp::FromSingle(j.at[p][k], true);
        }
}

static Store Run(const Graph& g, const Job& j)
{
    std::vector<Fp> v;
    Inputs(g, j, v);
    Store st;
    for (size_t k = 0; k < g.n.size(); k++) {
        const Node& nd = g.n[k];
        if (nd.op == O_IN) continue;
        if (KindOf(nd.op) == K_W) Write(nd, v, j, g, st);
        else v[k] = Op1(nd, v, j);
    }
    return st;
}

static bool Same(const Fp& a, const Fp& b)
{
    return a.neg == b.neg && a.bad == b.bad && a.mant == b.mant && (a.mant == 0 || a.exp == b.exp);
}
static std::string Str(const Fp& v)
{
    char s[96];
    snprintf(s, sizeof s, "{%d %d %d %06" PRIx64 "}", v.neg, v.bad, v.exp, (uint64_t)v.mant);
    return s;
}

// ---------------------------------------------------------------------------------------------------------------
// the graph check: the class's store words against refsw3's PlaneT::Setup and the K copies
static int CheckOne(const Graph& g, const Job& j, std::string* why)
{
    pvrfp::perpVal = Fp::FromBits(j.perp & 0x7fffffffu);
    const ClsDef& D = kCls[g.cls];
    const Store st = Run(g, j);
    static const pvrtsp::PlaneHW cfg;
    pvrtsp::PlaneT<pvrtsp::PlaneHW> pl[P_N];
    pl[P_W].Setup(j.x, j.y, j.z, nullptr, cfg);
    for (int p = P_U; p < P_N; p++)
        pl[p].Setup(j.x, j.y, j.z, j.at[p], cfg);
    int bad = 0;
    auto cmp = [&](const std::string& name, const Fp& got, const Fp& want) {
        if (Same(got, want)) return;
        bad++;
        if (why && why->size() < 500) *why += " " + name + " graph " + Str(got) + " refsw3 " + Str(want);
    };
    for (int p = 0; p < P_N; p++) {
        const bool live = p == P_W || (p >= P_C0 && p <= P_C3) || ((p == P_U || p == P_V) && D.tex) || (p >= P_O0 && D.ofs);
        if (!live) continue;
        if (!st.have[p]) { bad++; if (why) *why += std::string(" ") + kPlaneName[p] + " not written"; continue; }
        cmp(std::string("A") + kPlaneName[p], st.A[p], pl[p].A);
        cmp(std::string("B") + kPlaneName[p], st.B[p], pl[p].B);
        cmp(std::string("C") + kPlaneName[p], st.C[p], pl[p].C);
    }
    if (D.mip) {
        // MipSelect(U, V, invW, q, 3 + TexU, MipMapD ? MipMapD : 4, DCalcCtrl ? first : null) (refsw_tile.cpp mipChoose,
        // L1948-1953); first = u, v, 1/w, x, y of the first vertex (IPs3::Setup)
        const uint32_t first[5] = {j.at[P_U][0], j.at[P_V][0], j.z[0], j.x[0], j.y[0]};
        const p2tspref::MipKOut r = p2tspref::MipKOf(pl[P_U], pl[P_V], pl[P_W], 3 + j.texU, j.bias ? j.bias : 4,
                                                     D.mip == 2 ? first : nullptr);
        if (r.ret) { bad++; if (why) *why += " K: MipSelect returned before K"; }
        else {
            cmp("K8", st.k8, r.k8);
            if (st.dz != r.dzForce) { bad++; if (why) *why += " dz " + std::to_string(st.dz) + " refsw3 " + std::to_string(r.dzForce); }
        }
    }
    return bad;
}


}   // namespace

// the random jobs and the directed classes live in tsp_cases.h (shared with the RTL testbench): p2tspcase::Prim is a
// primitive as the parameter block gives it (raw vertex words); ToJob makes the setup's inputs of one (tag, vsel)
namespace {
static Job ToJob(const p2tspcase::SetupIn& s)
{
    Job j;
    for (int k = 0; k < 3; k++) { j.x[k] = s.x[k]; j.y[k] = s.y[k]; j.z[k] = s.z[k]; }
    for (int p = 0; p < P_N; p++)
        for (int k = 0; k < 3; k++) j.at[p][k] = s.at[p][k];
    j.cls = ClsOf(s.tex, s.ofs, s.mip);
    j.bias = s.bias;
    j.texU = s.texU;
    j.perp = s.perp;
    return j;
}

int GraphCheck(uint64_t n, uint64_t seed, int threads, const std::string& dcts)
{
    std::vector<Graph> G(C_N);
    for (int c = 0; c < C_N; c++) G[c] = Build(c);
    std::vector<p2tspcase::Case> directed;
    std::string err;
    p2tspcase::DirectedA3(&directed);
    const size_t nA3 = directed.size();
    p2tspcase::DirectedNamed(&directed);
    const size_t nNamed = directed.size() - nA3;
    if (!p2tspcase::ConsoleSets(dcts, &directed, nullptr, &err)) {
        printf("graph-check: %s\n", err.c_str());
        return 1;
    }
    const size_t nCons = directed.size() - nA3 - nNamed;
    const uint64_t total = n + directed.size();
    std::vector<std::pair<pid_t, int>> kids;
    for (int t = 0; t < threads; t++) {
        int fd[2];
        if (pipe(fd) != 0) { perror("pipe"); return 1; }
        fflush(stdout);
        const pid_t pid = fork();
        if (pid == 0) {
            close(fd[0]);
            long jobs = 0, fails = 0, shown = 0, perCls[C_N] = {};
            std::string why;
            for (uint64_t i = t; i < total; i += threads) {
                p2tspcase::Case cs;
                if (i < directed.size()) cs = directed[i];
                else {
                    p2tb::Rng r = p2tb::Rng::of(seed, i - directed.size());
                    cs = p2tspcase::RandomCase(r);
                }
                const Job j = ToJob(p2tspcase::SetupInOf(cs));
                if (j.cls < 0) { fails++; continue; }
                why.clear();
                const int bad = CheckOne(G[j.cls], j, &why);
                jobs++;
                perCls[j.cls]++;
                if (bad) {
                    fails++;
                    if (shown++ < 20 / threads + 1)
                        printf("  FAIL [graph %s] job %" PRIu64 " (%s): %d words:%s\n", kCls[j.cls].name, i,
                               i < nA3 ? "A3" : i < nA3 + nNamed ? "named" : i < directed.size() ? "console set" : "random", bad, why.c_str());
                }
            }
            fflush(stdout);
            long res[2 + C_N] = {jobs, fails};
            for (int c = 0; c < C_N; c++) res[2 + c] = perCls[c];
            if (write(fd[1], res, sizeof res) != (ssize_t)sizeof res) _exit(3);
            _exit(0);
        }
        close(fd[1]);
        kids.push_back({pid, fd[0]});
    }
    long jobs = 0, fails = 0, perCls[C_N] = {};
    bool lost = false;
    for (auto& k : kids) {
        long res[2 + C_N] = {};
        if (read(k.second, res, sizeof res) != (ssize_t)sizeof res) lost = true;
        close(k.second);
        int st = 0;
        waitpid(k.first, &st, 0);
        if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) lost = true;
        jobs += res[0];
        fails += res[1];
        for (int c = 0; c < C_N; c++) perCls[c] += res[2 + c];
    }
    if (lost) { printf("graph-check: a worker process died\n"); fails++; }
    printf("graph-check: graphs");
    for (int c = 0; c < C_N; c++) printf(" %s %zu", kCls[c].name, G[c].n.size());
    printf(" nodes\ngraph-check: jobs a class:");
    for (int c = 0; c < C_N; c++) printf(" %s %ld", kCls[c].name, perCls[c]);
    printf("\ngraph-check: %" PRIu64 " random jobs (seed %" PRIu64 "), %zu of the dropped-offset class A3, %zu of the console sets, "
           "%zu named, %ld evaluations, %ld failures\n", n, seed, nA3, nCons, nNamed, jobs, fails);
    const bool ok = fails == 0 && nCons > 0;
    printf("graph-check: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// ---------------------------------------------------------------------------------------------------------------
// the list scheduler
struct Params { int nm = 4, na = 4, lm = 1, la = 2, lr = 2; };
static const Params kDefault = {4, 4, 1, 2, 2};

struct Sched {
    std::vector<int> issue, slot, ready;
    int len = 0, lastIssue = 0;
    int nMul = 0, nAdd = 0, nRcp = 0, nW = 0;
};
static int Lat(const Params& P, Op o)
{
    switch (KindOf(o)) {
    case K_MUL: return P.lm;
    case K_ADD: return P.la;
    case K_RCP: return P.lr;
    case K_W: return 1;
    default: return 0;
    }
}
static std::vector<int> Preds(const Node& v)
{
    std::vector<int> p;
    for (int s : v.src) if (s >= 0) p.push_back(s);
    for (int d : v.deps) p.push_back(d);
    return p;
}
Sched Schedule(const Graph& g, const Params& P)
{
    const int N = (int)g.n.size();
    Sched s;
    s.issue.assign(N, -1);
    s.slot.assign(N, -1);
    s.ready.assign(N, 0);
    std::vector<std::vector<int>> succ(N);
    for (int k = 0; k < N; k++)
        for (int q : Preds(g.n[k])) succ[q].push_back(k);
    std::vector<int> prio(N, 0);
    for (int k = N - 1; k >= 0; k--) {
        int m = 0;
        for (int q : succ[k]) m = std::max(m, prio[q]);
        prio[k] = Lat(P, g.n[k].op) + m;
    }
    int left = 0;
    for (int k = 0; k < N; k++)
        if (g.n[k].op != O_IN) {
            left++;
            switch (KindOf(g.n[k].op)) {
            case K_MUL: s.nMul++; break; case K_ADD: s.nAdd++; break; case K_RCP: s.nRcp++; break; case K_W: s.nW++; break;
            default: break;
            }
        }
    std::vector<bool> done(N, false);
    for (int k = 0; k < N; k++) if (g.n[k].op == O_IN) done[k] = true;
    for (int t = 0; left > 0; t++) {
        if (t > 4000) { fprintf(stderr, "gen_tsp_prog: the scheduler is stuck\n"); exit(2); }
        std::vector<int> cand;
        for (int k = 0; k < N; k++) {
            if (done[k]) continue;
            bool ok = true;
            for (int q : Preds(g.n[k])) ok = ok && done[q] && s.ready[q] <= t;
            if (ok) cand.push_back(k);
        }
        std::stable_sort(cand.begin(), cand.end(), [&](int p, int q) { return prio[p] > prio[q]; });
        int used[5] = {0, 0, 0, 0, 0};
        const int cap[5] = {0, P.nm, P.na, 1, 1};
        for (int k : cand) {
            const Kind kd = KindOf(g.n[k].op);
            if (used[kd] >= cap[kd]) continue;
            s.issue[k] = t;
            s.slot[k] = used[kd]++;
            s.ready[k] = t + Lat(P, g.n[k].op);
            s.lastIssue = std::max(s.lastIssue, t);
            done[k] = true;
            left--;
        }
    }
    int r = 0;
    for (int k : g.outputs) r = std::max(r, s.issue[k]);
    s.len = r + 1;
    return s;
}

struct RegMap {
    std::vector<std::string> names;
    int nin = 0;                        // the inputs come first
    std::map<std::string, int> idx;
    int of(const std::string& s) const { return idx.at(s); }
};
RegMap Regs(const std::vector<Graph>& G)
{
    RegMap m;
    for (int pass = 0; pass < 2; pass++)
        for (const Graph& g : G)
            for (const Node& v : g.n) {
                if ((v.op == O_IN) != (pass == 0) || KindOf(v.op) == K_W || m.idx.count(v.name)) continue;
                m.idx[v.name] = (int)m.names.size();
                m.names.push_back(v.name);
                if (pass == 0) m.nin++;
            }
    return m;
}
static int Clog2(int v) { int b = 0; while ((1 << b) < v) b++; return b; }
static std::string Up(const std::string& s)
{
    std::string o = s;
    for (char& ch : o) ch = (char)toupper((unsigned char)ch);
    return o;
}

struct Built {
    Params P;
    std::vector<Graph> G;
    std::vector<Sched> Sc;
    RegMap R;
    int lenMax = 0;
};
Built BuildAll(const Params& P)
{
    Built b;
    b.P = P;
    for (int c = 0; c < C_N; c++) {
        b.G.push_back(Build(c));
        b.Sc.push_back(Schedule(b.G.back(), P));
        b.lenMax = std::max(b.lenMax, b.Sc.back().len);
    }
    b.R = Regs(b.G);
    return b;
}

void WriteSv(const Built& b, FILE* f, const std::string& cmd)
{
    const Params& P = b.P;
    const int nreg = (int)b.R.names.size(), rw = Clog2(nreg), pcb = Clog2(b.lenMax + 1);
    const int nin = b.R.nin;
    fprintf(f, "// GENERATED: do not edit. tools/gen/gen_tsp_prog.cpp (%s):\n"
               "// the TSP setup's microprograms, the operation graphs of refsw3's plane setup and MipSelect's K part per setup class,\n"
               "// list-scheduled onto p2_tsp_alu (ARCHITECTURE 3.7.3, PLAN M9). Regenerate: make tsp-prog; check: make tsp-prog-check.\n//\n"
               "// Per class and step (pc) the micro-word: per multiplier, adder, the reciprocal and the store's write port an issue\n"
               "// with its operation, operand registers and result register (readable L_<unit> steps later); a store write names\n"
               "// its plane and its operands (W_PL: A0, B0, C0 and the flat branch's C). Every value has its own register; the\n"
               "// inputs (P2_TSP_R_X0 .. ) are loaded when a job starts. A program ends with its last store write\n"
               "// (P2_TSP_LEN_<class> - 1). The lengths are the scheduler's, never padded: the measured 39 / 48 / 64 / 49 / +5\n"
               "// [M tim 3.7] are a check on the parameters (gen_tsp_prog --sweep, MT4).\n", cmd.c_str());
    fprintf(f, "package p2_tsp_prog_pkg;\n\n");
    fprintf(f, "  // the free parameters (ARCHITECTURE 6: TSP_NM, TSP_NA, the latencies)\n");
    fprintf(f, "  localparam int P2_TSP_NM    = %d;\n  localparam int P2_TSP_NA    = %d;\n", P.nm, P.na);
    fprintf(f, "  localparam int P2_TSP_L_MUL = %d;   // issued at step s, readable from step s + L\n", P.lm);
    fprintf(f, "  localparam int P2_TSP_L_ADD = %d;\n  localparam int P2_TSP_L_RCP = %d;\n\n", P.la, P.lr);
    fprintf(f, "  // the setup classes (p2_tsp_setup chooses one a job)\n");
    fprintf(f, "  localparam int P2_TSP_NCLS = %d;\n", C_N);
    for (int c = 0; c < C_N; c++)
        fprintf(f, "  localparam logic [3:0] P2_TSP_CLS_%s = 4'd%d;   // tex %d, offset planes %s, mip %s; length %d\n", kCls[c].name, c,
                kCls[c].tex, kCls[c].ofs == 0 ? "none" : kCls[c].ofs == 1 ? "computed" : "dropped",
                kCls[c].mip == 0 ? "no" : kCls[c].mip == 1 ? "DCalcCtrl 0" : "DCalcCtrl 1", b.Sc[c].len);
    fprintf(f, "  localparam int P2_TSP_PC_BITS = %d;\n", pcb);
    fprintf(f, "  // the programs' lengths (the last store write's step + 1)\n");
    fprintf(f, "  function automatic logic [P2_TSP_PC_BITS-1:0] p2_tsp_len(input logic [3:0] cls);\n    case (cls)\n");
    for (int c = 0; c < C_N; c++) fprintf(f, "      4'd%d: return %d'd%d;\n", c, pcb, b.Sc[c].len);
    fprintf(f, "      default: return %d'd1;\n    endcase\n  endfunction\n\n", pcb);
    fprintf(f, "  // the store's planes\n");
    for (int p = 0; p < P_N; p++) fprintf(f, "  localparam logic [3:0] P2_TSP_PL_%s = 4'd%d;\n", kPlaneName[p], p);
    fprintf(f, "  localparam int P2_TSP_NPLANE = %d;\n\n", P_N);
    fprintf(f, "  // the operand registers: the inputs first (loaded at a job's start), then one per value\n");
    fprintf(f, "  localparam int P2_TSP_NREG = %d;\n  localparam int P2_TSP_NIN  = %d;\n  localparam int P2_TSP_RW   = %d;\n", nreg, nin, rw);
    for (int k = 0; k < nreg; k++)
        fprintf(f, "  localparam logic [P2_TSP_RW-1:0] P2_TSP_R_%s = %d'd%d;\n", Up(b.R.names[k]).c_str(), rw, k);
    fprintf(f, "\n  // operations (p2_tsp_alu; p2_tsp_setup's store writes)\n");
    fprintf(f, "  localparam logic [2:0] P2_TSP_MUL_T = 3'd0, P2_TSP_MUL_K = 3'd1, P2_TSP_MUL_Q = 3'd2, P2_TSP_MUL_I2 = 3'd3,\n"
               "                         P2_TSP_MUL_B = 3'd4, P2_TSP_MUL_P = 3'd5;\n");
    fprintf(f, "  localparam logic [2:0] P2_TSP_ADD_T = 3'd0, P2_TSP_ADD_W = 3'd1, P2_TSP_ADD_R = 3'd2, P2_TSP_ADD_N = 3'd3,\n"
               "                         P2_TSP_ADD_LX = 3'd4, P2_TSP_ADD_LN = 3'd5, P2_TSP_ADD_BS = 3'd6, P2_TSP_ADD_P = 3'd7;\n");
    fprintf(f, "  localparam logic       P2_TSP_RCP_T = 1'b0, P2_TSP_RCP_M = 1'b1;\n");
    fprintf(f, "  localparam logic [1:0] P2_TSP_W_PL = 2'd0, P2_TSP_W_DR = 2'd1, P2_TSP_W_K = 2'd2;\n\n");
    fprintf(f, "  typedef struct packed {\n    logic                 v;\n    logic [2:0]           op;\n    logic [P2_TSP_RW-1:0] ra;\n"
               "    logic [P2_TSP_RW-1:0] rb;\n    logic [P2_TSP_RW-1:0] rd;\n  } p2_tsp_mslot_t;\n\n");
    fprintf(f, "  typedef struct packed {\n    logic                 v;\n    logic [2:0]           op;\n    logic                 sub;\n"
               "    logic [P2_TSP_RW-1:0] ra;\n    logic [P2_TSP_RW-1:0] rb;\n    logic [P2_TSP_RW-1:0] rd;\n  } p2_tsp_aslot_t;\n\n");
    fprintf(f, "  typedef struct packed {\n    logic                 v;\n    logic                 op;\n    logic [P2_TSP_RW-1:0] ra;\n"
               "    logic [P2_TSP_RW-1:0] rd;\n  } p2_tsp_rslot_t;\n\n");
    fprintf(f, "  typedef struct packed {\n    logic                 v;\n    logic [1:0]           op;\n    logic [3:0]           plane;\n"
               "    logic [3:0][P2_TSP_RW-1:0] r;\n  } p2_tsp_wslot_t;\n\n");
    fprintf(f, "  typedef struct packed {\n    p2_tsp_mslot_t [P2_TSP_NM-1:0] m;\n    p2_tsp_aslot_t [P2_TSP_NA-1:0] a;\n"
               "    p2_tsp_rslot_t                 r;\n    p2_tsp_wslot_t                 w;\n  } p2_tsp_uword_t;\n\n");
    fprintf(f, "  // the microprogram ROM: the micro-word of step pc of class cls (all zero: no issue)\n");
    fprintf(f, "  function automatic p2_tsp_uword_t p2_tsp_prog(input logic [3:0] cls, input logic [P2_TSP_PC_BITS-1:0] pc);\n");
    fprintf(f, "    p2_tsp_uword_t w;\n    w = '0;\n    case (cls)\n");
    for (int c = 0; c < C_N; c++) {
        const Graph& g = b.G[c];
        const Sched& s = b.Sc[c];
        fprintf(f, "      4'd%d: begin   // %s\n        case (pc)\n", c, kCls[c].name);
        for (int t = 0; t <= s.lastIssue; t++) {
            std::vector<int> at;
            for (size_t k = 0; k < g.n.size(); k++) if (s.issue[k] == t) at.push_back((int)k);
            if (at.empty()) continue;
            fprintf(f, "          %d'd%d: begin\n", pcb, t);
            for (int k : at) {
                const Node& v = g.n[k];
                const Kind kd = KindOf(v.op);
                auto R = [&](int src) { return src >= 0 ? b.R.of(g.n[src].name) : 0; };
                if (kd == K_MUL)
                    fprintf(f, "            w.m[%d] = {1'b1, 3'd%d, %d'd%d, %d'd%d, %d'd%d};   // %s %s\n", s.slot[k], OpNum(v.op), rw,
                            R(v.src[0]), rw, R(v.src[1]), rw, b.R.of(v.name), OpName(v.op), v.name.c_str());
                else if (kd == K_ADD)
                    fprintf(f, "            w.a[%d] = {1'b1, 3'd%d, 1'b%d, %d'd%d, %d'd%d, %d'd%d};   // %s %s\n", s.slot[k], OpNum(v.op),
                            v.sub, rw, R(v.src[0]), rw, R(v.src[1]), rw, b.R.of(v.name), OpName(v.op), v.name.c_str());
                else if (kd == K_RCP)
                    fprintf(f, "            w.r = {1'b1, 1'b%d, %d'd%d, %d'd%d};   // %s %s\n", OpNum(v.op), rw, R(v.src[0]), rw,
                            b.R.of(v.name), OpName(v.op), v.name.c_str());
                else
                    fprintf(f, "            w.w = {1'b1, 2'd%d, 4'd%d, %d'd%d, %d'd%d, %d'd%d, %d'd%d};   // %s %s\n", OpNum(v.op),
                            v.plane < 0 ? 0 : v.plane, rw, R(v.src[3]), rw, R(v.src[2]), rw, R(v.src[1]), rw, R(v.src[0]),
                            OpName(v.op), v.name.c_str());
            }
            fprintf(f, "          end\n");
        }
        fprintf(f, "          default: ;\n        endcase\n      end\n");
    }
    fprintf(f, "      default: ;\n    endcase\n    return w;\n  endfunction\n\nendpackage\n");
}

void WriteHdr(const Built& b, FILE* f, const std::string& cmd)
{
    fprintf(f, "// GENERATED: do not edit. tools/gen/gen_tsp_prog.cpp (%s): the schedule of the TSP setup's microprograms for\n"
               "// tb/tsp_setup's program consistency check, from the same run as rtl/v1/pkg/p2_tsp_prog_pkg.sv.\n"
               "#pragma once\n\nnamespace p2tspprog {\n\n", cmd.c_str());
    fprintf(f, "constexpr int kNM = %d, kNA = %d, kLMul = %d, kLAdd = %d, kLRcp = %d;\nconstexpr int kNCls = %d;\n", b.P.nm, b.P.na,
            b.P.lm, b.P.la, b.P.lr, C_N);
    fprintf(f, "static const char* const kClsName[] = {");
    for (int c = 0; c < C_N; c++) fprintf(f, "\"%s\", ", kCls[c].name);
    fprintf(f, "};\nconstexpr int kLen[] = {");
    for (int c = 0; c < C_N; c++) fprintf(f, "%d, ", b.Sc[c].len);
    fprintf(f, "};\nconstexpr int kNReg = %zu;\n", b.R.names.size());
    fprintf(f, "// unit: 0 multiplier, 1 adder, 2 reciprocal, 3 store write; r: the operands (W: A0, B0, C0, flat C), rd the result\n"
               "struct Issue { int cls, step, unit, slot, op, sub, plane, r0, r1, r2, r3, rd; const char* name; };\n"
               "static const Issue kIssues[] = {\n");
    long cnt = 0;
    for (int c = 0; c < C_N; c++) {
        const Graph& g = b.G[c];
        const Sched& s = b.Sc[c];
        for (int t = 0; t <= s.lastIssue; t++)
            for (size_t k = 0; k < g.n.size(); k++) {
                if (s.issue[k] != t) continue;
                const Node& v = g.n[k];
                const Kind kd = KindOf(v.op);
                auto R = [&](int src) { return src >= 0 ? b.R.of(g.n[src].name) : 0; };
                fprintf(f, "    {%d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, \"%s\"},\n", c, t,
                        kd == K_MUL ? 0 : kd == K_ADD ? 1 : kd == K_RCP ? 2 : 3, s.slot[k], OpNum(v.op), v.sub,
                        v.plane < 0 ? 0 : v.plane, R(v.src[0]), R(v.src[1]), R(v.src[2]), R(v.src[3]),
                        kd == K_W ? 0 : b.R.of(v.name), v.name.c_str());
                cnt++;
            }
    }
    fprintf(f, "};\nconstexpr int kNIssues = %ld;\n\n}   // namespace p2tspprog\n", cnt);
}

void WriteReport(const Built& b, FILE* f)
{
    fprintf(f, "TSP setup microprograms: TSP_NM %d, TSP_NA %d, L_MUL %d, L_ADD %d, L_RCP %d; %zu operand registers\n\n", b.P.nm,
            b.P.na, b.P.lm, b.P.la, b.P.lr, b.R.names.size());
    for (int c = 0; c < C_N; c++) {
        const Graph& g = b.G[c];
        const Sched& s = b.Sc[c];
        fprintf(f, "%s: %d multiplies, %d additions, %d reciprocals, %d store writes; length %d\n", kCls[c].name, s.nMul,
                s.nAdd, s.nRcp, s.nW, s.len);
        for (int t = 0; t < s.len; t++) {
            fprintf(f, "  %2d:", t);
            for (size_t k = 0; k < g.n.size(); k++)
                if (s.issue[k] == t) {
                    const Kind kd = KindOf(g.n[k].op);
                    fprintf(f, " %c%d:%s", kd == K_MUL ? 'M' : kd == K_ADD ? 'A' : kd == K_RCP ? 'R' : 'W', s.slot[k],
                            g.n[k].name.c_str());
                }
            fprintf(f, "\n");
        }
        fprintf(f, "\n");
    }
}

void Sweep()
{
    printf("sweep: program lengths UNTEX / TEX / TEX_O / TEX_D / TEX_M1 - TEX_M0; measured 39 / 48 / 64 / 48 (offsets dropped: \"+16 a "
           "triangle disappears\") / +5 [M tim 3.7]; the 12 nearest sets (|UNTEX - 39| + |TEX - 48| + |TEX_O - 64|)\n");
    printf("  NM NA LM LA LR   UNTEX  TEX TEX_O TEX_D  dcalc  distance\n");
    struct R { int nm, na, lm, la, lr, u, t, o, d, dc, dist; };
    std::vector<R> rs;
    for (int nm = 1; nm <= 6; nm++)
        for (int na = 1; na <= 6; na++)
            for (int lm = 1; lm <= 3; lm++)
                for (int la = 1; la <= 3; la++)
                    for (int lr = 1; lr <= 4; lr++) {
                        const Built b = BuildAll(Params{nm, na, lm, la, lr});
                        R x{nm, na, lm, la, lr, b.Sc[ClsOf(false, 0, 0)].len, b.Sc[ClsOf(true, 0, 0)].len, b.Sc[ClsOf(true, 1, 0)].len,
                            b.Sc[ClsOf(true, 2, 0)].len, b.Sc[ClsOf(true, 0, 2)].len - b.Sc[ClsOf(true, 0, 1)].len, 0};
                        x.dist = abs(x.u - 39) + abs(x.t - 48) + abs(x.o - 64);
                        rs.push_back(x);
                    }
    std::stable_sort(rs.begin(), rs.end(), [](const R& a, const R& b) { return a.dist < b.dist; });
    for (size_t i = 0; i < rs.size() && i < 12; i++)
        printf("  %2d %2d %2d %2d %2d   %5d %4d %5d %5d  %+5d  %d\n", rs[i].nm, rs[i].na, rs[i].lm, rs[i].la, rs[i].lr, rs[i].u,
               rs[i].t, rs[i].o, rs[i].d, rs[i].dc, rs[i].dist);
}

}   // namespace

int main(int argc, char** argv)
{
    Params P = kDefault;
    std::string sv, hdr, report, dcts = "../dreamcast-tests";
    bool check = false, sweep = false;
    uint64_t n = 1000000, seed = 1;
    int threads = 8;
    if (const char* e = getenv("DCTESTS")) dcts = e;
    for (int i = 1; i < argc; i++) {
        const std::string a = argv[i];
        auto val = [&]() -> const char* {
            if (i + 1 >= argc) { fprintf(stderr, "gen_tsp_prog: %s needs a value\n", a.c_str()); exit(2); }
            return argv[++i];
        };
        if (a == "--nm") P.nm = atoi(val());
        else if (a == "--na") P.na = atoi(val());
        else if (a == "--lm") P.lm = atoi(val());
        else if (a == "--la") P.la = atoi(val());
        else if (a == "--lr") P.lr = atoi(val());
        else if (a == "--sv") sv = val();
        else if (a == "--hdr") hdr = val();
        else if (a == "--report") report = val();
        else if (a == "--check") check = true;
        else if (a == "--sweep") sweep = true;
        else if (a == "--n") n = strtoull(val(), nullptr, 0);
        else if (a == "--seed") seed = strtoull(val(), nullptr, 0);
        else if (a == "--threads") threads = atoi(val());
        else if (a == "--dcts") dcts = val();
        else { fprintf(stderr, "gen_tsp_prog: unknown argument %s\n", a.c_str()); return 2; }
    }
    if (check) return GraphCheck(n, seed, std::max(1, threads), dcts);
    if (sweep) { Sweep(); return 0; }
    char pbuf[96];
    snprintf(pbuf, sizeof pbuf, "TSP_NM %d, TSP_NA %d, L_MUL %d, L_ADD %d, L_RCP %d", P.nm, P.na, P.lm, P.la, P.lr);
    const Built b = BuildAll(P);
    for (int c = 0; c < C_N; c++)
        for (size_t k = 0; k < b.G[c].n.size(); k++)
            if (b.G[c].n[k].op != O_IN && KindOf(b.G[c].n[k].op) != K_W && b.Sc[c].ready[k] > b.Sc[c].len - 1) {
                fprintf(stderr, "gen_tsp_prog: %s: %s is written after the program's last step (%d > %d): the next job's "
                                "accept would overlap it\n", kCls[c].name, b.G[c].n[k].name.c_str(), b.Sc[c].ready[k], b.Sc[c].len - 1);
                return 1;
            }
    auto open = [](const std::string& path) {
        FILE* f = fopen(path.c_str(), "w");
        if (!f) { fprintf(stderr, "gen_tsp_prog: cannot write %s\n", path.c_str()); exit(1); }
        return f;
    };
    if (!sv.empty()) { FILE* f = open(sv); WriteSv(b, f, pbuf); fclose(f); }
    if (!hdr.empty()) { FILE* f = open(hdr); WriteHdr(b, f, pbuf); fclose(f); }
    if (!report.empty()) { FILE* f = open(report); WriteReport(b, f); fclose(f); }
    if (sv.empty() && hdr.empty() && report.empty()) WriteReport(b, stdout);
    printf("gen_tsp_prog: %s:", pbuf);
    for (int c = 0; c < C_N; c++) printf(" %s %d", kCls[c].name, b.Sc[c].len);
    printf("\n");
    return 0;
}

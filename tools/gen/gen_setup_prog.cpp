// gen_setup_prog.cpp: the ISP setup's microprograms (PLAN M4; ARCHITECTURE 3.4.4 "The programs are generated, not
// written"). C++ on the refcore headers (conventions.md 5: hardware arithmetic is never written in Python).
//
// What it holds, per primitive class (TRI, QUAD, MODIFIER TRI), is the OPERATION GRAPH of refsw3's setup arithmetic at
// 4f3efe15: nodes are pvr_softfp operations in the flavours p2_isp_alu has, edges are data dependencies:
//   the swamped determinant (pvr_isp_edge.h EdgeWinding), per edge c, dx, dy, first and the tile's saturated start
//   (EdgeTile::Setup L183-200), and the depth plane in the depth unit's own ranged arithmetic (pvr_isp_depth.h
//   DepthTileT::Setup: the edges, a, b, c, det with Perpendicular, inv0 = Recip(det), first0 at the tile's sample point,
//   A = Mul(a, inv0), B, and the determinant-zero mean). The graph's OUTPUTS are the values p2_isp_setup's hand-off step
//   reads: what the fixed logic after the arithmetic (p2_isp_edge_steps, p2_isp_edge_fin, p2_isp_depth_fin, the cull,
//   the row range) turns into the descriptor p2_rdesc_t. A MODIFIER triangle has the triangle's arithmetic (its depth is
//   compared too); it differs in the fixed logic only (no row range, the kill descriptor).
//
// Modes:
//   gen_setup_prog [params] --sv <file> --hdr <file> [--report <file>]
//        schedules the three graphs on the ALU (the list scheduler below) and writes the microprogram package
//        rtl/v1/pkg/p2_isp_prog_pkg.sv (GENERATED), the testbench's copy of the schedule (a C++ header, for the program
//        consistency check of PLAN M4 item 3) and a readable report (every step, every unit)
//   gen_setup_prog [params] --sweep
//        the program lengths over a grid of the free parameters (ISP_NM, ISP_NA, L_MUL, L_ADD, L_RCP: ARCHITECTURE 6),
//        and which of them give the measured 16 (triangle) and 19 (sprite) [M tim 3.2]
//   gen_setup_prog --check [--n N] [--seed S] [--vec <dir>] [--threads T]
//        THE GRAPH CHECK (PLAN M4 item 1): every graph evaluated with pvr_softfp, its outputs against refsw3's own values
//        (tb/isp_setup/ref_copies_setup.h, verbatim copies; EdgeWinding) on N random primitives (1M by default) and on
//        every directed primitive: the literals below and every record of <dir>/*.trz (the console pages' primitives,
//        tools/gate/tria_extract.sh). Ends "graph-check: PASS" / "FAIL".
// params: --nm N --na N --lm N --la N --lr N (defaults: the ARCHITECTURE 6 values, kDefault below).
//
// The scheduler: nodes are issued in list order of their priority (the longest latency-weighted path from the node to
// the hand-off, then the node's place in the graph), at most ISP_NM multiplies, ISP_NA additions and one reciprocal a
// step, a node when its operands are readable (issued at s with latency L: readable from step s + L). Every value has its
// own register (the graph is single-assignment). The program's length is (the step all outputs are readable at) + 1:
// that last step is the hand-off write (ARCHITECTURE 3.4.4 Cycle), the step a culled or bad primitive skips. The
// determinant the cull reads must be readable one step earlier (checked).
#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <map>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

#include "p2tb.h"
#include "pvr_isp_depth.h"
#include "pvr_isp_edge.h"
#include "ref_copies_setup.h"
#include "triz_rec.h"

using pvrfp::Fp;

namespace {

// ---------------------------------------------------------------------------------------------------------------
// the graph
enum Cls { C_TRI = 0, C_QUAD = 1, C_MOD = 2, C_N = 3 };
static const char* const kClsName[C_N] = {"TRI", "QUAD", "MOD"};

enum Kind { K_IN, K_MUL, K_ADD, K_RCP };
// operations, as p2_isp_alu's units have them (the codes are the package's)
enum Op {
    O_IN,
    MUL_E,     // Mul(a, b, productBits), then the swamp at 2^128 (the edge unit: pvr_isp_edge.h)
    MUL_R,     // the depth setup's ranged `mul` (pvr_isp_depth.h L362-368)
    MUL_U,     // Mul(a, b, coefBits), unranged (A, B: L659-660)
    ADD_E,     // Add(a, +-b, sumBits, reach), plain (the edge unit), with a post-operation (swamp, saturation)
    ADD_Z,     // the depth setup's `addRule` with the zero rule (add, subC, addE: every switch is 1 in DepthHW)
    ADD_M1,    // the mean's first sum, addBad with the corners' fractions (L648-651)
    ADD_M2,    // the mean's second sum, addBad with a fraction 0 against the third corner's
    RCP        // Recip(a, recipBits)
};
enum Post { PO_NONE = 0, PO_SW = 1, PO_SAT = 2, PO_PERP = 3 };

struct Node {
    std::string name;
    Op op = O_IN;
    int a = -1, b = -1;
    bool sub = false, swa = false, swb = false;   // b negated; a swamp on reading a / b (edge: dxP = sw(dx))
    Post post = PO_NONE;
};

static Kind KindOf(Op o)
{
    switch (o) {
    case O_IN: return K_IN;
    case MUL_E: case MUL_R: case MUL_U: return K_MUL;
    case RCP: return K_RCP;
    default: return K_ADD;
    }
}

struct Graph {
    Cls cls = C_TRI;
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
            // a shared value (the edge products of the determinant and of c): the same operation on the same operands
            const Node& o = n[h];
            if (o.op != v.op || o.a != v.a || o.b != v.b || o.sub != v.sub || o.swa != v.swa || o.post != v.post) {
                fprintf(stderr, "gen_setup_prog: two different values named %s\n", v.name.c_str());
                exit(2);
            }
            return h;
        }
        n.push_back(v);
        idx[v.name] = (int)n.size() - 1;
        return (int)n.size() - 1;
    }
    int in(const std::string& s)
    {
        Node v;
        v.name = s;
        return put(v);
    }
    int mul(const std::string& s, Op op, int a, int b, bool swa = false)
    {
        Node v;
        v.name = s; v.op = op; v.a = a; v.b = b; v.swa = swa;
        return put(v);
    }
    int add(const std::string& s, Op op, int a, int b, bool sub, Post post = PO_NONE)
    {
        Node v;
        v.name = s; v.op = op; v.a = a; v.b = b; v.sub = sub; v.post = post;
        return put(v);
    }
    int rcp(const std::string& s, int a)
    {
        Node v;
        v.name = s; v.op = RCP; v.a = a;
        return put(v);
    }
    void out(int k) { outputs.push_back(k); }
};

static std::string S(const char* p, int k) { return std::string(p) + std::to_string(k); }
static std::string S2(const char* p, int j, int k) { return std::string(p) + std::to_string(j) + std::to_string(k); }

// The operation graph of one class (refsw3 4f3efe15). Corners in rasterizer order, 0-based; the inputs are the setup's
// input registers: EX, EY the corners as FromBits (num H4: the edge unit), ZX, ZY, ZZ the first three as
// FromSingle(., ranged) (the depth unit), TX, TY the tile's first sample point FromHalves(2 left + HALF_OFFSET[0]) (the
// same point for both units: refsw_tile.cpp L797-798, L809-813), THIRD the constant OneThird() (0xAAAAAB 2^-25).
Graph Build(Cls cls)
{
    Graph g;
    g.cls = cls;
    const bool quad = cls == C_QUAD;
    int EX[4], EY[4], ZX[3], ZY[3], ZZ[3];
    for (int k = 0; k < 4; k++) {
        EX[k] = g.in(S("EX", k));
        EY[k] = g.in(S("EY", k));
    }
    for (int k = 0; k < 3; k++) {
        ZX[k] = g.in(S("ZX", k));
        ZY[k] = g.in(S("ZY", k));
        ZZ[k] = g.in(S("ZZ", k));
    }
    const int TX = g.in("TX"), TY = g.in("TY"), THIRD = g.in("THIRD");

    // ---- the edge unit (pvr_isp_edge.h): swamped products x_j y_k, shared by EdgeWinding's e(j, k) and the edges' c
    auto pe = [&](int j, int k) { return g.mul(S2("pe", j, k), MUL_E, EX[j], EY[k]); };
    // EdgeWinding: e(j, k) = sw(Sub(sw(x_j y_k), sw(x_k y_j))), e1 = e(1, 2), e2 = e(2, 0), e3 = e(0, 1);
    // det = sw(Add(sw(Add(e1, e2)), e3)) [faredge_m131, faredge_cull: the swamped determinant]
    int ee[3];
    for (int q = 0; q < 3; q++) {
        const int J = (q + 1) % 3, K = (q + 2) % 3;
        ee[q] = g.add(S("ee", q), ADD_E, pe(J, K), pe(K, J), true, PO_SW);
    }
    const int d12 = g.add("dete12", ADD_E, ee[0], ee[1], false, PO_SW);
    g.out(g.add("detE", ADD_E, d12, ee[2], false, PO_SW));
    // the edges a -> b: E12, E23, E31 (3 -> 1, or 3 -> 4 for a quad), E41 (quads) (refsw_tile.cpp L800-804)
    const int nE = quad ? 4 : 3;
    for (int k = 0; k < nE; k++) {
        const int a = k, b = k == 2 ? (quad ? 3 : 0) : (k + 1) % 4;
        // c = sw(Sub(sw(xb ya), sw(xa yb))) (L184-185)
        const int c = g.add(S("c", k), ADD_E, pe(b, a), pe(a, b), true, PO_SW);
        // dx = Sub(xa, xb), dy = Sub(ya, yb) (L191): read as dxP = sw(dx) by the start's products; saturated for the
        // steps by p2_isp_edge_steps (fixed logic)
        const int dx = g.add(S("dx", k), ADD_E, EX[a], EX[b], true);
        const int dy = g.add(S("dy", k), ADD_E, EY[a], EY[b], true);
        // first = sw(Add(sw(dxP y0), -sw(dyP x0))) (L197); start = sat(Add(first, c)) (L198-200)
        const int q0 = g.mul(S("fy", k), MUL_E, dx, TY, true);
        const int q1 = g.mul(S("fx", k), MUL_E, dy, TX, true);
        const int first = g.add(S("first", k), ADD_E, q0, q1, true, PO_SW);
        g.out(dx);
        g.out(dy);
        g.out(g.add(S("start", k), ADD_E, first, c, false, PO_SAT));
    }

    // ---- the depth unit (pvr_isp_depth.h DepthTileT::Setup at 4f3efe15), its own ranged products: not the edge
    // unit's (isp 6.2, 9.2; the inputs are FromSingle(., ranged), and the products are limited)
    auto pz = [&](int j, int k) { return g.mul(S2("pz", j, k), MUL_R, ZX[j], ZY[k]); };
    int ze[3], ta[3], tb[3], tc[3];
    for (int q = 0; q < 3; q++) {
        const int J = (q + 1) % 3, K = (q + 2) % 3;
        // edge(j, k) = addE(mul(X_j, Y_k), -mul(X_k, Y_j)) (L417): e1 = edge(1, 2), e2 = edge(2, 0), e3 = edge(0, 1)
        ze[q] = g.add(S("ze", q), ADD_Z, pz(J, K), pz(K, J), true);
    }
    for (int q = 0; q < 3; q++) {
        const int J = (q + 1) % 3, K = (q + 2) % 3;
        // a's terms mul(Z_q, subC(Y_J, Y_K)), b's mul(Z_q, subC(X_K, X_J)), c's mul(Z_q, e_q) (L419-421)
        const int dyz = g.add(S("dyz", q), ADD_Z, ZY[J], ZY[K], true);
        const int dxz = g.add(S("dxz", q), ADD_Z, ZX[K], ZX[J], true);
        ta[q] = g.mul(S("ta", q), MUL_R, ZZ[q], dyz);
        tb[q] = g.mul(S("tb", q), MUL_R, ZZ[q], dxz);
        tc[q] = g.mul(S("tc", q), MUL_R, ZZ[q], ze[q]);
    }
    // a = (t1 + t2) + t3, b likewise, c = (t1 + t3) + t2 (sum3: zmeas item 1; zovf_sum)
    const int a12 = g.add("za12", ADD_Z, ta[0], ta[1], false);
    const int za = g.add("za", ADD_Z, a12, ta[2], false);
    const int b12 = g.add("zb12", ADD_Z, tb[0], tb[1], false);
    const int zb = g.add("zb", ADD_Z, b12, tb[2], false);
    const int c13 = g.add("zc13", ADD_Z, tc[0], tc[2], false);
    const int zc = g.add("zc", ADD_Z, c13, tc[1], false);
    // det = addE(addE(e1, e2), e3), then Perpendicular (FPU_PERP_VAL) (L423-426)
    const int dz12 = g.add("detz12", ADD_Z, ze[0], ze[1], false);
    const int detZ = g.add("detZ", ADD_Z, dz12, ze[2], false, PO_PERP);
    // inv0 = Recip(det); first0 = mul(add(add(mul(a, x00), mul(b, y00)), c), inv0) (L470-472)
    const int inv0 = g.rcp("inv0", detZ);
    const int ax = g.mul("zax", MUL_R, za, TX);
    const int by = g.mul("zby", MUL_R, zb, TY);
    const int sab = g.add("zsab", ADD_Z, ax, by, false);
    const int sabc = g.add("zsabc", ADD_Z, sab, zc, false);
    const int first0 = g.mul("zfirst0", MUL_R, sabc, inv0);
    // A = Mul(a, inv, coefBits), B likewise (L658-660; refsw3's inv and invS are inv0's value)
    const int A = g.mul("Araw", MUL_U, za, inv0);
    const int B = g.mul("Braw", MUL_U, zb, inv0);
    // the determinant-zero mean: mul(addBad(addBad(Z0, f0, Z1, f1), 0, Z2, f2), third) (L646-653)
    const int m12 = g.add("zm12", ADD_M1, ZZ[0], ZZ[1], false);
    const int msum = g.add("zmsum", ADD_M2, m12, ZZ[2], false);
    const int mean = g.mul("zmean", MUL_R, msum, THIRD);
    for (int v : {za, zb, zc, detZ, first0, A, B, mean})
        g.out(v);
    return g;
}

// ---------------------------------------------------------------------------------------------------------------
// evaluation with pvr_softfp: the operations as refsw3 writes them
struct Eval {
    static const pvrisp::EdgeHW& ecfg() { static const pvrisp::EdgeHW c; return c; }
    static const pvrisp::DepthHW& dcfg() { static const pvrisp::DepthHW c; return c; }
    static Fp inf(bool neg) { Fp r; r.bad = true; r.neg = neg; return r; }
    static Fp zero(bool neg) { Fp r; r.neg = neg; return r; }
    static Fp swamp(const Fp& v)
    {
        const int OE = ecfg().overflowExp;
        return v.atLeastPow2(OE) ? Fp::Pow2(OE + 72, v.neg) : v;
    }
    static Fp limit(const Fp& r, bool sumSign)
    {
        if (r.zero()) return r;
        if (r.top() - 1 > 127) return inf(r.neg);
        if (r.top() - 1 < -126) return zero(sumSign ? false : r.neg);
        return r;
    }
    static Fp zmul(const Fp& p, const Fp& q)
    {
        if (p.bad || q.bad) {
            const Fp& other = p.bad ? q : p;
            return (!other.bad && other.zero()) ? zero(p.neg != q.neg) : inf(p.neg != q.neg);
        }
        return limit(pvrfp::Mul(p, q, dcfg().productBits), false);
    }
    static Fp zadd(const Fp& p, const Fp& q)
    {
        if (p.bad || q.bad) {
            if (p.bad && q.bad && p.neg != q.neg) return zero(false);
            return inf(p.bad ? p.neg : q.neg);
        }
        if (p.zero() != q.zero()) {
            const Fp& v = p.zero() ? q : p;
            const bool zneg = p.zero() ? p.neg : q.neg;
            const int n = Fp::Bits(v.mant);
            if (v.top() - 1 == -126 && zneg != v.neg && !((v.mant >> (n - 2)) & 1))
                return zero(false);
        }
        Fp r = limit(pvrfp::Add(p, q, dcfg().sumBits, dcfg().reach), true);
        if (!r.bad && r.zero())
            r.neg = false;
        return r;
    }
    static Fp addBad(const Fp& p, uint32_t pf, const Fp& q, uint32_t qf)
    {
        if (p.bad && q.bad && p.neg != q.neg && pf != qf)
            return inf(pf > qf ? p.neg : q.neg);
        return zadd(p, q);
    }

    // one node; v holds the values of the nodes before it; frac[3] the corners' depth fractions (exponent field 255)
    static Fp Op1(const Node& n, const std::vector<Fp>& v, const uint32_t frac[3])
    {
        const auto& E = ecfg();
        Fp a = n.a >= 0 ? v[n.a] : Fp(), b = n.b >= 0 ? v[n.b] : Fp();
        if (n.swa) a = swamp(a);
        if (n.swb) b = swamp(b);
        Fp r;
        switch (n.op) {
        case MUL_E: return swamp(pvrfp::Mul(a, b, E.productBits));
        case MUL_R: return zmul(a, b);
        case MUL_U: return pvrfp::Mul(a, b, dcfg().coefBits);
        case RCP:
            // refsw3 takes the reciprocal of a determinant that is neither zero nor bad (DepthTileT::Setup L470, L658);
            // of the others p2_fp_recip24 makes some value no regime reads (p2_isp_depth_fin)
            return (a.zero() || a.bad) ? Fp() : pvrfp::Recip(a, dcfg().recipBits);
        case ADD_E:
            r = pvrfp::Add(a, n.sub ? -b : b, E.sumBits, E.reach);
            if (n.post == PO_SW)
                r = swamp(r);
            else if (n.post == PO_SAT && r.atLeastPow2(E.overflowExp))
                r = Fp::Pow2(E.saturateExp, r.neg);
            return r;
        case ADD_Z:
            r = zadd(a, n.sub ? -b : b);
            if (n.post == PO_PERP && pvrfp::Perpendicular(r))
                r = Fp();
            return r;
        case ADD_M1: return addBad(a, frac[0], b, frac[1]);
        case ADD_M2: return addBad(a, 0, b, frac[2]);
        default: return Fp();
        }
    }
};

// one (primitive, tile) job of the check
struct Prim {
    uint32_t x[4] = {}, y[4] = {}, z[3] = {};
    bool quad = false, modvol = false, half = true;
    int tileX = 0, tileY = 0;
    uint32_t perp = 0;
};

// the input registers' values, as p2_isp_setup loads them
static void Inputs(const Graph& g, const Prim& p, std::vector<Fp>& v, uint32_t frac[3])
{
    v.assign(g.n.size(), Fp());
    for (int k = 0; k < 4; k++) {
        const bool here = k < 3 || p.quad;
        v[g.find(S("EX", k))] = here ? Fp::FromBits(p.x[k]) : Fp();
        v[g.find(S("EY", k))] = here ? Fp::FromBits(p.y[k]) : Fp();
    }
    for (int k = 0; k < 3; k++) {
        v[g.find(S("ZX", k))] = Fp::FromSingle(p.x[k], true);
        v[g.find(S("ZY", k))] = Fp::FromSingle(p.y[k], true);
        v[g.find(S("ZZ", k))] = Fp::FromSingle(p.z[k], true);
        frac[k] = ((p.z[k] >> 23) & 0xff) == 255 ? p.z[k] & 0x7fffffu : 0u;
    }
    const int64_t hb = p.half ? 1 : 0;
    v[g.find("TX")] = Fp::FromHalves(2 * 32 * (int64_t)p.tileX + hb);
    v[g.find("TY")] = Fp::FromHalves(2 * 32 * (int64_t)p.tileY + hb);
    v[g.find("THIRD")] = pvrfp::OneThird();
}

static void Run(const Graph& g, const Prim& p, std::vector<Fp>& v)
{
    uint32_t frac[3];
    Inputs(g, p, v, frac);
    for (size_t k = 0; k < g.n.size(); k++)
        if (g.n[k].op != O_IN)
            v[k] = Eval::Op1(g.n[k], v, frac);
}

// the tuple equality of the RTL's comparisons (num 1.3): neg, bad, mant, and exp when mant != 0
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
// the graph check
// returns the number of outputs that differ; the first few printed by the caller's thread under a lock-free counter
static int CheckOne(const Graph& g, const Prim& p, std::string* why)
{
    const auto& ecfg = Eval::ecfg();
    const auto& dcfg = Eval::dcfg();
    pvrfp::perpVal = Fp::FromBits(p.perp & 0x7fffffffu);
    std::vector<Fp> v;
    Run(g, p, v);
    int bad = 0;
    auto cmp = [&](const char* name, const Fp& got, const Fp& want) {
        if (Same(got, want))
            return;
        bad++;
        if (why && why->size() < 400)
            *why += std::string(" ") + name + " graph " + Str(got) + " refsw3 " + Str(want);
    };
    // the edge unit
    const Fp FX[4] = {Fp::FromBits(p.x[0]), Fp::FromBits(p.x[1]), Fp::FromBits(p.x[2]), p.quad ? Fp::FromBits(p.x[3]) : Fp()};
    const Fp FY[4] = {Fp::FromBits(p.y[0]), Fp::FromBits(p.y[1]), Fp::FromBits(p.y[2]), p.quad ? Fp::FromBits(p.y[3]) : Fp()};
    Fp det;
    pvrisp::EdgeWinding(FX, FY, ecfg, &det);
    cmp("detE", v[g.find("detE")], det);
    const int64_t hb = p.half ? 1 : 0;
    const int64_t x0h = 2 * 32 * (int64_t)p.tileX + hb, y0h = 2 * 32 * (int64_t)p.tileY + hb;
    const int nE = p.quad ? 4 : 3;
    for (int k = 0; k < nE; k++) {
        const int a = k, b = k == 2 ? (p.quad ? 3 : 0) : (k + 1) % 4;
        const p2setupref::EdgeVals e = p2setupref::EdgeStart(FX[a], FY[a], FX[b], FY[b], x0h, y0h, ecfg);
        cmp(S("dx", k).c_str(), v[g.find(S("dx", k))], e.dx);
        cmp(S("dy", k).c_str(), v[g.find(S("dy", k))], e.dy);
        cmp(S("start", k).c_str(), v[g.find(S("start", k))], e.start);
    }
    // the depth unit
    const p2setupref::DepthVals d = p2setupref::DepthValues(p.x, p.y, p.z, 32 * p.tileX, 32 * p.tileY, dcfg, p.half);
    cmp("a", v[g.find("za")], d.a);
    cmp("b", v[g.find("zb")], d.b);
    cmp("c", v[g.find("zc")], d.c);
    cmp("detZ", v[g.find("detZ")], d.det);
    if (d.haveFirst0)
        cmp("first0", v[g.find("zfirst0")], d.first0);
    cmp("mean", v[g.find("zmean")], d.mean);
    if (d.haveFirst0) {
        cmp("A", v[g.find("Araw")], d.A);
        cmp("B", v[g.find("Braw")], d.B);
    }
    return bad;
}

static uint32_t fb(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float bf(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

// random primitives: the coordinate classes of tb/isp_edge (grid, ulp-perturbed, huge, denormal, far, slivers, points)
// and the depth classes of tb/isp_depth (starts near zero, near 2^-126, 2^126 .. 2^128, infinities and NaNs, any word)
static float RndCoord(p2tb::Rng& r)
{
    switch (r.below(10)) {
    case 0: return (float)r.below(2048) * 0.5f + (float)r.below(16) / 16.0f;
    case 1: return bf(fb((float)r.below(1280)) + (uint32_t)r.range(-12, 12));
    case 2: return ldexpf((float)r.below(0xffffff), (int)r.range(-40, 19)) * (r.below(2) ? -1 : 1);
    case 3: return (float)r.below(640) + ldexpf((float)r.below(1000), -(int)r.below(30));
    case 4: return ldexpf(1.0f + r.below(1000) / 1000.0f, (int)r.below(128)) * (r.below(2) ? -1 : 1);
    case 5: return ldexpf(1.0f + r.below(0x800000) / 8388608.0f, 118 + (int)r.below(10)) * (r.below(2) ? -1 : 1);
    case 6: return bf((uint32_t)r.below(0x800000) | (r.below(2) ? 0x80000000u : 0));     // a denormal or a zero
    case 7: return ldexpf(1.0f + (float)r.below(5) / 8.0f, -126) * (r.below(2) ? -1 : 1);
    case 8: return ldexpf(1.0f + r.below(0x800000) / 8388608.0f, 58 + (int)r.below(8)) * (r.below(2) ? -1 : 1);
    default: return (float)((int)r.below(4000) - 2000) / 7.0f;
    }
}
static uint32_t RndDepth(p2tb::Rng& r)
{
    auto frac = [&](int den) { return (float)r.below((uint64_t)den) / (float)den; };
    auto sgn = [&]() { return r.below(2) ? -1.0f : 1.0f; };
    switch (r.below(11)) {
    case 0: return fb(ldexpf(1.0f + frac(100000), (int)r.below(40) - 20) * (r.below(3) ? 1.0f : -1.0f));
    case 1: return fb(0.5f + r.below(1000) * 1e-6f);
    case 2: return fb(ldexpf((float)r.below(0xffffff), -(int)r.below(60)) * sgn());
    case 3: return fb((float)r.below(1000) / 997.0f - 0.3f);
    case 4: return fb(ldexpf(1.0f + frac(1 << 23), -126 + (int)r.below(4)) * sgn());
    case 5: return fb(ldexpf(1.0f + frac(1 << 23), 100 + (int)r.below(28)) * sgn());
    case 6: return r.below(2) ? 0u : 0x80000000u;
    case 7: return r.u32();
    case 8: return fb(-ldexpf(1.0f + frac(1000), (int)r.below(20)));
    case 9: { const uint32_t s[8] = {0x7f800000u, 0xff800000u, 0x7f7fffffu, 0xff7fffffu, 0x7f000000u, 0xff000000u,
                                      0x7fc00000u, 0xffc00001u};
              return s[r.below(8)]; }
    default: return fb(ldexpf(1.0f + frac(1 << 23), 124 + (int)r.below(4)) * sgn());
    }
}
static Prim RandomPrim(p2tb::Rng& r)
{
    Prim p;
    p.tileX = (int)r.below(64);
    p.tileY = (int)r.below(64);
    p.half = r.below(2);
    p.quad = r.below(4) == 0;
    p.perp = r.below(10) == 0 ? 0x3c000000u : r.below(30) == 0 ? r.u32() : 0;
    const float cx = 32.0f * p.tileX, cy = 32.0f * p.tileY;
    const int cls = (int)r.below(8);
    for (int k = 0; k < 4; k++) {
        float x, y;
        switch (cls) {
        case 0: x = cx + (float)r.range(-24, 56) + r.below(16) / 16.0f; y = cy + (float)r.range(-24, 56) + r.below(16) / 16.0f; break;
        case 1: x = bf(fb(cx + (float)r.range(-8, 40) + 0.5f) + (uint32_t)r.range(-12, 12));
                y = bf(fb(cy + (float)r.range(-8, 40) + 0.5f) + (uint32_t)r.range(-12, 12)); break;
        case 2: x = cx + (float)r.range(-300, 300) + r.below(256) / 256.0f; y = cy + (float)r.range(-300, 300) + r.below(256) / 256.0f; break;
        case 3: x = (float)r.below(4) * (r.below(2) ? 1 : -1) * ldexpf(1.0f, -126 + (int)r.below(2)); y = (float)r.below(3); break;
        default: x = RndCoord(r); y = RndCoord(r); break;
        }
        p.x[k] = fb(x);
        p.y[k] = fb(y);
    }
    if (r.below(12) == 0)
        (r.below(2) ? p.x : p.y)[r.below(4)] = r.below(2) ? 0x7f800000u | (uint32_t)r.below(4) : 0xff800000u;
    if (r.below(30) == 0) {           // determinant zero
        p.x[2] = p.x[0];
        p.y[2] = p.y[0];
    }
    if (r.below(16) == 0) {           // a determinant near 2^126: legs about 2^63
        const float L = ldexpf(1.0f + r.below(64) / 64.0f, 62 + (int)r.below(3)), M = ldexpf(1.0f, 63) * (r.below(2) ? 1.0f : 0.999f);
        p.x[1] = fb(bf(p.x[0]) + L);
        p.y[1] = p.y[0];
        p.x[2] = p.x[0];
        p.y[2] = fb(bf(p.y[0]) + M);
    }
    for (int k = 0; k < 3; k++)
        p.z[k] = RndDepth(r);
    if (r.below(3) == 0)
        p.z[1] = fb(bf(p.z[0]) + ldexpf((float)((int)r.below(2001) - 1000), -(int)r.below(40)));
    return p;
}

// literal primitives (directed): bad corners, determinants of exactly 2^126 and zero, perpendicular ones, infinite and
// NaN depths, far corners, a point
static std::vector<Prim> Literals()
{
    std::vector<Prim> v;
    auto tri = [&](float x0, float y0, float x1, float y1, float x2, float y2, uint32_t z0, uint32_t z1, uint32_t z2) {
        Prim p;
        p.x[0] = fb(x0); p.y[0] = fb(y0); p.x[1] = fb(x1); p.y[1] = fb(y1); p.x[2] = fb(x2); p.y[2] = fb(y2);
        p.z[0] = z0; p.z[1] = z1; p.z[2] = z2;
        for (int h = 0; h < 2; h++)
            for (int t = 0; t < 3; t++) {
                Prim q = p;
                q.half = h;
                q.tileX = t * 7;
                q.tileY = t * 3;
                v.push_back(q);
                q.quad = true;
                q.x[3] = fb(x2 + 3);
                q.y[3] = fb(y0 + 5);
                v.push_back(q);
            }
    };
    const uint32_t one = 0x3f800000u, inf = 0x7f800000u, ninf = 0xff800000u, nan = 0x7fc00000u;
    const float t63 = ldexpf(1.0f, 63);
    tri(0, 0, 8, 0, 0, 8, one, one, one);                                  // ordinary
    tri(0, 0, t63, 0, 0, t63, one, one, one);                              // det exactly 2^126
    tri(0, 0, t63, 0, 0, t63 * 2, one, one, one);                          // det 2^127
    tri(0, 0, ldexpf(1, 64), 0, 0, ldexpf(1, 64), one, one, one);          // det 2^128: infinite
    tri(5, 5, 5, 5, 5, 5, one, 0x40000000u, 0x40400000u);                  // a point: det 0, the mean
    tri(1, 1, 9, 9, 17, 17, inf, ninf, one);                               // det 0, infinite corners
    tri(1, 1, 9, 9, 17, 17, nan, 0xff800001u, one);                        // the fractions decide
    tri(0, 0, 8, 0, 0, 8, inf, one, one);                                  // REG
    tri(0, 0, bf(0x7f800000u), 0, 0, 8, one, one, one);                    // a bad corner
    tri(0, 0, ldexpf(1, 127), 3, 2, ldexpf(1, 126), one, one, one);        // far corners: swamps
    tri(-ldexpf(1, 127), 0, ldexpf(1, 127), 1, 0, 2, one, one, one);       // dx 2^128: saturated steps
    tri(bf(0x00000001u), 0, 0, bf(0x80000001u), 1, 1, one, one, one);      // denormals
    tri(0, 0, ldexpf(1.25f, -126), 0, 0, 1, fb(ldexpf(1, 126)), inf, one); // zcoord
    {
        Prim p;
        p.x[0] = fb(0); p.y[0] = fb(0); p.x[1] = fb(64); p.y[1] = fb(0.001f); p.x[2] = fb(0.001f); p.y[2] = fb(64);
        p.z[0] = p.z[1] = p.z[2] = one;
        p.perp = 0x3f400000u;                                            // FPU_PERP_VAL 0.75: not perpendicular
        v.push_back(p);
        p.perp = 0x4a800000u;                                            // 2^22: perpendicular
        v.push_back(p);
    }
    return v;
}

static std::vector<std::string> ListTrz(const std::string& dir)
{
    std::vector<std::string> out;
    if (DIR* d = opendir(dir.c_str())) {
        while (dirent* e = readdir(d)) {
            const std::string n = e->d_name;
            if (n.size() > 4 && n.compare(n.size() - 4, 4, ".trz") == 0)
                out.push_back(dir + "/" + n);
        }
        closedir(d);
    }
    std::sort(out.begin(), out.end());
    return out;
}

int GraphCheck(uint64_t n, uint64_t seed, const std::string& vecDir, int threads)
{
    Graph G[C_N];
    for (int c = 0; c < C_N; c++)
        G[c] = Build((Cls)c);
    std::vector<Prim> directed = Literals();
    const size_t nLit = directed.size();
    long recs = 0, files = 0;
    for (const std::string& f : ListTrz(vecDir)) {
        std::vector<uint8_t> raw;
        uint64_t cnt = 0;
        if (!p2tb::VecFile::read(f, p2tri::kTriZMagic, sizeof(p2tri::TriZRec), &raw, &cnt)) {
            printf("graph-check: cannot read %s\n", f.c_str());
            return 1;
        }
        files++;
        for (uint64_t r = 0; r < cnt; r++) {
            p2tri::TriZRec q;
            memcpy(&q, raw.data() + r * sizeof q, sizeof q);
            Prim p;
            for (int k = 0; k < 3; k++) {
                p.x[k] = q.x[k]; p.y[k] = q.y[k]; p.z[k] = q.z[k];
            }
            p.half = q.halfOffset & 1;
            p.perp = q.perpVal;
            p.tileX = q.tileX;
            p.tileY = q.tileY;
            p.modvol = q.modvol;
            // a quad's record has no corner 4 (the TRIA line): its three corners as a triangle (the depth and three edges)
            directed.push_back(p);
            recs++;
        }
    }
    // processes, not threads: pvr_softfp's Perpendicular reads the global pvrfp::perpVal (FPU_PERP_VAL), set per job
    const uint64_t total = n + directed.size();
    std::vector<std::pair<pid_t, int>> kids;
    for (int t = 0; t < threads; t++) {
        int fd[2];
        if (pipe(fd) != 0) { perror("pipe"); return 1; }
        fflush(stdout);
        const pid_t pid = fork();
        if (pid == 0) {
            close(fd[0]);
            long jobs = 0, fails = 0, shown = 0;
            std::string why;
            for (uint64_t i = t; i < total; i += threads) {
                Prim p;
                if (i < directed.size())
                    p = directed[i];
                else {
                    p2tb::Rng r = p2tb::Rng::of(seed, i - directed.size());
                    p = RandomPrim(r);
                }
                for (Cls c : {p.quad ? C_QUAD : C_TRI, p.quad ? C_QUAD : C_MOD}) {
                    why.clear();
                    const int bad = CheckOne(G[c], p, &why);
                    jobs++;
                    if (bad) {
                        fails++;
                        if (shown++ < 20 / threads + 1)
                            printf("  FAIL [graph %s] job %" PRIu64 " (%s, tile %d %d, half %d): %d outputs:%s\n",
                                   kClsName[c], i, i < nLit ? "literal" : i < directed.size() ? "console page" : "random",
                                   p.tileX, p.tileY, p.half, bad, why.c_str());
                    }
                }
            }
            fflush(stdout);
            const long res[2] = {jobs, fails};
            if (write(fd[1], res, sizeof res) != (ssize_t)sizeof res) _exit(3);
            _exit(0);
        }
        close(fd[1]);
        kids.push_back({pid, fd[0]});
    }
    long jobs = 0, fails = 0;
    bool lost = false;
    for (auto& k : kids) {
        long res[2] = {0, 0};
        if (read(k.second, res, sizeof res) != (ssize_t)sizeof res) lost = true;
        close(k.second);
        int st = 0;
        waitpid(k.first, &st, 0);
        if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) lost = true;
        jobs += res[0];
        fails += res[1];
    }
    if (lost) {
        printf("graph-check: a worker process died\n");
        fails++;
    }
    printf("graph-check: graphs TRI %zu nodes, QUAD %zu, MOD %zu\n", G[C_TRI].n.size(), G[C_QUAD].n.size(), G[C_MOD].n.size());
    printf("graph-check: %" PRIu64 " random primitives (seed %" PRIu64 "), %zu literals, %ld console-page records from %ld "
           "files in %s; %ld evaluations, %ld failures\n", n, seed, nLit, recs, files, vecDir.c_str(), jobs, fails);
    const bool ok = fails == 0 && files > 0;
    if (files == 0)
        printf("graph-check: no .trz files in %s (make isp-depth-vec)\n", vecDir.c_str());
    printf("graph-check: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// ---------------------------------------------------------------------------------------------------------------
// the list scheduler
struct Params {
    int nm = 3, na = 3, lm = 1, la = 2, lr = 2;
};
// ARCHITECTURE 6: ISP_NM, ISP_NA, L_MUL, L_ADD, L_RCP "chosen so the scheduler gives 16 / 19" (see --sweep and the
// report: docs/ARCHITECTURE.md 3.4.4 records which values this gives)
static const Params kDefault = {3, 3, 1, 2, 2};

struct Sched {
    std::vector<int> issue, slot, ready;    // per node (inputs: issue -1, ready 0)
    int len = 0;                            // program length: the hand-off step + 1
    int detReady = 0;                       // when the cull's determinant is readable
    int lastIssue = 0;
    int nMul = 0, nAdd = 0, nRcp = 0;
};

static int Lat(const Params& P, Op o)
{
    switch (KindOf(o)) {
    case K_MUL: return P.lm;
    case K_ADD: return P.la;
    case K_RCP: return P.lr;
    default: return 0;
    }
}

Sched Schedule(const Graph& g, const Params& P)
{
    const int N = (int)g.n.size();
    Sched s;
    s.issue.assign(N, -1);
    s.slot.assign(N, -1);
    s.ready.assign(N, 0);
    std::vector<std::vector<int>> succ(N);
    for (int k = 0; k < N; k++) {
        if (g.n[k].a >= 0) succ[g.n[k].a].push_back(k);
        if (g.n[k].b >= 0 && g.n[k].b != g.n[k].a) succ[g.n[k].b].push_back(k);
    }
    // priority: the longest latency-weighted path from the node to the hand-off
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
            const Kind kd = KindOf(g.n[k].op);
            (kd == K_MUL ? s.nMul : kd == K_ADD ? s.nAdd : s.nRcp)++;
        }
    std::vector<bool> done(N, false);
    for (int k = 0; k < N; k++)
        if (g.n[k].op == O_IN) done[k] = true;
    for (int t = 0; left > 0; t++) {
        if (t > 1000) { fprintf(stderr, "gen_setup_prog: the scheduler is stuck\n"); exit(2); }
        std::vector<int> cand;
        for (int k = 0; k < N; k++) {
            if (done[k]) continue;
            const Node& v = g.n[k];
            const bool ra = v.a < 0 || (done[v.a] && s.ready[v.a] <= t);
            const bool rb = v.b < 0 || (done[v.b] && s.ready[v.b] <= t);
            if (ra && rb) cand.push_back(k);
        }
        std::stable_sort(cand.begin(), cand.end(), [&](int p, int q) { return prio[p] > prio[q]; });
        int used[4] = {0, 0, 0, 0};
        const int cap[4] = {0, P.nm, P.na, 1};
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
    for (int k : g.outputs) r = std::max(r, s.ready[k]);
    s.len = r + 1;
    s.detReady = s.ready[g.find("detE")];
    return s;
}

// ---------------------------------------------------------------------------------------------------------------
// the register file: one register per value name over all three classes, the inputs first
struct RegMap {
    std::vector<std::string> names;
    std::map<std::string, int> idx;
    int of(const std::string& s) const { return idx.at(s); }
};
RegMap Regs(const Graph* G)
{
    RegMap m;
    for (int c = 0; c < C_N; c++)
        for (const Node& v : G[c].n)
            if (v.op == O_IN && !m.idx.count(v.name)) {
                m.idx[v.name] = (int)m.names.size();
                m.names.push_back(v.name);
            }
    for (int c = 0; c < C_N; c++)
        for (const Node& v : G[c].n)
            if (v.op != O_IN && !m.idx.count(v.name)) {
                m.idx[v.name] = (int)m.names.size();
                m.names.push_back(v.name);
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

static const char* OpCode(Op o)
{
    switch (o) {
    case MUL_E: return "P2_ISP_MUL_E";
    case MUL_R: return "P2_ISP_MUL_R";
    case MUL_U: return "P2_ISP_MUL_U";
    case ADD_E: return "P2_ISP_ADD_E";
    case ADD_Z: return "P2_ISP_ADD_Z";
    case ADD_M1: return "P2_ISP_ADD_M1";
    case ADD_M2: return "P2_ISP_ADD_M2";
    default: return "0";
    }
}
static int OpNum(Op o)
{
    switch (o) {
    case MUL_E: return 0; case MUL_R: return 1; case MUL_U: return 2;
    case ADD_E: return 0; case ADD_Z: return 1; case ADD_M1: return 2; case ADD_M2: return 3;
    default: return 0;
    }
}

struct Built {
    Params P;
    Graph G[C_N];
    Sched Sc[C_N];
    RegMap R;
    int lenMax = 0;
};

Built BuildAll(const Params& P)
{
    Built b;
    b.P = P;
    for (int c = 0; c < C_N; c++) {
        b.G[c] = Build((Cls)c);
        b.Sc[c] = Schedule(b.G[c], P);
        b.lenMax = std::max(b.lenMax, b.Sc[c].len);
    }
    b.R = Regs(b.G);
    return b;
}

void WriteSv(const Built& b, FILE* f, const std::string& cmd)
{
    const Params& P = b.P;
    const int nreg = (int)b.R.names.size();
    const int rw = Clog2(nreg);
    const int pcb = Clog2(b.lenMax + 1);
    fprintf(f, "// GENERATED: do not edit. tools/gen/gen_setup_prog.cpp (%s):\n"
               "// the ISP setup's microprograms, the operation graphs of refsw3's setup arithmetic (TRI, QUAD, MODIFIER TRI)\n"
               "// list-scheduled onto p2_isp_alu (ARCHITECTURE 3.4.4, PLAN M4). Regenerate: make isp-prog; check: make\n"
               "// isp-prog-check.\n//\n"
               "// Per class and step (pc) the micro-word: per multiplier, adder and the reciprocal, an issue with its operation,\n"
               "// operand registers and the register its result goes to (readable L_<unit> steps later). Every value has its own\n"
               "// register; the inputs (P2_ISP_R_EX0 .. P2_ISP_R_THIRD) are loaded when the primitive is accepted. The last step\n"
               "// of a program (P2_ISP_LEN_<class> - 1) issues nothing: it is the hand-off write, the step a culled or bad\n"
               "// primitive skips. The lengths are the scheduler's, never padded: the measured 16 / 19 [M tim 3.2] are a check\n"
               "// on the parameters (ARCHITECTURE 6), reported by gen_setup_prog --sweep.\n", cmd.c_str());
    fprintf(f, "package p2_isp_prog_pkg;\n\n");
    fprintf(f, "  // the free parameters (ARCHITECTURE 6)\n");
    fprintf(f, "  localparam int P2_ISP_NM    = %d;   // multipliers\n", P.nm);
    fprintf(f, "  localparam int P2_ISP_NA    = %d;   // adders\n", P.na);
    fprintf(f, "  localparam int P2_ISP_L_MUL = %d;   // latencies: issued at step s, readable from step s + L\n", P.lm);
    fprintf(f, "  localparam int P2_ISP_L_ADD = %d;\n", P.la);
    fprintf(f, "  localparam int P2_ISP_L_RCP = %d;\n\n", P.lr);
    fprintf(f, "  // the programs' lengths, the hand-off step included (the measured lengths are 16 a triangle and 19 a sprite)\n");
    for (int c = 0; c < C_N; c++)
        fprintf(f, "  localparam int P2_ISP_LEN_%s = %d;\n", kClsName[c], b.Sc[c].len);
    fprintf(f, "  localparam int P2_ISP_PC_BITS = %d;\n", pcb);
    fprintf(f, "  localparam logic [1:0] P2_ISP_CLS_TRI = 2'd0, P2_ISP_CLS_QUAD = 2'd1, P2_ISP_CLS_MOD = 2'd2;\n\n");
    int nin = 0;
    for (const Node& v : b.G[C_QUAD].n)
        if (v.op == O_IN) nin++;
    fprintf(f, "  // the operand registers: the inputs first (loaded at the accept), then one per value\n");
    fprintf(f, "  localparam int P2_ISP_NREG = %d;\n  localparam int P2_ISP_NIN  = %d;\n  localparam int P2_ISP_RW   = %d;\n",
            nreg, nin, rw);
    for (int k = 0; k < nreg; k++)
        fprintf(f, "  localparam logic [P2_ISP_RW-1:0] P2_ISP_R_%s = %d'd%d;\n", Up(b.R.names[k]).c_str(), rw, k);
    fprintf(f, "\n  // operations (p2_isp_alu)\n");
    fprintf(f, "  localparam logic [1:0] P2_ISP_MUL_E = 2'd0;   // Mul 24, swamped at 2^128 (the edge unit)\n");
    fprintf(f, "  localparam logic [1:0] P2_ISP_MUL_R = 2'd1;   // the depth setup's ranged mul\n");
    fprintf(f, "  localparam logic [1:0] P2_ISP_MUL_U = 2'd2;   // Mul 24, unranged (A, B)\n");
    fprintf(f, "  localparam logic [1:0] P2_ISP_ADD_E = 2'd0;   // Add 24 / 25, plain (the edge unit)\n");
    fprintf(f, "  localparam logic [1:0] P2_ISP_ADD_Z = 2'd1;   // the depth setup's addRule, the zero rule on\n");
    fprintf(f, "  localparam logic [1:0] P2_ISP_ADD_M1 = 2'd2;  // the mean's first sum (the corners' fractions)\n");
    fprintf(f, "  localparam logic [1:0] P2_ISP_ADD_M2 = 2'd3;  // the mean's second sum\n");
    fprintf(f, "  localparam logic [1:0] P2_ISP_PO_NONE = 2'd0, P2_ISP_PO_SW = 2'd1, P2_ISP_PO_SAT = 2'd2, P2_ISP_PO_PERP = 2'd3;\n\n");
    fprintf(f, "  typedef struct packed {\n    logic                 v;\n    logic [1:0]           op;\n    logic                 swa;\n"
               "    logic [P2_ISP_RW-1:0] ra;\n    logic [P2_ISP_RW-1:0] rb;\n    logic [P2_ISP_RW-1:0] rd;\n  } p2_isp_mslot_t;\n\n");
    fprintf(f, "  typedef struct packed {\n    logic                 v;\n    logic [1:0]           op;\n    logic                 sub;\n"
               "    logic [1:0]           post;\n    logic [P2_ISP_RW-1:0] ra;\n    logic [P2_ISP_RW-1:0] rb;\n"
               "    logic [P2_ISP_RW-1:0] rd;\n  } p2_isp_aslot_t;\n\n");
    fprintf(f, "  typedef struct packed {\n    logic                 v;\n    logic [P2_ISP_RW-1:0] ra;\n    logic [P2_ISP_RW-1:0] rd;\n"
               "  } p2_isp_rslot_t;\n\n");
    fprintf(f, "  typedef struct packed {\n    p2_isp_mslot_t [P2_ISP_NM-1:0] m;\n    p2_isp_aslot_t [P2_ISP_NA-1:0] a;\n"
               "    p2_isp_rslot_t                 r;\n  } p2_isp_uword_t;\n\n");
    fprintf(f, "  // the microprogram ROM: the micro-word of step pc of class cls (all zero: no issue)\n");
    fprintf(f, "  function automatic p2_isp_uword_t p2_isp_prog(input logic [1:0] cls, input logic [P2_ISP_PC_BITS-1:0] pc);\n");
    fprintf(f, "    p2_isp_uword_t w;\n    w = '0;\n    case (cls)\n");
    for (int c = 0; c < C_N; c++) {
        const Graph& g = b.G[c];
        const Sched& s = b.Sc[c];
        fprintf(f, "      P2_ISP_CLS_%s: begin\n        case (pc)\n", kClsName[c]);
        for (int t = 0; t <= s.lastIssue; t++) {
            std::vector<int> at;
            for (size_t k = 0; k < g.n.size(); k++)
                if (s.issue[k] == t) at.push_back((int)k);
            if (at.empty()) continue;
            fprintf(f, "          %d'd%d: begin\n", pcb, t);
            for (int k : at) {
                const Node& v = g.n[k];
                const Kind kd = KindOf(v.op);
                const int ra = b.R.of(g.n[v.a].name), rd = b.R.of(v.name);
                const int rbv = v.b >= 0 ? b.R.of(g.n[v.b].name) : 0;
                if (kd == K_MUL)
                    fprintf(f, "            w.m[%d] = {1'b1, %s, 1'b%d, %d'd%d, %d'd%d, %d'd%d};   // %s\n", s.slot[k],
                            OpCode(v.op), v.swa, rw, ra, rw, rbv, rw, rd, v.name.c_str());
                else if (kd == K_ADD)
                    fprintf(f, "            w.a[%d] = {1'b1, %s, 1'b%d, 2'd%d, %d'd%d, %d'd%d, %d'd%d};   // %s\n", s.slot[k],
                            OpCode(v.op), v.sub, (int)v.post, rw, ra, rw, rbv, rw, rd, v.name.c_str());
                else
                    fprintf(f, "            w.r = {1'b1, %d'd%d, %d'd%d};   // %s\n", rw, ra, rw, rd, v.name.c_str());
            }
            fprintf(f, "          end\n");
        }
        fprintf(f, "          default: ;\n        endcase\n      end\n");
    }
    fprintf(f, "      default: ;\n    endcase\n    return w;\n  endfunction\n\nendpackage\n");
}

void WriteHdr(const Built& b, FILE* f, const std::string& cmd)
{
    fprintf(f, "// GENERATED: do not edit. tools/gen/gen_setup_prog.cpp (%s): the schedule of the ISP setup's microprograms\n"
               "// for tb/isp_setup's program consistency check (PLAN M4 item 3), from the same run as rtl/v1/pkg/p2_isp_prog_pkg.sv.\n"
               "#pragma once\n\nnamespace p2prog {\n\n", cmd.c_str());
    fprintf(f, "constexpr int kNM = %d, kNA = %d, kLMul = %d, kLAdd = %d, kLRcp = %d;\n", b.P.nm, b.P.na, b.P.lm, b.P.la, b.P.lr);
    fprintf(f, "constexpr int kLen[3] = {%d, %d, %d};   // TRI, QUAD, MOD\n", b.Sc[0].len, b.Sc[1].len, b.Sc[2].len);
    fprintf(f, "constexpr int kNReg = %zu;\n", b.R.names.size());
    fprintf(f, "// unit: 0 multiplier, 1 adder, 2 reciprocal\nstruct Issue { int cls, step, unit, slot, op, sub, post, swa, ra, rb, rd; const char* name; };\n");
    fprintf(f, "static const Issue kIssues[] = {\n");
    long cnt = 0;
    for (int c = 0; c < C_N; c++) {
        const Graph& g = b.G[c];
        const Sched& s = b.Sc[c];
        for (int t = 0; t <= s.lastIssue; t++)
            for (size_t k = 0; k < g.n.size(); k++) {
                if (s.issue[k] != t) continue;
                const Node& v = g.n[k];
                const Kind kd = KindOf(v.op);
                fprintf(f, "    {%d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, \"%s\"},\n", c, t, kd == K_MUL ? 0 : kd == K_ADD ? 1 : 2,
                        s.slot[k], OpNum(v.op), v.sub, (int)v.post, v.swa, b.R.of(g.n[v.a].name),
                        v.b >= 0 ? b.R.of(g.n[v.b].name) : 0, b.R.of(v.name), v.name.c_str());
                cnt++;
            }
    }
    fprintf(f, "};\nconstexpr int kNIssues = %ld;\n\n", cnt);
    fprintf(f, "static const char* const kRegName[] = {\n");
    for (const std::string& s : b.R.names)
        fprintf(f, "    \"%s\",\n", s.c_str());
    fprintf(f, "};\n\n}   // namespace p2prog\n");
}

void WriteReport(const Built& b, FILE* f)
{
    fprintf(f, "ISP setup microprograms: ISP_NM %d, ISP_NA %d, L_MUL %d, L_ADD %d, L_RCP %d; %zu operand registers\n\n", b.P.nm,
            b.P.na, b.P.lm, b.P.la, b.P.lr, b.R.names.size());
    for (int c = 0; c < C_N; c++) {
        const Graph& g = b.G[c];
        const Sched& s = b.Sc[c];
        int cp = 0;
        {
            std::vector<int> rd(g.n.size(), 0);
            for (size_t k = 0; k < g.n.size(); k++) {
                const Node& v = g.n[k];
                if (v.op == O_IN) continue;
                int t = 0;
                if (v.a >= 0) t = std::max(t, rd[v.a]);
                if (v.b >= 0) t = std::max(t, rd[v.b]);
                rd[k] = t + Lat(b.P, v.op);
            }
            for (int k : g.outputs) cp = std::max(cp, rd[k]);
        }
        fprintf(f, "%s: %d multiplies, %d additions, %d reciprocal; length %d (the hand-off at step %d; the critical path alone "
                   "gives %d; the cull's determinant readable at step %d)\n", kClsName[c], s.nMul, s.nAdd, s.nRcp, s.len,
                s.len - 1, cp + 1, s.detReady);
        for (int t = 0; t < s.len; t++) {
            fprintf(f, "  %2d:", t);
            for (size_t k = 0; k < g.n.size(); k++)
                if (s.issue[k] == t) {
                    const Node& v = g.n[k];
                    const Kind kd = KindOf(v.op);
                    fprintf(f, " %c%d:%s", kd == K_MUL ? 'M' : kd == K_ADD ? 'A' : 'R', s.slot[k], v.name.c_str());
                }
            if (t == s.len - 1)
                fprintf(f, " [hand-off]");
            fprintf(f, "\n");
        }
        fprintf(f, "\n");
    }
}

void Sweep(const Params& base)
{
    printf("sweep: TRI / QUAD / MOD lengths (the hand-off step included); measured 16 / 19 / - [M tim 3.2]\n");
    printf("  NM NA LM LA LR   TRI QUAD MOD   (shown: every set with TRI 16 or within 1 clock of 16 / 19, and the base latencies)\n");
    int hits = 0, best = 99;
    for (int nm = 1; nm <= 6; nm++)
        for (int na = 1; na <= 6; na++)
            for (int lm = 1; lm <= 3; lm++)
                for (int la = 1; la <= 3; la++)
                    for (int lr = 1; lr <= 6; lr++) {
                        Params P{nm, na, lm, la, lr};
                        const Built b = BuildAll(P);
                        const bool hit = b.Sc[C_TRI].len == 16 && b.Sc[C_QUAD].len == 19;
                        const int dist = abs(b.Sc[C_TRI].len - 16) + abs(b.Sc[C_QUAD].len - 19);
                        const bool show = hit || dist <= 1 || b.Sc[C_TRI].len == 16 ||
                                          (lm == base.lm && la == base.la && lr == base.lr);
                        if (hit) hits++;
                        if (dist < best) best = dist;
                        if (show)
                            printf("  %2d %2d %2d %2d %2d   %3d %4d %3d%s\n", nm, na, lm, la, lr, b.Sc[C_TRI].len,
                                   b.Sc[C_QUAD].len, b.Sc[C_MOD].len, hit ? "   <- 16 / 19" : b.Sc[C_TRI].len == 16 ? "   <- TRI 16" : "");
                    }
    printf("sweep: %d parameter sets give TRI 16 and QUAD 19; the nearest is %d clocks away (|TRI - 16| + |QUAD - 19|)\n",
           hits, best);
}

}   // namespace

int main(int argc, char** argv)
{
    Params P = kDefault;
    std::string sv, hdr, report, vec = "build/vec";
    bool check = false, sweep = false;
    uint64_t n = 1000000, seed = 1;
    int threads = 8;
    std::string cmd = "gen_setup_prog";
    for (int i = 1; i < argc; i++) {
        const std::string a = argv[i];
        auto val = [&]() -> const char* {
            if (i + 1 >= argc) { fprintf(stderr, "gen_setup_prog: %s needs a value\n", a.c_str()); exit(2); }
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
        else if (a == "--vec") vec = val();
        else if (a == "--threads") threads = atoi(val());
        else { fprintf(stderr, "gen_setup_prog: unknown argument %s\n", a.c_str()); return 2; }
    }
    if (check)
        return GraphCheck(n, seed, vec, std::max(1, threads));
    if (sweep) {
        Sweep(P);
        return 0;
    }
    char pbuf[96];
    snprintf(pbuf, sizeof pbuf, "ISP_NM %d, ISP_NA %d, L_MUL %d, L_ADD %d, L_RCP %d", P.nm, P.na, P.lm, P.la, P.lr);
    cmd = pbuf;
    const Built b = BuildAll(P);
    for (int c = 0; c < C_N; c++)
        if (b.Sc[c].detReady > b.Sc[c].len - 2) {
            fprintf(stderr, "gen_setup_prog: %s: the cull's determinant is readable at step %d, after the last step a culled "
                            "primitive runs (%d)\n", kClsName[c], b.Sc[c].detReady, b.Sc[c].len - 2);
            return 1;
        }
    auto open = [](const std::string& path) {
        FILE* f = fopen(path.c_str(), "w");
        if (!f) { fprintf(stderr, "gen_setup_prog: cannot write %s\n", path.c_str()); exit(1); }
        return f;
    };
    if (!sv.empty()) { FILE* f = open(sv); WriteSv(b, f, cmd); fclose(f); }
    if (!hdr.empty()) { FILE* f = open(hdr); WriteHdr(b, f, cmd); fclose(f); }
    if (!report.empty()) { FILE* f = open(report); WriteReport(b, f); fclose(f); }
    if (sv.empty() && hdr.empty() && report.empty())
        WriteReport(b, stdout);
    printf("gen_setup_prog: %s: TRI %d, QUAD %d, MOD %d\n", cmd.c_str(), b.Sc[C_TRI].len, b.Sc[C_QUAD].len, b.Sc[C_MOD].len);
    return 0;
}

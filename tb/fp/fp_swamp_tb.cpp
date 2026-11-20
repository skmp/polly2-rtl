// fp_swamp_tb.cpp: make fp-swamp. H7a p2_fp_swamp against refcore pvr_isp_edge.h at 708fb8cd (docs/spec/numerics.md
// H7a, 7.3; PLAN M1b): alone, against the `swamp` lambda's rule (top > overflowExp gives Pow2(overflowExp + 72), the
// saturation Pow2(saturateExp)); in place in EdgeWinding (public, its swamped determinant); in place in
// EdgeTile::Setup's start (tb/fp/ref_copies.h p2fpref::edgeStart: L180-197 verbatim): c, dx, dy, dxP, dyP, first, start.
//
// Sections (--only):
//   directed  2^128 exactly (24 bits and 1 bit) and one unit below; the swamp value and two of them; a bad value with a
//             mantissa (the flag goes); in place: two swamped products of one sign cancelling to +0 (faredge_cmax
//             pages 11, 14, 15), a product at exactly 2^128 with the other taking 2^105 (faredge_cmax group A), dx of
//             -2^128 exactly (hugepos a), Mul(2^200, y0 = 0) a zero (the first tile row with HALF_OFFSET 0)
//   exh       every top 116 .. 140 x mantissas {1, 0x800000, 0xFFFFFF, U, N} x both signs x bad, alone
//   winding   random corners (the far class: tops 60 .. 128 so that products reach 2^128, powers of two at exactly
//             2^64, ordinary screen coordinates, denormals, zeros, infinities and NaNs) against EdgeWinding's det
//   start     random finite edges of the far class (steps of 2^123 and more, |far y| near 2^127, x0 = 0 and y0 = 0,
//             both signs, products at exactly 2^128) against the copy
//   stream    all three with random gap clocks
#include <memory>

#include "Vp2_fp_swamp_tb_top.h"
#include "fp_tb.h"
#include "ref_copies.h"
#include "vecgen.h"

using namespace fptb;
typedef Vp2_fp_swamp_tb_top Top;

namespace {

// a field of a packed-array port: integer ports and Verilator's VlWide words
template <class T>
void setField(T& port, int lsb, int width, uint64_t v)
{
    const uint64_t m = width >= 64 ? ~0ull : (1ull << width) - 1;
    port = (T)(((uint64_t)port & ~(m << lsb)) | ((v & m) << lsb));
}
template <std::size_t N>
void setField(VlWide<N>& port, int lsb, int width, uint64_t v)
{
    for (int b = 0; b < width; b++) {
        const int k = lsb + b, w = k / 32, s = k % 32;
        port[w] = (port[w] & ~(1u << s)) | ((uint32_t)((v >> b) & 1) << s);
    }
}
template <class T>
uint64_t getField(const T& port, int lsb, int width)
{
    const uint64_t m = width >= 64 ? ~0ull : (1ull << width) - 1;
    return ((uint64_t)port >> lsb) & m;
}
template <std::size_t N>
uint64_t getField(const VlWide<N>& port, int lsb, int width)
{
    uint64_t v = 0;
    for (int b = 0; b < width; b++) {
        const int k = lsb + b;
        v |= (uint64_t)((port[k / 32] >> (k % 32)) & 1) << b;
    }
    return v;
}

const char* const kStName[7] = {"c", "dx (sat)", "dy (sat)", "dxP", "dyP", "first", "start"};

enum Kind : uint8_t { K_ALONE = 1, K_WIND = 2, K_START = 4 };

struct Case {
    uint8_t kind = 0;
    Fp v;                        // alone
    Fp x[3], y[3];               // EdgeWinding
    Fp xa, ya, xb, yb;           // the start
    int64_t x0h = 0, y0h = 0;

    void drive(Top* t) const
    {
        FP_SET(t, i, v);
        t->x_neg = t->x_bad = t->y_neg = t->y_bad = 0;
        for (int k = 0; k < 3; k++) {
            setField(t->x_neg, k, 1, x[k].neg);
            setField(t->x_bad, k, 1, x[k].bad);
            setField(t->x_exp, 10 * k, 10, efield(x[k].exp));
            setField(t->x_mant, 24 * k, 24, x[k].mant);
            setField(t->y_neg, k, 1, y[k].neg);
            setField(t->y_bad, k, 1, y[k].bad);
            setField(t->y_exp, 10 * k, 10, efield(y[k].exp));
            setField(t->y_mant, 24 * k, 24, y[k].mant);
        }
        const Fp* ex[2] = {&xa, &xb};
        const Fp* ey[2] = {&ya, &yb};
        for (int k = 0; k < 2; k++) {
            setField(t->ex_neg, k, 1, ex[k]->neg);
            setField(t->ex_exp, 10 * k, 10, efield(ex[k]->exp));
            setField(t->ex_mant, 24 * k, 24, ex[k]->mant);
            setField(t->ey_neg, k, 1, ey[k]->neg);
            setField(t->ey_exp, 10 * k, 10, efield(ey[k]->exp));
            setField(t->ey_mant, 24 * k, 24, ey[k]->mant);
        }
        FP_SET(t, x0, Fp::FromHalves(x0h));
        FP_SET(t, y0, Fp::FromHalves(y0h));
    }
    std::string in() const
    {
        std::string s;
        if (kind & K_ALONE)
            s += "v " + str(v) + " ";
        if (kind & K_WIND)
            for (int k = 0; k < 3; k++)
                s += "(" + str(x[k]) + ", " + str(y[k]) + ") ";
        if (kind & K_START)
            s += "a (" + str(xa) + ", " + str(ya) + ") b (" + str(xb) + ", " + str(yb) + ") x0h " +
                 std::to_string(x0h) + " y0h " + std::to_string(y0h);
        return s;
    }
    void check(Top* t, Fails& f) const
    {
        auto what = [&] { return in(); };
        if (kind & K_ALONE) {
            // the lambda's rule (pvr_isp_edge.h L113 / L181; L190-191, L196-197)
            const int OE = pvrisp::EdgeHW::overflowExp;
            const Fp sw = v.atLeastPow2(OE) ? Fp::Pow2(OE + 72, v.neg) : v;
            const Fp sa = v.atLeastPow2(OE) ? Fp::Pow2(pvrisp::EdgeHW::saturateExp, v.neg) : v;
            expectFp(f, "swamp", sw, FP_GET(t, sw), 24, what);
            expectFp(f, "sat", sa, FP_GET(t, sat), 24, what);
        }
        if (kind & K_WIND) {
            Fp det;
            pvrisp::EdgeWinding(x, y, pvrisp::EdgeHW{}, &det);
            expectFp(f, "EdgeWinding det", det, FP_GET(t, det), 24, what);
        }
        if (kind & K_START) {
            const p2fpref::EdgeStart r = p2fpref::edgeStart(xa, ya, xb, yb, x0h, y0h);
            const Fp want[7] = {r.c, r.dx, r.dy, r.dxP, r.dyP, r.first, r.start};
            for (int k = 0; k < 7; k++) {
                const Fp got = fromPort(getField(t->st_neg, k, 1), getField(t->st_bad, k, 1),
                                        getField(t->st_exp, 10 * k, 10), getField(t->st_mant, 24 * k, 24));
                expectFp(f, kStName[k], want[k], got, 24, what);
            }
        }
    }
};

// a coordinate as the TA gives it (FromBits of a single), of one of the classes the edge unit meets
Fp coord(p2tb::Rng& r, bool allowBad)
{
    const uint32_t sgn = (uint32_t)(r.u64() & 1) << 31;
    switch (r.below(allowBad ? 10 : 9)) {
    case 0: case 1: {   // ordinary screen coordinates: 0 .. 2048 with fractions, or exactly on the half-pixel grid
        const uint32_t field = 120 + (uint32_t)r.below(16);
        return Fp::FromBits(sgn | field << 23 | (r.chance(300) ? 0 : (uint32_t)(r.u64() & 0x7fffff)));
    }
    case 2: case 3: {   // the far class: tops 60 .. 128 (products of two reach 2^128 and beyond)
        const uint32_t field = 186 + (uint32_t)r.below(69);
        return Fp::FromBits(sgn | field << 23 | (uint32_t)(r.u64() & 0x7fffff));
    }
    case 4: {           // powers of two and near: products at exactly 2^128, and one unit either side
        const uint32_t field = 190 + (uint32_t)r.below(5);   // 2^63 .. 2^67
        static const uint32_t fr[] = {0, 1, 0x7fffff, 0x400000};
        return Fp::FromBits(sgn | field << 23 | fr[r.below(4)]);
    }
    case 5: {           // steps of 2^123 and more: tops 124 .. 128
        const uint32_t field = 249 + (uint32_t)r.below(6);
        return Fp::FromBits(sgn | field << 23 | (uint32_t)(r.u64() & 0x7fffff));
    }
    case 6:             // zeros, denormals
        return Fp::FromBits(sgn | (r.chance(500) ? 0 : (uint32_t)(r.u64() & 0x7fffff)));
    case 7: {           // any finite word
        const uint32_t w = r.u32();
        return ((w >> 23) & 0xff) == 0xff ? Fp::FromBits(w & 0xbfffffffu) : Fp::FromBits(w);
    }
    case 8: {           // small: fields 1 .. 120
        const uint32_t field = 1 + (uint32_t)r.below(120);
        return Fp::FromBits(sgn | field << 23 | (uint32_t)(r.u64() & 0x7fffff));
    }
    default:            // infinities and NaNs (FromBits: bad, unsigned)
        return Fp::FromBits(sgn | 0x7f800000u | (r.chance(500) ? 0 : (uint32_t)(r.u64() & 0x7fffff)));
    }
}
int64_t halves(p2tb::Rng& r)
{
    if (r.chance(200))
        return r.chance(500) ? 0 : 1;      // the first tile column / row: x0 = 0 (HALF_OFFSET 0) or 0.5
    return (int64_t)r.below(1u << 13);
}

}   // namespace

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!start("fp-swamp", argc, argv, &a))
        return 2;
    Verilated::commandArgs(argc, argv);
    std::unique_ptr<Top> top(new Top);
    Fails f("fp-swamp");
    Lockstep<Top, Case> ls(top.get(), f, a.seed ^ 0x5a3);
    auto alone = [&](const Fp& v) {
        Case c;
        c.kind = K_ALONE;
        c.v = v;
        ls.push(c);
    };
    auto wind = [&](const Fp x0, const Fp y0, const Fp x1, const Fp y1, const Fp x2, const Fp y2) {
        Case c;
        c.kind = K_WIND;
        c.x[0] = x0; c.y[0] = y0; c.x[1] = x1; c.y[1] = y1; c.x[2] = x2; c.y[2] = y2;
        ls.push(c);
    };
    auto edge = [&](const Fp& xa, const Fp& ya, const Fp& xb, const Fp& yb, int64_t x0h, int64_t y0h) {
        Case c;
        c.kind = K_START;
        c.xa = xa; c.ya = ya; c.xb = xb; c.yb = yb;
        c.x0h = x0h; c.y0h = y0h;
        ls.push(c);
    };
    auto fb = [](uint32_t w) { return Fp::FromBits(w); };

    if (a.want("directed")) {
        f.set("directed");
        const uint64_t n0 = ls.cases();
        if (a.mine(0)) {
            for (int s = 0; s < 2; s++) {
                alone(mk(s, false, 128, 1));              // 2^128, one bit: swamped
                alone(mk(s, false, 105, 0x800000));       // 2^128, 24 bits
                alone(mk(s, false, 104, 0xFFFFFF));       // 2^128 - 2^104: kept
                alone(mk(s, false, 127, 1));              // 2^127: kept
                alone(mk(s, false, 200, 1));              // the swamp value: itself
                alone(mk(s, false, 200, 2));              // two of them: swamped again
                alone(mk(s, true, 110, 0xABCDEF));        // a flagged sum past 2^128: unflagged
                alone(mk(s, true, 0, 0));                 // a bad zero: as it is
                alone(mk(s, false, 0, 0));                // zeros
            }
            // faredge_cmax page 11 (c's products 2^128.5 and 2^128.0 of one sign: they cancel exactly, c is +0)
            edge(fb(0x60000000u), fb(0x60000000u), fb(0x60800000u), fb(0x60800000u), 1, 1);
            // a product at exactly 2^128 (2^64 x 2^64) beside one that takes 2^105 from c
            edge(fb(0x5f800000u), fb(0x5f800000u), fb(0x6a000000u), fb(0x3f800000u), 3, 5);
            // hugepos a: dx = -2^128 exactly (xa = 2^127, xb = 2^128 - .. no: xa = -2^127, xb = 2^127)
            edge(fb(0xff000000u), fb(0x42000000u), fb(0x7f000000u), fb(0x42800000u), 33, 65);
            // Mul(2^200, y0 = 0): a zero, not swamped (the first tile row with HALF_OFFSET[0] = 0)
            edge(fb(0xff000000u), fb(0x7f000000u), fb(0x7f000000u), fb(0xff000000u), 0, 0);
            edge(fb(0x7f7fffffu), fb(0x7f7fffffu), fb(0xff7fffffu), fb(0xff7fffffu), 0, 7);
            // EdgeWinding: the swamped products of a sliver to a corner at y 2^127 (faredge_m131 shape)
            wind(fb(0x00000000u), fb(0x00000000u), fb(0x41000000u), fb(0x7f000000u), fb(0x41100000u),
                 fb(0x7f010000u));
            wind(fb(0x7f000000u), fb(0x7f000000u), fb(0xff000000u), fb(0xff000000u), fb(0x7f000000u),
                 fb(0xff000000u));
            wind(fb(0x5f800000u), fb(0x5f800000u), fb(0x5f800000u), fb(0xdf800000u), fb(0x7fc00000u),
                 fb(0x3f800000u));
        }
        sectionDone("fp-swamp", "directed", ls.cases() - n0);
    }
    if (a.want("exh")) {
        f.set("exh");
        const uint64_t n0 = ls.cases();
        uint64_t i = 0;
        for (int tp = 116; tp <= 140; tp++)
            for (int k = 0; k < 64; k++)
                for (int s = 0; s < 2; s++)
                    for (int b = 0; b < 2; b++, i++)
                        if (a.mine(i)) {
                            p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0xe5, i);
                            Gen g(r);
                            static const uint64_t mm[] = {1, 0x800000, 0xFFFFFF};
                            const uint64_t m = k < 3 ? mm[k] : (k & 1) ? g.mantU(24) : g.mantN(24);
                            Fp v = Gen::at(m, tp, s);
                            v.bad = b;
                            alone(v);
                        }
        sectionDone("fp-swamp", "exh", ls.cases() - n0);
    }
    if (a.want("winding")) {
        f.set("winding");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 20000000 : 300000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x3d, i);
                Fp c[6];
                for (Fp& v : c)
                    v = coord(r, r.chance(100));
                if (r.chance(200))
                    c[4] = c[0], c[5] = c[1];          // a repeated corner
                wind(c[0], c[1], c[2], c[3], c[4], c[5]);
            }
        sectionDone("fp-swamp", "winding", ls.cases() - n0);
    }
    if (a.want("start")) {
        f.set("start");
        const uint64_t n0 = ls.cases();
        const uint64_t n = a.count(a.full ? 20000000 : 300000);
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x57, i);
                Fp c[4];
                for (Fp& v : c)
                    v = coord(r, false);
                if (r.chance(100))
                    c[2] = -c[0];                     // a step of exactly 2 |xa|
                edge(c[0], c[1], c[2], c[3], halves(r), halves(r));
            }
        sectionDone("fp-swamp", "start", ls.cases() - n0);
    }
    if (a.want("stream")) {
        f.set("stream");
        const uint64_t n0 = ls.cases();
        ls.gaps(300);
        const uint64_t n = a.full ? 2000000 : 100000;
        for (uint64_t i = 0; i < n; i++)
            if (a.mine(i)) {
                p2tb::Rng r = p2tb::Rng::of(a.seed ^ 0x5e, i);
                Gen g(r);
                Case c;
                c.kind = K_ALONE | K_WIND | K_START;
                c.v = g.num(24, 110, 210, 50, 20, 300);
                for (int k = 0; k < 3; k++) {
                    c.x[k] = coord(r, true);
                    c.y[k] = coord(r, true);
                }
                c.xa = coord(r, false); c.ya = coord(r, false); c.xb = coord(r, false); c.yb = coord(r, false);
                c.x0h = halves(r);
                c.y0h = halves(r);
                ls.push(c);
            }
        ls.gaps(0);
        sectionDone("fp-swamp", "stream", ls.cases() - n0);
    }
    top->final();
    return f.finish();
}

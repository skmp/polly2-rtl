// ref_copies_tsp.h: MipSelect's K part (pvr_tsp_plane.h at refsw3 4f3efe15), copied VERBATIM (PLAN 1.1 "copies", num
// 7.1; the marker format is tb/ref/ref_copies.h's; tools/check_ref_copies.sh re-extracts both copies on every gate run).
// L1: pvr_tsp_plane.h only, no libswirl header, so that tools/gen/gen_tsp_prog.cpp (the graph check) and the TSP setup
// testbench's reference (tb/tsp_setup/tsp_setup_ref.cpp) both run it.
//
// K is the polygon's part of the mipmap level: MipSelect computes it from the planes alone (u, v, 1/w of the volume, the
// texture's size, the bias and with DCalcCtrl 1 the first vertex); the pixel's 1/w q enters only after it. The two copies
// are the whole of it: tsp-mip-num from the determinant to the longer length `best` (the numerators of the undivided
// sums, the lengths, 1/det^2, the determinant-zero length of all ones), tsp-mip-k from `best` to the 8-bit K (the size,
// the bias, the infinite and zero cases). MipKOf runs them on the planes of an FpuEntry's volume (the ranged PlaneHW
// planes: `bad` is never set, so MipSelect's early returns before the copies never act; q is not read by them).
// Moved here from tb/ref/ref_copies.h (M9), where tsp-mip-k had been put by M5 and run by nothing.
#pragma once
#include <cstdint>
#include <cstdlib>
#include "pvr_tsp_plane.h"

namespace p2tspref {

struct MipKOut {
    pvrtsp::MipChoice r;        // MipSelect's r where it returns before the level (no level)
    pvrfp::Fp k8, kFull;        // K cut to 8 bits, and before the cut
    pvrfp::Fp best;             // the longer length as the K part takes it (after 1/det^2, or the determinant-zero one)
    bool dzForce = false;       // the determinant zero: the level is the last one, whatever w is (the pixel's part)
    bool ret = false;           // MipSelect returned r inside the copies (no K)
};

template<class P>
inline MipKOut MipKOf(const P& u, const P& v, const P& w, int sizeLog2, int biasQuarters, const uint32_t* first = nullptr)
{
    using namespace pvrfp;
    using pvrtsp::MipChoice;
    using pvrtsp::MipK;
    using pvrtsp::mipDzVariant;
    MipKOut out;
    out.ret = true;
    auto body = [&]() -> MipChoice {
        const Fp q = Fp::FromHalves(2);     // the pixel's 1/w: read before the K part only, by a test the ranged planes never meet
        (void)q;
// P2REF-COPY tsp-mip-num pvr_tsp_plane.h MipChoice r = { 0, 0, Fp() };
    MipChoice r = { 0, 0, Fp() };
    const bool ranged = w.cfg.range != 0;
    if (biasQuarters <= 0 || u.bad || v.bad || w.bad)
        return r;
    if (!ranged && (q.zero() || q.neg))
        return r;
    // At the limits of the setup's numbers (dreamcast-tests/pvr-tests/mipmeas, mix wext: 2400 cells with 1/w of 2^-126
    // .. 2^127, below zero, zero, infinite and NaN). A numerator is made of the planes' sums BEFORE their division by
    // the determinant, a_u c_w - c_u a_w, and divided twice afterwards: it is an infinity as soon as one of those two
    // products reaches 2^128 (flat 1/w = z on a 32x32 quad: z^2 * 2^15.6 for 3 texels a pixel, so from z = 2^57),
    // and zero when the quotient is below 2^-126 (z below 2^-60). A sum of two terms keeps the rules of the
    // setup. K is the length times the bias and then gets the texture's size added to its exponent field, with
    // no look at what the field means: a zero (field 0) becomes 2^(-127 + size), an infinity (field 255) wraps
    // to 2^(-128 + size). So below 2^-60 the level climbs by two for each halving of z, up to the smallest
    // map, and above 2^56 it is the largest map with no blending. The sign of 1/w does not matter.
    auto above = [](const Fp& x) { return !x.zero() && x.top() - 1 > 127; };
    auto below = [](const Fp& x) { return !x.zero() && x.top() - 1 < -126; };
    auto inf = []() { Fp x; x.bad = true; return x; };
    // one product of two sums: 0 a number, 1 an infinity, -1 a zero (the value itself: minor, below)
    auto kind = [&](const Fp& x, const Fp& y) {
        if (!ranged) return 0;
        if (x.bad || y.bad) return ((!x.bad && x.zero()) || (!y.bad && y.zero())) ? -1 : 1;
        if (x.zero() || y.zero()) return -1;
        Fp m = Mul(x, y, 24);
        return above(m) ? 1 : below(m) ? -1 : 0;
    };
    // The console's numerators (dreamcast-tests/pvr-tests/mipk5: 1991 of 1991 cells; mipk): of the UNDIVIDED sums,
    // each product cut to 24 bits and their difference cut to 24 bits, all toward zero; the two lengths are made of
    // those, and the longer is then multiplied once by 1/det^2, the determinant's 24 bit reciprocal squared and cut to
    // 24 bits (where every coefficient divided first loses its own cut; the 1/w plane's C of a flat triangle whose
    // determinant is not a power of two is just under 1, and the console's numerators are as if it were 1)
    const Fp& det = w.Sdet;
    if (mipDzVariant < 0) {
        const char* e = getenv("MIP_DZ");
        mipDzVariant = e ? atoi(e) : 0;
    }
    const int mipDz = mipDzVariant;
    const bool infInv = det.zero() && !det.bad && mipDz == 2;
    Fp inv = (det.bad || det.zero()) ? Fp() : Recip(det, 24);
    if (ranged && below(inv))
        inv = Fp();
    const bool undivided = MipK() != 1 && ((!det.zero() && !inv.zero()) || infInv);
    Fp inv2 = Mul(inv, inv, 24);
    // 1/det^2 is a number of the setup's range like the others: below 2^-126 (a determinant above about 2^63) it is
    // zero, so the length is zero and the level the largest map without blending, whatever the numerators are
    // (polly2-data sydney_race, sydney_stadium: the kerb's triangles with two corners at about 2^36 and 1/w of 10^6,
    // determinants of 2^63.0 .. 2^66.8 on the largest map on every pixel, those of 2^62.9 and below as before;
    // dreamcast-tests pvr-tests/mipdump)
    if (ranged && below(inv2))
        inv2 = Fp();
    // |a1 b2 - b1 a2|: of the undivided sums sa1 .. sb2 (MIP_K 1: of the divided coefficients a1 .. b2)
    auto minor = [&](const Fp& a1, const Fp& b1, const Fp& a2, const Fp& b2, const Fp& sa1, const Fp& sb1, const Fp& sa2, const Fp& sb2, bool neg1, bool neg2) {
        const int k1 = kind(sa1, sb2), k2 = kind(sb1, sa2);
        if (k1 == 1 || k2 == 1) {
            if (k1 == 1 && k2 == 1 && neg1 == neg2)
                return Fp();                                // infinity minus infinity
            return inf();
        }
        // a product that is a zero by the sums (zero times anything, also times an infinity) is one here too
        if (undivided) {
            const Fp q1 = (k1 < 0 || sa1.bad || sb2.bad) ? Fp() : Mul(sa1, sb2, 24), q2 = (k2 < 0 || sb1.bad || sa2.bad) ? Fp() : Mul(sb1, sa2, 24);
            Fp n = Sub(q1, q2, 62, 200).cut(24);
            n.neg = false;
            n.bad = false;
            if (infInv)
                return n.zero() ? Fp() : inf();
            if (ranged) {                               // the limits as before: by the quotient
                const Fp nq = Mul(n, inv2, 62);
                if (below(nq)) return Fp();
                if (above(nq)) return inf();
            }
            return n;
        }
        const Fp p1 = (k1 < 0 || a1.bad || b2.bad) ? Fp() : Mul(a1, b2, 62), p2 = (k2 < 0 || b1.bad || a2.bad) ? Fp() : Mul(b1, a2, 62);
        Fp n = Sub(p1, p2, 62, 200);
        n.neg = false;
        n.bad = false;
        if (ranged && below(n))
            return Fp();
        if (ranged && above(n))
            return inf();
        return n;
    };
    // along x: |C_a A_w - A_a C_w| for U and for V; along y: |B_a C_w - C_a B_w|. Each pair is one length (about
    // the larger plus (sqrt(2) - 1) of the smaller); K is the longer of the two.
    auto length = [](const Fp& p, const Fp& q) {
        if (p.bad || q.bad) {
            Fp x; x.bad = true; return x;
        }
        const bool pLonger = AtMost(q, p);
        const Fp& hi = pLonger ? p : q;
        const Fp& lo = pLonger ? q : p;
        if (lo.zero())
            return hi;
        if (MipK() == 1) {                              // as it was: the longer plus 27146 / 65536 of the shorter
            Fp part = Mul(lo, Fp::FromHalves(2 * 27146), 62);
            part.exp -= 16;
            return Add(hi, part, 62, 200);
        }
        // the console's (dreamcast-tests/pvr-tests/mipk4, mipk3, mipk2: every cell): the two added, less 0x3F15F612
        // (0.585785985, a little under 2 - sqrt(2)) times the shorter, each of the three cut to 24 bits toward zero,
        // in the setup's adder (an operand 25 exponents below the other is dropped: a shorter that is a rounding's
        // residue leaves the longer as it is). (longer + shorter) - (2 - sqrt(2)) shorter is longer + (sqrt(2) - 1)
        // shorter, but with the sum's own cut: the part of the shorter falls as the shorter rises, until the sum steps up
        Fp k2;
        k2.mant = 0x95F612;
        k2.exp = -24;
        const Fp sum = Add(hi, lo, 62, 25).cut(24), less = Mul(lo, k2, 62).cut(24);
        return Sub(sum, less, 62, 25).cut(24);
    };
    // the planes' values where the numerators are taken: their constants, or the first vertex's u / w, v / w, 1 / w
    Fp pu = u.C0, pv = v.C0, pw = w.C0;
    Fp su = u.Sc, sv = v.Sc, sw = w.Sc;                 // the same as undivided sums
    if (first) {
        // DCalcCtrl 1: the planes evaluated at the first vertex, a x1 + b y1 + c, instead of their constants c
        // (the value at the screen's origin). For the limits, the undivided planes there, in the setup's
        // arithmetic: a flat 1/w = z overflows from 2^57 as with DCalcCtrl 0, and an infinite or NaN z1 gives the
        // levels it gives there (dreamcast-tests/pvr-tests/mipmeas, mix wextd: 2400 of 2400 cells). The vertex's own u1
        // z1, v1 z1, z1 give the same levels in every set measured; the plane is one path for both.
        auto load = [&](uint32_t u) { return Fp::FromSingle(u, ranged); };
        auto rmul = [&](const Fp& x, const Fp& y) {
            if (x.bad || y.bad) {
                const Fp& o = x.bad ? y : x;
                Fp z; z.neg = x.neg != y.neg;
                if (!o.bad && o.zero()) return z;
                z.bad = true; return z;
            }
            Fp m = Mul(x, y, 24);
            if (ranged && above(m)) { Fp z; z.bad = true; z.neg = m.neg; return z; }
            if (ranged && below(m)) { Fp z; z.neg = m.neg; return z; }
            return m;
        };
        const Fp z1 = load(first[2]);
        pu = rmul(load(first[0]), z1);
        pv = rmul(load(first[1]), z1);
        pw = z1;
        if (!ranged && (pu.bad || pv.bad || pw.bad))
            return r;
        // for the limits: the undivided planes evaluated at the first vertex, a x1 + b y1 + c, in the setup's
        // arithmetic (a triangle whose 1/w sums are all zero has a zero there, whatever z1 is)
        const Fp x1 = load(first[3]), y1 = load(first[4]);
        auto radd = [&](const Fp& x, const Fp& y) {
            if (x.bad || y.bad) {
                Fp z;
                if (x.bad && y.bad && x.neg != y.neg) return z;
                z.bad = true; z.neg = x.bad ? x.neg : y.neg; return z;
            }
            Fp m = Add(x, y, 24, 53);
            if (ranged && above(m)) { Fp z; z.bad = true; z.neg = m.neg; return z; }
            if (ranged && below(m)) return Fp();
            return m;
        };
        auto at1 = [&](const P& pl) { return radd(radd(rmul(pl.Sa, x1), rmul(pl.Sb, y1)), pl.Sc); };
        su = at1(u); sv = at1(v); sw = at1(w);
        if (!x1.bad && !y1.bad) {
            auto val1 = [&](const P& pl) { return Add(Add(Mul(pl.A0, x1, 62), Mul(pl.B0, y1, 62), 62, 200), pl.C0, 62, 200); };
            pu = val1(u); pv = val1(v); pw = val1(w);
        }
    }
    auto sgn = [](const Fp& x, const Fp& y) { return x.neg != y.neg; };
    Fp lx = length(minor(pu, u.A0, pw, w.A0, su, u.Sa, sw, w.Sa, sgn(su, w.Sa), sgn(u.Sa, sw)),
                   minor(pv, v.A0, pw, w.A0, sv, v.Sa, sw, w.Sa, sgn(sv, w.Sa), sgn(v.Sa, sw)));
    Fp ly = length(minor(u.B0, pu, w.B0, pw, u.Sb, su, w.Sb, sw, sgn(u.Sb, sw), sgn(su, w.Sb)),
                   minor(v.B0, pv, w.B0, pw, v.Sb, sv, w.Sb, sw, sgn(v.Sb, sw), sgn(sv, w.Sb)));
    Fp best = (lx.bad || (!ly.bad && AtMost(ly, lx))) ? lx : ly;
    // A determinant of zero (the setup's: three equal corners, or a sliver whose products, cut to 24 bits, cancel;
    // the edge unit draws both) makes a length of all ones, as if beyond every number: whatever the numerators are,
    // zero or not, and whatever w is, the level is the last one, and its fraction is that of K's 8 bits 0xFF (times
    // the D adjust) times w * w's 8 bits (below). dreamcast-tests/pvr-tests/tsp2_mipdz (1/w 2^-65 .. 2^-56) and
    // tsp2_mipdz2 (1/w 2^-127 .. 2^126): 4,800 points and 3,722 such slivers each (1,078 points where no sliver was
    // found; 882 in mipdz2), 15 rows of sizes 8 .. 256, D adjust 1/4 .. 15/4, DCalcCtrl 1, bilinear, U to 2^20, 1/w
    // below zero; the level, and trilinear pass B's fraction: 1,200 of 1,200 regions each. 1/det = +0 (polly2-rtl's
    // decision D4: K = 2^(-127 + size)) got 59 of tsp2_mipdz's, 1/det = an infinity (2^(-128 + size)) 36: both put
    // the largest map there; a length of 1.FFFFFF 2^127, the largest number, is the console's up to 1/w = 2^48 and
    // then comes down from the last level, which the console does not (mipdz2: the columns of 1/w 2^64, 2^96, 2^126
    // wrong in every row). (refsw3 divided by zero here: Recip of 0.)
    const bool dzForce = det.zero() && !det.bad && mipDz == 0;
    if (dzForce) {
        best = Fp();
        best.mant = 0xffffff;
        best.exp = -23;
    }
    if (undivided && !infInv && !dzForce && !best.bad && !best.zero()) {
        best = Mul(best, inv2, 24);                     // the longer length, once times 1/det^2
        if (ranged && above(best)) best = inf();
        else if (ranged && below(best)) best = Fp();
    }
// P2REF-END tsp-mip-num
        out.best = best;
        out.dzForce = dzForce;
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

}   // namespace p2tspref

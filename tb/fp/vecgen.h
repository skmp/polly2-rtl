// vecgen.h: the shared vector classes of the tb/fp testbenches (docs/spec/numerics.md 7.2). Header only; xorshift from
// p2tb::Rng, seeded per case (Rng::of(seed, i)) so that a case's vector does not depend on the shard that runs it.
//
//   mantissas  N (normalized: bit w-1 set), U (BL uniform 1..w, random below the leading one), P2 (powers of two),
//              ONES (2^b - 1), NEAR (2^b +- 1), CONST (num 3.5: 0xAAAAAB, 0x95F612, and the 2^23 neighbours)
//   numbers    a mantissa of a class at a top drawn uniformly from a range or from the edge tops of num 7.2 (-148,
//              -127 .. -125, 0, 127 .. 129, 132, 133, 256 .. 259) that lie in it; signs both ways; zeros of both signs
//              (5 %), bad values (2 %: mant 0, or with a mantissa where an unranged add can make one)
//   ranged     the classes of the ranged arithmetic (num 7.3 H10): +-0, +-bad, [2^-126, 2^-125), [2^-125, 2^-124),
//              ordinary, [2^127, 2^128); values exactly at 2^-126, 2^-125, 2^128 and one unit either side
#pragma once

#include "fp_tb.h"

namespace fptb {

struct Gen {
    p2tb::Rng r;
    explicit Gen(const p2tb::Rng& rng) : r(rng) {}

    static uint64_t mask(int w) { return w >= 64 ? ~0ull : (1ull << w) - 1; }

    uint64_t mantN(int w) { return w <= 0 ? 0 : (1ull << (w - 1)) | (r.u64() & mask(w - 1)); }
    uint64_t mantU(int w) { return mantN((int)r.range(1, w)); }
    uint64_t mantP2(int w) { return 1ull << r.below((uint64_t)w); }
    uint64_t mantOnes(int w) { return mask((int)r.range(1, w)); }
    uint64_t mantNear(int w)
    {
        if (w < 2)
            return 1;
        const int b = (int)r.range(1, w - 1);
        const uint64_t v = 1ull << b;
        return r.chance(500) ? v + 1 : v - 1;
    }
    uint64_t mantConst(int w)
    {
        static const uint64_t k[] = {0xAAAAAB, 0x95F612, 0x800000, 0x800001, 0xFFFFFF, 0xC00000, 0xBFFFFF, 0xAAAAAA};
        uint64_t m = k[r.below(8)];
        const int b = bl(m);
        return b > w ? m >> (b - w) : m;
    }
    // a mantissa of a random class, at most w bits, never 0
    uint64_t mant(int w)
    {
        switch (r.below(10)) {
        case 0: case 1: case 2: return mantN(w);
        case 3: case 4: return mantU(w);
        case 5: return mantP2(w);
        case 6: return mantOnes(w);
        case 7: return mantNear(w);
        case 8: return mantConst(w);
        default: return mantN(w);
        }
    }

    // a top: uniform in [lo, hi] (70 %) or one of num 7.2's edge tops within it
    int top(int lo, int hi)
    {
        static const int edge[] = {-148, -127, -126, -125, -124, 0, 1, 127, 128, 129, 130, 132, 133, 256, 257, 258, 259};
        if (r.chance(300)) {
            for (int tries = 0; tries < 4; tries++) {
                const int t = edge[r.below(sizeof edge / sizeof edge[0])];
                if (t >= lo && t <= hi)
                    return t;
            }
        }
        return (int)r.range(lo, hi);
    }

    static Fp at(uint64_t m, int top, bool neg) { return mk(neg, false, top - bl(m), m); }

    // a number: mantissa class of at most w bits, top in [lo, hi]; zeroPm / badPm per mille zeros and bad values;
    // badMantPm: of the bad values, those with a mantissa (an unranged add's result)
    Fp num(int w, int lo, int hi, unsigned zeroPm = 50, unsigned badPm = 20, unsigned badMantPm = 0)
    {
        const bool neg = r.u64() & 1;
        if (r.chance(zeroPm))
            return mk(neg, false, (int)r.range(-300, 300), 0);
        if (r.chance(badPm)) {
            if (r.chance(badMantPm)) {
                Fp v = at(mant(w), top(lo, hi), neg);
                v.bad = true;
                return v;
            }
            return mk(neg, true, 0, 0);
        }
        return at(mant(w), top(lo, hi), neg);
    }

    // num 7.3 H10's classes of the ranged arithmetic, at 24 bits
    enum RClass { RC_ZERO, RC_BAD, RC_LOW1, RC_LOW2, RC_ORD, RC_HIGH, RC_N };
    Fp ranged(int cls)
    {
        const bool neg = r.u64() & 1;
        switch (cls) {
        case RC_ZERO: return mk(neg, false, (int)r.range(-200, 200), 0);
        case RC_BAD: return mk(neg, true, 0, 0);
        case RC_LOW1: return at(mant(24), -125, neg);                  // [2^-126, 2^-125)
        case RC_LOW2: return at(mant(24), -124, neg);                  // [2^-125, 2^-124)
        case RC_HIGH: return at(mant(24), 128, neg);                   // [2^127, 2^128)
        default: return at(mant(24), (int)r.range(-123, 127), neg);    // ordinary
        }
    }
    // a value of the ranged world: an input (FromSingle(., 1)) or a setup result
    Fp rangedAny() { return ranged((int)r.below(RC_N)); }
};

}   // namespace fptb

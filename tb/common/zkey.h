// zkey.h: a stored-depth key (p2_zkey_t, refsw3 StoredDepth::k) back to the StoredDepth refsw3 holds, for logs, the
// depth tap (PLAN 1.4: fit/zdump_data) and M3's round-trip assertion (PLAN M3 item 5). C++17, refcore L1 header.
//
// The RTL holds only the key; refsw3 also holds `bits`, the float word "for logs and the probes only" (pvr_isp_depth.h
// StoredDepth). The key has one of four forms, and each is inverted with refcore's own functions:
//   - low 32 bits 0:                         Bits(w), w the inverse of Key32 of the high half;
//   - high half the key of 0x7f800000:       Big: low half = ((field - 255) << 23 | frac) + 1;
//   - high half the key of sign | field<<23, low half below 2^31:  Neg above its window, E = field - 126,
//                                            M = low - 2^15;
//   - the same, low half from 2^31:          Neg below its window, E = field + 1 - 126, M = low - 2^31 - 2^30.
// The result is rebuilt with StoredDepth::Bits / Big / Neg and accepted only if its key equals k (so a key refsw3
// cannot make is reported, never inverted wrongly). A key of 0 gives the word 0: refsw3 has -0 (0x80000000) and +0 as
// one key; compare keys, not words.
#pragma once

#include "pvr_isp_depth.h"

#include <cstdint>

namespace p2tb {

// the inverse of StoredDepth::Key32 (key 0 gives the word 0, not 0x80000000)
inline uint32_t zkey_word(int32_t key32)
{
    const uint32_t b = (uint32_t)key32;
    return (b >> 31) ? (b ^ 0x007fffffu) : b;
}

// the StoredDepth whose key is k; false if refsw3 has no such key (then *out is untouched)
inline bool zkey_stored(int64_t k, pvrisp::StoredDepth* out)
{
    using pvrisp::StoredDepth;
    const int32_t hi = (int32_t)(uint32_t)((uint64_t)k >> 32);
    const uint32_t lo = (uint32_t)(uint64_t)k;
    const uint32_t w = zkey_word(hi);
    StoredDepth d;
    if (lo == 0) {
        d = StoredDepth::Bits(w);
    } else if (w == 0x7f800000u) {
        // Big(v): field = top(v) - 1 + 127 from 255 on, frac the 23 bits under the leading one
        const uint64_t o = (uint64_t)lo - 1;
        pvrfp::Fp v;
        v.mant = 0x800000u | (o & 0x7fffffu);
        v.exp = (int)(255 + (int64_t)(o >> 23)) - 127 - 23;   // top(v) = exp + 24 = field - 126
        d = StoredDepth::Big(v);
    } else if ((w >> 31) && (w & 0x7fffffu) == 0) {
        const int field = (int)((w >> 23) & 0xff);
        if (lo < 0x80000000u) {   // above the window of E = field - 126: lo = M + 2^15, M in (-2^15, 0)
            const int64_t M = (int64_t)lo - (1 << 15);
            if (M >= 0)
                return false;
            d = StoredDepth::Neg(field - 126, M);
        } else {                  // below the window of E = field + 1 - 126: lo = 2^31 + (M + 2^30)
            const int64_t M = (int64_t)lo - ((int64_t)1 << 31) - ((int64_t)1 << 30);
            d = StoredDepth::Neg(field + 1 - 126, M);
        }
    } else {
        return false;
    }
    if (d.k != k)
        return false;
    *out = d;
    return true;
}

// refsw3's bits for the key k, or `bad` if refsw3 has no such key
inline uint32_t zkey_bits(int64_t k, uint32_t bad = 0xffffffffu)
{
    pvrisp::StoredDepth d;
    return zkey_stored(k, &d) ? d.bits : bad;
}

}   // namespace p2tb

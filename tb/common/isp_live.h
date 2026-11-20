// isp_live.h: liveness masks of the ISP's per-pixel state (PLAN 1.3 "Liveness masks"). A field of p2ref::IspPix (the
// reference's state, tb/ref/p2ref.h) is compared with the RTL's only where refsw3's value is live: where a later phase
// of the entry may read it before writing it. Elsewhere the RTL may hold anything there (storage sharing, per-phase
// rules), and the comparison must not report it. Header only, C++17, no dependency on refcore or Verilator.
//
// A phase boundary is "after phase X" of one region array entry, in RenderCORE's order (tb/ref/phase_driver.cpp):
//
//   Z (ClearBuffers / ClearParamStatusBuffer)  OP  OP_MOD  OP_SHADE
//   PT_INIT  { PT_CHUNK (from the second chunk)  { PT_WALK  PT_SHADE } }  PT_FINAL  PT_MOD  PT_MV_SHADE
//   TR_PS (the presorted walk, which shades each triangle)  |  TR_SAVE  { TR_PEEL  TR_WALK  TR_MOD  TR_SHADE }  TR_RESTORE
//   END (before the write-out)
//
// The masks, at refsw3 4f3efe15 (refsw_tile.cpp, refsw_lists.cpp), where they differ from PLAN 1.3's first table:
//
//   depthA, tagA, stencil, valid       always (a keep-Z entry reads the entry before's depth)
//   depthB, tagB                       PT_INIT .. PT_SHADE (the boundary of the passes, TAG_BELOW at first); TR_PEEL only:
//                                      the translucent walk reads the layer drawn last, TR_MOD and TR_SHADE do not, and
//                                      the next PEEL writes it (PLAN: "TR autosort from the first PEEL")
//   depthC, refTagC, opTag             PT_INIT .. PT_SHADE (read by the walks, PT_CHUNK and PT_FINAL)
//   everRendered                       PT_INIT .. PT_SHADE
//   resPass                            PT_INIT .. PT_SHADE, pixels with `rendered` (ptResolvedLastPass is asked only there)
//   rendered                           PT_INIT .. PT_MOD (PT_MV_SHADE reads it; PLAN: "to the entry's end")
//   resTag, resDepth                   PT_INIT .. PT_SHADE, pixels with `rendered` OR `everRendered`: PT_FINAL takes the
//                                      resolved key of a pixel an earlier chunk resolved (PLAN: "rendered only")
//   savedDepth                         TR_SAVE .. TR_SHADE (TR_RESTORE reads it)
//
// tb/ref/refglue_selftest's --scramble mode proves the masks sound: at every boundary every field outside its mask is
// overwritten with random values in the reference's own state, and the render must still equal refsw3-offline's, every
// word of video memory (make refglue-selftest).
#pragma once
#include <cstdint>

namespace p2live {

enum Phase {
    Z, OP, OP_MOD, OP_SHADE,
    PT_INIT, PT_CHUNK, PT_WALK, PT_SHADE, PT_FINAL, PT_MOD, PT_MV_SHADE,
    TR_PS, TR_SAVE, TR_PEEL, TR_WALK, TR_MOD, TR_SHADE, TR_RESTORE,
    END,
    NPHASES
};

inline const char* name(Phase p)
{
    static const char* const n[NPHASES] = { "Z", "OP", "OP_MOD", "OP_SHADE", "PT_INIT", "PT_CHUNK", "PT_WALK",
                                            "PT_SHADE", "PT_FINAL", "PT_MOD", "PT_MV_SHADE", "TR_PS", "TR_SAVE",
                                            "TR_PEEL", "TR_WALK", "TR_MOD", "TR_SHADE", "TR_RESTORE", "END" };
    return p >= 0 && p < NPHASES ? n[p] : "?";
}

// the fields of p2ref::IspPix, one bit each
enum Field : uint32_t {
    DEPTH_A = 1u << 0, TAG_A = 1u << 1, STENCIL = 1u << 2, VALID = 1u << 3,
    DEPTH_B = 1u << 4, TAG_B = 1u << 5,
    DEPTH_C = 1u << 6, REFTAG_C = 1u << 7, OPTAG = 1u << 8, EVER_RENDERED = 1u << 9,
    RES_PASS = 1u << 10, RENDERED = 1u << 11, RES_TAG = 1u << 12, RES_DEPTH = 1u << 13,
    SAVED_DEPTH = 1u << 14,
    ALL_FIELDS = (1u << 15) - 1
};

// the fields live at the boundary after phase p, for a pixel whose state there has these two flags
inline uint32_t live(Phase p, bool rendered, bool everRendered)
{
    uint32_t m = DEPTH_A | TAG_A | STENCIL | VALID;
    const bool ptPasses = p == PT_INIT || p == PT_CHUNK || p == PT_WALK || p == PT_SHADE;
    if (ptPasses) {
        m |= DEPTH_B | TAG_B | DEPTH_C | REFTAG_C | OPTAG | EVER_RENDERED | RENDERED;
        if (rendered)
            m |= RES_PASS;
        if (rendered || everRendered)
            m |= RES_TAG | RES_DEPTH;
    }
    if (p == PT_FINAL || p == PT_MOD)
        m |= RENDERED;
    if (p == TR_PEEL)
        m |= DEPTH_B | TAG_B;
    if (p == TR_SAVE || p == TR_PEEL || p == TR_WALK || p == TR_MOD || p == TR_SHADE)
        m |= SAVED_DEPTH;
    return m;
}

}   // namespace p2live

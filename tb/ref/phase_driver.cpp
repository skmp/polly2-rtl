// phase_driver.cpp: RenderCORE's entry, one ISP / TSP phase at a time through the p2ref calls (tb/ref/phase_driver.h).
// The sequence is refsw_lists.cpp RenderCORE's at refsw3 4f3efe15 (the loop body between the entry's rectangle and its
// write-out), the render log left out. tb/ref/mutants.txt plants order errors here; make refglue-selftest must catch
// them.
#include "phase_driver.h"
#include "ref_copies.h"

#include <algorithm>

namespace p2drv {

using p2live::Phase;
namespace P = p2live;
using namespace refcore;

namespace {

struct DidNotEnd {};

struct At {
    Hook hook;
    void* user;
    const RegionArrayEntry& e;
    const taRECT& r;
    void operator()(Phase ph) const
    {
        if (hook)
            hook(ph, e, r, user);
    }
};

// the punch-through chunks and passes, PT_INIT up to the last pass of the last chunk
void PtPasses(const Options& o, Stats& st, const RegionArrayEntry& entry, const taRECT& rect, const At& at)
{
    p2ref::pt_initial();
    at(P::PT_INIT);
    p2ref::pt_begin(ISP_FEED_CFG.full >> 4 & 0x3ff);
    for (int chunk = 0; chunk < p2ref::pt_chunks(); chunk++) {
        p2ref::pt_chunk_start(chunk);
        if (chunk)
            at(P::PT_CHUNK);
        // one pass after the other until no pixel failed the alpha test (or nothing is left to try)
        for (int pass = 0;; pass++) {
            if (o.maxPasses && pass >= o.maxPasses)
                throw DidNotEnd();
            st.ptPasses = std::max(st.ptPasses, pass + 1);
            p2ref::pt_pass_start(pass);
            p2ref::walk(pass ? RM_PUNCHTHROUGH_PASSN : RM_PUNCHTHROUGH_PASS0, entry.puncht.ptr_in_words * 4, rect);
            at(P::PT_WALK);
            if (!p2ref::more())
                break;
            p2ref::clear_more();
            p2ref::render_param_tags(RM_PUNCHTHROUGH_PASS0, rect.left, rect.top);
            at(P::PT_SHADE);
            if (!p2ref::more())
                break;
        }
    }
    st.ptChunks = std::max(st.ptChunks, p2ref::pt_chunks());
}

void Entry(const Options& o, Stats& st, RegionArrayEntry& entry, taRECT& rect, Hook hook, void* user)
{
    const At at{ hook, user, entry, rect };
    st.entries++;
    p2ref::begin_entry();
    const uint32_t bgTag = p2ref::bg_tag();

    if (!entry.control.z_keep)
        p2ref::clear_buffers(bgTag, p2ref::bg_key());
    else
        p2ref::clear_status();
    at(P::Z);

    if (!entry.opaque.empty) {
        p2ref::walk(RM_OPAQUE, entry.opaque.ptr_in_words * 4, rect);
        at(P::OP);
        if (!entry.opaque_mod.empty) {
            p2ref::walk(RM_MODIFIER, entry.opaque_mod.ptr_in_words * 4, rect);
            at(P::OP_MOD);
        }
    }

    // OpInPt: the tile's punch-through list holds a primitive (refsw_lists.cpp)
    p2ref::set_opinpt(!entry.puncht.empty && p2ref::list_has_prim(entry.puncht.ptr_in_words * 4));
    p2ref::render_param_tags(RM_OPAQUE, rect.left, rect.top);
    at(P::OP_SHADE);

    if (!entry.puncht.empty) {
        if (o.ptCopy) {
            p2ref::pt_phase_copy(entry, rect);
            at(P::PT_FINAL);
        } else {
            PtPasses(o, st, entry, rect, at);
            p2ref::pt_final();
            at(P::PT_FINAL);
        }
        if (!entry.opaque_mod.empty) {
            p2ref::walk(RM_MODIFIER, entry.opaque_mod.ptr_in_words * 4, rect);
            at(P::PT_MOD);
            p2ref::render_param_tags(RM_PUNCHTHROUGH_MV, rect.left, rect.top);
            at(P::PT_MV_SHADE);
        }
    }

    if (!entry.trans.empty) {
        if (entry.control.pre_sort) {
            p2ref::clear_status();
            p2ref::walk(RM_TRANSLUCENT_PRESORT, entry.trans.ptr_in_words * 4, rect);
            at(P::TR_PS);
        } else {
            p2ref::save_depth();
            at(P::TR_SAVE);
            int pass = 0;
            do {
                if (o.maxPasses && pass >= o.maxPasses)
                    throw DidNotEnd();
                st.trPasses = std::max(st.trPasses, ++pass);
                p2ref::clear_more();
                p2ref::peel(p2ref::ZType::Bits(0x7f7fffff));       // the largest finite float
                at(P::TR_PEEL);
                p2ref::walk(RM_TRANSLUCENT_AUTOSORT, entry.trans.ptr_in_words * 4, rect);
                at(P::TR_WALK);
                if (!entry.trans_mod.empty) {
                    p2ref::walk(RM_MODIFIER, entry.trans_mod.ptr_in_words * 4, rect);
                    at(P::TR_MOD);
                }
                p2ref::render_param_tags(RM_TRANSLUCENT_AUTOSORT, rect.left, rect.top);
                at(P::TR_SHADE);
            } while (p2ref::more());
            p2ref::restore_depth();
            at(P::TR_RESTORE);
        }
    }
    at(P::END);
}

}   // namespace

bool render(const Options& o, Hook hook, void* user, Stats* stats)
{
    Stats local;
    Stats& st = stats ? *stats : local;
    try {
        p2ref::copy::RenderFrame([&](RegionArrayEntry& e, taRECT& r) { Entry(o, st, e, r, hook, user); });
    } catch (const DidNotEnd&) {
        return false;
    }
    return true;
}

}   // namespace p2drv

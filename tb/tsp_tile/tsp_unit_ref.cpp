// tsp_unit_ref.cpp: turef (tsp_unit_ref.h) on the p2ref API. Compiled with refsw3-offline's FLAGS / INC / DEF beside the
// L2 glue (tb/mk/tsp_tile.mk).
#include "tsp_unit_ref.h"
#include "p2ref.h"

#include <cstring>

namespace turef {

namespace {
pvrfp::Fp F(bool neg, int exp, uint64_t mant)
{
    pvrfp::Fp f;
    f.neg = neg;
    f.bad = false;
    f.exp = exp;
    f.mant = mant;
    return f;
}
refcore::Color C(uint32_t w)
{
    refcore::Color c;
    c.raw = w;
    return c;
}
}   // namespace

void init() { p2ref::reset_core(); }
uint8_t* vram() { return p2ref::vram(); }
void set_reg(uint32_t addr, uint32_t v) { memcpy(p2ref::regs() + addr, &v, 4); }
uint32_t texture_filter(uint32_t tsp, uint32_t tcw, bool uneg, int uexp, uint64_t umant, bool vneg, int vexp,
                        uint64_t vmant, uint32_t level)
{
    refcore::TSP t;
    t.full = tsp;
    refcore::TCW w;
    w.full = tcw;
    return p2ref::texture_filter(t, w, F(uneg, uexp, umant), F(vneg, vexp, vmant), level).raw;
}
uint32_t combiner(bool texture, bool offset, int shadInstr, uint32_t b, uint32_t t, uint32_t o)
{
    return p2ref::combiner(texture, offset, shadInstr, C(b), C(t), C(o)).raw;
}
uint32_t bump(uint32_t t, uint32_t o) { return p2ref::bump(C(t), C(o)).raw; }
uint32_t bump_light(uint32_t ofsFallback) { return p2ref::bump_light_copy(ofsFallback).raw; }
uint32_t shade(uint32_t isp, uint32_t tsp, uint32_t tcw, uint32_t b, uint32_t t, uint32_t o)
{
    return p2ref::shade_copy(isp, tsp, tcw, C(b), C(t), C(o)).raw;
}
uint32_t fog(bool offset, bool colorClamp, int fogCtrl, uint32_t c, bool wneg, int wexp, uint64_t wmant, uint8_t offsA)
{
    return p2ref::fog(offset, colorClamp, fogCtrl, C(c), F(wneg, wexp, wmant), offsA).raw;
}
uint32_t fade(uint32_t isp, uint32_t tsp, uint32_t tcw, uint32_t c, int k)
{
    return p2ref::fade_copy(isp, tsp, tcw, C(c), k).raw;
}
uint32_t super_avg(const uint32_t* c4)
{
    refcore::Color c[4];
    for (int i = 0; i < 4; i++)
        c[i] = C(c4[i]);
    return p2ref::super_avg_copy(c).raw;
}
bool blend(int srcSel, int dstSel, int srcInstr, int dstInstr, bool atest, uint32_t idx, uint32_t col, uint32_t* b1,
           uint32_t* b2)
{
    p2ref::set_color(1, (int)idx, *b1);
    p2ref::set_color(2, (int)idx, *b2);
    const bool at = p2ref::blend(srcSel, dstSel, srcInstr, dstInstr, atest, idx, C(col));
    *b1 = p2ref::color(1, (int)idx);
    *b2 = p2ref::color(2, (int)idx);
    return at;
}

}   // namespace turef

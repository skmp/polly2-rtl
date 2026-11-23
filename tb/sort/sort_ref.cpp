// sort_ref.cpp: sortref (sort_ref.h) on the p2ref API. Compiled with refsw3-offline's FLAGS / INC / DEF (P2REF_CXXFLAGS,
// tb/mk/sort.mk) and linked with the L2 glue objects (build/ref/lib).
#include "sort_ref.h"

#include <cstring>
#include <vector>

#include "p2ref.h"

namespace sortref {

int span_sort(uint32_t cfg, const Span* spans, int n, uint16_t* order)
{
    memcpy(p2ref::regs() + 0x30, &cfg, 4);      // SPAN_SORT_CFG_addr (pvr_regs.h)
    static std::vector<p2ref::SpanRec> s;
    s.resize(n > 0 ? n : 1);
    for (int i = 0; i < n; i++)
        s[i] = { spans[i].tag, spans[i].y, spans[i].x, spans[i].len };
    return p2ref::span_sort(s.data(), n, order);
}

}   // namespace sortref

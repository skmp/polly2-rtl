// sort_ref.h: the sorter testbench's view of the reference (PLAN M8). Plain C++: the Verilated testbench (sort_tb.cpp)
// includes only this; sort_ref.cpp, compiled with refsw3-offline's flags beside the L2 glue (tb/ref), implements it on
// p2ref::span_sort, which is refsw3's own SpanSort (refcore refsw_tile.cpp, through tb/ref/refcore_glue.cpp).
#pragma once
#include <cstdint>

namespace sortref {

struct Span {
    uint32_t tag;
    uint8_t y, x, len;
};

// refsw3's SpanSort of one pass's spans (raster order in) under SPAN_SORT_CFG = cfg (written into the register block
// first: SpanSort reads the register); order[k] = the index of the k-th span to shade; returns the count
int span_sort(uint32_t cfg, const Span* spans, int n, uint16_t* order);

}   // namespace sortref

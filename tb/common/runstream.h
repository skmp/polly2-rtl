// runstream.h: a recorded run stream (PLAN M8 "Gate" 1: M7's captured run streams), the file the ISP tile testbench
// writes in free-running mode (tb/isp_tile --dump-runs <dir>: <dir>/<case>.rs.gz) and the sorter testbench (tb/sort)
// reads. Every item p2_isp_cut emitted, as the TSP's side popped it, after the testbench checked it against refsw3's
// runs (the stream of a render that failed is not written); with each eoe item its entry record (p2_entrec_t, as the
// reference ran the entry and p2_entq gave it); before each render a record with its SPAN_SORT_CFG.
//
// gzip of fixed 24-byte records (zlib), little-endian:
#pragma once
#include <cstdint>

namespace p2rs {

enum : uint8_t { K_ITEM = 0, K_RENDER = 1 };
enum : uint8_t { F_NULL = 1, F_EOP = 2, F_EOE = 4 };
enum : uint8_t { R_RESET = 1 };     // K_RENDER's flags: the RTL was reset before this render (p2_isp_cut's epoch restarts)
enum : uint8_t { E_ZKEEP = 1, E_NOWO = 2, E_LAST = 4, E_SHADED = 8 };

struct Rec {
    uint8_t kind;           // K_ITEM, K_RENDER (tag: the render's SPAN_SORT_CFG)
    uint8_t flags;          // K_ITEM: F_NULL, F_EOP, F_EOE; K_RENDER: R_RESET
    uint8_t y, x, len;      // len 1..32 (lenm1 + 1)
    uint8_t rm;             // p2_rm_t
    uint8_t epoch;          // 7 bits
    uint8_t ent;            // the eoe item's entry record: E_ZKEEP, E_NOWO, E_LAST, E_SHADED
    uint8_t tilex, tiley;   // ... its tile
    uint16_t pad;
    uint32_t tag, vmask, pmask;
};
static_assert(sizeof(Rec) == 24, "runstream record");

}   // namespace p2rs

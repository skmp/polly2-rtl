// ztap_cmp: the depth tap against the console's depth read-outs (PLAN M13, 1.4 "gate_frames_hw.sh"; conventions.md 7.4.3:
// fit/zdump_data). C++17 on refcore's headers (tb/common/zkey.h: the RTL's 64-bit key back to refsw3's StoredDepth bits).
//
//   build/tools/ztap_cmp <ztap.txt> <fit/zdump_data/<scene>.txt>
//
// <ztap.txt>: p2-offline's +ztap output (rtl/v1/p2_core.sv): per entry "ZTAP <tilex> <tiley>" and 32 lines of 32 keys
// (hex), the tile's depths when the entry's ISP work ended; the last entry of a tile is its depth buffer after the render.
// <scene>.txt: one line per pixel the console's depth was read out at (dreamcast-tests zdumps.sh / model/zmiss.py):
// "(x, y) tile (tx, ty) at (px, py): console <hex> refsw3 <hex> ...". Prints a line per pixel whose depth differs, then
// "ztap_cmp: <n> of <N> depths the console's (<t> tiles tapped)"; exits 1 if any differs or a pixel's tile was not tapped.
#include "zkey.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

int main(int argc, char** argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: ztap_cmp <ztap.txt> <zdump .txt>\n");
        return 2;
    }
    std::map<std::pair<int, int>, std::vector<int64_t>> tiles;
    std::ifstream tf(argv[1]);
    if (!tf) {
        fprintf(stderr, "ztap_cmp: no %s\n", argv[1]);
        return 2;
    }
    std::string line;
    while (std::getline(tf, line)) {
        int tx, ty;
        if (sscanf(line.c_str(), "ZTAP %d %d", &tx, &ty) != 2)
            continue;
        std::vector<int64_t> k(1024);
        for (int r = 0; r < 32; r++) {
            if (!std::getline(tf, line)) {
                fprintf(stderr, "ztap_cmp: %s: a tile cut short\n", argv[1]);
                return 2;
            }
            std::istringstream ls(line);
            for (int i = 0; i < 32; i++) {
                std::string h;
                ls >> h;
                k[r * 32 + i] = (int64_t)strtoull(h.c_str(), nullptr, 16);
            }
        }
        tiles[{tx, ty}] = k;   // the last entry of the tile wins
    }
    std::ifstream zf(argv[2]);
    if (!zf) {
        fprintf(stderr, "ztap_cmp: no %s\n", argv[2]);
        return 2;
    }
    int n = 0, same = 0, untapped = 0;
    while (std::getline(zf, line)) {
        int x, y;
        unsigned console;
        const char* c = strstr(line.c_str(), "console ");
        if (sscanf(line.c_str(), "(%d, %d)", &x, &y) != 2 || !c || sscanf(c, "console %x", &console) != 1)
            continue;
        n++;
        auto it = tiles.find({x / 32, y / 32});
        if (it == tiles.end()) {
            printf("ztap_cmp: (%d, %d): tile (%d, %d) not tapped\n", x, y, x / 32, y / 32);
            untapped++;
            continue;
        }
        const int64_t k = it->second[(y % 32) * 32 + x % 32];
        const uint32_t bits = p2tb::zkey_bits(k);
        if (bits == console) {
            same++;
        } else {
            printf("ztap_cmp: (%d, %d): RTL %08x (key %016llx), console %08x\n", x, y, bits, (unsigned long long)k,
                   console);
        }
    }
    printf("ztap_cmp: %d of %d depths the console's (%zu tiles tapped)\n", same, n, tiles.size());
    return (same == n && n > 0 && !untapped) ? 0 : 1;
}

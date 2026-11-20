// tria_conv: refsw3-offline's render log (refcore refsw_lists.cpp RENDLOG lines) to build/vec/<test>.tri, the unit
// vectors of the console pages' own primitives (PLAN 1.2, M2 gate item 3; tools/gate/tria_extract.sh runs it).
//
//   refsw3-offline ... | tria_conv <regs folder> <out.tri>
//
// The log arrives on standard input, every render of the test one after the other (BGTAG starts one). Per render the
// registers are in <regs folder>/r<k>.regs (tria_extract's `regdump 0 40` before each STARTRENDER: FPU_CULL_VAL at
// 0x78, HALF_OFFSET at 0x80). Per tile (TILE: its control word has tilex 7:2, tiley 13:8; its fifth word the
// translucent modifier list) every TRIA line (tag, ISP word, TSP, TCW, then x y z u v of three corners with %a: exact)
// becomes one record, once per tile: the punch-through passes and the translucent peels repeat a primitive, and only
// the first is kept (same corners, ISP word and render-mode class). The render mode's class: MODIFIER after OPAQ_MOD
// and PT_MOD, and in a TR_AS_N pass from the OBJECT line at the translucent modifier list's first word on; anything
// else is a polygon (OPAQ, PT, TR_PS, TR_AS_N). A quad (a QARR line before its TRIA): the TRIA has three corners and
// QARR prints corner 4 with %f only, so a quad is reported and counted, not written (the M2 sets have none).
// Prints "tria_conv: <records> records, <renders> renders, <dups> repeats dropped, <quads> quads skipped".
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_set>
#include <vector>

#include "p2tb.h"
#include "tri_rec.h"

using p2tri::TriRec;

static uint32_t fbits(float f)
{
    uint32_t u;
    memcpy(&u, &f, 4);
    return u;
}

int main(int argc, char** argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: tria_conv <regs folder> <out.tri> < log\n");
        return 2;
    }
    const std::string regsDir = argv[1];
    std::vector<TriRec> out;
    std::unordered_set<std::string> seen;          // per tile
    int render = -1;
    uint32_t cullVal = 0, halfOffset = 0;
    int tileX = 0, tileY = 0;
    uint32_t trModAddr = 0;
    bool trModValid = false, modvol = false, inTrAs = false, pendingQuad = false;
    long dups = 0, quads = 0, bad = 0;
    char* buf = nullptr;
    size_t cap = 0;
    ssize_t len;
    while ((len = getline(&buf, &cap, stdin)) > 0) {
        const char* l = buf;
        if (l[0] < 'A' || l[0] > 'Z')
            continue;
        char tok[16];
        int n = 0;
        while (n < 15 && l[n] && l[n] != ':' && l[n] != '\n' && l[n] != ' ')
            tok[n] = l[n], n++;
        tok[n] = 0;
        if (!strncmp(l, "BGTAG:", 6)) {
            render++;
            char p[512];
            snprintf(p, sizeof p, "%s/r%d.regs", regsDir.c_str(), render);
            FILE* f = fopen(p, "rb");
            uint32_t w[0x40] = {};
            if (!f || fread(w, 4, 0x40, f) != 0x40) {
                fprintf(stderr, "tria_conv: cannot read %s\n", p);
                return 1;
            }
            fclose(f);
            cullVal = w[0x78 / 4];
            halfOffset = w[0x80 / 4];
        } else if (!strncmp(l, "TILE:", 5)) {
            uint32_t base, ctl, op, opm, tr, trm, pt;
            if (sscanf(l + 5, "%x %x %x %x %x %x %x", &base, &ctl, &op, &opm, &tr, &trm, &pt) != 7) {
                bad++;
                continue;
            }
            tileX = (ctl >> 2) & 63;
            tileY = (ctl >> 8) & 63;
            trModValid = !(trm >> 31);
            trModAddr = (trm & 0xFFFFFC);        // ListPointer ptr_in_words (bits 23:2) * 4
            seen.clear();
            modvol = inTrAs = pendingQuad = false;
        } else if (!strcmp(tok, "OPAQ_MOD") || !strcmp(tok, "PT_MOD")) {
            modvol = true;
            inTrAs = false;
        } else if (!strcmp(tok, "OPAQ") || !strcmp(tok, "PT") || !strcmp(tok, "PT_N") || !strcmp(tok, "PT_CHUNK") ||
                   !strcmp(tok, "TR_PS")) {
            modvol = inTrAs = false;
        } else if (!strcmp(tok, "TR_AS_N")) {
            modvol = false;
            inTrAs = true;
        } else if (!strncmp(l, "OBJECT:", 7)) {
            uint32_t base, obj;
            if (inTrAs && trModValid && sscanf(l + 7, "%x %x", &base, &obj) == 2 && base == trModAddr)
                modvol = true;
        } else if (!strncmp(l, "QARR:", 5)) {
            pendingQuad = true;
        } else if (!strncmp(l, "TRIA:", 5)) {
            uint32_t tag, isp, tsp, tcw;
            char* p = (char*)l + 5;
            tag = strtoul(p, &p, 16);
            isp = strtoul(p, &p, 16);
            tsp = strtoul(p, &p, 16);
            tcw = strtoul(p, &p, 16);
            (void)tag; (void)tsp; (void)tcw;
            float v[15];
            for (int k = 0; k < 15; k++)
                v[k] = strtof(p, &p);
            if (pendingQuad) {
                quads++;
                pendingQuad = false;
                continue;
            }
            TriRec r = {};
            for (int c = 0; c < 3; c++) {
                r.x[c] = fbits(v[5 * c]);
                r.y[c] = fbits(v[5 * c + 1]);
            }
            r.isp = isp;
            r.cullVal = cullVal;
            r.halfOffset = halfOffset;
            r.render = (uint16_t)render;
            r.tileX = (uint8_t)tileX;
            r.tileY = (uint8_t)tileY;
            r.modvol = modvol;
            std::string key((const char*)&r, sizeof r);
            if (!seen.insert(key).second) {
                dups++;
                continue;
            }
            out.push_back(r);
        }
    }
    free(buf);
    if (!p2tb::VecFile::write(argv[2], p2tri::kTriMagic, sizeof(TriRec), out.data(), out.size())) {
        fprintf(stderr, "tria_conv: cannot write %s\n", argv[2]);
        return 1;
    }
    printf("tria_conv: %zu records, %d renders, %ld repeats dropped, %ld quads skipped, %ld bad lines\n", out.size(),
           render + 1, dups, quads, bad);
    return bad ? 1 : 0;
}

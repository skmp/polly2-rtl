// gen_table_roms: prints one of the TSP's measured-table ROMs (docs/spec/tsp.md 20; PLAN M1c), read from refsw3's
// text, never typed by hand:
//
//   sin      rtl/v1/lib/rom/p2_rom_bm_sin.sv   refsw_tile.cpp  `static const u8 BM_HW_SIN[256] = {`   tsp 12, appendix B
//   cos      rtl/v1/lib/rom/p2_rom_bm_cos.sv   refsw_tile.cpp  `static const u8 BM_HW_COS[256] = {`   tsp 12, appendix B
//   dither   rtl/v1/lib/rom/p2_rom_dither.sv   refsw_lists.cpp `static const int ditherAdd[4][4] = {`  tsp 17.3
//
//   build/tools/gen/gen_table_roms <refcore dir> <sin | cos | dither> > <file>     (make roms; make roms-check compares)
//
// The table is the brace-enclosed list after its declaration, which must occur exactly once in its file: decimal numbers
// separated by commas, inner braces (ditherAdd's rows), whitespace, nothing else, exactly as many as the table has, each
// within the ROM word. Any other text there fails (exit 1, no output). The testbench (make fp-rom) compares every entry
// with a verbatim copy of the same lines (tb/fp/ref_copies.h, drift-checked against refcore by every gate).
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace {

int fail(const std::string& what)
{
    fprintf(stderr, "gen_table_roms: %s\n", what.c_str());
    return 1;
}

bool readTable(const std::string& path, const std::string& decl, size_t count, int maxv, std::vector<int>* out,
               std::string* err)
{
    std::ifstream in(path);
    if (!in) {
        *err = "cannot read " + path;
        return false;
    }
    std::stringstream ss;
    ss << in.rdbuf();
    const std::string text = ss.str();
    const size_t s = text.find(decl);
    if (s == std::string::npos || text.find(decl, s + 1) != std::string::npos) {
        *err = path + ": `" + decl + "` is not there exactly once";
        return false;
    }
    size_t p = s + decl.size();   // just after the opening brace
    int depth = 1;
    out->clear();
    while (depth > 0) {
        if (p >= text.size()) {
            *err = path + ": the table after `" + decl + "` does not end";
            return false;
        }
        const char c = text[p];
        if (c == '{') {
            depth++;
            p++;
        } else if (c == '}') {
            depth--;
            p++;
        } else if (c == ',' || c == ' ' || c == '\n' || c == '\t' || c == '\r') {
            p++;
        } else if (c >= '0' && c <= '9') {
            size_t q = p;
            while (q < text.size() && text[q] >= '0' && text[q] <= '9')
                q++;
            if (q - p > 1 && text[p] == '0') {
                *err = path + ": an entry with a leading zero (octal?) in `" + decl + "`";
                return false;
            }
            const long v = strtol(text.substr(p, q - p).c_str(), nullptr, 10);
            if (v > maxv) {
                *err = path + ": entry " + std::to_string(out->size()) + " (" + std::to_string(v) + ") of `" + decl +
                       "` does not fit the ROM word";
                return false;
            }
            out->push_back((int)v);
            p = q;
        } else {
            *err = path + std::string(": `") + decl + "` holds something that is not a decimal entry: '" + c + "'";
            return false;
        }
    }
    if (out->size() != count) {
        *err = path + ": `" + decl + "` has " + std::to_string(out->size()) + " entries, not " + std::to_string(count);
        return false;
    }
    return true;
}

void header(const char* file, const char* decl)
{
    printf("// GENERATED: do not edit. tools/gen/gen_table_roms.cpp from refcore (nulldc3 refsw3/refcore) %s,\n", file);
    printf("// the entries of `%s` read from the text. Regenerate: make roms; check: make roms-check.\n", decl);
    printf("//\n");
}

}   // namespace

int main(int argc, char** argv)
{
    if (argc != 3)
        return fail("usage: gen_table_roms <refcore dir> <sin | cos | dither>");
    const std::string refcore = argv[1], which = argv[2];
    std::vector<int> v;
    std::string err;
    if (which == "sin" || which == "cos") {
        const bool sin = which == "sin";
        const std::string decl = sin ? "static const u8 BM_HW_SIN[256] = {" : "static const u8 BM_HW_COS[256] = {";
        if (!readTable(refcore + "/refsw_tile.cpp", decl, 256, 255, &v, &err))
            return fail(err);
        const char* mod = sin ? "p2_rom_bm_sin" : "p2_rom_bm_cos";
        header("refsw_tile.cpp", decl.c_str());
        printf("// %s: the bump mapper's %s table, BM_HW_%s[0 .. 255] (docs/spec/tsp.md 12 and appendix B; refcore\n",
               mod, sin ? "SIN" : "COS", sin ? "SIN" : "COS");
        printf("// refsw_tile.cpp BumpMapper; dreamcast-tests pvr-tests/bumpfn: every S and R under fourteen lights, read off\n");
        printf("// the console's pictures). Not a %s: a line per 8 entries. %s\n", sin ? "sine" : "cosine",
               sin ? "SIN[0] may be 0 or 1: no light can show which [bumpfn]." :
                     "COS[255] may be 0, 1 or 2: no light can show which [bumpfn].");
        printf("// BumpMapper reads SIN[S], COS[S] and COS[4 x] (x or 63 - x) a pixel: p2_pp_shade has one SIN and two COS.\n");
        printf("// Combinational (a case ROM).\n");
        printf("module %s (\n", mod);
        printf("  input  logic [7:0] i,\n");
        printf("  output logic [7:0] v\n");
        printf(");\n");
        printf("  always_comb begin\n");
        printf("    case (i)\n");
        for (int i = 0; i < 256; i++) {
            char idx[32];
            snprintf(idx, sizeof idx, "8'd%d:", i);
            printf("      %-7s v = 8'd%d;\n", idx, v[i]);
        }
        printf("      default: v = '0;   // every index is above (a complete case)\n");
        printf("    endcase\n");
        printf("  end\n");
        printf("endmodule\n");
        return 0;
    }
    if (which == "dither") {
        const std::string decl = "static const int ditherAdd[4][4] = {";
        if (!readTable(refcore + "/refsw_lists.cpp", decl, 16, 15, &v, &err))
            return fail(err);
        header("refsw_lists.cpp", decl.c_str());
        printf("// p2_rom_dither: what the write-out adds to a channel before it cuts it to 4 bits, ditherAdd[Y & 3][X & 3]\n");
        printf("// (rows are y); half of it for 5 bits, a quarter for 6 (docs/spec/tsp.md 17.3; refcore refsw_lists.cpp\n");
        printf("// RenderCORE `put`; dreamcast-tests pvr-tests/fbpack: every entry pinned, lower bound = upper bound; fb555,\n");
        printf("// fb565). Combinational (a case ROM).\n");
        printf("module p2_rom_dither (\n");
        printf("  input  logic [1:0] y,     // Y & 3: the framebuffer line\n");
        printf("  input  logic [1:0] x,     // X & 3: the framebuffer column\n");
        printf("  output logic [3:0] v\n");
        printf(");\n");
        printf("  always_comb begin\n");
        printf("    case ({y, x})\n");
        for (int i = 0; i < 16; i++) {
            char idx[32], val[32];
            snprintf(idx, sizeof idx, "4'd%d:", i);
            snprintf(val, sizeof val, "4'd%d;", v[i]);
            printf("      %-6s v = %-6s   // y %d, x %d\n", idx, val, i >> 2, i & 3);
        }
        printf("      default: v = '0;   // every index is above (a complete case)\n");
        printf("    endcase\n");
        printf("  end\n");
        printf("endmodule\n");
        return 0;
    }
    return fail("unknown table '" + which + "': sin, cos or dither");
}

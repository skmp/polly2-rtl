// gen_recip_rom: prints rtl/v1/lib/fp/p2_fp_recip_rom.sv, the TSP divider's reciprocal table (docs/spec/numerics.md
// H13, docs/spec/tsp.md 6.1 and appendix A; refcore pvr_tsp_plane.h RecipTable; dreamcast-tests pvr-tests/uvmeas, mix
// recipscan: all 32768 16-bit mantissas). The ROM is generated from the header, never by hand (num H13):
//
//   - the 512 c digits are read from the text of RecipTable's string (`static const char c[] =` and the string
//     literals after it, up to the `;`), in the struct's one definition in <refcore>/pvr_tsp_plane.h;
//   - t[i] = ceil(2^32 / (64 (512 + i))), i = 0 .. 512, and n[i] = t[i] - t[i+1] + c[i], i = 0 .. 511, the formula;
//   - both are checked against the compiled pvrtsp::RecipTable (the header's own constructor): a change to the string,
//     or to the formula that this file does not follow, fails here (exit 1, no output) instead of giving a stale ROM.
//
//   build/tools/gen/gen_recip_rom <refcore dir> > p2_fp_recip_rom.sv     (make roms; make roms-check compares)
//
// A ROM word is {t[i] - 65536 (17 bits: t[0] = 2^17), n[i] (9 bits: 65 .. 256)}; c[i] and t[i] are in each line's
// comment. RecipTable::Mantissa's arithmetic, r = (64 t[i] - 1 - n[i] (D & 63)) >> 7, is p2_fp_recip_mant's.
#include "pvr_tsp_plane.h"

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

namespace {

int fail(const char* what)
{
    fprintf(stderr, "gen_recip_rom: %s\n", what);
    return 1;
}

// the text of <refcore>/pvr_tsp_plane.h; the c digits of the one `struct RecipTable {`
bool readDigits(const std::string& refcore, std::string* digits, std::string* err)
{
    std::ifstream in(refcore + "/pvr_tsp_plane.h");
    if (!in) {
        *err = "cannot read " + refcore + "/pvr_tsp_plane.h";
        return false;
    }
    std::stringstream ss;
    ss << in.rdbuf();
    const std::string text = ss.str();
    const std::string head = "struct RecipTable {";
    const size_t s = text.find(head);
    if (s == std::string::npos || text.find(head, s + 1) != std::string::npos) {
        *err = "pvr_tsp_plane.h: `struct RecipTable {` is not there exactly once";
        return false;
    }
    const size_t e = text.find("\n};", s);   // the struct's closing line
    const std::string body = text.substr(s, e == std::string::npos ? std::string::npos : e - s);
    const std::string decl = "static const char c[] =";
    const size_t d = body.find(decl);
    if (d == std::string::npos || body.find(decl, d + 1) != std::string::npos) {
        *err = "RecipTable: `static const char c[] =` is not there exactly once";
        return false;
    }
    // the string literals up to the declaration's `;`: whitespace between them, nothing else
    size_t p = d + decl.size();
    digits->clear();
    for (;;) {
        while (p < body.size() && (body[p] == ' ' || body[p] == '\n' || body[p] == '\t' || body[p] == '\r'))
            p++;
        if (p >= body.size()) {
            *err = "RecipTable: the string of c has no `;`";
            return false;
        }
        if (body[p] == ';')
            break;
        if (body[p] != '"') {
            *err = std::string("RecipTable: the string of c holds something that is not a plain literal: '") + body[p] + "'";
            return false;
        }
        const size_t q = body.find('"', p + 1);
        if (q == std::string::npos) {
            *err = "RecipTable: an unterminated literal in the string of c";
            return false;
        }
        digits->append(body, p + 1, q - p - 1);
        p = q + 1;
    }
    if (digits->size() != 512) {
        *err = "RecipTable: the string of c has " + std::to_string(digits->size()) + " characters, not 512";
        return false;
    }
    for (char ch : *digits)
        if (ch < '0' || ch > '2') {
            *err = std::string("RecipTable: a c digit that is not 0, 1 or 2: '") + ch + "'";
            return false;
        }
    return true;
}

}   // namespace

int main(int argc, char** argv)
{
    if (argc != 2)
        return fail("usage: gen_recip_rom <refcore dir>");
    std::string digits, err;
    if (!readDigits(argv[1], &digits, &err))
        return fail(err.c_str());

    // the formula, here
    int64_t t[513], n[512];
    for (int i = 0; i <= 512; i++) {
        const uint64_t d = 64ull * (512 + i);
        t[i] = (int64_t)(((1ull << 32) + d - 1) / d);
    }
    for (int i = 0; i < 512; i++)
        n[i] = t[i] - t[i + 1] + (digits[i] - '0');

    // against the compiled table
    static const pvrtsp::RecipTable tab;
    for (int i = 0; i <= 512; i++)
        if (tab.t[i] != t[i])
            return fail(("t[" + std::to_string(i) + "] = " + std::to_string(tab.t[i]) + " in RecipTable, " +
                         std::to_string(t[i]) + " by the formula here: the header's formula changed").c_str());
    for (int i = 0; i < 512; i++)
        if (tab.n[i] != n[i])
            return fail(("n[" + std::to_string(i) + "] = " + std::to_string(tab.n[i]) + " in RecipTable, " +
                         std::to_string(n[i]) + " from the text's digits and the formula: the header changed").c_str());
    // the ROM's fields
    int count[3] = {0, 0, 0};
    for (int i = 0; i < 512; i++) {
        if (t[i] < 65536 || t[i] - 65536 >= (1 << 17) || n[i] < 0 || n[i] >= (1 << 9))
            return fail(("entry " + std::to_string(i) + " does not fit {t - 65536: 17 bits, n: 9 bits}").c_str());
        count[digits[i] - '0']++;
    }

    printf("// GENERATED: do not edit. tools/gen/gen_recip_rom.cpp from refcore pvr_tsp_plane.h RecipTable (nulldc3\n");
    printf("// refsw3/refcore): the c digits read from the header's string, t and n by its formula, both checked against\n");
    printf("// the compiled table. Regenerate: make roms; check: make roms-check.\n");
    printf("//\n");
    printf("// p2_fp_recip_rom: the TSP divider's reciprocal table (docs/spec/numerics.md H13, docs/spec/tsp.md 6.1 and\n");
    printf("// appendix A), read off a console for all 32768 16-bit mantissas (dreamcast-tests pvr-tests/uvmeas, mix\n");
    printf("// recipscan, 14 runs):\n");
    printf("//\n");
    printf("//   t[i] = ceil(2^32 / (64 (512 + i)))     i = 0 .. 512 (t[512] = 65536 only enters n[511])\n");
    printf("//   n[i] = t[i] - t[i+1] + c[i]            c[i] the measured digits: %d zeros, %d ones, %d twos; no formula known\n",
           count[0], count[1], count[2]);
    printf("//\n");
    printf("// The word of entry i is {t[i] - 65536 (17 bits), n[i] (9 bits)}; p2_fp_recip_mant reads it at i = D[14:6].\n");
    printf("// Combinational (a case ROM: logic or a ROM block, the synthesizer's choice).\n");
    printf("module p2_fp_recip_rom (\n");
    printf("  input  logic [8:0]  i,\n");
    printf("  output logic [16:0] t,     // t[i] - 65536\n");
    printf("  output logic [8:0]  n      // n[i]\n");
    printf(");\n");
    printf("  logic [25:0] v;\n");
    printf("\n");
    printf("  assign t = v[25:9];\n");
    printf("  assign n = v[8:0];\n");
    printf("\n");
    printf("  always_comb begin\n");
    printf("    case (i)\n");
    for (int i = 0; i < 512; i++) {
        char idx[32], tf[32], nf[32];
        snprintf(idx, sizeof idx, "9'd%d:", i);
        snprintf(tf, sizeof tf, "17'd%lld,", (long long)(t[i] - 65536));
        snprintf(nf, sizeof nf, "9'd%lld};", (long long)n[i]);
        printf("      %-7s v = {%-10s %-8s   // t %lld, c %c\n", idx, tf, nf, (long long)t[i], digits[i]);
    }
    printf("      default: v = '0;   // every index is above (Verilator, Quartus: a complete case)\n");
    printf("    endcase\n");
    printf("  end\n");
    printf("endmodule\n");
    return 0;
}

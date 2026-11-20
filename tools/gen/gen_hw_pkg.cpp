// gen_hw_pkg: prints rtl/v1/pkg/p2_hw_pkg.sv, one localparam per member of refcore's *HW structs (conventions.md
// section 5). The values are the compiled constants of the headers (pvrfp::C<N>, std::true_type), never text.
//
//   build/tools/gen/gen_hw_pkg <refcore dir> > p2_hw_pkg.sv        (make hw-pkg; make hw-pkg-check compares)
//
// The member lists below are checked against the text of every C/C++ file under <refcore dir> on every run, so that
// refsw3 cannot add or drop a member, or add a *HW struct, without this generator (and the RTL) being told. The text
// is read as code: comments, string and character literals are blanked first.
//   - every identifier that ends in HW, anywhere (a struct or class of any form, a using or typedef, a macro), is one
//     of the structs below or one of kNotHw;
//   - each struct below is defined exactly once, in its header, with nothing between its name and its body (a base
//     class would bring members this text does not show), and no preprocessor line in its body (an #include there
//     would);
//   - every declaration in its body, whatever it is (static or not, `{}`, `{v}` or `= v`, a function, a type), is one
//     member whose name is listed for it, one name per declaration; every listed name is declared (static_assert
//     excepted).
// Any failure prints what differs and exits 1 without output. make hw-pkg-selftest shows each rule failing.
//
// Each member is a WIDTH (a number the RTL takes as a parameter) or a MODE (a switch with more than one value, of
// which the RTL implements one: conventions.md 5). rtl/v1/pkg/p2_hw_check.sv holds the value the RTL implements for
// every MODE and fails elaboration when the package says otherwise; make hw-pkg-check also elaborates a package with
// each MODE member changed and fails if that one still builds.
#include "pvr_isp_depth.h"
#include "pvr_isp_edge.h"
#include "pvr_tsp_plane.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct Member {
    const char* name;   // the refcore member name
    long value;
    bool mode;          // a mode switch: the RTL implements this value only
};

struct HwStruct {
    const char* name;     // EdgeHW
    const char* qname;    // pvrisp::EdgeHW
    const char* header;   // pvr_isp_edge.h
    const char* prefix;   // P2_ISP_EDGE
    std::vector<Member> members;
};

#define WIDTH(S, m) Member{#m, (long)S::m, false}
#define MODE(S, m) Member{#m, (long)S::m, true}

const std::vector<HwStruct> kStructs = {
    {"EdgeHW", "pvrisp::EdgeHW", "pvr_isp_edge.h", "P2_ISP_EDGE",
     {WIDTH(pvrisp::EdgeHW, productBits), WIDTH(pvrisp::EdgeHW, sumBits), WIDTH(pvrisp::EdgeHW, reach),
      MODE(pvrisp::EdgeHW, guard), WIDTH(pvrisp::EdgeHW, startBits), WIDTH(pvrisp::EdgeHW, slopeBits),
      WIDTH(pvrisp::EdgeHW, pairBits), WIDTH(pvrisp::EdgeHW, blockAdd), WIDTH(pvrisp::EdgeHW, startAdd),
      WIDTH(pvrisp::EdgeHW, zeroShift), WIDTH(pvrisp::EdgeHW, tieShift), WIDTH(pvrisp::EdgeHW, overflowExp),
      WIDTH(pvrisp::EdgeHW, saturateExp), MODE(pvrisp::EdgeHW, lastColumnByStep), WIDTH(pvrisp::EdgeHW, blockMax),
      WIDTH(pvrisp::EdgeHW, cutUnitBits), WIDTH(pvrisp::EdgeHW, walkExp)}},
    {"DepthHW", "pvrisp::DepthHW", "pvr_isp_depth.h", "P2_ISP_DEPTH",
     {WIDTH(pvrisp::DepthHW, productBits), WIDTH(pvrisp::DepthHW, sumBits), WIDTH(pvrisp::DepthHW, reach),
      WIDTH(pvrisp::DepthHW, recipBits), WIDTH(pvrisp::DepthHW, coefBits), WIDTH(pvrisp::DepthHW, startBits),
      WIDTH(pvrisp::DepthHW, slopeBits), WIDTH(pvrisp::DepthHW, pairBits), WIDTH(pvrisp::DepthHW, tileBits),
      WIDTH(pvrisp::DepthHW, storedBits), MODE(pvrisp::DepthHW, startOnSlopes), MODE(pvrisp::DepthHW, range),
      MODE(pvrisp::DepthHW, zeroRuleCoords), MODE(pvrisp::DepthHW, zeroRuleEdges)}},
    {"PlaneHW", "pvrtsp::PlaneHW", "pvr_tsp_plane.h", "P2_TSP_PLANE",
     {WIDTH(pvrtsp::PlaneHW, productBits), WIDTH(pvrtsp::PlaneHW, sumBits), WIDTH(pvrtsp::PlaneHW, reach),
      WIDTH(pvrtsp::PlaneHW, recipBits), WIDTH(pvrtsp::PlaneHW, coefBits), WIDTH(pvrtsp::PlaneHW, gridBits),
      WIDTH(pvrtsp::PlaneHW, valueBits), MODE(pvrtsp::PlaneHW, valueFixed), MODE(pvrtsp::PlaneHW, range),
      WIDTH(pvrtsp::PlaneHW, expLow), WIDTH(pvrtsp::PlaneHW, expHigh), WIDTH(pvrtsp::PlaneHW, zeroReach),
      MODE(pvrtsp::PlaneHW, tileLocal), MODE(pvrtsp::PlaneHW, macOrder), MODE(pvrtsp::PlaneHW, sumA),
      MODE(pvrtsp::PlaneHW, sumW)}},
};

// productBits -> PRODUCT_BITS, lastColumnByStep -> LAST_COLUMN_BY_STEP, sumA -> SUM_A
std::string Snake(const char* camel)
{
    std::string s;
    for (const char* p = camel; *p; p++) {
        if (std::isupper((unsigned char)*p) && p != camel)
            s += '_';
        s += (char)std::toupper((unsigned char)*p);
    }
    return s;
}

std::string ReadFile(const std::string& path)
{
    std::ifstream f(path);
    if (!f)
        return std::string();
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// identifiers in refcore that end in HW and are not *HW structs (none yet); one added here names why it is not
const std::set<std::string> kNotHw = {};

// words that cannot be a member's name: a declaration whose name would be one of these is not read
const std::set<std::string> kKeywords = {
    "alignas", "auto", "bool", "char", "class", "const", "consteval", "constexpr", "constinit", "decltype", "double",
    "enum", "explicit", "extern", "float", "friend", "inline", "int", "long", "mutable", "noexcept", "operator",
    "register", "short", "signed", "static", "struct", "template", "thread_local", "typedef", "typename", "union",
    "unsigned", "using", "virtual", "void", "volatile"};

bool IsIdent(char c)
{
    return std::isalnum((unsigned char)c) || c == '_';
}

// The text with every comment, string literal (raw ones too) and character literal blanked to spaces, newlines
// kept: what is left is code and preprocessor lines. A ' inside a number (1'000) is a digit separator.
std::string CodeOnly(const std::string& t)
{
    const size_t n = t.size(), npos = std::string::npos;
    std::string o = t;
    auto blank = [&](size_t a, size_t b) {
        for (size_t k = a; k < b && k < n; k++)
            if (o[k] != '\n')
                o[k] = ' ';
    };
    auto quoted = [&](size_t i) {   // the end of the "..." or '...' at i; an unterminated one ends with its line
        size_t j = i + 1;
        while (j < n && t[j] != t[i] && t[j] != '\n')
            j += (t[j] == '\\') ? 2 : 1;
        return std::min(j + 1, n);
    };
    size_t i = 0;
    while (i < n) {
        const char c = t[i];
        size_t j = i + 1;
        if (c == '/' && i + 1 < n && t[i + 1] == '/') {   // to the end of the line, backslash-newline continuing it
            j = i + 2;
            while (j < n && !(t[j] == '\n' && t[j - 1] != '\\'))
                j++;
            blank(i, j);
        } else if (c == '/' && i + 1 < n && t[i + 1] == '*') {
            const size_t e = t.find("*/", i + 2);
            j = (e == npos) ? n : e + 2;
            blank(i, j);
        } else if (c == '"') {
            size_t k = i;
            while (k > 0 && IsIdent(t[k - 1]))
                k--;
            const std::string prefix = t.substr(k, i - k);
            if (prefix == "R" || prefix == "u8R" || prefix == "uR" || prefix == "UR" || prefix == "LR") {
                const size_t p = t.find('(', i + 1);
                const std::string close = ")" + t.substr(i + 1, p == npos ? 0 : p - i - 1) + "\"";
                const size_t e = (p == npos) ? npos : t.find(close, p + 1);
                j = (e == npos) ? n : e + close.size();
            } else {
                j = quoted(i);
            }
            blank(i, j);
        } else if (c == '\'') {
            size_t k = i;
            while (k > 0 && (IsIdent(t[k - 1]) || t[k - 1] == '\'' || t[k - 1] == '.'))
                k--;
            if (!(k < i && std::isdigit((unsigned char)t[k]))) {   // not in a number: a character literal
                j = quoted(i);
                blank(i, j);
            }
        }
        i = j;
    }
    return o;
}

// whitespace runs to one space, none at the ends
std::string Collapse(const std::string& s)
{
    std::string o;
    for (char c : s) {
        if (std::isspace((unsigned char)c)) {
            if (!o.empty() && o.back() != ' ')
                o += ' ';
        } else {
            o += c;
        }
    }
    while (!o.empty() && o.back() == ' ')
        o.pop_back();
    return o;
}

// The declarations of a struct body (code only): each ends at a `;`, or at a `}` that closes a function body, outside
// every bracket. A `}` followed by what continues an expression (`x{}.v`, `[]{ }()`, `T{};`) does not end one.
// False if the brackets do not balance.
bool Declarations(const std::string& body, std::vector<std::string>* out)
{
    std::string cur;
    int depth = 0;
    for (size_t i = 0; i < body.size(); i++) {
        const char c = body[i];
        bool end = false;
        if (c == '(' || c == '[' || c == '{') {
            depth++;
        } else if (c == ')' || c == ']' || c == '}') {
            if (--depth < 0)
                return false;
            if (c == '}' && depth == 0) {
                const size_t j = body.find_first_not_of(" \t\r\n", i + 1);
                end = j == std::string::npos || !std::strchr(";,=().-+*/%&|^?<>![", body[j]) ||
                      body.compare(j, 2, "[[") == 0;
            }
        } else if (c == ';' && depth == 0) {
            out->push_back(cur);
            cur.clear();
            continue;
        }
        cur += c;
        if (end) {
            out->push_back(cur);
            cur.clear();
        }
    }
    out->push_back(cur);
    return depth == 0;
}

// The name the member declaration `d` (collapsed) declares: the identifier before the first = { ( [ , or bit-field
// colon outside brackets (< > counted as brackets there). True with an empty name for nothing to declare (an empty
// declaration, a static_assert); false, with the reason, when no name can be read or the declaration has more than
// one (a comma outside brackets after the name).
bool DeclName(std::string d, std::string* name, std::string* why)
{
    static const std::regex access("^(public|private|protected) ?:(?!:) ?");
    name->clear();
    for (;;) {   // access specifiers and [[attributes]] before the declaration
        std::smatch m;
        if (std::regex_search(d, m, access)) {
            d = d.substr((size_t)m.length(0));
        } else if (d.compare(0, 2, "[[") == 0) {
            const size_t e = d.find("]]");
            if (e == std::string::npos) {
                *why = "an unterminated [[";
                return false;
            }
            d = Collapse(d.substr(e + 2));
        } else {
            break;
        }
    }
    if (d.empty() || (d.compare(0, 13, "static_assert") == 0 && (d.size() == 13 || !IsIdent(d[13]))))
        return true;
    int depth = 0;
    size_t stop = d.size();
    for (size_t i = 0; i < d.size() && stop == d.size(); i++) {
        const char c = d[i];
        const bool colon = c == ':' && (i + 1 == d.size() || d[i + 1] != ':') && (i == 0 || d[i - 1] != ':');
        if (depth == 0 && (c == '=' || c == '{' || c == '(' || c == '[' || c == ',' || colon))
            stop = i;
        else if (c == '(' || c == '[' || c == '{' || c == '<')
            depth++;
        else if ((c == ')' || c == ']' || c == '}' || c == '>') && --depth < 0)
            break;
    }
    if (stop == d.size() && depth != 0) {
        *why = "its brackets do not balance";
        return false;
    }
    size_t e = stop;
    while (e > 0 && d[e - 1] == ' ')
        e--;
    size_t b = e;
    while (b > 0 && IsIdent(d[b - 1]))
        b--;
    const std::string n = d.substr(b, e - b);
    if (n.empty() || std::isdigit((unsigned char)n[0]) || kKeywords.count(n)) {
        *why = "no member name in it";
        return false;
    }
    depth = 0;
    for (size_t i = stop; i < d.size(); i++) {
        const char c = d[i];
        if (c == '(' || c == '[' || c == '{')
            depth++;
        else if (c == ')' || c == ']' || c == '}')
            depth--;
        else if (c == ',' && depth == 0) {
            *why = "a comma outside brackets: more than one name in one declaration";
            return false;
        }
    }
    *name = n;
    return true;
}

int CheckHeaders(const std::string& dir)
{
    namespace fs = std::filesystem;
    std::map<std::string, const HwStruct*> known;
    for (const HwStruct& s : kStructs)
        known[s.name] = &s;

    // every C/C++ file of refcore, subdirectories included
    std::vector<std::string> files;
    static const std::set<std::string> exts = {".h", ".hh", ".hpp", ".hxx", ".inc", ".inl", ".ipp",
                                               ".c", ".cc", ".cpp", ".cxx"};
    std::error_code ec;
    for (fs::recursive_directory_iterator it(dir, ec), end; !ec && it != end; it.increment(ec))
        if (it->is_regular_file() && exts.count(it->path().extension().string()))
            files.push_back(fs::relative(it->path(), dir).string());
    if (ec || files.empty()) {
        fprintf(stderr, "gen_hw_pkg: cannot read the C/C++ files of %s\n", dir.c_str());
        return 1;
    }
    std::sort(files.begin(), files.end());

    // 1. every identifier that ends in HW is a known struct (or in kNotHw); 2. where each known struct is defined
    struct Def {
        std::string file, between, body;
        bool closed;
    };
    std::map<std::string, std::vector<Def>> defs;
    static const std::regex hwDef(
        "\\b(struct|class|union)\\s+"
        "((alignas\\s*\\((?:[^()]|\\([^()]*\\))*\\)|\\[\\[(?:[^\\]]|\\][^\\]])*\\]\\]|"
        "__attribute__\\s*\\(\\((?:[^()]|\\([^()]*\\))*\\)\\)|__declspec\\s*\\((?:[^()]|\\([^()]*\\))*\\))\\s*)*"
        "(\\w+HW)\\b([^;{]*)\\{");
    int bad = 0;
    for (const std::string& f : files) {
        const std::string code = CodeOnly(ReadFile(dir + "/" + f));
        std::set<std::string> names;
        for (size_t i = 0; i < code.size();) {
            if (!IsIdent(code[i])) {
                i++;
                continue;
            }
            size_t j = i;
            while (j < code.size() && IsIdent(code[j]))
                j++;
            if (j - i >= 2 && code.compare(j - 2, 2, "HW") == 0)
                names.insert(code.substr(i, j - i));
            i = j;
        }
        for (const std::string& n : names)
            if (!known.count(n) && !kNotHw.count(n)) {
                fprintf(stderr, "gen_hw_pkg: %s names %s, which ends in HW and is not a *HW struct this generator "
                                "knows: if it is one, add it (and its members as WIDTH or MODE) to kStructs in "
                                "tools/gen/gen_hw_pkg.cpp; if it is not, add it to kNotHw there\n",
                        f.c_str(), n.c_str());
                bad++;
            }
        for (std::sregex_iterator it(code.begin(), code.end(), hwDef), end; it != end; ++it) {
            const std::string n = (*it)[4];
            if (!known.count(n))
                continue;   // reported above
            size_t i = (size_t)(it->position(0) + it->length(0));
            const size_t start = i;
            int depth = 1;
            for (; i < code.size() && depth > 0; i++)
                depth += (code[i] == '{') - (code[i] == '}');
            defs[n].push_back(Def{f, Collapse((*it)[5]), depth == 0 ? code.substr(start, i - 1 - start) : "",
                                  depth == 0});
        }
    }

    // 3. each known struct: defined once, in its header, nothing before its body; its members exactly those listed
    for (const HwStruct& s : kStructs) {
        const std::vector<Def>& v = defs[s.name];
        if (v.size() != 1 || v[0].file != s.header) {
            std::string where;
            for (const Def& d : v)
                where += " " + d.file;
            fprintf(stderr, "gen_hw_pkg: struct %s is defined %zu times (in:%s); this generator reads it from %s only\n",
                    s.name, v.size(), where.c_str(), s.header);
            bad++;
            continue;
        }
        const Def& d = v[0];
        if (!d.between.empty() && d.between != "final") {
            fprintf(stderr, "gen_hw_pkg: %s has `%s` between its name and its body: this generator reads only the "
                            "members in its own body\n", s.qname, d.between.c_str());
            bad++;
        }
        if (!d.closed) {
            fprintf(stderr, "gen_hw_pkg: the body of %s is not closed in %s\n", s.qname, s.header);
            bad++;
            continue;
        }
        if (d.body.find('#') != std::string::npos) {
            fprintf(stderr, "gen_hw_pkg: a preprocessor line in the body of %s: this generator reads the text and "
                            "cannot follow it (an #include would bring members it does not see)\n", s.qname);
            bad++;
            continue;
        }
        std::vector<std::string> decls;
        if (!Declarations(d.body, &decls)) {
            fprintf(stderr, "gen_hw_pkg: the brackets of %s's body do not balance\n", s.qname);
            bad++;
            continue;
        }
        std::set<std::string> inText, listed;
        for (const std::string& raw : decls) {
            const std::string decl = Collapse(raw);
            std::string name, why;
            if (!DeclName(decl, &name, &why)) {
                fprintf(stderr, "gen_hw_pkg: %s declares `%s`, which this generator cannot read (%s): one named "
                                "member per declaration\n", s.qname, decl.c_str(), why.c_str());
                bad++;
            } else if (!name.empty()) {
                inText.insert(name);
            }
        }
        for (const Member& m : s.members)
            listed.insert(m.name);
        for (const std::string& n : inText)
            if (!listed.count(n)) {
                fprintf(stderr, "gen_hw_pkg: %s has member %s, which this generator does not list: add it as "
                                "WIDTH or MODE\n", s.qname, n.c_str());
                bad++;
            }
        for (const std::string& n : listed)
            if (!inText.count(n)) {
                fprintf(stderr, "gen_hw_pkg: %s no longer has member %s: remove it here (and from the RTL)\n",
                        s.qname, n.c_str());
                bad++;
            }
    }
    return bad;
}

}   // namespace

int main(int argc, char** argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: gen_hw_pkg <refcore dir>\n");
        return 2;
    }
    if (CheckHeaders(argv[1]))
        return 1;

    printf("// GENERATED: do not edit. tools/gen/gen_hw_pkg.cpp from the refcore *HW structs (nulldc3 refsw3/refcore:\n");
    printf("// pvr_isp_edge.h, pvr_isp_depth.h, pvr_tsp_plane.h). Regenerate: make hw-pkg; check: make hw-pkg-check.\n");
    printf("//\n");
    printf("// The widths are refsw3's measured precisions (the evidence is at each member in refcore and in\n");
    printf("// docs/spec/numerics.md section 3). The RTL takes its widths from this package and nowhere else.\n");
    printf("// MODE members are switches of which the RTL implements one value: rtl/v1/pkg/p2_hw_check.sv fails\n");
    printf("// elaboration if a value below is not that one (conventions.md section 5).\n");
    printf("package p2_hw_pkg;\n");
    for (const HwStruct& s : kStructs) {
        printf("\n  // %s (%s)\n", s.qname, s.header);
        size_t w = 0;
        for (const Member& m : s.members)
            w = std::max(w, strlen(s.prefix) + 1 + Snake(m.name).size());
        for (const Member& m : s.members) {
            const std::string id = std::string(s.prefix) + "_" + Snake(m.name);
            const std::string val = std::to_string(m.value) + ";";
            printf("  localparam int %-*s = %-5s // %s::%s%s\n", (int)w, id.c_str(), val.c_str(), s.qname, m.name,
                   m.mode ? " (MODE)" : "");
        }
    }
    printf("\nendpackage\n");
    return 0;
}

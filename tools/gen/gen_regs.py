#!/usr/bin/env python3
# gen_regs.py: prints rtl/v1/pkg/p2_regs_pkg.sv, the register offsets, register fields, parameter words and the
# enums refsw3 uses, from nulldc3's headers (conventions.md section 5). Text munging only: no arithmetic.
#
#   python3 tools/gen/gen_regs.py <nulldc3 dir> > p2_regs_pkg.sv      (make regs-pkg; make regs-pkg-check compares)
#   python3 tools/gen/gen_regs.py <nulldc3 dir> --layout-check > x.cpp
#       a C++ program, compiled against the same headers by make regs-pkg-check, that sets every field of every
#       struct here to all ones in the C type and checks that the 32-bit word has exactly the bits the package gives
#       it (the compiler's bitfield layout is the reference, not this script's reading of it); and every enumerator.
#
# Adapted from polly2-rtl-lite tools/gen_pvr_regs.py (reuse.md 4.2): C bitfields (LSB first) become SV packed structs
# (MSB first) padded to 32 bits; `<NAME>_addr` defines become offsets. Retargeted from minicast's pvr_regs.h to
#   libswirl/hw/pvr/pvr_regs.h            register offsets and fields (union <NAME>_type, its first struct)
#   refsw3/refcore/core_structs.h         PCW, ISP_TSP, ISP_Modvol, TSP, TCW, PixelFormat
#   refsw3/refcore/refsw_lists_regtypes.h RegionArrayEntryControl, ListPointer, ObjectList*
#   refsw3/refcore/refsw_lists.h          enum RenderMode only (p2_rm_t, ARCHITECTURE 2.2)
#
# Names (conventions.md 4.5: fields as refsw3 / nulldc3 name them):
#   - offsets:  localparam logic [12:0] P2_REG_<NAME> (the byte offset in the 8 KB block);
#   - register fields: p2_<name in lower case>_t, e.g. p2_fb_w_ctrl_t;
#   - parameter words: the SV names of ARCHITECTURE 2.2 (TYPES below); a union's further views get the names below;
#   - a field whose name is a SystemVerilog keyword gets a trailing underscore (ObjectList* `type` -> `type_`);
#   - enumerators: P2_<C name>, e.g. P2_RM_OPAQUE, P2_Pixel1555.
# Every C union / struct with bitfields in the parameter-word headers must be named in TYPES, and every view of it,
# so that a struct refsw3 adds is not dropped silently: the generator fails on an unknown one.
import re
import sys

if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--layout-check"):
    sys.exit("usage: gen_regs.py <nulldc3 dir> [--layout-check]")
N3 = sys.argv[1]
LAYOUT = len(sys.argv) == 3
CHECKS = []         # (C type, member path, lsb, width) for --layout-check
ENUM_CHECKS = []    # (C enumerator, value)
SRC_REGS = "libswirl/hw/pvr/pvr_regs.h"
SRC_WORDS = ["refsw3/refcore/core_structs.h", "refsw3/refcore/refsw_lists_regtypes.h"]
SRC_RM = "refsw3/refcore/refsw_lists.h"

# C type (or "type.view": the k-th further anonymous struct, or a named struct member) -> SV type name.
# None: a view that is generated from its own struct (ObjectListEntry's tstrip ... link members).
TYPES = {
    "PCW": "p2_pcw_t",
    "PCW.1": "p2_pcw_ta_t",                 # padin, S6X (set by the TA for 64-byte vertices), PTEOS
    "ISP_TSP": "p2_isptsp_t",
    "ISP_TSP.modvol": "p2_isptsp_modvol_t",
    "ISP_Modvol": "p2_isp_modvol_t",
    "TSP": "p2_tsp_t",
    "TCW": "p2_tcw_t",
    "TCW.1": "p2_tcw_pal_t",                # PalSelect
    "RegionArrayEntryControl": "p2_region_ctl_t",
    "ListPointer": "p2_listptr_t",
    "ObjectListTstrip": "p2_objent_tstrip_t",
    "ObjectListTarray": "p2_objent_tarray_t",
    "ObjectListQarray": "p2_objent_qarray_t",
    "ObjectListLink": "p2_objent_link_t",
    "ObjectListEntry": "p2_objent_t",       # is_not_triangle_strip
    "ObjectListEntry.1": "p2_objent_type_t",
    "ObjectListEntry.tstrip": None,
    "ObjectListEntry.tarray": None,
    "ObjectListEntry.qarray": None,
    "ObjectListEntry.link": None,
}
ENUMS = {   # C enum -> (SV type, width)
    "RenderMode": ("p2_rm_t", 3),
    "PixelFormat": ("p2_pixfmt_t", 3),
    "fb_depth_enum": ("p2_fb_depth_t", 2),
}
TABLES = {"FOG_TABLE", "TA_OL_POINTERS", "PALETTE_RAM"}   # their _START / _END are emitted as offsets too

SV_KEYWORDS = set("""
accept_on alias always always_comb always_ff always_latch and assert assign assume automatic before begin bind bins
binsof bit break buf bufif0 bufif1 byte case casex casez cell chandle checker class clocking cmos config const
constraint context continue cover covergroup coverpoint cross deassign default defparam design disable dist do edge
else end endcase endchecker endclass endclocking endconfig endfunction endgenerate endgroup endinterface endmodule
endpackage endprimitive endprogram endproperty endspecify endsequence endtable endtask enum event eventually expect
export extends extern final first_match for force foreach forever fork forkjoin function generate genvar global
highz0 highz1 if iff ifnone ignore_bins illegal_bins implements implies import incdir include initial inout input
inside instance int integer interconnect interface intersect join join_any join_none large let liblist library local
localparam logic longint macromodule matches medium modport module nand negedge nettype new nexttime nmos nor
noshowcancelled not notif0 notif1 null or output package packed parameter pmos posedge primitive priority program
property protected pull0 pull1 pulldown pullup pulsestyle_ondetect pulsestyle_onevent pure rand randc randcase
randsequence rcmos real realtime ref reg reject_on release repeat restrict return rnmos rpmos rtran rtranif0
rtranif1 s_always s_eventually s_nexttime s_until s_until_with scalared sequence shortint shortreal showcancelled
signed small soft solve specify specparam static string strong strong0 strong1 struct super supply0 supply1
sync_accept_on sync_reject_on table tagged task this throughout time timeprecision timeunit tran tranif0 tranif1 tri
tri0 tri1 triand trior trireg type typedef union unique unique0 unsigned until until_with untyped use uwire var
vectored virtual void wait wait_order wand weak weak0 weak1 while wildcard wire with within wor xnor xor
""".split())


def fail(msg):
    sys.exit("gen_regs: " + msg)


def read(rel):
    try:
        return open(f"{N3}/{rel}").read()
    except OSError as e:
        fail(f"cannot read {rel}: {e}")


def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", " ", t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


def block(t, i):
    """t[i] == '{': returns the index after the matching '}'."""
    depth = 0
    for j in range(i, len(t)):
        if t[j] == "{":
            depth += 1
        elif t[j] == "}":
            depth -= 1
            if depth == 0:
                return j + 1
    fail("unbalanced braces")


BITFIELD = re.compile(r"^\s*(?:unsigned\s+)?(\w+)\s+(\w+)\s*:\s*(\d+)\s*$")


def bitfields(body):
    """[(name, width)] of `type name : width;` declarations, in C (LSB first) order; None if there are none."""
    out = []
    for decl in body.split(";"):
        m = BITFIELD.match(decl)
        if m:
            out.append((m.group(2), int(m.group(3))))
        elif ":" in decl:
            fail(f"bitfield not understood: {decl.strip()!r}")
    return out or None


def top_level_aggregates(t):
    """[(kind, name, body)] for every `union|struct NAME { ... };` in t (namespaces looked through)."""
    out = []
    for m in re.finditer(r"\b(union|struct)\s+(\w+)\s*\{", t):
        end = block(t, m.end() - 1)
        out.append((m.group(1), m.group(2), t[m.end():end - 1]))
    return out


def views(body):
    """The members of a union body: [(view name or None for anonymous, body or None, member type)]."""
    out, i = [], 0
    while i < len(body):
        m = re.compile(r"\s*struct\s*\{").match(body, i)
        if m:
            end = block(body, m.end() - 1)
            inner = body[m.end():end - 1]
            m2 = re.compile(r"\s*(\w*)\s*;").match(body, end)
            if not m2:
                fail("struct member not understood in a union")
            out.append((m2.group(1) or None, inner, None))
            i = m2.end()
            continue
        m = re.compile(r"\s*(\w+)\s+(\w+)\s*;").match(body, i)
        if m:
            out.append((m.group(2), None, m.group(1)))
            i = m.end()
            continue
        if body[i:].strip() == "":
            break
        fail(f"union member not understood: {body[i:i + 60]!r}")
    return out


def sv_field(name):
    return name + "_" if name in SV_KEYWORDS else name


def struct_sv(svname, fields, what, ctype, path=""):
    total = sum(w for _, w in fields)
    if total > 32:
        fail(f"{what}: {total} bits")
    lines = [f"  typedef struct packed {{   // {what}" + (f" ({total} bits used)" if total < 32 else "")]
    if total < 32:
        lines.append(f"    {'logic [' + str(31 - total) + ':0]':<14} {'pad_msb;':<34} // [31:{total}]")
    bit = total
    for f, w in reversed(fields):
        bit -= w
        CHECKS.append((ctype, path + f, bit, w))
        rng = f"[{bit + w - 1}:{bit}]" if w > 1 else f"[{bit}]"
        decl = "logic" + (f" [{w - 1}:0]" if w > 1 else "")
        lines.append(f"    {decl:<14} {sv_field(f) + ';':<34} // {rng}")
    lines.append(f"  }} {svname};")
    return lines


out = []
out.append("// GENERATED: do not edit. tools/gen/gen_regs.py from nulldc3 " + SRC_REGS + ",")
out.append("// " + ", ".join(SRC_WORDS) + " and " + SRC_RM + " (enum RenderMode).")
out.append("// Regenerate: make regs-pkg; check: make regs-pkg-check. Structs are MSB first (the C bitfields are LSB first);")
out.append("// a field named like an SV keyword has a trailing underscore (type_).")
out.append("package p2_regs_pkg;")

# ---- 1. register offsets ----
regs_h = read(SRC_REGS)
regs_txt = strip_comments(regs_h)
regs = []
for m in re.finditer(r"#define\s+(\w+)_addr\s+(0x[0-9A-Fa-f]+)", regs_txt):
    name, off = m.group(1), int(m.group(2), 16)
    if off >= 0x2000 or off & 3:
        fail(f"{name}_addr = {off:#x} is not a word in the 8 KB block")
    regs.append((name, off))
if not regs:
    fail("no registers found")
names = [n for n, _ in regs]
if len(set(names)) != len(names):
    fail("a register is defined twice")
out.append("")
out.append(f"  // ---- register byte offsets in the 8 KB block ({SRC_REGS} <NAME>_addr) ----")
w = max(len(n) for n in names)
for name, off in regs:
    out.append(f"  localparam logic [12:0] P2_REG_{name:<{w}} = 13'h{off:04X};")

# ---- 2. register fields ----
out.append("")
out.append(f"  // ---- register fields ({SRC_REGS} union <NAME>_type, its first struct) ----")
seen = set()
for kind, uname, body in top_level_aggregates(regs_txt):
    if kind != "union" or not uname.endswith("_type"):
        fail(f"{SRC_REGS}: {kind} {uname} not understood")
    reg = uname[:-len("_type")]
    vs = [v for v in views(body) if v[1] is not None]
    fields = bitfields(vs[0][1]) if vs else None
    if not fields:
        continue    # e.g. ISP_BACKGND_D_type { u32 i; f32 f; }: a plain word
    if len(vs) > 1:
        fail(f"{SRC_REGS}: {uname} has {len(vs)} bitfield views")
    if reg not in names:
        fail(f"{SRC_REGS}: {uname} has no register {reg}_addr")
    seen.add(reg)
    out.extend(struct_sv(f"p2_{reg.lower()}_t", fields, reg, uname))

# ---- 3. parameter words ----
out.append("")
out.append("  // ---- parameter words (" + ", ".join(SRC_WORDS) + ") ----")
used = set()
for src in SRC_WORDS:
    txt = strip_comments(read(src))
    for kind, cname, body in top_level_aggregates(txt):
        if kind == "struct":
            fields = bitfields(body)
            if not fields:
                continue            # Vertex: plain members, not a word
            if cname not in TYPES:
                fail(f"{src}: struct {cname} has bitfields and no SV name: add it to TYPES")
            used.add(cname)
            out.extend(struct_sv(TYPES[cname], fields, f"{cname} ({src.split('/')[-1]})", "refcore::" + cname))
            continue
        anon = 0
        for vname, vbody, vtype in views(body):
            if vbody is None:
                if vtype in ("u32", "u8", "u16"):
                    continue        # u32 full, u8 obj_ctrl
                key = f"{cname}.{vname}"
            elif vname is None:
                key = cname if anon == 0 else f"{cname}.{anon}"
                anon += 1
            else:
                key = f"{cname}.{vname}"
            if key not in TYPES:
                fail(f"{src}: union {cname} view {key} has no SV name: add it to TYPES")
            used.add(key)
            if TYPES[key] is None:
                continue
            fields = bitfields(vbody)
            if not fields:
                fail(f"{src}: {key} has no bitfields")
            out.extend(struct_sv(TYPES[key], fields, f"{key} ({src.split('/')[-1]})", "refcore::" + cname,
                                 vname + "." if vname else ""))
missing = set(TYPES) - used
if missing:
    fail("TYPES names views the headers no longer have: " + ", ".join(sorted(missing)))

# ---- 4. enums ----
out.append("")
out.append("  // ---- enums (" + SRC_REGS.split('/')[-1] + ", core_structs.h, refsw_lists.h) ----")
enum_src = {"fb_depth_enum": regs_txt, "PixelFormat": strip_comments(read(SRC_WORDS[0])),
            "RenderMode": strip_comments(read(SRC_RM))}
for cname, (svname, width) in ENUMS.items():
    m = re.search(r"\benum\s+" + cname + r"\s*\{([^}]*)\}", enum_src[cname])
    if not m:
        fail(f"enum {cname} not found")
    items, nxt = [], 0
    for e in [x.strip() for x in m.group(1).split(",") if x.strip()]:
        m2 = re.fullmatch(r"(\w+)(?:\s*=\s*(\w+))?", e)
        if not m2:
            fail(f"enum {cname}: {e!r} not understood")
        val = int(m2.group(2), 0) if m2.group(2) else nxt
        if val >= (1 << width):
            fail(f"enum {cname}: {m2.group(1)} = {val} does not fit {width} bits")
        items.append((m2.group(1), val))
        ENUM_CHECKS.append(("refcore::" + m2.group(1) if cname != "fb_depth_enum" else m2.group(1), val))
        nxt = val + 1
    out.append(f"  typedef enum logic [{width - 1}:0] {{")
    for i, (n, v) in enumerate(items):
        out.append(f"    P2_{n} = {width}'d{v}" + ("," if i + 1 < len(items) else ""))
    out.append(f"  }} {svname};   // {cname}")

out.append("")
out.append("endpackage")
if not LAYOUT:
    print("\n".join(out))
    sys.exit(0)

cpp = ["// GENERATED by tools/gen/gen_regs.py --layout-check (make regs-pkg-check): p2_regs_pkg's bit positions",
       "// against the C compiler's layout of the same headers.",
       '#include "types.h"', '#include "hw/pvr/pvr_regs.h"', '#include "refcore/core_structs.h"',
       '#include "refcore/refsw_lists_regtypes.h"', '#include "refcore/refsw_lists.h"',
       "#include <cstdio>", "#include <cstring>",
       "template<class T> static unsigned word(const T& t)",
       "{", "    static_assert(sizeof(T) == 4, \"a 32-bit word\");", "    unsigned w;", "    memcpy(&w, &t, 4);",
       "    return w;", "}",
       "static int n = 0, bad = 0;",
       "#define FIELD(T, F, LO, W) do { T t; memset(&t, 0, sizeof t); t.F = 0xFFFFFFFFu; n++; \\",
       "    const unsigned want = (unsigned)(((1ull << (W)) - 1) << (LO)), got = word(t); \\",
       "    if (got != want) { bad++; printf(\"regs-layout: %s.%s sets %08x, p2_regs_pkg has %08x\\n\", #T, #F, got, want); } \\",
       "} while (0)",
       "#define ENUMV(E, V) do { n++; if ((int)(E) != (V)) { bad++; \\",
       "    printf(\"regs-layout: %s is %d, p2_regs_pkg has %d\\n\", #E, (int)(E), (V)); } } while (0)",
       "int main()", "{"]
for t, f, lo, w in CHECKS:
    cpp.append(f"    FIELD({t}, {f}, {lo}, {w});")
for e, v in ENUM_CHECKS:
    cpp.append(f"    ENUMV({e}, {v});")
cpp += ['    printf("regs-layout: %d fields and enumerators, %d wrong\\n", n, bad);', "    return bad != 0;", "}"]
print("\n".join(cpp))

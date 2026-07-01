#!/usr/bin/env python3
# gen_pvr_regs.py - generate SystemVerilog PVR register typedefs + offsets from
# minicast's pvr_regs.h. Emits, for tsp_pkg:
#   * OFF_<NAME> localparam [12:0] = byte offset  (for every scalar _addr reg)
#   * a packed struct type <name>_t for each register that has a bitfield union
#     (fields listed MSB-first = reverse of the C LSB-first declaration so bit
#      positions match), else the register is a plain logic [31:0].
#   * pvr_regs_t : the aggregate of all scalar registers as named fields.
#
# Tables (FOG_TABLE 0x200, PALETTE_RAM 0x1000, TA_OL_POINTERS 0x600) are handled
# separately in reg_file as M10K and are excluded from the scalar struct.
#
# Usage: gen_pvr_regs.py <path/to/pvr_regs.h> > pvr_regs_gen.svh
import re, sys

HDR = sys.argv[1] if len(sys.argv) > 1 else \
    "../minicast/libswirl/hw/pvr/pvr_regs.h"
txt = open(HDR).read()

# ---- 1. scalar register offsets: NAME_addr 0xVALUE ----
# exclude table range markers (_START/_END) - handled as M10K tables.
TABLE_NAMES = {"FOG_TABLE", "TA_OL_POINTERS", "PALETTE_RAM"}
addr_re = re.compile(r'#define\s+(\w+)_addr\s+(0x[0-9A-Fa-f]+)')
regs = []   # (name, offset_int)
for m in addr_re.finditer(txt):
    name, off = m.group(1), int(m.group(2), 16)
    base = name.rsplit('_', 1)[0]
    if name.endswith("_START") or name.endswith("_END"):
        continue
    if name in TABLE_NAMES:
        continue
    regs.append((name, off))

# ---- 2. bitfield unions: union NAME_type { struct { u32 f : w; ... }; ... } ----
# capture the FIRST struct block's bitfields. If the union has no bitfield struct
# (e.g. {u32 i; f32 f;}), the register is plain 32-bit.
union_re = re.compile(r'union\s+(\w+)_type\s*\{(.*?)\n\};', re.DOTALL)
bf_re = re.compile(r'u32\s+(\w+)\s*:\s*(\d+)\s*;')
bitfields = {}   # regname -> [(field, width), ...] in C (LSB-first) order
for m in union_re.finditer(txt):
    uname, body = m.group(1), m.group(2)
    # only take bitfields inside the first `struct { ... }`
    sm = re.search(r'struct\s*\{(.*?)\}', body, re.DOTALL)
    if not sm:
        continue
    fields = [(f, int(w)) for f, w in bf_re.findall(sm.group(1))]
    if fields:
        bitfields[uname] = fields

def sv_ident(s):
    # sanitize a C field name into a legal SV identifier (avoid leading underscore
    # collisions / SV keywords are unlikely here but keep names verbatim otherwise)
    return s

out = []
out.append("// ====================================================================")
out.append("// AUTO-GENERATED from minicast pvr_regs.h by tools/gen_pvr_regs.py")
out.append("// Do not edit by hand. Scalar PVR registers -> named struct fields;")
out.append("// bitfield unions -> packed struct types (fields MSB-first to match")
out.append("// the C LSB-first bit layout). Tables (FOG/PAL) are M10K in reg_file.")
out.append("// ====================================================================")
out.append("")

# ---- offset localparams ----
for name, off in regs:
    out.append(f"    localparam [12:0] OFF_{name} = 13'h{off:03X};")
out.append("")

# ---- per-register bitfield struct types ----
# field type name = <lowercase name>_t
typed = {}   # regname -> sv type string
for name, off in regs:
    if name in bitfields:
        fields = bitfields[name]
        total = sum(w for _, w in fields)
        tname = name.lower() + "_reg_t"
        typed[name] = tname
        out.append(f"    typedef struct packed {{  // {name} ({total} bits used)")
        # SV declares MSB-first; C bitfields are LSB-first -> reverse.
        # If total < 32, pad the MSBs so the struct is exactly 32 bits.
        if total < 32:
            out.append(f"        logic [{32-total-1}:0] _pad_msb;")
        for f, w in reversed(fields):
            if w == 1:
                out.append(f"        logic        {sv_ident(f)};")
            else:
                out.append(f"        logic [{w-1}:0] {sv_ident(f)};")
        out.append(f"    }} {tname};   // == 32 bits")
        out.append("")
    else:
        typed[name] = "logic [31:0]"

# ---- aggregate pvr_regs_t + flat-vector bit positions ----
# In a packed struct the FIRST-declared field occupies the MOST-significant bits.
# We declare in `regs` order, so field k (0-based) sits at MSBs going down. Total
# width = 32 * N. The LSB position of field i (declared at index i) is:
#   lsb(i) = 32 * (N - 1 - i)
N = len(regs)
out.append("    typedef struct packed {")
for name, off in regs:
    out.append(f"        {typed[name]:<28} {name.lower()};")
out.append("    } pvr_regs_t;")
out.append(f"    localparam int PVR_REGS_N = {N};")
out.append("")

# ---- write-decode macro: assign DATA into the flat packed-vector slice of the
# matching field (no per-type cast needed since all fields are 32 bits). R must
# be a variable castable to a [32*N-1:0] vector (use the packed struct directly).
out.append("// Write-decode: case over byte offset OFF, writing DATA (32b) into")
out.append("// the packed-vector slice of the matching field of R (pvr_regs_t).")
out.append("`define PVR_REG_WRITE_CASE(R, OFF, DATA) \\")
lines = []
for i, (name, off) in enumerate(regs):
    lsb = 32 * (N - 1 - i)
    lines.append(f"    OFF_{name}: R[{lsb} +: 32] <= DATA;")
out.append(" \\\n".join(lines))
out.append("")

print("\n".join(out))

#!/bin/bash
# check_ref_copies.sh: the verbatim copies of refcore code in the testbenches have not drifted from refcore
# (PLAN 1.1, num 7.1). Every gate runs it. Under a second.
#
#   tools/check_ref_copies.sh [file ...]     default: every tb/**/ref_copies*.h
#   tools/check_ref_copies.sh --selftest     the checker itself: a good copy passes; a drifted, a missing, an ambiguous,
#                                            an unterminated, a duplicated and a misplaced one each fail
#
# The marker format is in tb/ref/ref_copies.h. Prints one line per copy that fails, with a diff, then
# "check_ref_copies: <n> copies in <m> files, <k> failed" and "check_ref_copies: PASS" / "FAIL" (exit code to match).
# REFCORE defaults to ../nulldc3/refsw3/refcore beside this repository.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
REFCORE=${REFCORE:-${NULLDC3:-$ROOT/../nulldc3}/refsw3/refcore}

check() {   # check <refcore dir> <file ...>
  python3 - "$@" <<'PY'
import difflib, sys
refcore, files = sys.argv[1], sys.argv[2:]
BEGIN, END = "// P2REF-COPY ", "// P2REF-END "
failed, ncopies, ids = 0, 0, {}
def bad(where, msg, diff=None):
    global failed
    failed += 1
    print(f"check_ref_copies: {where}: {msg}")
    for line in (diff or [])[:40]:
        print("    " + line.rstrip("\n"))
for path in files:
    try:
        lines = open(path, newline="").read().split("\n")
    except OSError as e:
        bad(path, f"cannot read: {e}")
        continue
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s.startswith(END):
            bad(f"{path}:{i + 1}", "P2REF-END without a P2REF-COPY")
            i += 1
            continue
        if not s.startswith(BEGIN):
            i += 1
            continue
        where = f"{path}:{i + 1}"
        parts = s[len(BEGIN):].split(" ", 2)
        if len(parts) < 3 or not parts[2].strip():
            bad(where, "marker needs <id> <file> <anchor>")
            i += 1
            continue
        cid, src, anchor = parts[0], parts[1], parts[2]
        ncopies += 1
        if cid in ids:
            bad(where, f"copy id {cid} also at {ids[cid]}")
        ids[cid] = where
        j = i + 1
        while j < len(lines) and not lines[j].strip().startswith((END, BEGIN)):
            j += 1
        if j >= len(lines) or lines[j].strip() != END + cid:
            bad(where, f"copy {cid} has no '{END}{cid}' line before the next marker or the end")
            i = j
            continue
        copy = lines[i + 1:j]
        i = j + 1
        try:
            ref = open(f"{refcore}/{src}", newline="").read().split("\n")
        except OSError as e:
            bad(where, f"copy {cid}: cannot read {src} in {refcore}: {e}")
            continue
        hits = [k for k, l in enumerate(ref) if anchor in l]
        if len(hits) != 1:
            bad(where, f"copy {cid}: the anchor {anchor!r} is on {len(hits)} lines of {src}, not on exactly one")
            continue
        if not copy or anchor not in copy[0]:
            bad(where, f"copy {cid}: its first line does not contain the anchor")
            continue
        k = hits[0]
        orig = ref[k:k + len(copy)]
        if orig != copy:
            diff = list(difflib.unified_diff([l + "\n" for l in orig], [l + "\n" for l in copy],
                                             f"refcore/{src}:{k + 1}", f"{path} copy {cid}"))
            bad(where, f"copy {cid} differs from {src} lines {k + 1}..{k + len(copy)}", diff)
print(f"check_ref_copies: {ncopies} copies in {len(files)} files, {failed} failed")
print("check_ref_copies: " + ("FAIL" if failed else "PASS"))
sys.exit(1 if failed else 0)
PY
}

if [ "${1:-}" = "--selftest" ]; then
  # a fake refcore and one ref_copies file per case, in build/
  T="$ROOT/build/check_ref_copies_selftest"
  rm -rf "$T" && mkdir -p "$T/ref"
  printf 'int a;\n    auto f = [&](int x) {\n        return x + 1;\n    };\nint twice;\nint twice;\n' > "$T/ref/r.cpp"
  good='// P2REF-COPY f r.cpp auto f = [&](int x)\n    auto f = [&](int x) {\n        return x + 1;\n    };\n// P2REF-END f\n'
  printf "$good" > "$T/good.h"
  printf "$good" | sed 's/x + 1/x + 2/' > "$T/drift.h"
  printf "$good" | sed 's/auto f = \[&\](int x)$/auto g = [\&](int x)/' > "$T/missing.h"
  printf '// P2REF-COPY t r.cpp int twice\nint twice;\n// P2REF-END t\n' > "$T/ambiguous.h"
  printf "$good" | sed '/P2REF-END/d' > "$T/unterminated.h"
  printf "$good" > "$T/dup1.h"; printf "$good" > "$T/dup2.h"
  printf '// P2REF-COPY m r.cpp auto f = [&](int x)\n        return x + 1;\n    };\n// P2REF-END m\n' > "$T/misplaced.h"
  printf "$good" | sed 's/    };/    };   /' > "$T/whitespace.h"
  st=0
  expect() {   # expect <exit code> <case> <files...>
    local want=$1 name=$2; shift 2
    check "$T/ref" "$@" > "$T/$name.log" 2>&1; local got=$?
    if [ "$got" = "$want" ]; then echo "check_ref_copies --selftest: $name: ok (exit $got)"
    else echo "check_ref_copies --selftest: $name: exit $got, want $want"; sed 's/^/    /' "$T/$name.log"; st=1; fi
  }
  expect 0 good "$T/good.h"
  expect 0 empty
  expect 1 drift "$T/drift.h"
  expect 1 missing "$T/missing.h"
  expect 1 ambiguous "$T/ambiguous.h"
  expect 1 unterminated "$T/unterminated.h"
  expect 1 duplicate-id "$T/dup1.h" "$T/dup2.h"
  expect 1 misplaced "$T/misplaced.h"
  expect 1 trailing-whitespace "$T/whitespace.h"
  echo "check_ref_copies --selftest: $([ $st = 0 ] && echo PASS || echo FAIL)"
  exit $st
fi

if [ $# -gt 0 ]; then
  files=("$@")
else
  mapfile -t files < <(find "$ROOT/tb" -name 'ref_copies*.h' 2>/dev/null | sort)
fi
[ -d "$REFCORE" ] || { echo "check_ref_copies: no refcore at $REFCORE"; echo "check_ref_copies: FAIL"; exit 1; }
check "$REFCORE" "${files[@]}"

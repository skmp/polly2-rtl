#!/bin/bash
# check_regs_pkg.sh: rtl/v1/pkg/p2_regs_pkg.sv is up to date with nulldc3's headers, and its bit positions are the C
# compiler's (make regs-pkg-check, conventions.md 5).
#   1. gen_regs.py regenerates into build/gen/; cmp with the checked-in file (out of date: make regs-pkg);
#   2. gen_regs.py --layout-check writes a C++ program that sets each field of each struct to all ones in the C type
#      and compares the word with the package's bits, and each enumerator with the package's value; it is compiled
#      with refsw3-offline's flags (the CXXFLAGS argument) and run.
#   tools/gen/check_regs_pkg.sh <nulldc3 dir> <c++ compiler> "<compiler flags>"
# Last line "regs-pkg-check: PASS" / "FAIL", exit code to match. About two seconds (the compile).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
N3=$1 CXX=$2 CXXFLAGS=$3
PKG="$ROOT/rtl/v1/pkg/p2_regs_pkg.sv" OUT="$ROOT/build/gen/p2_regs_pkg.sv"
LAY="$ROOT/build/gen/regs_layout_check"
mkdir -p "$ROOT/build/gen"
fail() { echo "regs-pkg-check: $1"; echo "regs-pkg-check: FAIL"; exit 1; }
python3 "$ROOT/tools/gen/gen_regs.py" "$N3" > "$OUT" || fail "the generator failed (above)"
if ! cmp -s "$OUT" "$PKG"; then
  diff -u "$PKG" "$OUT" | head -40
  fail "rtl/v1/pkg/p2_regs_pkg.sv differs from what nulldc3 gives (diff above): make regs-pkg"
fi
python3 "$ROOT/tools/gen/gen_regs.py" "$N3" --layout-check > "$LAY.cpp" || fail "the layout-check generator failed"
# shellcheck disable=SC2086
$CXX $CXXFLAGS -O0 "$LAY.cpp" -o "$LAY" || fail "the layout check does not compile (above)"
"$LAY" || fail "the package's bit positions are not the compiler's (above)"
echo "regs-pkg-check: PASS"

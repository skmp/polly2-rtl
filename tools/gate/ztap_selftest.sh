#!/bin/bash
# ztap_selftest.sh: build/tools/ztap_cmp's own rules on synthetic taps (PLAN M13; conventions.md 7.4.3), a step of
# tools/gate/gate_frames_hw.sh. The two zdumps of fit/zdump_data never tap a tile twice, so a ztap_cmp that kept a tile's
# FIRST entry passed them (M13's verifier); here a tile is tapped twice and the console's depth is the last entry's:
#
#   last      entry 1 wrong, entry 2 right   exit 0, "1 of 1 depths"
#   first     entry 1 right, entry 2 wrong   exit 1, "0 of 1 depths"
#   untapped  the pixel's tile not tapped    exit 1, "0 of 1 depths", "not tapped"
#   key       a key that is no stored depth  exit 1 (tb/common/zkey.h's bad bits)
#
# Writes build/tools/ztap_selftest/; prints "ztap_selftest: PASS" (exit 0) or the case that failed and "FAIL" (exit 1).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
Z=$ROOT/build/tools/ztap_cmp
W=$ROOT/build/tools/ztap_selftest
[ -x "$Z" ] || { echo "ztap_selftest: no $Z (make ztap-cmp)"; echo "ztap_selftest: FAIL"; exit 1; }
rm -rf "$W" && mkdir -p "$W"
# a tile's 32 x 32 keys, all <key> (hex): a positive depth's key is its bits << 32 (zkey.h, the Bits form)
tile() { awk -v tx="$1" -v ty="$2" -v k="$3" 'BEGIN { print "ZTAP", tx, ty; for (r = 0; r < 32; r++) { l = ""; for (i = 0; i < 32; i++) l = l (i ? " " : "") k; print l } }'; }
RIGHT=3b7a166000000000
WRONG=3f80000000000000
echo "(37, 70) tile (1, 2) at (5, 6): console 3b7a1660 refsw3 3b7a1660" > "$W/zdump.txt"
{ tile 1 2 $WRONG; tile 0 0 $WRONG; tile 1 2 $RIGHT; } > "$W/last.txt"
{ tile 1 2 $RIGHT; tile 1 2 $WRONG; } > "$W/first.txt"
{ tile 0 2 $RIGHT; tile 1 1 $RIGHT; } > "$W/untapped.txt"
tile 1 2 0000000012345678 > "$W/key.txt"
fail=0
check() {   # check <case> <exit> <pattern of the last line>
  local out st
  out=$("$Z" "$W/$1.txt" "$W/zdump.txt" 2>&1); st=$?
  if [ "$st" != "$2" ] || ! echo "$out" | tail -n 1 | grep -q "$3"; then
    echo "ztap_selftest: $1: exit $st (want $2), last line \"$(echo "$out" | tail -n 1)\" (want /$3/)"
    fail=1
  else
    echo "ztap_selftest: $1: exit $st, $(echo "$out" | tail -n 1)"
  fi
}
check last 0 '^ztap_cmp: 1 of 1 depths'
check first 1 '^ztap_cmp: 0 of 1 depths'
check untapped 1 '^ztap_cmp: 0 of 1 depths'
check key 1 '^ztap_cmp: 0 of 1 depths'
"$Z" "$W/untapped.txt" "$W/zdump.txt" | grep -q 'tile (1, 2) not tapped' || { echo "ztap_selftest: untapped: no \"not tapped\" line"; fail=1; }
[ "$fail" = 0 ] && echo "ztap_selftest: PASS" || echo "ztap_selftest: FAIL"
exit $fail

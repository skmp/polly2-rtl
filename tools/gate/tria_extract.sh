#!/bin/bash
# tria_extract.sh: the primitives of a dreamcast-tests page as unit vectors (PLAN 1.2 "triangles from console pages";
# M2 gate item 3, M3 later). For each test:
#   1. its PC build (gcc on pvr-tests/<test>/main.c with common/, as dreamcast-tests run2.sh `off` builds it) prints the
#      test's command stream (the same stream the console runs: common/pvrio.h);
#   2. the stream goes to refsw3-offline (built from $NULLDC3 into build/refsw3-offline by make refsw3-offline) with
#      `log /dev/stdout` first and, before every STARTRENDER, `regdump 0 40` of the render's registers (FPU_CULL_VAL,
#      HALF_OFFSET); the stream's own output commands (echo, dump32, png, tahash, scan32, ...) are dropped, so that
#      standard output carries the render log alone;
#   3. tools/gate/tria_conv turns the log's TRIA lines into build/vec/<test>.tri (tb/isp_edge/tri_rec.h).
# The converter's line ("<n> records ...") goes to build/vec/<test>.txt with the nulldc3 revision. Nothing is kept of
# the log. A test whose .tri is newer than refsw3-offline, tria_conv and the test's source is not redone.
#
#   tools/gate/tria_extract.sh [-j N] <test> ...
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
NULLDC3=${NULLDC3:-$ROOT/../nulldc3}
DCTESTS=${DCTESTS:-$ROOT/../dreamcast-tests}
OFF=$ROOT/build/refsw3-offline/refsw3-offline
CONV=$ROOT/build/tools/tria_conv
J=8
if [ "${1:-}" = -j ]; then J=$2; shift 2; fi
[ $# -gt 0 ] || { echo "usage: tria_extract.sh [-j N] <test> ..."; exit 2; }
[ -x "$OFF" ] || { echo "tria_extract: no $OFF (make refsw3-offline)"; exit 1; }
[ -x "$CONV" ] || { echo "tria_extract: no $CONV"; exit 1; }
rev=$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)

one() {
  local t=$1 src w out
  src=$DCTESTS/pvr-tests/$t/main.c
  [ -f "$src" ] || { echo "tria_extract: $t: no $src"; return 1; }
  out=$ROOT/build/vec/$t.tri
  if [ -f "$out" ] && [ "$out" -nt "$OFF" ] && [ "$out" -nt "$CONV" ] && [ "$out" -nt "$src" ]; then
    echo "tria_extract: $t: up to date ($(cat "$ROOT/build/vec/$t.txt" 2>/dev/null))"; return 0
  fi
  w=$ROOT/build/vec/$t.work
  rm -rf "$w" && mkdir -p "$w"
  gcc -O1 -w -I"$DCTESTS/common" -o "$w/pc" "$src" || { echo "tria_extract: $t: the PC build failed"; return 1; }
  "$w/pc" "$w" | awk -v d="$w" '
      BEGIN { k = 0; print "log /dev/stdout" }
      /^(echo|dump32|png|tahash|tastate|regdump|scan32|save|log)( |$)/ { next }
      /^reg STARTRENDER/ { printf "regdump 0 40 %s/r%d.regs\n", d, k; k++ }
      /^render( |$)/     { printf "regdump 0 40 %s/r%d.regs\n", d, k; k++ }
      { print }' | "$OFF" - 2> "$w/off.err" | "$CONV" "$w" "$out" > "$w/conv.txt" 2>&1
  local st=("${PIPESTATUS[@]}")
  if [ "${st[2]}" != 0 ] || [ "${st[3]}" != 0 ]; then
    echo "tria_extract: $t: failed (offline ${st[2]}, tria_conv ${st[3]})"; tail -n 3 "$w/off.err" "$w/conv.txt"
    rm -f "$out"; return 1
  fi
  echo "$(tail -1 "$w/conv.txt") (refsw3 $rev)" > "$ROOT/build/vec/$t.txt"
  rm -rf "$w"
  echo "tria_extract: $t: $(cat "$ROOT/build/vec/$t.txt")"
}
export -f one
export ROOT DCTESTS OFF CONV rev
mkdir -p "$ROOT/build/vec"
printf '%s\n' "$@" | xargs -P "$J" -I{} bash -c 'one {}'
st=0
for t in "$@"; do [ -f "$ROOT/build/vec/$t.tri" ] || st=1; done
exit $st

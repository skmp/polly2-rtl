#!/bin/bash
# capture_prerender.sh: pre-render captures for the tile-level testbenches (PLAN 1.3 "Inputs", M5): for every render
# of a case, the video memory and registers before it and refsw3-offline's video memory after it.
#
#   tools/gate/capture_prerender.sh [-j N] [--max R] <case> ...
#
#   <test>          a dreamcast-tests page test (pvr-tests/<test> or ta-tests/<test>): its PC build (as run2.sh `off`
#                   builds it, common/pvrio.h) prints the command stream the console runs; it goes to refsw3-offline
#                   (build/refsw3-offline, make refsw3-offline) with `save` inserted before and after each render
#                   trigger (reg STARTRENDER, render). A test that reads video memory back (pvrio_read32) gets
#                   refsw3-offline's answers, as in run2.sh `off`. The stream's png and log commands are dropped.
#   dump:<scene>    a polly2-data dump ($POLLY2_DUMPS): <scene>.pvrdmp, or the older vram_<scene>.bin +
#                   pvr_regs_<scene>.bin; one render
#   gen:<seed>      a scene of tb/gen/scenegen.cpp (build/tools/scenegen <seed> <folder>: one or more renders, each a
#                   vram.bin + pvr_regs.bin loaded before it)
#
# Writes build/pre/<case>/r<k>/{vram.bin.gz, pvr_regs.bin} (before render k, 32-bit-area order as refsw3-offline's
# `save`, gzipped; p2ref::load_state reads both forms) and r<k>/post/vram.bin.gz (after it); r<k>/skipped where
# refsw3-offline did not render (it refuses a render that reads a register never written, or a region array with no
# last entry); build/pre/<case>/info.txt. <case> is the test's name, dump_<scene> or gen_<seed>. Only the first R
# renders (--max, default 64) are captured; after them the stream goes nowhere and a readback gets zeros (a binary
# search by readbacks, zword's, runs thousands of renders otherwise). A case whose info.txt is newer than
# refsw3-offline and its source (the test's main.c, the dump, scenegen) is not redone. CAP_TIMEOUT: seconds refsw3-offline
# may take on one case (600).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
NULLDC3=${NULLDC3:-$ROOT/../nulldc3}
DCTESTS=${DCTESTS:-$ROOT/../dreamcast-tests}
POLLY2_DUMPS=${POLLY2_DUMPS:-$ROOT/../dreamster/polly2-rtl/polly2-data/dumps}
OFF=$ROOT/build/refsw3-offline/refsw3-offline
GEN=$ROOT/build/tools/scenegen
J=8
MAXR=64
CAP_TIMEOUT=${CAP_TIMEOUT:-600}
while [ $# -gt 0 ]; do
  case "$1" in
    -j) J=$2; shift 2 ;;
    --max) MAXR=$2; shift 2 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { echo "usage: capture_prerender.sh [-j N] [--max R] <test> | dump:<scene> | gen:<seed> ..."; exit 2; }
[ -x "$OFF" ] || { echo "capture_prerender: no $OFF (make refsw3-offline)"; exit 1; }
rev=$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)

one() {
  local c=$1 name src w out stream st
  case "$c" in
    dump:*) name=dump_${c#dump:}; src=$POLLY2_DUMPS/${c#dump:}.pvrdmp
            [ -f "$src" ] || src=$POLLY2_DUMPS/vram_${c#dump:}.bin ;;
    gen:*)  name=gen_${c#gen:}; src=$GEN ;;
    *)      name=$c; src=$DCTESTS/pvr-tests/$c/main.c; [ -f "$src" ] || src=$DCTESTS/ta-tests/$c/main.c ;;
  esac
  [ -f "$src" ] || { echo "capture_prerender: $c: no $src"; return 1; }
  out=$ROOT/build/pre/$name
  if [ -f "$out/info.txt" ] && [ "$out/info.txt" -nt "$OFF" ] && [ "$out/info.txt" -nt "$src" ]; then
    echo "capture_prerender: $name: up to date ($(cat "$out/info.txt"))"; return 0
  fi
  rm -rf "$out" && mkdir -p "$out/work"
  w=$out/work
  # the command stream, before the saves are put in
  case "$c" in
    dump:*)
      if [ "${src%.pvrdmp}" != "$src" ]; then printf 'pvrdmp %s\nrender\n' "$src" > "$w/stream.txt"
      else printf 'regs %s\nvram %s\nrender\n' "$POLLY2_DUMPS/pvr_regs_${c#dump:}.bin" "$src" > "$w/stream.txt"; fi
      stream="cat $w/stream.txt" ;;
    gen:*)
      "$GEN" "${c#gen:}" "$w/scene" > "$w/gen.txt" 2>&1 || { echo "capture_prerender: $name: scenegen failed"; tail -3 "$w/gen.txt"; return 1; }
      for d in $(ls -d "$w"/scene/r* | sort -V); do printf 'regs %s/pvr_regs.bin\nvram %s/vram.bin\nrender\n' "$d" "$d"; done > "$w/stream.txt"
      stream="cat $w/stream.txt" ;;
    *)
      gcc -O1 -w -I"$DCTESTS/common" -o "$w/pc" "$src" || { echo "capture_prerender: $name: the PC build failed"; return 1; }
      stream="$w/pc $w" ;;
  esac
  $stream | awk -v d="$out" -v w="$w" -v max="$MAXR" '
      function hex(s,  v, i, c) { v = 0; for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", tolower(substr(s, i, 1))); v = v * 16 + c - 1 } return v }
      BEGIN { k = 0 }
      # after the last render captured nothing goes to refsw3-offline; readbacks get zeros (as tria_extract.sh answers)
      k >= max && $1 == "dump32" && index($4, w "/readback.") == 1 {
        system("head -c " 4 * hex($3) " /dev/zero > " $4 ".tmp && mv " $4 ".tmp " $4); next }
      k >= max { next }
      /^(png|log)( |$)/ { next }
      /^reg STARTRENDER/ || /^render( |$)/ {
        system("mkdir -p " d "/r" k "/post")
        printf "echo P2CAP pre %d\nsave %s/r%d\n", k, d, k
        print
        printf "save %s/r%d/post\necho P2CAP post %d\n", d, k, k
        k++; fflush(); next }
      { print }
      $1 == "dump32" { fflush() }' | timeout "$CAP_TIMEOUT" "$OFF" - > "$w/off.log" 2>&1
  st=("${PIPESTATUS[@]}")
  # refsw3-offline exits 2 for a problem it reported (a register read but never written): the render it refused is
  # marked below; anything else is a failure
  if [ "${st[2]}" = 124 ]; then
    echo "capture_prerender: $name: refsw3-offline did not finish in $CAP_TIMEOUT s (a render that does not end?)"; return 1
  fi
  if [ "${st[2]}" != 0 ] && [ "${st[2]}" != 2 ]; then
    echo "capture_prerender: $name: refsw3-offline exit ${st[2]}"; tail -n 3 "$w/off.log"; return 1
  fi
  awk '$1 == "P2CAP" && $2 == "pre" { k = $3; bad = 0; next }
       /not rendering/ { bad = 1 }
       $1 == "P2CAP" && $2 == "post" && bad { print k }' "$w/off.log" | while read -r k; do touch "$out/r$k/skipped"; done
  ls "$out"/r*/vram.bin "$out"/r*/post/vram.bin 2>/dev/null | xargs -r -n 8 gzip -1 -f
  local n s
  n=$(ls -d "$out"/r* 2>/dev/null | wc -l)
  s=$(ls "$out"/r*/skipped 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] || { echo "capture_prerender: $name: no render"; tail -n 3 "$w/off.log"; return 1; }
  rm -rf "$w"
  echo "$n renders captured ($s not rendered by refsw3-offline), refsw3 $rev" > "$out/info.txt"
  echo "capture_prerender: $name: $(cat "$out/info.txt")"
}
export -f one
export ROOT DCTESTS POLLY2_DUMPS OFF GEN MAXR CAP_TIMEOUT rev
mkdir -p "$ROOT/build/pre"
printf '%s\n' "$@" | xargs -P "$J" -I{} bash -c 'one {}'
st=0
for c in "$@"; do
  case "$c" in dump:*) n=dump_${c#dump:} ;; gen:*) n=gen_${c#gen:} ;; *) n=$c ;; esac
  [ -f "$ROOT/build/pre/$n/info.txt" ] || st=1
done
exit $st

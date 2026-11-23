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
# search by readbacks, zword's, runs thousands of renders otherwise). R is recorded in build/pre/<case>/max. A case whose
# info.txt is newer than refsw3-offline and its source (the test's main.c, the dump, scenegen) is not redone if it is
# what --max R would make (same_max below: its recorded max is R, or its stream ended before both caps); otherwise it is
# captured again, also when R is smaller (the quick gates' --max 8 after the full gates' --max 256: a quick gate's
# inputs stay its first 8 renders). Until 2026-11-22 the max was not checked, and the full gates reused the quick
# gates' 8-render captures (48 fit/hw tests, e.g. ptchunkq: 200 renders, zovf_word: 256). CAP_TIMEOUT: seconds refsw3-offline
# may take on one case (600). The cases run N at a time (-j, default tools/gate/jobs.sh's) from one queue, longest first: by the
# seconds the case's last capture took (build/pre/<case>/secs), else by kind (a test, which may render up to R times,
# before a dump before a seed): PLAN 0 rule 8. CAP_PRE: the output folder (build/pre; a scratch one for a comparison).
#
# A case is complete or it fails, whatever the load: the program writing the command stream (the test's PC build, which
# gives up after 20 s without the answer to a readback: pvrio.h) must exit 0, as must refsw3-offline (or 2, above). A
# render's video memory is compressed as soon as its post save is complete (its post/pvr_regs.bin is written after its
# vram.bin), not at the case's end: 256 renders of a test are 4 GB uncompressed, and 16 such tests at once had the page
# cache's writeback hold refsw3-offline's saves past the 20 s of the readback searches (depthgaps_*, depth2_*: their
# captures came out short). A case that fails is tried once more after the queue, alone (CAP_RETRY=0: not).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
NULLDC3=${NULLDC3:-$ROOT/../nulldc3}
DCTESTS=${DCTESTS:-$ROOT/../dreamcast-tests}
POLLY2_DUMPS=${POLLY2_DUMPS:-$ROOT/../dreamster/polly2-rtl/polly2-data/dumps}
OFF=$ROOT/build/refsw3-offline/refsw3-offline
GEN=$ROOT/build/tools/scenegen
J=$(bash "$HERE/jobs.sh")
MAXR=64
CAP_TIMEOUT=${CAP_TIMEOUT:-600}
CAP_RETRY=${CAP_RETRY:-1}
PRE=${CAP_PRE:-$ROOT/build/pre}
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

# a capture made with --max M holds n = min(renders, M) renders; it is what --max MAXR would make iff n < M and n <= MAXR
# (the stream ended before either cap), or M = MAXR. Captures from before the max was recorded (no max file): M = n
# when n >= 8 (they were made with --max 8, 64 or 256), so they count only for MAXR = n; n < 8 is a stream that ended.
same_max() {
  local out=$1 n m
  n=$(ls -d "$out"/r* 2>/dev/null | wc -l)
  if [ -f "$out/max" ]; then m=$(cat "$out/max"); elif [ "$n" -lt 8 ]; then m=8; else m=$n; fi
  [ "$m" = "$MAXR" ] || { [ "$n" -lt "$m" ] && [ "$n" -le "$MAXR" ]; }
}
export -f same_max

one() {
  local c=$1 name src w out stream st
  case "$c" in
    dump:*) name=dump_${c#dump:}; src=$POLLY2_DUMPS/${c#dump:}.pvrdmp
            [ -f "$src" ] || src=$POLLY2_DUMPS/vram_${c#dump:}.bin ;;
    gen:*)  name=gen_${c#gen:}; src=$GEN ;;
    *)      name=$c; src=$DCTESTS/pvr-tests/$c/main.c; [ -f "$src" ] || src=$DCTESTS/ta-tests/$c/main.c ;;
  esac
  [ -f "$src" ] || { echo "capture_prerender: $c: no $src"; return 1; }
  out=$PRE/$name
  if [ -f "$out/info.txt" ] && [ "$out/info.txt" -nt "$OFF" ] && [ "$out/info.txt" -nt "$src" ] && same_max "$out"; then
    echo "capture_prerender: $name: up to date ($(cat "$out/info.txt"))"; return 0
  fi
  rm -rf "$out" && mkdir -p "$out/work"
  w=$out/work
  local t0=$SECONDS
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
  # the renders' video memory compressed behind refsw3-offline (the header): r<k> once r<k>/post/pvr_regs.bin is there
  : > "$w/running"
  (
    k=0
    while :; do
      if [ -e "$out/r$k/post/pvr_regs.bin" ]; then
        gzip -1 -f "$out/r$k/vram.bin" "$out/r$k/post/vram.bin" 2>/dev/null
        k=$((k + 1)); continue
      fi
      [ -e "$w/running" ] || break
      sleep 0.2
    done
  ) &
  local zpid=$!
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
  rm -f "$w/running"
  wait "$zpid"
  # the stream's program (a test's PC build gives up when a readback does not come: the capture would be short)
  if [ "${st[0]}" != 0 ]; then
    echo "capture_prerender: $name: the command stream's program exit ${st[0]} (a test's PC build: no readback answer in 20 s?)"; return 1
  fi
  if [ "${st[1]}" != 0 ]; then
    echo "capture_prerender: $name: the stream's filter (awk) exit ${st[1]}"; return 1
  fi
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
  [ "$n" -gt 0 ] || { echo "capture_prerender: $name: no render"; tail -n 3 "$w/off.log"; : > "$out/norender"; return 1; }
  rm -rf "$w"
  echo "$MAXR" > "$out/max"
  echo "$n renders captured ($s not rendered by refsw3-offline), refsw3 $rev" > "$out/info.txt"
  echo $((SECONDS - t0)) > "$out/secs"
  echo "capture_prerender: $name: $(cat "$out/info.txt")"
}
export -f one
export ROOT PRE DCTESTS POLLY2_DUMPS OFF GEN MAXR CAP_TIMEOUT rev
mkdir -p "$PRE"
# longest first: the last capture's seconds, else a test (up to R renders) 3, a dump 2, a seed 1
for c in "$@"; do
  case "$c" in dump:*) n=dump_${c#dump:} e=2 ;; gen:*) n=gen_${c#gen:} e=1 ;; *) n=$c e=3 ;; esac
  [ -f "$PRE/$n/secs" ] && e=$(( $(cat "$PRE/$n/secs") + 3 ))
  printf '%s %s\n' "$e" "$c"
done | sort -s -k1,1nr | cut -d' ' -f2- | xargs -P "$J" -I{} bash -c 'one {}'
missing() {   # the cases with no info.txt (failed, or not run); with -r not those that never render (no input)
  local c n r=0
  [ "$1" = -r ] && { r=1; shift; }
  for c in "$@"; do
    case "$c" in dump:*) n=dump_${c#dump:} ;; gen:*) n=gen_${c#gen:} ;; *) n=$c ;; esac
    [ -f "$PRE/$n/info.txt" ] || { [ $r = 1 ] && [ -f "$PRE/$n/norender" ]; } || echo "$c"
  done
}
if [ "$CAP_RETRY" != 0 ]; then
  for c in $(missing -r "$@"); do
    echo "capture_prerender: $c: once more, alone"
    one "$c"
  done
fi
[ -z "$(missing "$@")" ]

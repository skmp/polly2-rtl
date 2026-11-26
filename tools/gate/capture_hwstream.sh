#!/bin/bash
# capture_hwstream.sh: the console-archive gates' command streams (PLAN M13, 1.4 "gate_frames_hw.sh"; conventions.md
# 7.4.1, 7.4.3): a run's whole command stream as refsw3-offline was given it, for p2-offline to replay.
#
#   tools/gate/capture_hwstream.sh [-j N] <run> ...
#
#   <run>   <test>                      a dreamcast-tests page test (pvr-tests/<test>, ta-tests/<test>)
#           <test>+<reg>=<value>[+...]  the same with REG_OVERRIDE, as run2.sh builds it (fit/hw's detinf+084=7f800000)
#           <test>@<set>[+...]          the test with the tables of an archived set (fit/<test>_data/<set>.cases.json)
#
# Each run as dreamcast-tests run2.sh `off` makes it (its worker, unchanged in what it builds and pipes): the test's PC
# build, gcc -O1 -Wall -Wno-unused-function -I$DCTESTS/common <defs>; for a set the tables first (regen.py's two ways:
# a test with a gen.cpp through its generator `--regen <archive> <folder>`, built here into build/hwstream/.tools from the
# test's gen.cpp with model/build.sh's command, so that nothing is built in dreamcast-tests (a reader read.cpp too, for
# the hw gate and refsw3_known.sh: build/hwstream/.tools/<test>_read); the others through
# `python3 -B regen.py <test> <set> <folder>`); `pc --labels > labels.txt`; `pc <folder> | tee stream.txt |
# refsw3-offline -`. Unlike capture_prerender.sh nothing is cut: the whole stream (no --max), refsw3-offline's pages
# (page<n>.off.raw) and readback answers stay in the folder.
#
# Writes build/hwstream/<run>/{stream.txt, labels.txt, off.log, off.crc, page*.off*.raw, readbacks.txt, renders, secs,
# info.txt}. readbacks.txt: per readback of the stream (a `dump32 <addr> <n> <folder>/readback.bin`, the answer the program
# waits for; each overwrites the last) "<k> <md5>" of refsw3-offline's k-th answer, numbered into its own rb.<k>.bin on
# the way to refsw3-offline (stream.txt is the program's stream, unnumbered); a capture whose stream has readbacks and
# whose readbacks.txt is missing or of another count is redone.
# CAP_HW: another output folder. renders: the stream's render triggers (`render`, `reg STARTRENDER`); secs:
# refsw3-offline's seconds. A run is redone when its info.txt is older than refsw3-offline, the test's main.c or the
# set's archive. The program writing the stream must exit 0 (a test's PC build gives up a readback after 20 s), and
# refsw3-offline 0 or 2 (a problem it reported). HWCAP_TIMEOUT: seconds a run may take (1800). Longest first by the last
# capture's secs, else by name; N at a time (-j, tools/gate/jobs.sh's default).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
DCTESTS=${DCTESTS:-$ROOT/../dreamcast-tests}
REFCORE=${REFCORE:-$ROOT/../nulldc3/refsw3/refcore}
OFF=$ROOT/build/refsw3-offline/refsw3-offline
OUT=${CAP_HW:-$ROOT/build/hwstream}
J=$(bash "$HERE/jobs.sh")
HWCAP_TIMEOUT=${HWCAP_TIMEOUT:-1800}
while [ $# -gt 0 ]; do
  case "$1" in
    -j) J=$2; shift 2 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { echo "usage: capture_hwstream.sh [-j N] <test>[@<set>][+<reg>=<value>...] ..."; exit 2; }
[ -x "$OFF" ] || { echo "capture_hwstream: no $OFF (make refsw3-offline)"; exit 1; }
mkdir -p "$OUT/.tools"

# a test's generator or reader from its gen.cpp / read.cpp, in build/hwstream/.tools/<test>_<gen|read> (model/build.sh's
# command and flags, its rule: built when older than a source)
gen_of() {
  local t=$1 td=$2 k=${3:-gen} g=$OUT/.tools/$1_${3:-gen}
  ( flock 9
    if [ ! -x "$g" ] || [ -n "$(find "$td/$k.cpp" "$td"/*.h "$REFCORE"/pvr_*.h "$DCTESTS/model/gen_common.h" -newer "$g" 2>/dev/null | grep -v '/cases.h$')" ]; then
      g++ -O2 -std=c++17 -Wall -Wextra -fopenmp -I "$REFCORE" -I "$DCTESTS/model" -I "$td" "$td/$k.cpp" -o "$g.new.$$" \
        > "$g.log" 2>&1 && mv "$g.new.$$" "$g" || { rm -f "$g.new.$$"; exit 1; }
    fi ) 9> "$OUT/.tools/.lock" || return 1
  echo "$g"
}

# the stream's readbacks (dump32 to <folder>/readback.bin)
rb_count() { awk -v rb="$1/readback.bin" '$1 == "dump32" && $4 == rb { n++ } END { print n + 0 }' "$1/stream.txt" 2>/dev/null || echo 0; }

one() {
  local run=$1 base t set td src w ovr def st t0
  base=${run%%+*}; t=${base%%@*}; set=""; [ "$base" != "$t" ] && set=${base#*@}
  td=""; for g in pvr-tests ta-tests; do [ -d "$DCTESTS/$g/$t" ] && td=$DCTESTS/$g/$t; done
  [ -n "$td" ] && [ -f "$td/main.c" ] || { echo "capture_hwstream: $run: no test $t"; return 1; }
  src=$td/main.c
  w=$OUT/$run
  local arch=""; [ -n "$set" ] && arch=$DCTESTS/fit/${t}_data/$set.cases.json
  if [ -n "$set" ] && [ -f "$td/read.cpp" ]; then
    gen_of "$t" "$td" read > /dev/null || { echo "capture_hwstream: $run: the reader does not build"; return 1; }
  fi
  if [ -f "$w/info.txt" ] && [ "$w/info.txt" -nt "$OFF" ] && [ "$w/info.txt" -nt "$src" ] &&
     { [ -z "$arch" ] || [ "$w/info.txt" -nt "$arch" ]; } &&
     { [ "$(rb_count "$w")" = 0 ] || [ "$(cat "$w/readbacks.txt" 2>/dev/null | wc -l)" = "$(rb_count "$w")" ]; }; then
    echo "capture_hwstream: $run: up to date ($(cat "$w/info.txt"))"; return 0
  fi
  rm -rf "$w" && mkdir -p "$w/build"
  def=()
  if [ -n "$set" ]; then
    [ -f "$arch" ] || { echo "capture_hwstream: $run: no archive $arch"; return 1; }
    if [ -f "$td/gen.cpp" ]; then
      local gen; gen=$(gen_of "$t" "$td") || { echo "capture_hwstream: $run: the generator does not build"; return 1; }
      "$gen" --regen "$arch" "$w" > "$w/build/regen.log" 2>&1
    else
      (cd "$DCTESTS" && python3 -B regen.py "$t" "$set" "$w") > "$w/build/regen.log" 2>&1
    fi || { echo "capture_hwstream: $run: cannot make the tables of set $set"; tail -n 2 "$w/build/regen.log"; return 1; }
    def=("-DCASES_H=\"$w/cases.h\"")
  fi
  if [ "$run" != "$base" ]; then
    ovr=$(echo "${run#*+}" | tr '+' '\n' | awk -F= '{ printf "%s{0x%s,0x%s}", (NR > 1 ? "," : ""), $1, $2 }')
    def+=("-DREG_OVERRIDE=$ovr")
  fi
  gcc -O1 -Wall -Wno-unused-function -I"$DCTESTS/common" "${def[@]}" -o "$w/build/pc" "$src" > "$w/build/gcc.log" 2>&1 ||
    { echo "capture_hwstream: $run: the PC build failed"; tail -n 3 "$w/build/gcc.log"; return 1; }
  "$w/build/pc" --labels > "$w/labels.txt"
  t0=$(cut -d' ' -f1 /proc/uptime)
  # each readback (`dump32 <addr> <n> <folder>/readback.bin`, which the program reads and the next one overwrites) also
  # numbered, to rb.<k>.bin just before it: refsw3-offline's k-th answer, kept as its md5 in readbacks.txt
  # ("<k> <md5>"), the answer the RTL must give at the k-th readback of the replay (frames_hw_run.sh, frames_hw_cmp.py)
  "$w/build/pc" "$w" | tee "$w/stream.txt" |
    awk -v rb="$w/readback.bin" -v d="$w" '$1 == "dump32" && $4 == rb { k++; print $1, $2, $3, d "/rb." k ".bin" } { print; fflush() }' |
    timeout "$HWCAP_TIMEOUT" "$OFF" - > "$w/off.log" 2>&1
  st=("${PIPESTATUS[@]}")
  [ "${st[0]}" = 0 ] || { echo "capture_hwstream: $run: the command stream's program exit ${st[0]} (no readback answer in 20 s?)"; return 1; }
  [ "${st[3]}" = 124 ] && { echo "capture_hwstream: $run: refsw3-offline did not finish in $HWCAP_TIMEOUT s"; return 1; }
  [ "${st[3]}" = 0 ] || [ "${st[3]}" = 2 ] || { echo "capture_hwstream: $run: refsw3-offline exit ${st[3]}"; tail -n 3 "$w/off.log"; return 1; }
  grep -a '^PVRIO crc' "$w/off.log" > "$w/off.crc"
  grep -c '^render\( \|$\)\|^reg STARTRENDER' "$w/stream.txt" > "$w/renders"
  local nrb k
  nrb=$(rb_count "$w")
  : > "$w/readbacks.txt"
  for ((k = 1; k <= nrb; k++)); do
    [ -f "$w/rb.$k.bin" ] || { echo "capture_hwstream: $run: refsw3-offline wrote no readback $k"; rm -f "$w/info.txt"; return 1; }
    echo "$k $(md5sum < "$w/rb.$k.bin" | cut -d' ' -f1)" >> "$w/readbacks.txt"
    rm -f "$w/rb.$k.bin"
  done
  awk -v a="$t0" -v b="$(cut -d' ' -f1 /proc/uptime)" 'BEGIN { s = b - a; printf "%d\n", s < 0 ? 0 : s + 0.5 }' > "$w/secs"
  rm -rf "$w/build"
  echo "$(cat "$w/renders") renders, $(ls "$w"/*.off*.raw 2>/dev/null | wc -l) pages, $nrb readbacks, refsw3 $(git -C "$ROOT/../nulldc3" rev-parse --short HEAD 2>/dev/null)" > "$w/info.txt"
  echo "capture_hwstream: $run: $(cat "$w/info.txt")"
}
export -f one gen_of rb_count
export OUT OFF DCTESTS REFCORE ROOT HWCAP_TIMEOUT
for r in "$@"; do
  e=1; [ -f "$OUT/$r/secs" ] && e=$(( $(cat "$OUT/$r/secs") + 2 ))
  printf '%s %s\n' "$e" "$r"
done | sort -s -k1,1nr | cut -d' ' -f2- | xargs -P "$J" -I{} bash -c 'one "$1"' _ {}
fail=0
for r in "$@"; do [ -f "$OUT/$r/info.txt" ] || { echo "capture_hwstream: $r: not captured"; fail=1; }; done
exit $fail

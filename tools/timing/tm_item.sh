#!/bin/bash
# tm_item.sh: one work item of a timing run (PLAN MT0, 1.5; tools/timing/gate_timing.sh): some renders of one timemeas
# emission through p2-offline with the timing tap.
#
#   tools/timing/tm_item.sh <emission program> <stream file | -> <renders> <log> [p2-offline]
#
# <stream file>: the program's command stream written beforehand (the variants without readbacks); "-": the program runs
# live into p2-offline (the palette clock variants read their pixels back), with <log>'s folder for the readbacks.
# <renders>: P2_RENDERS (a-b[,c-d...]; "all": every render; "match:<regex>": the scenes whose key matches, a live
# program only: its stream is indexed by a first pass with every render skipped). The environment passes through (P2_TIMED_WRITES,
# P2_PLUSARGS, P2_VR_LAT, ...). The item passes when p2-offline exits 0, every render of <renders> the stream has was
# clocked and ended ("p2: render <n> isp ..."), and none "did not end"; the last line says so:
#   "tm_item: <k> renders clocked: PASS" or "tm_item: ...: FAIL".
set -u
prog=$1 stream=$2 renders=$3 log=$4
P2OFF=${5:-${P2OFF:-$(cd "$(dirname "$0")/../.." && pwd)/build/p2-offline/p2-offline}}
dir=$(dirname "$log")
mkdir -p "$dir"
export P2_TIMING=1
if [ "${renders#match:}" != "$renders" ]; then
  # the scenes whose key matches: a live program's stream is indexed first, by one pass with every render skipped (the
  # stream through tee; its readbacks answered from video memory as it stands, which changes no command)
  [ "$stream" = - ] || { echo "tm_item: match: only with a live program"; exit 2; }
  ix="$dir/$(basename "$log" .log).stream"
  mkdir -p "$dir/$(basename "$log" .log).rb0"
  ( unset P2_TIMED_WRITES; "$prog" "$dir/$(basename "$log" .log).rb0" | tee "$ix" | P2_RENDERS=-1 "$P2OFF" - > /dev/null 2>&1 ) ||
    { echo "tm_item: the index pass failed: FAIL"; exit 1; }
  renders=$(python3 "$(dirname "$0")/tm_items.py" "$ix" --match "${renders#match:}" --split 1 | cut -f2)
  rm -f "$ix"
  [ -n "$renders" ] || { echo "tm_item: no scene matches: FAIL"; exit 1; }
fi
[ "$renders" = all ] || export P2_RENDERS="$renders"
set -o pipefail
if [ "$stream" = - ]; then
  rd="$dir/$(basename "$log" .log).rb"
  mkdir -p "$rd"
  "$prog" "$rd" | "$P2OFF" - > "$log" 2>&1
  st=$?
else
  "$P2OFF" - < "$stream" > "$log" 2>&1
  st=$?
fi
clocked=$(grep -c '^p2: render [0-9]* isp ' "$log")
hung=$(grep -c '^p2: render [0-9]* did not end' "$log")
total=$(grep -c '^p2: render [0-9]* ' "$log")
skipped=$(grep -c '^p2: render [0-9]* skipped' "$log")
if [ "$renders" = all ]; then want=$total; else
  want=$(awk -v sel="$renders" -v n="$total" 'BEGIN { c = 0; k = split(sel, r, ","); for (i = 1; i <= k; i++) {
    split(r[i], ab, "-"); a = ab[1] + 0; b = (ab[2] == "" ? a : ab[2] + 0); if (b > n - 1) b = n - 1; if (b >= a) c += b - a + 1 }
    print c }')
fi
if [ $st != 0 ] || [ "$hung" != 0 ] || [ "$clocked" != "$want" ]; then
  echo "tm_item: exit $st, $clocked of $want renders clocked, $hung did not end, $skipped skipped: FAIL" >> "$log"
  tail -1 "$log"
  exit 1
fi
echo "tm_item: $clocked renders clocked ($skipped skipped): PASS" >> "$log"
tail -1 "$log"

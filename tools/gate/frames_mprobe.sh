#!/bin/bash
# frames_mprobe.sh: the frame gate's probe for the M6-M12 mutant lists (make frames-unit-mutants, PLAN M13): make
# p2-offline-mprobe copies it beside p2-offline in the object folder (tools/gate/mutants.py runs a probe from there, in the
# repository's root):
#   <object folder>/frames_mprobe --jobs N <case list> [config]
# tools/gate/frames_run.sh with that p2-offline on every case of the list (capture folders, one a line, cheapest first),
# N at a time, in the configuration (base); exits 1 as soon as one case fails (no further case is started and the ones
# running are stopped), 0 when all pass. Prints "frames_mprobe: <case>: FAIL" for the case that caught the mutant.
d=$(cd "$(dirname "$0")" && pwd)
[ "$1" = --jobs ] || { echo "usage: frames_mprobe --jobs N <case list> [config]"; exit 2; }
n=$2 list=$3 cfg=${4:-base}
# a render past FRAMES_PROBE_CLK_LIMIT clocks (50 M) is a render that did not end (as frames_probe.sh)
export P2_CLK_LIMIT=${P2_CLK_LIMIT:-${FRAMES_PROBE_CLK_LIMIT:-50000000}}
export d cfg
# the first case that fails: exit 255 stops xargs from starting another, and the cases still running are stopped (their
# p2-offline, this object folder's: the verdict is already the mutant's)
rm -f "$d/mprobe.stop"
xargs -P "$n" -I{} bash -c '
  [ -e "$d/mprobe.stop" ] && exit 0
  c={}; r=$d/run_$(basename "$c")_$cfg
  if bash tools/gate/frames_run.sh "$c" "$cfg" "$r" "$d/p2-offline" > "$r.log" 2>&1; then rm -rf "$r" "$r.log"; exit 0; fi
  [ -e "$d/mprobe.stop" ] && exit 0
  : > "$d/mprobe.stop"
  echo "frames_mprobe: $c: FAIL"; grep "^frames_cmp: .*\(differ\|exit\|did not\|no save\)" "$r.log" | head -3
  pkill -f "$d/p2-offline" 2> /dev/null
  exit 255' < "$list"
st=$?
[ $st = 0 ] && [ ! -e "$d/mprobe.stop" ] && { echo "frames_mprobe: PASS ($(wc -l < "$list") cases)"; exit 0; }
echo "frames_mprobe: FAIL"
exit 1

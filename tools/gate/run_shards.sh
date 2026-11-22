#!/bin/bash
# run_shards.sh: run one testbench as N slices on the work queue (tools/gate/pq.py, P2_J workers: tools/gate/jobs.sh) and merge
# the verdicts (conventions.md 7.8: a failing slice does not stop the others; the merged report decides). The gates
# build their queues themselves (tools/gate/lib.sh gate_queue); this is the stand-alone form (make fp-<p>-full).
#
#   tools/gate/run_shards.sh <name> <N> <log dir> <testbench> [args ...]
#
# Slice k runs `<testbench> [args ...] --shard k/N`, its output in <log dir>/log_<k>.txt. Prints each failed slice's
# last lines, the summed sections, checks and failures, the queue's time line and "<name>: PASS" / "<name>: FAIL" (exit
# code to match): PASS iff every slice exits 0 and its last line ends in PASS.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
name=$1 n=$2 dir=$3; shift 3
rm -rf "$dir" && mkdir -p "$dir"
items=$dir/items.txt
for k in $(seq 0 $((n - 1))); do
  printf '%s\t%s\t1\t1\ttb\tlog_%s.txt\t%s --shard %s\n' "$name" "$k/$n" "$k" "$*" "$k/$n"
done > "$items"
python3 "$HERE/pq.py" --name "$name" --dir "$dir" ${P2_J:+--jobs "$P2_J"} "$items" > "$dir/pq.out" 2>&1
st=$?
grep -v "^$name: [0-9]* items, \|^$name: PASS$\|^$name: FAIL$" "$dir/pq.out" | grep -v "^$name: wall "
line=$(grep "^$name: [0-9]* items, " "$dir/pq.out" | tail -1)
c=$(echo "$line" | sed -n 's/.* items, \([0-9]*\) checks, \([0-9]*\) failures (span \([0-9.]*\) s.*/\1 \2 \3/p')
set -- $c
echo "$name: $n shards, ${1:-0} checks, ${2:-0} failures (${3:-0} s)"
grep "^$name: wall " "$dir/pq.out"
if [ $st = 0 ]; then echo "$name: PASS"; else echo "$name: FAIL"; fi
exit $st

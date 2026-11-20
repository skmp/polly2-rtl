#!/bin/bash
# run_shards.sh: run one testbench as N shards in parallel and merge the verdicts (conventions.md 7.8: a failing
# shard does not stop the others; the merged report decides).
#
#   tools/gate/run_shards.sh <name> <N> <log dir> <testbench> [args ...]
#
# Shard k runs `<testbench> [args ...] --shard k/N`, its output in <log dir>/log_<k>.txt. Prints each shard's last two
# lines, the summed checks and failures, and "<name>: PASS" / "<name>: FAIL" (exit code to match): PASS iff every
# shard's last line ends in PASS.
set -u
name=$1 n=$2 dir=$3; shift 3
rm -rf "$dir" && mkdir -p "$dir"
t0=$(date +%s.%N)
seq 0 $((n - 1)) | xargs -P "$n" -I{} sh -c '"$@" --shard {}/'"$n"' > '"$dir"'/log_{}.txt 2>&1' sh "$@"
st=0 checks=0 fails=0
for k in $(seq 0 $((n - 1))); do
  f="$dir/log_$k.txt"
  last=$(tail -1 "$f" 2>/dev/null)
  case "$last" in *": PASS") ;; *) st=1; echo "$name: shard $k/$n did not pass:"; tail -30 "$f" | sed 's/^/    /' ;; esac
  line=$(grep -E ': [0-9]+ checks, [0-9]+ failures$' "$f" | tail -1)
  c=$(echo "$line" | sed -n 's/.*: \([0-9]*\) checks, \([0-9]*\) failures$/\1/p')
  x=$(echo "$line" | sed -n 's/.*: \([0-9]*\) checks, \([0-9]*\) failures$/\2/p')
  checks=$((checks + ${c:-0})); fails=$((fails + ${x:-0}))
done
secs=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
grep -h ': section ' "$dir"/log_*.txt | awk '{ s[$3] += $4 } END { for (k in s) printf "  section %s %d cases\n", k, s[k] }' | sort
echo "$name: $n shards, $checks checks, $fails failures ($secs s)"
if [ $st = 0 ]; then echo "$name: PASS"; else echo "$name: FAIL"; fi
exit $st

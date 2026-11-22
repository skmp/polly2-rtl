#!/bin/bash
# tools/gate/lib.sh: what every gate script shares (PLAN 0 rules 2 and 8, conventions.md 2 and 7.8). Source it:
#
#   . "$(dirname "$0")/lib.sh"
#   gate_begin <gate>                 build/gate/<gate>/ (cleared, but for its cost file cost.txt); the revision header
#   gate_step <name> <command ...>    runs the command, its output in build/gate/<gate>/<name>.log; prints and records
#                                     "<name>: PASS (<s> s)" or "<name>: FAIL (<s> s)" with the log's last lines
#   gate_queue <name> <items> [pq options]   the work items of the file <items> (tools/gate/pq.py's format) on one
#                                     queue of $J workers, longest first by build/gate/<gate>/cost.txt (the last run's
#                                     seconds per item); a step <name> whose log has every group's verdict; records a
#                                     line per group (its items, checks, span, CPU, slowest item)
#   gate_item <items> <group> <id> <estimate> <slots> <tb|step> <log> <command ...>   appends an item to <items>
#   gate_mutants <name> <mutants file> [mutants.py options]   tools/gate/mutants.py on $J slots (builds and probe runs on
#                                     one queue); a step <name>, the verdict of every mutant and the count in the summary
#   gate_end                          writes build/gate/<gate>/summary.txt (header, the runtime-switch check, one line
#                                     per step, the time line, "<gate>: PASS" / "FAIL" last), prints the verdict, exits
#                                     0 / 1
#
# The job budget (PLAN 0 rule 8): P2_J, default nproc - 4 but at most the physical cores (tools/gate/jobs.sh); each
# gate's own variable (FP_J, ISP_TILE_J, ...) defaults to it. P2_POLE=0: the queue never holds slots back beside a
# long item (tools/gate/pqlib.py's pole rule; on by default). The captures: CAP_TIMEOUT, CAP_RETRY, CAP_PRE
# (tools/gate/capture_prerender.sh). The time line: the gate's wall time, the CPU time of everything it ran (bash's `times`: user + system
# of the children it waited for), the utilisation CPU / wall / J, and the slowest work item (a queue's item, or a step
# that ran alone).
#
# The revision header (conventions.md 2): nulldc3 HEAD and refsw3-dirty (clean, or the first 8 hex digits of the md5
# of `git status --porcelain` and `git diff HEAD` of refsw3 and refsw3-offline: the content, not only the file names),
# dreamcast-tests HEAD, polly2-rtl HEAD (+dirty when the working tree has changes).
# The runtime-switch check (PLAN 1.1) is the check_ref_switches step's verdict when the gate ran one, else a run of
# tools/check_ref_switches.sh --no-hwpkg made by gate_end.

P2_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export NULLDC3=${NULLDC3:-$P2_ROOT/../nulldc3}
export REFCORE=${REFCORE:-$NULLDC3/refsw3/refcore}
export DCTESTS=${DCTESTS:-$P2_ROOT/../dreamcast-tests}
MAKE=${MAKE:-make}
export P2_J=${P2_J:-$(bash "$P2_ROOT/tools/gate/jobs.sh")}

# CPU_NOW: the CPU seconds (user + system) of the children this shell has waited for, from `times` (run in this shell,
# not in a command substitution's subshell, whose children are its own)
cpu_now() {
  times > "$P2_ROOT/build/gate/.times.$$"
  CPU_NOW=$(tail -1 "$P2_ROOT/build/gate/.times.$$" |
            awk '{ s = 0; for (i = 1; i <= 2; i++) { split($i, p, "m"); s += p[1] * 60 + p[2] } printf "%.1f", s }')
  rm -f "$P2_ROOT/build/gate/.times.$$"
}
# mono_now: seconds since boot (/proc/uptime: monotonic; WSL steps the wall clock, and date-based spans came out
# negative)
mono_now() { cut -d' ' -f1 /proc/uptime; }
# GATE_SLOW / GATE_SLOW_S: the slowest work item so far
gate_slow() {   # gate_slow <what> <seconds>
  if awk -v a="$2" -v b="${GATE_SLOW_S:-0}" 'BEGIN { exit !(a > b) }'; then GATE_SLOW=$1; GATE_SLOW_S=$2; fi
}

rev_header() {
  local n3 dirty dct p2
  n3=$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null || echo "none")
  if [ -z "$(git -C "$NULLDC3" status --porcelain refsw3 refsw3-offline 2>/dev/null)" ]; then
    dirty=clean
  else
    dirty=$({ git -C "$NULLDC3" status --porcelain refsw3 refsw3-offline; git -C "$NULLDC3" diff HEAD -- refsw3 refsw3-offline; } |
            md5sum | cut -c1-8)
  fi
  dct=$(git -C "$DCTESTS" rev-parse --short HEAD 2>/dev/null || echo "none")
  if p2=$(git -C "$P2_ROOT" rev-parse --short HEAD 2>/dev/null); then
    [ -n "$(git -C "$P2_ROOT" status --porcelain 2>/dev/null)" ] && p2="$p2+dirty"
  else
    p2=untracked
  fi
  echo "nulldc3 $n3 refsw3-dirty $dirty"
  echo "dreamcast-tests $dct ; polly2-rtl $p2"
}

gate_begin() {
  GATE=$1
  GATE_DIR="$P2_ROOT/build/gate/$GATE"
  # the cost file survives (the queues' order: the last run's seconds per item)
  local keep="$P2_ROOT/build/gate/.cost-$GATE.txt"
  rm -f "$keep"
  [ -f "$GATE_DIR/cost.txt" ] && mv "$GATE_DIR/cost.txt" "$keep"
  rm -rf "$GATE_DIR" && mkdir -p "$GATE_DIR"
  [ -f "$keep" ] && mv "$keep" "$GATE_DIR/cost.txt"
  J=${J:-$P2_J}
  GATE_SLOW="" GATE_SLOW_S=0
  cpu_now
  GATE_CPU0=$CPU_NOW
  GATE_HEADER=$(rev_header)
  GATE_LINES=()
  GATE_FAILED=0
  GATE_T0=$(mono_now)
  echo "$GATE_HEADER"
}

gate_step() {
  local name=$1; shift
  local t0 t1 st secs c0 cpu
  t0=$(mono_now)
  cpu_now
  c0=$CPU_NOW
  ( cd "$P2_ROOT" && "$@" ) > "$GATE_DIR/$name.log" 2>&1
  st=$?
  t1=$(mono_now)
  secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
  cpu_now
  cpu=$(awk -v a="$c0" -v b="$CPU_NOW" 'BEGIN { printf "%.1f", b - a }')
  [ -z "${GATE_IN_QUEUE:-}" ] && gate_slow "step $name" "$secs"
  if [ $st = 0 ]; then
    GATE_LINES+=("$name: PASS ($secs s, CPU $cpu s)")
    echo "$name: PASS ($secs s, CPU $cpu s)"
  else
    GATE_LINES+=("$name: FAIL ($secs s, CPU $cpu s, exit $st; build/gate/$GATE/$name.log)")
    GATE_FAILED=1
    echo "$name: FAIL ($secs s, CPU $cpu s, exit $st)"
    tail -15 "$GATE_DIR/$name.log" | sed 's/^/    /'
  fi
}

gate_item() {   # gate_item <items file> <group> <id> <estimate> <slots> <tb|step> <log> <command ...>
  local f=$1 g=$2 id=$3 est=$4 sl=$5 kind=$6 log=$7; shift 7
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$g" "$id" "$est" "$sl" "$kind" "$log" "$*" >> "$f"
}

gate_queue() {  # gate_queue <step name> <items file> [pq.py options]
  local name=$1 items=$2; shift 2
  GATE_IN_QUEUE=1 gate_step "$name" python3 "$P2_ROOT/tools/gate/pq.py" --name "$name" --dir "$GATE_DIR" --jobs "$J" \
    --cost "$GATE_DIR/cost.txt" "$@" "$items"
  local l
  while IFS= read -r l; do GATE_LINES+=("    $l"); echo "    $l"; done < <(
    grep -E '^[^ ]+: [0-9]+ items, |^[^ ]+: (PASS|FAIL) \(|^[^ ]+: (item .* )?did not pass|^'"$name"': wall ' "$GATE_DIR/$name.log")
  l=$(sed -n 's/^'"$name"': wall .*, slowest \(.*\) \([0-9.]*\) s$/\1 \2/p' "$GATE_DIR/$name.log" | tail -1)
  [ -n "$l" ] && gate_slow "${l% *}" "${l##* }"
}

gate_mutants() {   # gate_mutants <step name> <mutants file> [mutants.py options]: the mutants on one queue of $J slots
  local name=$1 file=$2; shift 2
  GATE_IN_QUEUE=1 gate_step "$name" python3 "$P2_ROOT/tools/gate/mutants.py" "$file" --jobs "$J" \
    --cost "$GATE_DIR/cost.txt" "$@"
  local l
  while IFS= read -r l; do GATE_LINES+=("    $l"); echo "    $l"; done < <(
    grep -E ' (caught|SURVIVED|ERROR|passes|CAUGHT)|-mutants: control .*FAIL|of [0-9]+ caught|-mutants: wall ' "$GATE_DIR/$name.log")
  l=$(sed -n 's/^.*-mutants: wall .*, slowest \(.*\) \([0-9.]*\) s$/\1 \2/p' "$GATE_DIR/$name.log" | tail -1)
  [ -n "$l" ] && gate_slow "$name ${l% *}" "${l##* }"
}

gate_end() {
  local sw verdict total
  if [ -f "$GATE_DIR/check_ref_switches.log" ]; then
    sw=$(tail -1 "$GATE_DIR/check_ref_switches.log")
  else
    sw=$(bash "$P2_ROOT/tools/check_ref_switches.sh" --no-hwpkg 2>&1 | tail -1)
    case "$sw" in *PASS) ;; *) GATE_FAILED=1 ;; esac
  fi
  verdict=$([ "$GATE_FAILED" = 0 ] && echo PASS || echo FAIL)
  total=$(awk -v a="$GATE_T0" -v b="$(mono_now)" 'BEGIN { printf "%.1f", b - a }')
  local cpu tline
  cpu_now
  cpu=$(awk -v a="$GATE_CPU0" -v b="$CPU_NOW" 'BEGIN { printf "%.1f", b - a }')
  tline=$(awk -v w="$total" -v c="$cpu" -v j="$J" -v s="$GATE_SLOW" -v ss="$GATE_SLOW_S" 'BEGIN {
    printf "time: wall %.1f s, CPU %.1f s, J %d, utilisation %.0f %% (CPU / wall / J); slowest item %s (%.1f s)",
           w, c, j, (w > 0 ? 100 * c / w / j : 0), (s == "" ? "-" : s), ss }')
  {
    echo "$GATE_HEADER"
    echo "switches: $sw"
    printf '%s\n' "${GATE_LINES[@]}"
    echo "$tline"
    echo "total: $total s"
    echo "$GATE: $verdict"
  } > "$GATE_DIR/summary.txt"
  echo "$tline"
  echo "summary: build/gate/$GATE/summary.txt ($total s)"
  echo "$GATE: $verdict"
  [ "$verdict" = PASS ]
  exit $?
}

# A unit testbench in slices (--shard k/N) on the queue, and their merged report (the lines run_shards.sh printed).
# With cal = 1 one more item, the calibration: a slice that owns no vector (--shard 3999999999/4000000000), whose checks
# are the ones every process makes once whatever its slice (the vector files it loads: one check each); the report then
# also gives the checks of the vectors, sum - N x that, which do not depend on N.
#   shard_items <items> <group> <N> <log dir, under the gate's> <cal 0|1> <estimate> <command ...>
shard_items() {
  local f=$1 g=$2 n=$3 d=$4 cal=$5 est=$6; shift 6
  local k
  for k in $(seq 0 $((n - 1))); do gate_item "$f" "$g" "$k/$n" "$est" 1 tb "$d/log_$k.txt" "$@" --shard "$k/$n"; done
  [ "$cal" = 1 ] && gate_item "$f" "$g-cal" cal 1 1 tb "$d/cal.txt" "$@" --shard 3999999999/4000000000
  return 0
}
#   shard_report <group> <log dir> <N>: the sections' cases summed, "<group>: <N> shards, <c> checks, <f> failures",
#   and with a calibration log "<group>: <v> checks of the vectors (<c> - <N> x <c0> ...)"
shard_report() {
  local g=$1 d=$GATE_DIR/$2 n=$3 c f c0
  grep -h ': section ' "$d"/log_*.txt 2>/dev/null | awk '{ s[$3] += $4 } END { for (k in s) printf "  section %s %d cases\n", k, s[k] }' | sort
  read -r c f < <(for x in "$d"/log_*.txt; do grep -E ': [0-9]+ checks, [0-9]+ failures$' "$x" | tail -1; done |
                  awk '{ c += $(NF - 3); f += $(NF - 1) } END { print c + 0, f + 0 }')
  echo "$g: $n shards, $c checks, $f failures"
  if [ -f "$d/cal.txt" ]; then
    c0=$(grep -E ': [0-9]+ checks, [0-9]+ failures$' "$d/cal.txt" | tail -1 | awk '{ print $(NF - 3) }')
    echo "$g: $((c - n * c0)) checks of the vectors ($c - $n x $c0, the checks each process makes once: the vector files it loads)"
  fi
}

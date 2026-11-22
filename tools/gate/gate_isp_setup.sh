#!/bin/bash
# gate_isp_setup.sh: the M4 gate (PLAN M4), run by make isp-setup / isp-setup-full / isp-setup-mutants.
#
#   tools/gate/gate_isp_setup.sh [--full | --mutants]
#
#   quick (isp-setup)          hw-pkg-check; isp-prog-check (rtl/v1/pkg/p2_isp_prog_pkg.sv is the generator's output, and
#                              the testbench's copy of the schedule, build/gen/p2_isp_prog.h, comes from the same run);
#                              check_ref_copies on the setup's and the edge's copies (tb/isp_setup/ref_copies_setup.h,
#                              tb/isp_edge/ref_copies_edge.h), check_ref_switches; the console pages' primitives (make
#                              isp-edge-vec isp-depth-vec: build/vec); the schedule (the lengths against the measured
#                              16 / 19, reported); then the four gate items:
#                                1. the graph check (gen_setup_prog --check: 1M random primitives and every directed one,
#                                   the literals and the console pages' records);
#                                2. the function: the testbench's directed, tria (one record in eight) and random (500k)
#                                   sections and stream, in ISP_SETUP_SHARDS slices on the queue;
#                                3. the program consistency: checked by the testbench on every clock of every section;
#                                4. the cycle section (shard 0);
#                              with the build and lint-isp-setup between
#   --full (isp-setup-full)    the same with --full: the graph check on 10M, every tria record, 5M random; under
#                              /tmp/polly2-rtl-gate.lock
#   --mutants                  tools/gate/mutants.py on tb/isp_setup/mutants.txt (rtl/v1/isp) and mutants_gen.txt (the
#                              generator's graphs); under the lock
#
# Ends with "<gate>: PASS" or "<gate>: FAIL" (exit code to match); build/gate/<gate>/summary.txt with the revision header,
# the inputs, each step's checks / failures line and the time line (lib.sh). Environment: ISP_SETUP_J (the queue's slots
# and make -j: P2_J: tools/gate/jobs.sh), ISP_SETUP_SHARDS (the quick run's slices, 12), ISP_SETUP_FULL_SHARDS (the full run's,
# 96: a fixed number, so that a run's report does not depend on J), ISP_SETUP_MUT_NJOBS (each mutant build's make -j, 2).
# The graph check (8 threads), lint and the slices with a calibration item run on one queue (PLAN 0 rule 8); a slice's
# checks include the ones its process makes once (loading the vector files), so the summed checks grow by that much for
# every slice more; the checks of the vectors (sum less N times the calibration's), the sections' cases and the jobs do
# not depend on N. The program trace's checks are one per clock and the stream sections' stalls come from one generator
# per process: they depend on the slices (at the default 12, the M4 numbers). The 'shard 0' lines are slice 0's (of N).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
case "$mode" in
  quick)     gate=isp-setup ;;
  --full)    gate=isp-setup-full ;;
  --mutants) gate=isp-setup-mutants ;;
  *)         echo "usage: gate_isp_setup.sh [--full | --mutants]"; exit 2 ;;
esac
if [ "$mode" != quick ] && [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock bash "$0" "$@"
fi

. "$HERE/lib.sh"
J=${ISP_SETUP_J:-$P2_J}
SHARDS=${ISP_SETUP_SHARDS:-12}
[ "$mode" = --full ] && SHARDS=${ISP_SETUP_FULL_SHARDS:-96}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}

note() { GATE_LINES+=("    $1"); echo "    $1"; }
tb_lines() {   # tb_lines <step name>: its checks / failures line and its sections into the summary
  local name=$1
  local line
  while IFS= read -r line; do note "$line"; done < <(
    grep -E '^  section |: [0-9]+ ((shards|items), [0-9]+ )?checks, [0-9]+ failures|: [0-9]+ checks of the vectors|graph-check: [0-9]' "$GATE_DIR/$name.log" |
    grep -v '^isp_setup: section' | sed 's/^isp_setup: //')
}
tb_step() {   # tb_step <step name> <command ...>: the step, its checks / failures line and its sections in the summary
  local name=$1; shift
  gate_step "$name" "$@"
  tb_lines "$name"
}
mut_step() {   # mut_step <step name> <mutants file>
  gate_mutants "$1" "$2" --njobs "${ISP_SETUP_MUT_NJOBS:-2}"
}
shards() {    # shards <pattern>: the matching lines of every shard log, summed where they are counts
  while IFS= read -r l; do note "shard 0 ${l#isp_setup: }"; done < <(
    grep -hE "$1" "$GATE_DIR"/shards/log_0.txt 2>/dev/null | cut -c1-400)
}

gate_begin "$gate"
gate_step hw-pkg-check       $MAKE -s hw-pkg-check
gate_step isp-prog-check     $MAKE -s isp-prog-check
gate_step check_ref_copies   bash tools/check_ref_copies.sh tb/isp_setup/ref_copies_setup.h tb/isp_edge/ref_copies_edge.h
gate_step check_ref_switches bash tools/check_ref_switches.sh --no-hwpkg
if [ "$mode" = --mutants ]; then
  mut_step mutants     tb/isp_setup/mutants.txt
  mut_step mutants-gen tb/isp_setup/mutants_gen.txt
else
  gate_step vec $MAKE -s isp-edge-vec isp-depth-vec
  note "inputs: $(ls build/vec/*.trz 2>/dev/null | wc -l) console tests' records (build/vec), $DCTESTS"
  # the schedule: the scheduler's lengths at the ARCHITECTURE 6 parameters, against the measured lengths (reported: the
  # parameters are fitted on the triangle, PLAN 0 rule 6)
  while IFS= read -r l; do note "schedule: $l"; done < <(grep -E '^ISP setup|^(TRI|QUAD|MOD):' build/gen/p2_isp_prog.txt | cut -c1-200)
  gate_step isp-prog-sweep $MAKE -s isp-prog-sweep
  note "$(tail -1 "$GATE_DIR/isp-prog-sweep.log")"
  gate_step build $MAKE -s -j"$J" NJOBS="$J" isp-setup-build
  items=$GATE_DIR/items.txt
  : > "$items"
  gate_item "$items" lint-isp-setup - 2 1 step lint-isp-setup.log $MAKE -s lint-isp-setup
  graph_n=""
  [ "$mode" = --full ] && graph_n=ISP_GRAPH_N=10000000
  gate_item "$items" graph-check - 20 8 step graph-check.log $MAKE -s isp-setup-graph ISP_GRAPH_THREADS=8 $graph_n
  name=isp-setup flag=""
  [ "$mode" = --full ] && name=isp-setup-full flag=--full
  shard_items "$items" "$name" "$SHARDS" shards 1 10 build/obj_isp_setup/tb $flag
  gate_queue queue "$items"
  tb_lines graph-check
  shard_report "$name" shards "$SHARDS" > "$GATE_DIR/$name.log"
  tb_lines "$name"
  # the job counts of every shard, summed (the kill count in brackets too: before 2026-11-22 the last shard's was shown);
  # the cycle checks and the program trace of shard 0
  for s in directed tria random stream; do
    while IFS= read -r l; do note "$l"; done < <(
      grep -h "^isp_setup: $s: [0-9]* jobs" "$GATE_DIR"/shards/log_*.txt 2>/dev/null | awk -v s="$s" '
        { for (i = 1; i <= NF; i++) if ($i ~ /^\(?[0-9]+$/) { v[i] += ($i ~ /^\(/ ? substr($i, 2) : $i); p[i] = ($i ~ /^\(/) }
          n = NF; line = $0 }
        END { if (n) { split(line, w, " "); out = ""; for (i = 1; i <= n; i++) out = out (i > 1 ? " " : "") ((i in v) ? (p[i] ? "(" : "") v[i] : w[i]);
                       print out } }' | sed 's/^isp_setup: //')
  done
  shards 'cycle:'
  shards 'tria: [0-9]* tests'
  while IFS= read -r l; do note "$l"; done < <(
    grep -h "program trace: [0-9]* checks" "$GATE_DIR"/shards/log_*.txt 2>/dev/null |
    awk '{ n += $4 } END { printf "program trace: %d checks over all shards (every issued micro-word and register write against the schedule)\n", n }')
fi
gate_end

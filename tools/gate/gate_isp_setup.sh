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
#                                   sections and stream, sharded ISP_SETUP_SHARDS ways;
#                                3. the program consistency: checked by the testbench on every clock of every section;
#                                4. the cycle section (shard 0);
#                              with the build and lint-isp-setup between
#   --full (isp-setup-full)    the same with --full: the graph check on 10M, every tria record, 5M random; under
#                              /tmp/polly2-rtl-gate.lock
#   --mutants                  tools/gate/mutants.py on tb/isp_setup/mutants.txt (rtl/v1/isp) and mutants_gen.txt (the
#                              generator's graphs); under the lock
#
# Ends with "<gate>: PASS" or "<gate>: FAIL" (exit code to match); build/gate/<gate>/summary.txt with the revision header,
# the inputs and each step's checks / failures line. Environment: ISP_SETUP_J (make -j, 12), ISP_SETUP_SHARDS (12),
# ISP_SETUP_MUT_JOBS (parallel mutant builds, 6).
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
J=${ISP_SETUP_J:-12}
SHARDS=${ISP_SETUP_SHARDS:-12}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}

note() { GATE_LINES+=("    $1"); echo "    $1"; }
tb_step() {   # tb_step <step name> <command ...>: the step, its checks / failures line and its sections in the summary
  local name=$1; shift
  gate_step "$name" "$@"
  local line
  while IFS= read -r line; do note "$line"; done < <(
    grep -E '^  section |: [0-9]+ (shards, [0-9]+ )?checks, [0-9]+ failures|graph-check: [0-9]' "$GATE_DIR/$name.log" |
    grep -v '^isp_setup: section' | sed 's/^isp_setup: //')
}
mut_step() {   # mut_step <step name> <mutants file>
  tb_step "$1" python3 tools/gate/mutants.py "$2" --jobs "${ISP_SETUP_MUT_JOBS:-6}" --njobs 2
  grep -E 'caught|SURVIVED|ERROR|control' "$GATE_DIR/$1.log" | sed 's/^/    /'
  while IFS= read -r l; do GATE_LINES+=("    $l"); done < <(grep -E ' (caught|SURVIVED|ERROR)' "$GATE_DIR/$1.log")
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
  if [ "$mode" = --full ]; then
    tb_step graph-check $MAKE -s isp-setup-graph ISP_GRAPH_N=10000000
  else
    tb_step graph-check $MAKE -s isp-setup-graph
  fi
  gate_step build $MAKE -s -j"$J" NJOBS="$J" isp-setup-build
  gate_step lint-isp-setup $MAKE -s lint-isp-setup
  if [ "$mode" = --full ]; then
    tb_step isp-setup-full bash tools/gate/run_shards.sh isp-setup-full "$SHARDS" "$GATE_DIR/shards" \
      build/obj_isp_setup/tb --full
  else
    tb_step isp-setup-tb bash tools/gate/run_shards.sh isp-setup "$SHARDS" "$GATE_DIR/shards" build/obj_isp_setup/tb
  fi
  # the job counts of every shard; the cycle checks and the program trace of shard 0
  for s in directed tria random stream; do
    while IFS= read -r l; do note "$l"; done < <(
      grep -h "^isp_setup: $s: [0-9]* jobs" "$GATE_DIR"/shards/log_*.txt 2>/dev/null | awk -v s="$s" '
        { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) v[i] += $i; n = NF; line = $0 }
        END { if (n) { split(line, w, " "); out = ""; for (i = 1; i <= n; i++) out = out (i > 1 ? " " : "") ((i in v) ? v[i] : w[i]);
                       print out } }' | sed 's/^isp_setup: //')
  done
  shards 'cycle:'
  shards 'tria: [0-9]* tests'
  while IFS= read -r l; do note "$l"; done < <(
    grep -h "program trace: [0-9]* checks" "$GATE_DIR"/shards/log_*.txt 2>/dev/null |
    awk '{ n += $4 } END { printf "program trace: %d checks over all shards (every issued micro-word and register write against the schedule)\n", n }')
fi
gate_end

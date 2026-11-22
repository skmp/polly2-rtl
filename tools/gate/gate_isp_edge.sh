#!/bin/bash
# gate_isp_edge.sh: the M2 gate (PLAN M2), run by make isp-edge / isp-edge-full / isp-edge-mutants.
#
#   tools/gate/gate_isp_edge.sh [--full | --mutants]
#
#   quick (isp-edge)          hw-pkg-check (p2_hw_pkg at refsw3's EdgeHW / DepthHW), check_ref_copies on the edge
#                             copies (tb/isp_edge/ref_copies_edge.h), check_ref_switches; the console pages' primitives
#                             (make isp-edge-vec: refsw3-offline built from nulldc3, tools/gate/tria_extract.sh on every
#                             fit/hw faredge*, hugepos*, edge2_* test; and make isp-depth-vec, M3's pages: the testbench
#                             reads every build/vec/*.tri, so both sets are made here and the inputs do not depend on
#                             what another gate left in build/vec); the build; lint-isp-edge; then the testbench in
#                             quick mode, sharded ISP_EDGE_SHARDS ways (tools/gate/run_shards.sh): the five gate items
#                             (directed facts, the covmeas sets, the pages' primitives, random and raster-only vectors with
#                             the far class, the width claims asserted on every job) and the stream section
#   --full (isp-edge-full)    the same with --full: every covmeas set, every primitive of the pages, 400M random edges,
#                             20M descriptors; under /tmp/polly2-rtl-gate.lock
#   --mutants                 tools/gate/mutants.py on tb/isp_edge/mutants.txt (rtl/v1/isp) and mutants_lib.txt (the
#                             M1 library's rules the edge path depends on); under the lock
#
# Ends with "<gate>: PASS" or "<gate>: FAIL" (exit code to match); build/gate/<gate>/summary.txt with the revision
# header, the enumerated inputs, each step's checks / failures line and the time line (lib.sh). Environment: ISP_EDGE_J (the
# queue's slots and make -j: P2_J: tools/gate/jobs.sh), ISP_EDGE_SHARDS (the quick run's slices, 12), ISP_EDGE_FULL_SHARDS (the
# full run's, 96: a fixed number, so that a run's report does not depend on J), ISP_EDGE_MUT_NJOBS (each mutant
# build's make -j, 2). The slices and a calibration item run on one queue with lint (PLAN 0 rule 8); a slice's checks
# include the ones its process makes once (loading the vector files), so the summed checks grow by that much for every
# slice more; the checks of the vectors (sum less N times the calibration's) and the sections' cases do not depend on N.
# The 'shard 0' lines are slice 0's (of N).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
case "$mode" in
  quick)     gate=isp-edge ;;
  --full)    gate=isp-edge-full ;;
  --mutants) gate=isp-edge-mutants ;;
  *)         echo "usage: gate_isp_edge.sh [--full | --mutants]"; exit 2 ;;
esac
if [ "$mode" != quick ] && [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock bash "$0" "$@"
fi

. "$HERE/lib.sh"
J=${ISP_EDGE_J:-$P2_J}
SHARDS=${ISP_EDGE_SHARDS:-12}
[ "$mode" = --full ] && SHARDS=${ISP_EDGE_FULL_SHARDS:-96}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}

tb_lines() {   # tb_lines <step name>: its checks / failures line and its sections into the summary
  local name=$1
  local line
  while IFS= read -r line; do GATE_LINES+=("    $line"); echo "    $line"; done < <(
    grep -E '^  section |: section |widths:|: [0-9]+ ((shards|items), [0-9]+ )?checks, [0-9]+ failures|: [0-9]+ checks of the vectors' "$GATE_DIR/$name.log" |
    grep -v '^isp_edge: section' | sed 's/^isp_edge: //')
}
tb_step() {   # tb_step <step name> <command ...>: the step, its checks / failures line and its sections in the summary
  local name=$1; shift
  gate_step "$name" "$@"
  tb_lines "$name"
}
mut_step() {   # mut_step <step name> <mutants file>
  gate_mutants "$1" "$2" --njobs "${ISP_EDGE_MUT_NJOBS:-2}"
}

gate_begin "$gate"
gate_step hw-pkg-check       $MAKE -s hw-pkg-check
gate_step check_ref_copies   bash tools/check_ref_copies.sh tb/isp_edge/ref_copies_edge.h
gate_step check_ref_switches bash tools/check_ref_switches.sh --no-hwpkg
if [ "$mode" = --mutants ]; then
  mut_step mutants     tb/isp_edge/mutants.txt
  mut_step mutants-lib tb/isp_edge/mutants_lib.txt
else
  gate_step vec $MAKE -s isp-edge-vec isp-depth-vec   # both sets: the tb reads every build/vec/*.tri (self-contained on a clean build)
  n_tests=$(ls build/vec/*.tri 2>/dev/null | wc -l)
  n_sets=$(ls "$DCTESTS"/fit/covmeas_data/*.npz 2>/dev/null | wc -l)
  GATE_LINES+=("    inputs: $n_sets covmeas sets ($DCTESTS/fit/covmeas_data), $n_tests console tests' primitives (build/vec)")
  echo "    inputs: $n_sets covmeas sets, $n_tests console tests' primitives"
  gate_step build $MAKE -s -j"$J" NJOBS="$J" isp-edge-build
  items=$GATE_DIR/items.txt
  : > "$items"
  gate_item "$items" lint-isp-edge - 2 1 step lint-isp-edge.log $MAKE -s lint-isp-edge
  name=isp-edge flag=""
  [ "$mode" = --full ] && name=isp-edge-full flag=--full
  shard_items "$items" "$name" "$SHARDS" shards 1 10 build/obj_isp_edge/tb $flag
  gate_queue queue "$items"
  shard_report "$name" shards "$SHARDS" > "$GATE_DIR/$name.log"
  tb_lines "$name"
  # the directed console pages (shard 0 runs the directed section): records, tiles off the console, mechanisms
  while IFS= read -r l; do GATE_LINES+=("    ${l#isp_edge: }"); echo "    ${l#isp_edge: }"; done < <(
    grep -h 'directed console ' "$GATE_DIR"/shards/log_0.txt 2>/dev/null | grep -v ': section ' | cut -c1-200)
  # the width claims' maxima of shard 0 (every shard asserts them; a violation is a failure above)
  while IFS= read -r l; do GATE_LINES+=("    shard 0 ${l#isp_edge: }"); echo "    shard 0 ${l#isp_edge: }"; done < <(
    grep -h 'widths:' "$GATE_DIR"/shards/log_0.txt 2>/dev/null)
fi
gate_end

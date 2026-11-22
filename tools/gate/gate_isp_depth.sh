#!/bin/bash
# gate_isp_depth.sh: the M3 gate (PLAN M3), run by make isp-depth / isp-depth-full / isp-depth-mutants.
#
#   tools/gate/gate_isp_depth.sh [--full | --mutants]
#
#   quick (isp-depth)          hw-pkg-check (p2_hw_pkg at refsw3's DepthHW: zeroRuleCoords, zeroRuleEdges included),
#                              check_ref_copies on the depth copy (tb/isp_depth/ref_copies_depth.h), check_ref_switches;
#                              the console pages' primitives (make isp-depth-vec: tools/gate/tria_extract.sh on every
#                              pvr-tests depthgaps_*, zovf*, nantr_*, perpmean_*, zword, zbad*, zspec, zsign, bg*,
#                              depth2_*, trsort_*: their .trz depth records; and make isp-edge-vec, M2's pages: the
#                              testbench reads every build/vec/*.trz, so both sets are made here and the inputs do not
#                              depend on what another gate left in build/vec); the build; lint-isp-depth; then the
#                              testbench in quick mode, sharded ISP_DEPTH_SHARDS ways (tools/gate/run_shards.sh): the five
#                              gate items (directed facts, the 13 zmeas sets and the covmeas zprobe sets, the pages'
#                              primitives one in eight, 1M random planes, the width claims asserted on every pixel) and
#                              the rdesc and stream sections
#   --full (isp-depth-full)    the same with --full: every primitive of the pages, 100M random planes, 4M descriptors;
#                              under /tmp/polly2-rtl-gate.lock
#   --mutants                  tools/gate/mutants.py on tb/isp_depth/mutants.txt (rtl/v1/isp), mutants_lib.txt (the M1
#                              library's rules the depth path depends on) and mutants_zword.txt (p2_zword_pkg); under the
#                              lock
#
# Ends with "<gate>: PASS" or "<gate>: FAIL" (exit code to match); build/gate/<gate>/summary.txt with the revision
# header, the enumerated inputs, each step's checks / failures line and the time line (lib.sh). Environment: ISP_DEPTH_J (the
# queue's slots and make -j: P2_J: tools/gate/jobs.sh), ISP_DEPTH_SHARDS (the quick run's slices, 12), ISP_DEPTH_FULL_SHARDS (the
# full run's, 12: in full mode this testbench's checks depend on the slicing beyond the per-process loads, 1486824890 of
# the vectors at 96 slices against 1486824722 at 12 (2026-11-22, agents/gates), with every section's cases equal and 96
# slices no faster on the 16-core box (3007 s against 2966 s), so the full run keeps the recorded 12), ISP_DEPTH_MUT_NJOBS (each mutant
# build's make -j, 2). The slices and a calibration item run on one queue with lint (PLAN 0 rule 8); a slice's checks
# include the ones its process makes once (loading the vector files), so the summed checks grow by that much for every
# slice more; the checks of the vectors (sum less N times the calibration's) and the sections' cases do not depend on N.
# The 'shard 0' lines are slice 0's (of N).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
case "$mode" in
  quick)     gate=isp-depth ;;
  --full)    gate=isp-depth-full ;;
  --mutants) gate=isp-depth-mutants ;;
  *)         echo "usage: gate_isp_depth.sh [--full | --mutants]"; exit 2 ;;
esac
if [ "$mode" != quick ] && [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock bash "$0" "$@"
fi

. "$HERE/lib.sh"
J=${ISP_DEPTH_J:-$P2_J}
SHARDS=${ISP_DEPTH_SHARDS:-12}
[ "$mode" = --full ] && SHARDS=${ISP_DEPTH_FULL_SHARDS:-12}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}

tb_lines() {   # tb_lines <step name>: its checks / failures line and its sections into the summary
  local name=$1
  local line
  while IFS= read -r line; do GATE_LINES+=("    $line"); echo "    $line"; done < <(
    grep -E '^  section |: [0-9]+ ((shards|items), [0-9]+ )?checks, [0-9]+ failures|: [0-9]+ checks of the vectors' "$GATE_DIR/$name.log" |
    grep -v '^isp_depth: section' | sed 's/^isp_depth: //')
}
tb_step() {   # tb_step <step name> <command ...>: the step, its checks / failures line and its sections in the summary
  local name=$1; shift
  gate_step "$name" "$@"
  tb_lines "$name"
}
mut_step() {   # mut_step <step name> <mutants file>
  gate_mutants "$1" "$2" --njobs "${ISP_DEPTH_MUT_NJOBS:-2}"
}
shard0() {    # shard0 <pattern>: shard 0's lines matching the pattern into the summary (every shard asserts them)
  while IFS= read -r l; do GATE_LINES+=("    shard 0 ${l#isp_depth: }"); echo "    shard 0 ${l#isp_depth: }"; done < <(
    grep -hE "$1" "$GATE_DIR"/shards/log_0.txt 2>/dev/null | cut -c1-400)
}

gate_begin "$gate"
gate_step hw-pkg-check       $MAKE -s hw-pkg-check
gate_step check_ref_copies   bash tools/check_ref_copies.sh tb/isp_depth/ref_copies_depth.h
gate_step check_ref_switches bash tools/check_ref_switches.sh --no-hwpkg
if [ "$mode" = --mutants ]; then
  mut_step mutants       tb/isp_depth/mutants.txt
  mut_step mutants-lib   tb/isp_depth/mutants_lib.txt
  mut_step mutants-zword tb/isp_depth/mutants_zword.txt
else
  gate_step vec $MAKE -s isp-edge-vec isp-depth-vec   # both sets: the tb reads every build/vec/*.trz (self-contained on a clean build)
  n_tests=$(ls build/vec/*.trz 2>/dev/null | wc -l)
  n_zme=$(ls "$DCTESTS"/fit/zmeas_data/*.zme 2>/dev/null | wc -l)
  n_zp=$(ls "$DCTESTS"/fit/covmeas_data/*zprobe*.npz 2>/dev/null | wc -l)
  GATE_LINES+=("    inputs: $n_zme zmeas sets, $n_zp covmeas zprobe sets ($DCTESTS/fit), $n_tests console tests' depth records (build/vec)")
  echo "    inputs: $n_zme zmeas sets, $n_zp covmeas zprobe sets, $n_tests console tests' depth records"
  gate_step build $MAKE -s -j"$J" NJOBS="$J" isp-depth-build
  items=$GATE_DIR/items.txt
  : > "$items"
  gate_item "$items" lint-isp-depth - 2 1 step lint-isp-depth.log $MAKE -s lint-isp-depth
  name=isp-depth flag=""
  [ "$mode" = --full ] && name=isp-depth-full flag=--full
  shard_items "$items" "$name" "$SHARDS" shards 1 10 build/obj_isp_depth/tb $flag
  gate_queue queue "$items"
  shard_report "$name" shards "$SHARDS" > "$GATE_DIR/$name.log"
  tb_lines "$name"
  # the zmeas brackets and the covmeas pages of every shard; the width claims' maxima and the regimes of shard 0
  for k in brackets probe-hidden; do
    while IFS= read -r l; do GATE_LINES+=("    $l"); echo "    $l"; done < <(
      grep -h "section .*$k" "$GATE_DIR"/shards/log_*.txt 2>/dev/null | awk -v k="$k" '
        k == "brackets" { n += $4; i += $(NF - 8) } k == "probe-hidden" { s += $4; d += $(NF - 1) }
        END { if (k == "brackets") printf "zmeas: %d brackets, %d inside the console'"'"'s\n", n, i;
              else printf "covmeas zprobe: %d sets, %d pixels differ from the console\n", s, d }')
  done
  shard0 'widths:'
  shard0 'regimes CONST'
fi
gate_end

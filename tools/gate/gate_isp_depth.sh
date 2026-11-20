#!/bin/bash
# gate_isp_depth.sh: the M3 gate (PLAN M3), run by make isp-depth / isp-depth-full / isp-depth-mutants.
#
#   tools/gate/gate_isp_depth.sh [--full | --mutants]
#
#   quick (isp-depth)          hw-pkg-check (p2_hw_pkg at refsw3's DepthHW: zeroRuleCoords, zeroRuleEdges included),
#                              check_ref_copies on the depth copy (tb/isp_depth/ref_copies_depth.h), check_ref_switches;
#                              the console pages' primitives (make isp-depth-vec: tools/gate/tria_extract.sh on every
#                              pvr-tests depthgaps_*, zovf*, nantr_*, perpmean_*, zword, zbad*, zspec, zsign, bg*,
#                              depth2_*, trsort_*: their .trz depth records); the build; lint-isp-depth; then the
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
# header, the enumerated inputs and each step's checks / failures line. Environment: ISP_DEPTH_J (make -j, 12),
# ISP_DEPTH_SHARDS (12), ISP_DEPTH_MUT_JOBS (parallel mutant builds, 6).
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
J=${ISP_DEPTH_J:-12}
SHARDS=${ISP_DEPTH_SHARDS:-12}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}

tb_step() {   # tb_step <step name> <command ...>: the step, its checks / failures line and its sections in the summary
  local name=$1; shift
  gate_step "$name" "$@"
  local line
  while IFS= read -r line; do GATE_LINES+=("    $line"); echo "    $line"; done < <(
    grep -E '^  section |: [0-9]+ (shards, [0-9]+ )?checks, [0-9]+ failures' "$GATE_DIR/$name.log" |
    grep -v '^isp_depth: section' | sed 's/^isp_depth: //')
}
mut_step() {   # mut_step <step name> <mutants file>
  tb_step "$1" python3 tools/gate/mutants.py "$2" --jobs "${ISP_DEPTH_MUT_JOBS:-6}" --njobs 2
  grep -E 'caught|SURVIVED|ERROR|control' "$GATE_DIR/$1.log" | sed 's/^/    /'
  while IFS= read -r l; do GATE_LINES+=("    $l"); done < <(grep -E ' (caught|SURVIVED|ERROR)' "$GATE_DIR/$1.log")
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
  gate_step isp-depth-vec $MAKE -s isp-depth-vec
  n_tests=$(ls build/vec/*.trz 2>/dev/null | wc -l)
  n_zme=$(ls "$DCTESTS"/fit/zmeas_data/*.zme 2>/dev/null | wc -l)
  n_zp=$(ls "$DCTESTS"/fit/covmeas_data/*zprobe*.npz 2>/dev/null | wc -l)
  GATE_LINES+=("    inputs: $n_zme zmeas sets, $n_zp covmeas zprobe sets ($DCTESTS/fit), $n_tests console tests' depth records (build/vec)")
  echo "    inputs: $n_zme zmeas sets, $n_zp covmeas zprobe sets, $n_tests console tests' depth records"
  gate_step build $MAKE -s -j"$J" NJOBS="$J" isp-depth-build
  gate_step lint-isp-depth $MAKE -s lint-isp-depth
  if [ "$mode" = --full ]; then
    tb_step isp-depth-full bash tools/gate/run_shards.sh isp-depth-full "$SHARDS" "$GATE_DIR/shards" \
      build/obj_isp_depth/tb --full
  else
    tb_step isp-depth-tb bash tools/gate/run_shards.sh isp-depth "$SHARDS" "$GATE_DIR/shards" build/obj_isp_depth/tb
  fi
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

#!/bin/bash
# gate_isp_tile_op.sh: the M6 gate (PLAN M6), run by make isp-tile-op / isp-tile-op-full / isp-tile-op-mutants.
#
#   tools/gate/gate_isp_tile_op.sh [--full | --mutants]
#
#   quick (isp-tile-op)   check_ref_copies, check_ref_switches (with hw-pkg-check); the builds (refsw3-offline, the L2 glue,
#                         scenegen, the ISP tile testbench); the captures of the M6 inputs (tools/gate/capture_prerender.sh:
#                         tb/tile/subset_isp_op.txt at most 8 renders a test, the tile subset's dumps subset_dumps.txt,
#                         scenegen seeds subset_seeds.txt); lint-isp-tile; then the testbench (build/obj_isp_tile/tb) in
#                         phase-halt mode on every capture, a work item per case on one queue with lint (PLAN 0 rule 8;
#                         longest first by the last run's seconds, build/gate/<gate>/cost.txt) (--op-only: M7's testbench runs every phase,
#                         M6's gate compares these): after Z, OP and OP_MOD of every entry, depthA,
#                         tagA, stencil and valid of all 1024 pixels against the M5 phase driver's (p2ref), once with the
#                         VRAM model plain and once with --vramvary 7 (the values must not change; the variation is seeded
#                         per case, so its clocks do not depend on J or the order); the mutants of
#                         tb/isp_tile/mutants.txt (rtl/v1/isp) and mutants_mem.txt (rtl/v1/mem), every one caught
#   --full                the same on M5's full set (every fit/hw test, its first 256 renders; every dump; seeds 1-5000),
#                         both VRAM modes; no mutants. Under /tmp/polly2-rtl-gate.lock
#   --mutants             the builds, the captures the probes use, the mutants alone
#
# Ends with "<gate>: PASS" or "<gate>: FAIL"; build/gate/<gate>/summary.txt with the revision header, the inputs and each
# step's line, the clocks per entry the RTL took (reported, not gated: PLAN 0 rule 6) and the time line (lib.sh).
# Environment: ISP_TILE_J (the queue's slots, the captures' and the builds' -j: P2_J: tools/gate/jobs.sh), ISP_TILE_MUT_NJOBS
# (each mutant build's make -j, 4).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
case "$mode" in
  quick)     gate=isp-tile-op ;;
  --full)    gate=isp-tile-op-full ;;
  --mutants) gate=isp-tile-op-mutants ;;
  *)         echo "usage: gate_isp_tile_op.sh [--full | --mutants]"; exit 2 ;;
esac
if [ "$mode" = --full ] && [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock bash "$0" "$@"
fi

. "$HERE/lib.sh"
J=${ISP_TILE_J:-$P2_J}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}
export POLLY2_DUMPS=${POLLY2_DUMPS:-$P2_ROOT/../dreamster/polly2-rtl/polly2-data/dumps}

note() { GATE_LINES+=("    $1"); echo "    $1"; }
cases_of() {   # the subset file's cases, comments and blank lines dropped; seeds' ranges a-b expanded
  sed 's/#.*//' "$1" | awk 'NF { print $1 }' | while read -r c; do
    if [[ "$c" =~ ^([0-9]+)-([0-9]+)$ ]]; then seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; else echo "$c"; fi
  done
}

gate_begin "$gate"
gate_step check_ref_copies   bash tools/check_ref_copies.sh
gate_step check_ref_switches bash tools/check_ref_switches.sh
gate_step build              $MAKE -s -j"$J" NJOBS="$J" refsw3-offline refglue-build scenegen isp-tile-build

# ---- the inputs
if [ "$mode" = --full ]; then
  tests=$(ls "$DCTESTS/fit/hw" | grep -v '_races$' | grep -v '[+@]')
  dumps=$( (ls "$POLLY2_DUMPS"/*.pvrdmp | xargs -n 1 basename | sed 's/\.pvrdmp$//';
            ls "$POLLY2_DUMPS"/vram_*.bin | xargs -n 1 basename | sed 's/^vram_//; s/\.bin$//' | grep -v '^out_') | sort -u)
  seeds=$(seq 1 5000)
  maxr=256
else
  tests=$( (cases_of tb/tile/subset_isp_op.txt; sed 's/#.*//' tb/isp_tile/mutant_cases.txt | awk 'NF { print $1 }' |
            sed -n 's:^build/pre/\([^/]*\)$:\1:p' | grep -v '^dump_\|^gen_') | sort -u)
  dumps=$(cases_of tb/tile/subset_dumps.txt)
  seeds=$(cases_of tb/tile/subset_seeds.txt)
  maxr=8
fi
caps=$( (for t in $tests; do echo "$t"; done; for d in $dumps; do echo "dump:$d"; done; for s in $seeds; do echo "gen:$s"; done) )
gate_step captures bash tools/gate/capture_prerender.sh -j "$J" --max "$maxr" $caps
list=$GATE_DIR/cases.txt
(for t in $tests; do echo "build/pre/$t"; done; for d in $dumps; do echo "build/pre/dump_$d"; done
 for s in $seeds; do echo "build/pre/gen_$s"; done) > "$list"
nren=$(while read -r d; do ls -d "$d"/r* 2>/dev/null; done < "$list" | wc -l)
note "inputs: $(echo $tests | wc -w) test pages (at most $maxr renders each), $(echo $dumps | wc -w) dumps, $(echo $seeds | wc -w) scenegen seeds: $nren renders"

if [ "$mode" != --mutants ]; then
  items=$GATE_DIR/items.txt
  : > "$items"
  gate_item "$items" lint-isp-tile - 4 1 step lint-isp-tile.log $MAKE -s lint-isp-tile
  for v in 0 7; do
    name=phase-halt; [ $v != 0 ] && name=phase-halt-vramvary$v
    python3 tools/gate/tile_items.py --list "$list" --group "$name" --logs "shards-$name" --cost "$GATE_DIR/cost.txt" \
      --jobs "$J" -- build/obj_isp_tile/tb --op-only --vramvary $v >> "$items"
  done
  gate_queue queue "$items"
  for v in 0 7; do
    name=phase-halt; [ $v != 0 ] && name=phase-halt-vramvary$v
    r=$(cat "$GATE_DIR"/shards-$name/log_*.txt | grep -h '^isp_tile: build/pre/' |
        awk '{ r += $3; e += $5; p += $7 } END { printf "%d renders, %d entries, %d phases compared (1024 pixels each; Z, OP, OP_MOD)", r, e, p }')
    note "$name: $r; $(cat "$GATE_DIR"/shards-$name/log_*.txt | grep -c '  FAIL ') failures shown"
    c=$(cat "$GATE_DIR"/shards-$name/log_*.txt | grep -h '^isp_tile: [0-9]* cases' |
        awk '{ n += $10; c += $12; if ($20 + 0 > m) m = $20 + 0 } END { printf "%d entries, %d RTL clocks: mean %.0f, max %d clocks an entry (from the entry accept to its last phase; halts excluded; VRAM model VR_LAT 8)", n, c, n ? c / n : 0, m }')
    note "$name: $c"
  done
fi
if [ "$mode" != --full ]; then
  gate_mutants mutants tb/isp_tile/mutants.txt --njobs "${ISP_TILE_MUT_NJOBS:-4}"
  gate_mutants mutants-mem tb/isp_tile/mutants_mem.txt --njobs "${ISP_TILE_MUT_NJOBS:-4}"
fi
gate_end

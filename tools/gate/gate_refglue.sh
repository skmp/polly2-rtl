#!/bin/bash
# gate_refglue.sh: the M5 gate (PLAN M5), run by make refglue-selftest / refglue-selftest-full / refglue-mutants.
#
#   tools/gate/gate_refglue.sh [--full | --mutants]
#
#   quick (refglue-selftest)   check_ref_copies (every tb/**/ref_copies*.h), check_ref_switches (with hw-pkg-check);
#                              the builds (refsw3-offline, the glue and the self-test, scenegen, tria_conv); the captures
#                              of the tile subset (tools/gate/capture_prerender.sh: tb/tile/subset_tests.txt at most 8
#                              renders a test, subset_dumps.txt, subset_seeds.txt's 200 seeds); tria_extract on a dump
#                              and a seed (build/vec/frames); then refglue_selftest on every capture in four modes, a work
#                              item per case and mode on one queue (PLAN 0 rule 8; longest first by the last run's seconds,
#                              build/gate/<gate>/cost.txt), each the whole video memory after every render against
#                              refsw3-offline's:
#                                drv       the phase driver (the gate's subject); PtChunkTake's copy checked by an item of
#                                          its own
#                                core      RenderCORE_sw (the glue's build against refsw3-offline's)
#                                ptcopy    the phase driver with the PT loop's verbatim copy
#                                scramble  the phase driver with every dead field (tb/common/isp_live.h) randomized at
#                                          every phase boundary
#                              refsw3_known.sh on the tests tb/ref/readme_scores.txt names, which must reproduce the
#                              dreamcast-tests README's scores; the mutants of tb/ref/mutants.txt (the phase driver's
#                              order) and tb/ref/mutants_live.txt (unsound liveness masks), every one caught (builds and
#                              probe runs, an item per case, on one queue: tools/gate/mutants.py)
#   --full                     the same on every fit/hw test (its first 256 renders: a readback search runs thousands,
#                              16 MB of captures each), every polly2-data dump and seeds 1-5000;
#                              refsw3_known.sh on every fit/hw test, each exact (the README's "every regress test is
#                              exact" at 4f3efe15); under /tmp/polly2-rtl-gate.lock. Hours
#   --mutants                  the captures (as quick) and the mutants alone
#
# Ends with "<gate>: PASS" or "<gate>: FAIL" (exit code to match); build/gate/<gate>/summary.txt with the revision header,
# the inputs, each step's line and the time line (lib.sh). Environment: REFGLUE_J (the queue's slots, the captures' and
# builds' -j: P2_J: tools/gate/jobs.sh), REFGLUE_MUT_NJOBS (each mutant build's make -j, 4).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
case "$mode" in
  quick)     gate=refglue-selftest ;;
  --full)    gate=refglue-selftest-full ;;
  --mutants) gate=refglue-mutants ;;
  *)         echo "usage: gate_refglue.sh [--full | --mutants]"; exit 2 ;;
esac
if [ "$mode" = --full ] && [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock bash "$0" "$@"
fi

. "$HERE/lib.sh"
J=${REFGLUE_J:-$P2_J}
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
gate_step build              $MAKE -s -j"$J" NJOBS="$J" refsw3-offline refglue-build scenegen build/tools/tria_conv

# ---- the inputs
if [ "$mode" = --full ]; then
  tests=$(ls "$DCTESTS/fit/hw" | grep -v '_races$' | grep -v '[+@]')
  dumps=$( (ls "$POLLY2_DUMPS"/*.pvrdmp | xargs -n 1 basename | sed 's/\.pvrdmp$//';
            ls "$POLLY2_DUMPS"/vram_*.bin | xargs -n 1 basename | sed 's/^vram_//; s/\.bin$//' | grep -v '^out_') | sort -u)
  seeds=$(seq 1 5000)
  maxr=256
else
  tests=$(cases_of tb/tile/subset_tests.txt)
  dumps=$(cases_of tb/tile/subset_dumps.txt)
  seeds=$(cases_of tb/tile/subset_seeds.txt)
  maxr=8
fi
caps=$( (for t in $tests; do echo "$t"; done; for d in $dumps; do echo "dump:$d"; done; for s in $seeds; do echo "gen:$s"; done) )
echo "$caps" > "$GATE_DIR/captures.txt"
gate_step captures bash tools/gate/capture_prerender.sh -j "$J" --max "$maxr" $caps
list=build/pre/subset_cases.txt
[ "$mode" = --full ] && list=build/pre/full_cases.txt
(for t in $tests; do echo "build/pre/$t"; done; for d in $dumps; do echo "build/pre/dump_$d"; done
 for s in $seeds; do echo "build/pre/gen_$s"; done) > "$list"
nren=$(cat "$list" | while read -r d; do ls -d "$d"/r* 2>/dev/null; done | wc -l)
note "inputs: $(echo $tests | wc -w) test pages (at most $maxr renders each), $(echo $dumps | wc -w) dumps, $(echo $seeds | wc -w) scenegen seeds: $nren renders ($list)"

if [ "$mode" != --mutants ]; then
  gate_step tria_extract bash tools/gate/tria_extract.sh -j 2 dump:logo gen:1
  [ -f build/vec/frames/dump_logo.txt ] && note "tria_extract dump:logo: $(cat build/vec/frames/dump_logo.txt)"
  # the self-test, four modes, on one queue
  items=$GATE_DIR/items.txt
  : > "$items"
  for m in drv core ptcopy scramble; do
    python3 tools/gate/tile_items.py --list "$list" --group "selftest-$m" --logs "shards-$m" --cost "$GATE_DIR/cost.txt" \
      --jobs "$J" -- build/ref/refglue_selftest --mode $m >> "$items"
  done
  gate_item "$items" selftest-drv take 5 1 tb shards-drv/take.txt build/ref/refglue_selftest --mode drv --check-take 1000000
  gate_queue selftest "$items"
  for m in drv core ptcopy scramble; do
    r=$(cat "$GATE_DIR"/shards-$m/log_*.txt | grep -h "^refglue_selftest: $m: [0-9]* cases" | awk '{ c += $3; r += $5; s += $7; h += $12 } END { printf "%d cases, %d renders, %d not rendered by refsw3-offline, %d did not end", c, r, s, h }')
    d=$(cat "$GATE_DIR"/shards-$m/log_*.txt | grep -c "  FAIL ")
    note "$m: $r; $d failures"
    [ $m = scramble ] && note "scramble: $(cat "$GATE_DIR"/shards-$m/log_*.txt | grep -ho '[0-9]* dead fields scrambled' | awk '{ s += $1 } END { print s }') dead fields scrambled"
    [ $m = drv ] && note "drv: $(grep -h 'pt-take:' "$GATE_DIR"/shards-$m/take.txt | sed 's/^refglue_selftest: //')"
    [ $m = drv ] && note "drv: $(cat "$GATE_DIR"/shards-$m/log_*.txt | grep -h "^refglue_selftest: drv: at most" | awk '{ if ($5 > c) c = $5; if ($8 > p) p = $8; if ($13 > t) t = $13; e += substr($18, 2) } END { printf "at most %d chunks and %d passes a punch-through entry, %d passes a translucent sort (%d entries)", c, p, t, e }')"
  done
  # refsw3-known: the README's scores
  if [ "$mode" = --full ]; then
    gate_step refsw3_known bash tools/gate/refsw3_known.sh -j "$J" --expect tb/ref/readme_scores.txt --all-exact
  else
    gate_step refsw3_known bash tools/gate/refsw3_known.sh -j "$J" --expect tb/ref/readme_scores.txt \
      $(sed 's/#.*//' tb/ref/readme_scores.txt | awk 'NF { print $1 }')
  fi
  while IFS= read -r l; do note "$l"; done < <(grep -E '^refsw3_known: .* (=|has) ' "$GATE_DIR/refsw3_known.log")
fi
if [ "$mode" != --full ]; then
  gate_mutants mutants tb/ref/mutants.txt --njobs "${REFGLUE_MUT_NJOBS:-4}"
  gate_mutants mutants-live tb/ref/mutants_live.txt --njobs "${REFGLUE_MUT_NJOBS:-4}"
fi
gate_end

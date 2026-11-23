#!/bin/bash
# gate_isp_tile.sh: the M7 gate (PLAN M7, 1.3), run by make isp-tile / isp-tile-full / isp-tile-mutants.
#
#   tools/gate/gate_isp_tile.sh [--full | --mutants]
#
#   quick (isp-tile)      check_ref_copies, check_ref_switches (with hw-pkg-check); the builds (refsw3-offline, the L2 glue,
#                         scenegen, the ISP tile testbench); the captures of the inputs (tools/gate/capture_prerender.sh: M6's
#                         pages tb/tile/subset_isp_op.txt and M7's tb/tile/subset_isp_tile.txt at most 8 renders a test, the
#                         tile subset's dumps subset_dumps.txt and M7's subset_isp_tile_dumps.txt, scenegen seeds
#                         subset_seeds.txt); then on one queue (PLAN 0 rule 8) lint-isp-tile and the testbench
#                         (build/obj_isp_tile/tb) on every capture in both modes, a work item per case (phase-halt) and
#                         per case or run of segments (free-running: tools/gate/tile_items.py cuts the costly cases),
#                         longest first by the last run's seconds (build/gate/<gate>/cost.txt):
#                           phase-halt   the live ISP state of all 1024 pixels at every phase boundary of every entry,
#                                        every SHADE pass's runs (tag, line, column, length, vmask, pmask, rm, epoch, eop,
#                                        eoe) against refsw3's, the punch-through feedback from the reference's outcomes,
#                                        the entry records (p2_entq, shaded_any) and the PT chunk / pass and sort pass
#                                        counts, under random back-pressure of the run stream
#                           free-running the entries back to back with no halt, the run stream popped with random
#                                        back-pressure, the punch-through passes answered after a random delay, the VRAM
#                                        model varied (--vramvary 7): the run stream, the entry records, the counts and the
#                                        live state at each render's end; a case runs in segments of 8 renders (the RTL's
#                                        state carried within one; at a segment's start the RTL reset and synced from the
#                                        reference, generators seeded from the case and the segment), so the numbers
#                                        (clocks too) do not depend on how a case is cut into items (whole segments) or on J;
#                                        each item's run stream into build/sort/rs (--dump-runs: M8's sorter gate's input)
#   --full                the same on the full set (every fit/hw test, its first 256 renders; every dump; seeds 1-5000),
#                         both modes. Under /tmp/polly2-rtl-gate.lock
#   --mutants             the builds, the captures the probes use, the mutants of tb/isp_tile/mutants_m7.txt (every one
#                         caught, the per-tile barrier one passing: PLAN M7): builds and probe runs (an item per case) on
#                         one queue (tools/gate/mutants.py)
#
# Ends with "<gate>: PASS" or "<gate>: FAIL"; build/gate/<gate>/summary.txt with the revision header, the inputs and each
# step's line, the clocks per entry the RTL took (reported, not gated: PLAN 0 rule 6) and the time line (lib.sh).
# Environment: ISP_TILE_J (the queue's slots, the captures' and the builds' -j: P2_J: tools/gate/jobs.sh), ISP_TILE_MUT_NJOBS
# (each mutant build's make -j, 4).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
case "$mode" in
  quick)     gate=isp-tile ;;
  --full)    gate=isp-tile-full ;;
  --mutants) gate=isp-tile-mutants ;;
  *)         echo "usage: gate_isp_tile.sh [--full | --mutants]"; exit 2 ;;
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
elif [ "$mode" = --mutants ]; then
  tests=$(sed 's/#.*//' tb/isp_tile/mutant_cases_m7.txt | awk 'NF { print $1 }' | sed -n 's:^build/pre/\([^/]*\)$:\1:p' |
          grep -v '^dump_\|^gen_' | sort -u)
  dumps=$(sed 's/#.*//' tb/isp_tile/mutant_cases_m7.txt | awk 'NF { print $1 }' | sed -n 's:^build/pre/dump_\(.*\)$:\1:p')
  seeds=$(sed 's/#.*//' tb/isp_tile/mutant_cases_m7.txt | awk 'NF { print $1 }' | sed -n 's:^build/pre/gen_\(.*\)$:\1:p')
  maxr=8
else
  tests=$( (cases_of tb/tile/subset_isp_op.txt; cases_of tb/tile/subset_isp_tile.txt) | sort -u)
  dumps=$( (cases_of tb/tile/subset_dumps.txt; cases_of tb/tile/subset_isp_tile_dumps.txt) | sort -u)
  seeds=$(cases_of tb/tile/subset_seeds.txt)
  maxr=8
fi
caps=$( (for t in $tests; do echo "$t"; done; for d in $dumps; do echo "dump:$d"; done; for s in $seeds; do echo "gen:$s"; done) )
# the captures; a fit/hw folder whose test never renders (the TA-only ta-tests: ta-probe, ta-tests) captures nothing
# and is no input: it does not fail the step (any other capture failure does)
captures() {
  bash tools/gate/capture_prerender.sh -j "$J" --max "$maxr" $caps > "$GATE_DIR/captures.out" 2>&1
  local st=$?
  cat "$GATE_DIR/captures.out"
  [ $st = 0 ] && return 0
  # a case's last line decides (a case that failed is tried once more, alone)
  ! grep '^capture_prerender: [^ ]*: ' "$GATE_DIR/captures.out" | grep -v ': once more, alone$' |
    awk '{ n = $2; $1 = $2 = ""; last[n] = $0 } END { for (n in last) print n, last[n] }' |
    grep -v ' [0-9]* renders captured\| up to date\| no render$' | grep -q .
}
gate_step captures captures
retried=$(sed -n 's/^capture_prerender: \(.*\): once more, alone$/\1/p' "$GATE_DIR/captures.out" | sort -u)
[ -n "$retried" ] && note "captures tried once more, alone: $(echo $retried)"
norender=$(sed -n 's/^capture_prerender: \(.*\): no render$/\1/p' "$GATE_DIR/captures.out" | sort -u)
[ -n "$norender" ] && note "no render (no input): $(echo $norender)"
list=$GATE_DIR/cases.txt
(for t in $tests; do echo "build/pre/$t"; done; for d in $dumps; do echo "build/pre/dump_$d"; done
 for s in $seeds; do echo "build/pre/gen_$s"; done) | while read -r d; do [ -d "$d/r0" ] && echo "$d"; done > "$list"
nren=$(while read -r d; do ls -d "$d"/r* 2>/dev/null; done < "$list" | wc -l)
note "inputs: $(echo $tests | wc -w) test pages (at most $maxr renders each), $(echo $dumps | wc -w) dumps, $(echo $seeds | wc -w) scenegen seeds: $nren renders"

# the per-case lines of a run, summed (gawk)
summ() {
  cat "$1"/log_*.txt | grep -h '^isp_tile: build/pre/' | gawk '
    function g(re,   m) { return match($0, re, m) ? m[1] : 0 }
    { r += g(": ([0-9]+) renders"); e += g(" ([0-9]+) entries"); p += g(" ([0-9]+) phases compared")
      s += g(" ([0-9]+) passes"); u += g(" ([0-9]+) runs"); nl += g(" ([0-9]+) null items")
      d += g(" ([0-9]+) descriptors"); rp += g("\\(([0-9]+) replayed\\)"); rw += g(" ([0-9]+) rows")
      b += g("\\(([0-9]+) barrier stalls\\)"); o += g("overflowed ([0-9]+) clk"); fw += g("full-walk ([0-9]+) clk")
      h += g("held ([0-9]+) clk"); fb += g("; ([0-9]+) feedback") }
    END { printf "%d renders, %d entries, %d phase boundaries compared (1024 pixels each), %d SHADE passes, %d runs, %d null eoe items; %d descriptors (%d replayed by pcache), %d raster rows (%d held by the row barrier); pcache overflowed %d clk, ptc full-walk %d clk, ptc holding the next chunk %d clk; %d feedback messages", r, e, p, s, u, nl, d, rp, rw, b, o, fw, h, fb }'
}
clocks() {
  cat "$1"/log_*.txt | grep -h '^isp_tile: [0-9]* cases' |
    awk '{ n += $10; c += $12; if ($20 + 0 > m) m = $20 + 0 } END { printf "%d entries, %d RTL clocks: mean %.0f clocks an entry (a tile), max %d", n, c, n ? c / n : 0, m }'
}

if [ "$mode" != --mutants ]; then
  items=$GATE_DIR/items.txt
  : > "$items"
  gate_item "$items" lint-isp-tile - 4 1 step lint-isp-tile.log $MAKE -s lint-isp-tile
  python3 tools/gate/tile_items.py --list "$list" --group phase-halt --logs shards-halt --cost "$GATE_DIR/cost.txt" \
    --jobs "$J" -- build/obj_isp_tile/tb --phase-limit 5000000 >> "$items"
  # the free-running items write their run streams for M8's sorter gate (tools/gate/gate_sort.sh): build/sort/rs (quick),
  # build/sort/rs-full (full: cleared first; "complete" written when the gate passes)
  rsdir=build/sort/rs
  if [ "$mode" = --full ]; then rsdir=build/sort/rs-full; rm -rf "$rsdir"; fi
  mkdir -p "$rsdir"
  python3 tools/gate/tile_items.py --list "$list" --group free-running --logs shards-free --split render \
    --cost "$GATE_DIR/cost.txt" --jobs "$J" -- build/obj_isp_tile/tb --mode free --vramvary 7 --phase-limit 500000000 \
    --dump-runs "$rsdir" >> "$items"
  gate_queue queue "$items"
  note "phase-halt: $(summ "$GATE_DIR/shards-halt")"
  note "phase-halt: $(clocks "$GATE_DIR/shards-halt") (from the entry's accept to its end, halts excluded; VR_LAT 8)"
  note "free-running: $(summ "$GATE_DIR/shards-free")"
  note "free-running: $(clocks "$GATE_DIR/shards-free") (mean: a render's clocks per entry, the entries back to back; max: one entry's accept to its end; run stream back-pressure, --vramvary 7)"
fi
if [ "$mode" = --mutants ]; then
  gate_mutants mutants tb/isp_tile/mutants_m7.txt --njobs "${ISP_TILE_MUT_NJOBS:-4}"
fi
[ "$mode" = --full ] && [ "$GATE_FAILED" = 0 ] && echo "isp-tile-full $(date +%F)" > build/sort/rs-full/complete
gate_end

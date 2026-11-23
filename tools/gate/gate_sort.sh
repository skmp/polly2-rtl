#!/bin/bash
# gate_sort.sh: the M8 gate (PLAN M8), run by make sort / sort-full / sort-mutants.
#
#   tools/gate/gate_sort.sh [--full | --mutants]
#
#   quick (sort)   check_ref_copies, check_ref_switches (with hw-pkg-check); the builds (refsw3-offline, the L2 glue,
#                  scenegen, the ISP tile testbench, the sorter testbench); the captures of M7's quick inputs
#                  (tools/gate/capture_prerender.sh --max 8: the pages of tb/tile/subset_isp_op.txt and
#                  subset_isp_tile.txt, the dumps of subset_dumps.txt and subset_isp_tile_dumps.txt, scenegen seeds
#                  subset_seeds.txt) and their run streams (build/sort/rs/<case>.r0-<n-1>.rs.gz: every item p2_isp_cut
#                  emitted, as the ISP tile testbench in free-running mode checked it against refsw3, --dump-runs; make
#                  isp-tile writes them too; a stream older than the ISP tile testbench or its capture is made again,
#                  on one queue); then on one queue (PLAN 0 rule 8) lint-sort and the sorter testbench
#                  (build/obj_sort/tb), each under SPAN_SORT_CFG 0x101, 0x001 and 0x000:
#                    subset  every recorded stream (a work item a case), its renders back to back, no barrier between
#                            passes (but where the ISP was reset)
#                    random  100,000 random streams in blocks of 1,000 (a work item a block)
#                  with random back-pressure on both sides (a class per render / stream: none, gaps, a slow cutter, a
#                  slow TSP); the sorted stream must equal refsw3's SpanSort of every pass, eop / eoe on exactly the
#                  last item of each pass and entry, p2_entq's records with the eoe items (tb/sort/sort_tb.cpp)
#   --full         the same with 1,000,000 random streams and the run streams of M7's full set (build/sort/rs-full,
#                  written by make isp-tile-full: its "complete" marker must be there). Under /tmp/polly2-rtl-gate.lock
#   --mutants      the builds, the captures and streams the probes use, and tb/sort/mutants.txt (tools/gate/mutants.py):
#                  every mutant caught
#
# Ends with "<gate>: PASS" or "<gate>: FAIL"; build/gate/<gate>/summary.txt with the revision header, the inputs, each
# step's line, the clocks (reported, not gated: PLAN 0 rule 6) and the time line (lib.sh).
# Environment: SORT_J (the queue's slots, the builds' -j: P2_J, tools/gate/jobs.sh), SORT_RANDOM (the random streams),
# SORT_MUT_NJOBS (each mutant build's make -j, 4).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
case "$mode" in
  quick)     gate=sort ;;
  --full)    gate=sort-full ;;
  --mutants) gate=sort-mutants ;;
  *)         echo "usage: gate_sort.sh [--full | --mutants]"; exit 2 ;;
esac
if [ "$mode" = --full ] && [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock bash "$0" "$@"
fi

. "$HERE/lib.sh"
J=${SORT_J:-$P2_J}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}
export POLLY2_DUMPS=${POLLY2_DUMPS:-$P2_ROOT/../dreamster/polly2-rtl/polly2-data/dumps}
CFGS="0x101 0x001 0x000"

note() { GATE_LINES+=("    $1"); echo "    $1"; }
cases_of() {   # the subset file's cases, comments and blank lines dropped; seeds' ranges a-b expanded
  sed 's/#.*//' "$1" | awk 'NF { print $1 }' | while read -r c; do
    if [[ "$c" =~ ^([0-9]+)-([0-9]+)$ ]]; then seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; else echo "$c"; fi
  done
}

gate_begin "$gate"
gate_step check_ref_copies   bash tools/check_ref_copies.sh
gate_step check_ref_switches bash tools/check_ref_switches.sh
gate_step build              $MAKE -s -j"$J" NJOBS="$J" refsw3-offline refglue-build scenegen isp-tile-build sort-build

rsdir=build/sort/rs
streams=$GATE_DIR/streams.txt
if [ "$mode" = --full ]; then
  nrandom=${SORT_RANDOM:-1000000}
  rsdir=build/sort/rs-full
  if [ -f "$rsdir/complete" ]; then
    ls "$rsdir"/*.rs.gz > "$streams"
    note "inputs: the run streams of make isp-tile-full ($(cat "$rsdir/complete")): $(wc -l < "$streams") files"
  else
    : > "$streams"
    GATE_LINES+=("streams: FAIL (no $rsdir/complete: run make isp-tile-full first)"); GATE_FAILED=1
    echo "streams: FAIL (no $rsdir/complete: run make isp-tile-full first)"
  fi
else
  nrandom=${SORT_RANDOM:-100000}
  if [ "$mode" = --mutants ]; then
    tests=$(sed 's/#.*//' tb/sort/mutant_cases.txt | awk 'NF { print $1 }' | sed -n 's:^build/sort/rs/\(.*\)\.r0-[0-9]*\.rs\.gz$:\1:p' |
            grep -v '^dump_\|^gen_' | sort -u)
    dumps=$(sed 's/#.*//' tb/sort/mutant_cases.txt | awk 'NF { print $1 }' | sed -n 's:^build/sort/rs/dump_\(.*\)\.r0-[0-9]*\.rs\.gz$:\1:p')
    seeds=$(sed 's/#.*//' tb/sort/mutant_cases.txt | awk 'NF { print $1 }' | sed -n 's:^build/sort/rs/gen_\(.*\)\.r0-[0-9]*\.rs\.gz$:\1:p')
  else
    tests=$( (cases_of tb/tile/subset_isp_op.txt; cases_of tb/tile/subset_isp_tile.txt) | sort -u)
    dumps=$( (cases_of tb/tile/subset_dumps.txt; cases_of tb/tile/subset_isp_tile_dumps.txt) | sort -u)
    seeds=$(cases_of tb/tile/subset_seeds.txt)
  fi
  caps=$( (for t in $tests; do echo "$t"; done; for d in $dumps; do echo "dump:$d"; done; for s in $seeds; do echo "gen:$s"; done) )
  captures() {
    bash tools/gate/capture_prerender.sh -j "$J" --max 8 $caps > "$GATE_DIR/captures.out" 2>&1
    local st=$?
    cat "$GATE_DIR/captures.out"
    [ $st = 0 ] && return 0
    ! grep '^capture_prerender: [^ ]*: ' "$GATE_DIR/captures.out" | grep -v ': once more, alone$' |
      awk '{ n = $2; $1 = $2 = ""; last[n] = $0 } END { for (n in last) print n, last[n] }' |
      grep -v ' [0-9]* renders captured\| up to date\| no render$' | grep -q .
  }
  gate_step captures captures
  list=$GATE_DIR/cases.txt
  (for t in $tests; do echo "build/pre/$t"; done; for d in $dumps; do echo "build/pre/dump_$d"; done
   for s in $seeds; do echo "build/pre/gen_$s"; done) | while read -r d; do [ -d "$d/r0" ] && echo "$d"; done > "$list"
  # the run streams: one a case (at most 8 renders: one free-running segment), made again when older than the ISP
  # tile testbench or the capture
  mkdir -p "$rsdir"
  need=$GATE_DIR/need.txt
  : > "$need"
  : > "$streams"
  while read -r d; do
    n=$(ls -d "$d"/r* | wc -l)
    f=$rsdir/$(basename "$d").r0-$((n - 1)).rs.gz
    echo "$f" >> "$streams"
    if ! [ -f "$f" ] || ! [ "$f" -nt build/obj_isp_tile/tb ] || ! [ "$f" -nt "$d/info.txt" ]; then echo "$d" >> "$need"; fi
  done < "$list"
  note "inputs: $(echo $tests | wc -w) test pages (at most 8 renders each), $(echo $dumps | wc -w) dumps, $(echo $seeds | wc -w) scenegen seeds: $(wc -l < "$streams") run streams, $(wc -l < "$need") made now"
  if [ -s "$need" ]; then
    sitems=$GATE_DIR/stream_items.txt
    : > "$sitems"
    python3 tools/gate/tile_items.py --list "$need" --group streams --logs shards-streams --split render \
      --cost "$GATE_DIR/cost.txt" --jobs "$J" -- build/obj_isp_tile/tb --mode free --vramvary 7 \
      --phase-limit 500000000 --dump-runs "$rsdir" >> "$sitems"
    gate_queue streams "$sitems"
    while read -r f; do [ -f "$f" ] || { GATE_LINES+=("streams: FAIL (no $f)"); GATE_FAILED=1; echo "streams: no $f"; }; done < "$streams"
  fi
fi

# the per-case lines of a run, summed
summ() {
  cat "$1"/log_*.txt 2>/dev/null | grep -h '^sort: .*: [0-9]* \(renders\|streams\), ' | gawk '
    function g(re,   m) { return match($0, re, m) ? m[1] : 0 }
    { u += g(": ([0-9]+) (renders|streams), "); e += g(" ([0-9]+) entries"); p += g(" ([0-9]+) passes")
      i += g(" ([0-9]+) items \\("); nl += g("\\(([0-9]+) null\\)"); c += g("; ([0-9]+) clocks")
      f += g("window full ([0-9]+) clk"); w += g(" ([0-9]+) steps held"); d += g(" ([0-9]+) drains \\(")
      de += g(" ([0-9]+) drain ends"); q = g("run queue at most ([0-9]+)"); if (q + 0 > qm) qm = q + 0 }
    END { printf "%d %s, %d entries, %d passes, %d items (%d null); %d clocks (%.3f an item), window full %d clk, %d steps held by the emit condition, %d drains (%.2f runs a drain), %d drain ends with no emit, run queue at most %d", u, unit, e, p, i, nl, c, i ? c / i : 0, f, w, d, d ? (i - nl) / d : 0, de, qm }' unit="$2"
}

if [ "$mode" != --mutants ]; then
  items=$GATE_DIR/items.txt
  : > "$items"
  gate_item "$items" lint-sort - 2 1 step lint-sort.log $MAKE -s lint-sort
  nblk=$(( (nrandom + 999) / 1000 ))
  ns=$(wc -l < "$streams")
  for c in $CFGS; do
    k=0
    while read -r f; do
      est=$(( $(stat -c %s "$f") / 20000 + 1 ))
      gate_item "$items" "subset-$c" "$(basename "$f")" "$est" 1 tb "shards-subset-$c/log_$k.txt" \
        build/obj_sort/tb --cfg "$c" --shard "$k/$ns" "@$streams"
      k=$((k + 1))
    done < "$streams"
    for b in $(seq 0 $((nblk - 1))); do
      gate_item "$items" "random-$c" "$b" 3 1 tb "shards-random-$c/log_$b.txt" \
        build/obj_sort/tb --cfg "$c" --random "$nrandom" --block 1000 --shard "$b/$nblk"
    done
  done
  gate_queue queue "$items"
  for c in $CFGS; do
    note "SPAN_SORT_CFG $c, subset: $(summ "$GATE_DIR/shards-subset-$c" renders)"
    note "SPAN_SORT_CFG $c, random: $(summ "$GATE_DIR/shards-random-$c" streams)"
  done
else
  gate_mutants mutants tb/sort/mutants.txt --njobs "${SORT_MUT_NJOBS:-4}"
fi
gate_end

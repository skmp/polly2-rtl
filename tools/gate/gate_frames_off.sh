#!/bin/bash
# gate_frames_off.sh: the frame gate (PLAN M12 "make frames", M13 "make frames-full", 1.4; conventions.md 7.4.2), run by
# make frames / frames-full / frames-mutants / frames-unit-mutants: p2-offline (refsw3-offline with the RTL for
# RenderCORE, tb/frame/p2_rendercore.cpp) against refsw3-offline, every word of video memory after every render.
#
#   tools/gate/gate_frames_off.sh [--subset | --full | --mutants | --unit-mutants]
#
#   --subset (frames)  hw-pkg-check, check_ref_copies, check_ref_switches; the builds (refsw3-offline, scenegen,
#                      p2-offline, p2-offline-dual); the captures of the inputs with their command streams
#                      (tools/gate/capture_prerender.sh --max 8, CAP_STREAM=1): tb/frames/subset_tests.txt,
#                      subset_dumps.txt, subset_seeds.txt; then on one queue (PLAN 0 rule 8), a work item per case and
#                      configuration (tools/gate/frames_run.sh: the case's stream on p2-offline, tools/gate/frames_cmp.py):
#                        base    VR_LAT 8
#                        vary    +vramvary (P2_VRAMVARY=7)
#                        lat1    VR_LAT 1
#                        lat4    VR_LAT 4 (M13: PLAN 1.6's sweep is 1, 4, 8, 16)
#                        lat16   VR_LAT 16
#                      every render's video memory equal to refsw3-offline's in every word; VRAM-race renders (the hazard
#                      detector, ARCHITECTURE 3.2.1) and the renders after one that differed in their own class, each race
#                      render listed per configuration with its difference count (PLAN 5 D13); also lint-core (p2_core)
#                      and the dual mode once (p2-offline-dual on a dump: "p2-dual: render 0: equal")
#   --full (frames-full, M13)  the same on every pvrtest2 page (every test of dreamcast-tests pvr-tests / ta-tests that
#                      run2.sh takes, git-tracked, but dumprender, which renders the dumps; fit/hw's register-override
#                      variants and make frames' race case texctl_bank+0e4=900 too), its first FRAMES_FULL_MAX (256) renders, and every polly2-data dump (the .pvrdmp and
#                      the legacy vram_ / pvr_regs_ ones); with SAMPLE=<seed> (PLAN 0 rule 10) a seeded sample
#                      (tools/gate/sample_items.py): every case once in base (--every frames-base), the other
#                      configurations drawn at random within SAMPLE_BUDGET (4000 s), the always-run items
#                      (tools/gate/always_run.txt); without SAMPLE the exhaustive run (once, after the last milestone)
#   --mutants          the builds and the captures the probes use, tools/gate/mutants.py on tb/frames/mutants*.txt (PLAN
#                      M12's mutants that the frame gate catches: the hazard detector off, the background not shaded
#                      with keep Z off, ...; M13's sequencer mutants, mutants_seq.txt; M13's dither mutants on fbpack's
#                      dither variants, mutants_wout.txt): every one caught
#   --unit-mutants (frames-unit-mutants, M13)  the M6-M12 mutant lists (tb/frames/unit_mutant_lists.txt) through the frame
#                      gate: tools/gate/frames_unit_mutants.py merges them into one list on rtl/v1 (RTLV1: one control),
#                      each mutant's probe the base configuration of the whole subset (tools/gate/frames_mprobe.sh, the
#                      cheap cases first, then the rest longest first, FRAMES_MPROBE_J at a time, stopping at the first
#                      that differs; the survivors' reasons: tb/frames/unit_mutant_reasons.txt); reported,
#                      not a pass criterion of the mutants (a mutant the frame subset does not reach is caught by its own
#                      unit gate): per mutant "caught by frames" or "only by its unit gate", the control must pass
#
# Ends with "<gate>: PASS" or "<gate>: FAIL"; build/gate/<gate>/summary.txt with the revision header, each step's line,
# the totals per configuration (renders, equal, differ; VRAM-race; clocks: reported, not gated) and the time line
# (lib.sh). Environment: FRAMES_J (the queue's slots, P2_J), FRAMES_CFGS (the configurations, "base vary lat1 lat4 lat16"),
# FRAMES_TIMEOUT (seconds a case may take, 7200), FRAMES_MUT_NJOBS (each mutant build's make -j, 4), FRAMES_FULL_MAX,
# FRAMES_MPROBE_J (8), SAMPLE, SAMPLE_BUDGET.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:---subset}
SAMPLE=${SAMPLE:-}
case "$mode" in
  --subset)       gate=frames ;;
  --full)         gate=frames-full ;;
  --mutants)      gate=frames-mutants ;;
  --unit-mutants) gate=frames-unit-mutants ;;
  *)              echo "usage: gate_frames_off.sh [--subset | --full | --mutants | --unit-mutants]"; exit 2 ;;
esac
if [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock env SAMPLE="$SAMPLE" bash "$0" "$@"
fi
. "$HERE/lib.sh"
J=${FRAMES_J:-$P2_J}
CFGS=${FRAMES_CFGS:-base vary lat1 lat4 lat16}
BUDGET=${SAMPLE_BUDGET:-4000}
MAXR=8
[ "$mode" = --full ] && MAXR=${FRAMES_FULL_MAX:-256}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}
export POLLY2_DUMPS=${POLLY2_DUMPS:-$P2_ROOT/../dreamster/polly2-rtl/polly2-data/dumps}
export CAP_STREAM=1
note() { GATE_LINES+=("    $1"); echo "    $1"; }
cases_of() {   # the subset file's cases, comments and blank lines dropped; seeds' ranges a-b expanded
  sed 's/#.*//' "$1" | awk 'NF { print $1 }' | while read -r c; do
    if [[ "$c" =~ ^([0-9]+)-([0-9]+)$ ]]; then seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; else echo "$c"; fi
  done
}

gate_begin "$gate"
gate_step hw-pkg-check       $MAKE -s hw-pkg-check
gate_step check_ref_copies   bash tools/check_ref_copies.sh
gate_step check_ref_switches bash tools/check_ref_switches.sh --no-hwpkg
gate_step build              $MAKE -s -j"$J" NJOBS="$J" refsw3-offline refglue-build scenegen p2-offline p2-offline-dual

if [ "$mode" = --mutants ]; then
  list=$(sed 's/#.*//' tb/frames/mutant_cases.txt | awk 'NF { print $1 }')
elif [ "$mode" = --full ]; then
  dumps=$( (ls "$POLLY2_DUMPS"/*.pvrdmp | xargs -n 1 basename | sed 's/\.pvrdmp$//';
            ls "$POLLY2_DUMPS"/vram_*.bin | xargs -n 1 basename | sed 's/^vram_//; s/\.bin$//' | grep -v '^out_') | sort -u)
  list=$( (for f in $(git -C "$DCTESTS" ls-files 'pvr-tests/*/main.c' 'ta-tests/*/main.c'); do
             grep -q 'pvrtest2.h\|pvrio.h\|#include "\.\./[a-z0-9_]*/main.c"' "$DCTESTS/$f" && basename "$(dirname "$f")"
           done | grep -vx dumprender
           ls "$DCTESTS/fit/hw" | grep '+' | grep -v '@'
           echo "texctl_bank+0e4=900"    # make frames' VRAM-race case (M12)
           for d in $dumps; do echo "dump:$d"; done) | awk '!seen[$0]++')
else
  list=$( (cases_of tb/frames/subset_tests.txt; cases_of tb/frames/subset_dumps.txt | sed 's/^/dump:/';
           cases_of tb/frames/subset_seeds.txt | sed 's/^/gen:/') | awk '!seen[$0]++')
fi
captures() {
  bash tools/gate/capture_prerender.sh -j "$J" --max "$MAXR" $list > "$GATE_DIR/captures.out" 2>&1
  local st=$?
  cat "$GATE_DIR/captures.out"
  [ $st = 0 ] && return 0
  ! grep '^capture_prerender: [^ ]*: ' "$GATE_DIR/captures.out" | grep -v ': once more, alone$' |
    awk '{ n = $2; $1 = $2 = ""; last[n] = $0 } END { for (n in last) print n, last[n] }' |
    grep -v ' [0-9]* renders captured\| up to date\| no render$' | grep -q .
}
gate_step captures captures
dirs=$GATE_DIR/cases.txt
for c in $list; do
  case "$c" in dump:*) n=dump_${c#dump:} ;; gen:*) n=gen_${c#gen:} ;; *) n=$c ;; esac
  [ -d "build/pre/$n/r0" ] && echo "build/pre/$n"
done > "$dirs"
nren=$(while read -r d; do ls -d "$d"/r* 2>/dev/null; done < "$dirs" | wc -l)
norender=$(sed -n 's/^capture_prerender: \(.*\): no render$/\1/p' "$GATE_DIR/captures.out" | sort -u)
[ -n "$norender" ] && note "no render (no input): $(echo $norender)"
note "inputs: $(wc -l < "$dirs") cases ($(grep -vc 'dump_\|gen_' "$dirs") test pages, at most $MAXR renders each; $(grep -c 'dump_' "$dirs") dumps; $(grep -c 'gen_' "$dirs") scenegen seeds), $nren renders; configurations: $CFGS"

if [ "$mode" = --mutants ]; then
  gate_mutants mutants      tb/frames/mutants.txt      --njobs "${FRAMES_MUT_NJOBS:-4}"
  gate_mutants mutants-isp  tb/frames/mutants_isp.txt  --njobs "${FRAMES_MUT_NJOBS:-4}"
  gate_mutants mutants-tbuf tb/frames/mutants_tbuf.txt --njobs "${FRAMES_MUT_NJOBS:-4}"
  gate_mutants mutants-seq  tb/frames/mutants_seq.txt  --njobs "${FRAMES_MUT_NJOBS:-4}"
  gate_mutants mutants-wout tb/frames/mutants_wout.txt --njobs "${FRAMES_MUT_NJOBS:-4}"
  gate_end
fi
if [ "$mode" = --unit-mutants ]; then
  # the probe's cases by make frames' last base run (its cost file), else by renders: the cheapest first up to a tenth of
  # the total (most mutants are caught there), then the rest longest first (a survivor runs every case: its pole early)
  python3 - "$dirs" build/gate/frames/cost.txt "$GATE_DIR/mprobe_cases.txt" <<'PY'
import os, sys
sys.path.insert(0, "tools/gate")
import pqlib
dirs, cost_f, out = sys.argv[1:4]
cost = pqlib.read_cost(cost_f)
cases = [l.strip() for l in open(dirs) if l.strip()]
def c(d):
    n = d[len("build/pre/"):]
    k = cost.get(("frames-base", n))
    return k if k is not None else 1e3 + len([x for x in os.listdir(d) if x.startswith("r")])
asc = sorted(cases, key=c)
tot = sum(c(d) for d in cases)
head, s = [], 0.0
for d in asc:
    if s + c(d) > 0.1 * tot:
        break
    head.append(d)
    s += c(d)
rest = sorted(asc[len(head):], key=c, reverse=True)
with open(out, "w") as f:
    for d in head + rest:
        f.write(d + "\n")
PY
  gate_step lists python3 tools/gate/frames_unit_mutants.py --cases "$GATE_DIR/mprobe_cases.txt" --jobs "${FRAMES_MPROBE_J:-8}" \
    --out "$GATE_DIR/lists/frames_units/mutants.txt" tb/frames/unit_mutant_lists.txt
  while IFS= read -r l; do note "$l"; done < <(grep '^frames-unit-mutants: ' "$GATE_DIR/lists.log")
  failed0=$GATE_FAILED
  GATE_IN_QUEUE=1 gate_step mutants python3 tools/gate/mutants.py "$GATE_DIR/lists/frames_units/mutants.txt" --jobs "$J" \
    --cost "$GATE_DIR/cost.txt" --njobs "${FRAMES_MUT_NJOBS:-4}"
  python3 tools/gate/frames_unit_mutants.py --report "$GATE_DIR/mutants.log" --out "$GATE_DIR/lists/frames_units/mutants.txt" \
    tb/frames/unit_mutant_lists.txt > "$GATE_DIR/report.txt"
  while IFS= read -r l; do note "$l"; done < "$GATE_DIR/report.txt"
  l=$(sed -n 's/^.*-mutants: wall .*, slowest \(.*\) \([0-9.]*\) s$/\1 \2/p' "$GATE_DIR/mutants.log" | tail -1)
  [ -n "$l" ] && gate_slow "mutants ${l% *}" "${l##* }"
  # reported, not a pass criterion (a survivor is a mutant the subset does not reach): the control must pass and every
  # mutant must build and run to its verdict
  GATE_FAILED=$failed0
  grep -q 'control .*: PASS' "$GATE_DIR/mutants.log" && ! grep -q ' ERROR' "$GATE_DIR/mutants.log" || GATE_FAILED=1
  for i in "${!GATE_LINES[@]}"; do
    case "${GATE_LINES[$i]}" in "mutants: FAIL"*) GATE_LINES[$i]="mutants: done, the verdicts reported (${GATE_LINES[$i]#mutants: FAIL (})";; esac
  done
  gate_end
fi

items=$GATE_DIR/items.txt
: > "$items"
gate_item "$items" lint-core - 30 1 step lint-core.log $MAKE -s lint-core
dual=$(grep 'dump_' "$dirs" | while read -r d; do [ -f "$POLLY2_DUMPS/${d#build/pre/dump_}.pvrdmp" ] && echo "$d"; done | head -1)
gate_item "$items" dual - 30 1 step dual.log bash tools/gate/frames_dual.sh "$POLLY2_DUMPS/${dual#build/pre/dump_}.pvrdmp"
while read -r d; do
  n=${d#build/pre/}
  case "$n" in dump_*) e=40 ;; gen_*) e=3 ;; *) e=$(( $(ls -d "$d"/r* | wc -l) * 6 )) ;; esac
  # frames-full's estimates where its cost file has none: make frames-full's first run (2026-11-25), base: a dump 4-25 s,
  # a test page about 4 s a render (13,008 renders, 58,556 CPU s)
  [ "$mode" = --full ] && case "$n" in dump_*) e=12 ;; gen_*) e=3 ;; *) e=$(( $(ls -d "$d"/r* | wc -l) * 4 + 2 )) ;; esac
  for cfg in $CFGS; do
    ec=$e; [ "$cfg" = vary ] && ec=$((e * 5))
    gate_item "$items" "frames-$cfg" "$n" "$ec" 1 tb "runs-$cfg/$n.log" bash tools/gate/frames_run.sh "$d" "$cfg" \
      "build/frames/$cfg/$n"
  done
done < "$dirs"
qopt=()
if [ "$mode" = --full ] && [ -n "$SAMPLE" ]; then
  mv "$items" "$GATE_DIR/items_all.txt"
  gate_step sample python3 tools/gate/sample_items.py --seed "$SAMPLE" --gate frames-full --budget "$BUDGET" \
    --jobs "$J" --cost "$GATE_DIR/cost.txt" --always tools/gate/always_run.txt --whole lint-core,dual --every frames-base \
    "$GATE_DIR/items_all.txt" "$items"
  while IFS= read -r l; do note "$l"; done < <(grep '^sample: ' "$GATE_DIR/sample.log")
  cp "$GATE_DIR/cost.txt" "$GATE_DIR/cost_before.txt" 2>/dev/null || : > "$GATE_DIR/cost_before.txt"
  qopt=(--optional "$items.optional" --deadline "$BUDGET")
fi
gate_queue queue "$items" "${qopt[@]}"
if [ "$mode" = --full ] && [ -n "$SAMPLE" ]; then
  python3 tools/gate/sample_items.py --coverage "$GATE_DIR/pq_results.tsv" --cost "$GATE_DIR/cost_before.txt" \
    "$GATE_DIR/items_all.txt" "$items" > "$GATE_DIR/coverage.log"
  while IFS= read -r l; do note "$l"; done < "$GATE_DIR/coverage.log"
fi

for cfg in $CFGS; do
  cat "$GATE_DIR"/runs-$cfg/*.log 2>/dev/null | gawk -v c="$cfg" '
    function v(re,   m) { return match($0, re, m) ? m[1] : 0 }
    /^frames_cmp: .*: [0-9]+ renders, / { nc++; r += v(": ([0-9]+) renders"); e += v(", ([0-9]+) equal"); d += v(", ([0-9]+) differ;")
      rc += v("VRAM-race ([0-9]+)"); rd += v("\\(([0-9]+) differ there"); ar += v("after a race ([0-9]+)")
      isp += v("; ([0-9]+) / "); tsp += v(" / ([0-9]+) clk"); w += v(", ([0-9]+) words compared") }
    /^frames_cmp: FAIL/ { bad++ }
    /: r[0-9]+: VRAM-race \(/ { split($0, a, ": "); split(a[2], cn, " "); nr++
      racers = racers sprintf(" %s %s %d", cn[1], a[3], v("\\): ([0-9]+) words differ")) }
    END {
      printf "frames-%s: %d cases (%d FAIL), %d renders: %d equal, %d differ; VRAM-race %d (%d differ there: their own class), after a race %d; %d words compared\n", c, nc, bad, r, e, d, rc, rd, ar, w
      printf "frames-%s: clocks (reported, not gated: MT7, MT9): ISP %d, TSP %d (the sums of the renders'"'"' ev_isp / ev_tsp from STARTRENDER)\n", c, isp, tsp
      if (nr) printf "frames-%s: the %d VRAM-race renders (case, render, words that differ; PLAN 5 D13):%s\n", c, nr, substr(racers, 1, 3000) }'
done > "$GATE_DIR/tb.txt"
grep -h ': r[0-9]*: did not end\|words differ, the first' "$GATE_DIR"/runs-*/*.log 2>/dev/null | head -20 >> "$GATE_DIR/tb.txt"
while IFS= read -r l; do note "$l"; done < "$GATE_DIR/tb.txt"
grep -qE '\([1-9][0-9]* FAIL\)' "$GATE_DIR/tb.txt" && { GATE_LINES+=("frames: FAIL"); GATE_FAILED=1; }
grep -qE '^frames-base: 0 cases ' "$GATE_DIR/tb.txt" && { GATE_LINES+=("frames: no case ran: FAIL"); GATE_FAILED=1; }
# PLAN 5 D13 (a): the VRAM-race renders against the pinned list tb/frames/races_expected.txt (a render that enters or
# leaves it, or a count that changes, fails; only the cases that ran are checked), with the checker's selftest
gate_step races-expected python3 tools/gate/races_expected.py --gate frames --selftest "$GATE_DIR"/runs-*/*.log
while IFS= read -r l; do note "$l"; done < <(grep '^races-expected: ' "$GATE_DIR/races-expected.log" | tail -12)
gate_end

#!/bin/bash
# gate_frames_off.sh: the M12 frame gate (PLAN M12 "make frames", 1.4; conventions.md 7.4.2), run by make frames /
# frames-mutants: p2-offline (refsw3-offline with the RTL for RenderCORE, tb/frame/p2_rendercore.cpp) against
# refsw3-offline, every word of video memory after every render.
#
#   tools/gate/gate_frames_off.sh [--subset | --mutants]
#
#   --subset (frames)  hw-pkg-check, check_ref_copies, check_ref_switches; the builds (refsw3-offline, scenegen,
#                      p2-offline, p2-offline-dual); the captures of the inputs with their command streams
#                      (tools/gate/capture_prerender.sh --max 8, CAP_STREAM=1): tb/frames/subset_tests.txt,
#                      subset_dumps.txt, subset_seeds.txt; then on one queue (PLAN 0 rule 8), a work item per case and
#                      configuration (tools/gate/frames_run.sh: the case's stream on p2-offline, tools/gate/frames_cmp.py):
#                        base    VR_LAT 8
#                        vary    +vramvary (P2_VRAMVARY=7)
#                        lat1    VR_LAT 1
#                        lat16   VR_LAT 16
#                      every render's video memory equal to refsw3-offline's in every word; VRAM-race renders (the hazard
#                      detector, ARCHITECTURE 3.2.1) and the renders after one that differed in their own class; also
#                      lint-core (p2_core) and the dual mode once (p2-offline-dual on a dump: "p2-dual: render 0: equal")
#   --mutants          the builds and the captures the probes use, tools/gate/mutants.py on tb/frames/mutants*.txt (PLAN
#                      M12's mutants that the frame gate catches: the hazard detector off, the background not shaded
#                      with keep Z off, ...): every one caught
#
# Ends with "<gate>: PASS" or "<gate>: FAIL"; build/gate/<gate>/summary.txt with the revision header, each step's line,
# the totals per configuration (renders, equal, differ; VRAM-race; clocks: reported, not gated) and the time line
# (lib.sh). Environment: FRAMES_J (the queue's slots, P2_J), FRAMES_CFGS (the configurations, "base vary lat1 lat16"),
# FRAMES_TIMEOUT (seconds a case may take, 7200), FRAMES_MUT_NJOBS (each mutant build's make -j, 4).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:---subset}
case "$mode" in
  --subset)  gate=frames ;;
  --mutants) gate=frames-mutants ;;
  *)         echo "usage: gate_frames_off.sh [--subset | --mutants]"; exit 2 ;;
esac
if [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock bash "$0" "$@"
fi
. "$HERE/lib.sh"
J=${FRAMES_J:-$P2_J}
CFGS=${FRAMES_CFGS:-base vary lat1 lat16}
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
else
  list=$( (cases_of tb/frames/subset_tests.txt; cases_of tb/frames/subset_dumps.txt | sed 's/^/dump:/';
           cases_of tb/frames/subset_seeds.txt | sed 's/^/gen:/') | awk '!seen[$0]++')
fi
captures() {
  bash tools/gate/capture_prerender.sh -j "$J" --max 8 $list > "$GATE_DIR/captures.out" 2>&1
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
note "inputs: $(wc -l < "$dirs") cases ($(grep -vc 'dump_\|gen_' "$dirs") test pages, at most 8 renders each; $(grep -c 'dump_' "$dirs") dumps; $(grep -c 'gen_' "$dirs") scenegen seeds), $nren renders; configurations: $CFGS"

if [ "$mode" = --mutants ]; then
  gate_mutants mutants      tb/frames/mutants.txt      --njobs "${FRAMES_MUT_NJOBS:-4}"
  gate_mutants mutants-isp  tb/frames/mutants_isp.txt  --njobs "${FRAMES_MUT_NJOBS:-4}"
  gate_mutants mutants-tbuf tb/frames/mutants_tbuf.txt --njobs "${FRAMES_MUT_NJOBS:-4}"
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
  for cfg in $CFGS; do
    ec=$e; [ "$cfg" = vary ] && ec=$((e * 5))
    gate_item "$items" "frames-$cfg" "$n" "$ec" 1 tb "runs-$cfg/$n.log" bash tools/gate/frames_run.sh "$d" "$cfg" \
      "build/frames/$cfg/$n"
  done
done < "$dirs"
gate_queue queue "$items"

for cfg in $CFGS; do
  cat "$GATE_DIR"/runs-$cfg/*.log 2>/dev/null | gawk -v c="$cfg" '
    function v(re,   m) { return match($0, re, m) ? m[1] : 0 }
    /^frames_cmp: .*: [0-9]+ renders, / { nc++; r += v(": ([0-9]+) renders"); e += v(", ([0-9]+) equal"); d += v(", ([0-9]+) differ;")
      rc += v("VRAM-race ([0-9]+)"); rd += v("\\(([0-9]+) differ there"); ar += v("after a race ([0-9]+)")
      isp += v("; ([0-9]+) / "); tsp += v(" / ([0-9]+) clk"); w += v(", ([0-9]+) words compared") }
    /^frames_cmp: FAIL/ { bad++ }
    /VRAM-race \(.*words differ/ { split($0, a, ": "); racers[a[2]] = 1 }
    END {
      printf "frames-%s: %d cases (%d FAIL), %d renders: %d equal, %d differ; VRAM-race %d (%d differ there: their own class), after a race %d; %d words compared\n", c, nc, bad, r, e, d, rc, rd, ar, w
      printf "frames-%s: clocks (reported, not gated: MT7, MT9): ISP %d, TSP %d (the sums of the renders'"'"' ev_isp / ev_tsp from STARTRENDER)\n", c, isp, tsp
      s = ""; for (k in racers) s = s " " k; if (s != "") printf "frames-%s: the race renders that differ:%s\n", c, s }'
done > "$GATE_DIR/tb.txt"
grep -h ': r[0-9]*: did not end\|words differ, the first' "$GATE_DIR"/runs-*/*.log 2>/dev/null | head -20 >> "$GATE_DIR/tb.txt"
while IFS= read -r l; do note "$l"; done < "$GATE_DIR/tb.txt"
grep -qE '\([1-9][0-9]* FAIL\)' "$GATE_DIR/tb.txt" && { GATE_LINES+=("frames: FAIL"); GATE_FAILED=1; }
grep -qE ': 0 cases ' "$GATE_DIR/tb.txt" && { GATE_LINES+=("frames: no case ran: FAIL"); GATE_FAILED=1; }
gate_end

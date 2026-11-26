#!/bin/bash
# gate_frames_hw.sh: the M13 console-archive gate (PLAN M13, 1.4 "gate_frames_hw.sh"; conventions.md 7.4.3), run by make
# frames-hw / frames-hw-full: p2-offline (refsw3-offline with the RTL for RenderCORE) against the console's archived
# results, judged by the computed refsw3-known (PLAN 0 rule 4: refsw3-equal everywhere refsw3 is console-equal; where
# refsw3 differs from the console the RTL may not be worse).
#
#   tools/gate/gate_frames_hw.sh [--subset | --full]
#
#   --subset (frames-hw)  hw-pkg-check, check_ref_copies, check_ref_switches; the builds (refsw3-offline, p2-offline,
#                         ztap_cmp) and ztap_cmp's self-check (tools/gate/ztap_selftest.sh); refsw3-known (build/gate/refsw3_known.txt, tools/gate/refsw3_known.sh run when its
#                         header is not this nulldc3 / refsw3-dirty / dreamcast-tests revision or a section is missing);
#                         the streams (tools/gate/capture_hwstream.sh: the whole command stream refsw3-offline was given,
#                         no render cap); then on one queue (PLAN 0 rule 8) an item per input and configuration
#                         (tools/gate/frames_hw_run.sh, frames_hw_cmp.py), the configurations base (VR_LAT 8) and vary
#                         (+vramvary 7; PLAN 1.6: on every functional gate; the VR_LAT sweep is make frames'):
#                           test:<run>   tb/frames_hw/subset_tests.txt (fit/hw tests): compare2.py <test> ref off, region by
#                                        region; every readback's answer against refsw3-offline's (frames_hw_cmp.py)
#                           set:<t>@<s>  tb/frames_hw/subset_sets.txt (archived sets): the reader, compare_archive.py
#                           png:<scene>  tb/frames_hw/subset_png.txt: the frame against framepng.py raw <scene>.hw.png
#                           vout:<scene> tb/frames_hw/subset_vout.txt: all of video memory against vram_out_<scene>.bin
#                           z:<scene>    every fit/zdump_data/<scene>.txt: the depth tap against the console's depths
#   --full (frames-hw-full)  every directory of fit/hw enumerated at gate time (*_races excluded: MT8's), every archived
#                         set with a reader, every <scene>.hw.png, every vram_out_<scene>.bin, every zdump; the
#                         configurations of FRAMES_HW_FULL_CFGS ("base vary"). With SAMPLE=<seed> (PLAN 0 rule 10) a seeded
#                         sample (tools/gate/sample_items.py): every input once in the base configuration where the budget
#                         allows (--every: the base items predicted to fit, the rest and the vary items drawn at random
#                         while the queue's predicted end stays within SAMPLE_BUDGET, 4000 s; the inputs whose base item
#                         alone is predicted over FRAMES_HW_MAX_ITEM (SAMPLE_BUDGET) are listed and never drawn), the
#                         always-run items (tools/gate/always_run.txt); the seed and the coverage in the summary. Without
#                         SAMPLE the exhaustive run (once, after the last milestone). Under /tmp/polly2-rtl-gate.lock.
#
# Ends with "<gate>: PASS" or "<gate>: FAIL"; build/gate/<gate>/summary.txt with the revision header, each step's line,
# per kind and configuration the items, the regions / sets / frames / depths, the refsw3-known regions, the VRAM-race
# class (reported, never a pass or a fail), the clocks (reported, not gated) and the time line (lib.sh). Environment:
# FRAMES_HW_J (the queue's slots, P2_J), FRAMES_HW_CFGS ("base vary"), FRAMES_HW_TIMEOUT (seconds an item's p2-offline
# may take, 86400), FRAMES_HW_MAX_ITEM, SAMPLE, SAMPLE_BUDGET.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:---subset}
SAMPLE=${SAMPLE:-}
case "$mode" in
  --subset) gate=frames-hw ;;
  --full)   gate=frames-hw-full ;;
  *)        echo "usage: gate_frames_hw.sh [--subset | --full]"; exit 2 ;;
esac
if [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock env SAMPLE="$SAMPLE" bash "$0" "$@"
fi
. "$HERE/lib.sh"
J=${FRAMES_HW_J:-$P2_J}
if [ "$mode" = --full ]; then CFGS=${FRAMES_HW_FULL_CFGS:-base vary}; else CFGS=${FRAMES_HW_CFGS:-base vary}; fi
BUDGET=${SAMPLE_BUDGET:-4000}
# an item's p2-offline may run this long (frames_hw_run.sh's FRAMES_TIMEOUT): the exhaustive run's readback searches take
# hours (nantr_word, 6,576 renders); a render that never ends stops at P2_CLK_LIMIT anyway
export FRAMES_TIMEOUT=${FRAMES_HW_TIMEOUT:-86400}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}
export POLLY2_DUMPS=${POLLY2_DUMPS:-$P2_ROOT/../dreamster/polly2-rtl/polly2-data/dumps}
note() { GATE_LINES+=("    $1"); echo "    $1"; }
list_of() { sed 's/#.*//' "$1" | awk 'NF { print $1 }'; }

gate_begin "$gate"
gate_step hw-pkg-check       $MAKE -s hw-pkg-check
gate_step check_ref_copies   bash tools/check_ref_copies.sh
gate_step check_ref_switches bash tools/check_ref_switches.sh --no-hwpkg
gate_step build              $MAKE -s -j"$J" NJOBS="$J" refsw3-offline p2-offline ztap-cmp
# ztap_cmp's own rules on synthetic taps (the two zdumps never tap a tile twice: the last entry of a tile must win)
gate_step ztap-cmp-check     bash tools/gate/ztap_selftest.sh

# ---- refsw3-known: computed at gate time when stale (PLAN 1.4)
KNOWN=$P2_ROOT/build/gate/refsw3_known.txt
known_fresh() {
  [ -f "$KNOWN" ] || return 1
  local h1 h2
  h1=$(sed -n 1p "$KNOWN"); h2=$(sed -n 2p "$KNOWN" | sed 's/ ; polly2-rtl .*//')
  [ "$h1" = "$(rev_header | sed -n 1p)" ] && [ "$h2" = "$(rev_header | sed -n 2p | sed 's/ ; polly2-rtl .*//')" ] &&
    grep -q '^# sections: tests sets dumps$' "$KNOWN"
}
if known_fresh; then
  GATE_LINES+=("refsw3-known: build/gate/refsw3_known.txt is this revision's ($(sed -n 1p "$KNOWN"); $(sed -n 2p "$KNOWN" | sed 's/ ; polly2-rtl .*//'))")
  echo "refsw3-known: up to date"
else
  gate_step refsw3-known bash tools/gate/refsw3_known.sh -j "$J"
fi
while IFS= read -r l; do note "$l"; done < <(
  awk 'NR > 2 && /^[^ #]/ && $1 != "set" && $1 != "png" && $1 != "vout" { n++; split($2, a, "/"); if (a[1] != a[2]) d++; if ($3 == "input-stale") s++ }
       $1 == "set" { ns++; if (/DIFFER/) ds++ } $1 == "png" { np++; if ($3 != 0) dp++ } $1 == "vout" { nv++; if ($3 != 0) dv++ }
       END { printf "refsw3-known: %d tests (%d differ from the console, %d input-stale), %d sets (%d differ), %d hw.png frames (%d differ), %d vram_out (%d differ)\n", n, d, s, ns, ds, np, dp, nv, dv }' "$KNOWN")

# ---- the inputs
DUMPS=$POLLY2_DUMPS
if [ "$mode" = --full ]; then
  tests=$(ls "$DCTESTS/fit/hw" | grep -v '_races$')
  sets=$(awk '$1 == "set" { print $2 }' "$KNOWN")
  pngs=$(ls "$DUMPS"/*.hw.png | xargs -n 1 basename | sed 's/\.hw\.png$//')
  vouts=$(ls "$DUMPS"/vram_out_*.bin | xargs -n 1 basename | sed 's/^vram_out_//; s/\.bin$//')
else
  tests=$(list_of tb/frames_hw/subset_tests.txt)
  sets=$(list_of tb/frames_hw/subset_sets.txt)
  pngs=$(list_of tb/frames_hw/subset_png.txt)
  vouts=$(list_of tb/frames_hw/subset_vout.txt)
fi
zs=$(ls "$DCTESTS"/fit/zdump_data/*.txt | xargs -n 1 basename | sed 's/\.txt$//')
note "inputs: $(echo $tests | wc -w) fit/hw tests (of $(ls "$DCTESTS/fit/hw" | grep -vc '_races$'), the *_races excluded), $(echo $sets | wc -w) archived sets, $(echo $pngs | wc -w) hw.png frames, $(echo $vouts | wc -w) vram_out, $(echo $zs | wc -w) zdumps; configurations: $CFGS"
captures() {
  bash tools/gate/capture_hwstream.sh -j "$J" $tests $sets > "$GATE_DIR/captures.out" 2>&1
  local st=$?
  grep -v ': up to date' "$GATE_DIR/captures.out" | tail -n 20
  return $st
}
gate_step captures captures
note "streams: $(for r in $tests $sets; do cat "build/hwstream/$r/renders" 2>/dev/null; done | awk '{ s += $1 } END { print s + 0 }') renders"

# ---- the items: an estimate from the stream (where the cost file has none): p2-offline ~30 times refsw3-offline's
# seconds on it, at least ~4 s a render (2026-11-25, frames-hw-full's first run beside 15 others: the readback searches,
# depth2_cneg 2,096 renders 7,200 s, depthgaps_bigslope 1,746 renders 6,642 s; perpmean_strip, zbadk, scalertile 26-30x);
# a dump ~10 s
est() {   # est <run> <multiplier>
  local a b
  a=$(( $(cat "build/hwstream/$1/secs" 2>/dev/null || echo 1) * 30 ))
  b=$(( $(cat "build/hwstream/$1/renders" 2>/dev/null || echo 8) * 4 ))
  echo $(( ((a > b ? a : b) + 3) * $2 ))
}
items=$GATE_DIR/items.txt
: > "$items"
for cfg in $CFGS; do
  m=1; [ "$cfg" = vary ] && m=5
  for r in $tests; do
    e=$(est "$r" "$m")
    gate_item "$items" "test-$cfg" "$r" "$e" 1 tb "runs-$cfg/test.$r.log" bash tools/gate/frames_hw_run.sh "test:$r" "$cfg" "build/frames-hw/$cfg"
  done
  for r in $sets; do
    e=$(est "$r" "$m")
    gate_item "$items" "set-$cfg" "$r" "$e" 1 tb "runs-$cfg/set.$r.log" bash tools/gate/frames_hw_run.sh "set:$r" "$cfg" "build/frames-hw/$cfg"
  done
  for s in $pngs; do
    gate_item "$items" "png-$cfg" "$s" $((10 * m)) 1 tb "runs-$cfg/png.$s.log" bash tools/gate/frames_hw_run.sh "png:$s" "$cfg" "build/frames-hw/$cfg"
  done
  for s in $vouts; do
    gate_item "$items" "vout-$cfg" "$s" $((10 * m)) 1 tb "runs-$cfg/vout.$s.log" bash tools/gate/frames_hw_run.sh "vout:$s" "$cfg" "build/frames-hw/$cfg"
  done
  for s in $zs; do
    gate_item "$items" "z-$cfg" "$s" $((20 * m)) 1 tb "runs-$cfg/z.$s.log" bash tools/gate/frames_hw_run.sh "z:$s" "$cfg" "build/frames-hw/$cfg"
  done
done

qopt=()
if [ "$mode" = --full ] && [ -n "$SAMPLE" ]; then
  mv "$items" "$GATE_DIR/items_all.txt"
  # every input once in base where the budget allows: the base items predicted over FRAMES_HW_MAX_ITEM seconds (the
  # readback searches: thousands of renders) are left to the exhaustive run, listed below
  maxi=${FRAMES_HW_MAX_ITEM:-$BUDGET}
  python3 - "$GATE_DIR/items_all.txt" "$GATE_DIR/cost.txt" "$maxi" "$GATE_DIR/items_cut.txt" "$GATE_DIR/too_long.txt" <<'PY'
import sys
sys.path.insert(0, "tools/gate")
import pqlib
items_in, cost_f, maxi, out, too = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4], sys.argv[5]
cost = pqlib.read_cost(cost_f)
with open(items_in) as f, open(out, "w") as o, open(too, "w") as t:
    for line in f:
        g, iid, est = line.split("\t")[:3]
        p = float(cost.get((g, iid), est))
        (t if p > maxi else o).write(line if p <= maxi else f"{g}\t{iid}\t{p:.0f}\n")
PY
  ntoo=$(wc -l < "$GATE_DIR/too_long.txt")
  # every one named (the whole list, sorted by kind and name; M13's verifier: a 1,500-character cut hid 53)
  if [ "$ntoo" -gt 0 ]; then
    note "sample: $ntoo items predicted over ${maxi} s alone, left to the exhaustive run ($(cut -f1 "$GATE_DIR/too_long.txt" | sort | uniq -c | awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $1, $2 }')):"
    while IFS= read -r l; do note "  $l"; done < <(sort -k1,1 -k2,2 "$GATE_DIR/too_long.txt" |
      awk -F'\t' '{ g[$1] = g[$1] (g[$1] == "" ? "" : ", ") $2 " (" $3 " s)" } END { for (k in g) print k ": " g[k] }' | sort)
  fi
  gate_step sample python3 tools/gate/sample_items.py --seed "$SAMPLE" --gate frames-hw-full --budget "$BUDGET" \
    --jobs "$J" --cost "$GATE_DIR/cost.txt" --always tools/gate/always_run.txt --every test-base,set-base,png-base,vout-base,z-base \
    "$GATE_DIR/items_cut.txt" "$items"
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

# ---- the totals per kind and configuration
for cfg in $CFGS; do
  for k in test set png vout z; do
    ls "$GATE_DIR"/runs-$cfg/$k.*.log > /dev/null 2>&1 || continue
    cat "$GATE_DIR"/runs-$cfg/$k.*.log | gawk -v c="$cfg" -v k="$k" '
      function v(re,   m) { return match($0, re, m) ? m[1] : 0 }
      /^frames_hw: [a-z]+:[^ ]+ [a-z]+: .*; [0-9]+ checks, [0-9]+ failures$/ { n++; ck += v("; ([0-9]+) checks,"); fl += v("checks, ([0-9]+) failures")
        if (k == "test") { rs += v("in ([0-9]+) of [0-9]+ regions"); rr += v("in [0-9]+ of ([0-9]+) regions"); kn += v("\\(([0-9]+) refsw3-known, not")
                           kb += v("; ([0-9]+) refsw3-known now"); rc += v("; ([0-9]+) after a VRAM-race"); if (/input-stale/) st++ }
        if (k == "test" || k == "set") { rbe += v("; readbacks ([0-9]+) of"); rbn += v("; readbacks [0-9]+ of ([0-9]+)")
                           rbr += v("refsw3-offline.s \\(([0-9]+) after a VRAM-race"); if (v("; readbacks [0-9]+ of ([0-9]+)") > 0) rbt++ }
        rend += v("([0-9]+) renders, ISP"); isp += v("ISP ([0-9]+) /"); tsp += v("/ TSP ([0-9]+) clk") }
      /^frames_hw: FAIL/ { bad++ }
      /\(their own class\)$/ { race = race "; " $0 }
      END {
        printf "%s-%s: %d items (%d FAIL), %d checks, %d failures", k, c, n, bad, ck, fl
        if (k == "test") printf "; regions console = RTL %d of %d (%d refsw3-known, not worse; %d refsw3-known now equal; %d after a VRAM-race render, their own class); %d input-stale", rs, rr, kn, kb, rc, st
        if (k == "test" || k == "set") printf "; readbacks equal to refsw3-offline%cs %d of %d in %d items (%d after a VRAM-race render, their own class)", 39, rbe, rbn, rbt, rbr
        printf "; %d renders, clocks ISP %d / TSP %d (reported, not gated)\n", rend, isp, tsp
        if (race != "") printf "%s-%s: VRAM-race class%s\n", k, c, substr(race, 1, 1500) }'
  done
done > "$GATE_DIR/tb.txt"
grep -h '^frames_hw: .*\(differ, refsw3\|pixels differ, refsw3 equal\|did not end\|exit\|failed\|not in refsw3-known\|RTL [0-9a-f]* (key\|answer differs\|readbacks\(.*no \| in the stream\)\)' \
  "$GATE_DIR"/runs-*/*.log 2>/dev/null | head -20 >> "$GATE_DIR/tb.txt"
while IFS= read -r l; do note "$l"; done < "$GATE_DIR/tb.txt"
grep -qE '\([1-9][0-9]* FAIL\)' "$GATE_DIR/tb.txt" && { GATE_LINES+=("frames-hw: FAIL"); GATE_FAILED=1; }
grep -qE '^[a-z]+-base: [1-9]' "$GATE_DIR/tb.txt" || { GATE_LINES+=("frames-hw: no item ran: FAIL"); GATE_FAILED=1; }
gate_end

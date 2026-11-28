#!/bin/bash
# gate_timing.sh: the MT0 timing harness gate and its companions (PLAN MT0, 1.5; conventions.md 7.6), run by make
# timing-harness / timing-harness-mutants / timing-fit / timing-report.
#
#   tools/timing/gate_timing.sh [--mutants | --fit | --report]
#
#   quick (timing-harness)   p2-offline; the timemeas PC emission (dreamcast-tests: make -C pvr-tests/timemeas emit, main.c
#                  TM_EMIT, PLAN 5 D7) into build/timing/emit; the streams of the variants all and cut; then on one queue
#                  (PLAN 0 rule 8): the gate's scenes of `all` (bgonly, wout, clip, zk), the cut variant's cut / cutn
#                  scenes, the order variant whole (live: its pixels are read back) with the palette clock through
#                  P2_TIMED_WRITES (tools/timing/tm_order_writes.py); each item p2-offline with the timing tap (P2_TIMING)
#                  under tb/timing/k.txt's VRAM configuration (P2_VR_ROW). Then the checks of tb/timing/gate.txt, groups
#                  wout and cut (tools/timing/gate_timing.py: 0 <= console - (rtl + K) <= 14, slopes within 0.1 clk an
#                  object, single differences within 5); the order run as the console's log (tools/timing/tm_log.py) read
#                  by dreamcast-tests' order.py --fit (it must run: the palette clock end to end; its numbers are
#                  reported, MT3's); the races lists' consistency (tools/timing/races_check.py: tb/timing/races_*.txt
#                  against docs/probes.txt); the table of the gate's scenes (reported)
#   --mutants (timing-harness-mutants)  tools/gate/mutants.py on tb/timing/mutants.txt (the cutter +1 clk a run must fail
#                  the cut checks; the 888 write-out a pixel in two clocks must fail the wout checks)
#   --fit (timing-fit)   the fits, once (PLAN 0 rule 6): VR_ROW over TIMING_FIT_ROWS (4 .. 16) on gate.txt's fitdiff
#                  (clip 0 against clip 4: the 0888 write-out's per-line excess), the least |error| (the lower on a tie);
#                  then K on gate.txt's fit scene at that VR_ROW; writes tb/timing/k.txt (record the derivation in
#                  docs/timing.md 11)
#   --report (timing-report)   every timed scene: the variants all (cut into items, tools/timing/tm_items.py), cut, order,
#                  setupk, sortoff on one queue; each variant's console-format log (build/timing/report/<variant>.log,
#                  analyze.py's and order.py's input) and detail (.tsv); the table console against RTL of every scene
#                  (build/timing/report/table.txt, gate_timing.py --table) and its summary; analyze.py on the RTL's log
#                  of `all` (build/timing/report/analyze.txt); the *_races tests on the RTL (run2.sh off with p2-offline)
#                  and races_check.py --run on them: every listed expected miss still a miss, every other deterministic
#                  cell the console's (the one part of the report that fails it). Otherwise reported, not gated (PLAN
#                  MT0: the starting table for MT1)
#
# Ends with "<gate>: PASS" or "<gate>: FAIL"; build/gate/<gate>/summary.txt with the revision header, each step's line
# and the time line (tools/gate/lib.sh). Environment: TIMING_J (the queue's slots, P2_J), TIMING_MUT_NJOBS (each mutant
# build's make -j, 4), TIMING_ITEM_SECS (the report's item size, 60), TIMING_FIT_ROWS.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
case "$mode" in
  quick)     gate=timing-harness ;;
  --mutants) gate=timing-harness-mutants ;;
  --fit)     gate=timing-fit ;;
  --report)  gate=timing-report ;;
  *)         echo "usage: gate_timing.sh [--mutants | --fit | --report]"; exit 2 ;;
esac
. "$HERE/../gate/lib.sh"
J=${TIMING_J:-$P2_J}
note() { GATE_LINES+=("    $1"); echo "    $1"; }
TB=build/timing
EMIT=$P2_ROOT/$TB/emit
SD=$P2_ROOT/$TB/streams
TM=tools/timing
P2OFF=$P2_ROOT/build/p2-offline/p2-offline
VR_ROW=$(python3 -c "import sys; sys.path.insert(0, '$P2_ROOT/$TM'); import tmlib; print(int(tmlib.read_cfg('VR_ROW')))")
K=$(python3 -c "import sys; sys.path.insert(0, '$P2_ROOT/$TM'); import tmlib; print(tmlib.read_k())")

gate_begin "$gate"
note "timing configuration (tb/timing/k.txt): VR_ROW $VR_ROW, K $K"
gate_step build-p2-offline $MAKE -s NJOBS="$J" p2-offline
gate_step build-emission   $MAKE -s -C "$DCTESTS/pvr-tests/timemeas" emit EMIT="$EMIT"
mkdir -p "$SD"
gate_step streams bash -c "set -e
  '$EMIT/tm-all' '$SD/rb' > '$SD/all.txt'; '$EMIT/tm-cut' '$SD/rb' > '$SD/cut.txt'
  ! grep -q readback '$SD/all.txt' '$SD/cut.txt'
  echo \"streams: all \$(grep -c '^echo T ' '$SD/all.txt') T lines, cut \$(grep -c '^echo T ' '$SD/cut.txt')\""
note "$(tail -1 "$GATE_DIR/streams.log")"
items=$GATE_DIR/items.txt
: > "$items"
L=$GATE_DIR/runs

if [ "$mode" = --mutants ]; then
  # the probes read the cut stream and the all stream from build/timing/streams
  gate_mutants mutants      tb/timing/mutants.txt      --njobs "${TIMING_MUT_NJOBS:-4}"
  gate_mutants mutants-wout tb/timing/mutants_wout.txt --njobs "${TIMING_MUT_NJOBS:-4}"
  gate_end
fi

if [ "$mode" = --fit ]; then
  sel=$(python3 $TM/tm_items.py "$SD/all.txt" --match '^(clip [04] 0 0 0|bgonly 0 0 0 0)$' --split 1 | cut -f2)
  for v in ${TIMING_FIT_ROWS:-4 5 6 7 8 9 10 11 12 13 14 15 16}; do
    gate_item "$items" vrrow "$v" 15 1 tb "runs/vrrow_$v.log" env P2_VR_ROW="$v" bash $TM/tm_item.sh \
      "$EMIT/tm-all" "$SD/all.txt" "$sel" "$L/vrrow_$v.log"
  done
  gate_queue queue "$items"
  best="" be=""
  for v in ${TIMING_FIT_ROWS:-4 5 6 7 8 9 10 11 12 13 14 15 16}; do
    e=$(python3 $TM/gate_timing.py --spec tb/timing/gate.txt --fitdiff "$L/vrrow_$v.log" 2>&1 | tail -1)
    note "VR_ROW $v: $e"
    err=$(echo "$e" | awk '{ print ($NF < 0 ? -$NF : $NF) }')
    if [ -z "$be" ] || awk -v a="$err" -v b="$be" 'BEGIN { exit !(a < b) }'; then best=$v; be=$err; fi
  done
  [ -n "$best" ] || { GATE_LINES+=("fit: no VR_ROW: FAIL"); GATE_FAILED=1; gate_end; }
  gate_step fit-k python3 $TM/gate_timing.py --spec tb/timing/gate.txt --fit "$L/vrrow_$best.log"
  while IFS= read -r l; do note "$l"; done < "$GATE_DIR/fit-k.log"
  newk=$(awk '$1 == "K" { print $2 }' "$GATE_DIR/fit-k.log")
  if [ -n "$newk" ]; then
    {
      echo "# tb/timing/k.txt: the timing configuration (PLAN 1.5, MT0; docs/timing.md 11), written by make timing-fit, read by"
      echo "# tools/timing (tmlib.read_cfg) and the timing gates. Each value is fitted once and never adjusted per scene."
      echo "# VR_ROW: the least |rtl - console| of clip 0 - clip 4 (the 0888 write-out's per-line excess, tb/timing/gate.txt"
      echo "# fitdiff) over VR_ROW ${TIMING_FIT_ROWS:-4 .. 16}: error $be clk; K: $(grep '^fit: K' "$GATE_DIR/fit-k.log" | sed 's/^fit: //')"
      echo "VR_ROW $best"
      echo "K $newk"
    } > tb/timing/k.txt
    note "written tb/timing/k.txt: VR_ROW $best, K $newk"
  else
    GATE_LINES+=("fit: no K: FAIL"); GATE_FAILED=1
  fi
  gate_end
fi

PAL=$P2_ROOT/$TB/palette_writes.txt
gate_step palette-writes bash -c "python3 $TM/tm_order_writes.py > '$PAL'"
note "$(grep -h 'one every' "$GATE_DIR/palette-writes.log")"
run_item() {    # run_item <group> <id> <estimate> <variant> <stream|-> <renders> [env ...]
  local g=$1 id=$2 est=$3 v=$4 st=$5 r=$6; shift 6
  gate_item "$items" "$g" "$id" "$est" 1 tb "runs/$v-$id.log" env P2_VR_ROW="$VR_ROW" "$@" bash $TM/tm_item.sh \
    "$EMIT/tm-$v" "$st" "$r" "$L/$v-$id.log"
}

if [ "$mode" = --report ]; then
  OUT=$P2_ROOT/$TB/report
  rm -rf "$OUT" && mkdir -p "$OUT"
  while IFS=$'\t' read -r id r est n; do
    run_item all "$id" "$est" all "$SD/all.txt" "$r"
  done < <(python3 $TM/tm_items.py "$SD/all.txt" --item-secs "${TIMING_ITEM_SECS:-60}")
  run_item cut all 40 cut "$SD/cut.txt" all
  for v in order setupk sortoff; do run_item "$v" all 30 "$v" - 'match:^order ' P2_TIMED_WRITES="$PAL"; done
  # the *_races tests on the RTL (dreamcast-tests run2.sh off with p2-offline, conventions.md 7.4.1), one item a test
  for t in accbuf_races blendpos_races keepz_races ptchunkcarry_races ptchunkrun_races; do
    gate_item "$items" races "$t" 60 1 step "runs/races-$t.log" bash $TM/races_run.sh "$t" "$OUT/races" "$VR_ROW"
  done
  gate_queue queue "$items"
  for v in all cut order setupk sortoff; do
    gate_step "log-$v" bash -c "python3 $TM/tm_log.py --detail '$OUT/$v.tsv' $L/$v-*.log > '$OUT/$v.log'"
  done
  gate_step table python3 $TM/gate_timing.py --table "$OUT/table.txt" $L/all-*.log $L/cut-*.log
  while IFS= read -r l; do note "$l"; done < "$GATE_DIR/table.log"
  gate_step analyze bash -c "mkdir -p '$OUT/an' && cp '$OUT/all.log' '$OUT/an/timemeas_run1.log' &&
    python3 -B '$DCTESTS/pvr-tests/timemeas/analyze.py' '$OUT/an' > '$OUT/analyze.txt' 2>&1; echo \"analyze.py exit \$?: \$(wc -l < '$OUT/analyze.txt') lines\""
  note "$(tail -1 "$GATE_DIR/analyze.log")"
  gate_step order-fit bash -c "python3 -B '$DCTESTS/pvr-tests/timemeas/order.py' --fit '$OUT/order.log' > '$OUT/order_fit.txt'"
  note "order.py --fit on the RTL's order run: $(tail -1 "$OUT/order_fit.txt")"
  gate_step races python3 $TM/races_check.py --run "$OUT/races"
  note "$(tail -1 "$GATE_DIR/races.log")"
  note "report: build/timing/report/ (table.txt, <variant>.log / .tsv, analyze.txt, order_fit.txt, races/)"
  gate_end
fi

# quick: the gate's scenes
sel=$(python3 $TM/tm_items.py "$SD/all.txt" --match '^(bgonly 0 0 0 0|wout [0-6] [18] 0 0|clip [0-4] 0 0 0|zk [0-9]+ 0 0 0)$' --split 1 | cut -f2)
run_item wout scenes 30 all "$SD/all.txt" "$sel"
sel=$(python3 $TM/tm_items.py "$SD/cut.txt" --match '^cut' --split 1 | cut -f2)
run_item cut scenes 15 cut "$SD/cut.txt" "$sel"
run_item order all 20 order - 'match:^order ' P2_TIMED_WRITES="$PAL"
gate_queue queue "$items"
gate_step checks python3 $TM/gate_timing.py --spec tb/timing/gate.txt --groups wout,cut "$L"/all-scenes.log "$L"/cut-scenes.log
while IFS= read -r l; do note "$l"; done < <(grep -v ': PASS$' "$GATE_DIR/checks.log" | grep -v '^timing: [0-9]')
note "$(grep '^timing: [0-9]' "$GATE_DIR/checks.log")"
gate_step order-clock bash -c "python3 $TM/tm_log.py '$L/order-all.log' > '$GATE_DIR/order_rtl.log' &&
  python3 -B '$DCTESTS/pvr-tests/timemeas/order.py' --fit '$GATE_DIR/order_rtl.log' > '$GATE_DIR/order_fit.txt' &&
  echo \"order: \$(grep -c '^O ' '$GATE_DIR/order_rtl.log') palette clock scenes, \$(grep -c '^R ' '$GATE_DIR/order_rtl.log') lines read back; order.py --fit: \$(tail -1 '$GATE_DIR/order_fit.txt')\""
note "$(tail -1 "$GATE_DIR/order-clock.log")"
gate_step races-lists python3 $TM/races_check.py
note "$(tail -1 "$GATE_DIR/races-lists.log")"
gate_step table python3 $TM/gate_timing.py --table "$GATE_DIR/table.txt" "$L"/all-scenes.log "$L"/cut-scenes.log
while IFS= read -r l; do note "$l"; done < <(tail -1 "$GATE_DIR/table.log")
gate_end

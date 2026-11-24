#!/bin/bash
# gate_wout.sh: the M12 write-out gate (PLAN M12 "make wout"), run by make wout / wout-mutants.
#
#   tools/gate/gate_wout.sh [--mutants]
#
#   quick (wout)   hw-pkg-check, check_ref_copies (the write-out's copies core-put, core-prev, core-writeout and core-endframe
#                  in tb/ref/ref_copies.h among them), check_ref_switches; the build (the L2 glue, build/obj_wout/tb); then on
#                  one queue (PLAN 0 rule 8): lint-wout; frames: WOUT_FRAMES (8000) random frames in 16 slices under
#                  --vramvary 7, and WOUT_FRAMES / 4 in 4 slices without it (tb/wout/wout_tb.cpp: every pack mode, dither,
#                  the clip, strips, scaler factors 0x400 / 0x401 / 0x800 / 0x6532 / 0x80 / 0 / random, Y_COEFF values, hscale,
#                  interlace / fieldselect, render to texture, unaligned bases; z_keep, no_writeout and empty entries through
#                  p2_tbuf_ctl; every word of video memory after every frame against RenderCORE's frame from its verbatim
#                  copies, the buffers and the swaps at the end)
#   --mutants      the build, then tools/gate/mutants.py on tb/wout/mutants.txt (rtl/v1/wout) and tb/wout/mutants_tbuf.txt
#                  (rtl/v1/tbuf): every one caught
#
# Ends with "<gate>: PASS" or "<gate>: FAIL"; build/gate/<gate>/summary.txt with the revision header, each step's line, the
# totals (frames, entries, write-outs, VRAM writes, the coverage of the modes) and the time line (lib.sh). Environment:
# WOUT_J (the queue's slots, P2_J), WOUT_FRAMES, WOUT_MUT_NJOBS (each mutant build's make -j, 4).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
case "$mode" in
  quick)     gate=wout ;;
  --mutants) gate=wout-mutants ;;
  *)         echo "usage: gate_wout.sh [--mutants]"; exit 2 ;;
esac
. "$HERE/lib.sh"
J=${WOUT_J:-$P2_J}
NF=${WOUT_FRAMES:-8000}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}
note() { GATE_LINES+=("    $1"); echo "    $1"; }

gate_begin "$gate"
gate_step hw-pkg-check       $MAKE -s hw-pkg-check
gate_step check_ref_copies   bash tools/check_ref_copies.sh
gate_step check_ref_switches bash tools/check_ref_switches.sh --no-hwpkg
gate_step build              $MAKE -s -j"$J" NJOBS="$J" refglue-build wout-build

if [ "$mode" = --mutants ]; then
  gate_mutants mutants      tb/wout/mutants.txt      --njobs "${WOUT_MUT_NJOBS:-4}"
  gate_mutants mutants-tbuf tb/wout/mutants_tbuf.txt --njobs "${WOUT_MUT_NJOBS:-4}"
  gate_end
fi

items=$GATE_DIR/items.txt
: > "$items"
gate_item "$items" lint-wout - 4 1 step lint-wout.log $MAKE -s lint-wout
for k in $(seq 0 15); do
  gate_item "$items" frames "$k/16" 30 1 tb "shards-vary/log_$k.txt" build/obj_wout/tb --n "$NF" --shard "$k/16" --vramvary 7
done
for k in $(seq 0 3); do
  gate_item "$items" frames-novary "$k/4" 30 1 tb "shards-novary/log_$k.txt" build/obj_wout/tb --seed 2 --n $((NF / 4)) \
    --shard "$k/4"
done
gate_queue queue "$items"

{
  for g in vary novary; do
    cat "$GATE_DIR"/shards-$g/log_*.txt 2>/dev/null | gawk -v g="$g" '
      function v(re,   m) { return match($0, re, m) ? m[1] : 0 }
      /^wout: [0-9]+ frames, [0-9]+ entries/ { fr += $2; en += v(", ([0-9]+) entries"); sw += v(", ([0-9]+) swaps")
        wo += v(", ([0-9]+) write-outs"); vw += v(", ([0-9]+) VRAM writes"); st += v(", ([0-9]+) secondary-port steals")
        clk += v("; ([0-9]+) clk") }
      /^wout: pack modes/ { for (i = 0; i < 7; i++) pm[i] += $(5 + i); f400 += v("factor 0x400 ([0-9]+)"); fs += v("a stream ([0-9]+)")
        f0 += v(", 0 ([0-9]+), hscale"); hs += v("hscale ([0-9]+)"); rt += v("texture ([0-9]+)"); sp += v("strips ([0-9]+)")
        cl += v("clip ([0-9]+)"); di += v("dither ([0-9]+)"); ua += v("unaligned ([0-9]+)") }
      /^wout: [0-9]+ checks, [0-9]+ failures/ { ck += $2; fa += $4 }
      END {
        printf "frames-%s: %d frames, %d entries, %d swaps, %d write-outs, %d VRAM writes, %d secondary-port steals, %d clk; %d checks, %d failures\n", g, fr, en, sw, wo, vw, st, clk, ck, fa
        printf "frames-%s: pack modes 0-6 %d %d %d %d %d %d %d; factor 0x400 %d, a stream %d, 0 %d; hscale %d, render to texture %d, strips %d, clip %d, dither %d, unaligned bases %d\n", g, pm[0], pm[1], pm[2], pm[3], pm[4], pm[5], pm[6], f400, fs, f0, hs, rt, sp, cl, di, ua }'
  done
} > "$GATE_DIR/tb.txt"
while IFS= read -r l; do note "$l"; done < "$GATE_DIR/tb.txt"
grep -qE ': [0-9]+ checks, [1-9][0-9]* failures' "$GATE_DIR/tb.txt" && { GATE_LINES+=("testbench: FAIL"); GATE_FAILED=1; }
grep -qE ': 0 frames' "$GATE_DIR/tb.txt" && { GATE_LINES+=("frames: none ran: FAIL"); GATE_FAILED=1; }
gate_end

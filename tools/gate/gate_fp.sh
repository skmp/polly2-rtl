#!/bin/bash
# gate_fp.sh: the M1 gates (PLAN M1; docs/spec/numerics.md 7), run by make fp-a / fp-a-full / fp-a-mutants, make fp-b /
# fp-b-full / fp-b-mutants, make fp-c / fp-c-full / fp-c-mutants and make fp / fp-full / fp-mutants (the whole M1).
#
#   tools/gate/gate_fp.sh <round> [--full | --mutants]     round: a (M1a), b (M1b), c (M1c), all (every round)
#
#   quick (gate fp-a, fp)            check_ref_copies, check_ref_switches, the round's testbenches built (make -j), then
#                                    on one queue (PLAN 0 rule 8) lint-fp and every testbench in quick mode, an item each
#                                    (seconds each; under a minute)
#   --full (fp-a-full, fp-full)      the same with every testbench's exhaustive sweeps (--full), each in FP_SHARDS
#                                    slices (--shard k/N), every slice of every testbench an item of the one queue,
#                                    longest first; a few minutes, under /tmp/polly2-rtl-gate.lock
#   --mutants (fp-a-mutants, ...)    tools/gate/mutants.py tb/fp/mutants.txt on the mutants whose probe is a testbench
#                                    of the round, and for M1b also tb/fp/mutants_zword.txt (the mutants of
#                                    rtl/v1/pkg/p2_zword_pkg.sv, which lives outside lib/fp), for M1c also
#                                    tb/fp/mutants_rom.txt (the measured-table ROMs in rtl/v1/lib/rom); builds and probe
#                                    runs on one queue of FP_J slots; under the lock
#   M1c and all (every mode) also run roms-check: the generated ROMs are what refcore gives (tb/mk/gen.mk)
#
# FP_SHARDS stays 12 by default: the testbenches' lockstep draws its idle clocks (gaps) from one generator per process,
# so the number of checks (every idle clock is one) depends on how the vectors are split; at 12 the counts are the ones
# M1 recorded. The slices of one testbench are the queue's longest items (fp-zword-full), so more slices would gain
# little.
#
# Ends with "<gate>: PASS" or "<gate>: FAIL" (exit code to match); build/gate/<gate>/summary.txt with the revision
# header, a line per testbench (its items, checks / failures, span, CPU, slowest item) and the time line (lib.sh).
# Environment: FP_J (the queue's slots, make -j of the build: P2_J: tools/gate/jobs.sh), FP_SHARDS (12), FP_MUT_NJOBS (each
# mutant build's make -j, 2).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)

# the testbenches of each round (tb/mk/fp.mk FP_A_PRIMS, FP_B_PRIMS, FP_C_PRIMS)
ROUND_a="lzc cut cutbelow in mul add recip cmp range"
ROUND_b="swamp halfline minor floor value zblock zword"
ROUND_c="div colour rom"

round=${1:-}
mode=${2:-quick}
case "$round" in
  a)   prims=$ROUND_a; gate=fp-a ;;
  b)   prims=$ROUND_b; gate=fp-b ;;
  c)   prims=$ROUND_c; gate=fp-c ;;
  all) prims="$ROUND_a $ROUND_b $ROUND_c"; gate=fp ;;
  *)   echo "usage: gate_fp.sh <a | b | c | all> [--full | --mutants]"; exit 2 ;;
esac
case "$mode" in
  quick)     ;;
  --full)    gate=$gate-full ;;
  --mutants) gate=$gate-mutants ;;
  *)         echo "usage: gate_fp.sh <a | b | c | all> [--full | --mutants]"; exit 2 ;;
esac

# the long ones run one at a time on the box (PLAN 0 rule 3)
if [ "$mode" != quick ] && [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock bash "$0" "$@"
fi

. "$HERE/lib.sh"
J=${FP_J:-$P2_J}
SHARDS=${FP_SHARDS:-12}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}

# a testbench step, with its "checks, failures" line kept in the summary
tb_step() {   # tb_step <step name> <command ...>
  local name=$1; shift
  gate_step "$name" "$@"
  local line
  line=$(grep -E ': [0-9]+ ((shards|items), [0-9]+ )?checks, [0-9]+ failures' "$GATE_DIR/$name.log" | tail -1)
  [ -n "$line" ] && GATE_LINES+=("    $line") && echo "    $line"
}

gate_begin "$gate"
gate_step check_ref_copies   bash tools/check_ref_copies.sh
gate_step check_ref_switches bash tools/check_ref_switches.sh
case "$round" in c|all) gate_step roms-check $MAKE -s roms-check ;; esac
if [ "$mode" = --mutants ]; then
  gate_mutants mutants tb/fp/mutants.txt --njobs "${FP_MUT_NJOBS:-2}" --probes "${prims// /,}"
  case "$round" in b|all) gate_mutants mutants-zword tb/fp/mutants_zword.txt --njobs "${FP_MUT_NJOBS:-2}" ;; esac
  case "$round" in c|all) gate_mutants mutants-rom tb/fp/mutants_rom.txt --njobs "${FP_MUT_NJOBS:-2}" ;; esac
else
  targets=""
  for p in $prims; do targets="$targets fp-$p-build"; done
  gate_step build   $MAKE -s -j"$J" NJOBS=2 $targets
  items=$GATE_DIR/items.txt
  : > "$items"
  gate_item "$items" lint-fp - 10 8 step lint-fp.log $MAKE -s lint-fp LINT_J=8
  for p in $prims; do
    if [ "$mode" = --full ]; then
      for k in $(seq 0 $((SHARDS - 1))); do
        gate_item "$items" "fp-$p-full" "$k/$SHARDS" 60 1 tb "fp-$p-full/log_$k.txt" build/obj_fp/$p/tb --full --shard "$k/$SHARDS"
      done
    else
      gate_item "$items" "fp-$p" - 1 1 tb "fp-$p.log" build/obj_fp/$p/tb
    fi
  done
  gate_queue tests "$items"
  # each testbench's checks / failures line (the slices' summed for --full), as the M1 summaries had them
  for p in $prims; do
    if [ "$mode" = --full ]; then
      l=$(shard_report "fp-$p-full" "fp-$p-full" "$SHARDS" | grep 'shards, ')
    else
      l=$(grep -E ': [0-9]+ checks, [0-9]+ failures$' "$GATE_DIR/fp-$p.log" | tail -1)
    fi
    [ -n "$l" ] && GATE_LINES+=("    $l") && echo "    $l"
  done
fi
gate_end

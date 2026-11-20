#!/bin/bash
# gate_fp.sh: the M1 gates (PLAN M1; docs/spec/numerics.md 7), run by make fp-a / fp-a-full / fp-a-mutants, make fp-b /
# fp-b-full / fp-b-mutants and make fp / fp-full / fp-mutants.
#
#   tools/gate/gate_fp.sh <round> [--full | --mutants]     round: a (M1a), b (M1b), all (every round so far)
#
#   quick (gate fp-a, fp)            check_ref_copies, check_ref_switches, the round's testbenches built (make -j), lint-fp,
#                                    then every testbench in quick mode, one step each (seconds each; under a minute)
#   --full (fp-a-full, fp-full)      the same with every testbench's exhaustive sweeps (--full), each sharded FP_SHARDS
#                                    ways by tools/gate/run_shards.sh; a few minutes, under /tmp/polly2-rtl-gate.lock
#   --mutants (fp-a-mutants, ...)    tools/gate/mutants.py tb/fp/mutants.txt on the mutants whose probe is a testbench
#                                    of the round, and for M1b also tb/fp/mutants_zword.txt (the mutants of
#                                    rtl/v1/pkg/p2_zword_pkg.sv, which lives outside lib/fp); under the lock
#
# Ends with "<gate>: PASS" or "<gate>: FAIL" (exit code to match); build/gate/<gate>/summary.txt with the revision
# header and, under each testbench's step, its checks / failures line. Environment: FP_J (make -j, 12), FP_SHARDS (12),
# FP_MUT_JOBS (parallel mutant builds, 6).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)

# the testbenches of each round (tb/mk/fp.mk FP_A_PRIMS, FP_B_PRIMS)
ROUND_a="lzc cut cutbelow in mul add recip cmp range"
ROUND_b="swamp halfline minor floor value zblock zword"

round=${1:-}
mode=${2:-quick}
case "$round" in
  a)   prims=$ROUND_a; gate=fp-a ;;
  b)   prims=$ROUND_b; gate=fp-b ;;
  all) prims="$ROUND_a $ROUND_b"; gate=fp ;;
  *)   echo "usage: gate_fp.sh <a | b | all> [--full | --mutants]"; exit 2 ;;
esac
case "$mode" in
  quick)     ;;
  --full)    gate=$gate-full ;;
  --mutants) gate=$gate-mutants ;;
  *)         echo "usage: gate_fp.sh <a | b | all> [--full | --mutants]"; exit 2 ;;
esac

# the long ones run one at a time on the box (PLAN 0 rule 3)
if [ "$mode" != quick ] && [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock bash "$0" "$@"
fi

. "$HERE/lib.sh"
J=${FP_J:-12}
SHARDS=${FP_SHARDS:-12}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}

# a testbench step, with its "checks, failures" line kept in the summary
tb_step() {   # tb_step <step name> <command ...>
  local name=$1; shift
  gate_step "$name" "$@"
  local line
  line=$(grep -E ': [0-9]+ (shards, [0-9]+ )?checks, [0-9]+ failures' "$GATE_DIR/$name.log" | tail -1)
  [ -n "$line" ] && GATE_LINES+=("    $line") && echo "    $line"
}

gate_begin "$gate"
gate_step check_ref_copies   bash tools/check_ref_copies.sh
gate_step check_ref_switches bash tools/check_ref_switches.sh
if [ "$mode" = --mutants ]; then
  tb_step mutants python3 tools/gate/mutants.py tb/fp/mutants.txt --jobs "${FP_MUT_JOBS:-6}" --probes "${prims// /,}"
  grep -E 'caught|SURVIVED|ERROR|control' "$GATE_DIR/mutants.log" | sed 's/^/    /'
  while IFS= read -r l; do GATE_LINES+=("    $l"); done < <(grep -E ' (caught|SURVIVED|ERROR)' "$GATE_DIR/mutants.log")
  if [ "$round" != a ]; then
    tb_step mutants-zword python3 tools/gate/mutants.py tb/fp/mutants_zword.txt --jobs "${FP_MUT_JOBS:-6}"
    grep -E 'caught|SURVIVED|ERROR|control' "$GATE_DIR/mutants-zword.log" | sed 's/^/    /'
    while IFS= read -r l; do GATE_LINES+=("    $l"); done < <(grep -E ' (caught|SURVIVED|ERROR)' "$GATE_DIR/mutants-zword.log")
  fi
else
  targets=""
  for p in $prims; do targets="$targets fp-$p-build"; done
  gate_step build   $MAKE -s -j"$J" NJOBS=2 $targets
  gate_step lint-fp $MAKE -s lint-fp
  for p in $prims; do
    if [ "$mode" = --full ]; then
      tb_step "fp-$p-full" bash tools/gate/run_shards.sh "fp-$p-full" "$SHARDS" "$GATE_DIR/fp-$p-full" \
        build/obj_fp/$p/tb --full
    else
      tb_step "fp-$p" build/obj_fp/$p/tb
    fi
  done
fi
gate_end

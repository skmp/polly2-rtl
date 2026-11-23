#!/bin/bash
# gate_tsp_setup.sh: the M9 gate (PLAN M9), run by make tsp-setup / tsp-setup-mutants.
#
#   tools/gate/gate_tsp_setup.sh [--mutants]
#
#   quick (tsp-setup)   hw-pkg-check; tsp-prog-check (rtl/v1/pkg/p2_tsp_prog_pkg.sv is the generator's output, the
#                       testbench's copy of the schedule build/gen/p2_tsp_prog.h from the same run); check_ref_copies (every
#                       copy, MipSelect's K part tb/tsp_setup/ref_copies_tsp.h among them), check_ref_switches; the schedule
#                       (the lengths against the measured 39 / 48 / 64 / 48 / +5, reported: PLAN 0 rule 6) and the sweep;
#                       the builds (the L2 glue, the generator, the testbench); then on one queue (PLAN 0 rule 8):
#                         lint-tsp-setup;
#                         gate item 1  the graph check: every class's graph and its store-write logic, evaluated with
#                                      pvr_softfp, against PlaneT::Setup and the K copies on 1M random jobs, the
#                                      dropped-offset class A3, the named cases and every console set's triangles
#                                      (gen_tsp_prog --check);
#                         items 2-7    the testbench (build/obj_tsp_setup/tb): every live store word of every run's
#                                      entries against p2ref::fpu_entry and the K copies, the SRQ, the volumes, the class
#                                      and the program length of every job: `named` (item 3), `a3` (item 4, in full),
#                                      `console` (item 5: cmeas c1 / cwext1 / cwsum1, mipk, mipk2, mipk3, mipk5 with the
#                                      console's K8, the 10 mipmeas sets), `random` (item 6: 1M primitives); mipmapped
#                                      Sdet 0 counted (item 7; compared: refsw3 defines it since 2bee80f2), each in
#                                      slices (--shard over batches)
#   --mutants           tools/gate/mutants.py on tb/tsp_setup/mutants.txt (rtl/v1/tsp), mutants_fp.txt (rtl/v1/lib/fp: the
#                       zero rule's reach) and mutants_gen.txt (the generator's graphs), every one caught
#
# Ends with "<gate>: PASS" or "<gate>: FAIL"; build/gate/<gate>/summary.txt with the revision header, the inputs, each
# step's checks / failures and the clocks (reported, not gated), and the time line (lib.sh). Environment: TSP_SETUP_J (the
# queue's slots and make -j: P2_J), TSP_SETUP_RANDOM (the random primitives, 1M), TSP_SETUP_SLICES (the random
# section's slices, 32), TSP_SETUP_MUT_NJOBS (each mutant build's make -j, 4).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
case "$mode" in
  quick)     gate=tsp-setup ;;
  --mutants) gate=tsp-setup-mutants ;;
  *)         echo "usage: gate_tsp_setup.sh [--mutants]"; exit 2 ;;
esac

. "$HERE/lib.sh"
J=${TSP_SETUP_J:-$P2_J}
NRAND=${TSP_SETUP_RANDOM:-1000000}
SLICES=${TSP_SETUP_SLICES:-32}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}

note() { GATE_LINES+=("    $1"); echo "    $1"; }

gate_begin "$gate"
gate_step hw-pkg-check       $MAKE -s hw-pkg-check
gate_step tsp-prog-check     $MAKE -s tsp-prog-check
gate_step check_ref_copies   bash tools/check_ref_copies.sh
gate_step check_ref_switches bash tools/check_ref_switches.sh --no-hwpkg
if [ "$mode" = --mutants ]; then
  gate_step build $MAKE -s -j"$J" NJOBS="$J" refglue-build tsp-setup-build tsp-setup-graph-bin
  gate_mutants mutants     tb/tsp_setup/mutants.txt     --njobs "${TSP_SETUP_MUT_NJOBS:-4}"
  gate_mutants mutants-fp  tb/tsp_setup/mutants_fp.txt  --njobs "${TSP_SETUP_MUT_NJOBS:-4}"
  gate_mutants mutants-gen tb/tsp_setup/mutants_gen.txt --njobs "${TSP_SETUP_MUT_NJOBS:-4}"
  gate_end
fi

# the schedule: the scheduler's lengths at ARCHITECTURE 6's parameters; the measured lengths are a check (MT4)
note "schedule: $(grep -m1 '^TSP setup microprograms' build/gen/p2_tsp_prog.txt)"
while IFS= read -r l; do note "schedule: $l"; done < <(grep -E '^[A-Z0-9_]+: [0-9]+ multiplies' build/gen/p2_tsp_prog.txt)
gate_step tsp-prog-sweep $MAKE -s tsp-prog-sweep
note "sweep (measured 39 / 48 / 64 / 48 / +5; the nearest sets): $(sed -n '3,4p' "$GATE_DIR/tsp-prog-sweep.log" | tr -s ' ' | paste -sd ';')"
gate_step build $MAKE -s -j"$J" NJOBS="$J" refglue-build tsp-setup-build tsp-setup-graph-bin

items=$GATE_DIR/items.txt
: > "$items"
gate_item "$items" lint-tsp-setup - 4 1 step lint-tsp-setup.log $MAKE -s lint-tsp-setup
gate_item "$items" graph-check - 8 8 step graph-check.log $MAKE -s tsp-setup-graph TSP_GRAPH_THREADS=8
for k in 0 1; do gate_item "$items" named "$k/2" 1 1 tb "shards-named/log_$k.txt" build/obj_tsp_setup/tb --only named --shard "$k/2"; done
for k in 0 1 2 3; do gate_item "$items" a3 "$k/4" 1 1 tb "shards-a3/log_$k.txt" build/obj_tsp_setup/tb --only a3 --shard "$k/4"; done
for k in $(seq 0 7); do gate_item "$items" console "$k/8" 2 1 tb "shards-console/log_$k.txt" build/obj_tsp_setup/tb --only console --shard "$k/8"; done
for k in $(seq 0 $((SLICES - 1))); do
  gate_item "$items" random "$k/$SLICES" 5 1 tb "shards-random/log_$k.txt" build/obj_tsp_setup/tb --only random --n "$NRAND" --shard "$k/$SLICES"
done
gate_queue queue "$items"

while IFS= read -r l; do note "$l"; done < <(grep -E '^graph-check: ' "$GATE_DIR/graph-check.log" | grep -v ': PASS$\|: FAIL$')
# the testbench's lines, summed over the slices of each section
for s in named a3 console random; do
  cat "$GATE_DIR"/shards-$s/log_*.txt 2>/dev/null | gawk -v s="$s" '
    function g(re,   m) { return match($0, re, m) ? m[1] : 0 }
    /^tsp_setup: [0-9]+ batches, / { b += g("([0-9]+) batches"); c += g(" ([0-9]+) cases"); r += g(" ([0-9]+) runs"); nl += g("\\(([0-9]+) null\\)")
      j += g(" ([0-9]+) setup jobs"); h += g(" ([0-9]+) store hits"); w += g(" ([0-9]+) words read"); k += g(" ([0-9]+) K checked")
      dz += g(" ([0-9]+) of them mipmapped with Sdet 0"); sk += g("but ([0-9]+) \\(blocks") }
    /^tsp_setup: [0-9]+ checks, [0-9]+ failures/ { ck += $2; fl += $4 }
    /^tsp_setup: clocks / { clk += g("clocks ([0-9]+)"); bz += g("setup busy ([0-9.]+) %") * g("clocks ([0-9]+)") / 100
      p = g("at most ([0-9]+) entries pinned"); if (p + 0 > pm) pm = p + 0; jc += g("last store write ([0-9.]+)\\)") * 0 }
    /^tsp_setup: jobs a class:/ { for (i = 5; i < NF; i += 2) cls[$i] += $(i + 1); order = $0 }
    END {
      printf "%s: %d checks, %d failures; %d batches, %d cases, %d runs (%d null), %d setup jobs, %d store hits, %d words read, %d K (%d mipmapped with Sdet 0), the class checked on all header reads but %d (overlapping vertices)\n", s, ck, fl, b, c, r, nl, j, h, w, k, dz, sk
      out = ""; n = split(order, f, " "); for (i = 5; i < n; i += 2) out = out " " f[i] " " cls[f[i]]
      printf "%s: jobs a class:%s; %d clocks, %.2f a job, setup busy %.1f %%, at most %d entries pinned\n", s, out, clk, j ? clk / j : 0, clk ? 100 * bz / clk : 0, pm }'
  # the console's K: the per-set lines summed over the slices
  cat "$GATE_DIR"/shards-$s/log_*.txt 2>/dev/null | gawk '
    /^tsp_setup: the console.s K, / { n = split($0, f, " "); key = $5; sub(/:$/, "", key); c[key] += $6; r[key] += $15; q[key] += $18 }
    END { for (k in c) printf "console K %s: %d cells observed, the RTL K8 the console'"'"'s on %d, refsw3'"'"'s on %d (where refsw3 is not, the RTL is refsw3)\n", k, c[k], r[k], q[k] }' | sort
done > "$GATE_DIR/tb.txt"
while IFS= read -r l; do note "$l"; done < "$GATE_DIR/tb.txt"
grep -q 'failures' "$GATE_DIR/tb.txt" && ! grep -qE ': [0-9]+ checks, [1-9][0-9]* failures' "$GATE_DIR/tb.txt" || {
  GATE_LINES+=("testbench: FAIL (a section has failures)"); GATE_FAILED=1; }
gate_end

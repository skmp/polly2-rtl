#!/bin/bash
# gate_tsp_run.sh: the M10 gate (PLAN M10), run by make tsp-run / tsp-run-mutants / tsp-run-full.
#
#   tools/gate/gate_tsp_run.sh [--mutants | --full]
#
#   quick (tsp-run)     hw-pkg-check; check_ref_copies (every copy, mipChoose's tb/tsp_run/ref_copies_run.h among them),
#                       check_ref_switches; the builds (the L2 glue, the testbench); then on one queue (PLAN 0 rule 8):
#                         lint-tsp-run;
#                         random   2M random pixels (TSP_RUN_RANDOM) in TSP_RUN_SLICES slices: every point's W, values,
#                                  quotients, colours, MipSelect's and mipChoose's level and k against refsw3;
#                         super    500,000 pixels of SupSample primitives (num H7b's half lines), 8 slices;
#                         console  every archived console set of dreamcast-tests (tb/tsp_run/tsp_sets.h), every reading
#                                  equal to the console's wherever refsw3's is: uvspan (4), uvrun (1), wmeas (4), cmeas (3),
#                                  mipmeas (10) every reading; the 36 uvmeas sets every 8th run (TSP_RUN_UV_STRIDE; every
#                                  reading in tsp-run-full); a set an item, the large ones in slices
#   --full              the same with every uvmeas reading (24.7M); with SAMPLE=<seed> (make tsp-run-full SAMPLE=<seed>,
#                       PLAN 0 rule 10) through tools/gate/sample_items.py: every item is this milestone's own (--whole),
#                       so the sample is the whole gate; the seed and the coverage are in the summary
#   --mutants           tools/gate/mutants.py on tb/tsp_run/mutants.txt (rtl/v1/tsp) and mutants_fp.txt (rtl/v1/lib/fp),
#                       every one caught
#
# Ends with "<gate>: PASS" or "<gate>: FAIL"; build/gate/<gate>/summary.txt with the revision header, each section's
# checks / failures, every set's readings (the RTL the console's, refsw3 the console's), the clocks (reported, not gated:
# PLAN 0 rule 6, MT5 / MT6) and the time line (lib.sh). Environment: TSP_RUN_J (the queue's slots and make -j: P2_J),
# TSP_RUN_RANDOM, TSP_RUN_SLICES (16), TSP_RUN_UV_STRIDE (8), TSP_RUN_MUT_NJOBS (each mutant build's make -j, 4).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
SAMPLE=${SAMPLE:-}
case "$mode" in
  quick)     gate=tsp-run ;;
  --full)    gate=tsp-run-full ;;
  --mutants) gate=tsp-run-mutants ;;
  *)         echo "usage: gate_tsp_run.sh [--mutants | --full]"; exit 2 ;;
esac
if [ "$mode" = --full ] && [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock env SAMPLE="$SAMPLE" bash "$0" "$@"
fi

. "$HERE/lib.sh"
J=${TSP_RUN_J:-$P2_J}
NRAND=${TSP_RUN_RANDOM:-2000000}
SLICES=${TSP_RUN_SLICES:-16}
UVSTRIDE=${TSP_RUN_UV_STRIDE:-8}
[ "$mode" = --full ] && UVSTRIDE=1
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}

note() { GATE_LINES+=("    $1"); echo "    $1"; }

gate_begin "$gate"
gate_step hw-pkg-check       $MAKE -s hw-pkg-check
gate_step check_ref_copies   bash tools/check_ref_copies.sh
gate_step check_ref_switches bash tools/check_ref_switches.sh --no-hwpkg
gate_step build $MAKE -s -j"$J" NJOBS="$J" refglue-build tsp-run-build
if [ "$mode" = --mutants ]; then
  gate_mutants mutants    tb/tsp_run/mutants.txt    --njobs "${TSP_RUN_MUT_NJOBS:-4}"
  gate_mutants mutants-fp tb/tsp_run/mutants_fp.txt --njobs "${TSP_RUN_MUT_NJOBS:-4}"
  gate_end
fi
[ "$mode" = --full ] && [ -n "$SAMPLE" ] && note "sample: seed $SAMPLE (every item of tsp-run-full is M10's own: --whole)"

items=$GATE_DIR/items.txt
: > "$items"
gate_item "$items" lint-tsp-run - 4 1 step lint-tsp-run.log $MAKE -s lint-tsp-run
for k in $(seq 0 $((SLICES - 1))); do
  gate_item "$items" random "$k/$SLICES" 3 1 tb "shards-random/log_$k.txt" build/obj_tsp_run/tb --only random --n "$NRAND" --shard "$k/$SLICES"
done
for k in $(seq 0 7); do
  gate_item "$items" super "$k/8" 2 1 tb "shards-super/log_$k.txt" build/obj_tsp_run/tb --only super --shard "$k/8"
done
# run start's pitch, reported (not gated: MT5's T7; the values of its points are compared all the same)
gate_item "$items" pitch - 1 1 tb "shards-pitch/log_0.txt" build/obj_tsp_run/tb --only pitch
# the console sets: a set an item, in N slices (--shard over its units of ~3000 runs); estimates in seconds
console() {   # console <family> <set> <slices> <estimate> [args]
  local fam=$1 s=$2 n=$3 est=$4; shift 4
  for k in $(seq 0 $((n - 1))); do
    gate_item "$items" "console-$fam" "$s/$k/$n" "$est" 1 tb "shards-console/log_${fam}_${s}_$k.txt" \
      build/obj_tsp_run/tb --only console --set "$fam/$s" --shard "$k/$n" "$@"
  done
}
for s in dump_gundam1 dump_jgr2a dump_rayman1 dump_rayman2 reach1 uflat2 ugen5 urecip6 urfull_0 urfull_1 urfull_10 urfull_11 \
         urfull_12 urfull_13 urfull_2 urfull_3 urfull_4 urfull_5 urfull_6 urfull_7 urfull_8 urfull_9 urrow9 urrown10 urscan7 \
         urscan8 usteep3 uv1 uwflat4 wexp1 whuge1 wneg1 wspec1 wtiny1 wzero1 wzero2; do
  if [ "$UVSTRIDE" = 1 ]; then console uvmeas "$s" 4 2; else console uvmeas "$s" 1 1 --stride "$UVSTRIDE"; fi
done
for s in cspan31 cspan32tr span1 span2tr; do console uvspan "$s" 2 1; done
console uvrun run2 4 2
for s in flat2 scan3 slopes4 w1; do console wmeas "$s" 2 2; done
for s in c1 cwext1 cwsum1; do console cmeas "$s" 2 2; done
for s in d0dcalc d0first dcalc5 det3 det4 first1 mpos1 mwext1 mwextd1 w2; do console mipmeas "$s" 2 2; done

qopt=()
if [ "$mode" = --full ] && [ -n "$SAMPLE" ]; then
  mv "$items" "$GATE_DIR/items_all.txt"
  wholeg=$(cut -f1 "$GATE_DIR/items_all.txt" | sort -u | paste -sd,)
  gate_step sample python3 tools/gate/sample_items.py --seed "$SAMPLE" --gate tsp-run-full --budget "${SAMPLE_BUDGET:-900}" \
    --jobs "$J" --cost "$GATE_DIR/cost.txt" --always tools/gate/always_run.txt --whole "$wholeg" \
    "$GATE_DIR/items_all.txt" "$items"
  while IFS= read -r l; do note "$l"; done < <(grep '^sample: ' "$GATE_DIR/sample.log")
  cp "$GATE_DIR/cost.txt" "$GATE_DIR/cost_before.txt" 2>/dev/null || : > "$GATE_DIR/cost_before.txt"
  qopt=(--optional "$items.optional" --deadline "${SAMPLE_BUDGET:-900}")
fi
gate_queue queue "$items" "${qopt[@]}"
if [ "$mode" = --full ] && [ -n "$SAMPLE" ]; then
  python3 tools/gate/sample_items.py --coverage "$GATE_DIR/pq_results.tsv" --cost "$GATE_DIR/cost_before.txt" \
    "$GATE_DIR/items_all.txt" "$items" > "$GATE_DIR/coverage.log"
  while IFS= read -r l; do note "$l"; done < "$GATE_DIR/coverage.log"
fi

# the testbench's lines, summed over the slices of each section
summ() {   # summ <section> <logs ...>
  local sect=$1; shift
  cat "$@" 2>/dev/null | gawk -v s="$sect" '
    function g(re,   m) { return match($0, re, m) ? m[1] : 0 }
    /^tsp_run: [0-9]+ jobs, / { jb += g("([0-9]+) jobs"); it += g(" ([0-9]+) items"); nl += g("\\(([0-9]+) null\\)")
      px += g(" ([0-9]+) pixels,"); pt += g(" ([0-9]+) points"); sp += g("\\(([0-9]+) SupSample\\)"); vc += g(" ([0-9]+) value checks")
      mp += g(" ([0-9]+) points mipmapped"); of += g(" ([0-9]+) with the offset planes") }
    /^tsp_run: [0-9]+ checks, [0-9]+ failures/ { ck += $2; fl += $4 }
    /^tsp_run: clocks / { clk += g("clocks ([0-9]+)"); rb += g("run start busy ([0-9.]+) %") * g("clocks ([0-9]+)") / 100
      rr += g("row reads ([0-9]+)"); rm += g("product clocks ([0-9]+)"); p0 += g("P0 issuing ([0-9.]+) %") * g("clocks ([0-9]+)") / 100
      dr += g("the pass drain ([0-9]+) clk"); st += g("P3 stalled ([0-9]+) clk")
      q = g("at most ([0-9]+) runs"); if (q + 0 > qr) qr = q + 0; q = g("runs / ([0-9]+) pixels"); if (q + 0 > qp) qp = q + 0
      q = g("at most ([0-9]+) entries pinned"); if (q + 0 > pm) pm = q + 0 }
    END {
      printf "%s: %d checks, %d failures; %d jobs, %d items (%d null), %d pixels, %d points (%d SupSample), %d value checks, %d points mipmapped, %d with the offset planes\n", s, ck, fl, jb, it, nl, px, pt, sp, vc, mp, of
      printf "%s: clocks %d (reported, not gated: MT5 / MT6): %.3f a pixel, %.3f a point; run start busy %.1f %% (row reads %d, product clocks %d), P0 issuing %.1f %%, pass drain %d clk, P3 stalled (the testbench) %d clk; pixel queue at most %d runs / %d pixels, at most %d entries pinned\n", s, clk, px ? clk / px : 0, pt ? clk / pt : 0, clk ? 100 * rb / clk : 0, rr, rm, clk ? 100 * p0 / clk : 0, dr, st, qr, qp, pm }'
}
{
  summ random "$GATE_DIR"/shards-random/log_*.txt
  summ super "$GATE_DIR"/shards-super/log_*.txt
  # SupSample's half lines by num H7b's classes (coverage), over the random and super slices
  cat "$GATE_DIR"/shards-random/log_*.txt "$GATE_DIR"/shards-super/log_*.txt 2>/dev/null | gawk '
    function g(re,   m) { return match($0, re, m) ? m[1] : 0 }
    /^tsp_run: SupSample half lines/ { n += g(" ([0-9]+) planes"); c += g(" ([0-9]+) where the fractions carry"); w += g(" ([0-9]+) beyond")
      t += g(" ([0-9]+) with the 62-bit"); ng += g(" ([0-9]+) with C"); nc += g("\\(([0-9]+) of them carrying") }
    END { printf "SupSample half lines (num H7b classes, at runs'"'"' starts, random + super): %d planes, %d where the fractions carry (hyd = F(B'"'"'/2) + 1), %d beyond the 90 window, %d with the 62-bit truncation, %d with C'"'"' < 0 (%d of them carrying)\n", n, c, w, t, ng, nc }'
  summ console "$GATE_DIR"/shards-console/log_*.txt
  # every set's readings, summed over its slices
  cat "$GATE_DIR"/shards-console/log_*.txt 2>/dev/null | gawk '
    /^tsp_run: console / { k = $3 " " $4; sub(/:$/, "", k); r[k] += $5; c[k] += $12 + 0; q[k] += $15 + 0 }
    END { for (k in r) { fam = k; sub(/ .*/, "", fam); R[fam] += r[k]; C[fam] += c[k]; Q[fam] += q[k]; N[fam]++
            printf "console %s: %d readings, the RTL the console'"'"'s on %d, refsw3 on %d\n", k, r[k], c[k], q[k] }
          for (f in R) printf "console family %s (%d sets): %d readings, the RTL the console'"'"'s on %d, refsw3 the console'"'"'s on %d\n", f, N[f], R[f], C[f], Q[f] }' | sort
  sed -n 's/^tsp_run: pitch \(.*\)$/run start pitch (reported; measured 3.9 \/ 4.2 \/ 6.3 within one triangle, ~4.7 \/ 6 \/ 8 across: tim 3.8): \1/p' \
    "$GATE_DIR"/shards-pitch/log_0.txt 2>/dev/null
} > "$GATE_DIR/tb.txt"
while IFS= read -r l; do note "$l"; done < <(grep -v '^console [a-z]* [a-z0-9_]*:' "$GATE_DIR/tb.txt")
grep '^console [a-z]* [a-z0-9_]*:' "$GATE_DIR/tb.txt" > "$GATE_DIR/sets.txt"
note "every set's line: build/gate/$gate/sets.txt ($(wc -l < "$GATE_DIR/sets.txt") sets)"
# a set whose RTL readings are not all the console's where refsw3's are fails in the testbench; here: every set ran
nsets=$(wc -l < "$GATE_DIR/sets.txt")
[ "$nsets" = 58 ] || { GATE_LINES+=("console: $nsets sets reported, 58 expected: FAIL"); GATE_FAILED=1; }
grep -qE ': [0-9]+ checks, [1-9][0-9]* failures' "$GATE_DIR/tb.txt" && { GATE_LINES+=("testbench: FAIL (a section has failures)"); GATE_FAILED=1; }
grep -q '^tsp_run: PASS' "$GATE_DIR"/shards-pitch/log_0.txt 2>/dev/null || { GATE_LINES+=("pitch: FAIL (its points)"); GATE_FAILED=1; }
# the RTL is the console's wherever refsw3 is (PLAN 0 rule 4; each reading checked so in the testbench), and every set ran
awk '/^console [a-z]* [a-z0-9_]*:/ && ($11 + 0 < $14 + 0 || $4 + 0 == 0) { bad = 1 } END { exit bad }' "$GATE_DIR/sets.txt" ||
  { GATE_LINES+=("console: a set's RTL readings are not the console's where refsw3's are, or a set had none: FAIL"); GATE_FAILED=1; }
gate_end

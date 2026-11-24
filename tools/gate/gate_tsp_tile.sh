#!/bin/bash
# gate_tsp_tile.sh: the M11 gate (PLAN M11, 1.3 "TSP tile testbench"), run by make tsp-tile / tsp-tile-full /
# tsp-tile-mutants.
#
#   tools/gate/gate_tsp_tile.sh [--full | --mutants]
#
#   quick (tsp-tile)   hw-pkg-check, check_ref_copies (M11's copies tb/tsp_tile/ref_copies_tile.h among them),
#                      check_ref_switches; the builds (refsw3-offline, the L2 glue, scenegen, the two testbenches); the
#                      captures of the inputs (tools/gate/capture_prerender.sh --max 8): the tile subset (tb/tile/
#                      subset_tests.txt, subset_dumps.txt, subset_seeds.txt) and M11's console tests (tb/tsp_tile/
#                      subset_tsp_tile.txt); then on one queue (PLAN 0 rule 8):
#                        lint-tsp-tile;
#                        unit-tex     2M random texture points (TSP_TILE_TEX) in 16 slices: p2_tex_coord .. p2_tex_filter
#                                     against p2ref::texture_filter;
#                        unit-shade   1M random pixels (TSP_TILE_SHADE) in 16 slices: p2_pp_shade, p2_pp_fog, p2_pp_ss,
#                                     p2_pp_blend with p2_tbuf against the copies of bumpLight / shade / fade / the
#                                     SupSample average and p2ref::combiner / bump / fog / blend;
#                        tile         every capture, a work item per case (tools/gate/tile_items.py), --vramvary 7: every
#                                     pixel's tile-buffer write, every feedback message, both buffers after every pass,
#                                     tspAlphaStuck and offsKept at every pass end, every word at every render's end
#   --full             the same on the full set (every fit/hw test, its first 256 renders; every dump; seeds 1-5000), a
#                      case cut into runs of renders where its cost asks (--renders A-B; tile_items.py --split render);
#                      with SAMPLE=<seed> (make tsp-tile-full SAMPLE=<seed>, PLAN 0 rule 10) a seeded sample through
#                      tools/gate/sample_items.py: the unit sections and lint in full (--whole), every case at least once
#                      (one of its items, at random: --every tile), a random subset of the rest within SAMPLE_BUDGET (1800)
#                      s, the always-run
#                      items (tools/gate/always_run.txt); the seed and the coverage in the summary. Under
#                      /tmp/polly2-rtl-gate.lock
#   --mutants          the builds, the captures the probes use, tools/gate/mutants.py on tb/tsp_tile/mutants.txt (rtl/v1/tsp),
#                      mutants_tex.txt (rtl/v1/tex) and mutants_tbuf.txt (rtl/v1/tbuf): every one caught (the timing ones,
#                      written !<probe>, passing)
#
# Ends with "<gate>: PASS" or "<gate>: FAIL"; build/gate/<gate>/summary.txt with the revision header, each step's line,
# the totals (renders, entries, passes, pixels, writes, feedback; the VRAM-race renders in their own class), the clocks
# (reported, not gated: PLAN 0 rule 6, MT5 / MT6 / T8) and the time line (lib.sh). Environment: TSP_TILE_J (the queue's
# slots, P2_J), TSP_TILE_TEX, TSP_TILE_SHADE, TSP_TILE_MUT_NJOBS (each mutant build's make -j, 4).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-quick}
SAMPLE=${SAMPLE:-}
case "$mode" in
  quick)     gate=tsp-tile ;;
  --full)    gate=tsp-tile-full ;;
  --mutants) gate=tsp-tile-mutants ;;
  *)         echo "usage: gate_tsp_tile.sh [--full | --mutants]"; exit 2 ;;
esac
if [ "$mode" = --full ] && [ -z "${P2_GATE_LOCKED:-}" ]; then
  export P2_GATE_LOCKED=1
  exec flock /tmp/polly2-rtl-gate.lock env SAMPLE="$SAMPLE" bash "$0" "$@"
fi

. "$HERE/lib.sh"
J=${TSP_TILE_J:-$P2_J}
NTEX=${TSP_TILE_TEX:-2000000}
NSHADE=${TSP_TILE_SHADE:-1000000}
export P2_REFREV=${P2_REFREV:-$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null)}
export POLLY2_DUMPS=${POLLY2_DUMPS:-$P2_ROOT/../dreamster/polly2-rtl/polly2-data/dumps}

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
gate_step build              $MAKE -s -j"$J" NJOBS="$J" refsw3-offline refglue-build scenegen tsp-tile-build tsp-unit-build

# ---- the inputs
if [ "$mode" = --full ]; then
  tests=$(ls "$DCTESTS/fit/hw" | grep -v '_races$' | grep -v '[+@]')
  dumps=$( (ls "$POLLY2_DUMPS"/*.pvrdmp | xargs -n 1 basename | sed 's/\.pvrdmp$//';
            ls "$POLLY2_DUMPS"/vram_*.bin | xargs -n 1 basename | sed 's/^vram_//; s/\.bin$//' | grep -v '^out_') | sort -u)
  seeds=$(seq 1 5000)
  maxr=256
elif [ "$mode" = --mutants ]; then
  tests=$(sed 's/#.*//' tb/tsp_tile/mutant_cases.txt | awk 'NF { print $1 }' | sed -n 's:^build/pre/\([^/]*\)$:\1:p' |
          grep -v '^dump_\|^gen_' | sort -u)
  dumps=$(sed 's/#.*//' tb/tsp_tile/mutant_cases.txt | awk 'NF { print $1 }' | sed -n 's:^build/pre/dump_\(.*\)$:\1:p')
  seeds=$(sed 's/#.*//' tb/tsp_tile/mutant_cases.txt | awk 'NF { print $1 }' | sed -n 's:^build/pre/gen_\(.*\)$:\1:p')
  maxr=8
else
  tests=$( (cases_of tb/tile/subset_tests.txt; cases_of tb/tsp_tile/subset_tsp_tile.txt) | sort -u)
  dumps=$(cases_of tb/tile/subset_dumps.txt | sort -u)
  seeds=$(cases_of tb/tile/subset_seeds.txt)
  maxr=8
fi
caps=$( (for t in $tests; do echo "$t"; done; for d in $dumps; do echo "dump:$d"; done; for s in $seeds; do echo "gen:$s"; done) )
captures() {
  bash tools/gate/capture_prerender.sh -j "$J" --max "$maxr" $caps > "$GATE_DIR/captures.out" 2>&1
  local st=$?
  cat "$GATE_DIR/captures.out"
  [ $st = 0 ] && return 0
  ! grep '^capture_prerender: [^ ]*: ' "$GATE_DIR/captures.out" | grep -v ': once more, alone$' |
    awk '{ n = $2; $1 = $2 = ""; last[n] = $0 } END { for (n in last) print n, last[n] }' |
    grep -v ' [0-9]* renders captured\| up to date\| no render$' | grep -q .
}
gate_step captures captures
norender=$(sed -n 's/^capture_prerender: \(.*\): no render$/\1/p' "$GATE_DIR/captures.out" | sort -u)
[ -n "$norender" ] && note "no render (no input): $(echo $norender)"
list=$GATE_DIR/cases.txt
(for t in $tests; do echo "build/pre/$t"; done; for d in $dumps; do echo "build/pre/dump_$d"; done
 for s in $seeds; do echo "build/pre/gen_$s"; done) | while read -r d; do [ -d "$d/r0" ] && echo "$d"; done > "$list"
nren=$(while read -r d; do ls -d "$d"/r* 2>/dev/null; done < "$list" | wc -l)
note "inputs: $(echo $tests | wc -w) test pages (at most $maxr renders each), $(echo $dumps | wc -w) dumps, $(echo $seeds | wc -w) scenegen seeds: $(wc -l < "$list") cases, $nren renders"

if [ "$mode" = --mutants ]; then
  gate_mutants mutants      tb/tsp_tile/mutants.txt      --njobs "${TSP_TILE_MUT_NJOBS:-4}"
  gate_mutants mutants-tex  tb/tsp_tile/mutants_tex.txt  --njobs "${TSP_TILE_MUT_NJOBS:-4}"
  gate_mutants mutants-tbuf tb/tsp_tile/mutants_tbuf.txt --njobs "${TSP_TILE_MUT_NJOBS:-4}"
  gate_end
fi

items=$GATE_DIR/items.txt
: > "$items"
gate_item "$items" lint-tsp-tile - 6 1 step lint-tsp-tile.log $MAKE -s lint-tsp-tile
for k in $(seq 0 15); do
  gate_item "$items" unit-tex "$k/16" 3 1 tb "shards-tex/log_$k.txt" build/obj_tsp_tile/unit/tb --only tex --n "$NTEX" --shard "$k/16"
  gate_item "$items" unit-shade "$k/16" 3 1 tb "shards-shade/log_$k.txt" build/obj_tsp_tile/unit/tb --only shade --n "$NSHADE" \
    --shard "$k/16"
done
split=case
[ "$mode" = --full ] && split=render
python3 tools/gate/tile_items.py --list "$list" --group tile --logs shards-tile --split "$split" --cost "$GATE_DIR/cost.txt" \
  --jobs "$J" -- build/obj_tsp_tile/tb --vramvary 7 >> "$items"

qopt=()
if [ "$mode" = --full ] && [ -n "$SAMPLE" ]; then
  mv "$items" "$GATE_DIR/items_all.txt"
  gate_step sample python3 tools/gate/sample_items.py --seed "$SAMPLE" --gate tsp-tile-full --budget "${SAMPLE_BUDGET:-1800}" \
    --jobs "$J" --cost "$GATE_DIR/cost.txt" --always tools/gate/always_run.txt --whole lint-tsp-tile,unit-tex,unit-shade \
    --every tile \
    "$GATE_DIR/items_all.txt" "$items"
  while IFS= read -r l; do note "$l"; done < <(grep '^sample: ' "$GATE_DIR/sample.log")
  cp "$GATE_DIR/cost.txt" "$GATE_DIR/cost_before.txt" 2>/dev/null || : > "$GATE_DIR/cost_before.txt"
  qopt=(--optional "$items.optional" --deadline "${SAMPLE_BUDGET:-1800}")
fi
gate_queue queue "$items" "${qopt[@]}"
if [ "$mode" = --full ] && [ -n "$SAMPLE" ]; then
  python3 tools/gate/sample_items.py --coverage "$GATE_DIR/pq_results.tsv" --cost "$GATE_DIR/cost_before.txt" \
    "$GATE_DIR/items_all.txt" "$items" > "$GATE_DIR/coverage.log"
  while IFS= read -r l; do note "$l"; done < "$GATE_DIR/coverage.log"
fi

# the testbenches' lines, summed
{
  for s in tex shade; do
    cat "$GATE_DIR"/shards-$s/log_*.txt 2>/dev/null | gawk -v s="$s" '
      /^tsp_unit: (tex|shade): / { n += $3; c += $(NF - 1) }
      /^tsp_unit: [0-9]+ checks, [0-9]+ failures/ { ck += $2; fl += $4 }
      END { printf "unit-%s: %d %s, %d checks, %d failures\n", s, n, s == "tex" ? "points" : "pixels", ck, fl }'
  done
  cat "$GATE_DIR"/shards-tile/log_*.txt 2>/dev/null | gawk '
    function g(re,   m) { return match($0, re, m) ? m[1] : 0 }
    /^tsp_tile: case / { nc++; r += g(": ([0-9]+) renders"); rr += g("\\(([0-9]+) VRAM-race"); rd += g(", ([0-9]+) differences there")
      e += g(" ([0-9]+) entries"); p += g(" ([0-9]+) passes"); ps += g("\\(([0-9]+) pre-sorted"); it += g(" ([0-9]+) items")
      nl += g("\\(([0-9]+) null\\)"); px += g(" ([0-9]+) pixels,"); w += g(" ([0-9]+) writes"); fb += g(" ([0-9]+) feedback messages")
      sw += g(" ([0-9]+) swaps"); wo += g(" ([0-9]+) write-out reads"); clk += g("; ([0-9]+) clk"); ts += g("texture stall ([0-9]+)")
      ms += g("misses ([0-9]+)"); fl += g("fill ([0-9]+)"); fbb += g("feedback block ([0-9]+)"); h += g("held ([0-9]+)")
      dr += g("pass drain ([0-9]+)"); if ($NF != "ok") bad++ }
    /^tsp_tile: [0-9]+ checks, [0-9]+ failures/ { ck += $2; fa += $4 }
    END {
      printf "tile: %d cases (%d not ok), %d renders, %d entries, %d SHADE passes (%d pre-sorted), %d items (%d null), %d pixels, %d tile-buffer writes, %d feedback messages, %d swaps, %d secondary-port reads; %d checks, %d failures\n", nc, bad, r, e, p, ps, it, nl, px, w, fb, sw, wo, ck, fa
      printf "tile: VRAM-race renders %d (%d differences there, their own class: ARCHITECTURE 3.2.1)\n", rr, rd
      printf "tile: clocks %d (reported, not gated: MT6, T8): %.3f a pixel; texture stall %d clk (%d line fills, filling %d clk), feedback block %d, held by the testbench %d, the pass drain %d\n", clk, px ? clk / px : 0, ts, ms, fl, fbb, h, dr }'
} > "$GATE_DIR/tb.txt"
while IFS= read -r l; do note "$l"; done < "$GATE_DIR/tb.txt"
grep -qE '(: [0-9]+ checks, [1-9][0-9]* failures|\([1-9][0-9]* not ok\))' "$GATE_DIR/tb.txt" && { GATE_LINES+=("testbench: FAIL"); GATE_FAILED=1; }
grep -qE '^tile: 0 cases' "$GATE_DIR/tb.txt" && { GATE_LINES+=("tile: no case ran: FAIL"); GATE_FAILED=1; }
gate_end

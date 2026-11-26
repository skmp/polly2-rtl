#!/bin/bash
# refsw3_known.sh: where the recorded refsw3 differs from the console, computed (PLAN 1.4 "refsw3-known, computed", 0 rule
# 4): never a hand-kept list. refsw3-offline at the recorded nulldc3 revision (build/refsw3-offline, make refsw3-offline)
# renders every console archive the hw gate (tools/gate/gate_frames_hw.sh, M13) reads:
#   tests    every test of $DCTESTS/fit/hw but the *_races (their cells vary from run to run; MT8's), with the
#            register-override and archived-set variants (<test>+<reg>=<value>, <test>@<set>) as run2.sh takes them,
#            through dreamcast-tests' own scripts, unchanged:
#              bash $DCTESTS/run2.sh <tests> off      (OFFLINE=build/refsw3-offline, PVR_TESTS=build/known/pvr_tests)
#              python3 $DCTESTS/compare2.py <test> ref off -a
#            a line "<test> <same>/<regions>" (and "input-stale" when the stream is not the one the console was given:
#            off.crc against fit/hw/<test>/hw.crc), each region that differs indented below it
#   sets     (M13) every archived measurement set fit/<test>_data/<set>.cases.json that has a reader (archive_check.sh's
#            185: uvrun has none): the stream and refsw3-offline's pages of tools/gate/capture_hwstream.sh <test>@<set>
#            (run2.sh's worker's build and pipe), the test's reader (read.py; zmeas's read.cpp built in
#            build/hwstream/.tools) and compare_archive.py <test> <set> off: a line "set <test>@<set> <its line>"
#            (archive_check.sh's own steps; it is not called, because its model/build.sh builds the readers inside
#            dreamcast-tests)
#   dumps    (M13) every polly2-data dump with a console frame (<scene>.hw.png, 786): refsw3-offline "pvrdmp; render; save",
#            the frame against framepng.py's raw bytes (tools/gate/frames_hw_cmp.py --ref png: rescore.py's logic), a line
#            "png <scene> <pixels that differ> <of>"; every legacy dump with the console's video memory
#            (vram_out_<scene>.bin, 63): "regs; vram; render; save" (--lax, as polly2dumps.py), "vout <scene> <words that
#            differ> <framebuffer pixels that differ> <of>"
# The result is build/gate/refsw3_known.txt: the revision header (nulldc3 HEAD and refsw3-dirty, dreamcast-tests HEAD), a
# line "# sections: <the sections run>", then the lines; a partial run (tests named, or --sections short of all three)
# writes build/gate/refsw3_known.partial.txt instead (M13: make refglue-selftest's README tests had overwritten the gate's
# file with one section). The hw gate refuses the file when its header is not the revisions
# it runs at or it lacks a section the gate reads (and then runs this script).
#
#   tools/gate/refsw3_known.sh [-j N] [--expect <file>] [--all-exact] [--sections tests,sets,dumps] [test ...]
#
#   test ...       default: every test of fit/hw but the *_races (tests named: the tests section only)
#   --sections     the sections to compute (default all three)
#   --expect f     lines "<test> <same>/<regions>": the scores the dreamcast-tests README records for refsw3 at this
#                  revision (tb/ref/readme_scores.txt); each must be reproduced exactly, and the test must be in the run
#   --all-exact    every test of the run must be exact (the README's "every regress test is exact" at 4f3efe15)
#
# Prints the per-test lines and "refsw3_known: PASS" / "FAIL" (the exit code); without --expect / --all-exact it passes
# when every test, set and dump ran.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
J=12
EXPECT=""
ALLEXACT=0
SECTIONS=tests,sets,dumps
while [ $# -gt 0 ]; do
  case "$1" in
    -j) J=$2; shift 2 ;;
    --expect) EXPECT=$2; shift 2 ;;
    --all-exact) ALLEXACT=1; shift ;;
    --sections) SECTIONS=$2; shift 2 ;;
    *) break ;;
  esac
done
OFFDIR=$P2_ROOT/build/refsw3-offline
[ -x "$OFFDIR/refsw3-offline" ] || { echo "refsw3_known: no $OFFDIR/refsw3-offline (make refsw3-offline)"; exit 1; }
if [ $# -gt 0 ]; then
  TESTS="$*"
  SECTIONS=tests
else
  TESTS=$(ls "$DCTESTS/fit/hw" | grep -v '_races$')
fi
W=$P2_ROOT/build/known/pvr_tests
mkdir -p "$W"
export PVR_TESTS=$W OFFLINE=$OFFDIR OFFLINE_TOOL=refsw3-offline JOBS=$J PYTHONDONTWRITEBYTECODE=1
has() { [[ ",$SECTIONS," == *",$1,"* ]]; }
# a partial run (tests named, or not every section: make refglue-selftest's README tests) writes beside the gate's file,
# never over it (the hw gate reads build/gate/refsw3_known.txt, all three sections)
OUT=$P2_ROOT/build/gate/refsw3_known.txt
[ "$SECTIONS" = tests,sets,dumps ] || OUT=$P2_ROOT/build/gate/refsw3_known.partial.txt
mkdir -p "$(dirname "$OUT")"
rev_header > "$OUT.tmp"
echo "# sections: $(echo "$SECTIONS" | tr ',' ' ')" >> "$OUT.tmp"
fail=0
declare -A score
has tests || TESTS=""
if [ -n "$TESTS" ]; then
  for t in $TESTS; do rm -f "$W/$t"/*.off*.raw "$W/$t/off.crc"; done
  bash "$DCTESTS/run2.sh" -j "$J" $TESTS off > "$W/run2.log" 2>&1
fi
for t in $TESTS; do
  res=$(cd "$DCTESTS" && python3 compare2.py "$t" ref off -a 2>&1)
  last=$(echo "$res" | tail -n 1)
  if [[ "$last" =~ in\ ([0-9]+)\ of\ ([0-9]+)\ regions ]]; then
    s="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else
    s="error"
    fail=1
  fi
  score[$t]=$s
  note=""
  cmp -s "$W/$t/off.crc" "$DCTESTS/fit/hw/$t/hw.crc" || note=" input-stale"
  echo "$t $s$note" | tee -a "$OUT.tmp"
  [ "$s" = error ] && echo "$res" | tail -n 3 | sed 's/^/    /'
  # the regions that differ: compare2's lines before its summary
  echo "$res" | head -n -1 | sed 's/^/    /' >> "$OUT.tmp"
  if [ "$ALLEXACT" = 1 ] && [ "$s" != error ] && [ "${s%/*}" != "${s#*/}" ]; then
    echo "refsw3_known: $t is not exact ($s)"; fail=1
  fi
done
# ---- the archived sets (archive_check.sh's steps on capture_hwstream.sh's refsw3-offline pages)
nsets=0
if has sets; then
  sets=$(for t in $(ls -d "$DCTESTS"/fit/*_data | sed 's|.*/fit/||; s|_data$||'); do
           td=""; for g in pvr-tests ta-tests; do [ -d "$DCTESTS/$g/$t" ] && td=$DCTESTS/$g/$t; done
           [ -n "$td" ] && { [ -f "$td/read.py" ] || [ -f "$td/read.cpp" ]; } || continue
           for f in "$DCTESTS/fit/${t}_data"/*.cases.json; do [ -f "$f" ] && echo "$t@$(basename "$f" .cases.json)"; done
         done)
  nsets=$(echo $sets | wc -w)
  bash "$HERE/capture_hwstream.sh" -j "$J" $sets > "$P2_ROOT/build/known/sets_capture.log" 2>&1 ||
    { echo "refsw3_known: the sets' captures failed (build/known/sets_capture.log)"; fail=1; }
  export DCTESTS P2_ROOT
  echo "$sets" | xargs -P "$J" -I{} bash -c '
    r={}; t=${r%%@*}; s=${r#*@}; d=$P2_ROOT/build/hwstream/$r
    td=$DCTESTS/pvr-tests/$t; [ -d "$td" ] || td=$DCTESTS/ta-tests/$t
    if [ -f "$td/read.cpp" ]; then (cd "$d" && "$P2_ROOT/build/hwstream/.tools/${t}_read" "$d" off) > /dev/null 2>&1
    else python3 -B "$td/read.py" "$d" off > /dev/null 2>&1; fi
    l=$(OFFLINE_TOOL=refsw3-offline python3 -B "$DCTESTS/compare_archive.py" "$t" "$s" off "$d" 2>&1 | tail -n 1)
    echo "set $r $l"' | sort > "$P2_ROOT/build/known/sets.txt"
  cat "$P2_ROOT/build/known/sets.txt" >> "$OUT.tmp"
  n=$(grep -c "archived console on" "$P2_ROOT/build/known/sets.txt")
  echo "refsw3_known: $n of $nsets sets read ($(grep -c DIFFER "$P2_ROOT/build/known/sets.txt") with readings that differ from the console)"
  [ "$n" = "$nsets" ] || { grep -v "archived console on" "$P2_ROOT/build/known/sets.txt" | head -5; fail=1; }
fi

# ---- the dumps: hw.png frames and vram_out video memory
if has dumps; then
  DUMPS=${POLLY2_DUMPS:-$P2_ROOT/../dreamster/polly2-rtl/polly2-data/dumps}
  KD=$P2_ROOT/build/known/dumps
  mkdir -p "$KD"
  export DUMPS KD OFFDIR
  { ls "$DUMPS"/*.hw.png | xargs -n 1 basename | sed 's/\.hw\.png$//; s/^/png /'
    ls "$DUMPS"/vram_out_*.bin | xargs -n 1 basename | sed 's/^vram_out_//; s/\.bin$//; s/^/vout /'; } |
  xargs -P "$J" -L 1 bash -c '
    k=$0 s=$1 w=$KD/$k.$s; mkdir -p "$w"
    if [ $k = png ]; then
      if [ -f "$DUMPS/$s.pvrdmp" ]; then c="pvrdmp $DUMPS/$s.pvrdmp"; else c="regs $DUMPS/pvr_regs_$s.bin; vram $DUMPS/vram_$s.bin"; fi
      "$OFFDIR/refsw3-offline" -c "$c; render; save $w" > "$w/off.log" 2>&1
    else
      "$OFFDIR/refsw3-offline" --lax -c "regs $DUMPS/pvr_regs_$s.bin; vram $DUMPS/vram_$s.bin; render; save $w" > "$w/off.log" 2>&1
    fi
    python3 -B "$P2_ROOT/tools/gate/frames_hw_cmp.py" --ref $k "$s" "$w" 2>&1 | tail -n 1
    rm -rf "$w"' | sort > "$KD.txt"
  cat "$KD.txt" >> "$OUT.tmp"
  np=$(grep -c '^png [^ ]* [0-9]* [0-9]*$' "$KD.txt"); nv=$(grep -c '^vout [^ ]* -\?[0-9]* [0-9]* [0-9]*$' "$KD.txt")
  echo "refsw3_known: $np hw.png frames ($(awk '$1 == "png" && $3 != 0' "$KD.txt" | wc -l) differ from the console), $nv vram_out ($(awk '$1 == "vout" && $3 != 0' "$KD.txt" | wc -l) differ)"
  [ "$np" = "$(ls "$DUMPS"/*.hw.png | wc -l)" ] && [ "$nv" = "$(ls "$DUMPS"/vram_out_*.bin | wc -l)" ] ||
    { grep -v '^png [^ ]* [0-9]* [0-9]*$\|^vout [^ ]* -\?[0-9]* [0-9]* [0-9]*$' "$KD.txt" | head -5; fail=1; }
fi
mv "$OUT.tmp" "$OUT"

if [ -n "$EXPECT" ]; then
  while read -r t want _; do
    case "$t" in ''|\#*) continue ;; esac
    got=${score[$t]:-not run}
    if [ "$got" = "$want" ]; then
      echo "refsw3_known: $t $got = the README's $want"
    else
      echo "refsw3_known: $t $got, the README has $want"; fail=1
    fi
  done < "$EXPECT"
fi
echo "refsw3_known: $(echo $TESTS | wc -w) tests, $nsets sets$(has dumps && echo ", the dumps"): ${OUT#$P2_ROOT/}"
if [ $fail = 0 ]; then echo "refsw3_known: PASS"; exit 0; fi
echo "refsw3_known: FAIL"; exit 1

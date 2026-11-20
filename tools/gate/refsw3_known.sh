#!/bin/bash
# refsw3_known.sh: where the recorded refsw3 differs from the console, computed (PLAN 1.4 "refsw3-known, computed", 0 rule
# 4): never a hand-kept list. refsw3-offline at the recorded nulldc3 revision (build/refsw3-offline, make refsw3-offline)
# renders every console archive the hw gate reads, through dreamcast-tests' own scripts, unchanged:
#   bash $DCTESTS/run2.sh <tests> off      (OFFLINE=build/refsw3-offline, PVR_TESTS=build/known/pvr_tests)
#   python3 $DCTESTS/compare2.py <test> ref off -a
# and the result is build/gate/refsw3_known.txt: the revision header (nulldc3 HEAD and refsw3-dirty, dreamcast-tests
# HEAD), then per test "<test> <same>/<regions>" (and "input-stale" when the stream is not the one the console was given:
# off.crc against fit/hw/<test>/hw.crc), each region that differs indented below it. The hw gate (M13) refuses the
# file when its header is not the revisions it runs at.
#
#   tools/gate/refsw3_known.sh [-j N] [--expect <file>] [--all-exact] [test ...]
#
#   test ...       default: every test of $DCTESTS/fit/hw but the *_races (their cells vary from run to run), with the
#                  register-override and archived-set variants (<test>+<reg>=<value>, <test>@<set>) as run2.sh takes them
#   --expect f     lines "<test> <same>/<regions>": the scores the dreamcast-tests README records for refsw3 at this
#                  revision (tb/ref/readme_scores.txt); each must be reproduced exactly, and the test must be in the run
#   --all-exact    every test of the run must be exact (the README's "every regress test is exact" at 4f3efe15)
#
# Prints the per-test lines and "refsw3_known: PASS" / "FAIL" (the exit code); without --expect / --all-exact it passes
# when every test ran. Archived measurement sets (archive_check.sh) are not run: dreamcast-tests' readers build tools
# inside its own tree (model/build.sh), which this repository does not write to.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
J=12
EXPECT=""
ALLEXACT=0
while [ $# -gt 0 ]; do
  case "$1" in
    -j) J=$2; shift 2 ;;
    --expect) EXPECT=$2; shift 2 ;;
    --all-exact) ALLEXACT=1; shift ;;
    *) break ;;
  esac
done
OFFDIR=$P2_ROOT/build/refsw3-offline
[ -x "$OFFDIR/refsw3-offline" ] || { echo "refsw3_known: no $OFFDIR/refsw3-offline (make refsw3-offline)"; exit 1; }
if [ $# -gt 0 ]; then
  TESTS="$*"
else
  TESTS=$(ls "$DCTESTS/fit/hw" | grep -v '_races$')
fi
W=$P2_ROOT/build/known/pvr_tests
mkdir -p "$W"
export PVR_TESTS=$W OFFLINE=$OFFDIR OFFLINE_TOOL=refsw3-offline JOBS=$J PYTHONDONTWRITEBYTECODE=1
for t in $TESTS; do rm -f "$W/$t"/*.off*.raw "$W/$t/off.crc"; done
bash "$DCTESTS/run2.sh" -j "$J" $TESTS off > "$W/run2.log" 2>&1

OUT=$P2_ROOT/build/gate/refsw3_known.txt
mkdir -p "$(dirname "$OUT")"
rev_header > "$OUT"
fail=0
declare -A score
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
  echo "$t $s$note" | tee -a "$OUT"
  [ "$s" = error ] && echo "$res" | tail -n 3 | sed 's/^/    /'
  # the regions that differ: compare2's lines before its summary
  echo "$res" | head -n -1 | sed 's/^/    /' >> "$OUT"
  if [ "$ALLEXACT" = 1 ] && [ "$s" != error ] && [ "${s%/*}" != "${s#*/}" ]; then
    echo "refsw3_known: $t is not exact ($s)"; fail=1
  fi
done
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
echo "refsw3_known: $(echo $TESTS | wc -w) tests, build/gate/refsw3_known.txt"
if [ $fail = 0 ]; then echo "refsw3_known: PASS"; exit 0; fi
echo "refsw3_known: FAIL"; exit 1

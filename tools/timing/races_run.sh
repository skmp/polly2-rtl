#!/bin/bash
# races_run.sh: one *_races test on the RTL (make timing-report): dreamcast-tests run2.sh off with p2-offline
# (conventions.md 7.4.1) under the timing configuration's VR_ROW, into <folder>/<test>/ (page<n>.off.raw, labels.txt).
#   tools/timing/races_run.sh <test> <folder> <VR_ROW>
set -u
t=$1 out=$2 vr=$3
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DCT=${DCTESTS:-$ROOT/../dreamcast-tests}
mkdir -p "$out"
# run2.sh builds the offline tool first ($NULLDC3/$OFFLINE_TOOL/build.sh): several of these at once must not all run make
# on p2-offline, so they get a build.sh that only checks that p2-offline is there (the gate built it)
nb=$ROOT/build/timing/nobuild/p2-offline
mkdir -p "$nb"
printf '#!/bin/bash\ntest -x "%s/build/p2-offline/p2-offline"\n' "$ROOT" > "$nb/build.sh"
cd "$DCT" && env P2_VR_ROW="$vr" NULLDC3="$ROOT/build/timing/nobuild" OFFLINE_TOOL=p2-offline OFFLINE="$ROOT/build/p2-offline" \
  PVR_TESTS="$out" bash run2.sh -j 1 "$t" off || exit 1
test -s "$out/$t/labels.txt" && ls "$out/$t"/page*.off*.raw > /dev/null 2>&1

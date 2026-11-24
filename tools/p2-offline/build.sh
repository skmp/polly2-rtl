#!/bin/bash
# Build p2-offline (polly2-rtl's refsw3-offline with the RTL for RenderCORE, PLAN 1.4, conventions.md 7.4.1) for
# dreamcast-tests' scripts, which run `bash $NULLDC3/$OFFLINE_TOOL/build.sh $OFFLINE` and then `$OFFLINE/$OFFLINE_TOOL -`:
#   NULLDC3=<polly2-rtl>/tools OFFLINE_TOOL=p2-offline OFFLINE=<polly2-rtl>/build/p2-offline PVR_TESTS=<polly2-rtl>/build/pvr_tests
#   bash build.sh [output folder, default: <polly2-rtl>/build/p2-offline]
# nulldc3 is found beside polly2-rtl, not from $NULLDC3 (which points here in those runs).
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${1:-$ROOT/build/p2-offline}
N3=$(cd "$ROOT/../nulldc3" && pwd) || { echo "p2-offline: no nulldc3 beside polly2-rtl"; exit 1; }
make -C "$ROOT" -s NULLDC3="$N3" REFCORE="$N3/refsw3/refcore" REFTA="$N3/refsw3/refta" p2-offline || exit 1
mkdir -p "$OUT"
if [ "$(cd "$OUT" && pwd)" != "$ROOT/build/p2-offline" ]; then
  ln -sf "$ROOT/build/p2-offline/p2-offline" "$OUT/p2-offline"
fi
echo "built $OUT/p2-offline"

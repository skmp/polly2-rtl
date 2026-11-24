#!/bin/bash
# frames_dual.sh: the frame gate's dual-mode item (PLAN 1.4, M12): p2-offline-dual on a polly2-data dump, refcore's
# RenderCORE_sw on a copy of video memory and the RTL compared in process; passes iff "p2-dual: render 0: equal".
#   tools/gate/frames_dual.sh <dump file (.pvrdmp)>
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
out=$("$ROOT/build/p2-offline-dual/p2-offline" -c "pvrdmp $1; render" 2>&1)
echo "$out"
grep -q '^p2-dual: render 0: equal' <<< "$out" && echo "frames_dual: PASS" || { echo "frames_dual: FAIL"; exit 1; }

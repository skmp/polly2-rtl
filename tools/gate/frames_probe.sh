#!/bin/bash
# frames_probe.sh: the frame gate's mutant probe (tb/frames/mutants*.txt, make frames-mutants): make p2-offline-probe copies
# it beside p2-offline in the object folder (tools/gate/mutants.py runs a probe from there, in the repository's root):
#   <object folder>/frames_probe <capture folder> <config>     tools/gate/frames_run.sh with that p2-offline
# A mutant that never ends a render (a region array read out of step) stops at FRAMES_PROBE_CLK_LIMIT clocks (50 M; the
# subset's longest render is 4.7 M at VR_LAT 8, 27 M under +vramvary) instead of p2-offline's 2e9.
d=$(cd "$(dirname "$0")" && pwd)
export P2_CLK_LIMIT=${P2_CLK_LIMIT:-${FRAMES_PROBE_CLK_LIMIT:-50000000}}
exec bash tools/gate/frames_run.sh "$1" "$2" "$d/run_$(basename "$1")_$2" "$d/p2-offline"

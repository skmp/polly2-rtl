#!/bin/bash
# frames_probe.sh: the frame gate's mutant probe (tb/frames/mutants*.txt, make frames-mutants): make p2-offline-probe copies
# it beside p2-offline in the object folder (tools/gate/mutants.py runs a probe from there, in the repository's root):
#   <object folder>/frames_probe <capture folder> <config>     tools/gate/frames_run.sh with that p2-offline
d=$(cd "$(dirname "$0")" && pwd)
exec bash tools/gate/frames_run.sh "$1" "$2" "$d/run_$(basename "$1")_$2" "$d/p2-offline"

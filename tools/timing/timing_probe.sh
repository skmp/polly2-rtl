#!/bin/bash
# timing_probe.sh: the timing harness's mutant probe (tb/timing/mutants.txt, make timing-harness-mutants): make
# p2-offline-tprobe copies it beside p2-offline in the object folder (tools/gate/mutants.py runs a probe from there, in the
# repository's root):
#   <object folder>/timing_probe <group>       the group's scenes (cut: the cut variant's cut / cutn; wout: the gate's
#                                              scenes of `all`) through that p2-offline under tb/timing/k.txt's VRAM
#                                              configuration, then tools/timing/gate_timing.py --groups <group>
# The streams are build/timing/streams' (make timing-harness or timing-harness-mutants writes them first).
set -u
d=$(cd "$(dirname "$0")" && pwd)
g=$1
TM=tools/timing
SD=build/timing/streams
EMIT=build/timing/emit
VR_ROW=$(python3 -c "import sys; sys.path.insert(0, '$TM'); import tmlib; print(int(tmlib.read_cfg('VR_ROW')))")
case "$g" in
  cut)  v=cut; sel=$(python3 $TM/tm_items.py $SD/cut.txt --match '^cut' --split 1 | cut -f2) ;;
  wout) v=all; sel=$(python3 $TM/tm_items.py $SD/all.txt --match '^(bgonly 0 0 0 0|wout [0-6] [18] 0 0)$' --split 1 | cut -f2) ;;
  *)    echo "timing_probe: no group $g"; exit 2 ;;
esac
log=$d/probe_$g.log
P2_VR_ROW=$VR_ROW bash $TM/tm_item.sh "$EMIT/tm-$v" "$SD/$v.txt" "$sel" "$log" "$d/p2-offline" || exit 1
python3 $TM/gate_timing.py --spec tb/timing/gate.txt --groups "$g" "$log"

#!/bin/bash
# frames_run.sh: one case of the frame gate (PLAN M12, 1.4; conventions.md 7.4.2) on p2-offline, compared with
# refsw3-offline's video memory after every render: tools/gate/gate_frames_off.sh's work item.
#
#   tools/gate/frames_run.sh <capture folder> <config> <run folder> [p2-offline]
#
#   <capture folder>  build/pre/<case>, made by tools/gate/capture_prerender.sh with CAP_STREAM=1: refsw3-offline's video
#                     memory after each render (r<k>/post/vram.bin.gz) and the command stream it ran (stream.txt: a test's
#                     PC build's commands with refsw3-offline's readback answers, or a dump's); a scenegen case's stream is
#                     its renders' registers and video memory (r<k>/pvr_regs.bin, vram.bin.gz), loaded before each render
#   <config>          base (VR_LAT 8), vary (+vramvary: P2_VRAMVARY=7), lat1 (P2_VR_LAT=1), lat4 (P2_VR_LAT=4), lat16
#                     (P2_VR_LAT=16); PLAN 1.6's sweep 1, 4, 8, 16
#   <run folder>      p2-offline's log and its saves (deleted once compared)
#
# The stream goes to p2-offline unchanged but for its saves: the one before each render is dropped, the one after it
# writes into the run folder; the readbacks' files go there too. Then tools/gate/frames_cmp.py compares every word of
# video memory after every render (its last line "frames_cmp: PASS" / "FAIL"). FRAMES_TIMEOUT: seconds p2-offline may take
# on the case (7200).
set -u
cap=$(cd "$1" && pwd); cfg=$2; run=$3
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OFF=${4:-$ROOT/build/p2-offline/p2-offline}
name=$(basename "$cap")
rm -rf "$run" && mkdir -p "$run/work"
run=$(cd "$run" && pwd)
case "$cfg" in
  base)  envs=() ;;
  vary)  envs=(P2_VRAMVARY=7) ;;
  lat1)  envs=(P2_VR_LAT=1) ;;
  lat4)  envs=(P2_VR_LAT=4) ;;
  lat16) envs=(P2_VR_LAT=16) ;;
  *) echo "frames_run: unknown config $cfg"; exit 2 ;;
esac
if [ "${name#gen_}" != "$name" ]; then
  for d in $(ls -d "$cap"/r* | sort -V); do
    k=${d##*/r}
    [ -e "$d/skipped" ] && continue
    zcat "$d/vram.bin.gz" > "$run/work/r$k.bin"
    printf 'regs %s/pvr_regs.bin\nvram %s/work/r%s.bin\necho P2CAP pre %s\nrender\nsave %s/r%s\necho P2CAP post %s\n' \
      "$d" "$run" "$k" "$k" "$run" "$k" "$k"
  done > "$run/stream.txt"
else
  [ -f "$cap/stream.txt" ] || { echo "frames_run: $name: no stream.txt (capture with CAP_STREAM=1)"; echo "frames_cmp: FAIL"; exit 1; }
  # the saves: before a render dropped, after it into the run folder; the readbacks' files into the run folder
  awk -v cap="$cap" -v run="$run" '
    function lit(s, a, b,   i, o) { o = ""; while ((i = index(s, a)) > 0) { o = o substr(s, 1, i - 1) b; s = substr(s, i + length(a)) } return o s }
    $1 == "save" && index($2, cap "/r") == 1 {
      k = substr($2, length(cap) + 3)
      if (k ~ /^[0-9]+$/) next
      if (k ~ /^[0-9]+\/post$/) { sub(/\/post$/, "", k); print "save " run "/r" k; next } }
    { print lit($0, cap "/work", run "/work") }' "$cap/stream.txt" > "$run/stream.txt"
fi
mkdir -p $(awk '$1 == "save" { print $2 }' "$run/stream.txt")
t0=$SECONDS
env "${envs[@]}" timeout "${FRAMES_TIMEOUT:-7200}" "$OFF" - < "$run/stream.txt" > "$run/p2.log" 2>&1
st=$?
echo "frames_run: $name $cfg: p2-offline exit $st, $((SECONDS - t0)) s"
python3 "$HERE/frames_cmp.py" "$cap" "$run" "$cfg" "$st"
r=$?
rm -rf "$run"/r* "$run/work"
exit $r

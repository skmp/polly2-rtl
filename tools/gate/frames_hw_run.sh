#!/bin/bash
# frames_hw_run.sh: one item of the console-archive gate (PLAN M13, 1.4 "gate_frames_hw.sh"; conventions.md 7.4.3):
# p2-offline on one console archive's input, compared with the console's archived result by tools/gate/frames_hw_cmp.py.
#
#   tools/gate/frames_hw_run.sh <item> <config> <run root> [p2-offline]
#
#   <item>      test:<run>      a fit/hw test (<test>, <test>+<reg>=<value>, <test>@<set>...): the stream refsw3-offline was
#                               given (build/hwstream/<run>/stream.txt, tools/gate/capture_hwstream.sh), replayed into
#                               <run root>/<run>/ (its page<n>.off.raw, labels.txt); compare2.py <run> ref off; every
#                               readback's answer (the stream's k-th `dump32 ... readback.bin`) against refsw3-offline's
#                               k-th answer (the capture's readbacks.txt): the stream after a readback is what the
#                               program sent on refsw3's answer, so the pages are the RTL's only if its answers are equal
#               set:<test>@<set>  an archived set (fit/<test>_data/<set>): the same replay, the test's reader (read.py, or
#                               read.cpp built in build/hwstream/.tools), compare_archive.py <test> <set> off
#               png:<scene>     a polly2-data dump with a console frame (<scene>.hw.png): pvrdmp; render; save; the frame
#                               (FB_W_SOF1, FB_W_LINESTRIDE, FB_Y_CLIP, as dumprender.sh dumps it) against
#                               framepng.py raw <scene>.hw.png, pixel by pixel
#               vout:<scene>    a legacy dump with the console's video memory after the render (vram_out_<scene>.bin):
#                               regs; vram; render; save; all of video memory word by word, and the framebuffer's pixels
#               z:<scene>       fit/zdump_data/<scene>.txt: the dump rendered with the depth tap (+ztap, p2_core's
#                               simulation-only tap of the ISP buffer's depths at each entry's end), each pixel the console
#                               read out against the RTL's key converted to refsw3's bits (tb/common/zkey.h,
#                               build/tools/ztap_cmp)
#   <config>    base (VR_LAT 8), vary (+vramvary: P2_VRAMVARY=7)
#   <run root>  the items' folders: <run root>/<run>/ for a test, <run root>/<kind>/<name>/ for the others (their
#               outputs deleted once compared, but for the logs)
#
# The last lines are frames_hw_cmp.py's: "frames_hw: <item> <config>: ...; <c> checks, <f> failures" and
# "frames_hw: PASS" / "FAIL". FRAMES_TIMEOUT: seconds p2-offline may take (7200). POLLY2_DUMPS, DCTESTS.
set -u
item=$1; cfg=$2; root=$3
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OFF=${4:-$ROOT/build/p2-offline/p2-offline}
DCTESTS=${DCTESTS:-$ROOT/../dreamcast-tests}
DUMPS=${POLLY2_DUMPS:-$ROOT/../dreamster/polly2-rtl/polly2-data/dumps}
HW=${CAP_HW:-$ROOT/build/hwstream}
case "$cfg" in
  base) envs=() ;;
  vary) envs=(P2_VRAMVARY=7) ;;
  *) echo "frames_hw_run: unknown config $cfg"; exit 2 ;;
esac
kind=${item%%:*}; name=${item#*:}
mkdir -p "$root"
root=$(cd "$root" && pwd)
# a test's folder is <run root>/<run> (compare2.py reads PVR_TESTS/<test>); the other kinds' <run root>/<kind>/<name>, so that
# two kinds of one scene (vout:sa2_ingame, z:sa2_ingame) never share a folder
run=$root/$name
[ "$kind" = test ] || run=$root/$kind/$name
rm -rf "$run" && mkdir -p "$run"
t0=$SECONDS
case "$kind" in
  test|set)
    cap=$HW/$name
    [ -f "$cap/stream.txt" ] || { echo "frames_hw_run: $name: no $cap/stream.txt (capture_hwstream.sh)"; echo "frames_hw: FAIL"; exit 1; }
    cp "$cap/labels.txt" "$run/"
    [ -f "$cap/cases.json" ] && cp "$cap/cases.json" "$run/"
    [ -f "$cap/cases.h" ] && cp "$cap/cases.h" "$run/"
    # the stream's files (pages, readbacks) into the run folder; before each page dump the renders so far (the race
    # class: a page after a VRAM-race render); each readback numbered, as capture_hwstream.sh numbered refsw3-offline's
    # answers: rb.<k>.bin, with the renders before it in readbacks.txt ("<k> <renders>"), its md5 in rb_p2.txt
    # ("<k> <md5>", "<k> -" where p2-offline wrote none), compared by frames_hw_cmp.py with the capture's readbacks.txt
    awk -v cap="$cap" -v run="$run" '
      function lit(s, a, b,   i, o) { o = ""; while ((i = index(s, a)) > 0) { o = o substr(s, 1, i - 1) b; s = substr(s, i + length(a)) } return o s }
      /^render( |$)/ || /^reg STARTRENDER/ { n++ }
      $1 == "dump32" && index($4, cap "/page") == 1 { f = substr($4, length(cap) + 2); print f, n > (run "/pages.txt") }
      $1 == "dump32" && $4 == cap "/readback.bin" { k++; print k, n + 0 > (run "/readbacks.txt"); print $1, $2, $3, run "/rb." k ".bin"; next }
      { print lit($0, cap, run) }' "$cap/stream.txt" > "$run/stream.txt"
    env "${envs[@]}" timeout "${FRAMES_TIMEOUT:-7200}" "$OFF" - < "$run/stream.txt" > "$run/p2.log" 2>&1
    st=$?
    if [ -f "$run/readbacks.txt" ]; then
      while read -r k n; do
        if [ -f "$run/rb.$k.bin" ]; then echo "$k $(md5sum < "$run/rb.$k.bin" | cut -d' ' -f1)"; else echo "$k -"; fi
        rm -f "$run/rb.$k.bin"
      done < "$run/readbacks.txt" > "$run/rb_p2.txt"
    fi
    rm -f "$run/stream.txt" "$run"/readback*.bin "$run"/readback.done
    ;;
  png|z)
    dump=$DUMPS/$name.pvrdmp
    if [ -f "$dump" ]; then cmd="pvrdmp $dump"; else cmd="regs $DUMPS/pvr_regs_$name.bin; vram $DUMPS/vram_$name.bin"; fi
    pa=()
    [ "$kind" = z ] && pa=("P2_PLUSARGS=+ztap=$run/ztap.txt")
    env "${envs[@]}" "${pa[@]}" timeout "${FRAMES_TIMEOUT:-7200}" "$OFF" -c "$cmd; render; save $run" > "$run/p2.log" 2>&1
    st=$?
    ;;
  vout)
    env "${envs[@]}" timeout "${FRAMES_TIMEOUT:-7200}" "$OFF" --lax -c \
      "regs $DUMPS/pvr_regs_$name.bin; vram $DUMPS/vram_$name.bin; render; save $run" > "$run/p2.log" 2>&1
    st=$?
    ;;
  *) echo "frames_hw_run: what is $item?"; echo "frames_hw: FAIL"; exit 2 ;;
esac
echo "frames_hw_run: $item $cfg: p2-offline exit $st, $((SECONDS - t0)) s"
python3 -B "$HERE/frames_hw_cmp.py" "$kind" "$name" "$run" "$cfg" "$st"
r=$?
rm -f "$run"/*.raw "$run"/vram.bin "$run"/pvr_regs.bin "$run"/*.npz
exit $r

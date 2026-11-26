#!/usr/bin/env python3
"""frames_cmp.py: the frame gate's comparison (PLAN M12, 1.4; conventions.md 7.4.2): p2-offline's video memory after each
render against refsw3-offline's, every 32-bit word.

    tools/gate/frames_cmp.py <capture folder> <run folder> <config> <p2-offline exit status>

<capture folder>/r<k>/post/vram.bin.gz is refsw3-offline's video memory after render k (32-bit-area order, as `save`
writes it); <run folder>/r<k>/vram.bin p2-offline's; a render refsw3-offline refused (r<k>/skipped) p2-offline refuses too
(the same main.cpp) and is not compared. <run folder>/p2.log has p2-offline's lines "p2: render <n> isp .. tsp .. video ..
vramrace <w> [first <a>]" for its renders in order, and "p2: render <n> did not end".

Classes (PLAN 0 rule 4, ARCHITECTURE 3.2.1): a render whose vramrace is not 0 is VRAM-race: its differences are reported in
their own class, never a pass or a fail; so are the renders after a VRAM-race render that differed in the same case (their
video memory starts from the race's). Every other render must be equal in every word. Prints one line per render that
is not equal and one per VRAM-race render (with its difference count, 0 too: PLAN 5 D13), then
    frames_cmp: <case> <config>: <n> renders, <e> equal, <d> differ; VRAM-race <r> (<rd> differ there), after a race <a>;
                <isp> / <tsp> clk (ISP, TSP: sums), <words> words compared
    frames_cmp: <case> <config>: <words> checks, <f> failures      (tools/gate/pq.py's per-group counts: f the words that
                                                                    differ outside the race class)
and "frames_cmp: PASS" / "FAIL" (exit 0 / 1). FAIL also when p2-offline did not exit 0 or 2 (2: a problem it reported,
as refsw3-offline does) or a render did not end.
"""
import gzip
import os
import re
import sys

import numpy as np


def main():
    cap, run, cfg, status = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    name = os.path.basename(cap.rstrip("/"))
    lines = open(os.path.join(run, "p2.log"), errors="replace").read().splitlines()
    p2 = []
    for l in lines:
        m = re.match(r"p2: render (\d+) isp (\d+) tsp (\d+) video (\d+) vramrace (\d+)(?: first ([0-9a-f]+))?", l)
        if m:
            p2.append(dict(isp=int(m[2]), tsp=int(m[3]), race=int(m[5]), first=m[6], hung=False))
            continue
        m = re.match(r"p2: render (\d+) did not end", l)
        if m:
            p2.append(dict(isp=0, tsp=0, race=0, first=None, hung=True))
    ks = sorted(int(d[1:]) for d in os.listdir(cap) if re.fullmatch(r"r\d+", d))
    fail = status not in (0, 2)
    if fail:
        print(f"frames_cmp: {name} {cfg}: p2-offline exit {status}")
    n = eq = df = rc = rcd = after = 0
    isp = tsp = words = failw = 0
    raced = False
    j = 0
    for k in ks:
        d = os.path.join(cap, f"r{k}")
        if os.path.exists(os.path.join(d, "skipped")):
            continue
        if j >= len(p2):
            print(f"frames_cmp: {name} {cfg}: r{k}: p2-offline made no render for it")
            fail = True
            break
        info = p2[j]
        j += 1
        n += 1
        if info["hung"]:
            print(f"frames_cmp: {name} {cfg}: r{k}: did not end")
            fail = True
            continue
        isp += info["isp"]
        tsp += info["tsp"]
        mine = os.path.join(run, f"r{k}", "vram.bin")
        if not os.path.exists(mine):
            print(f"frames_cmp: {name} {cfg}: r{k}: no save from p2-offline")
            fail = True
            continue
        a = np.frombuffer(open(mine, "rb").read(), dtype="<u4")
        b = np.frombuffer(gzip.open(os.path.join(d, "post", "vram.bin.gz")).read(), dtype="<u4")
        words += b.size
        if a.size != b.size:
            print(f"frames_cmp: {name} {cfg}: r{k}: {a.size} words saved, refsw3-offline {b.size}")
            fail = True
            continue
        diff = np.nonzero(a != b)[0]
        if info["race"]:
            rc += 1
            if diff.size:
                rcd += 1
                raced = True
            # every VRAM-race render, equal or not, with its difference count (PLAN 5 D13: reported in every summary)
            print(f"frames_cmp: {name} {cfg}: r{k}: VRAM-race ({info['race']} words, the first at {info['first']}): "
                  f"{diff.size} words differ (their own class)")
            continue
        if diff.size and raced:
            after += 1
            print(f"frames_cmp: {name} {cfg}: r{k}: {diff.size} words differ after a VRAM-race render (their own class)")
            continue
        if diff.size:
            df += 1
            failw += int(diff.size)
            i = int(diff[0])
            print(f"frames_cmp: {name} {cfg}: r{k}: {diff.size} words differ, the first at 32-bit-area address {4 * i:06x} "
                  f"({int(a[i]):08x}, refsw3-offline {int(b[i]):08x})")
            fail = True
        else:
            eq += 1
    print(f"frames_cmp: {name} {cfg}: {n} renders, {eq} equal, {df} differ; VRAM-race {rc} ({rcd} differ there), after a "
          f"race {after}; {isp} / {tsp} clk (ISP, TSP: sums), {words} words compared")
    # the queue's per-group counts (tools/gate/pq.py): a check a word compared, a failure a word that differs outside the
    # VRAM-race class (and a render that did not end or was not saved)
    print(f"frames_cmp: {name} {cfg}: {words} checks, {failw + (1 if fail and not failw else 0)} failures")
    print("frames_cmp: " + ("FAIL" if fail else "PASS"))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())

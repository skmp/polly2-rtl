#!/usr/bin/env python3
"""tm_items.py: a timemeas emission's renders cut into the work items of a timing run (PLAN 0 rule 8.3, MT0).

    tools/timing/tm_items.py <stream> [--console <folder>] [--keys <file> | --match <regex>] [--item-secs S] [--split N]

Prints one item a line, tab-separated: <id> <renders (P2_RENDERS)> <estimate, s> <scenes>. Items are cut at scene
boundaries only, so a scene's renders (its warm-up with them) always run in one p2-offline process; where the cuts fall
depends on the stream alone (the scenes' estimates), not on J or the cost file. A scene's estimate: its console TSP time
(clocks; 20000 when the console has none) over p2-offline's speed (~150 k clk/s) a render, plus the item's pass over
the whole stream (~8 s). --keys: only the scenes whose key ("<what> a b c d") is a line of the file (# comments); --match:
whose key matches. --item-secs (60): the most a cut-up item is predicted to take; --split N: N items of about equal
cost instead. The id: "<first scene>-<last scene>".
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tmlib  # noqa: E402

SPEED = 150e3       # clocks a second, p2-offline (one tile, VR_LAT 8)
PASS_S = 8.0        # one pass over the stream with every render skipped


def ranges(rs):
    rs = sorted(rs)
    out, a, b = [], None, None
    for r in rs:
        if a is None:
            a = b = r
        elif r == b + 1:
            b = r
        else:
            out.append((a, b))
            a = b = r
    if a is not None:
        out.append((a, b))
    return ",".join(f"{x}-{y}" if x != y else f"{x}" for x, y in out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("--console", default=os.path.join(os.path.dirname(tmlib.ROOT), "dreamcast-tests", "fit", "timemeas_logs"))
    ap.add_argument("--keys")
    ap.add_argument("--match")
    ap.add_argument("--item-secs", type=float, default=60.0)
    ap.add_argument("--split", type=int, default=0)
    a = ap.parse_args()
    D = tmlib.load_console(a.console) if os.path.isdir(a.console) else {}
    scenes = tmlib.index_stream(a.stream)
    want = None
    if a.keys:
        want = set()
        for line in open(a.keys):
            line = line.split("#")[0].strip()
            if line:
                want.add(" ".join(line.split()))
    sel = []
    for i, s in enumerate(scenes):
        if not s["n"]:
            continue
        if want is not None and s["key"] not in want:
            continue
        if a.match and not re.search(a.match, s["key"]):
            continue
        v = D.get(s["key"])
        clk = v[2] / 2 if v else 20000
        sel.append((i, s, s["n"] * clk / SPEED))
    if want is not None:
        missing = want - {s["key"] for _, s, _ in sel}
        if missing:
            sys.exit("tm_items: not in the stream: " + "; ".join(sorted(missing)))
    total = sum(e for _, _, e in sel)
    budget = max(1.0, total / a.split) if a.split else max(1.0, a.item_secs - PASS_S)
    items, cur, cost = [], [], 0.0
    for i, s, e in sel:
        if cur and cost + e > budget and (not a.split or len(items) < a.split - 1):
            items.append((cur, cost))
            cur, cost = [], 0.0
        cur.append((i, s))
        cost += e
    if cur:
        items.append((cur, cost))
    for sc, cost in items:
        rs = [r for _, s in sc for r in range(s["first"], s["first"] + s["n"])]
        print(f"{sc[0][0]}-{sc[-1][0]}\t{ranges(rs)}\t{cost + PASS_S:.0f}\t{len(sc)}")


if __name__ == "__main__":
    main()

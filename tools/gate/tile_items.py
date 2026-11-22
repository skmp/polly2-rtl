#!/usr/bin/env python3
"""tile_items.py: the work items of a tile-level testbench run over a case list (tools/gate/pq.py's items format), for
the gates of tb/isp_tile and tb/ref (PLAN 0 rule 8).

    tools/gate/tile_items.py --list <cases file> --group <g> --logs <dir> [--split case|render] [--cost <file>]
                             [--jobs J] [--est <s>] >> <items file> -- <testbench> [args ...]

Every case of the list (a capture folder a line, as the testbenches read @<list>) is an item running
`<testbench> [args ...] --shard i/N @<list>`, N the list's cases: the case alone, its index i in the list (the
testbenches seed their generators from it, not from the shard or the process). --split render (free-running mode:
tb/isp_tile/isp_tile_tb.cpp runs a case in segments of SEG = 8 renders, each from a sync with the reference and with
generators of its own, the RTL's state carried within it) cuts a case of more than one segment into runs of whole
segments, `--renders A-B` with A a segment's first render, when its cost asks for it: a case whose cost (the last
run's seconds of its items in the cost file) is above the target (the whole group's cost / (3 J), at least 2 s) is cut
into runs of segments each within the target where it can be (a segment costlier than the target is a run of its own;
an item's seconds are spread evenly over its renders); a case not in the cost file is cut into one item a segment.
Where a case is cut does not change its results (a segment's do not depend on what ran before it). The renders before
A run on the reference alone, so a cut costs that (small next to the RTL).
The estimate of a case not in the cost file: 30 times the seconds its capture took (build/pre/<case>/secs, written by
tools/gate/capture_prerender.sh: refsw3-offline's time, which grows with the scene's work), else its renders times 4
for a dump (they are larger), 1 for others; spread evenly over its renders.
Item ids: the case folder (case split) or <case>/r<A>-<B>; logs <dir>/log_<case name>[.r<A>-<B>].txt.
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pqlib  # noqa: E402

SEG = 8     # tb/isp_tile/isp_tile_tb.cpp's free-running segment


def renders(case):
    ks = []
    try:
        for d in os.listdir(case):
            if d.startswith("r") and d[1:].isdigit() and os.path.isdir(os.path.join(case, d)):
                ks.append(int(d[1:]))
    except OSError:
        pass
    ks.sort()
    # the testbenches stop at the first missing r<k>
    n = 0
    while n < len(ks) and ks[n] == n:
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", required=True)
    ap.add_argument("--group", required=True)
    ap.add_argument("--logs", required=True)
    ap.add_argument("--split", default="case", choices=("case", "render"))
    ap.add_argument("--cost", default="")
    ap.add_argument("--jobs", type=int, default=0)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
    if not cmd:
        sys.exit("tile_items: no testbench")
    J = a.jobs or pqlib.default_jobs()
    cases = []
    for line in open(a.list):
        l = line.rstrip("\n ")
        if l and not l.startswith("#"):
            cases.append(l)
    N = len(cases)
    cost = {i: w for (g, i), w in pqlib.read_cost(a.cost).items() if g == a.group} if a.cost else {}
    base = " ".join(cmd)
    out = sys.stdout

    def name(c):
        return os.path.basename(c.rstrip("/"))

    def est(c, n):
        try:
            return max(1.0, 30.0 * float(open(os.path.join(c, "secs")).read().split()[0]))
        except (OSError, ValueError, IndexError):
            return max(1, n) * (4 if name(c).startswith("dump_") else 1)

    def item(iid, e, log, extra):
        out.write(f"{a.group}\t{iid}\t{e:.2f}\t1\ttb\t{a.logs}/log_{log}.txt\t{base}{extra} --shard {ci}/{N} @{a.list}\n")

    # the per-render costs of the cases the cost file has
    per = {}
    for iid, w in cost.items():
        if "/r" in iid and a.split == "render":
            c, rr = iid.rsplit("/r", 1)
            lo, _, hi = rr.partition("-")
            try:
                lo, hi = int(lo), int(hi or lo)
            except ValueError:
                continue
            for k in range(lo, hi + 1):
                per.setdefault(c, {})[k] = w / (hi - lo + 1)
        else:
            per.setdefault(iid, {})[-1] = w
    total = sum(cost.values())
    target = max(total / (3 * J), 2.0)
    for ci, c in enumerate(cases):
        n = renders(c)
        if a.split == "case" or n <= SEG:
            iid = c
            e = cost.get(c, sum(per.get(c, {}).values()) or est(c, n))
            if a.split == "render":
                iid = f"{c}/r0-{max(n - 1, 0)}"
                e = sum(per.get(c, {}).values()) or est(c, n)
            item(iid, e, name(c) if a.split == "case" else f"{name(c)}.r0-{max(n - 1, 0)}",
                 "" if a.split == "case" else f" --renders 0-{max(n - 1, 0)}")
            continue
        pc = per.get(c, {})
        segs = [(lo, min(lo + SEG, n) - 1) for lo in range(0, n, SEG)]
        rc = [pc.get(k) for k in range(n)]
        if all(x is not None for x in rc):
            sc = [sum(rc[lo:hi + 1]) for lo, hi in segs]
            if sum(sc) <= target:
                cuts = [(0, n - 1)]
            else:
                # a run ends before the segment that would take it past the target, so a costly segment is an item
                # of its own (not the tail of a cheap run)
                cuts, first, acc = [], 0, 0.0
                for i, (lo, hi) in enumerate(segs):
                    if acc > 0 and acc + sc[i] > target:
                        cuts.append((segs[first][0], segs[i - 1][1]))
                        first, acc = i, 0.0
                    acc += sc[i]
                cuts.append((segs[first][0], n - 1))
        else:
            rc = [est(c, n) / n] * n
            cuts = segs
        for lo, hi in cuts:
            item(f"{c}/r{lo}-{hi}", sum(rc[lo:hi + 1]), f"{name(c)}.r{lo}-{hi}", f" --renders {lo}-{hi}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

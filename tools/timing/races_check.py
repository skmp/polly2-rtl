#!/usr/bin/env python3
"""races_check.py: the races lists of PLAN 1.5 (5 D5): tb/timing/races_variable.txt (tools/timing/races_var.py),
tb/timing/races_expected.txt and docs/probes.txt.

    tools/timing/races_check.py                         the lists' consistency
    tools/timing/races_check.py --run <PVR_TESTS dir>   and the RTL's pictures of the *_races tests in that folder (run2.sh
                                                        off with OFFLINE_TOOL=p2-offline: <dir>/<test>/page<n>.off.raw and
                                                        labels.txt) against the console's archived pages (fit/hw/<test>)
    tools/timing/races_check.py --write <dir>           writes races_expected.txt from such a run (then check it)

races_expected.txt: the deterministic cells (not in races_variable.txt) of the *_races tests whose console picture the
RTL does not give, because the mechanism is not fitted yet; each keyed by the probe that will fix it:
    <probe> <test> <page> <cell> | <label> | <pixels that differ>
Probes by test (PLAN 3.1): accbuf_races T10 (the write-out against the TSP: SEC COPY / SEC WRITE right after a written
tile), but T11 for the tile two before an empty keep Z tile and a SEC COPY after a tile that was not written out (the
lost event behind an empty keep Z: pages 0 and 1 H, page 2); keepz_races T11; ptchunkcarry_races and ptchunkrun_races
T12 (K1 / K2). blendpos_races is all run-variable (its statistic, MT8).

Checks: every races_expected line's probe is in docs/probes.txt and not "landed" (a landed probe's lines must be gone);
no cell is in both lists; with --run: every listed cell still differs (one that starts to pass makes the list stale) and
no other deterministic cell differs (every cell outside both lists equals the console page). Last line "races-lists:
... PASS" or "... FAIL"; exit 1 on a failure.
"""
import argparse
import gzip
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DCT = os.environ.get("DCTESTS", os.path.join(os.path.dirname(ROOT), "dreamcast-tests"))
VAR = os.path.join(ROOT, "tb", "timing", "races_variable.txt")
EXP = os.path.join(ROOT, "tb", "timing", "races_expected.txt")
PROBES = os.path.join(ROOT, "docs", "probes.txt")
TESTS = ["accbuf_races", "keepz_races", "ptchunkcarry_races", "ptchunkrun_races", "blendpos_races"]


def probe_of(test, page, text):
    if test == "accbuf_races":
        if page == 2 or text.startswith("H:"):
            return "T11"
        return "T10"
    return {"keepz_races": "T11", "ptchunkcarry_races": "T12", "ptchunkrun_races": "T12"}.get(test, "T10")


def read_cells(path, with_probe):
    out = {}
    for line in open(path):
        if not line.strip() or line.startswith("#"):
            continue
        head = line.split("|")[0].split()
        if with_probe:
            out[(head[1], int(head[2]), int(head[3]))] = (head[0], line.rstrip("\n"))
        elif head[1] != "T":
            out[(head[0], int(head[1]), int(head[2]))] = line.rstrip("\n")
    return out


def probes():
    st = {}
    for line in open(PROBES):
        if line.startswith("#") or not line.strip():
            continue
        f = [x.strip() for x in line.split("|")]
        st[f[0]] = f[1]
    return st


def diffs(run, test):
    """{(page, cell): (label, pixels that differ)} of every labelled region where the RTL's page is not the console's."""
    import numpy as np
    d = os.path.join(run, test)
    labels = [l.split(" ", 5) for l in open(os.path.join(d, "labels.txt")).read().splitlines() if l.startswith("LABEL ")]
    pages, out, n = {}, {}, 0
    for _, p, c, cw, ch, text in labels:
        p, c, cw, ch = int(p), int(c), int(cw), int(ch)
        if p not in pages:
            ref = np.frombuffer(gzip.open(os.path.join(DCT, "fit", "hw", test, f"page{p}.hw.raw.gz")).read(), dtype="<u4")
            off = np.fromfile(os.path.join(d, f"page{p}.off.raw"), dtype="<u4")
            pages[p] = (ref.reshape(480, 640), off.reshape(480, 640))
        x0, y0 = (c % 20) * 32, (c // 20) * 32
        a = pages[p][0][y0:y0 + 32 * ch, x0:x0 + 32 * cw]
        b = pages[p][1][y0:y0 + 32 * ch, x0:x0 + 32 * cw]
        k = int((a != b).sum())
        n += 1
        if k:
            out[(p, c)] = (text, k)
    return out, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run")
    ap.add_argument("--write")
    a = ap.parse_args()
    var = read_cells(VAR, False)
    if a.write:
        lines = []
        for t in TESTS:
            if t == "blendpos_races":
                continue
            dd, n = diffs(a.write, t)
            for (p, c), (text, k) in sorted(dd.items()):
                if (t, p, c) in var:
                    continue
                lines.append(f"{probe_of(t, p, text)} {t} {p} {c} | {text} | {k} pixels differ")
        with open(EXP, "w") as f:
            f.write("# tb/timing/races_expected.txt: the deterministic cells of the *_races tests (not in races_variable.txt)\n")
            f.write("# whose console picture the RTL does not give because the mechanism is not fitted yet, each keyed by its\n")
            f.write("# probe (PLAN 1.5, 5 D5; docs/probes.txt). Written by tools/timing/races_check.py --write from the RTL's run\n")
            f.write("# under tb/timing/k.txt's configuration (make timing-harness checks it). A probe that lands removes its lines.\n")
            f.write("# <probe> <test> <page> <cell> | <label> | <pixels that differ>\n")
            for l in lines:
                f.write(l + "\n")
        print(f"races-lists: wrote {len(lines)} lines to tb/timing/races_expected.txt")
    exp = read_cells(EXP, True)
    st = probes()
    bad = []
    for key, (pr, line) in exp.items():
        if pr not in st:
            bad.append(f"{pr}: not in docs/probes.txt ({line})")
        elif st[pr] == "landed":
            bad.append(f"{pr} is landed, its line is still there: {line}")
        if key in var:
            bad.append(f"in both lists: {line}")
    per = {}
    for key, (pr, _) in exp.items():
        per[pr] = per.get(pr, 0) + 1
    msg = (f"{len(var)} run-variable cells, {len(exp)} expected misses ("
           + ", ".join(f"{p} {n}" for p, n in sorted(per.items())) + f"), {len(st)} probes")
    if a.run:
        tot = equal = 0
        for t in TESTS:
            dd, n = diffs(a.run, t)
            tot += n
            for (p, c), (text, k) in dd.items():
                if (t, p, c) in var:
                    continue
                if (t, p, c) not in exp:
                    bad.append(f"{t} page {p} cell {c} ({text}): {k} pixels differ, not expected")
            for (tt, p, c), (pr, line) in exp.items():
                if tt == t and (p, c) not in dd:
                    bad.append(f"listed but now equal to the console (the list is stale): {line}")
            equal += n - len(dd)
        msg += f"; run {a.run}: {equal} of {tot} cells equal to the console"
    for b in bad[:40]:
        print("races-lists: " + b)
    print(f"races-lists: {msg}: {'PASS' if not bad else 'FAIL (%d problems)' % len(bad)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

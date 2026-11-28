#!/usr/bin/env python3
"""races_var.py: tb/timing/races_variable.txt, the race cells that vary from run to run on the console (PLAN 1.5, D5;
conventions.md 7.6.2): never compared.

    tools/timing/races_var.py [--dctests <dreamcast-tests>] [--runs <dir> <dir> ...] > tb/timing/races_variable.txt

Three sources, each line saying which:
  timing   the console's multi-run timing logs fit/accbuf_logs/accbuf_run1..6.log (accbuf's "T end / flush / stall" lines,
           console only; key = every number between the kind and "W": end v k, stall v fb, flush v fb n; 128 lines, the
           flush lines only in runs 3-6): a line whose least (end: min of t1 t2; stall: t[0]; flush: its best of three)
           differs between the runs by more than a poll quantum (28 counts, 14 clocks;
           0 = the event never came is a value too) varies. Lines "accbuf T <kind> <a> <b> | <min>..<max> counts over
           runs <list> | timing logs".
  pages    multi-run page archives (--runs: folders with page<n>.hw.raw[.gz] of the same test, at least 2): a labelled
           region whose words differ between runs varies. None is archived yet (PLAN 4: at least 3 runs of every *_races
           test, requested for MT8): with no --runs this source gives nothing.
  documented   the regions a test's own description says vary from run to run (no multi-run pictures exist to show it):
           accbuf_races (pvr-tests/accbuf/main.c, "Races (2026-11-17)": "different from one run to the next (page 7,
           pages 0 and 1 A-D, page 5 from its keep Z SEC WRITE on)"; accbuf_races' pages 4, 0 / 1, 3) and blendpos_races
           (README "Races": "damaged somewhere else every run": every region, judged only by the blendpos statistic,
           PLAN 1.5 / MT8). ptchunkcarry_races and ptchunkrun_races are "the same picture in two console runs" (README),
           keepz_races has no varying region stated: none of theirs is listed.
  Region lines "<test> <page> <cell> | <label> | <source>", the labels from the test's PC build (--labels).
"""
import argparse
import glob
import gzip
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
POLL = 28           # counts: a poll turn of 140 ns


def labels(dct, test):
    d = tempfile.mkdtemp(prefix="races_var_")
    exe = os.path.join(d, "pc")
    src = os.path.join(dct, "pvr-tests", test, "main.c")
    subprocess.run(["gcc", "-O1", "-w", "-I" + os.path.join(dct, "common"), "-o", exe, src], check=True)
    out = subprocess.run([exe, "--labels"], capture_output=True, text=True, check=True).stdout
    res = []
    for l in out.splitlines():
        if l.startswith("LABEL "):
            _, p, c, cw, ch, text = l.split(" ", 5)
            res.append((int(p), int(c), int(cw), int(ch), text))
    return res


def timing_lines(dct):
    """The key is every token between the kind and "W" (end / stall: 2 numbers, flush: 3); the value is the least of
    the numbers after "W" up to the first non-number (end: least of t1 t2; stall: t[0], already the least of the
    sorted nine; flush: the best of three, the only number before "P")."""
    runs = {}
    for f in sorted(glob.glob(os.path.join(dct, "fit", "accbuf_logs", "accbuf_run*.log"))):
        n = int(re.search(r"run(\d+)", f)[1])
        for line in open(f, errors="replace"):
            p = line.split()
            if len(p) < 4 or p[0] != "T" or "W" not in p:
                continue
            w = p.index("W")
            vals = []
            for t in p[w + 1:]:
                if not t.isdigit():
                    break
                vals.append(int(t))
            if w < 3 or not vals:
                continue
            runs.setdefault(tuple([p[1]] + [int(x) for x in p[2:w]]), {})[n] = min(vals)
    out = []
    for key in sorted(runs):
        v = runs[key]
        if len(v) >= 2 and max(v.values()) - min(v.values()) > POLL:
            out.append(f"accbuf T {' '.join(str(x) for x in key)} | {min(v.values())}..{max(v.values())} counts over runs "
                       f"{','.join(str(r) for r in sorted(v))} | timing logs fit/accbuf_logs")
    return out, len(runs)


def page(d, p):
    import numpy as np
    for name in (f"page{p}.hw.raw", f"page{p}.hw.raw.gz"):
        f = os.path.join(d, name)
        if os.path.exists(f):
            b = gzip.open(f).read() if f.endswith(".gz") else open(f, "rb").read()
            return np.frombuffer(b, dtype="<u4").reshape(480, 640)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dctests", default=os.path.join(os.path.dirname(ROOT), "dreamcast-tests"))
    ap.add_argument("--runs", nargs="*", default=[])
    a = ap.parse_args()
    dct = a.dctests
    print("# tb/timing/races_variable.txt: the race cells that vary from run to run on the console, never compared (PLAN 1.5,")
    print("# 5 D5). Written by tools/timing/races_var.py (its header: the three sources); do not edit by hand.")
    print("#   accbuf T <kind> <a> <b> [<n>] | <range> | timing logs    a console-only timing line of accbuf (flush: 3 numbers)")
    print("#   <test> <page> <cell> | <label> | <source>               a labelled region of a *_races test")
    tl, nt = timing_lines(dct)
    print(f"# timing: {len(tl)} of {nt} accbuf timing lines vary by more than {POLL} counts over fit/accbuf_logs runs 1-6 (least per line)")
    for l in tl:
        print(l)
    if a.runs:
        import numpy as np
        test = os.path.basename(os.path.normpath(a.runs[0]))
        lab = labels(dct, test)
        n = 0
        for p, c, cw, ch, text in lab:
            pages = [page(d, p) for d in a.runs]
            if any(x is None for x in pages):
                continue
            x0, y0 = (c % 20) * 32, (c // 20) * 32
            regs = [x[y0:y0 + 32 * ch, x0:x0 + 32 * cw] for x in pages]
            if any(not np.array_equal(regs[0], r) for r in regs[1:]):
                print(f"{test} {p} {c} | {text} | pages: {len(a.runs)} runs differ")
                n += 1
        print(f"# pages: {n} regions of {test} differ between {len(a.runs)} runs")
    else:
        print("# pages: no multi-run page archive (PLAN 4's request, MT8): nothing from this source")
    # documented
    lab = labels(dct, "accbuf_races")
    src = 'documented: pvr-tests/accbuf/main.c "Races (2026-11-17)"'
    n = 0
    for p, c, cw, ch, text in lab:
        var = False
        if p in (0, 1) and re.match(r"[A-D]: ", text):
            var, why = True, f"{src}: pages 0 and 1 A-D"
        elif p == 4 and not text.startswith("prime"):
            var, why = True, f"{src}: page 7 (accbuf_races' page 4)"
        elif p == 3 and c >= 10:
            var, why = True, f"{src}: page 5 from its keep Z SEC WRITE on (accbuf_races' page 3, cell 10 on)"
        if var:
            print(f"accbuf_races {p} {c} | {text} | {why}")
            n += 1
    print(f"# documented: {n} regions of accbuf_races")
    lab = labels(dct, "blendpos_races")
    for p, c, cw, ch, text in lab:
        print(f"blendpos_races {p} {c} | {text} | documented: README \"Races\": damaged somewhere else every run (the blendpos "
              f"statistic, PLAN 1.5)")
    print(f"# documented: {len(lab)} regions of blendpos_races (all)")


if __name__ == "__main__":
    main()

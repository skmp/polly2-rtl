#!/usr/bin/env python3
"""mutants.py: every planted bug must be caught (conventions.md 7.7, PLAN 0 rule 5). After shrike4 tb/v1_mutants.py.

    tools/gate/mutants.py <tb/<unit>/mutants.txt> [--jobs N] [--only ID,ID] [--probes P,P] [--keep]

The mutants file:

    @dir <folder> <MAKEVAR>     the source folder copied for every run, and the make variable its build reads it from
    @obj <MAKEVAR>              the make variable of the build's object folder (each run gets its own)
    @probe <name> <make target> <binary under the object folder> [args ...]
    <id> | <file in the folder> | <original fragment> | <mutated fragment> | <probe> [extra args] | <what it breaks>

In a fragment, \\n is a newline, \\| a bar and \\\\ a backslash. Lines that start with # are comments. A probe written
!<name> marks a mutant that must PASS the probe (a change the function must not see, e.g. a timing choice: PLAN M7's
per-tile barrier); it counts when it passes ("passes, as it must").

The control (the folder unchanged) builds and runs every probe the selected mutants use; each must pass. A mutant copies
the folder into build/mut/<unit>/<id>/src and replaces its original fragment, which must occur exactly once in the file
(so a mutant can never silently be the original); it builds the probe's target into build/mut/<unit>/<id>/obj and runs
the probe, and it is caught when the probe exits non-zero. A mutant that does not build is an error, not a catch.
--probes keeps the mutants whose probe is one of those named. Prints one line per mutant, then
"<unit>-mutants: <k> of <n> caught" and "<unit>-mutants: PASS" / "FAIL"; exits 1 if the control fails or any mutant
survives or does not build. <unit>: the mutants file's folder name.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s) and s[i + 1] in "n|\\":
            out.append({"n": "\n", "|": "|", "\\": "\\"}[s[i + 1]])
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def split_bars(line):
    """split on bars that are not escaped"""
    parts, cur, i = [], [], 0
    while i < len(line):
        if line[i] == "\\" and i + 1 < len(line):
            cur.append(line[i:i + 2])
            i += 2
        elif line[i] == "|":
            parts.append("".join(cur))
            cur = []
            i += 1
        else:
            cur.append(line[i])
            i += 1
    parts.append("".join(cur))
    return [p.strip() for p in parts]


def parse(path):
    cfg = {"dir": None, "obj": None, "probes": {}, "mutants": []}
    for n, raw in enumerate(open(path), 1):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("@dir "):
            folder, var = line.split()[1:3]
            cfg["dir"] = (folder, var)
        elif line.startswith("@obj "):
            cfg["obj"] = line.split()[1]
        elif line.startswith("@probe "):
            f = line.split()
            cfg["probes"][f[1]] = {"target": f[2], "binary": f[3], "args": f[4:]}
        else:
            p = split_bars(line)
            if len(p) != 6:
                sys.exit(f"{path}:{n}: a mutant needs 6 fields separated by bars, has {len(p)}")
            probe = p[4].split()
            must_pass = probe[0].startswith("!")
            cfg["mutants"].append({"id": p[0], "file": p[1], "orig": unescape(p[2]), "mut": unescape(p[3]),
                                   "probe": probe[0].lstrip("!"), "extra": probe[1:], "what": unescape(p[5]),
                                   "line": n, "pass": must_pass})
    if not cfg["dir"] or not cfg["obj"]:
        sys.exit(f"{path}: needs @dir and @obj")
    for m in cfg["mutants"]:
        if m["probe"] not in cfg["probes"]:
            sys.exit(f"{path}:{m['line']}: unknown probe {m['probe']}")
    return cfg


def run(cmd, log, env=None):
    with open(log, "a") as f:
        f.write("$ " + " ".join(cmd) + "\n")
        f.flush()
        return subprocess.call(cmd, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT, env=env)


def one(cfg, unit, rid, probes, edit, njobs):
    """build and run the probes on a copy of the folder, edited by edit (None: the control); per probe: the exit code
    of the run, or None if the build failed"""
    base = os.path.join(ROOT, "build", "mut", unit, rid)
    shutil.rmtree(base, ignore_errors=True)
    src, obj = os.path.join(base, "src"), os.path.join(base, "obj")
    folder, var = cfg["dir"]
    shutil.copytree(os.path.join(ROOT, folder), src)
    os.makedirs(obj, exist_ok=True)
    log = os.path.join(base, "log.txt")
    if edit:
        path = os.path.join(src, edit["file"])
        text = open(path).read()
        k = text.count(edit["orig"])
        if k != 1:
            return {"error": f"the original fragment occurs {k} times in {edit['file']}, not once"}
        open(path, "w").write(text.replace(edit["orig"], edit["mut"]))
    res = {}
    rel = lambda p: os.path.relpath(p, ROOT)
    for name in probes:
        pr = cfg["probes"][name]
        b = run(["make", "-s", pr["target"], f"{var}={rel(src)}", f"{cfg['obj']}={rel(obj)}", f"NJOBS={njobs}"], log)
        if b != 0:
            res[name] = None
            continue
        args = pr["args"] + (edit["extra"] if edit else [])
        res[name] = run([os.path.join(obj, pr["binary"])] + args, log)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mutants")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--njobs", type=int, default=2, help="NJOBS of each build")
    ap.add_argument("--only", default="")
    ap.add_argument("--probes", default="")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    cfg = parse(a.mutants)
    unit = os.path.basename(os.path.dirname(os.path.abspath(a.mutants)))
    ms = cfg["mutants"]
    if a.only:
        ids = set(a.only.split(","))
        ms = [m for m in ms if m["id"] in ids]
    if a.probes:
        ps = set(a.probes.split(","))
        ms = [m for m in ms if m["probe"] in ps]
    if not ms:
        print(f"{unit}-mutants: no mutants selected")
        print(f"{unit}-mutants: FAIL")
        return 1
    t0 = time.time()
    used = sorted({m["probe"] for m in ms})
    # the control: every probe the selection uses, one run each in parallel
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        ctl = dict(zip(used, ex.map(lambda p: one(cfg, unit, "control-" + p, [p], None, a.njobs)[p], used)))
    bad = False
    for p in used:
        ok = ctl[p] == 0
        bad |= not ok
        print(f"{unit}-mutants: control {p}: {'PASS' if ok else 'FAIL (' + ('build' if ctl[p] is None else 'exit ' + str(ctl[p])) + ')'}")
    if bad:
        print(f"{unit}-mutants: the control does not pass (build/mut/{unit}/control-*/log.txt)")
        print(f"{unit}-mutants: FAIL")
        return 1
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        results = list(ex.map(lambda m: one(cfg, unit, m["id"], [m["probe"]], m, a.njobs), ms))
    caught = 0
    for m, r in zip(ms, results):
        if "error" in r:
            verdict = "ERROR: " + r["error"]
        else:
            x = r[m["probe"]]
            if x is None:
                verdict = "ERROR: does not build"
            elif m["pass"]:
                verdict = "passes, as it must" if x == 0 else "CAUGHT (must pass)"
            else:
                verdict = "caught" if x != 0 else "SURVIVED"
        if verdict in ("caught", "passes, as it must"):
            caught += 1
            if not a.keep:
                shutil.rmtree(os.path.join(ROOT, "build", "mut", unit, m["id"]), ignore_errors=True)
        print(f"{unit}-mutants: {m['id']:24s} {verdict:12s} {m['probe']}: {m['what']}")
    if not a.keep:
        for p in used:
            shutil.rmtree(os.path.join(ROOT, "build", "mut", unit, "control-" + p), ignore_errors=True)
    print(f"{unit}-mutants: {caught} of {len(ms)} caught ({time.time() - t0:.0f} s)")
    ok = caught == len(ms)
    print(f"{unit}-mutants: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

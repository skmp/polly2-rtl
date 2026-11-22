#!/usr/bin/env python3
"""mutants.py: every planted bug must be caught (conventions.md 7.7, PLAN 0 rule 5). After shrike4 tb/v1_mutants.py.

    tools/gate/mutants.py <tb/<unit>/mutants.txt> [--jobs J] [--njobs B] [--only ID,ID] [--probes P,P] [--keep]
                          [--cost <file>]

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

One queue (PLAN 0 rule 8; tools/gate/pqlib.py): J slots (--jobs, default tools/gate/jobs.sh's) shared by the builds, each holding
B slots (--njobs: its make NJOBS), and the probe runs, one slot each. A probe whose arguments name a case list (@<file>)
runs as one item per case (`--shard i/N`, N the list's cases: the testbenches seed per case from its index in the list,
so the case runs as it does in the whole list); its verdict is the items' (it fails iff one of them fails; the first
failure of a mutant drops its other items). A probe with --threads T (or an unsplit one with --jobs T) holds T slots.
Runs go before builds, and the items longest first, by --cost (the control's seconds per item and the builds' seconds of
the last run, written back at the end) or else by order. The control's builds start first; if the control fails, the
mutants are dropped. Ends with "<unit>-mutants: wall <w> s, CPU <c> s, J <j>, utilisation <u> %, slowest <what> <s> s".
"""
import argparse
import os
import shutil
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pqlib  # noqa: E402

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


def case_count(path):
    """the cases of a list file as the testbenches read it (tb/isp_tile, tb/ref: lines without the trailing newline and
    spaces, empty ones and those starting with # skipped)"""
    n = 0
    for line in open(os.path.join(ROOT, path)):
        l = line.rstrip("\n ")
        if l and not l.startswith("#"):
            n += 1
    return n


def plan_runs(args):
    """the run items of a probe's arguments: [(item id, args, slots)]"""
    lists = [x for x in args if x.startswith("@")]
    if len(lists) == 1:
        n = case_count(lists[0][1:])
        return [(str(i), args + ["--shard", f"{i}/{n}"], 1) for i in range(n)]
    slots = 1
    for flag in ("--threads", "--jobs"):
        if flag in args and args.index(flag) + 1 < len(args):
            try:
                slots = max(slots, int(args[args.index(flag) + 1]))
            except ValueError:
                pass
    return [("all", args, slots)]


class Mutant:
    """a mutant (edit) or a control (edit None) on one probe: its build and its run items"""

    def __init__(self, rid, probe, edit):
        self.rid, self.probe, self.edit = rid, probe, edit
        self.build = None           # None: not built yet; False: build failed; True: built
        self.error = None
        self.items = {}             # item id -> exit code
        self.n = 0
        self.failed = False
        self.lock = threading.Lock()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mutants")
    ap.add_argument("--jobs", type=int, default=0, help="the queue's slots (tools/gate/jobs.sh)")
    ap.add_argument("--njobs", type=int, default=2, help="NJOBS of each build, the slots it holds")
    ap.add_argument("--only", default="")
    ap.add_argument("--probes", default="")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--cost", default="")
    a = ap.parse_args()
    cfg = parse(a.mutants)
    unit = os.path.basename(os.path.dirname(os.path.abspath(a.mutants)))
    grp = os.path.basename(a.mutants)
    J = a.jobs or pqlib.default_jobs()
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
    t0 = time.monotonic()
    cost = pqlib.read_cost(a.cost) if a.cost else {}
    pool = pqlib.Pool(J)
    used = sorted({m["probe"] for m in ms})
    folder, var = cfg["dir"]
    rel = lambda p: os.path.relpath(p, ROOT)
    times = []                      # (cost id, wall, cpu) of the control's items and of every build
    tlock = threading.Lock()
    slow = ["", 0.0]
    cpu_sum = [0.0]

    def note(what, wall, cpu):
        with tlock:
            cpu_sum[0] += cpu
            if wall > slow[1]:
                slow[0], slow[1] = what, wall

    controls = {p: Mutant("control-" + p, p, None) for p in used}
    mutants = [Mutant(m["id"], m["probe"], m) for m in ms]

    def finish_item(mu, iid, st, wall, cpu, control):
        note(f"{mu.rid} {iid}", wall, cpu)
        if control:
            with tlock:
                times.append((f"run:{mu.probe}:{iid}", wall, cpu))
        with mu.lock:
            if st is None:
                return
            mu.items[iid] = st
            if st != 0 and not mu.failed:
                mu.failed = True
                if not control:
                    pool.cancel(mu.rid)     # one failure decides a mutant
            if control and st != 0:
                for x in mutants:           # the control fails: nothing else counts
                    pool.cancel(x.rid)

    def build_task(mu):
        def fn():
            if mu.edit is not None and any(c.failed or c.build is False for c in controls.values()):
                return
            base = os.path.join(ROOT, "build", "mut", unit, mu.rid)
            shutil.rmtree(base, ignore_errors=True)
            src, obj = os.path.join(base, "src"), os.path.join(base, "obj")
            shutil.copytree(os.path.join(ROOT, folder), src)
            os.makedirs(obj, exist_ok=True)
            log = os.path.join(base, "log.txt")
            if mu.edit:
                path = os.path.join(src, mu.edit["file"])
                text = open(path).read()
                k = text.count(mu.edit["orig"])
                if k != 1:
                    mu.error = f"the original fragment occurs {k} times in {mu.edit['file']}, not once"
                    mu.build = False
                    return
                open(path, "w").write(text.replace(mu.edit["orig"], mu.edit["mut"]))
            pr = cfg["probes"][mu.probe]
            st, wall, cpu = pqlib.run_cmd(pool, ["make", "-s", pr["target"], f"{var}={rel(src)}",
                                                 f"{cfg['obj']}={rel(obj)}", f"NJOBS={a.njobs}"], log, cwd=ROOT,
                                          group=mu.rid, mode="a")
            note(f"{mu.rid} build", wall, cpu)
            with tlock:
                times.append((f"build:{mu.probe}", wall, cpu))
            if st is None:
                return
            mu.build = st == 0
            if not mu.build:
                if mu.edit is None:
                    for x in mutants:
                        pool.cancel(x.rid)
                return
            args = pr["args"] + (mu.edit["extra"] if mu.edit else [])
            runs = plan_runs(args)
            mu.n = len(runs)
            for iid, rargs, slots in runs:
                c = cost.get((grp, f"run:{mu.probe}:{iid}"), 1.0)
                pool.submit(1e9 + c, slots, run_task(mu, iid, [os.path.join(obj, pr["binary"])] + rargs,
                                                     os.path.join(base, f"run_{iid}.txt")), group=mu.rid)
        return fn

    def run_task(mu, iid, cmd, log):
        def fn():
            st, wall, cpu = pqlib.run_cmd(pool, cmd, log, cwd=ROOT, group=mu.rid, mode="a")
            finish_item(mu, iid, st, wall, cpu, mu.edit is None)
        return fn

    for p in used:
        c = cost.get((grp, f"build:{p}"), 60.0)
        pool.submit(1e8 + c, a.njobs, build_task(controls[p]), group=controls[p].rid)
    for i, mu in enumerate(mutants):
        c = cost.get((grp, f"build:{mu.probe}"), 60.0)
        pool.submit(1e6 + c - i * 1e-3, a.njobs, build_task(mu), group=mu.rid)
    pool.wait()
    for e in pool.errors:
        print(f"{unit}-mutants: queue error: {e}")

    bad = bool(pool.errors)
    for p in used:
        c = controls[p]
        ok = c.build is True and len(c.items) == c.n and all(x == 0 for x in c.items.values())
        bad |= not ok
        why = "build" if c.build is not True else ", ".join(f"item {k} exit {v}" for k, v in sorted(c.items.items()) if v)
        print(f"{unit}-mutants: control {p}: {'PASS' if ok else 'FAIL (' + (why or 'incomplete') + ')'}")
    wall = time.monotonic() - t0
    stat = (f"{unit}-mutants: wall {wall:.1f} s, CPU {cpu_sum[0]:.1f} s, J {J}, utilisation "
            f"{100.0 * cpu_sum[0] / (wall * J) if wall > 0 else 0:.0f} %, slowest {slow[0] or '-'} {slow[1]:.1f} s")
    if a.cost:
        agg = {}
        for k, w, c in times:
            if k.startswith("build:") and k in agg:
                w, c = max(w, agg[k][0]), max(c, agg[k][1])
            agg[k] = (w, c)
        pqlib.write_cost(a.cost, [(grp, k, w, c) for k, (w, c) in agg.items()], {grp})
    if bad:
        print(f"{unit}-mutants: the control does not pass (build/mut/{unit}/control-*/log.txt)")
        print(stat)
        print(f"{unit}-mutants: FAIL")
        return 1
    caught = 0
    for mu in mutants:
        m = mu.edit
        if mu.error:
            verdict = "ERROR: " + mu.error
        elif mu.build is not True:
            verdict = "ERROR: does not build"
        else:
            failed = any(x != 0 for x in mu.items.values())
            complete = len(mu.items) == mu.n
            if m["pass"]:
                verdict = "passes, as it must" if complete and not failed else "CAUGHT (must pass)"
            elif failed:
                verdict = "caught"
            else:
                verdict = "SURVIVED" if complete else "ERROR: runs incomplete"
        if verdict in ("caught", "passes, as it must"):
            caught += 1
            if not a.keep:
                shutil.rmtree(os.path.join(ROOT, "build", "mut", unit, m["id"]), ignore_errors=True)
        print(f"{unit}-mutants: {m['id']:24s} {verdict:12s} {m['probe']}: {m['what']}")
    if not a.keep:
        for p in used:
            shutil.rmtree(os.path.join(ROOT, "build", "mut", unit, "control-" + p), ignore_errors=True)
    print(f"{unit}-mutants: {caught} of {len(ms)} caught ({wall:.0f} s)")
    print(stat)
    ok = caught == len(ms)
    print(f"{unit}-mutants: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

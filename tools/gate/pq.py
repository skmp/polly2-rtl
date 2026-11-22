#!/usr/bin/env python3
"""pq.py: run a gate's work items on one queue of J workers and merge the verdicts (PLAN 0 rule 8; conventions.md 7.8:
a failing item never stops the others, the merged report decides). It replaces the static --shard k/N slices of
run_shards.sh: a free worker takes the next item, longest first.

    tools/gate/pq.py --name <name> --dir <log dir> [--jobs J] [--cost <file>] [--cancel-group-on-fail] <items file>

The items file, one item a line, tab-separated:

    <group> <id> <estimate> <slots> <kind> <log> <command>

  group     the items' set, reported on its own (a gate step: phase-halt, free-running, fp-add-full, ...)
  id        the item's name in its group, stable from run to run (the cost file's key): a case, case/r3-5, 7/96, ...
  estimate  its cost in seconds when the cost file has none (a static estimate)
  slots     the workers it occupies (1; a build of make -jB or a tool with B threads: B)
  kind      tb: passes iff it exits 0 and its last line ends in ": PASS"; step: passes iff it exits 0
  log       its output, relative to the log dir
  command   run by bash -c in the current folder

A group of one step item prints "<group>: PASS (<wall> s, CPU <c> s)" (or FAIL) instead.
Order: by the cost file's wall seconds of the item in the last run of the same gate (--cost), else the estimate,
largest first. At the end the cost file gets this run's wall and CPU seconds of every item (the groups run replace their
old entries). Prints, per group in order of appearance: each failed item's last 30 lines; the summed "<n> checks, <m>
failures" lines and ": section <name> <n> cases" lines of its logs; "<group>: <n> items, <c> checks, <f> failures (span
<s> s, CPU <c> s; slowest <id> <s> s)" and "<group>: PASS" / "FAIL"; then "<name>: wall <w> s, CPU <c> s, J <j>,
utilisation <u> %, slowest <group> <id> <s> s" and "<name>: PASS" / "FAIL" (the exit code to match: PASS iff every
item passes). <dir>/pq_results.tsv: group, id, verdict, wall, CPU, start, end (seconds from the queue's start) per item.
--cancel-group-on-fail: the first failure of a group drops the group's other items (a mutant's probe: one failure
decides).
"""
import argparse
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pqlib  # noqa: E402

CHK = re.compile(r": (\d+) checks, (\d+) failures$")


def last_lines(path, n):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 65536))
            return f.read().decode("utf-8", "replace").splitlines()[-n:]
    except OSError:
        return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("items")
    ap.add_argument("--name", required=True)
    ap.add_argument("--dir", required=True)
    ap.add_argument("--jobs", type=int, default=0)
    ap.add_argument("--cost", default="")
    ap.add_argument("--cancel-group-on-fail", action="store_true")
    a = ap.parse_args()
    J = a.jobs or pqlib.default_jobs()
    cost = pqlib.read_cost(a.cost) if a.cost else {}
    items, groups = [], []
    for n, line in enumerate(open(a.items), 1):
        line = line.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        f = line.split("\t", 6)
        if len(f) != 7 or f[4] not in ("tb", "step"):
            sys.exit(f"pq: {a.items}:{n}: <group> <id> <estimate> <slots> <tb|step> <log> <command>, tab-separated")
        it = {"group": f[0], "id": f[1], "est": float(f[2]), "slots": int(f[3]), "kind": f[4],
              "log": os.path.join(a.dir, f[5]), "cmd": f[6]}
        it["prio"] = cost.get((it["group"], it["id"]), it["est"])
        items.append(it)
        if it["group"] not in groups:
            groups.append(it["group"])
    for it in items:
        os.makedirs(os.path.dirname(it["log"]), exist_ok=True)
    pool = pqlib.Pool(J)
    t0 = time.monotonic()

    def job(it):
        def fn():
            it["start"] = time.monotonic() - t0
            st, wall, cpu = pqlib.run_cmd(pool, it["cmd"], it["log"], group=it["group"])
            it["end"] = time.monotonic() - t0
            it["wall"], it["cpu"] = wall, cpu
            if st is None:
                it["verdict"] = "cancelled"
                return
            ok = st == 0
            if ok and it["kind"] == "tb":
                ll = last_lines(it["log"], 1)
                ok = bool(ll) and ll[-1].endswith(": PASS")
            it["verdict"] = "PASS" if ok else "FAIL"
            it["exit"] = st
            if not ok and a.cancel_group_on_fail:
                pool.cancel(it["group"])
        return fn

    for it in items:
        it.update(verdict="cancelled", wall=0.0, cpu=0.0, start=0.0, end=0.0)
        pool.submit(it["prio"], it["slots"], job(it), group=it["group"])
    pool.wait()
    wall = time.monotonic() - t0
    ok_all = not pool.errors
    for e in pool.errors:
        print(f"{a.name}: queue error: {e}")
    for g in groups:
        gi = [it for it in items if it["group"] == g]
        checks = fails = 0
        sections = {}
        for it in gi:
            if it["verdict"] == "FAIL":
                print(f"{g}: {'' if it['id'] == '-' else 'item ' + it['id'] + ' '}did not pass (exit {it.get('exit')}; {os.path.relpath(it['log'])}):")
                for l in last_lines(it["log"], 30):
                    print("    " + l)
            try:
                lines = open(it["log"], errors="replace").read().splitlines()
            except OSError:
                lines = []
            for l in reversed(lines):
                m = CHK.search(l)
                if m:
                    checks += int(m.group(1))
                    fails += int(m.group(2))
                    break
            for l in lines:
                if ": section " in l:
                    w = l.split()
                    if len(w) >= 4 and w[3].isdigit():
                        sections[w[2]] = sections.get(w[2], 0) + int(w[3])
        for k in sorted(sections):
            print(f"  section {k} {sections[k]} cases")
        bad = [it for it in gi if it["verdict"] != "PASS"]
        ok_all = ok_all and not bad
        if len(gi) == 1 and gi[0]["kind"] == "step":
            it = gi[0]
            print(f"{g}: {'PASS' if not bad else 'FAIL'} ({it['wall']:.1f} s, CPU {it['cpu']:.1f} s"
                  + (f", exit {it.get('exit')}" if bad else "") + ")")
            continue
        cancelled = sum(1 for it in gi if it["verdict"] == "cancelled")
        span = max(it["end"] for it in gi) - min(it["start"] for it in gi) if gi else 0.0
        cpu = sum(it["cpu"] for it in gi)
        slow = max(gi, key=lambda it: it["wall"])
        extra = f", {cancelled} cancelled" if cancelled else ""
        print(f"{g}: {len(gi)} items, {checks} checks, {fails} failures (span {span:.1f} s, CPU {cpu:.1f} s; slowest "
              f"{slow['id']} {slow['wall']:.1f} s{extra})")
        print(f"{g}: {'PASS' if not bad else 'FAIL'}")
    with open(os.path.join(a.dir, "pq_results.tsv"), "w") as f:
        for it in items:
            f.write(f"{it['group']}\t{it['id']}\t{it['verdict']}\t{it['wall']:.2f}\t{it['cpu']:.2f}\t{it['start']:.2f}\t"
                    f"{it['end']:.2f}\n")
    if a.cost:
        pqlib.write_cost(a.cost, [(it["group"], it["id"], it["wall"], it["cpu"]) for it in items
                                  if it["verdict"] in ("PASS", "FAIL")], set(groups))
    cpu = sum(it["cpu"] for it in items)
    slow = max(items, key=lambda it: it["wall"]) if items else None
    util = 100.0 * cpu / (wall * J) if wall > 0 else 0.0
    print(f"{a.name}: wall {wall:.1f} s, CPU {cpu:.1f} s, J {J}, utilisation {util:.0f} %"
          + (f", slowest {slow['group']}{'' if slow['id'] == '-' else ' ' + slow['id']} {slow['wall']:.1f} s"
             if slow else ""))
    print(f"{a.name}: {'PASS' if ok_all else 'FAIL'}")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())

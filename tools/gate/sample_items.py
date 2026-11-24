#!/usr/bin/env python3
"""sample_items.py: a seeded SAMPLE of a full gate's work items (the owner's rule from M9 on: exhaustive gates run as
samples each milestone and in full only once, after the last milestone; PLAN 0 rule 10).

    tools/gate/sample_items.py --seed S --gate <gate> --budget <wall s> [--jobs J] [--cost <file>]
                               [--always tools/gate/always_run.txt] [--whole <group,...>] [--every <group,...>]
                               [--prefix <group>:<renders>] [--case-key render|stream] [--scale [<group>:]X ...]
                               <items in> <items out>
    tools/gate/sample_items.py --coverage <pq_results.tsv> [--cost <file>] [--scale ...] <items in> <items out>

The input is the full gate's items file (tools/gate/pq.py's format, as gate_isp_tile.sh / gate_sort.sh write it); the
output keeps:
  1. every item of the --whole groups (a group exercising the milestone's own modules);
  2. every item the always-run file names (a line "<gate> <group> <id regex>": anything that ever failed stays in every
     sample); a line of this gate that names no item is an error (exit 1: the sample would silently lose it);
  3. every case at least once for the --every groups: a case's item drawn at random from its items (a case: the item's
     id without its /r<A>-<B> render range, --case-key render; or a stream's case with its SPAN_SORT_CFG group merged,
     --case-key stream: one of the configurations). Where a group's items are whole cases (phase-halt), every item of
     the group is kept, in full. --prefix <group>:<R> (isp-tile-full's SAMPLE_PH_RENDERS only,
     not a default: an open decision of the owner's, PLAN D12)
     would cut the group's cases longer than R renders to their first R renders (`--renders 0-<R-1>`);
  4. then items drawn at random (seeded) from the rest while the predicted wall stays within the budget (predicted CPU
     seconds within budget x J x 0.85). These are the OPTIONAL items, listed in <items out>.optional
     ("<group>\t<id>"): tools/gate/pq.py --optional ... --deadline <budget> starts one only while its predicted end is
     within the budget, so a slow machine (this box runs from 1x to 3x, load and power) drops some instead of
     overrunning; the coverage of what ran is the --coverage line.
An item's predicted seconds: the cost file's (the last run's wall), else its static estimate times --scale (per group
with <group>:X, else all). The estimates are written into <items out> (the queue's order and the deadline use them).
Calibration (measured wall / static estimate, every cost file of agents/gates, m8, m9, verify-m9): phase-halt 0.07 ..
0.48, free-running 0.35 .. 1.81 (2026-11-23's clean-tree runs: phase-halt 0.21 and 0.22 in full, free-running 0.90);
the gates pass phase-halt:0.25 and free-running:1.0 to isp-tile-full, subset 0.35 and random 9 to sort-full.
Items predicted from static estimates are counted in the output (a run with no cost file says so).
The mandatory items (1-3) are never dropped; where they alone are predicted over the budget, a "sample: WARNING" line
says so. The choice depends only on the seed, the items and the cost file, never on what ran. Prints "sample: ..."
lines: the seed, the items and the weight kept (all and per group, %), the always-run items, the predicted wall.
--coverage: the same per-group lines for the items that ran (pq_results.tsv's PASS / FAIL), the optional items the
deadline dropped counted.
"""
import argparse
import os
import random
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pqlib  # noqa: E402


def case_of(iid, key):
    c = re.sub(r"/r\d+-\d+$", "", iid)
    if key == "stream":
        c = re.sub(r"\.r\d+-\d+\.rs\.gz$", "", os.path.basename(c))
    return c


def renders_of(case):
    n = 0
    while os.path.isdir(os.path.join(case, f"r{n}")):
        n += 1
    return n


def read_items(path):
    items = []
    for line in open(path):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 7:
            items.append(f)
    return items


def scales(specs):
    """--scale [<group>:]X ...: {group or "": X}"""
    sc = {"": 1.0}
    for p in specs:
        g, _, x = p.rpartition(":")
        sc[g] = float(x)
    return sc


def predictor(cost, sc):
    def est(g, iid, e):
        c = cost.get((g, iid))
        return float(c) if c is not None else float(e) * sc.get(g, sc[""])
    return est


def group_order(items):
    groups = []
    for it in items:
        if it[0] not in groups:
            groups.append(it[0])
    return groups


def coverage(a):
    """the per-group coverage of what ran: the sample's items (items out) whose pq_results.tsv verdict is PASS or FAIL,
    against the full gate's items (items in), weights as predicted"""
    est = predictor(pqlib.read_cost(a.cost) if a.cost else {}, scales(a.scale))
    full = read_items(a.items_in)
    samp = read_items(a.items_out)
    res = {}
    for line in open(a.coverage):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 3:
            res[(f[0], f[1])] = f[2]
    # the weights as the sample predicted them: a full item's from its own estimate; the sample's estimate column is
    # already a prediction (written by the sample step), used as it is for a cut of a full item (a render range)
    wmap = {(it[0], it[1]): est(it[0], it[1], it[2]) * float(it[3]) for it in full}

    def w(it):
        k = (it[0], it[1])
        return wmap[k] if k in wmap else float(it[2]) * float(it[3])
    ran = [it for it in samp if res.get((it[0], it[1])) in ("PASS", "FAIL")]
    dropped = [it for it in samp if res.get((it[0], it[1])) == "skipped"]
    wfull = sum(wmap.values())
    wran = sum(w(it) for it in ran)
    print(f"sample: ran {len(ran)} of {len(full)} items, {100.0 * wran / wfull if wfull else 0:.1f} % of the weight "
          f"({wran:.0f} of {wfull:.0f} predicted s); {len(dropped)} optional items not started (the deadline)")
    for g in group_order(full):
        n = sum(1 for it in full if it[0] == g)
        wg = sum(w(it) for it in full if it[0] == g)
        r = [it for it in ran if it[0] == g]
        wr = sum(w(it) for it in r)
        d = sum(1 for it in dropped if it[0] == g)
        print(f"sample: ran {g}: {len(r)} of {n} items, {100.0 * wr / wg if wg else 0:.1f} % of its weight"
              + (f"; {d} not started (the deadline)" if d else ""))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int)
    ap.add_argument("--gate", default="")
    ap.add_argument("--budget", type=float, default=0.0)
    ap.add_argument("--jobs", type=int, default=0)
    ap.add_argument("--cost", default="")
    ap.add_argument("--always", default="")
    ap.add_argument("--whole", default="")
    ap.add_argument("--every", default="")
    ap.add_argument("--prefix", action="append", default=[])
    ap.add_argument("--case-key", default="render", choices=("render", "stream"))
    ap.add_argument("--scale", action="append", default=[])
    ap.add_argument("--coverage", default="")
    ap.add_argument("items_in")
    ap.add_argument("items_out")
    a = ap.parse_args()
    if a.coverage:
        return coverage(a)
    if a.seed is None or not a.gate or a.budget <= 0:
        ap.error("--seed, --gate and --budget are required")
    J = a.jobs or pqlib.default_jobs()
    rnd = random.Random(a.seed)
    items = read_items(a.items_in)
    cost = pqlib.read_cost(a.cost) if a.cost else {}
    sc = scales(a.scale)
    pred = predictor(cost, sc)

    def est(it):
        return pred(it[0], it[1], it[2])

    whole = set(g for g in a.whole.split(",") if g)
    every = set(g for g in a.every.split(",") if g)
    prefix = {}
    for p in a.prefix:
        g, _, r = p.partition(":")
        prefix[g] = int(r)
    always = []
    if a.always and os.path.exists(a.always):
        for n, line in enumerate(open(a.always), 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            w = line.split(None, 2)
            if len(w) == 3 and w[0] == a.gate:
                always.append((n, w[1], w[2], re.compile(w[2])))

    keep = [False] * len(items)
    why = [""] * len(items)
    hits = {n: 0 for n, _, _, _ in always}
    for i, it in enumerate(items):
        if it[0] in whole:
            keep[i], why[i] = True, "whole"
        for n, g, _, r in always:
            if g == it[0] and r.search(it[1]):
                hits[n] += 1
                if not keep[i]:
                    keep[i], why[i] = True, "always"
    # every case once (in the --every groups); the prefix rewrite of long cases
    out_items = [list(it) for it in items]
    by_case = {}
    for i, it in enumerate(items):
        if it[0] in every:
            g = "" if a.case_key == "stream" else it[0]
            by_case.setdefault((g, case_of(it[1], a.case_key)), []).append(i)
    for (g, c), idx in sorted(by_case.items()):
        if any(keep[i] for i in idx):
            continue
        i = idx[rnd.randrange(len(idx))]
        keep[i], why[i] = True, "case"
    for g, R in prefix.items():
        for i, it in enumerate(items):
            if it[0] != g or not keep[i] or why[i] == "always" or "--renders" in it[6]:
                continue
            m = re.search(r"@(\S+)", it[6])
            ci = re.search(r"--shard (\d+)/(\d+)", it[6])
            if not m or not ci:
                continue
            cases = [l.strip() for l in open(m.group(1)) if l.strip() and not l.startswith("#")]
            c = cases[int(ci.group(1))]
            n = renders_of(c)
            if n > R:
                o = out_items[i]
                o[1] = f"{it[1]}/r0-{R - 1}"
                o[2] = f"{float(it[2]) * R / n:.2f}"
                o[5] = re.sub(r"\.txt$", f".r0-{R - 1}.txt", it[5])
                o[6] = it[6].replace(" --shard ", f" --renders 0-{R - 1} --shard ", 1)
                why[i] = "prefix"
    budget_cpu = a.budget * J * 0.85
    used = sum(est(out_items[i]) * float(out_items[i][3]) for i in range(len(items)) if keep[i])
    mandatory = used
    rest = [i for i in range(len(items)) if not keep[i]]
    rnd.shuffle(rest)
    for i in rest:
        c = est(items[i]) * float(items[i][3])
        if used + c <= budget_cpu:
            keep[i], why[i] = True, "random"
            used += c
    total = sum(est(it) * float(it[3]) for it in items)
    nstatic = 0
    with open(a.items_out, "w") as o, open(a.items_out + ".optional", "w") as oo:
        for i in range(len(items)):
            if keep[i]:
                it = list(out_items[i])
                if (it[0], it[1]) not in cost:
                    nstatic += 1
                it[2] = f"{est(it):.2f}"        # the predicted seconds: the queue's order and its deadline
                o.write("\t".join(it) + "\n")
                if why[i] == "random":
                    oo.write(f"{it[0]}\t{it[1]}\n")
    nk = sum(keep)
    wk = sum(est(out_items[i]) * float(out_items[i][3]) for i in range(len(items)) if keep[i])
    print(f"sample: seed {a.seed}: {nk} of {len(items)} items, {100.0 * wk / total if total else 0:.1f} % of the weight "
          f"({wk:.0f} of {total:.0f} predicted CPU s); budget {a.budget:.0f} s wall at J {J} ({budget_cpu:.0f} CPU s), "
          f"predicted wall >= {wk / J:.0f} s")
    print(f"sample: predictions: {nk - nstatic} items from the cost file ({os.path.relpath(a.cost) if a.cost else 'none'}), {nstatic} from static "
          f"estimates (scale {', '.join(f'{g or 'all'} {x:g}' for g, x in sc.items())})"
          + ("; no cost file: the first run's predictions are rough, the deadline holds the optional items" if not cost
             else ""))
    if mandatory > budget_cpu:
        print(f"sample: WARNING: the mandatory items alone are predicted at {mandatory:.0f} CPU s, over the budget's "
              f"{budget_cpu:.0f} (>= {mandatory / J:.0f} s wall at J {J}): no optional item drawn")
    for g in group_order(items):
        idx = [i for i in range(len(items)) if items[i][0] == g]
        k = [i for i in idx if keep[i]]
        wg = sum(est(items[i]) * float(items[i][3]) for i in idx)
        wkg = sum(est(out_items[i]) * float(out_items[i][3]) for i in k)
        tags = {}
        for i in k:
            tags[why[i]] = tags.get(why[i], 0) + 1
        print(f"sample: {g}: {len(k)} of {len(idx)} items, {100.0 * wkg / wg if wg else 0:.1f} % of its weight ("
              + ", ".join(f"{v} {t}" for t, v in sorted(tags.items())) + ")")
    # (an item an always-run line names may already be in the sample as its group's whole: it runs all the same, and is
    # counted under that reason; "drawn for the list" are the items the list alone added)
    print(f"sample: always-run ({a.always or 'none'}): {len(always)} lines of this gate name {sum(hits.values())} items, "
          f"every one run ({sum(1 for w in why if w == 'always')} drawn for the list alone, the others already in the "
          f"sample: their group whole)")
    bad = [(n, g, rx) for n, g, rx, _ in always if hits[n] == 0]
    for n, g, rx in bad:
        print(f"sample: always-run FAIL: {a.always}:{n} ({g} {rx}) names no item of the full gate")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""races_expected.py: the pinned list of VRAM-race renders, tb/frames/races_expected.txt (PLAN 5 D13, option (a), decided
2026-11-26): a render the hazard detector flags (ARCHITECTURE 3.2.1) is still compared in its own class, never a pass or a
fail, but the gate fails when such a render enters or leaves the list or its difference count changes.

    tools/gate/races_expected.py --gate frames|frames-hw [--write] [--selftest] <item logs ...>

frames: the logs of tools/gate/frames_run.sh (frames_cmp.py): "frames_cmp: <case> <cfg>: r<k>: VRAM-race (...): <n> words
differ (their own class)" a race render, "frames_cmp: <case> <cfg>: <n> renders, ..." a case that ran. frames-hw: the logs
of tools/gate/frames_hw_run.sh (frames_hw_cmp.py): "frames_hw: <kind>:<name> <cfg>: VRAM-race renders r<i> ..." an item's
race renders, its count the sum of its "... (their own class)" lines (pixels, words, readbacks that differ after them;
they cannot be told apart by render), "frames_hw: <kind>:<name> <cfg>: ...; <c> checks, <f> failures" an item that ran.

The list, one line a race render (frames) or a race item (frames-hw):
    frames <case> <cfg> r<k> <words that differ | equal>
    frames-hw <kind>:<name> <cfg> r<i>[,r<j>...] <differences in the race class | equal>
Only the cases (items) that ran in this gate run are checked, and of a frames case only the renders it ran (make frames
runs a test's first 8); the lines of the others stay (a sampled gate runs a part).
--write: the lines of the cases that ran replaced by what they gave (the list built from an accepted run; review the
diff). --selftest: the check must fail on a changed count, a dropped line and an extra line (made on a copy). Prints one
line a difference and "races-expected: <gate>: <n> race renders in <m> cases that ran, <l> lines listed for them: PASS" or
FAIL; exit 1 on a difference.
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIST = os.path.join(ROOT, "tb", "frames", "races_expected.txt")
RE_F_RACE = re.compile(r"^frames_cmp: (\S+) (\S+): r(\d+): VRAM-race \(.*\): (\d+) words differ")
RE_F_RAN = re.compile(r"^frames_cmp: (\S+) (\S+): (\d+) renders, ")
RE_H_RACE = re.compile(r"^frames_hw: (\S+) (\S+): VRAM-race renders (.*)$")
RE_H_RAN = re.compile(r"^frames_hw: (\S+) (\S+): .*; \d+ checks, \d+ failures$")
RE_H_CLS = re.compile(r"^frames_hw: (\S+) (\S+): (?:VRAM-race page \d+ .*?: )?(\d+) .*\(their own class\)$")


def observe(gate, logs):
    ran, seen, nr = set(), {}, {}
    for p in logs:
        try:
            lines = open(p, errors="replace").read().splitlines()
        except OSError:
            continue
        cls, rr = {}, {}
        for l in lines:
            if gate == "frames":
                m = RE_F_RAN.match(l)
                if m:
                    ran.add((m[1], m[2]))
                    nr[(m[1], m[2])] = int(m[3])
                m = RE_F_RACE.match(l)
                if m:
                    seen[(m[1], m[2], f"r{m[3]}")] = "equal" if m[4] == "0" else m[4]
            else:
                m = RE_H_RAN.match(l)
                if m and "VRAM-race renders" not in l:
                    ran.add((m[1], m[2]))
                m = RE_H_RACE.match(l)
                if m:
                    rr[(m[1], m[2])] = ",".join(m[3].split())
                    continue
                m = RE_H_CLS.match(l)
                if m:
                    cls[(m[1], m[2])] = cls.get((m[1], m[2]), 0) + int(m[3])
        for k, r in rr.items():
            n = cls.get(k, 0)
            seen[(k[0], k[1], r)] = "equal" if n == 0 else str(n)
    return ran, seen, nr


def read_list(gate):
    out, other = {}, []
    if os.path.exists(LIST):
        for l in open(LIST):
            w = l.split()
            if len(w) == 5 and w[0] == gate:
                out[(w[1], w[2], w[3])] = w[4]
            else:
                other.append(l.rstrip("\n"))
    return out, other


def compare(listed, ran, seen, nr):
    bad = []
    for k, v in sorted(seen.items()):
        if k not in listed:
            bad.append(f"enters the list: {' '.join(k)} {v}")
        elif listed[k] != v:
            bad.append(f"its count changes: {' '.join(k)} {listed[k]} -> {v}")
    for k, v in sorted(listed.items()):
        # a render that ran: frames' renders r0 .. r(n-1) of the case (a quick gate's cases run their first renders
        # only, FRAMES_MAX_RENDERS); a frames-hw item's line, whenever the item ran
        if (k[0], k[1]) in ran and k not in seen and ((k[0], k[1]) not in nr or int(k[2].split(",")[0][1:]) < nr[(k[0], k[1])]):
            bad.append(f"leaves the list: {' '.join(k)} {v} (no VRAM-race render there now)")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gate", required=True, choices=["frames", "frames-hw"])
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("logs", nargs="*")
    a = ap.parse_args()
    ran, seen, nr = observe(a.gate, a.logs)
    listed, other = read_list(a.gate)
    if a.write:
        keep = {k: v for k, v in listed.items()
                if (k[0], k[1]) not in ran or ((k[0], k[1]) in nr and int(k[2].split(",")[0][1:]) >= nr[(k[0], k[1])])}
        keep.update(seen)
        head = [l for l in other if l.startswith("#")]
        rest = [l for l in other if not l.startswith("#") and l.strip()]
        if not head:
            head = ["# tb/frames/races_expected.txt: the pinned VRAM-race renders (PLAN 5 D13, option (a)), checked by",
                    "# tools/gate/races_expected.py in make frames / frames-full (gate frames) and frames-hw / frames-hw-full",
                    "# (gate frames-hw): a race render that enters or leaves the list, or whose count changes, fails the gate.",
                    "# Built from accepted runs with --write (review the diff); only the cases a run ran are checked.",
                    "#   frames <case> <configuration> r<render> <words that differ | equal>",
                    "#   frames-hw <kind>:<item> <configuration> r<render>[,r<render>...] <race-class differences | equal>"]
        with open(LIST, "w") as f:
            for l in head:
                f.write(l + "\n")
            for l in rest:
                f.write(l + "\n")
            for k in sorted(keep):
                f.write(f"{a.gate} {k[0]} {k[1]} {k[2]} {keep[k]}\n")
        print(f"races-expected: {a.gate}: wrote {len(keep)} lines ({len(seen)} from this run)")
        listed = keep
    if a.selftest:
        if not seen:
            print(f"races-expected: {a.gate}: selftest: no race render in this run to perturb: PASS (vacuous)")
        else:
            k0 = sorted(seen)[0]
            changed, extra = dict(seen), dict(seen)
            changed[k0] = str(int(seen[k0]) + 1) if seen[k0] != "equal" else "1"
            # an extra line at a render that ran and is no race (frames), or any render (frames-hw)
            xk = None
            for k in sorted(seen):
                if (k[0], k[1]) not in nr:
                    xk = (k[0], k[1], "r9999")
                    break
                free = [f"r{i}" for i in range(nr[(k[0], k[1])]) if (k[0], k[1], f"r{i}") not in seen]
                if free:
                    xk = (k[0], k[1], free[0])
                    break
            if xk is None:
                xr = sorted(c for c in ran if c in nr and nr[c] > 0 and not any(k[:2] == c for k in seen))
                xk = (xr[0][0], xr[0][1], "r0")
            extra[xk] = "equal"
            tries = {"a changed count": changed,
                     "a dropped line": {k: v for k, v in seen.items() if k != k0},
                     "an extra line": extra}
            for what, lst in tries.items():
                if not compare(lst, ran, seen, nr):
                    print(f"races-expected: {a.gate}: selftest: {what} passes the check: FAIL")
                    return 1
            print(f"races-expected: {a.gate}: selftest: a changed count, a dropped line and an extra line fail: PASS")
    bad = compare(listed, ran, seen, nr)
    for b in bad[:60]:
        print(f"races-expected: {a.gate}: {b}")
    nl = sum(1 for k in listed if (k[0], k[1]) in ran)
    print(f"races-expected: {a.gate}: {len(seen)} race renders in {len({(k[0], k[1]) for k in seen})} cases of the {len(ran)} "
          f"that ran, {nl} lines listed for them: {'PASS' if not bad else 'FAIL'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

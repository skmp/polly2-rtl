#!/usr/bin/env python3
"""gate_timing.py: the timing gate's checks (PLAN 1.5, MT0; conventions.md 7.6.2) on p2-offline's logs of the timemeas
emissions against the console's archived logs.

    tools/timing/gate_timing.py --spec <file> [--groups g,g] [--k K | --fit] [--console <folder>] <sim log> ...
    tools/timing/gate_timing.py --table <out> [--k K] [--console <folder>] <sim log> ...

The sim logs (tools/timing/tm_item.sh's) of any variants, merged per scene key: a key's RTL clocks are its timed renders'
least (tmlib.timed). The console's: the least over fit/timemeas_logs/timemeas_run*.log (analyze.py's), counts / 2.

The spec (tb/timing/gate.txt), one check a line, "|"-separated:
    <group> | fit   | <field> | <key>                       the K fit (--fit): K = round(console - rtl) - 7, the middle of
                                                           the poll's 0-14 (a reading is late by 0 to 14 clocks)
    <group> | abs   | <field> | <key>                       0 <= console - (rtl + K) <= 14
    <group> | diff  | <field> | <key A> - <key B>           |(console A - B) - (rtl A - B)| <= 5
    <group> | slope | <field> | <x> = <key A> - <key B> | <x> = ...   the least-squares slopes of (A - B) against x, console
                                                           and RTL, within 0.1 clk an object
    <group> | fitdiff | <field> | <key A> - <key B>         a difference a fit is made on (--fitdiff prints console, rtl
                                                           and the error; make timing-fit's VR_ROW sweep)
<field>: tsp (the TSP's end-of-render bit) or isp (the ISP's). K: --k, else tb/timing/k.txt. A check whose keys the
console or the RTL lacks fails. Prints a line a check ("<group> <kind> ...: console <c> rtl <r> ...: PASS / FAIL"), then
"timing: <n> checks, <f> failures" and "timing: PASS" / "FAIL"; exit 1 on a failure. --fit prints "K <value>" (and the
fit scene's numbers) instead and checks nothing.

--table: every scene of the logs, console against RTL, to <out> (tab-separated: key, console tsp / isp, rtl tsp / isp,
the residual console - (rtl + K) of each, in clocks; "-" where one is missing), and a summary on stdout: how many scenes
fall in 0..14, below, above, per kind (the key's first word).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tmlib  # noqa: E402

POLL = 14       # clocks: a poll turn (140 ns)
DIFF = 5        # clocks: a single difference's repeatability
SLOPE = 0.1     # clocks an object


def rtl_table(logs):
    R = {}
    for p in logs:
        scenes, _ = tmlib.parse_sim_log(p)
        for s in scenes:
            tr = tmlib.timed(s["renders"])
            if s["kind"] != "T" or not tr:
                continue
            v = (min(r["isp"] for r in tr), min(r["tsp"] for r in tr))
            old = R.get(s["key"])
            R[s["key"]] = v if old is None else (min(old[0], v[0]), min(old[1], v[1]))
    return R


def norm(k):
    return " ".join(k.split())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec")
    ap.add_argument("--groups")
    ap.add_argument("--k", type=float)
    ap.add_argument("--fit", action="store_true")
    ap.add_argument("--fitdiff", action="store_true")
    ap.add_argument("--table")
    ap.add_argument("--console", default=os.path.join(os.path.dirname(tmlib.ROOT), "dreamcast-tests", "fit", "timemeas_logs"))
    ap.add_argument("logs", nargs="+")
    a = ap.parse_args()
    C = {k: (v[0] / 2, v[2] / 2) for k, v in tmlib.load_console(a.console).items()}
    R = rtl_table(a.logs)
    F = {"isp": 0, "tsp": 1}

    if a.table:
        K = a.k if a.k is not None else tmlib.read_k()
        by = {}
        with open(a.table, "w") as f:
            f.write("key\tconsole_tsp\tconsole_isp\trtl_tsp\trtl_isp\tres_tsp\tres_isp\n")
            for key in sorted(set(R) | set(C), key=lambda k: (k.split()[0], [int(x) for x in k.split()[1:]])):
                c, r = C.get(key), R.get(key)
                if r is None:
                    continue
                if c is None:
                    f.write(f"{key}\t-\t-\t{r[1]}\t{r[0]}\t-\t-\n")
                    by.setdefault(key.split()[0], [0, 0, 0, 0, []])[3] += 1
                    continue
                res = [c[1] - (r[1] + K), c[0] - (r[0] + K)]
                f.write(f"{key}\t{c[1]:g}\t{c[0]:g}\t{r[1]}\t{r[0]}\t{res[0]:g}\t{res[1]:g}\n")
                b = by.setdefault(key.split()[0], [0, 0, 0, 0, []])
                b[0 if res[0] < 0 else 1 if res[0] <= POLL else 2] += 1
                b[4].append(res[0])
        tot = [0, 0, 0, 0]
        print(f"table: K {K:g}; per kind: scenes with the TSP's residual console - (rtl + K) below 0 / in 0..{POLL} / above {POLL}"
              f" / no console; the median residual")
        for kind in sorted(by):
            b = by[kind]
            med = sorted(b[4])[len(b[4]) // 2] if b[4] else float("nan")
            print(f"  {kind:12s} {b[0]:5d} {b[1]:5d} {b[2]:5d} {b[3]:5d}   median {med:9.1f}")
            for i in range(4):
                tot[i] += b[i]
        print(f"table: {sum(tot)} scenes: {tot[0]} below 0, {tot[1]} in 0..{POLL}, {tot[2]} above, {tot[3]} without a console number")
        return 0

    lines = []
    for raw in open(a.spec):
        raw = raw.split("#")[0].strip()
        if raw:
            lines.append([x.strip() for x in raw.split("|")])
    groups = set(a.groups.split(",")) if a.groups else None
    if a.fitdiff:
        fl = [l for l in lines if l[1] == "fitdiff" and (groups is None or l[0] in groups)]
        if len(fl) != 1:
            sys.exit("gate_timing: --fitdiff wants exactly one fitdiff line")
        ka, kb = [norm(x) for x in fl[0][3].split(" - ")]
        f = F[fl[0][2]]
        if any(k not in C or k not in R for k in (ka, kb)):
            sys.exit(f"gate_timing: {fl[0][3]}: a number is missing")
        c, r = C[ka][f] - C[kb][f], R[ka][f] - R[kb][f]
        print(f"fitdiff {fl[0][3]}: console {c:g} rtl {r} error {r - c:g}")
        return 0
    if a.fit:
        fits = [l for l in lines if l[1] == "fit" and (groups is None or l[0] in groups)]
        if len(fits) != 1:
            sys.exit("gate_timing: --fit wants exactly one fit line")
        g, _, field, key = fits[0]
        key = norm(key)
        if key not in C or key not in R:
            sys.exit(f"gate_timing: the fit scene {key} has no {'console' if key not in C else 'RTL'} number")
        c, r = C[key][F[field]], R[key][F[field]]
        K = round(c - r) - POLL // 2
        print(f"fit: {key} {field}: console {c:g} clk (least of the archived runs), rtl {r} clk")
        print(f"fit: K = round({c:g} - {r}) - {POLL // 2} = {K} (the reading's lateness taken as the middle of 0..{POLL})")
        print(f"K {K}")
        return 0
    K = a.k if a.k is not None else tmlib.read_k()
    n = fails = 0

    def val(src, key, field):
        key = norm(key)
        return src.get(key, (None, None))[F[field]]

    def pair(src, spec, field):
        ka, kb = [norm(x) for x in spec.split(" - ")]
        va, vb = val(src, ka, field), val(src, kb, field)
        return None if va is None or vb is None else va - vb

    for l in lines:
        g, kind, field = l[0], l[1], l[2]
        if groups is not None and g not in groups:
            continue
        if kind in ("fit", "fitdiff"):
            continue
        n += 1
        ok, msg = False, ""
        if kind == "abs":
            key = norm(l[3])
            c, r = val(C, key, field), val(R, key, field)
            if c is None or r is None:
                msg = f"{key}: {'no console number' if c is None else 'no RTL number'}"
            else:
                res = c - (r + K)
                ok = 0 <= res <= POLL
                msg = f"{key}: console {c:g} rtl {r} + K {K:g}: residual {res:g} (0..{POLL})"
        elif kind == "diff":
            c, r = pair(C, l[3], field), pair(R, l[3], field)
            if c is None or r is None:
                msg = f"{l[3]}: a number is missing"
            else:
                ok = abs(c - r) <= DIFF
                msg = f"{l[3]}: console {c:g} rtl {r} (within {DIFF})"
        elif kind == "slope":
            pts = []
            for t in l[3:]:
                x, spec = t.split("=", 1)
                pts.append((float(x), pair(C, spec, field), pair(R, spec, field)))
            if any(p[1] is None or p[2] is None for p in pts) or len(pts) < 2:
                msg = "a number is missing"
            else:
                def slope(ys):
                    xs = [p[0] for p in pts]
                    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
                    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
                sc, sr = slope([p[1] for p in pts]), slope([p[2] for p in pts])
                ok = abs(sc - sr) <= SLOPE
                msg = (f"{l[3].split('=', 1)[1].strip()} ...: x {','.join(f'{p[0]:g}' for p in pts)}: console {sc:.3f} rtl "
                       f"{sr:.3f} clk an object (within {SLOPE})")
        else:
            msg = f"unknown check kind {kind}"
        if not ok:
            fails += 1
        print(f"{g} {kind} {field} {msg}: {'PASS' if ok else 'FAIL'}")
    print(f"timing: {n} checks, {fails} failures")
    print(f"timing: {'PASS' if fails == 0 and n > 0 else 'FAIL'}")
    return 0 if fails == 0 and n > 0 else 1


if __name__ == "__main__":
    sys.exit(main())

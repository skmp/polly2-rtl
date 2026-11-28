#!/usr/bin/env python3
"""tm_log.py: p2-offline's logs of a timemeas emission as the console's log (PLAN MT0, 1.5; conventions.md 7.6.2 option
a), so that dreamcast-tests' analyze.py, order.py and the rest read a simulated run as a console's.

    tools/timing/tm_log.py [--k K] [--detail <tsv>] <sim log> [<sim log> ...] > rtl.log

The sim logs are one stream's (tools/timing/tm_run.sh: one log a part of its renders); they are merged scene by scene.
Each measured scene becomes "T <what> a b c d W <isp least> <isp middle> <tsp least> <tsp middle> <tsp-isp least>
<tsp-isp middle> P 000000 000000" in counts: 2 x (clocks + K) for the ISP's and the TSP's bits (K: --k, else
tb/timing/k.txt; 0 with --k 0), 2 x the difference; least and middle over the timed renders (all but the first when a
scene has more than one: the console's warm-up). A palette clock scene: "O <what> <k> <tiles> writes <w> counts <c>" (w:
the timed writes the render got, from the sim log's "p2: timed" line when the runner wrote one, else 0; c the TSP's bit
as above), then its R lines as echoed. A scene with no timed render (skipped everywhere, or hung): "# <what> ... no
render" or "# ... did not end". Every other line the stream echoed (F, L, "T display", "T end", ...) is passed through
in place.

--detail <tsv>: one row a timed render: scene index, kind, key, render, and every field of its "p2: render" and "p2:
timing" lines (t_<name>), for the tables.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tmlib  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--k", type=float, default=None)
    ap.add_argument("--detail")
    ap.add_argument("logs", nargs="+")
    a = ap.parse_args()
    K = a.k if a.k is not None else tmlib.read_k()
    scenes, other = tmlib.merge_chunks(a.logs)
    out = sys.stdout
    oi = 0
    rows, fields = [], []

    def flush_other(upto):
        nonlocal oi
        while oi < len(other) and other[oi][0] < upto:
            out.write(other[oi][1] + "\n")
            oi += 1

    flush_other(0)
    for i, s in enumerate(scenes):
        tr = tmlib.timed(s["renders"])
        if not tr:
            hung = any(r.get("hung") for r in s["renders"])
            out.write(f"# {s['kind']} {s['key']} {'did not end' if hung else 'no render'}\n")
        elif s["kind"] == "T":
            il, im = tmlib.least_middle([r["isp"] for r in tr])
            tl, tm = tmlib.least_middle([r["tsp"] for r in tr])
            dl, dm = tmlib.least_middle([r["tsp"] - r["isp"] for r in tr])
            c = lambda x: int(round(2 * (x + K)))  # noqa: E731
            out.write(f"T {s['key']} W {c(il)} {c(im)} {c(tl)} {c(tm)} {2 * dl} {2 * dm} P 000000 000000\n")
        else:
            tl, _ = tmlib.least_middle([r["tsp"] for r in tr])
            w = tr[0].get("t_writes", 0) if isinstance(tr[0].get("t_writes", 0), int) else 0
            out.write(f"O {s['key']} writes {w} counts {int(round(2 * (tl + K)))}\n")
        for r in tr:
            for k in r:
                if k not in fields:
                    fields.append(k)
            rows.append((i, s["kind"], s["key"], r))
        flush_other(i + 1)
    flush_other(len(scenes) + 1)
    if a.detail:
        with open(a.detail, "w") as f:
            f.write("\t".join(["scene", "kind", "key"] + fields) + "\n")
            for i, kind, key, r in rows:
                f.write("\t".join([str(i), kind, key] + [str(r.get(k, "")) for k in fields]) + "\n")


if __name__ == "__main__":
    main()

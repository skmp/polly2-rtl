#!/usr/bin/env python3
"""tm_order_writes.py: the palette clock of timemeas TM_ORDER as p2-offline's P2_TIMED_WRITES (PLAN 1.5, MT0).

    tools/timing/tm_order_writes.py [--console <folder>] [--clocks N] [--offset C] > writes.txt

On a console the CPU rewrites PALETTE_RAM[0] with 0xff000000 | v, v = 1, 2, ..., while the core renders (main.c
order_go, eight writes a loop turn), so a pixel's colour is the count of writes when the TSP looked the entry up. The
rate is the console's: writes / counts of every "O" line of the order logs (fit/timemeas_logs/*order*.log, setupk_*,
sortoff_*), their mean, ~0.0407 writes a count (one every ~12.3 clocks). The file writes v at clock round(v x clocks a
write) - C (--offset, 0: the first write about one write interval after STARTRENDER, as the console's loop starts right
after its write to STARTRENDER; how STARTRENDER's own latency splits K is GAP, tim 3.1a), for every render (no "@"
line), up to --clocks (200000). Prints the rate it used on stderr.
"""
import argparse
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tmlib  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--console", default=os.path.join(os.path.dirname(tmlib.ROOT), "dreamcast-tests", "fit", "timemeas_logs"))
    ap.add_argument("--clocks", type=int, default=200000)
    ap.add_argument("--offset", type=int, default=0)
    a = ap.parse_args()
    w = c = 0
    for f in sorted(glob.glob(os.path.join(a.console, "*.log"))):
        for line in open(f, errors="replace"):
            p = line.split()
            if len(p) >= 8 and p[0] == "O" and p[4] == "writes" and p[6] == "counts":
                w += int(p[5])
                c += int(p[7])
    if not w:
        sys.exit("tm_order_writes: no O lines in " + a.console)
    per = c / w / 2          # clocks a write
    print(f"tm_order_writes: {w} writes in {c} counts: one every {per:.3f} clocks", file=sys.stderr)
    print(f"# PALETTE_RAM[0] = 0xff000000 | v at clock round(v x {per:.4f}) - {a.offset} (tools/timing/tm_order_writes.py)")
    v, last = 1, 0
    while True:
        t = max(last + 1, round(v * per) - a.offset)
        if t > a.clocks or v > 0xffffff:
            break
        print(f"{t} 1000 {0xff000000 | v:08x}")
        last = t
        v += 1


if __name__ == "__main__":
    main()

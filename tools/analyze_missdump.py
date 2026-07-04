#!/usr/bin/env python3
"""
Analyze missdump.log (from peel_core +missdump) to ESTIMATE the cycle wins of
different spanner policies BEFORE implementing them.

The log is the in-order event stream the spanner produced:
  [HIT ] px<N> tag=<T>                         -> 1 resolved pixel from the plane cache
  [MISS #k] PROMOTE  ...                        -> demand miss served from prefetch shadow (fetch hidden, setup paid)
  [MISS #k] WAIT     ... (MATCH|MISMATCH)       -> miss, prefetch in flight (about to WAITHIT/WAITMISS)
  [MISS #k] WAITHIT  ...                        -> waited for in-flight prefetch, matched (fetch hidden, setup paid)
  [MISS #k] WAITMISS ...                        -> waited, wrong tag -> demand fetch (fetch+setup paid)
  [MISS #k] FETCH    ... (COLD ...)             -> no prefetch -> demand fetch (fetch+setup paid)
  [PREFETCH] issue tag=<T> (scanned pixel P, during miss tag=<M>)
  [PREFETCH] WASTED ...

Cost knobs (cycles) - approximate, matched to the RTL:
  HIT              = 1     (1 px / clk resolve+write)
  SETUP            = 54    (tsp_setup_min, fixed, UNHIDEABLE by prefetch)
  FETCH_COLD       = 91    (record+vertex DDR fetch on a cold miss)
  These are the spanner's per-event *occupancy*; the reader drains at 1 px/clk in
  parallel and starves whenever the spanner stalls (that starvation == the wall).

We estimate SPANNER-BUSY cycles (which the occupancy showed is the floor, ~2.4M) under:
  A. CURRENT      : promote/waithit pay SETUP; cold/waitmiss pay FETCH+SETUP; hits 1.
  B. NB_SETUP     : NON-BLOCKING setup - a miss's SETUP overlaps the following HITS
                    (setup runs in bg; only stalls if the next miss arrives < SETUP
                    cycles later, i.e. fewer than SETUP hit-pixels between misses).
                    Also needs fetch hidden (prefetch) to fully overlap.
  C. NB_SETUP+FETCH: as B but cold-miss FETCH also overlapped (perfect prefetch).
  D. PERFECT      : every miss fully hidden -> spanner == #resolved pixels (1/clk).
"""
import sys, re

# Calibrated to the MEASURED perf buckets (menu2, 2.79M run):
#   SETUP_WAIT=767772 over 6786 misses  -> ~113 cyc/miss actually spent in P_TSP_RUN
#   FETCH=231404 over 2855 cold(FETCH+WAITMISS) -> ~81 cyc/cold-fetch
#   CACHE_LOOK=785116 ~ per-pixel resolve for 702634 hits+ -> ~1.1 cyc/pixel
# (The measured SETUP_WAIT/miss (113) is ~2x the tsp_setup_min module latency (~54) -
#  the extra is handshake + the spanner sitting frozen; that's exactly the hideable part.)
HIT_CYC   = 1
SETUP_CYC = 113   # measured SETUP_WAIT / miss (P_TSP_RUN occupancy, the hideable stall)
FETCH_CYC = 81    # measured FETCH / cold-miss (on top of setup)

def parse(path):
    ev = []  # (kind, subkind)  kind in {H, M}; subkind for M
    miss_re = re.compile(r'^\[MISS #\d+\]\s+(\w+)')
    for line in open(path):
        if line.startswith('[HIT'):
            ev.append(('H', None))
        elif line.startswith('[MISS'):
            m = miss_re.match(line)
            sk = m.group(1) if m else '?'
            # WAIT lines are followed by WAITHIT/WAITMISS for the SAME miss; skip the
            # bare WAIT (it's the decision, the resolution is the next line).
            if sk == 'WAIT':
                continue
            ev.append(('M', sk))
        # PREFETCH lines: ignore (their effect is already reflected in PROMOTE/WAITHIT)
    return ev

def analyze(ev):
    n_hit = sum(1 for k,_ in ev if k=='H')
    misses = [sk for k,sk in ev if k=='M']
    from collections import Counter
    mc = Counter(misses)
    n_miss = len(misses)

    # A. CURRENT spanner-busy estimate
    A = 0
    for k,sk in ev:
        if k=='H': A += HIT_CYC
        else:
            if sk in ('PROMOTE','WAITHIT'):      A += SETUP_CYC            # fetch hidden, setup serial
            elif sk in ('FETCH','WAITMISS'):     A += FETCH_CYC + SETUP_CYC # cold: fetch + setup
            else:                                A += FETCH_CYC + SETUP_CYC

    # B/C. NON-BLOCKING setup: a miss's SETUP overlaps the HITS that FOLLOW it, up to
    # SETUP cycles. Walk the stream; track "setup debt" that burns down on hits.
    # A miss adds its (hidden-able) cost as debt; hits pay it down 1/cyc; if a new miss
    # arrives while debt>0, the spanner must stall for the remaining debt (single setup
    # unit) before starting the new one.
    def nonblocking(hide_fetch):
        cyc = 0
        debt = 0   # remaining cycles of the in-flight (bg) setup/fetch
        for k,sk in ev:
            if k=='H':
                cyc += HIT_CYC
                debt = max(0, debt-HIT_CYC)
            else:
                # must wait for any in-flight setup to finish (one unit)
                cyc += debt
                debt = 0
                # this miss's cost:
                if sk in ('PROMOTE','WAITHIT'):
                    new = SETUP_CYC                      # fetch already hidden
                else:
                    new = SETUP_CYC + (0 if hide_fetch else FETCH_CYC)
                # 1 cycle to issue/commit the miss pixel, rest overlaps following hits
                cyc += 1
                debt = new
        cyc += debt  # drain the last
        return cyc

    B = nonblocking(hide_fetch=False)  # setup overlaps hits, cold fetch still serial
    C = nonblocking(hide_fetch=True)   # setup AND fetch overlap (perfect prefetch)
    D = n_hit + n_miss                 # perfect: 1 cyc per resolved pixel

    print(f"resolved pixels (HIT): {n_hit}")
    print(f"misses: {n_miss}   {dict(mc)}")
    print()
    print(f"A. CURRENT (setup+fetch serial per miss)   spanner-busy ~ {A:,}")
    print(f"B. NON-BLOCKING setup (overlap hits, cold fetch serial) ~ {B:,}   (save {A-B:,})")
    print(f"C. NB setup + fetch hidden (perfect prefetch)          ~ {C:,}   (save {A-C:,})")
    print(f"D. PERFECT (1 cyc/resolved pixel)                      ~ {D:,}   (save {A-D:,})")
    print()
    print(f"real-HW total target ~1,300,000 (whole frame incl raster; this is spanner-only)")

if __name__ == '__main__':
    path = sys.argv[1] if len(sys.argv)>1 else 'missdump.log'
    ev = parse(path)
    analyze(ev)

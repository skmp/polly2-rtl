#!/usr/bin/env python3
"""
Model the 4-tags/clock SPAN generator, ALIGNED reads (px 0-3,4-7,8-11,...).

Per-cycle rule (user-specified):
  - Read the 4 tags of the current ALIGNED group [g,g+3], g = x & ~3.
  - Emit ONE span = the leading run of EQUAL tags starting at x, but capped at the
    group boundary g+3 (can't see past the aligned window this cycle).
  - Advance x by that run length (1..up to 4).
  So: 4 identical in a group -> 4px in 1 cyc. Alternating -> 1px/cyc. A long run
  crossing group boundaries costs 1 cyc per group-portion (each a separate emission).

Each EMISSION is a span-segment that needs a plane-cache lookup (hit=1, the emission
cycle itself; miss=setup[+fetch]). Repeats within the emitted segment are free.

The reader still shades every pixel at 1px/clk (unchanged).

Cost knobs calibrated to measured menu2 buckets:
  SETUP=113 (P_TSP_RUN/miss), FETCH=81 (cold/miss). scan is the emission cycles.
"""
import sys, re, math
from collections import Counter

SETUP=113; FETCH=81

def load_stream(path):
    stream=[]  # (tag, was_miss) in resolve/pixel order
    hit_re  = re.compile(r'^\[HIT \] px(\d+) tag=([0-9a-f]+)')
    miss_re = re.compile(r'^\[MISS #\d+\]\s+(\w+).*actual=([0-9a-f]+)')
    for line in open(path):
        if line.startswith('[HIT'):
            m=hit_re.match(line)
            if m: stream.append((int(m.group(2),16), False))
        elif line.startswith('[MISS'):
            m=miss_re.match(line)
            if not m: continue
            if m.group(1)=='WAIT': continue
            stream.append((int(m.group(2),16), True))
    return stream

def main(path):
    s = load_stream(path)
    n = len(s)
    tags = [t for t,_ in s]
    miss = [m for _,m in s]

    # --- ALIGNED 4-wide span emission ---
    emissions = 0          # = spanner cycles for the resolve walk (1 emission/cycle)
    emit_miss = 0          # emissions whose FIRST pixel was a miss (need setup)
    # also model UNALIGNED (ignore group cap) for comparison
    emit_unaligned = 0
    i = 0
    while i < n:
        g_end = (i | 3)               # last index of aligned group
        tag = tags[i]
        j = i
        while j <= g_end and j < n and tags[j]==tag:
            j += 1
        # emission covers [i, j)
        if miss[i]:
            emit_miss += 1
        emissions += 1
        i = j
    # unaligned (advance over full run regardless of group)
    i=0
    while i<n:
        tag=tags[i]; j=i
        while j<n and tags[j]==tag: j+=1
        emit_unaligned += 1
        i=j

    old_miss = sum(miss)
    old_hits = n - old_miss

    # spanner LOOKUP+SETUP cycles:
    #  OLD  : 1/pixel + setup/miss
    #  SPAN : 1/emission (the emit cycle does the lookup) + setup/emit_miss
    old_cyc  = old_hits*1 + old_miss*SETUP
    span_cyc = emissions*1 + emit_miss*SETUP
    span_unaligned_cyc = emit_unaligned*1 + old_miss*SETUP  # ~ (emit_miss~=old_miss)

    print(f"pixels: {n:,}   misses: {old_miss:,}")
    print(f"emissions (ALIGNED 4-wide, = resolve cycles): {emissions:,}   avg {n/emissions:.2f} px/emit")
    print(f"emissions (UNALIGNED, full-run coalesce):     {emit_unaligned:,}   avg {n/emit_unaligned:.2f} px/emit")
    print(f"emit that are misses (need setup): {emit_miss:,}  (vs per-pixel misses {old_miss:,})")
    print()
    print(f"spanner LOOKUP+SETUP cycles (fetch excluded):")
    print(f"  OLD  per-pixel:            {old_cyc:,}")
    print(f"  SPAN aligned:              {span_cyc:,}   (save {old_cyc-span_cyc:,})")
    print(f"    of which setup:          {emit_miss*SETUP:,}")
    print(f"    of which emit(scan+hit): {emissions:,}")
    print(f"  SPAN unaligned (ideal):    {span_unaligned_cyc:,}   (save {old_cyc-span_unaligned_cyc:,})")
    print()
    # emission run-length histogram (aligned)
    i=0; runs=[]
    while i<n:
        g_end=(i|3); tag=tags[i]; j=i
        while j<=g_end and j<n and tags[j]==tag: j+=1
        runs.append(j-i); i=j
    c=Counter(runs)
    print(f"aligned emission-length histogram: 1:{c[1]}  2:{c[2]}  3:{c[3]}  4:{c[4]}")
    print(f"  (max 4 by construction; distribution shows how often the 4-window is fully used)")

if __name__=='__main__':
    main(sys.argv[1] if len(sys.argv)>1 else 'missdump.log')

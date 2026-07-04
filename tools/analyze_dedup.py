#!/usr/bin/env python3
"""Model set-associative core_tag->setup_id dedup vs direct-mapped, incl. adversarial aliasing."""
import re, sys

def load_segs(path):
    tag_re=re.compile(r"(?:tag=|actual=)([0-9a-f]+)")
    segs=[]; cur=[]
    for line in open(path):
        if line.startswith("[TILE"):
            if cur: segs.append(cur[:]); cur=[]
        elif line.startswith("[HIT") or (line.startswith("[MISS") and "WAIT " not in line):
            m=tag_re.search(line)
            if m: cur.append(int(m.group(1),16))
    if cur: segs.append(cur)
    return segs

def hash_set(t,nset): return (t>>3 ^ (t&0x7)) % nset

def setassoc(segs,nset,ways):
    """LRU per set, id=set*ways+way. Returns (re)setup count."""
    setups=0
    for tags in segs:
        sets=[dict() for _ in range(nset)]; clk=0
        for t in tags:
            clk+=1; d=sets[hash_set(t,nset)]
            if t in d: d[t]=clk
            else:
                if len(d)>=ways:
                    lru=min(d,key=lambda k:d[k]); del d[lru]
                d[t]=clk; setups+=1
    return setups

SHADE=709420; SETUP=54
def hid(cyc, sh): return "HIDDEN" if cyc<sh else "SETUP-BOUND"

def main(path):
    segs=load_segs(path)
    ideal=sum(len(set(t)) for t in segs)
    print(f"ideal (distinct/tile): {ideal:,}   shade={SHADE:,}")
    for nset,w,lab in [(1024,1,"direct-map 1024x1"),(256,4,"256set x4way"),
                       (128,8,"128 x8"),(64,16,"64 x16"),(16,64,"16 x64"),(1,1024,"fully-assoc 1024")]:
        s=setassoc(segs,nset,w)
        print(f"  {lab:20s}: {s:,} setups (+{s-ideal:>4})  setup-cyc={s*SETUP:,} {hid(s*SETUP,SHADE)}")

    print("\n--- ADVERSARIAL: 512 distinct tags ALL hashing to one set, 4 reuse passes (2048 px) ---")
    for nset,w,lab in [(1024,1,"DM 1024x1"),(256,4,"256x4"),(64,16,"64x16"),(16,64,"16x64"),(1,1024,"FA 1024")]:
        # find 512 tags mapping to set 0
        found=[]; t=0
        while len(found)<512:
            if hash_set(t,nset)==0: found.append(t)
            t+=8
        seq=found*4
        d={}; clk=0; setups=0
        for x in seq:
            clk+=1
            if x in d: d[x]=clk
            else:
                if len(d)>=w:
                    lru=min(d,key=lambda k:d[k]); del d[lru]
                d[x]=clk; setups+=1
        px=len(seq)
        print(f"  {lab:12s}: {setups} setups / {px}px  setup-cyc={setups*SETUP:,} vs shade {px} -> {'SETUP-BOUND' if setups*SETUP>px else 'ok'}")

if __name__=='__main__':
    main(sys.argv[1] if len(sys.argv)>1 else 'missdump.log')

#!/usr/bin/env python3
# scan_arrays.py - walk every dumps/*_<name> pair (pvr_regs_<name>.bin +
# vram_<name>.bin), parse the region array -> object lists, and report every
# triangle/quad ARRAY entry with its element count. For multi-element arrays,
# probe the two candidate memory layouts and say which one is self-consistent:
#   SHARED : one [isp][tsp][tcw] header, then N * (3 or 4) contiguous vertices
#   PERELEM: a full [isp][tsp][tcw][verts] record repeated per element (refsw)
#
# The dumps are the 32-bit VIEW stored linearly (read directly; see
# pvr-list-decode-conventions memory).
import struct, glob, os, sys

VMASK = 0x7FFFFF

def scan(regs_path, vram_path, name):
    rg = open(regs_path, 'rb').read()
    v  = open(vram_path, 'rb').read()
    def rr(o):  return struct.unpack_from('<I', rg, o)[0]
    def vri(a): return struct.unpack_from('<I', v, a & VMASK)[0]
    def f32(a): return struct.unpack('<f', struct.pack('<I', vri(a)))[0]

    region_base = rr(0x2C) & VMASK
    param_base  = rr(0x20) & 0xF00000
    fpu         = rr(0x7C)
    rht         = (fpu >> 21) & 1
    stride_ra   = 24 if rht else 20            # v2=24B, v1=20B region entry

    def refptr(x):  # ListPointer: ptr_in_words = bits[23:2], byte = *4
        return ((x >> 2) & 0x3FFFFF) << 2

    # plausibility tests for an ISP word (header) vs a vertex coordinate.
    def looks_like_isp(w):
        # DepthMode 1..7 (0=never rare), CullMode any; the low bits vary. Mostly
        # we check it's NOT a "normal-magnitude" float coordinate.
        return True
    def is_coord(w):
        # a screen-space vertex coord is a normal float roughly in [2^-8, 2^13]
        e = (w >> 23) & 0xFF
        return 0x74 <= e <= 0x8C     # ~1e-2 .. ~8k in magnitude

    results = []
    def walk_list(byte_base, listname, tile):
        base = byte_base
        n = 0
        while n < 2048:
            e = vri(base); base += 4; n += 1
            is_not_ts = (e >> 31) & 1
            if not is_not_ts:
                continue                       # triangle strip
            typ = (e >> 29) & 7
            if typ == 7:                       # link
                if (e >> 28) & 1: break        # end_of_list
                base = refptr(e); continue
            if typ in (4, 5):                  # 4=tri array, 5=quad array
                prims = (e >> 25) & 0xF
                skip  = (e >> 21) & 7
                shadow= (e >> 24) & 1
                po    = e & 0x1FFFFF
                count = prims + 1
                nvtx  = 3 if typ == 4 else 4
                results.append(dict(tile=tile, list=listname, kind='tri' if typ==4 else 'quad',
                                    count=count, skip=skip, shadow=shadow, po=po,
                                    base=param_base + po*4, nvtx=nvtx))
            # unknown types: ignore
        return

    # walk the region array
    base = region_base
    for _ in range(16384):
        ctrl = vri(base+0)
        opq  = vri(base+4); trn = vri(base+12)
        pt   = vri(base+20) if stride_ra == 24 else 0x80000000
        tx = (ctrl>>2)&0x3F; ty=(ctrl>>8)&0x3F; last=(ctrl>>31)&1
        for nm, ptr in (('OP',opq), ('TR',trn), ('PT',pt)):
            if (ptr>>31)&1: continue           # empty
            walk_list(refptr(ptr), nm, (tx,ty))
        if last: break
        base += stride_ra

    # summarize
    arrays = results
    multi  = [a for a in arrays if a['count'] > 1]
    if not arrays:
        print(f"  {name:22s}: no tri/quad array entries")
        return 0
    ntri  = sum(1 for a in arrays if a['kind']=='tri')
    nquad = sum(1 for a in arrays if a['kind']=='quad')
    print(f"  {name:22s}: {len(arrays):5d} arrays (tri={ntri} quad={nquad}), "
          f"multi-element={len(multi)}, max count={max(a['count'] for a in arrays)}")

    # Two candidate layouts for a multi-element array:
    #   PERELEM : each element a full [hdr][verts] record (refsw / current RTL)
    #   SHARED  : one [hdr], then count*nvtx contiguous vertices (PVR TA docs)
    # Decide per array by which keeps its Z coordinates plausible. Vertex Z here
    # is 1/w, a small positive normal float (~1e-4..1e-1); a misparse lands on a
    # header/UV/color word which is NOT such a value.
    def z_ok(w):
        e=(w>>23)&0xFF; return (w>>31)==0 and 0x60<=e<=0x80   # ~1e-9..~2, positive
    def check(a, shared):
        two=a['shadow']; hdrw=5 if two else 3
        vsw=3+a['skip']*(1+(1 if two else 0))
        good=0; tot=0
        for el in range(a['count']):
            if shared:
                vb = a['base'] + hdrw*4 + el*a['nvtx']*vsw*4
            else:
                vb = a['base'] + el*(hdrw+a['nvtx']*vsw)*4 + hdrw*4
            for k in range(a['nvtx']):
                tot+=1
                if z_ok(vri(vb + k*vsw*4 + 8)): good+=1   # +8 = Z word of vertex
        return good, tot
    per_score=shr_score=0; per_tot=0
    for a in multi:
        pg,pt=check(a,False); sg,st=check(a,True)
        per_score+=pg; shr_score+=sg; per_tot+=pt
    pp = 100*per_score/per_tot if per_tot else 0
    sp = 100*shr_score/per_tot if per_tot else 0
    winner = "SHARED" if sp>pp+5 else ("PERELEM" if pp>sp+5 else "ambiguous")
    print(f"        Z-plausibility: PERELEM={pp:5.1f}%  SHARED={sp:5.1f}%  -> {winner}")
    return winner

def main():
    d = 'dumps'
    names = sorted({os.path.basename(p)[len('vram_'):-4]
                    for p in glob.glob(os.path.join(d,'vram_*.bin'))})
    total_multi = 0
    print("scanning %d dump sets for triangle/quad arrays...\n" % len(names))
    for nm in names:
        rp = os.path.join(d, f'pvr_regs_{nm}.bin')
        vp = os.path.join(d, f'vram_{nm}.bin')
        if not (os.path.exists(rp) and os.path.exists(vp)):
            continue
        try:
            total_multi += scan(rp, vp, nm)
        except Exception as ex:
            print(f"  {nm:22s}: ERROR {ex}")
    print(f"\n=== total multi-element arrays across all dumps: {total_multi} ===")

if __name__ == '__main__':
    main()

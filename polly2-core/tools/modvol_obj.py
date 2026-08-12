#!/usr/bin/env python3
"""modvol_obj.py - export a dump's MODIFIER VOLUMES as a Wavefront OBJ.

Each volume becomes its own OBJ object (`o volume_NNN`), so a viewer can isolate
them and see how they are built - which is what you want when a shadow has a hole
in it and the question is whether the volume is closed, folded, or pinched.

VOLUME GROUPING. The object lists are per-tile and the same volume is binned into
every tile it touches, so faces are first de-duplicated by their parameter offset
(unique per record) and then re-sorted into submission order. A volume is a run of
records terminated by one whose ISP word carries a non-zero VolumeMode (bits 31:29,
1 = "inside last polygon", 2 = "outside last"), exactly as the renderers split them.

COORDINATES. A modifier-volume vertex is (x, y, 1/w) with x,y already projected to
screen pixels, so the raw triple is not a shape - x,y are pixels while 1/w runs from
~0.006 to the guest's near-plane clamp of 100000, and the extruded vertices land at
|x| ~ 5e9. The default output therefore UNPROJECTS back to a view-space-proportional
frame:

    w = 1/pvr_depth ;   X = (x - W/2)/64*w ,  Y = -(y - H/2)/64*w ,  Z = w

which is the true shape up to one unknown scale factor, and incidentally brings the
extruded vertices (~5e4) into the same range as the caps. Pass --raw for screen-space
(x, y, w) instead. The depth channel is 1/pvr_depth in BOTH modes. Y is negated so +Y is up, as OBJ viewers expect.
"""
import struct, sys, os, argparse, collections

VMASK = 0x7FFFFF

def load(scene, dumps):
    v  = open(os.path.join(dumps, f'vram_{scene}.bin'), 'rb').read()
    rg = open(os.path.join(dumps, f'pvr_regs_{scene}.bin'), 'rb').read()
    return v, rg

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('scene')
    ap.add_argument('-o', '--out')
    ap.add_argument('--dumps', default=os.path.join(os.path.dirname(__file__), '..', '..', 'polly2-data', 'dumps'))
    ap.add_argument('--raw', action='store_true', help='emit raw (x, y, 1/w) instead of unprojecting')
    ap.add_argument('--list', choices=['op', 'tr', 'both'], default='op',
                    help='which modifier list: opaque_mod (default), trans_mod, or both')
    ap.add_argument('--find', default=None,
                    help='comma-separated param offsets (hex) - report which volume owns each')
    ap.add_argument('--xy-scale', type=float, default=64.0,
                    help='divide screen x/y by this before transforming (default 64)')
    ap.add_argument('--width', type=float, default=640.0)
    ap.add_argument('--height', type=float, default=480.0)
    a = ap.parse_args()

    v, rg = load(a.scene, a.dumps)
    rr  = lambda o: struct.unpack_from('<I', rg, o)[0]
    vri = lambda x: struct.unpack_from('<I', v, x & VMASK)[0]
    vrf = lambda x: struct.unpack_from('<f', v, x & VMASK)[0]

    param_base  = rr(0x20) & 0xF00000
    region_base = rr(0x2C) & VMASK
    stride      = 24 if (rr(0x7C) >> 21) & 1 else 20
    refptr      = lambda x: ((x >> 2) & 0x3FFFFF) << 2

    # ---- walk the region array, collect every modvol record (de-duped by param offset) ----
    recs = {}                      # param_offs -> (isp, [(x,y,z) x3])
    tiles = 0
    base = region_base
    for _ in range(16384):
        ctrl = vri(base); tiles += 1
        ptrs = []
        if a.list in ('op', 'both'):   ptrs.append(vri(base + 8))    # opaque_mod
        if a.list in ('tr', 'both'):   ptrs.append(vri(base + 16))   # trans_mod
        for lp in ptrs:
            if (lp >> 31) & 1: continue
            b, k = refptr(lp), 0
            while k < 100000:
                e = vri(b); b += 4; k += 1
                if (e >> 31) & 1 and (e >> 29) & 7 == 7:
                    if (e >> 28) & 1: break
                    b = refptr(e); continue
                t = (e >> 29) & 7
                po, skip = e & 0x1FFFFF, (e >> 21) & 7
                n  = ((e >> 25) & 0xF) + 1 if t in (4, 5) else 1
                nv = 4 if t == 5 else 3
                recw = 3 + nv * (3 + skip)
                for i in range(n):
                    p = po + i * recw
                    if p in recs: continue
                    ad = param_base + p * 4
                    recs[p] = (vri(ad),
                               [(vrf(ad + 12 + j*12), vrf(ad + 16 + j*12), vrf(ad + 20 + j*12))
                                for j in range(3)])
        if (ctrl >> 31) & 1: break
        base += stride

    # ---- submission order -> volumes (a run ending at VolumeMode != 0) ----
    vols, cur = [], []
    for p in sorted(recs):
        isp, tri = recs[p]
        vm = (isp >> 29) & 7
        cur.append((p, vm, tri))
        if vm:
            vols.append(cur); cur = []
    if cur: vols.append(cur)        # trailing run with no terminator

    out = a.out or f'modvol_{a.scene}.obj'
    cx, cy = a.width / 2.0, a.height / 2.0
    XY_SCALE = a.xy_scale
    def xf(p):
        # The vertex's third component is PVR depth = 1/w. The depth channel written
        # out is its RECIPROCAL, 1/pvr_depth = w: linear in view depth, and it maps
        # the guest's near-plane clamp (pvr_depth = 100000) to 1e-5 instead of a
        # value five orders of magnitude off the rest of the model.
        x, y, pvr_depth = p
        w = 1.0 / pvr_depth if pvr_depth != 0.0 else 0.0
        # X/Y are divided by XY_SCALE (64) so the model comes out at a sane size
        # next to the depth channel instead of pixel-magnitude.
        if a.raw: return (x / XY_SCALE, y / XY_SCALE, w)
        return ((x - cx) / XY_SCALE * w, -(y - cy) / XY_SCALE * w, w)

    # One colour per volume, on a golden-ratio hue walk so adjacent volumes never
    # come out similar. Written BOTH as an .mtl and as per-vertex colours (the
    # `v x y z r g b` extension), since viewers split on which of the two they honour.
    import colorsys
    cols = [colorsys.hsv_to_rgb((i * 0.61803398875) % 1.0, 0.65, 0.95) for i in range(len(vols))]
    mtl = os.path.splitext(out)[0] + '.mtl'
    with open(mtl, 'w') as m:
        for i, (r, g, b) in enumerate(cols):
            m.write('newmtl volume_%03d\nKd %.4f %.4f %.4f\nd 1.0\nillum 1\n\n' % (i, r, g, b))

    nv = 0
    modes = collections.Counter()
    with open(out, 'w') as f:
        f.write(f'# modifier volumes from {a.scene}  ({"raw screen" if a.raw else "unprojected"})\n')
        f.write(f'# {tiles} region entries, {len(recs)} distinct faces, {len(vols)} volumes\n')
        f.write('mtllib %s\n' % os.path.basename(mtl))
        for i, vol in enumerate(vols):
            vm_last = vol[-1][1]
            modes[vm_last] += 1
            f.write(f'o volume_{i:03d}\n')
            f.write(f'usemtl volume_{i:03d}\n')
            f.write(f'# {len(vol)} faces, terminator VolumeMode={vm_last}'
                    f' ({ {0:"none - unterminated", 1:"inside last", 2:"outside last"}.get(vm_last, "?") })\n')
            cr, cg, cb = cols[i]
            for p, vm, tri in vol:
                for q in tri:
                    X, Y, Z = xf(q)
                    f.write('v %.6g %.6g %.6g %.4f %.4f %.4f\n' % (X, Y, Z, cr, cg, cb))
                nv += 3
                f.write('f %d %d %d\n' % (nv - 2, nv - 1, nv))
    print(f'wrote {out}  (+ {os.path.basename(mtl)})')
    print(f'  {tiles} region entries, {len(recs)} distinct faces, {len(vols)} volumes, {nv} verts')
    print(f'  faces/volume: min={min(len(x) for x in vols)} max={max(len(x) for x in vols)} '
          f'mean={nv/3/len(vols):.1f}')
    if a.find:
        want = {int(x, 16) for x in a.find.split(',')}
        for i, vol in enumerate(vols):
            hit = [p for p, vm, t in vol if p in want]
            if hit: print('  volume_%03d (%d faces) owns: %s' % (i, len(vol), ' '.join('%05x' % h for h in hit)))
    print(f'  terminators: ' + ', '.join(f'VolumeMode {k}: {n}' for k, n in sorted(modes.items())))

if __name__ == '__main__':
    main()

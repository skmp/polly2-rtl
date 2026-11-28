#!/usr/bin/env python3
"""frames_hw_cmp.py: the console-archive gate's comparison (PLAN M13, 1.4 "gate_frames_hw.sh"; conventions.md 7.4.3):
one item of p2-offline against the console's archived result, judged by the computed refsw3-known
(build/gate/refsw3_known.txt, tools/gate/refsw3_known.sh; P2_KNOWN: another file).

    tools/gate/frames_hw_cmp.py <kind> <name> <run folder> <config> <p2-offline exit status>
    tools/gate/frames_hw_cmp.py --ref <png|vout> <scene> <folder>      refsw3-offline's side for refsw3_known.sh: the
                                                                       line "<kind> <scene> <differ> <of>" of <folder>'s
                                                                       vram.bin (a `save` after the render)

Kinds (tools/gate/frames_hw_run.sh made the run folder):
  test   compare2.py <name> ref off -a (dreamcast-tests, unchanged, PVR_TESTS = the run folder's parent): region by region
         over labels.txt, the whole framebuffer word. A region that differs fails unless refsw3-known has the same region
         differing in at least as many pixels (refsw3-known regions not worse). A page dumped after a VRAM-race render
         (pages.txt: the renders before each page; p2.log's vramrace) is in its own class: its regions that differ are
         reported, never a pass or a fail (PLAN 0 rule 4). Every readback (a test that searches by reading video memory
         back): the RTL's k-th answer equal to refsw3-offline's k-th (the capture's readbacks.txt), because the stream
         after it, and so every page after it, is what the program sent on refsw3's answer; a readback after a VRAM-race
         render is in the race class. Each readback is a check, each differing one a failure.
  set    the test's reader (read.py <folder> off, or read.cpp built in build/hwstream/.tools), then compare_archive.py
         <test> <set> off <folder>: each measured quantity's DIFFER count no more than refsw3-known's for the set; the
         readbacks as for a test.
  png    the frame dumprender.sh dumps (FB_W_SOF1 & 0xfffffc, FB_W_LINESTRIDE * 8 bytes a line, FB_Y_CLIP's lines) out of
         the run's vram.bin against framepng.py's raw bytes of <scene>.hw.png, pixel by pixel (rescore.py's logic): no
         pixel more than refsw3-known's count (0 at 4f3efe15).
  vout   all of video memory against vram_out_<scene>.bin, word by word, and the framebuffer's pixels (polly2dumps.py's
         logic): no more words than refsw3-known's count.
  z      build/tools/ztap_cmp on the run's ztap.txt and fit/zdump_data/<scene>.txt: every depth the console read out
         equal to the RTL's (the key in refsw3's bits, tb/common/zkey.h).
Every kind fails when p2-offline did not exit 0 or 2, or a render did not end. Prints
    frames_hw: <kind>:<name> <config>: <what was compared>; <c> checks, <f> failures
(the checks: pixels, words or readings compared; the failures: those that differ outside refsw3-known and the race
class), the same counts alone on a line "frames_hw: <kind>:<name> <config>: <c> checks, <f> failures" (tools/gate/pq.py's
per-group counts) and "frames_hw: PASS" / "FAIL" (exit 0 / 1).
"""
import gzip
import os
import re
import subprocess
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DCT = os.environ.get("DCTESTS", os.path.join(ROOT, "..", "dreamcast-tests"))
DUMPS = os.environ.get("POLLY2_DUMPS", os.path.join(ROOT, "..", "dreamster", "polly2-rtl", "polly2-data", "dumps"))
KNOWN = os.environ.get("P2_KNOWN", os.path.join(ROOT, "build", "gate", "refsw3_known.txt"))
HWSTREAM = os.environ.get("CAP_HW", os.path.join(ROOT, "build", "hwstream"))
sys.dont_write_bytecode = True
sys.path.insert(0, DCT)
BPP = {0: 2, 1: 2, 2: 2, 3: 2, 4: 3, 5: 4, 6: 4}
REGION = re.compile(r"^  page (\d+) (.*): (\d+) of (\d+) pixels differ;")


def known():
    """refsw3-known: {test: {(page, label): pixels}}, {("set"|"png"|"vout", name): line fields}"""
    tests, other, cur = {}, {}, None
    if not os.path.exists(KNOWN):
        return tests, other
    for line in open(KNOWN):
        line = line.rstrip("\n")
        m = REGION.match(line.replace("    ", "  ", 1)) if line.startswith("    ") else None
        if m and cur is not None:
            tests[cur][(int(m[1]), m[2])] = int(m[3])
            continue
        f = line.split()
        if len(f) >= 2 and f[0] in ("set", "png", "vout"):
            other[(f[0], f[1])] = line
            cur = None
        elif len(f) >= 2 and re.fullmatch(r"\d+/\d+|error", f[1]):
            cur = f[0]
            tests[cur] = {}
    return tests, other


def p2_renders(run):
    out = []
    for l in open(os.path.join(run, "p2.log"), errors="replace"):
        m = re.match(r"p2: render (\d+) isp (\d+) tsp (\d+) video (\d+) vramrace (\d+)", l)
        if m:
            out.append(dict(race=int(m[5]), hung=False, isp=int(m[2]), tsp=int(m[3])))
        elif re.match(r"p2: render (\d+) did not end", l):
            out.append(dict(race=0, hung=True, isp=0, tsp=0))
    return out


def readbacks(name, run, races, tag):
    """every readback's answer against refsw3-offline's (the capture's readbacks.txt, capture_hwstream.sh; the run's
    readbacks.txt and rb_p2.txt, frames_hw_run.sh): (readbacks, equal, after a VRAM-race render and differing, differing
    outside the race class, a problem or None)"""
    cap = os.path.join(HWSTREAM, name, "readbacks.txt")
    order = os.path.join(run, "readbacks.txt")
    if not os.path.exists(order):
        return 0, 0, 0, 0, None
    before = {int(k): int(n) for k, n in (l.split() for l in open(order))}
    if not os.path.exists(cap):
        return len(before), 0, 0, 0, f"{len(before)} readbacks but no {cap} (capture_hwstream.sh again)"
    ref = {int(k): h for k, h in (l.split() for l in open(cap))}
    if len(ref) != len(before):
        return len(before), 0, 0, 0, f"{len(before)} readbacks in the stream, {len(ref)} in {cap}"
    p2f = os.path.join(run, "rb_p2.txt")
    p2 = {int(k): h for k, h in (l.split() for l in open(p2f))} if os.path.exists(p2f) else {}
    eq = rc = bad = 0
    shown = 0
    for k in sorted(before):
        if p2.get(k) == ref[k]:
            eq += 1
        elif any(i < before[k] for i in races):
            rc += 1
        else:
            bad += 1
            if shown < 10:
                shown += 1
                print(f"{tag}: readback {k} (after {before[k]} renders): RTL's answer differs from refsw3-offline's" +
                      (" (p2-offline wrote none)" if p2.get(k, "-") == "-" else ""))
    if rc:
        print(f"{tag}: {rc} readbacks differ after a VRAM-race render (their own class)")
    return len(before), eq, rc, bad, None


def regs_of(name):
    import framepng
    d = os.path.join(DUMPS, name + ".pvrdmp")
    return framepng.regs_of(d if os.path.exists(d) else os.path.join(DUMPS, f"pvr_regs_{name}.bin"))


def png_diff(name, vram):
    """pixels of the dumped frame that differ from the console's <scene>.hw.png, and the frame's pixels"""
    import framepng
    from PIL import Image
    r = regs_of(name)
    sof = int(r[0x60 // 4]) & 0xfffffc
    stride = (int(r[0x4c // 4]) & 0x1ff) * 8
    lines = ((int(r[0x6c // 4]) >> 16) & 0x3ff) + 1
    off = vram[sof:sof + stride * lines].tobytes()
    hw = framepng.to_raw(Image.open(os.path.join(DUMPS, name + ".hw.png")))
    bpp = framepng.BPP[int(r[0x48 // 4]) & 7]
    a = np.frombuffer(off[:len(hw)], np.uint8)
    b = np.frombuffer(hw, np.uint8)
    if len(a) != len(b):
        return -1, len(b) // bpp
    return int((a.reshape(-1, bpp) != b.reshape(-1, bpp)).any(-1).sum()), len(b) // bpp


def vout_diff(name, vram):
    """words of video memory that differ from vram_out_<scene>.bin; framebuffer pixels that differ, of"""
    import polly2dumps
    hw = np.fromfile(os.path.join(DUMPS, f"vram_out_{name}.bin"), dtype=np.uint8)
    words = int((hw.view(np.uint32) != vram.view(np.uint32)).sum()) if hw.size == vram.size else -1
    regs = np.fromfile(os.path.join(DUMPS, f"pvr_regs_{name}.bin"), dtype=np.uint32)
    fh, fs = polly2dumps.framebuffer(hw, regs), polly2dumps.framebuffer(vram, regs)
    if fh is None or fs is None:
        return words, 0, 0
    return words, int((~(fh == fs).all(-1)).sum()), fh.shape[0] * fh.shape[1]


def ref_main(kind, name, folder):
    vram = np.fromfile(os.path.join(folder, "vram.bin"), dtype=np.uint8)
    if kind == "png":
        n, of = png_diff(name, vram)
        print(f"png {name} {n} {of}")
    else:
        w, n, of = vout_diff(name, vram)
        print(f"vout {name} {w} {n} {of}")


def main():
    if sys.argv[1] == "--ref":
        return ref_main(*sys.argv[2:5])
    kind, name, run, cfg, status = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
    tag = f"frames_hw: {kind}:{name} {cfg}"
    ktests, kother = known()
    fail = status not in (0, 2)
    if fail:
        print(f"{tag}: p2-offline exit {status}")
    rend = p2_renders(run) if os.path.exists(os.path.join(run, "p2.log")) else []
    for i, r in enumerate(rend):
        if r["hung"]:
            print(f"{tag}: render {i} did not end")
            fail = True
    races = [i for i, r in enumerate(rend) if r["race"]]
    clk = f"{len(rend)} renders, ISP {sum(r['isp'] for r in rend)} / TSP {sum(r['tsp'] for r in rend)} clk"
    checks = failures = 0
    what = ""
    if kind == "test":
        tainted = set()
        pf = os.path.join(run, "pages.txt")
        if os.path.exists(pf):
            for l in open(pf):
                f, n = l.split()
                m = re.match(r"page(\d+)\.", f)
                if m and any(i < int(n) for i in races):
                    tainted.add(int(m[1]))
        env = dict(os.environ, PVR_TESTS=os.path.dirname(run), PYTHONDONTWRITEBYTECODE="1")
        p = subprocess.run(["python3", "-B", os.path.join(DCT, "compare2.py"), name, "ref", "off", "-a"],
                           capture_output=True, text=True, env=env)
        lines = p.stdout.splitlines()
        last = lines[-1] if lines else ""
        m = re.search(r"in (\d+) of (\d+) regions, on (\d+) of (\d+) pixels", last)
        if p.returncode or not m:
            print(f"{tag}: compare2.py failed: {(p.stderr or p.stdout).strip().splitlines()[-1:]}")
            print("frames_hw: FAIL")
            return 1
        checks = int(m[4])
        kreg = ktests.get(name)
        if kreg is None:
            print(f"{tag}: not in refsw3-known ({KNOWN}): run tools/gate/refsw3_known.sh")
            fail = True
            kreg = {}
        nk = nr = better = 0
        for l in lines[:-1]:
            r = REGION.match(l)
            if not r:
                continue
            key, n = (int(r[1]), r[2]), int(r[3])
            if key[0] in tainted:
                nr += 1
                print(f"{tag}: VRAM-race page {key[0]} {key[1]}: {n} pixels differ (their own class)")
            elif key in kreg and n <= kreg[key]:
                nk += 1
                print(f"{tag}: refsw3-known page {key[0]} {key[1]}: {n} pixels differ (refsw3 {kreg[key]})")
            else:
                failures += n
                fail = True
                print(f"{tag}: page {key[0]} {key[1]}: {n} pixels differ" +
                      (f", refsw3 {kreg[key]} (worse)" if key in kreg else ", refsw3 equal there") + l[l.index(";"):])
        diffkeys = {(int(r[1]), r[2]) for r in map(REGION.match, lines[:-1]) if r}
        better = sum(1 for k in kreg if k not in diffkeys)
        stale = ""
        crc = os.path.join(run, "off.crc")
        with open(os.path.join(run, "p2.log"), errors="replace") as f:
            open(crc, "w").writelines(l for l in f if l.startswith("PVRIO crc"))
        hwcrc = os.path.join(DCT, "fit", "hw", name, "hw.crc")
        if os.path.exists(hwcrc) and open(hwcrc).read() != open(crc).read():
            stale = "; input-stale (off.crc is not the archived hw.crc)"
        nrb, rbeq, rbrc, rbbad, rberr = readbacks(name, run, races, tag)
        if rberr:
            print(f"{tag}: {rberr}")
            fail = True
        checks += nrb
        failures += rbbad
        fail |= rbbad > 0
        what = (f"console = RTL in {m[1]} of {m[2]} regions ({nk} refsw3-known, not worse; {better} refsw3-known now "
                f"equal; {nr} after a VRAM-race render, {len(tainted)} race pages){stale}; readbacks {rbeq} of {nrb} "
                f"refsw3-offline's ({rbrc} after a VRAM-race render); {clk}")
    elif kind == "set":
        t, s = name.split("@", 1)
        s = s.split("+", 1)[0]
        td = next(os.path.join(DCT, g, t) for g in ("pvr-tests", "ta-tests") if os.path.isdir(os.path.join(DCT, g, t)))
        if os.path.exists(os.path.join(td, "read.cpp")):
            rd = [os.path.join(HWSTREAM, ".tools", f"{t}_read"), run, "off"]
        else:
            rd = ["python3", "-B", os.path.join(td, "read.py"), run, "off"]
        p = subprocess.run(rd, capture_output=True, text=True, cwd=run)
        if p.returncode:
            print(f"{tag}: the reader failed: {(p.stderr or p.stdout).strip().splitlines()[-2:]}")
            print("frames_hw: FAIL")
            return 1
        p = subprocess.run(["python3", "-B", os.path.join(DCT, "compare_archive.py"), t, s, "off", run],
                           capture_output=True, text=True, env=dict(os.environ, OFFLINE_TOOL="p2-offline"))
        line = (p.stdout.strip().splitlines() or [""])[-1]
        parts = re.findall(r"(\d+) of (\d+) ([a-z ]+?)(?: \((\d+) DIFFER\))?(?:;|$)", line)
        if p.returncode or not parts:
            print(f"{tag}: compare_archive.py failed: {(p.stderr or p.stdout).strip().splitlines()[-1:]}")
            print("frames_hw: FAIL")
            return 1
        kl = kother.get(("set", name))
        kparts = {q[2]: int(q[3] or 0) for q in re.findall(r"(\d+) of (\d+) ([a-z ]+?)(?: \((\d+) DIFFER\))?(?:;|$)", kl)} if kl else None
        if kparts is None:
            print(f"{tag}: not in refsw3-known ({KNOWN})")
            fail = True
            kparts = {}
        for a, b, w, d in parts:
            checks += int(b)
            d = int(d or 0)
            if d and races:
                print(f"{tag}: {d} {w} differ after VRAM-race renders (their own class)")
            elif d > kparts.get(w, 0):
                failures += d - kparts.get(w, 0)
                fail = True
                print(f"{tag}: {d} {w} differ, refsw3 {kparts.get(w, 0)}")
        nrb, rbeq, rbrc, rbbad, rberr = readbacks(name, run, races, tag)
        if rberr:
            print(f"{tag}: {rberr}")
            fail = True
        checks += nrb
        failures += rbbad
        fail |= rbbad > 0
        what = (f"{line.split(': ', 1)[-1]}; refsw3-known: {kl.split(': ', 1)[-1] if kl else '-'}; readbacks {rbeq} of "
                f"{nrb} refsw3-offline's ({rbrc} after a VRAM-race render); {clk}")
    elif kind in ("png", "vout"):
        f = os.path.join(run, "vram.bin")
        if not os.path.exists(f):
            print(f"{tag}: no save from p2-offline")
            print("frames_hw: FAIL")
            return 1
        vram = np.fromfile(f, dtype=np.uint8)
        kl = kother.get((kind, name))
        kf = kl.split() if kl else None
        if kf is None:
            print(f"{tag}: not in refsw3-known ({KNOWN})")
            fail = True
        if kind == "png":
            n, of = png_diff(name, vram)
            checks = of
            kn = int(kf[2]) if kf else 0
            what = f"{of - n if n >= 0 else 0} of {of} frame pixels the console's (refsw3 {kn} differ); {clk}"
            if n < 0 or n > kn:
                if races:
                    print(f"{tag}: {n} pixels differ after a VRAM-race render (their own class)")
                else:
                    failures = max(n, 1)
                    fail = True
        else:
            w, n, of = vout_diff(name, vram)
            checks = vram.size // 4
            kw = int(kf[2]) if kf else 0
            what = f"{w} words of video memory differ (refsw3 {kw}), framebuffer {of - n} of {of} pixels; {clk}"
            if w < 0 or w > kw:
                if races:
                    print(f"{tag}: {w} words differ after a VRAM-race render (their own class)")
                else:
                    failures = max(w, 1)
                    fail = True
    elif kind == "z":
        p = subprocess.run([os.path.join(ROOT, "build", "tools", "ztap_cmp"), os.path.join(run, "ztap.txt"),
                            os.path.join(DCT, "fit", "zdump_data", name + ".txt")], capture_output=True, text=True)
        print(p.stdout, end="")
        # its last line first: "ztap_cmp: <n> of <N> depths" whenever it compared (exit 1 then means a depth differs or a
        # pixel's tile was not tapped); a tool failure only without that line
        last = (p.stdout.strip().splitlines() or [""])[-1]
        m = re.match(r"ztap_cmp: (\d+) of (\d+) depths", last)
        if not m:
            print(f"{tag}: ztap_cmp failed (exit {p.returncode}): {(p.stderr or p.stdout).strip()[-200:]}")
            fail = True
        else:
            untapped = len(re.findall(r"not tapped$", p.stdout, re.M))
            checks = int(m[2])
            failures = int(m[2]) - int(m[1])
            fail |= failures > 0 or p.returncode != 0 or checks == 0
            what = (f"{m[1]} of {m[2]} archived depths the console's" + (f" ({untapped} not tapped)" if untapped else "") +
                    f"; {clk}")
    nf = failures + (1 if fail and not failures else 0)
    if races:
        # PLAN 5 D13: the item's VRAM-race renders, for tb/frames/races_expected.txt (tools/gate/races_expected.py)
        print(f"{tag}: VRAM-race renders " + " ".join(f"r{i}" for i in races))
    print(f"{tag}: {what}; {checks} checks, {nf} failures")
    # the queue's per-group counts (tools/gate/pq.py reads ": <c> checks, <f> failures" at a line's end)
    print(f"{tag}: {checks} checks, {nf} failures")
    print("frames_hw: " + ("FAIL" if fail else "PASS"))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())

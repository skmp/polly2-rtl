"""tmlib.py: what the timing tools share (PLAN MT0, 1.5; conventions.md 7.6): the timemeas PC emission's command stream,
p2-offline's logs of it, the console's archived logs and K.

The stream (dreamcast-tests pvr-tests/timemeas, `make -C pvr-tests/timemeas emit`, main.c TM_EMIT): every measured render
is preceded by "echo T <what> <a> <b> <c> <d>", every palette clock render by "echo O <what> <k> <tiles>"; a scene owns
the renders (reg STARTRENDER) up to the next such line. Any other echo line (F, L, P, R, "T display", "T end") is what the
console prints too, passed through.

p2-offline's log of it (stdout and stderr in one file, P2_TIMING=1): the echo lines, and for each render a "p2: timing
..." line (rtl/v1/p2_core.sv's timing tap) and its "p2: render <n> ..." line, or "p2: render <n> skipped" (P2_RENDERS), or
"p2: render <n> did not end".

The console's logs (fit/timemeas_logs/timemeas_run*.log, analyze.py's): "T <what> a b c d W <isp least> <isp middle>
<tsp least> <tsp middle> <tsp-isp least> <tsp-isp middle> P ...", counts of 5 ns (2 a clock); several runs are combined
by the least of every number, as analyze.py does.
"""
import glob
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
K_FILE = os.path.join(ROOT, "tb", "timing", "k.txt")

_NUM = re.compile(r"^-?\d+$")


def scene_line(words):
    """("T", key) for a measured scene's echo, ("O", key) for a palette clock scene's, else None. key: the words after
    the letter, joined by one space."""
    if len(words) == 6 and words[0] == "T" and all(_NUM.match(w) for w in words[2:6]):
        return "T", " ".join(words[1:])
    if len(words) == 4 and words[0] == "O" and all(_NUM.match(w) for w in words[2:4]):
        return "O", " ".join(words[1:])
    return None


def index_stream(path):
    """The stream's scenes in order: a list of dicts kind, key, first (render index), n (renders)."""
    scenes, r = [], 0
    with open(path, errors="replace") as f:
        for line in f:
            if line.startswith("echo "):
                s = scene_line(line.split()[1:])
                if s:
                    scenes.append({"kind": s[0], "key": s[1], "first": r, "n": 0})
            elif line.startswith("reg STARTRENDER") or line.startswith("reg 0014 ") or line.strip() == "render":
                if scenes:
                    scenes[-1]["n"] += 1
                r += 1
    return scenes


def parse_kv(words):
    d = {}
    for i in range(0, len(words) - 1, 2):
        try:
            d[words[i]] = int(words[i + 1])
        except ValueError:
            d[words[i]] = words[i + 1]
    return d


def parse_sim_log(path):
    """p2-offline's log: a list of scenes in stream order, each a dict kind, key, renders (a list of dicts: n, isp, tsp,
    video, vramrace and the timing tap's fields; skipped renders left out; a render that did not end: hung = 1), and
    the pass-through lines (other echo output) as `lines` with their scene index (-1: before the first scene)."""
    scenes, other = [], []
    pend = None
    with open(path, errors="replace") as f:
        for line in f:
            w = line.split()
            if not w:
                continue
            if w[0] == "p2:":
                if len(w) > 1 and w[1] == "timing":
                    pend = dict(pend or {}, **parse_kv(w[2:]))
                elif len(w) > 3 and w[1] == "timed" and w[2] == "writes":
                    pend = dict(pend or {}, writes=int(w[3]))
                elif len(w) > 3 and w[1] == "render":
                    if w[3] == "skipped":
                        pend = None
                        continue
                    rec = {"n": int(w[2])}
                    if w[3] == "did":
                        rec["hung"] = 1
                    else:
                        rec.update(parse_kv(w[3:]))
                        if pend:
                            for k, v in pend.items():
                                rec.setdefault("t_" + k, v)
                    pend = None
                    if scenes:
                        scenes[-1]["renders"].append(rec)
                continue
            if w[0].startswith("PVRIO") or w[0].startswith("refsw3-offline") or w[0].startswith("pvrio"):
                continue
            s = scene_line(w)
            if s:
                scenes.append({"kind": s[0], "key": s[1], "renders": []})
            else:
                other.append((len(scenes) - 1, line.rstrip("\n")))
    return scenes, other


def merge_chunks(paths):
    """Several logs of one stream (each clocked a part of its renders): one scene list with every scene's renders, and the
    pass-through lines; a scene's own lines (those echoed after it: an order scene's R lines, read back from its render)
    from the log that clocked it."""
    merged, per = None, []
    for p in paths:
        sc, ot = parse_sim_log(p)
        had = [bool(x["renders"]) for x in sc]
        if merged is None:
            merged = sc
        elif [(s["kind"], s["key"]) for s in sc] != [(s["kind"], s["key"]) for s in merged]:
            raise SystemExit(f"tmlib: {p}: not the same stream as {paths[0]}")
        else:
            for a, b in zip(merged, sc):
                a["renders"].extend(b["renders"])
        by = {}
        for i, l in ot:
            by.setdefault(i, []).append(l)
        per.append((had, by))
    merged = merged or []
    other = []
    for i in range(-1, len(merged)):
        src = per[0][1] if per else {}
        if i >= 0:
            for had, by in per:
                if had[i]:
                    src = by
                    break
        other.extend((i, l) for l in src.get(i, []))
    for s in merged:
        s["renders"].sort(key=lambda r: r["n"])
    return merged, other


def timed(renders):
    """The renders a console would time: all of them if one, else all but the first (the warm-up)."""
    rs = [r for r in renders if not r.get("hung")]
    return rs if len(rs) <= 1 else rs[1:]


def least_middle(vals):
    v = sorted(vals)
    return v[0], v[len(v) // 2]


def load_console(folder, pattern="timemeas_run*.log"):
    """{key: (isp least, isp middle, tsp least, tsp middle, dif least, dif middle)} in counts, the least of every number
    over the logs (analyze.py's load)."""
    D = {}
    for f in sorted(glob.glob(os.path.join(folder, pattern))):
        for line in open(f, errors="replace"):
            p = line.split()
            if len(p) >= 13 and p[0] == "T" and p[6] == "W":
                key = " ".join(p[1:6])
                try:
                    v = tuple(int(x) for x in p[7:13])
                except ValueError:
                    continue
                old = D.get(key)
                D[key] = v if old is None else tuple(min(a, b) for a, b in zip(old, v))
    return D


def read_cfg(name, path=K_FILE):
    """A value of tb/timing/k.txt: the line "<name> <value>" (K, VR_ROW)."""
    with open(path) as f:
        for line in f:
            w = line.split()
            if len(w) >= 2 and w[0] == name:
                return float(w[1])
    raise SystemExit(f"tmlib: no {name} line in {path}")


def read_k(path=K_FILE):
    """K (clocks) from tb/timing/k.txt."""
    return read_cfg("K", path)

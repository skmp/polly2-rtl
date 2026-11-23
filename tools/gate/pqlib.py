"""pqlib.py: the gates' work queue (PLAN 0 rule 8): one pool of J slots, tasks taken longest first, a task holding the
slots it says it uses (a test item 1, a build of make -jB B), every command's wall and CPU time measured.

Used by tools/gate/pq.py (a gate's test items) and tools/gate/mutants.py (builds and probe runs of the mutants).

    pool = Pool(slots)
    pool.submit(prio, weight, fn, group=None)   fn() runs on a thread of its own once `weight` slots are free; tasks
                                                start in order of prio (largest first), a smaller one may start beside a
                                                larger one that waits for slots; fn may submit further tasks
    pool.cancel(group)                          tasks of the group not started are dropped; commands of the group that
                                                run (started with run_cmd(..., group=...)) are killed
    pool.wait()                                 until nothing is queued or running
    run_cmd(pool, cmd, log, ...)                a shell command (bash -c), its output appended to log, in a process
                                                group of its own; returns (exit code or None if cancelled, wall s, CPU s)

J's default: default_jobs(), tools/gate/jobs.sh's (P2_J, else nproc - 4 but at most the physical cores).

A task's prio is its predicted seconds (the cost file's wall, else an estimate). When the queue is bound by its
longest task (a pole: a case that cannot be cut further), more workers beside it only slow it down (on this box N
copies at once run up to 3x slower each: memory and the shared power budget), so the pool holds slots back: it starts
a task only while the slots in use stay within the pole's weight + ceil(1.25 W / P), P the pole's predicted remaining
seconds, W the predicted seconds of everything else (queued, and the rest of the other running tasks). Then the other
work ends about when the pole does, with the fewest workers beside it. A pole that has overrun its prediction counts as
none. P2_POLE=0: no holding back (J workers whenever there is work).
"""
import heapq
import math
import os
import signal
import subprocess
import threading
import time


def default_jobs():
    try:
        out = subprocess.run(["bash", os.path.join(os.path.dirname(os.path.abspath(__file__)), "jobs.sh")],
                             capture_output=True, text=True).stdout.strip()
        return max(1, int(out))
    except (OSError, ValueError):
        return max(1, (os.cpu_count() or 4) - 4)


class Pool:
    def __init__(self, slots):
        self.slots = max(1, int(slots))
        self.free = self.slots
        self.cv = threading.Condition()
        self.heap = []
        self.seq = 0
        self.running = 0
        self.cancelled = set()
        self.procs = {}             # group -> set of Popen running
        self.errors = []
        self.live = {}              # seq -> (start time, prio, weight) of the running tasks
        self.pole = os.environ.get("P2_POLE", "1") != "0"

    def submit(self, prio, weight, fn, group=None):
        with self.cv:
            heapq.heappush(self.heap, (-prio, self.seq, min(max(1, int(weight)), self.slots), fn, group))
            self.seq += 1
            self.cv.notify_all()

    def cancel(self, group):
        with self.cv:
            self.cancelled.add(group)
            procs = list(self.procs.get(group, ()))
        for p in procs:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass

    def is_cancelled(self, group):
        with self.cv:
            return group is not None and group in self.cancelled

    def _take(self, room):
        """the next task to start in `room` slots (the lock held): the head if it fits, else the first that fits; None
        if none"""
        while self.heap and self.heap[0][4] is not None and self.heap[0][4] in self.cancelled:
            heapq.heappop(self.heap)
        if not self.heap:
            return None
        if self.heap[0][2] <= room:
            return heapq.heappop(self.heap)
        for i, t in enumerate(sorted(self.heap)):
            if t[4] is not None and t[4] in self.cancelled:
                continue
            if t[2] <= room:
                self.heap.remove(t)
                heapq.heapify(self.heap)
                return t
        return None

    def _cap(self):
        """the slots the pool may have in use now (the lock held): the header's pole rule"""
        if not self.pole or not self.live:
            return self.slots
        now = time.monotonic()
        rem = [(max(0.0, pr - (now - st)), w) for st, pr, w in self.live.values()]
        P, pw = max(rem)
        if P <= 0:
            return self.slots
        W = sum(r * w for r, w in rem) - P * pw
        W += sum(-t[0] * t[2] for t in self.heap if not (t[4] is not None and t[4] in self.cancelled))
        return max(1, min(self.slots, pw + math.ceil(1.25 * W / P)))

    def _run(self, t):
        try:
            t[3]()
        except Exception as e:          # a bug in a task: recorded, the pool goes on
            with self.cv:
                self.errors.append(repr(e))
        finally:
            with self.cv:
                self.free += t[2]
                self.running -= 1
                self.live.pop(t[1], None)
                self.cv.notify_all()

    def wait(self):
        with self.cv:
            while True:
                # the slots free under the pole rule (the header); the cap is looked at again every few seconds
                # (a task is started while some room is left; it may take more slots than the room, up to the free)
                room = self.free - (self.slots - self._cap())
                t = self._take(self.free) if room > 0 and self.free > 0 else None
                if t is not None:
                    self.free -= t[2]
                    self.running += 1
                    self.live[t[1]] = (time.monotonic(), -t[0], t[2])
                    threading.Thread(target=self._run, args=(t,), daemon=True).start()
                    continue
                if not self.heap and self.running == 0:
                    return
                self.cv.wait(timeout=2.0)


def run_cmd(pool, cmd, log, cwd=None, env=None, group=None, mode="w"):
    """cmd: a string (run by bash -c) or an argument list. Returns (exit code, wall s, CPU s); the exit code is None if
    the group was cancelled before or while it ran."""
    if pool is not None and pool.is_cancelled(group):
        return None, 0.0, 0.0
    os.makedirs(os.path.dirname(os.path.abspath(log)), exist_ok=True)
    args = ["bash", "-c", cmd] if isinstance(cmd, str) else cmd
    t0 = time.monotonic()
    with open(log, mode) as f:
        if mode == "a":
            f.write("$ " + (cmd if isinstance(cmd, str) else " ".join(cmd)) + "\n")
            f.flush()
        p = subprocess.Popen(args, cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                             start_new_session=True)
        if pool is not None:
            with pool.cv:
                pool.procs.setdefault(group, set()).add(p)
        killed = pool is not None and pool.is_cancelled(group)
        if killed:
            os.killpg(p.pid, signal.SIGKILL)
        _, status, ru = os.wait4(p.pid, 0)
        p.returncode = os.waitstatus_to_exitcode(status)
        if pool is not None:
            with pool.cv:
                pool.procs[group].discard(p)
    wall = time.monotonic() - t0
    cpu = ru.ru_utime + ru.ru_stime
    if pool is not None and pool.is_cancelled(group):
        return None, wall, cpu
    return p.returncode, wall, cpu


def read_cost(path):
    """the cost file: lines "<group>\\t<id>\\t<wall s>\\t<CPU s>"; {(group, id): wall}"""
    cost = {}
    try:
        for line in open(path):
            f = line.rstrip("\n").split("\t")
            if len(f) >= 3:
                try:
                    cost[(f[0], f[1])] = float(f[2])
                except ValueError:
                    pass
    except OSError:
        pass
    return cost


def write_cost(path, rows, groups):
    """rows: (group, id, wall, cpu) of this run; merged into the file: an item that ran replaces its own entry, every
    other entry is kept (a sampled run, PLAN 0 rule 10, runs part of a group: the items it did not draw keep their
    costs; M9's verifier found a sampled run erasing them when a group's entries were replaced as a whole). `groups`
    (the groups run) is no longer needed and kept for the callers. An item a later list no longer has keeps its line;
    read_cost's users look items up by (group, id), so such a line is never read"""
    ran = set((g, i) for g, i, _w, _c in rows)
    old = []
    try:
        for line in open(path):
            f = line.rstrip("\n").split("\t")
            if len(f) >= 3 and (f[0], f[1]) not in ran:
                old.append(line.rstrip("\n"))
    except OSError:
        pass
    tmp = path + ".tmp"
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(tmp, "w") as f:
        for line in old:
            f.write(line + "\n")
        for g, i, w, c in rows:
            f.write(f"{g}\t{i}\t{w:.2f}\t{c:.2f}\n")
    os.replace(tmp, path)

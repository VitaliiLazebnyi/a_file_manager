#!/usr/bin/env python3
"""Runs one command exclusively (a lock shared by every heavy run), with a timeout.
On a timeout the command's descendants are sampled (`sample`) and then killed by pid.
With --max-rss-mb the resident memory of the command and its descendants is added up twice a
second; above the limit they are killed (exit code "RSS") so that a leak cannot take the machine.
The lock and nothing else lives in ../out/.
usage: run.py [--timeout S] [--max-rss-mb N] [--log FILE] [--nolock] [--cwd DIR] [--env K=V]... -- cmd args...
"""
import os, sys, subprocess, time, signal

S = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(S, "out")
os.makedirs(OUT, exist_ok=True)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


_held = None


def acquire():
    # A kernel lock: it cannot be stolen and is given back when this process ends, however it ends.
    global _held
    import fcntl
    _held = open(os.path.join(OUT, "measure.flock"), "w")
    fcntl.flock(_held, fcntl.LOCK_EX)
    _held.write(str(os.getpid()) + "\n"); _held.flush()


def release():
    global _held
    if _held:
        _held.close()
        _held = None


def descendants(root):
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, text=True).stdout
    kids = {}
    names = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid, ppid = int(parts[0]), int(parts[1])
        kids.setdefault(ppid, []).append(pid)
        names[pid] = parts[2]
    found, stack = [], [root]
    while stack:
        p = stack.pop()
        for k in kids.get(p, []):
            found.append((k, names.get(k, "?")))
            stack.append(k)
    return found


def rss_mb(pids):
    out = subprocess.run(["ps", "-o", "rss=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    return sum(int(x) for x in out.split() if x.isdigit()) / 1024


def main():
    args = sys.argv[1:]
    timeout, log, lock, cwd, env, max_rss = None, None, True, None, dict(os.environ), None
    while args and args[0] != "--":
        a = args.pop(0)
        if a == "--timeout": timeout = float(args.pop(0))
        elif a == "--max-rss-mb": max_rss = float(args.pop(0))
        elif a == "--log": log = args.pop(0)
        elif a == "--nolock": lock = False
        elif a == "--cwd": cwd = args.pop(0)
        elif a == "--env":
            k, v = args.pop(0).split("=", 1); env[k] = v
        else: sys.exit("bad arg " + a)
    cmd = args[1:]
    if lock: acquire()
    code = None
    try:
        out = open(log, "ab") if log else None
        load0 = os.getloadavg()
        t0 = time.time()
        p = subprocess.Popen(cmd, stdout=out or None, stderr=subprocess.STDOUT if out else None, cwd=cwd, env=env, start_new_session=True)
        peak = 0.0
        try:
            if max_rss is None:
                code = p.wait(timeout=timeout)
            else:
                while True:
                    try:
                        code = p.wait(timeout=0.5)
                        break
                    except subprocess.TimeoutExpired:
                        pass
                    used = rss_mb([p.pid] + [pid for pid, _ in descendants(p.pid)])
                    peak = max(peak, used)
                    if used > max_rss:
                        code = "RSS"
                        for pid, name in descendants(p.pid) + [(p.pid, "root")]:
                            try: os.kill(pid, signal.SIGKILL)
                            except OSError: pass
                        p.wait()
                        break
                    if timeout is not None and time.time() - t0 > timeout:
                        raise subprocess.TimeoutExpired(cmd, timeout)
        except subprocess.TimeoutExpired:
            code = "TIMEOUT"
            for pid, name in descendants(p.pid):
                base = os.path.basename(name)
                if base in ("sample",): continue
                if log and not base.startswith("swift-"):
                    try:
                        subprocess.run(["sample", str(pid), "3", "-file", f"{log}.hang.{base}.{pid}.sample.txt"], capture_output=True, timeout=90)
                    except subprocess.TimeoutExpired:
                        pass
            for pid, name in descendants(p.pid) + [(p.pid, "root")]:
                try: os.kill(pid, signal.SIGKILL)
                except OSError: pass
            p.wait()
        wall = time.time() - t0
        line = f"RUN exit={code} wall={wall:.1f}s load_before={load0[0]:.1f} load_after={os.getloadavg()[0]:.1f}"
        if max_rss is not None: line += f" rss_limit={max_rss:.0f}MB rss_seen={peak:.0f}MB"
        line += f" cmd={' '.join(cmd)[:200]}"
        print(line)
        if out:
            out.write((line + "\n").encode()); out.close()
    finally:
        if lock: release()
    sys.exit(0 if code == 0 else 1)


main()

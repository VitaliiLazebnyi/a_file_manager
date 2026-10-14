#!/usr/bin/env python3
"""One block of figures per log of a stress run: the columns of the table in report 25.
usage: summary.py LOG...
"""
import re, sys, os

for path in sys.argv[1:]:
    try:
        text = open(path, errors="replace").read()
    except OSError as error:
        print(f"{path}: {error}"); continue
    lines = text.splitlines()
    run = re.search(r"RUN exit=(\S+) wall=([\d.]+)s load_before=([\d.]+) load_after=([\d.]+)(?: rss_limit=(\d+)MB rss_seen=(\d+)MB)?", text)
    rss = re.search(r"(\d+)\s+maximum resident set size", text)
    total = None
    for line in lines:
        if line.startswith("TOTAL"):
            total = line.split()
    loads = [float(x) for x in re.findall(r"load=([\d.]+)", text)]
    if run: loads += [float(run.group(3)), float(run.group(4))]
    threads = [l.strip() for l in lines if re.search(r"^(threads: baseline|threads: baseline \d|FINAL threads|THREADS baseline|threads after closing|  threads after closing)", l)]
    failures = [l.strip() for l in lines if re.match(r"\s*(FAILURES|VIOLATIONS|FAIL:|!!!! HANG)", l)]
    print(f"== {os.path.basename(path)}")
    if run:
        print(f"   exit {run.group(1)}, wall {run.group(2)} s" + (f", killed above {run.group(5)} MB (seen {run.group(6)} MB)" if run.group(1) == "RSS" else ""))
    if rss: print(f"   peak RSS {int(rss.group(1)) / 1048576:.0f} MB")
    if total and len(total) >= 7:
        print(f"   main thread: max stall {total[6]} ms; stalls >8 ms {total[3]}, >100 ms {total[4]}, >1 s {total[5]} (watched {total[1]} s)")
    for line in threads[-3:]: print("   " + line[:200])
    if loads: print(f"   load average during the run {min(loads):.1f}-{max(loads):.1f}")
    for line in failures[:12]: print("   " + line[:220])

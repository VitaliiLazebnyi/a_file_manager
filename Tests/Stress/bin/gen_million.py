#!/usr/bin/env python3
"""Makes the directory of scenario 1: `files` empty-ish files named item0000000.<ext> with twelve
extensions in turn (so `*.txt;*.swift;*.jpg;*.png` marks a third of them) and 200 folders.
usage: gen_million.py DIR [files=1000000]
About 1.5 minutes and 4 GB of disk (the file system's own records) for a million.
"""
import os, sys, time
target = sys.argv[1]
files = int(sys.argv[2]) if len(sys.argv) > 2 else 1_000_000
extensions = ["txt", "swift", "jpg", "png", "md", "pdf", "c", "h", "json", "xml", "log", "dat"]
os.makedirs(target, exist_ok=True)
t0 = time.time()
directory = os.open(target, os.O_RDONLY)
flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
for i in range(files):
    fd = os.open("item%07d.%s" % (i, extensions[i % 12]), flags, 0o644, dir_fd=directory)
    if i % 7:
        os.write(fd, b"x" * (i % 7))
    os.close(fd)
for i in range(200):
    os.mkdir("folder%03d" % i, dir_fd=directory)
os.close(directory)
print("made %d files and 200 folders in %s in %.0f s" % (files, target, time.time() - t0))

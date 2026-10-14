#!/usr/bin/env python3
"""Builds the archives of scenario 5.
usage: gen_zips.py OUTDIR [entries=200000] [chain=2000]
  big.zip    `entries` tiny members in entries/500 folders, plus probe/ with 64 members of
             mixed sizes and methods; probe-ref/ holds the same 64 files raw, probe.tsv their
             name, size and CRC-32.
  deep.zip   one chain `chain` folders deep with a file at the bottom, a binary tree 12 deep
             with a file at every node, and a member with a 60,000-byte path.
"""
import os, sys, zipfile, zlib, random, time

out = sys.argv[1]
entries = int(sys.argv[2]) if len(sys.argv) > 2 else 200000
chain = int(sys.argv[3]) if len(sys.argv) > 3 else 2000
os.makedirs(out, exist_ok=True)
os.makedirs(os.path.join(out, "probe-ref"), exist_ok=True)
rnd = random.Random(5)
t0 = time.time()

with zipfile.ZipFile(os.path.join(out, "big.zip"), "w", zipfile.ZIP_STORED, allowZip64=True) as z:
    for i in range(entries):
        z.writestr("dir%04d/f%06d.txt" % (i // 500, i), "entry %d\n" % i)
    sizes = [rnd.randrange(0, 256 << 10) for _ in range(46)] + [0, 1] + [rnd.randrange(1 << 20, 4 << 20) for _ in range(12)] + [24 << 20] * 4
    with open(os.path.join(out, "probe.tsv"), "w") as manifest:
        for n, size in enumerate(sizes):
            kind = n % 3
            if kind == 0:  # random: does not compress
                data = rnd.randbytes(size)
            elif kind == 1:  # text: compresses well
                line = b"".join(b"line %d of probe %d\n" % (k, n) for k in range(2000))
                data = (line * (size // len(line) + 1))[:size]
            else:  # mixed
                block = rnd.randbytes(4096)
                data = bytearray()
                k = 0
                while len(data) < size:
                    data += block[: rnd.randrange(64, 4096)] + (b"%d" % k) * 50
                    k += 1
                data = bytes(data[:size])
            name = "probe/p%02d.bin" % n
            method = zipfile.ZIP_STORED if n % 4 == 0 else zipfile.ZIP_DEFLATED
            z.writestr(zipfile.ZipInfo(name, date_time=(2024, 1, 2, 3, 4, 6)), data, compress_type=method)
            open(os.path.join(out, "probe-ref", "p%02d.bin" % n), "wb").write(data)
            manifest.write("%s\t%d\t%d\n" % (name, len(data), zlib.crc32(data) & 0xFFFFFFFF))
print("big.zip: %d members, %.1f MB, %.1fs" % (entries + 64, os.path.getsize(os.path.join(out, "big.zip")) / 1e6, time.time() - t0))

t0 = time.time()
count = 0
with zipfile.ZipFile(os.path.join(out, "deep.zip"), "w", zipfile.ZIP_DEFLATED, allowZip64=True) as z:
    z.writestr("c/" * chain + "leaf.txt", "bottom of the chain\n")
    count += 1
    def tree(path, depth):
        global count
        z.writestr(path + "node.txt", "node %s\n" % path)
        count += 1
        if depth < 12:
            tree(path + "0/", depth + 1)
            tree(path + "1/", depth + 1)
    tree("t/", 0)
    z.writestr("long/" + "/".join(["n" * 250] * 238) + "/end.txt", "long path\n")
    count += 1
print("deep.zip: %d members, chain %d, %.1f MB, %.1fs" % (count, chain, os.path.getsize(os.path.join(out, "deep.zip")) / 1e6, time.time() - t0))

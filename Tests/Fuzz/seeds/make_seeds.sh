#!/bin/bash
# Seed archives made with the system tools and with Python's zipfile/tarfile (hostile names).
set -u
# Run from anywhere: the seeds are written next to this script. The program's own packer adds its
# seeds afterwards:  ../build.sh rel fuzz-arch && ../out/build-rel/release/fuzz-arch mkseeds "$PWD"
S=$(cd "$(dirname "$0")" && pwd); T=$S/tree.tmp
rm -rf $S/zip $S/tar $S/tgz $S/txz $S/bz $T; mkdir -p $S/zip $S/tar $S/tgz $S/txz $S/bz $T/t/sub/deep $T/t/hollow
cd $T
printf 'hello world\n' > t/a.txt; : > t/empty.txt; printf 'unicode' > "t/sub/deep/übung – ñ 日本.txt"; printf 'hidden' > t/sub/.hidden
head -c 300 /dev/urandom > t/sub/r.bin; yes 'All work and no play' | head -40 > t/sub/jack.txt
ln -s a.txt t/link; ln -s ../a.txt t/sub/uplink; ln t/a.txt t/hard.txt
L=$(printf 'n%.0s' $(seq 1 120)); printf 'long' > "t/$L.txt"; mkdir -p "t/$L/$L"; printf x > "t/$L/$L/deep.txt"
(cd t && zip -q -r $T/inner.zip a.txt sub/jack.txt) && cp inner.zip t/nested.zip
zip -q -r -y $S/zip/tool.zip t; zip -q -r -0 $S/zip/stored.zip t/a.txt t/sub/jack.txt; zip -q -r -P secret $S/zip/crypt.zip t/a.txt t/sub/jack.txt
zip -q -j $S/zip/flat.zip t/a.txt; printf 'x' | zip -q $S/zip/stream.zip -; zip -q -r -fz $S/zip/zip64.zip t/a.txt t/sub 2>/dev/null
echo comment | zip -q -z $S/zip/comment.zip t/a.txt >/dev/null; (printf '#!/bin/sh\nexit 0\n'; cat $S/zip/flat.zip) > $S/zip/sfx.zip
bsdtar -cf $S/zip/bsd.zip --format zip t/a.txt t/sub/jack.txt t/link; ditto -c -k --sequesterRsrc t/sub $S/zip/ditto.zip
tar -cf $S/tar/bsd.tar t; bsdtar -cf $S/tar/ustar.tar --format ustar t/a.txt t/sub t/link t/hard.txt 2>/dev/null; bsdtar -cf $S/tar/pax.tar --format pax t
bsdtar -cf $S/tar/gnu.tar --format gnutar t; bsdtar -cf $S/tar/v7.tar --format v7 t/a.txt t/sub/jack.txt 2>/dev/null; bsdtar -cf $S/tar/small.tar t/a.txt
tar -czf $S/tgz/t.tar.gz t/a.txt t/sub t/link; tar -cJf $S/txz/t.tar.xz t/a.txt t/sub t/link; tar -cjf $S/bz/t.tar.bz2 t/a.txt t/sub/jack.txt t/link
bsdtar -czf $S/tgz/pax.tar.gz --format pax t; bsdtar -cJf $S/txz/pax.tar.xz --format pax t; bsdtar -czf $S/tgz/gnu.tar.gz --format gnutar t
gzip -c t/sub/jack.txt > $S/tgz/jack.txt.gz; gzip -c -N t/a.txt > $S/tgz/named.gz; (gzip -c t/a.txt; gzip -c t/sub/jack.txt) > $S/tgz/multi.gz; : | gzip -c > $S/tgz/empty.gz
xz -c t/sub/jack.txt > $S/txz/jack.txt.xz; (xz -c t/a.txt; xz -c t/sub/jack.txt) > $S/txz/multi.xz; : | xz -c > $S/txz/empty.xz; xz -c --block-size=100 t/sub/jack.txt > $S/txz/blocks.xz
(xz -c t/a.txt; head -c 8 /dev/zero; xz -c t/a.txt) > $S/txz/padded.xz; xz -c --check=sha256 t/a.txt > $S/txz/sha.xz; xz -c --check=none t/a.txt > $S/txz/nocheck.xz
bzip2 -c t/sub/jack.txt > $S/bz/jack.txt.bz2; : | bzip2 -c > $S/bz/empty.bz2
python3 - "$S" <<'P'
import sys, io, zipfile, tarfile, struct, os, stat, gzip, lzma
S = sys.argv[1]
def zi(name, mode=0o100644, t=(2020,1,2,3,4,6)):
    z = zipfile.ZipInfo(name, t); z.external_attr = mode << 16; z.create_system = 3; return z
def mkzip(path, members, comment=b'', **kw):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED, **kw) as z:
        for name, data, mode in members:
            z.writestr(zi(name, mode), data)
        z.comment = comment
mkzip(S+'/zip/trav.zip', [('../canary/pwn.txt', b'pwn', 0o100644), ('ok.txt', b'ok', 0o100644), ('/abs.txt', b'abs', 0o100644), ('a/../../canary/pwn2', b'p', 0o100644), ('..\\canary\\pwn3', b'p', 0o100644), ('a/./b//c.txt', b'c', 0o100644)])
mkzip(S+'/zip/symw.zip', [('ln', b'../canary', 0o120777), ('ln/pwn.txt', b'pwn', 0o100644), ('up', b'..', 0o120777), ('up/canary/pwn2.txt', b'p', 0o100644), ('d/', b'', 0o040755), ('d/f', b'x', 0o104755)])
mkzip(S+'/zip/dups.zip', [('a.txt', b'one', 0o100644), ('a.txt', b'two', 0o100644), ('A.TXT', b'three', 0o100644), ('a.txt/', b'', 0o040755), ('a.txt/x', b'x', 0o100644)])
mkzip(S+'/zip/odd.zip', [('', b'e', 0o100644), ('.', b'd', 0o100644), ('..', b'dd', 0o100644), ('a\x00b', b'n', 0o100644), ('é/é', b'nfc', 0o100644), ('x'*300, b'l', 0o100644), ('dev', b'', 0o020644), ('fifo', b'', 0o010644)], comment=b'c'*40)
with zipfile.ZipFile(S+'/zip/z64.zip', 'w', zipfile.ZIP_STORED) as z:
    with z.open(zi('big.txt'), 'w', force_zip64=True) as f: f.write(b'zip64 member')
    z.writestr(zi('b.txt'), b'bb')
with zipfile.ZipFile(S+'/zip/many.zip', 'w') as z:
    for i in range(40): z.writestr(zi('d%d/f%d.txt' % (i % 5, i)), b'%d' % i)
# data descriptor (streamed) member, by hand
def dd_zip():
    name = b'dd.txt'; data = b'descriptor data'; import zlib
    comp = zlib.compressobj(6, zlib.DEFLATED, -15); c = comp.compress(data) + comp.flush(); crc = zlib.crc32(data)
    lh = struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, 8, 8, 0, 0x5021, 0, 0, 0, len(name), 0) + name
    desc = struct.pack('<IIII', 0x08074b50, crc, len(c), len(data))
    cd = struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 0x031e, 20, 8, 8, 0, 0x5021, crc, len(c), len(data), len(name), 0, 0, 0, 0, 0o100644 << 16, 0) + name
    body = lh + c + desc
    eocd = struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, 1, 1, len(cd), len(body), 0)
    return body + cd + eocd
open(S+'/zip/dd.zip', 'wb').write(dd_zip())
# explicit zip64 end records with an extra field carrying sizes and offset
def z64_zip():
    name = b'z.txt'; data = b'zip64 by hand'; import zlib
    crc = zlib.crc32(data)
    lx = struct.pack('<HHQQ', 1, 16, len(data), len(data))
    lh = struct.pack('<IHHHHHIIIHH', 0x04034b50, 45, 0, 0, 0, 0x5021, crc, 0xFFFFFFFF, 0xFFFFFFFF, len(name), len(lx)) + name + lx
    cx = struct.pack('<HHQQQ', 1, 24, len(data), len(data), 0) + struct.pack('<HHBI', 0x5455, 5, 1, 1600000000) + struct.pack('<HHBBBIBI', 0x7875, 11, 1, 4, 0, 501, 4, 20)[:15]
    cd = struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 0x032d, 45, 0, 0, 0, 0x5021, crc, 0xFFFFFFFF, 0xFFFFFFFF, len(name), len(cx), 0, 0, 0, 0o100644 << 16, 0xFFFFFFFF) + name + cx
    body = lh + data
    e64 = struct.pack('<IQHHIIQQQQ', 0x06064b50, 44, 45, 45, 0, 0, 1, 1, len(cd), len(body))
    loc = struct.pack('<IIQI', 0x07064b50, 0, len(body) + len(cd), 1)
    eocd = struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    return body + cd + e64 + loc + eocd
open(S+'/zip/z64hand.zip', 'wb').write(z64_zip())
def ti(name, data=b'', typ=tarfile.REGTYPE, link='', mode=0o644):
    t = tarfile.TarInfo(name); t.size = len(data) if typ == tarfile.REGTYPE else 0; t.type = typ; t.linkname = link; t.mode = mode; t.mtime = 1600000000; return t, data
def mktar(path, members, fmt=tarfile.USTAR_FORMAT, mode='w'):
    with tarfile.open(path, mode, format=fmt) as tf:
        for t, data in members: tf.addfile(t, io.BytesIO(data) if t.isreg() else None)
hostile = [ti('ok.txt', b'ok'), ti('../canary/pwn.txt', b'pwn'), ti('/abs.txt', b'abs'), ti('ln', typ=tarfile.SYMTYPE, link='../canary'), ti('ln/pwn2.txt', b'p'),
           ti('up', typ=tarfile.SYMTYPE, link='..'), ti('up/canary/pwn3.txt', b'p'), ti('hl', typ=tarfile.LNKTYPE, link='../canary/keep.txt'), ti('hl', b'overwritten'),
           ti('hl2', typ=tarfile.LNKTYPE, link='ok.txt'), ti('hl3', typ=tarfile.LNKTYPE, link='hl2'), ti('loop', typ=tarfile.LNKTYPE, link='loop'),
           ti('d/', typ=tarfile.DIRTYPE, mode=0o755), ti('d/s', b'suid', mode=0o4755), ti('ok.txt', b'again'), ti('dev', typ=tarfile.CHRTYPE), ti('fifo', typ=tarfile.FIFOTYPE)]
mktar(S+'/tar/hostile.tar', hostile); mktar(S+'/tar/hostile-gnu.tar', hostile, tarfile.GNU_FORMAT); mktar(S+'/tar/hostile-pax.tar', hostile, tarfile.PAX_FORMAT)
longs = [ti('L'*150 + '/' + 'm'*120 + '.txt', b'long'), ti('k'*300, typ=tarfile.SYMTYPE, link='t'*200), ti('日本/éé.txt', b'u'), ti('big', b'x'*1500)]
mktar(S+'/tar/long-gnu.tar', longs, tarfile.GNU_FORMAT); mktar(S+'/tar/long-pax.tar', longs, tarfile.PAX_FORMAT)
mktar(S+'/tgz/hostile.tar.gz', hostile, mode='w:gz'); mktar(S+'/txz/hostile.tar.xz', hostile, mode='w:xz'); mktar(S+'/bz/hostile.tar.bz2', hostile[:6], mode='w:bz2')
mktar(S+'/tgz/long.tar.gz', longs, tarfile.PAX_FORMAT, 'w:gz'); mktar(S+'/txz/long.tar.xz', longs, tarfile.GNU_FORMAT, 'w:xz')
# base-256 size, by hand: a ustar header whose size field is binary
def raw_header(name, size_field, typ=b'0', link=b''):
    h = bytearray(512); h[0:len(name)] = name; h[100:107] = b'0000644'; h[108:115] = b'0000000'; h[116:123] = b'0000000'
    h[124:136] = size_field; h[136:147] = b'13732770000'; h[156:157] = typ; h[157:157+len(link)] = link; h[257:263] = b'ustar\x00'; h[263:265] = b'00'
    h[148:156] = b' ' * 8; s = sum(h); h[148:155] = ('%06o' % s).encode() + b'\x00'; h[155] = 32; return bytes(h)
b256 = b'\x80' + (5).to_bytes(11, 'big')
pax = b'30 path=pax/renamed-by-pax.txt\n20 size=5\n18 mtime=1.5\n'
paxh = raw_header(b'PaxHeader/x', ('%011o' % len(pax)).encode() + b'\x00', b'x')
glob = b'19 comment=global\n'
globh = raw_header(b'GlobalHead', ('%011o' % len(glob)).encode() + b'\x00', b'g')
gl = b'gnu-long-name-' + b'z'*120 + b'\x00'
glh = raw_header(b'././@LongLink', ('%011o' % len(gl)).encode() + b'\x00', b'L')
pad = lambda b: b + b'\x00' * (-len(b) % 512)
tarb = (raw_header(b'b256.txt', b256) + pad(b'12345') + globh + pad(glob) + paxh + pad(pax) + raw_header(b'short', b'00000000005\x00') + pad(b'abcde')
        + glh + pad(gl) + raw_header(b'trunc', b'00000000003\x00') + pad(b'xyz') + bytes(1024))
open(S+'/tar/hand.tar', 'wb').write(tarb)
open(S+'/tgz/hand.tar.gz', 'wb').write(gzip.compress(tarb)); open(S+'/txz/hand.tar.xz', 'wb').write(lzma.compress(tarb))
# old GNU sparse member
sp = bytearray(raw_header(b'sparse.bin', b'00000000005\x00', b'S')); sp[257:265] = b'ustar  \x00'; sp[386:398] = b'00000000000\x00'; sp[398:410] = b'00000000005\x00'; sp[483:495] = b'00000010000\x00'
sp[148:156] = b' ' * 8; s = sum(sp); sp[148:155] = ('%06o' % s).encode() + b'\x00'; sp[155] = 32
open(S+'/tar/sparse.tar', 'wb').write(bytes(sp) + pad(b'12345') + raw_header(b'after.txt', b'00000000002\x00') + pad(b'ok') + bytes(1024))
P
rm -rf $T; ls -la $S/*/ | awk '{print $5, $9}' | grep -v '^ *$' | tr '\n' ';'

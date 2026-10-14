import Foundation
import FuzzCore

@testable import NetworkPlugin

/// The `ftplist` target: lines of an FTP listing (MLSD, MLST, LIST in its many forms).
internal enum FTPListFuzz {
    /// Tokens of the listing formats.
    private static let dict = [
        "type=file;", "type=dir;", "type=cdir;", "type=pdir;", "type=OS.unix=slink:/x;", "size=", "sizd=",
        "modify=20240102030405;", "perm=", "unix.mode=0755;", "UNIX.mode=", " -> ", "drwxr-xr-x", "lrwxrwxrwx",
        "-rw-r--r--", "+i8388621.29609,m824255902,/,\t", "+s", ",r,", "<DIR>", "01-02-24  03:04PM", "AM", "PM", " Jan ",
        " janv. ", " 2024 ", " 12:34 ", "2024-01-31 12:34 ", "total 12", "\t", ";", "=", "../", "/", "..",
        "99999999999999999999", "-1", "\u{0}", "\r"
    ]

    /// The target.
    ///
    /// - Returns: The target for `fuzzMain`.
    internal static func target() -> FuzzTarget {
        FuzzTarget("ftplist", maxLen: 2_048, dict: dict, seeds: seeds, run: run)
    }

    /// Listings of every format the parser knows.
    ///
    /// - Returns: The seeds.
    private static func seeds() -> [[UInt8]] {
        [
            "type=file;size=12;modify=20240102030405;perm=adfr;unix.mode=0644; name.txt",
            "type=dir;modify=20240102030405.123; sub dir", "type=cdir; .", "type=pdir; ..",
            "type=OS.unix=slink:/target;size=3; link", " type=file;size=5; /path/to/name",
            "-rw-r--r--   1 user group     1234 Jan  2 03:04 file.txt", "drwxr-xr-x 2 0 0 4096 Jan 02  2020 dir",
            "lrwxrwxrwx 1 u g 4 Feb 29 12:00 link -> target", "-rwsr-sr-t 1 u g 99999999999999999999 31 Dec 2099 big",
            "-rw-r--r-- 1 u g 12 2024-01-31 12:34:56.789 +0100 iso name",
            "crw-rw-rw- 1 root wheel 3, 2 Jan 1 00:00 null",
            "01-02-24  03:04PM       <DIR>          Program Files", "12-31-1999  11:59AM              1234 file.exe",
            "+i8388621.29609,m824255902,/,\tdev", "+i8388621.44468,m839956783,r,s10376,\tRFCEPLF",
            "+up644,s0,m99999999999999999999,\tx", "total 42",
            "-rw-r--r-- 1 u g 5 Jan 2 03:04 a\n-rw-r--r-- 1 u g 5 2 Jan 03:04 b\ntype=file;size=1; c\n"
                + "+s1,\td\n01-02-24 03:04AM 5 e"
        ]
        .map { Array($0.utf8) }
    }

    /// Parses every line as each format, then the whole as a listing.
    ///
    /// - Parameter bytes: The input.
    private static func run(_ bytes: [UInt8]) {
        var decoded: [String] = []
        for (index, raw) in NetFuzz.lines(bytes).enumerated() {
            // Names come in the server's encoding; the choice of the decoder goes with the line.
            let encoding = NameEncoding.allCases[index % NameEncoding.allCases.count]
            let line = index.isMultiple(of: 3) ? NetFuzz.text(raw) : encoding.decode(Data(raw))
            decoded.append(line)
            NetFuzz.check(FTPListParser.mlsd(line))
            _ = FTPListParser.mlst(line).map { $0.item(in: NetFuzz.base) }
            NetFuzz.check(FTPListParser.list(line, now: NetFuzz.fixedNow))
        }
        FTPListParser.entries(of: decoded, asMLSD: true, now: NetFuzz.fixedNow).forEach(NetFuzz.check)
        FTPListParser.entries(of: decoded, asMLSD: false, now: NetFuzz.fixedNow).forEach(NetFuzz.check)
    }
}

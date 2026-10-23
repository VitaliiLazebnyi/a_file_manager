import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// Directory listings as FTP servers send them: `ls -l` of many systems, DOS, EPLF and MLSD.
@Suite
internal struct NetworkListParserTests {
    /// A listing line parsed as the plugin does, with "now" in June 2024, UTC.
    internal func list(_ line: String) -> RemoteEntry? {
        FTPListParser.list(line, now: ListingClock.now, calendar: ListingClock.utc)
    }

    /// Unix listings give name, kind, size, date and permissions, also for names with spaces, names
    /// that look like dates and symbolic links; a date later in the year than now is last year's.
    @Test
    internal func unixListings() {
        // GNU ls, as vsftpd and ProFTPD send it.
        var entry = list("-rw-r--r--    1 1000     1000         1234 Jan 05 10:30 report.txt")
        #expect(
            entry
                == RemoteEntry(
                    name: "report.txt",
                    isDirectory: false,
                    size: 1_234,
                    modified: ListingClock.time(2_024, 1, 5, 10, 30),
                    permissions: 0o644
                )
        )
        entry = list("drwxr-xr-x   12 root     wheel        4096 Mar  3  2021 pub")
        #expect(
            entry
                == RemoteEntry(
                    name: "pub",
                    isDirectory: true,
                    size: 4_096,
                    modified: ListingClock.day(2_021, 3, 3),
                    permissions: 0o755
                )
        )
        // A date later in the year than today belongs to last year.
        #expect(list("-rw-r--r-- 1 u g 5 Dec 24 08:00 gift.txt")?.modified == ListingClock.time(2_023, 12, 24, 8, 0))
        // Names with spaces, also leading and doubled ones.
        #expect(list("-rw-r--r-- 1 u g 5 Jan 01 2020 My  Documents and more.txt")?.name == "My  Documents and more.txt")
        #expect(list("-rw-r--r-- 1 u g 5 Jan 01 2020  leading space")?.name == " leading space")
        // A name that itself looks like a date.
        #expect(list("-rw-r--r-- 1 u g 77 Feb 02 2019 7 Jan 01 2020 notes")?.name == "7 Jan 01 2020 notes")
        // Symbolic links carry their target.
        entry = list("lrwxrwxrwx 1 root root 11 May 10 2022 latest -> release-2.4")
        #expect(
            entry?.name == "latest" && entry?.isSymlink == true && entry?.linkTarget == "release-2.4"
                && entry?.isDirectory == false
        )
    }

    /// The variants of `ls -l` other systems send: no group column, group names with spaces, ACL marks, set-id
    /// bits, device files, seconds, ISO dates and month names of other languages.
    @Test
    internal func unixListingVariants() {
        // No group column (BSD `ls -lo`, some embedded servers).
        #expect(list("-rw-r--r--   1 ftp          512 Apr 12 09:15 nogroup.bin")?.size == 512)
        // Group names with spaces and numbers, huge sizes.
        var entry = list("-rw-rw-r--   1 jdoe   Domain Users 9876543210 Jun 14 23:59 big.iso")
        #expect(
            entry?.size == 9_876_543_210 && entry?.name == "big.iso"
                && entry?.modified == ListingClock.time(2_024, 6, 14, 23, 59)
        )
        // ACL and extended-attribute marks after the mode.
        #expect(list("-rw-r--r--+  1 u g 10 Jan 01 2020 acl.txt")?.permissions == 0o644)
        #expect(list("drwx------@  5 u g 160 Jan 01 2020 Library")?.isDirectory == true)
        #expect(list("-rw-r--r--.  1 u g 10 Jan 01 2020 selinux.txt")?.name == "selinux.txt")
        // Set-id and sticky bits.
        #expect(list("-rwsr-sr-t 1 u g 10 Jan 01 2020 special")?.permissions == 0o7755)
        #expect(list("drwxrwxrwT 2 u g 10 Jan 01 2020 tmp")?.permissions == 0o1776)
        // Device files have "major, minor" where the size is.
        #expect(list("crw-rw-rw- 1 root wheel 3, 2 Jan 01 2020 null")?.name == "null")
        // Seconds in the time, ISO dates (`ls --time-style=long-iso`).
        #expect(
            list("-rw-r--r-- 1 u g 42 Jun 01 07:08:09 secs.log")?.modified == ListingClock.time(2_024, 6, 1, 7, 8) + 9
        )
        entry = list("-rw-r--r-- 1 u g 42 2023-11-30 16:45 iso.log")
        #expect(
            entry?.name == "iso.log" && entry?.modified == ListingClock.time(2_023, 11, 30, 16, 45) && entry?.size == 42
        )
        // Month names of other languages, with and without a dot; day before month.
        #expect(list("-rw-r--r-- 1 u g 1 Okt 03 2022 deutsch.txt")?.modified == ListingClock.day(2_022, 10, 3))
        #expect(list("-rw-r--r-- 1 u g 1 déc. 25 2022 noel.txt")?.modified == ListingClock.day(2_022, 12, 25))
        #expect(list("-rw-r--r-- 1 u g 1 25 Mai 2022 tag-zuerst.txt")?.modified == ListingClock.day(2_022, 5, 25))
    }

    /// NetWare listings are read, a carriage return left at the end is dropped, and totals, the folder itself,
    /// its parent, replies and error messages give no entry.
    @Test
    internal func netWareListingsAndLinesThatAreNoEntries() {
        // NetWare.
        var entry = list("d [R----F--] supervisor            512       Jan 16 18:53    login")
        #expect(entry?.isDirectory == true && entry?.size == 512)
        entry = list("- [R----F--] rhesus             214059       Oct 20 15:27    cx.exe")
        #expect(
            entry?.isDirectory == false && entry?.size == 214_059
                && entry?.modified == ListingClock.time(2_023, 10, 20, 15, 27)
        )
        // Carriage returns that survived, and what is no entry at all.
        #expect(list("-rw-r--r-- 1 u g 5 Jan 01 2020 cr.txt\r")?.name == "cr.txt")
        for line in [
            "total 48", "", "drwxr-xr-x 2 u g 4096 Jan 01 2020 .", "drwxr-xr-x 2 u g 4096 Jan 01 2020 ..",
            "226 Transfer complete",
            "ls: cannot access x: No such file", "-rw-r--r-- garbage"
        ] {
            #expect(list(line) == nil)
        }
    }

    /// DOS listings (IIS) give folders, sizes with separators, two- and four-digit years and junctions.
    @Test
    internal func windowsListings() {
        var entry = list("01-31-24  03:04PM       <DIR>          Program Files")
        #expect(
            entry
                == RemoteEntry(
                    name: "Program Files",
                    isDirectory: true,
                    modified: ListingClock.time(2_024, 1, 31, 15, 4)
                )
        )
        entry = list("12-07-98  12:30AM              1048576 setup.exe")
        #expect(
            entry
                == RemoteEntry(
                    name: "setup.exe",
                    isDirectory: false,
                    size: 1_048_576,
                    modified: ListingClock.time(1_998, 12, 7, 0, 30)
                )
        )
        // Four-digit years and a 24-hour clock, thousands separators.
        entry = list("02-29-2024  17:45            1,234,567 leap year.zip")
        #expect(
            entry?.size == 1_234_567 && entry?.name == "leap year.zip"
                && entry?.modified == ListingClock.time(2_024, 2, 29, 17, 45)
        )
        #expect(list("07-04-05  12:00PM                    0 empty")?.modified == ListingClock.time(2_005, 7, 4, 12, 0))
        #expect(list("07-04-05  09:00AM       <JUNCTION>     link")?.isSymlink == true)
    }

    /// EPLF lines give the kind, the size, the date in seconds and the permissions.
    @Test
    internal func eplfListings() {
        var entry = list("+i8388621.29609,m824255902,/,\tdev")
        #expect(
            entry == RemoteEntry(name: "dev", isDirectory: true, modified: Date(timeIntervalSince1970: 824_255_902))
        )
        entry = list("+i8388621.44468,m839956783,r,s10376,up644,\tRFCEPLF with spaces")
        #expect(
            entry
                == RemoteEntry(
                    name: "RFCEPLF with spaces",
                    isDirectory: false,
                    size: 10_376,
                    modified: Date(timeIntervalSince1970: 839_956_783),
                    permissions: 0o644
                )
        )
    }

    /// MLSD facts are read in any order and case; the folder itself and its parent are no entries.
    @Test
    internal func mlsdListings() {
        var entry = FTPListParser.mlsd(
            "type=file;size=4096;modify=20261011035043;UNIX.mode=0640; a file; with semicolon.txt"
        )
        #expect(
            entry
                == RemoteEntry(
                    name: "a file; with semicolon.txt",
                    isDirectory: false,
                    size: 4_096,
                    modified: ListingClock.time(2_026, 10, 11, 3, 50) + 43,
                    permissions: 0o640
                )
        )
        entry = FTPListParser.mlsd("modify=20261011035043.123;perm=eldfmMTcp;size=4096;type=dir; docs")
        #expect(
            entry?.isDirectory == true && entry?.name == "docs"
                && entry?.modified == ListingClock.time(2_026, 10, 11, 3, 50) + 43
        )
        #expect(FTPListParser.mlsd("Type=cdir;Modify=20200101000000; .") == nil)
        #expect(FTPListParser.mlsd("type=pdir; ..") == nil)
        entry = FTPListParser.mlsd("type=OS.unix=slink:/srv/target;size=7; link")
        #expect(entry?.isSymlink == true && entry?.linkTarget == "/srv/target")
        #expect(
            FTPListParser.mlsd("Type=file;Size=3; UPPER") == RemoteEntry(name: "UPPER", isDirectory: false, size: 3)
        )
        // No facts at all: only the name.
        #expect(FTPListParser.mlsd(" just a name")?.name == "just a name")
        #expect(FTPListParser.mlsd("nonsense") == nil)
        // MLST indents its line and may give the whole path.
        #expect(
            FTPListParser.mlst(" type=file;size=9; /pub/dir/file name.txt")
                == RemoteEntry(name: "file name.txt", isDirectory: false, size: 9)
        )
    }

    /// Five thousand lines come out in their order, in both formats.
    @Test
    internal func largeListingsAreParsedInOrder() {
        let lines = (0..<5_000).map { "-rw-r--r-- 1 u g \($0) Jan 01 2020 file\($0).txt" } + ["total 5000"]
        let entries = FTPListParser.entries(of: lines, asMLSD: false)
        #expect(entries.count == 5_000 && entries[4_999].size == 4_999 && entries[17].name == "file17.txt")
        let facts = (0..<5_000).map { "type=file;size=\($0); f\($0)" }
        #expect(FTPListParser.entries(of: facts, asMLSD: true).map(\.size) == (0..<5_000).map(Int64.init))
    }
}

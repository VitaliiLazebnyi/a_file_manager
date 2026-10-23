import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// One 512-byte TAR header built by hand, for headers the packer never writes.
private func tarBlock(
    name: String,
    type: UInt8 = 48,
    size: UInt64 = 0,
    link: String = "",
    magic: [UInt8] = Array("ustar\u{0}00".utf8),
    patch: (inout [UInt8]) -> Void = { _ in
        // The header as it is.
    }
) -> Data {
    var block = [UInt8](repeating: 0, count: 512)
    func put(_ bytes: [UInt8], at offset: Int) {
        for (index, byte) in bytes.enumerated() { block[offset + index] = byte }
    }
    func octal(_ value: UInt64, _ length: Int) -> [UInt8] {
        let digits = String(value, radix: 8)
        return Array((String(repeating: "0", count: length - 1 - digits.count) + digits).utf8)
    }
    put(Array(name.utf8), at: 0)
    put(octal(0o644, 8), at: 100)
    put(octal(size, 12), at: 124)
    put(octal(1_600_000_000, 12), at: 136)
    block[156] = type
    put(Array(link.utf8), at: 157)
    put(magic, at: 257)
    patch(&block)
    for index in 148..<156 { block[index] = 32 }
    let sum = block.reduce(0) { $0 + Int($1) }
    put(Array(String(format: "%06o", sum).utf8) + [0, 32], at: 148)
    return Data(block)
}

private func tarData(_ text: String) -> Data {
    var data = Data(text.utf8)
    data.append(Data(count: (512 - data.count % 512) % 512))
    return data
}

/// TAR archives as other programs write them, or as an attacker crafts them: impossible sizes, pax records, hard links,
/// old GNU headers and sparse files.
@Suite
internal struct ArchiveTarFixes: ArchiveFixSuite {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// TAR headers with sizes beyond what the file can hold, in the binary field or in a pax record, make the archive
    /// damaged.
    @Test
    internal func tarHeadersWithImpossibleSizesAreDamaged() throws {
        // GNU's binary size field with every bit set.
        var data = tarBlock(name: "huge.bin") { block in
            block[124] = 0x80
            for index in 125..<136 { block[index] = 0xFF }
        }
        data.append(TarHeader.endOfArchive)
        try data.write(to: box.url("binary.tar"))
        #expect(throws: ArchiveError.self) {
            try bench.names(bench.inside(box.url("binary.tar"), scheme: ArchiveURL.readOnlyScheme))
        }
        // The same through a pax record.
        let record = "29 size=18446744073709551615\n"
        #expect(record.utf8.count == 29)
        data = tarBlock(name: "PaxHeader/x", type: 120, size: 29)
        data.append(tarData(record))
        data.append(tarBlock(name: "huge.bin"))
        data.append(TarHeader.endOfArchive)
        try data.write(to: box.url("pax.tar"))
        #expect(throws: ArchiveError.self) {
            try bench.names(bench.inside(box.url("pax.tar"), scheme: ArchiveURL.readOnlyScheme))
        }
        // A size just below the limit is refused when its data turns out not to be there.
        data = tarBlock(name: "claims.bin") { block in
            block[124] = 0x80
            block[128] = 0x7F
        }
        try data.write(to: box.url("claims.tar"))
        #expect(throws: ArchiveError.self) {
            try bench.names(bench.inside(box.url("claims.tar"), scheme: ArchiveURL.readOnlyScheme))
        }
    }

    /// Pax records that are shorter than their own length end the list, and times no calendar knows are kept in range.
    @Test
    internal func paxRecordsShorterThanTheirOwnLengthEndTheList() {
        for text in ["1 ", "01 ", "0000002 a", "3 a", "0 ", "-5 x=y\n", "99999999999999999999999 a=b\n", " ", "5", ""] {
            #expect(TarHeader.paxRecords(Data(text.utf8)).isEmpty, "\(text)")
        }
        #expect(TarHeader.paxRecords(Data("12 path=abc\n1 ".utf8)) == ["path": "abc"])
        #expect(TarHeader.paxRecords(Data("12 path=abc\n8 a=bcd\n".utf8)) == ["path": "abc", "a": "bcd"])
        // Times no calendar knows do not get far.
        #expect(
            TarHeader.date(.nan) == Date(timeIntervalSince1970: 0)
                && TarHeader.date(.infinity).timeIntervalSince1970 < 3e11
        )
        var record = ZipRecord.new(
            name: "a",
            isDirectory: false,
            modified: Date(timeIntervalSince1970: .nan),
            permissions: 0o644,
            isSymbolicLink: false
        )
        record.setModified(Date(timeIntervalSince1970: .infinity))
        #expect(record.extra.count == 9)
    }
    /// Hard links in a TAR are files of their own wherever their target stands, in one pass or not.
    @Test
    internal func hardLinksAreFilesOfTheirOwnWhereverTheirTargetStands() throws {
        // A link to a member that comes later, a link to a link, and a link to nothing.
        var data = tarBlock(name: "early-link", type: 49, link: "dir/real.txt")
        data.append(tarBlock(name: "second-link", type: 49, link: "early-link"))
        data.append(tarBlock(name: "dir/real.txt", size: 9))
        data.append(tarData("the bytes"))
        data.append(tarBlock(name: "late-link", type: 49, link: "dir/real.txt"))
        data.append(tarBlock(name: "broken-link", type: 49, link: "nowhere"))
        data.append(TarHeader.endOfArchive)
        try data.write(to: box.url("links.tar"))
        #expect(runTool("/usr/bin/gzip", ["-k", "links.tar"], in: box.root).status == 0)
        for (name, limit) in [("links.tar", UInt64(1 << 20)), ("links.tar.gz", 1 << 20), ("links.tar.gz", 0)] {
            bench.store.close()
            bench.environment.materializeLimit = limit
            let root = bench.inside(box.url(name), scheme: ArchiveURL.readOnlyScheme)
            for link in ["early-link", "second-link", "late-link", "dir/real.txt"] {
                #expect(
                    try bench.item(bench.inside(box.url(name), link, scheme: ArchiveURL.readOnlyScheme)).size == 9,
                    "\(name) \(link)"
                )
            }
            #expect(try bench.read(root.appending(name: "second-link")) == Data("the bytes".utf8))
            // Unpacked in one pass, every name gets the contents.
            let target = box.url("out-\(name)-\(limit)")
            let result = try bench.unpack(box.url(name), to: target)
            #expect(result.problems.isEmpty, "\(result.problems)")
            let unpacked = snapshot(target)
            for link in ["early-link", "second-link", "late-link", "dir/real.txt"] {
                #expect(unpacked[link] == Data("the bytes".utf8), "\(name) \(link)")
            }
            #expect(unpacked["broken-link"] == Data())
        }
    }

    /// Old GNU TAR headers, which keep times where POSIX has the path prefix, have no prefix.
    @Test
    internal func oldGnuHeadersHaveNoPathPrefix() throws {
        // GNU tar's old format keeps times where POSIX has the prefix of a long path.
        var data = tarBlock(name: "gnu.txt", size: 3, magic: Array("ustar  \u{0}".utf8)) { block in
            for (index, byte) in "14000000000\u{0}14000000001\u{0}".utf8.enumerated() { block[345 + index] = byte }
        }
        data.append(tarData("gnu"))
        data.append(
            tarBlock(name: "posix.txt", size: 5) { block in
                for (index, byte) in "some/long/prefix".utf8.enumerated() { block[345 + index] = byte }
            }
        )
        data.append(tarData("posix"))
        data.append(TarHeader.endOfArchive)
        try data.write(to: box.url("gnu.tar"))
        let root = bench.inside(box.url("gnu.tar"), scheme: ArchiveURL.readOnlyScheme)
        #expect(try bench.names(root) == ["gnu.txt", "some"])
        #expect(try bench.read(root.appending(name: "gnu.txt")) == Data("gnu".utf8))
        #expect(
            try bench.read(
                bench.inside(box.url("gnu.tar"), "some/long/prefix/posix.txt", scheme: ArchiveURL.readOnlyScheme)
            )
                == Data("posix".utf8)
        )
    }

    /// Sparse files of a TAR, in the old GNU form and the pax form, are shown at their real size and refused when read
    /// or unpacked.
    @Test
    internal func sparseFilesAreShownAndRefused() throws {
        // The old GNU form: type S, the real size in the header, the list of pieces going on
        // in a block of its own.
        var data = tarBlock(name: "holes.img", type: 83, size: 512, magic: Array("ustar  \u{0}".utf8)) { block in
            for (index, byte) in "00004000000\u{0}".utf8.enumerated() { block[483 + index] = byte }
            block[482] = 1
        }
        data.append(Data(count: 512))
        data.append(Data(repeating: 65, count: 512))
        data.append(tarBlock(name: "after.txt", size: 5))
        data.append(tarData("after"))
        // The pax form: the name and the size in records of their own.
        let records = [
            "22 GNU.sparse.major=1\n", "22 GNU.sparse.minor=0\n", "29 GNU.sparse.name=pax-holes\n",
            "29 GNU.sparse.realsize=70000\n"
        ]
        #expect(records.map(\.utf8.count) == [22, 22, 29, 29])
        data.append(tarBlock(name: "PaxHeader/x", type: 120, size: UInt64(records.joined().utf8.count)))
        data.append(tarData(records.joined()))
        data.append(tarBlock(name: "GNUSparseFile.0/pax-holes", size: 1_024))
        data.append(Data(repeating: 66, count: 1_024))
        data.append(tarBlock(name: "last.txt", size: 4))
        data.append(tarData("last"))
        data.append(TarHeader.endOfArchive)
        try data.write(to: box.url("sparse.tar"))
        let archive = box.url("sparse.tar")
        func inner(_ path: String) -> URL { bench.inside(archive, path, scheme: ArchiveURL.readOnlyScheme) }
        #expect(try bench.names(inner("")) == ["after.txt", "holes.img", "last.txt", "pax-holes"])
        #expect(try bench.item(inner("holes.img")).size == 1 << 20 && bench.item(inner("pax-holes")).size == 70_000)
        #expect(
            try bench.read(inner("after.txt")) == Data("after".utf8)
                && bench.read(inner("last.txt")) == Data("last".utf8)
        )
        for name in ["holes.img", "pax-holes"] {
            #expect(throws: ArchiveError.self) { try bench.read(inner(name)) }
        }
        let result = try bench.unpack(archive, to: box.url("out"))
        #expect(
            result.unpacked == 2 && result.problems.count == 2
                && namesOnDisk(box.url("out")) == ["after.txt", "last.txt"]
        )
    }
}

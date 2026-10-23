import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2, second pass: what the directory of a large archive costs in memory
/// (A051, A076), and that the compact form of it behaves like the plain one.
@Suite
internal struct Review2ArchivesP2MemoryTests {
    /// The archive file system and its sandbox for this test.
    internal let bench: ArchiveBench
    /// The sandbox the archives are written in.
    internal var box: Sandbox { bench.box }

    /// A fresh bench in a sandbox of its own.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// A ZIP as the `zip` program writes it: each member with the exact-time field and the
    /// owner field (24 bytes of extra fields), in folders of a few hundred files.
    private func writeLargeZip(_ name: String, members: Int) throws -> URL {
        let url = box.url(name)
        let output = try OutputFile(creating: url, mode: 0o600)
        let writer = ZipWriter(output, limits: .standard)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<members {
            var record = ZipRecord.new(
                name: "project-\(index / 40_000)/module-\(index / 400)/source-file-\(index).swift",
                isDirectory: false,
                modified: modified,
                permissions: 0o644,
                isSymbolicLink: false
            )
            var extra = record.extra
            extra.append(contentsOf: [0x75, 0x78, 11, 0, 1, 4, 0xF5, 1, 0, 0, 4, 0x14, 0, 0, 0])
            record.extra = extra
            try writer.end(try writer.begin(record, localExtra: nil, expectedSize: nil), record, headerChanged: false)
        }
        try writer.finish(comment: Data())
        try output.close(durably: false)
        return url
    }

    /// Opening a ZIP of 60,000 members leaves a few hundred bytes per member allocated, not about a thousand.
    @Test
    internal func aLargeDirectoryCostsAFewHundredBytesPerMember() throws {
        // (Measured alone with 200,064 members: 396 bytes each, 975 before. Fewer here, so the
        // test is quick among the others; the cost per member is the same.)
        let members = 60_000
        let url = try writeLargeZip("large.zip", members: members)
        // What opening the archive leaves allocated, counted on this thread alone (the
        // directory is read by the thread that opens the archive): the other tests of the
        // process, which allocate at the same time, are not in the figure.
        var best: Int?
        var folders = 0
        for _ in 0..<3 {
            let (bytes, archive) = try ThreadAllocations.measure {
                try OpenArchive(
                    archiveURL: url,
                    localURL: url,
                    fetchedCopy: nil,
                    remoteStamp: nil,
                    quarantine: nil,
                    cancellation: nil,
                    environment: bench.environment
                )
            }
            folders = archive.entries.count - members
            #expect(archive.entry("project-1/module-149/source-file-59999.swift")?.size == 0)
            #expect(try archive.children(of: "project-0/module-7").count == 400)
            if let bytes { best = min(best ?? .max, bytes / members) }
        }
        guard let best else {
            // (A sanitizer's allocator does not call the hook.)
            print("A051/A076: not measured, the allocator's logging hook is not available in this build")
            #expect(folders == 2 + 150)
            return
        }
        print(
            "A051/A076: \(best) bytes per member (\(members) members, \(folders) folders); "
                + "an entry is \(MemoryLayout<ArchiveEntry?>.stride) bytes, "
                + "of which the ZIP record \(MemoryLayout<ZipRecord>.size)"
        )
        #expect(folders == 2 + 150)
        // Measured alone before this round's fix: 975. A reading far below what the entries
        // themselves take would mean nothing was counted.
        #expect(best > 150 && best < 600, "\(best) bytes per member")
    }
}

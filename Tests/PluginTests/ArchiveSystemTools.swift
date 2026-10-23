import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Archives of the system's own tools, read by the program, and the program's archives, read by those tools.
@Suite
internal struct ArchiveSystemTools {
    /// The archive file systems and the sandbox of the test.
    internal let bench: ArchiveBench
    /// The test's own folder on the local disk.
    internal var box: Sandbox { bench.box }

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// The system's unzip, tar, gzip and bzip2 accept and unpack what the archive code writes, with the same contents.
    @Test
    internal func systemToolsReadWhatIsWritten() throws {
        let tree = try bench.makeTree()
        let expected = snapshot(tree)

        let zip = box.url("tree.zip")
        try bench.pack([tree], to: zip)
        #expect(runTool("/usr/bin/unzip", ["-tq", zip.path]).status == 0)
        try box.folder("unzipped")
        #expect(runTool("/usr/bin/unzip", ["-q", zip.path, "-d", box.url("unzipped").path]).status == 0)
        #expect(snapshot(box.url("unzipped/tree")) == expected)
        let mode =
            try
            FileManager.default.attributesOfItem(atPath: box.url("unzipped/tree/readme.txt").path)[
                .posixPermissions
            ] as? Int
        #expect(mode == 0o755)

        for format in [ArchiveFormat.tar, .compressedTar(.gzip), .compressedTar(.bzip2), .compressedTar(.xzStream)] {
            let archive = box.url("tree." + format.defaultExtension)
            try bench.pack([tree], to: archive) { $0.format = format }
            let folder = try box.folder("untar-" + format.defaultExtension)
            let run = runTool("/usr/bin/tar", ["-xf", archive.path, "-C", folder.path])
            #expect(run.status == 0, "\(format.title): \(run.output)")
            #expect(snapshot(folder.appendingPathComponent("tree")) == expected, "\(format.title)")
        }

        let big = tree.appendingPathComponent("big.log")
        try bench.pack([big], to: box.url("big.log.gz")) { $0.format = .compressedFile(.gzip) }
        try bench.pack([big], to: box.url("big.log.bz2")) { $0.format = .compressedFile(.bzip2) }
        #expect(runTool("/usr/bin/gzip", ["-t", box.url("big.log.gz").path]).status == 0)
        #expect(runTool("/usr/bin/bzip2", ["-t", box.url("big.log.bz2").path]).status == 0)
        try FileManager.default.copyItem(at: box.url("big.log.gz"), to: box.url("copy.log.gz"))
        #expect(runTool("/usr/bin/gzip", ["-d", box.url("copy.log.gz").path]).status == 0)
        #expect(try Data(contentsOf: box.url("copy.log")) == Data(contentsOf: big))
    }

    /// Archives written by the system's zip, tar and bsdtar are recognised, listed, unpacked and tested, links and
    /// long names included.
    @Test
    internal func archivesOfTheSystemToolsAreRead() throws {
        let tree = try bench.makeTree()
        try FileManager.default.createSymbolicLink(
            atPath: tree.appendingPathComponent("link").path,
            withDestinationPath: "readme.txt"
        )
        let longName = String(repeating: "long-name-", count: 14) + ".txt"
        try box.file("tree/\(longName)", "long")
        var expected = snapshot(tree)
        expected["link"] = nil

        #expect(runTool("/usr/bin/zip", ["-qry", "sys.zip", "tree"], in: box.root).status == 0)
        try checkUnpacking(box.url("sys.zip"), .zip, expected: expected)
        for (name, flags, format) in [
            ("sys.tar", "-cf", ArchiveFormat.tar), ("sys.tgz", "-czf", .compressedTar(.gzip)),
            ("sys.tar.bz2", "-cjf", .compressedTar(.bzip2)), ("sys.tar.xz", "-cJf", .compressedTar(.xzStream))
        ] {
            #expect(runTool("/usr/bin/tar", [flags, name, "tree"], in: box.root).status == 0)
            try checkUnpacking(box.url(name), format, expected: expected)
        }
        // What only libarchive reads: 7z and cpio stand for the family.
        #expect(runTool("/usr/bin/bsdtar", ["-cf", "sys.7z", "--format", "7zip", "tree"], in: box.root).status == 0)
        try checkUnpacking(box.url("sys.7z"), .foreign, expected: expected)
        #expect(runTool("/usr/bin/bsdtar", ["-cf", "sys.cpio", "--format", "cpio", "tree"], in: box.root).status == 0)
        try checkUnpacking(box.url("sys.cpio"), .foreign, expected: expected)
        let listing = try bench.names(bench.inside(box.url("sys.7z"), "tree/sub", scheme: ArchiveURL.readOnlyScheme))
        #expect(listing == [".hidden", "deep", "random.bin"])
    }

    /// Files compressed by the system's gzip (also in several members, as parallel compressors write them) and
    /// bzip2 are read; a file that is no archive says so.
    @Test
    internal func filesOfTheSystemCompressorsAreRead() throws {
        try box.file("one.txt", "first ")
        try box.file("two.txt", "second")
        #expect(runTool("/usr/bin/gzip", ["-k", "one.txt", "two.txt"], in: box.root).status == 0)
        let both = try Data(contentsOf: box.url("one.txt.gz")) + Data(contentsOf: box.url("two.txt.gz"))
        try both.write(to: box.url("both.gz"))
        #expect(
            try bench.read(bench.inside(box.url("both.gz"), "one.txt", scheme: ArchiveURL.readOnlyScheme))
                == Data("first second".utf8)
        )
        #expect(runTool("/usr/bin/bzip2", ["-k", "one.txt"], in: box.root).status == 0)
        #expect(
            try bench.read(bench.inside(box.url("one.txt.bz2"), "one.txt", scheme: ArchiveURL.readOnlyScheme))
                == Data("first ".utf8)
        )

        #expect(throws: ArchiveError.self) { try bench.store.archive(at: box.url("one.txt"), cancellation: nil) }
        #expect(bench.fileSystems.item(at: bench.inside(box.url("one.txt"), "x")) == nil)
    }

    /// Opens `archive`, expects `format`, unpacks it and expects the files of `expected` (links left out), the link
    /// where the format keeps links, and a clean test.
    private func checkUnpacking(
        _ archive: URL,
        _ format: ArchiveFormat,
        expected: [String: Data?],
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) throws {
        let opened = try bench.store.archive(at: archive, cancellation: nil)
        #expect(opened.format == format, sourceLocation: sourceLocation)
        let folder = try box.folder("out-" + archive.lastPathComponent)
        let result = try bench.unpack(archive, to: folder)
        #expect(result.problems.isEmpty, "\(result.problems)", sourceLocation: sourceLocation)
        var unpacked = snapshot(folder.appendingPathComponent("tree"))
        unpacked["link"] = nil
        #expect(unpacked == expected, "\(archive.lastPathComponent)", sourceLocation: sourceLocation)
        // Formats that keep links hand them back as links.
        if format != .foreign || archive.pathExtension == "cpio" {
            #expect(
                (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: folder.appendingPathComponent("tree/link").path
                )) == "readme.txt",
                "\(archive.lastPathComponent)",
                sourceLocation: sourceLocation
            )
        }
        #expect(
            ArchiveTester.test(opened, cancellation: CancellationFlag(), counter: nil, members: .all).isEmpty,
            sourceLocation: sourceLocation
        )
    }
}

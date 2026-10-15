import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Pack on the local disk: names, links, replacing, dates, and what happens when the disk or
/// the archive fails it.
@Suite
internal struct CoverageArchivesFormatsPack {
    private typealias Support = CoverageArchivesFormatsSupport

    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }

    /// A new bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    private func packer(_ monitor: any JobMonitor, _ configure: ((inout PackOptions) -> Void)? = nil) -> Packer {
        var options = PackOptions()
        configure?(&options)
        return Packer(fileSystems: bench.fileSystems, store: bench.store, monitor: monitor, options: options)
    }

    private func names(in archive: URL) throws -> [String] {
        try bench.store.archive(at: archive).entries.map(\.path).sorted()
    }

    /// The archive of one operand is named after it: a file without its extension, a file
    /// that is all extension and a folder by their whole names.
    @Test
    internal func anArchiveIsNamedAfterItsOperand() throws {
        let file = try bench.item(try box.file("notes.txt"))
        let dotted = try bench.item(try box.file(".profile"))
        let folder = try bench.item(try box.folder("folder.d"))
        #expect(Packer.archiveName(for: file, format: .zip) == "notes.zip")
        #expect(Packer.archiveName(for: dotted, format: .zip) == ".profile.zip")
        #expect(Packer.archiveName(for: folder, format: .tar) == "folder.d.tar")
    }

    /// A link to a folder on a file system that cannot say where it points is left out.
    @Test
    internal func aLinkToAFolderElsewhereIsLeftOut() throws {
        let link = FileItem(url: bench.memory.url("link"), name: "link", kind: [.directory, .symlink])
        let archive = box.url("links.zip")
        let result = packer(bench.monitor).run([link], archive: archive)
        #expect(result.failure == nil && result.archives == [archive])
        #expect(try names(in: archive).isEmpty)
    }

    /// Symbolic links on the local disk are stored as links, in ZIP and in TAR.
    @Test(arguments: [ArchiveFormat.zip, .tar])
    internal func symbolicLinksAreStoredAsLinks(format: ArchiveFormat) throws {
        try box.file("tree/target.txt", "the target")
        try FileManager.default.createSymbolicLink(atPath: box.url("tree/link").path, withDestinationPath: "target.txt")
        let archive = box.url("links." + format.defaultExtension)
        try bench.pack([box.url("tree")], to: archive) { $0.format = format }
        let entry = try #require(try bench.store.archive(at: archive).entry("tree/link"))
        #expect(entry.isSymbolicLink)
        #expect(try bench.read(bench.inside(archive, "tree/link")) == Data("target.txt".utf8))
    }

    /// An existing archive of another kind than ZIP is replaced only when the user agrees.
    @Test
    internal func anExistingTARIsReplacedOnlyWhenTheUserAgrees() throws {
        let old = try box.file("old.txt", "old")
        let new = try box.file("new.txt", "new")
        let archive = box.url("both.tar")
        try bench.pack([old], to: archive) { $0.format = .tar }
        let declined = packer(bench.monitor) { $0.format = .tar }
        declined.confirmReplace = { _ in false }
        #expect(declined.run([try bench.item(new)], archive: archive).cancelled)
        #expect(try names(in: archive) == ["old.txt"])
        let agreed = packer(bench.monitor) { $0.format = .tar }
        agreed.confirmReplace = { _ in true }
        #expect(agreed.run([try bench.item(new)], archive: archive).failure == nil)
        #expect(try names(in: archive) == ["new.txt"])
    }

    /// Archives of a type this program cannot write are refused.
    @Test
    internal func archivesOfAForeignTypeAreRefused() throws {
        let file = try bench.item(try box.file("a.txt"))
        let result = packer(bench.monitor) { $0.format = .foreign }.run([file], archive: box.url("a.rar"))
        #expect(
            result.failure?.localizedDescription
                == ArchiveError.unsupported("Creating archives of this type").errorDescription
        )
    }

    /// With dates by the newest file, the archive gets the time of the newest file in it.
    @Test
    internal func theArchiveCanTakeTheTimeOfItsNewestFile() throws {
        let newest = Date(timeIntervalSince1970: 1_500_000_000)
        try box.file("dated/old.txt", modified: Date(timeIntervalSince1970: 1_000_000_000))
        try box.file("dated/new.txt", modified: newest)
        let archive = box.url("dated.zip")
        try bench.pack([box.url("dated")], to: archive) { $0.datesByNewest = true }
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        #expect(attributes[.modificationDate] as? Date == newest)
    }

    /// A file that shrank since it was listed fills its place in a TAR with zeros.
    @Test
    internal func aFileThatShrankIsFilledUpWithZeros() throws {
        let url = try box.file("short.txt", "abc")
        let claimed = FileItem(url: url, name: "short.txt", stat: FileItem.Stat(size: 6))
        let archive = box.url("short.tar")
        let result = packer(bench.monitor) { $0.format = .tar }.run([claimed], archive: archive)
        #expect(result.failure == nil)
        #expect(try bench.read(bench.inside(archive, "short.txt")) == Data("abc".utf8) + Data(count: 3))
    }

    /// A pack whose archive cannot take its place leaves no temporary file and says why.
    @Test(arguments: [false, true])
    internal func aPackThatCannotPutItsArchiveInPlaceLeavesNothing(addsToZip: Bool) throws {
        let folder = try box.folder("locked")
        let archive = folder.appending(name: "out." + (addsToZip ? "zip" : "tar"))
        if addsToZip {
            try bench.pack([try box.file("first.txt")], to: archive)
        }
        let source = try bench.item(try box.file("second.txt", "second"))
        let monitor = CoverageArchivesFormatsMonitor()
        // While the file is read, the folder stops taking new names.
        monitor.whenReporting { _ in chmod(folder.path, 0o555) }
        defer { chmod(folder.path, 0o755) }
        let result = packer(monitor) { $0.format = addsToZip ? .zip : .tar }.run([source], archive: archive)
        // (The message names the archive where it really lies.)
        let named = [archive.path, Durable.realFile(archive).path].map { Support.systemError(EACCES, $0) }
        #expect(named.contains(result.failure?.localizedDescription ?? ""))
        chmod(folder.path, 0o755)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        // The temporary file could not go either; it is noted to be removed later.
        #expect(left.filter { $0.hasSuffix(".afm-pack.tmp") }.count == 1)
        #expect(left.contains(archive.lastPathComponent) == addsToZip)
    }

    /// A ZIP that was changed by someone else while members were added to it is left as it is.
    @Test
    internal func aZIPChangedWhileItIsAddedToIsLeftAlone() throws {
        let archive = box.url("changing.zip")
        try bench.pack([try box.file("first.txt")], to: archive)
        let monitor = CoverageArchivesFormatsMonitor()
        monitor.whenReporting { progress in
            guard progress.lines.first?.hasPrefix("Packing") == true else {
                return
            }
            let handle = try? FileHandle(forWritingTo: archive)
            _ = try? handle?.seekToEnd()
            try? handle?.write(contentsOf: Data("appended".utf8))
            try? handle?.close()
        }
        let source = try bench.item(try box.file("second.txt"))
        let result = packer(monitor).run([source], archive: archive)
        #expect(
            result.failure?.localizedDescription == ArchiveError.changedOutside("changing.zip").errorDescription
        )
        #expect(
            try !FileManager.default.contentsOfDirectory(atPath: box.root.path).contains { $0.hasSuffix(".tmp") }
        )
    }

    /// Members whose names cannot be shown stay in a ZIP that is added to, by cloning and by copying.
    @Test(arguments: [true, false])
    internal func membersWithNamesThatCannotBeShownStay(clones: Bool) throws {
        bench.environment.clonesArchives = clones
        let archive = box.url("odd.zip")
        let output = try OutputFile(creating: archive)
        let packer = ZipPacker(output, level: 0)
        let odd = ZipRecord.new(name: "../odd.txt", isDirectory: false, modified: Date(), permissions: 0o644)
        var sent = false
        try packer.add(odd, expectedSize: 3) {
            defer { sent = true }
            return sent ? nil : Data("odd".utf8)
        }
        try packer.finish()
        try output.close()
        try bench.pack([try box.file("new.txt")], to: archive)
        let records = try ZipDirectory.read(try RandomAccessFile(archive)).records.map(\.name)
        #expect(records == ["../odd.txt", "new.txt"])
    }

    /// What stands in front of the first member of a ZIP (a self-extracting program) stays
    /// when members are added by copying.
    @Test
    internal func aProgramInFrontOfAZIPStays() throws {
        bench.environment.clonesArchives = false
        let archive = box.url("program.zip")
        try bench.pack([try box.file("first.txt")], to: archive)
        let program = Data("#!/bin/sh\nexit 0\n".utf8)
        try (program + Data(contentsOf: archive)).write(to: archive)
        try bench.pack([try box.file("second.txt")], to: archive)
        let data = try Data(contentsOf: archive)
        #expect(data.prefix(program.count) == program)
        #expect(try names(in: archive) == ["first.txt", "second.txt"])
    }

    /// A new archive damaged before its test fails the pack, and the sources stay.
    @Test
    internal func aNewArchiveDamagedBeforeItsTestKeepsTheSources() throws {
        let source = try box.file("kept.txt", "contents that are checked")
        let archive = box.url("damaged.zip")
        let monitor = CoverageArchivesFormatsMonitor()
        monitor.whenReporting { progress in
            guard progress.lines.first?.hasPrefix("Testing") == true, var data = try? Data(contentsOf: archive),
                let range = data.range(of: Data("checked".utf8))
            else {
                return
            }
            data[range.lowerBound] ^= 0x20
            try? data.write(to: archive)
        }
        let result = packer(monitor) { options in
            options.level = 0
            options.verifies = true
            options.movesSources = true
        }
        .run([try bench.item(source)], archive: archive)
        let reason = "kept.txt: " + ArchiveError.crcMismatch("kept.txt").localizedDescription
        #expect(
            result.failure?.localizedDescription
                == ArchiveError.damaged("the new archive failed its test (\(reason))").errorDescription
        )
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}

import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The Archives plugin when the program quits with nothing left to write.
@MainActor
@Suite
internal struct CovSmallArchivePluginTests {
    /// Quitting with nothing to write lets go of the open archives and starts nothing more.
    @Test
    internal func quittingWithNothingToWriteLetsGoOfTheArchives() throws {
        let packing = try ArchiveBench()
        try packing.box.file("tree/a.txt", "a")
        let url = packing.box.url("tree.zip")
        try packing.pack([packing.box.url("tree")], to: url) { $0.format = .zip }
        let archives = ArchivesPlugin(flushDelay: nil, launchesApplications: false)
        let bench = TestBench(
            plugins: [archives],
            fileSystems: [LocalFileSystem()],
            left: packing.box.root,
            right: packing.box.root
        )
        weak var opened: OpenArchive?
        autoreleasepool {
            opened = try? archives.store.archive(at: url, cancellation: nil)
        }
        #expect(opened != nil && !archives.hasPendingChanges)
        archives.stop()
        #expect(opened == nil && archives.environment.isStopping)
        // The kernel the plugin was started in lives to here.
        withExtendedLifetime(bench) {
            // Nothing more to do with it.
        }
    }

    /// An archive whose file was changed by someone else while a change has begun in it stays
    /// the archive the store hands out, and the change is written.
    @Test
    internal func anArchiveInTheMiddleOfAChangeStaysWhenItsFileChanges() throws {
        let bench = try ArchiveBench()
        try bench.box.file("tree/a.txt", "a")
        let url = bench.box.url("tree.zip")
        try bench.pack([bench.box.url("tree")], to: url) { $0.format = .zip }
        let first = try bench.store.archive(at: url, cancellation: nil)
        let writer = try bench.zip.write(bench.inside(url, "tree/held.txt"))
        // Someone else touches the file: it is not the one that was read any more.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: url.path
        )
        #expect(try bench.store.archive(at: url, cancellation: nil) === first)
        try writer.close(attributes: FileAttributes())
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
    }
}

import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// The defaults of a file system that offers only what it must, sizes that are stopped half way,
/// and locations without a scheme.
@Suite(.serialized)
internal struct CoreProviderCoverageTests {
    /// A file system with the required calls only.
    private final class BareFileSystem: MemoryBacked, @unchecked Sendable {
        let inner = MemoryFileSystem(scheme: "corebare")
        var capabilities: FileSystemCapabilities { [.write] }

        deinit {
            // Nothing to release.
        }
    }

    /// A file system that keeps attributes and metadata, as far as being asked goes.
    ///
    /// Unchecked: the record is guarded by `lock`.
    private final class KeepingFileSystem: MemoryBacked, @unchecked Sendable {
        let inner = MemoryFileSystem(scheme: "corekeep")
        private let lock = NSLock()
        private var asked: [String] = []
        var capabilities: FileSystemCapabilities { [.write] }
        var record: [String] { lock.withLock { asked } }

        func setAttributes(_: FileAttributes, of url: URL) { lock.withLock { asked.append("attributes " + url.path) } }

        func copyMetadata(from _: URL, to destination: URL) {
            lock.withLock { asked.append("metadata " + destination.path) }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A file system that cannot list one folder.
    private final class FailingFileSystem: MemoryBacked, @unchecked Sendable {
        let inner = MemoryFileSystem(scheme: "corefail")
        var capabilities: FileSystemCapabilities { [.write] }

        func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
            if directory.path == "/top/one" {
                throw CocoaError(.fileReadNoPermission)
            }
            return try inner.list(directory, showHidden: showHidden)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A file system that reads paths from its root as its own.
    private final class RootedFileSystem: MemoryBacked, @unchecked Sendable {
        let inner = MemoryFileSystem(scheme: "corerooted")
        var capabilities: FileSystemCapabilities { [.write] }
        var readsRootedPaths: Bool { true }

        deinit {
            // Nothing to release.
        }
    }

    /// A file system that sets a flag when a given folder is listed: a user who gives up while
    /// the size of a tree is worked out.
    ///
    /// Unchecked: the flag is set before the walk and only read while it runs.
    private final class GivingUpFileSystem: MemoryBacked, @unchecked Sendable {
        let inner = MemoryFileSystem(scheme: "coregiveup")
        let flag = CancellationFlag()
        let stopAt: String
        var capabilities: FileSystemCapabilities { [.write] }

        init(stopAt: String) { self.stopAt = stopAt }

        func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
            if directory.path == stopAt {
                flag.cancel()
            }
            return try inner.list(directory, showHidden: showHidden)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A tree with files at each of three levels and two folders on the first.
    private static func fill(_ memory: MemoryFileSystem) {
        _ = memory.addFile("/top/a.txt", "12345")
        _ = memory.addFile("/top/one/b.txt", "123")
        _ = memory.addFile("/top/one/deep/c.txt", "1")
        _ = memory.addFile("/top/two/d.txt", "12")
    }

    /// Without a way of their own, file systems refuse attributes and metadata, keep no marks,
    /// and commit after asking `progress` once.
    @Test
    internal func theDefaultsOfAFileSystemThatOffersLittle() throws {
        let bare = BareFileSystem()
        let file = bare.inner.addFile("/a.txt")
        let live = CancellationFlag()
        #expect(throws: FileSystemError.self) { try bare.setAttributes(FileAttributes(), of: file, cancellation: live) }
        #expect(throws: FileSystemError.self) { try bare.copyMetadata(from: file, to: file, cancellation: live) }
        try bare.setQuarantine(Data([1]), of: file, cancellation: live)
        #expect(bare.quarantine(of: file) == nil)
        var asked = 0
        try bare.commit(file, cancellation: live) { _, _ in
            asked += 1
            return true
        }
        #expect(asked == 1)
        #expect(throws: CocoaError.self) { try bare.commit(file, cancellation: live) { _, _ in false } }
        let stopped = CancellationFlag()
        stopped.cancel()
        #expect(throws: CocoaError.self) { try bare.commit(file, cancellation: stopped) { _, _ in true } }
        #expect(throws: CocoaError.self) { try bare.setQuarantine(Data([1]), of: file, cancellation: stopped) }
    }

    /// The calls with a flag hand on to those without while the flag is not set.
    @Test
    internal func callsWithAFlagHandOnWhileItIsNotSet() throws {
        let keeping = KeepingFileSystem()
        let file = keeping.inner.addFile("/a.txt")
        try keeping.setAttributes(FileAttributes(), of: file, cancellation: CancellationFlag())
        try keeping.copyMetadata(from: file, to: file, cancellation: CancellationFlag())
        #expect(keeping.record == ["attributes /a.txt", "metadata /a.txt"])
    }

    /// A folder that cannot be listed counts as empty, in a walk level by level as in one that nests.
    @Test
    internal func aFolderThatCannotBeListedCountsAsEmpty() {
        let failing = FailingFileSystem()
        Self.fill(failing.inner)
        let top = failing.inner.url("/top")
        #expect(failing.totalSize(of: top, cancellation: CancellationFlag()) == 7)
        let depth = TreeWalk.nesting
        TreeWalk.nesting = TreeWalk.deepestNesting
        #expect(failing.totalSize(of: top, cancellation: CancellationFlag()) == 7)
        TreeWalk.nesting = depth
    }

    /// A path from the root is a place of the file system of the base when that file system
    /// reads such paths itself.
    @Test
    internal func aRootedPathIsAPlaceOfAFileSystemThatReadsIt() {
        let registry = FileSystemRegistry()
        registry.register(RootedFileSystem())
        let base = URL(string: "corerooted:/a")!
        #expect(registry.location(from: "/b/c", relativeTo: base).absoluteString == "corerooted:///b/c")
    }

    /// Every error says what went wrong in a sentence.
    @Test
    internal func errorsDescribeThemselves() {
        let url = URL(string: "nowhere:/a")!
        #expect(FileSystemError.noProvider(url).errorDescription == "No file system is available for nowhere:/a.")
        #expect(
            FileSystemError.crossesVolumes.errorDescription
                == "The file cannot be moved or copied inside its file system."
        )
        #expect(FileSystemError.alreadyExists("/a").errorDescription == "/a already exists.")
        #expect(FileSystemError.notSupported("Paste").errorDescription == "Paste is not supported here.")
    }

    /// A walk that is given up half way, nested or level by level, counts nothing.
    @Test
    internal func aSizeGivenUpHalfWayIsZero() {
        for stop in ["/top", "/top/one", "/top/one/deep"] {
            let nested = GivingUpFileSystem(stopAt: stop)
            Self.fill(nested.inner)
            #expect(nested.totalSize(of: nested.inner.url("/top"), cancellation: nested.flag) == 0, "\(stop)")
            let flat = GivingUpFileSystem(stopAt: stop)
            Self.fill(flat.inner)
            let depth = TreeWalk.nesting
            TreeWalk.nesting = TreeWalk.deepestNesting
            #expect(flat.totalSize(of: flat.inner.url("/top"), cancellation: flat.flag) == 0, "\(stop)")
            TreeWalk.nesting = depth
        }
        let whole = GivingUpFileSystem(stopAt: "/elsewhere")
        Self.fill(whole.inner)
        #expect(whole.totalSize(of: whole.inner.url("/top"), cancellation: whole.flag) == 11)
    }

    /// A location written without a scheme is a local one, for the registry, for keys and for
    /// containment.
    @Test
    internal func aLocationWithoutASchemeIsLocal() throws {
        let registry = FileSystemRegistry()
        let local = MemoryFileSystem(scheme: "file")
        registry.register(local)
        let bare = try #require(URL(string: "a/b"))
        #expect(try registry.provider(for: bare) === local)
        #expect(bare.locationKey == "file://a/b")
        #expect(PathSafety.isContained(bare, in: try #require(URL(string: "a"))))
    }

    /// Closing the files on a volume writes what is pending first, then every closer closes
    /// what it keeps open there.
    @Test
    internal func closingTheFilesOnAVolumeCallsEveryCloser() throws {
        let registry = FileSystemRegistry()
        let order = Shared<[String]>([])
        registry.addFlusher { url, _ in order.modify { $0.append("flush " + url.path) } }
        registry.addVolumeCloser { url, _ in order.modify { $0.append("close " + url.path) } }
        registry.addVolumeCloser { url, _ in order.modify { $0.append("close again " + url.path) } }
        try registry.closeFiles(on: URL(fileURLWithPath: "/Volumes/Stick"), cancellation: CancellationFlag())
        #expect(order.value == ["flush /Volumes/Stick", "close /Volumes/Stick", "close again /Volumes/Stick"])
    }
}

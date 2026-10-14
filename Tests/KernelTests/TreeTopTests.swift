import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// The top of a file system's tree (review 2, second pass, K039): asked of the file system that
/// knows it, found by going up where it does not say.
@Suite
internal struct TreeTopTests {
    /// A file system that knows its top, or not, and counts how often it is asked to go up.
    ///
    /// Unchecked: the count is guarded by `lock`; the rest are constants.
    internal final class RootedFileSystem: ListingOnly, @unchecked Sendable {
        /// `rooted`.
        internal let scheme = "rooted"
        /// None.
        internal let capabilities: FileSystemCapabilities = []
        /// Whether `root(of:)` answers by itself or goes up as the kernel's default does.
        internal let knowsItsTop: Bool
        private let lock = NSLock()
        private var climbs = 0

        /// How often `parent(of:)` was asked.
        internal var parentQuestions: Int { lock.withLock { climbs } }

        /// A file system that knows its top when `knowsItsTop`.
        internal init(knowsItsTop: Bool) { self.knowsItsTop = knowsItsTop }

        /// Every folder is empty.
        internal func list(_: URL, showHidden _: Bool) -> [FileItem] { [] }

        /// The folder above, counted; nil at `/`.
        internal func parent(of directory: URL) -> URL? {
            lock.withLock { climbs += 1 }
            return directory.path == "/" ? nil : directory.deletingLastPathComponent()
        }

        /// `rooted:///` when it knows its top; otherwise what the kernel does for a file
        /// system that does not say: it goes up.
        internal func root(of url: URL) -> URL {
            guard knowsItsTop else {
                var current = url
                while let parent = parent(of: current) {
                    current = parent
                }
                return current
            }
            return URL(string: "rooted:///") ?? url
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Loading a folder 400 levels deep asks a file system that knows its top once for the folder
    /// above; one that does not is climbed all the way, and both give the same root and parent.
    @Test(arguments: [true, false])
    internal func aFileSystemThatKnowsItsTopIsNotClimbed(knows: Bool) throws {
        let deep = "/" + (0..<400).map { "d\($0)" }.joined(separator: "/")
        let provider = RootedFileSystem(knowsItsTop: knows)
        let fileSystems = FileSystemRegistry()
        fileSystems.register(provider)
        let location = try #require(URL(string: "rooted://" + deep))
        let result = try PanelLoader.load(location, showHidden: false, fileSystems: fileSystems)
        #expect(result.listing.root.path == "/")
        #expect(result.listing.parent?.path == URL(fileURLWithPath: deep).deletingLastPathComponent().path)
        // One question for the directory above; the top is asked of the file system.
        if knows {
            #expect(provider.parentQuestions == 1)
        } else {
            #expect(provider.parentQuestions >= 400)
        }
    }

    /// The memory file system does not say where its top is: it is found by going up, also
    /// through the protocol, which is how the loader asks.
    @Test
    internal func theTopIsFoundByGoingUpWhereAFileSystemDoesNotSay() {
        let memory = MemoryFileSystem()
        #expect(memory.root(of: memory.url("/a/b/c")).path == "/")
        // Through the protocol, which is how the loader asks.
        let provider: any FileSystemProvider = memory
        #expect(provider.root(of: memory.url("/a/b/c")).isSameLocation(as: memory.url("/")))
    }
}

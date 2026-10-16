import Foundation
import TestSupport
import os

@testable import AFMKernel

/// A file system whose listings break off after their first batch.
///
/// As a disk that fails or a server that goes away halfway through a large folder. The folders
/// in `failing` cannot be read at all. A listing whose first batch is not wanted ends, and notes
/// whether it was told to stop. Everything else is not supported.
internal final class PanelsBrokenListing: FileSystemProvider, Sendable {
    /// Why the listing broke off.
    internal struct Broken: Error {}

    /// The scheme of its URLs.
    internal let scheme = "broken"
    /// It cannot be written.
    internal let capabilities = FileSystemCapabilities()
    /// The paths of folders that cannot be read at all.
    internal let failing: Set<String>
    /// How often the top of a tree was asked for.
    private let rootQuestions = OSAllocatedUnfairLock(initialState: 0)
    /// What `wasToldToStop` says.
    private let sawCancellation = OSAllocatedUnfairLock(initialState: false)

    /// Whether a listing whose batch was not wanted saw its cancellation flag set.
    internal var wasToldToStop: Bool { sawCancellation.withLock { $0 } }

    /// How often the top of a tree was asked for.
    internal var rootQuestionCount: Int { rootQuestions.withLock { $0 } }

    /// A file system whose folders at `failing` cannot be read.
    internal init(failing: Set<String>) {
        self.failing = failing
    }

    /// A file system whose every folder breaks off after its first batch.
    internal convenience init() {
        self.init(failing: [])
    }

    /// A URL of this file system.
    internal func url(_ path: String) -> URL {
        URL(string: "broken://host" + path) ?? URL(fileURLWithPath: path)
    }

    /// The first batch, then the error; nothing at all for a failing folder.
    internal func list(
        _ directory: URL,
        showHidden _: Bool,
        cancellation: CancellationFlag,
        receive: ([FileItem]) -> Bool
    )
        throws
    {
        guard !failing.contains(directory.path) else {
            throw Broken()
        }
        let item = FileItem(url: directory.appendingPathComponent("first"), name: "first")
        guard receive([item]) else {
            // Told to stop: the flag follows soon after the answer.
            sawCancellation.withLock { $0 = Wait.until { cancellation.isCancelled } }
            return
        }
        throw Broken()
    }

    /// Every listing breaks off.
    internal func list(_: URL, showHidden _: Bool) throws -> [FileItem] { throw Broken() }

    /// The top of every tree is the host's; each question is counted.
    internal func root(of _: URL) -> URL {
        rootQuestions.withLock { $0 += 1 }
        return url("/")
    }

    /// Every location is a folder.
    internal func item(at url: URL) -> FileItem? {
        FileItem(url: url, name: url.lastPathComponent, kind: .directory)
    }

    /// The folder above, up to the host.
    internal func parent(of directory: URL) -> URL? {
        directory.path == "/" || directory.path.isEmpty ? nil : directory.deletingLastPathComponent()
    }

    /// Not supported.
    internal func read(_: URL) throws -> any FileReader { throw Broken() }

    /// Not supported.
    internal func createDirectory(at _: URL) throws { throw Broken() }

    /// Not supported.
    internal func write(_: URL) throws -> any FileWriter { throw Broken() }

    /// Not supported.
    internal func remove(_: URL) throws { throw Broken() }

    /// Not supported.
    internal func move(_: URL, to _: URL, replacing _: Bool) throws { throw Broken() }

    /// Not supported.
    internal func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws { throw Broken() }

    deinit {
        // Nothing to release.
    }
}

public import Foundation

/// A scratch folder on the local disk that is removed when the test ends.
///
/// Unchecked: it holds constants only, and `FileManager.default` may be used from any thread.
public final class Sandbox: @unchecked Sendable {
    /// The folder itself, with links resolved, so paths read back from the disk compare equal.
    public let root: URL
    private let fileManager = FileManager.default

    /// Makes a new, empty folder of a unique name in the temporary folder; throws when the disk refuses.
    public init() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("afm-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The location of `path` inside the folder; nothing is made.
    public func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    /// Writes a file with `content`, making the folders above it, and gives it the modification date `modified` when
    /// one is given.
    ///
    /// Returns the file's location.
    @discardableResult
    public func file(_ path: String, _ content: String = "x", modified: Date? = nil) throws -> URL {
        let url = url(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    /// Makes a folder and the folders above it; returns its location.
    @discardableResult
    public func folder(_ path: String) throws -> URL {
        let url = url(path)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Whether anything is at `path`.
    public func exists(_ path: String) -> Bool { fileManager.fileExists(atPath: url(path).path) }

    /// The text of the file at `path`, or nil when there is none or it is not UTF-8.
    public func read(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }

    deinit { try? fileManager.removeItem(at: root) }
}

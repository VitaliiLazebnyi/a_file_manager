import Foundation

/// A scratch folder on the local disk that is removed when the test ends.
public final class Sandbox {
    public let root: URL
    private let fm = FileManager.default

    public init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("afm-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: root) }

    public func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    @discardableResult
    public func file(_ path: String, _ content: String = "x", modified: Date? = nil) throws -> URL {
        let url = url(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    @discardableResult
    public func folder(_ path: String) throws -> URL {
        let url = url(path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func exists(_ path: String) -> Bool { fm.fileExists(atPath: url(path).path) }
    public func read(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }
}

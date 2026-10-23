import AFMKernel
import Foundation

/// A file system of folders only, for the directory tree: listings come from a table at once,
/// and the next listing of a folder can be held until the test lets it go.
///
/// Unchecked: every value is guarded by `condition`.
internal final class CoveragePlacesFolders: FileSystemProvider, @unchecked Sendable {
    private struct NotAFolder: Error {}

    /// The scheme of its locations: `tree://`.
    internal let scheme = "tree"

    private let condition = NSCondition()
    private var children: [String: [String]] = ["/": []]
    /// Folders whose next listing waits until it is let go.
    private var holding: Set<String> = []
    private var waiting: [String: Int] = [:]
    private var letGo: Set<String> = []

    private lazy var offered = [
        Place(name: "Tree", url: url("/"), kind: .internalDisk),
        Place(name: "Inner", url: url("/Inner"), kind: .externalDisk),
        Place(name: "Home", url: url("/Home"), kind: .home)
    ]

    /// Nothing can be written: the file system offers no capability.
    internal var capabilities: FileSystemCapabilities { [] }

    /// The places the file system offers; at first the disk, one inside it, and a home folder.
    internal var placeList: [Place] {
        get { condition.withLock { offered } }
        set { condition.withLock { offered = newValue } }
    }

    /// A file system holding the folders `paths` and the folders above them.
    internal init(_ paths: [String]) {
        for path in paths {
            add(path)
        }
    }

    private static func path(of url: URL) -> String {
        let path = url.standardized.path
        return path.isEmpty ? "/" : path
    }

    /// The location of the folder at `path`, with or without its leading slash.
    internal func url(_ path: String) -> URL {
        URL(string: "tree://" + (path.hasPrefix("/") ? path : "/" + path)) ?? URL(fileURLWithPath: "/")
    }

    /// Makes a folder and the folders above it.
    internal func add(_ path: String) {
        condition.withLock {
            var parent = "/"
            for name in path.split(separator: "/").map(String.init) {
                let child = parent == "/" ? "/" + name : parent + "/" + name
                if children[child] == nil {
                    children[child] = []
                    children[parent, default: []].append(name)
                }
                parent = child
            }
        }
    }

    /// Removes a folder and what is in it.
    internal func remove(_ path: String) {
        let location = URL(fileURLWithPath: path)
        condition.withLock {
            children = children.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
            children[location.deletingLastPathComponent().path]?.removeAll { $0 == location.lastPathComponent }
        }
    }

    /// Adds `count` subfolders `f<n>` to the folder at `path` at once.
    internal func addMany(_ count: Int, below path: String) {
        condition.withLock {
            for index in 0..<count {
                let name = "f\(index)"
                children[path + "/" + name] = []
                children[path, default: []].append(name)
            }
        }
    }

    /// The next listing of `path` waits until `release(path)`.
    internal func hold(_ path: String) {
        condition.withLock { _ = holding.insert(path) }
    }

    /// Lets a held listing of `path` go on.
    internal func release(_ path: String) {
        condition.withLock {
            letGo.insert(path)
            condition.broadcast()
        }
    }

    /// Whether a listing of `path` waits right now.
    internal func isWaiting(_ path: String) -> Bool {
        condition.withLock { waiting[path, default: 0] > 0 }
    }

    private func pass(_ path: String) {
        condition.withLock {
            guard holding.remove(path) != nil else {
                return
            }
            waiting[path, default: 0] += 1
            while !letGo.contains(path) {
                condition.wait()
            }
            letGo.remove(path)
            waiting[path, default: 1] -= 1
        }
    }

    /// The subfolders of `directory`, after waiting if its listing is held; throws for a folder
    /// it does not have.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        let path = Self.path(of: directory)
        pass(path)
        guard let names = condition.withLock({ children[path] }) else {
            throw NotAFolder()
        }
        return names.filter { showHidden || !$0.hasPrefix(".") }
            .map { name in
                FileItem(
                    url: url(path == "/" ? "/" + name : path + "/" + name),
                    name: name,
                    kind: .init(isDirectory: true, isHidden: name.hasPrefix(".")),
                    stat: .init(permissions: 0o755)
                )
            }
    }

    /// No single item is known: always nil.
    internal func item(at _: URL) -> FileItem? { nil }

    /// The folder above `directory`; nil for the root.
    internal func parent(of directory: URL) -> URL? {
        let path = Self.path(of: directory)
        return path == "/" ? nil : url(URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }

    /// The one root, `tree:///`.
    internal func root(of _: URL) -> URL { url("/") }

    /// Throws: there are no files to read.
    internal func read(_: URL) throws -> any FileReader { throw FileSystemError.notSupported("Reading") }

    /// Throws: nothing can be written.
    internal func createDirectory(at _: URL) throws { throw FileSystemError.notSupported("Writing") }

    /// Throws: nothing can be written.
    internal func write(_: URL) throws -> any FileWriter { throw FileSystemError.notSupported("Writing") }

    /// Throws: nothing can be written.
    internal func remove(_: URL) throws { throw FileSystemError.notSupported("Writing") }

    /// Throws: nothing can be written.
    internal func move(_: URL, to _: URL, replacing _: Bool) throws { throw FileSystemError.notSupported("Writing") }

    /// Throws: nothing can be written.
    internal func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws {
        throw FileSystemError.notSupported("Writing")
    }

    /// The path as the panel shows it: `tree:` and the path.
    internal func displayPath(_ url: URL) -> String { "tree:" + Self.path(of: url) }

    /// The location of a typed `tree:` path; nil for any other text.
    internal func location(from text: String) -> URL? {
        text.hasPrefix("tree:") ? url(String(text.dropFirst(5))) : nil
    }

    /// The places of `placeList`.
    internal func places() -> [Place] { placeList }

    deinit {
        // Nothing to release.
    }
}

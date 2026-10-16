import AFMKernel
import Foundation
import TestSupport

/// A memory file system (scheme `scripted`) that does what the test says where a job meets the world: it runs a
/// hook before it answers a look at a path, fails moves, copies, removals and attribute changes by a rule, lists
/// files in an order of its own, and says what it can do.
///
/// Any thread: the rules are kept in `Shared` boxes; `base` is safe from any thread.
internal final class CovFileOpsScriptedDisk: FileSystemProvider, Sendable {
    /// What a rule decides for a call: nil lets it go on, an error ends it.
    internal typealias Rule = @Sendable (URL, URL?) -> (any Error)?

    /// The memory file system underneath, which holds the files.
    internal let base = MemoryFileSystem(scheme: "scripted")
    /// Paths from the root are this file system's own.
    internal let readsRootedPaths = true
    /// Runs before a look at a path is answered, with the path and how many looks at it came before.
    internal let beforeLook = Shared<(@Sendable (String, Int) -> Void)?>(nil)
    /// The looks so far, by path.
    internal let looks = Shared<[String: Int]>([:])
    /// Fails a move from the first to the second location.
    internal let moveRule = Shared<Rule?>(nil)
    /// Fails a copy from the first to the second location.
    internal let copyRule = Shared<Rule?>(nil)
    /// Fails a removal.
    internal let removeRule = Shared<Rule?>(nil)
    /// Fails a change of attributes.
    internal let attributesRule = Shared<Rule?>(nil)
    /// The order in which the file system reads files best; nil keeps the order asked.
    internal let order = Shared<(@Sendable ([URL]) -> [URL])?>(nil)
    /// What the file system can do.
    internal let abilities = Shared<FileSystemCapabilities>([.write, .trash])
    /// What a look at a path answers instead of the memory file system.
    internal let seen = Shared<[String: FileItem]>([:])
    /// How many reads of a file go well before the next one fails, by path, counted over every reader of it.
    internal let readsBeforeFailure = Shared<[String: Int]>([:])
    /// What moving to the Trash throws; nil moves the item into `/.Trash`.
    internal let trashError = Shared<(any Error)?>(nil)
    /// Runs before a folder is listed, with its path.
    internal let beforeList = Shared<(@Sendable (String) -> Void)?>(nil)
    /// The real place behind a path, given how often it was asked before; nil for none.
    internal let realPlaces = Shared<(@Sendable (String, Int) -> URL?)?>(nil)
    /// How often the real place of a path was asked, by path.
    internal let realAsks = Shared<[String: Int]>([:])

    /// `scripted`.
    internal var scheme: String { base.scheme }
    /// What the test says it can do.
    internal var capabilities: FileSystemCapabilities { abilities.value }

    /// Lets everything go on.
    internal init() {
        // The rules are set by the test.
    }

    /// The same everywhere.
    internal func capabilities(for _: URL) -> FileSystemCapabilities {
        abilities.value
    }

    /// Runs the hook of the folder, then lists it in the memory file system.
    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        beforeList.value?(directory.path)
        return try base.list(directory, showHidden: showHidden)
    }

    /// Runs the hook of the path, then asks the memory file system.
    internal func item(at url: URL) -> FileItem? {
        let path = url.path
        var count = 0
        looks.modify { counts in
            count = counts[path, default: 0]
            counts[path] = count + 1
        }
        beforeLook.value?(path, count)
        return seen.value[path] ?? base.item(at: url)
    }

    /// The memory file system's answer.
    internal func parent(of directory: URL) -> URL? {
        base.parent(of: directory)
    }

    /// The memory file system's reader, which fails where the test says.
    internal func read(_ url: URL) throws -> any FileReader {
        let reader = try base.read(url)
        guard readsBeforeFailure.value[url.path] != nil else {
            return reader
        }
        return CovFileOpsFailingReader(reader, path: url.path, budget: readsBeforeFailure)
    }

    /// The memory file system's continuation of a file.
    internal func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        try base.append(to: url, at: offset, cancellation: cancellation)
    }

    /// Moves the item into `/.Trash`, unless the test says what is thrown instead.
    internal func trash(_ url: URL) throws {
        if let error = trashError.value {
            throw error
        }
        base.addDirectory("/.Trash")
        try base.move(url, to: base.url("/.Trash/" + url.lastPathComponent), replacing: true)
    }

    /// The memory file system's writer.
    internal func write(_ url: URL) throws -> any FileWriter {
        try base.write(url)
    }

    /// Removes from the memory file system, unless the rule fails it.
    internal func remove(_ url: URL) throws {
        if let error = removeRule.value?(url, nil) {
            throw error
        }
        try base.remove(url)
    }

    /// Moves in the memory file system, unless the rule fails it.
    internal func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        if let error = moveRule.value?(source, destination) {
            throw error
        }
        try base.move(source, to: destination, replacing: replacing)
    }

    /// Copies in the memory file system, unless the rule fails it.
    internal func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        if let error = copyRule.value?(source, destination) {
            throw error
        }
        try base.copy(source, to: destination, progress: progress)
    }

    /// Changes the attributes in the memory file system, unless the rule fails it.
    internal func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        if let error = attributesRule.value?(url, nil) {
            throw error
        }
        try base.setAttributes(attributes, of: url)
    }

    /// The real place the test says.
    internal func realLocation(of url: URL) -> URL? {
        let path = url.path
        var count = 0
        realAsks.modify { counts in
            count = counts[path, default: 0]
            counts[path] = count + 1
        }
        return realPlaces.value?(path, count)
    }

    /// The order the test says.
    internal func readOrder(of urls: [URL]) -> [URL] {
        order.value?(urls) ?? urls
    }

    /// The memory file system's notation.
    internal func displayPath(_ url: URL) -> String {
        base.displayPath(url)
    }

    /// Reads the memory file system's notation.
    internal func location(from text: String) -> URL? {
        base.location(from: text)
    }

    /// The memory file system's volume.
    internal func volume(of url: URL) -> VolumeInfo? {
        base.volume(of: url)
    }

    /// Makes a folder in the memory file system.
    internal func createDirectory(at url: URL) {
        base.createDirectory(at: url)
    }

    deinit {
        // Nothing to release.
    }
}

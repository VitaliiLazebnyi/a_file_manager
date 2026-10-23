public import AFMKernel
public import Foundation

/// The file system of folders that exist only in the panel: the branch view of a directory and
/// lists of files from anywhere (spec 03 › Branch view, 09 › Feed to listbox).
///
/// Its entries are the real files. Each keeps its real `url`, so copying, deleting, viewing and
/// renaming go to the file system the file is on, without passing through here; only `name`
/// differs, being the path relative to the branch root (or the full path in a file list), which
/// is unique within the list. `parent(of:)` of a virtual folder is the real directory, so
/// `[..]` and Backspace leave the view.
///
/// **Threading.** Like every provider it is called from several threads at once. The registered
/// lists are kept by `lists`, which guards them with a lock of its own; the options and what was
/// learned on the last walk are guarded by `lock`. The walk itself holds no lock and reads the
/// directories of a level on all cores.
public final class VirtualFileSystem: FileSystemProvider, @unchecked Sendable {
    /// The lists that are remembered; the oldest is forgotten when one more is registered.
    internal static let listLimit = 64
    /// The files all lists together may hold; when a list is registered and there are more, the
    /// least recently used lists that are not watched are forgotten (the new one is kept).
    internal static let entryLimit = 3_000_000
    /// A list up to this long is prepared on the spot; a longer one in the background.
    internal static let inlineEntryLimit = 2_048
    /// How many files of a list that is not prepared yet are looked at to find folders to watch.
    internal static let parentScanLimit = 4_096
    /// The directories of a branch that are watched for changes; a larger branch is watched
    /// in its upper levels only.
    internal static let watchLimit = 512
    /// The entries of a file list that are looked up side by side before they are handed over.
    internal static let entriesPerBatch = 256

    /// The scheme of the locations this file system serves, `vfolder`.
    public let scheme = VirtualLocation.scheme
    /// The registered lists and which of them are shown.
    internal let lists = ListStore()
    /// Weak: the registry holds this file system, whose work (a list prepared in the background,
    /// a listing, a watcher) can still run after the registry has gone; it then finds no file
    /// systems.
    private weak let registry: FileSystemRegistry?
    private let lock = NSLock()
    private var storedOptions = Options()
    /// What the file system behind each virtual folder that was read can do, by its location key.
    private var noted: [String: FileSystemCapabilities] = [:]
    /// The directories read on the last walk of a virtual folder, by its location key.
    private var walked: [String: [URL]] = [:]

    /// The registry, or an empty one once it has gone.
    internal var fileSystems: FileSystemRegistry { registry ?? FileSystemRegistry() }

    /// How branch views are walked; read on the threads that list them, set from the settings.
    public var options: Options {
        get { synchronized { storedOptions } }
        set { synchronized { storedOptions = newValue } }
    }

    /// What every virtual folder that was read can do: the answer for a caller that does not
    /// say which location it means (`capabilities(for:)` does), so that with two different
    /// virtual folders shown it claims nothing that one of them cannot do.
    public var capabilities: FileSystemCapabilities {
        synchronized {
            noted.values.reduce(into: [.write, .trash] as FileSystemCapabilities) { common, next in
                common.formIntersection(next)
            }
        }
    }

    /// A file system that finds the real file systems in `fileSystems`, which it does not keep.
    public init(fileSystems: FileSystemRegistry) {
        registry = fileSystems
    }

    /// What the file systems of `locations` can all do, as far as a list of files is changed
    /// (its files are deleted, not written to).
    internal static func common(of locations: [URL], _ fileSystems: FileSystemRegistry) -> FileSystemCapabilities {
        var common: FileSystemCapabilities = [.write, .trash]
        for example in locations { common.formIntersection(fileSystems.capabilities(for: example)) }
        return common
    }

    /// What identifies a file in a list, as exact bytes: two names that differ only in Unicode
    /// normalisation are two files (a `String` key would merge them).
    ///
    /// The scheme, host, port and path, without a trailing slash (which `URL.path` never has), as
    /// `locationKey` has them.
    internal static func identity(of url: URL) -> [UInt8] {
        var bytes = Array((url.scheme ?? "file").utf8)
        bytes.append(0)
        if let host = url.host { bytes.append(contentsOf: host.utf8) }
        if let port = url.port { bytes.append(contentsOf: ":\(port)".utf8) }
        bytes.append(0)
        bytes.append(contentsOf: url.path.utf8)
        return bytes
    }

    /// The names the items are listed under: their own, except where two have the very same
    /// name (compared by bytes, as marks are), when each of those is listed by its `path`, so
    /// that no two entries of a list are marked together.
    internal static func uniqueNames(of items: [FileItem], path: (FileItem) -> String) -> [String] {
        var counts: [[UInt8]: Int] = [:]
        for item in items { counts[Array(item.name.utf8), default: 0] += 1 }
        var names = items.map { item in counts[Array(item.name.utf8)] == 1 ? item.name : path(item) }
        // Whatever still clashes (two paths that read alike) gets a number, so that no two
        // entries are ever marked together.
        var used = Set<[UInt8]>()
        for index in names.indices {
            var candidate = names[index]
            var number = 2
            while !used.insert(Array(candidate.utf8)).inserted {
                candidate = names[index] + " (\(number))"
                number += 1
            }
            names[index] = candidate
        }
        return names
    }

    /// What can be done in one virtual folder: a branch view or selected branch can do what
    /// the file system of its directory can; a list, what all the file systems of its files can.
    public func capabilities(for url: URL) -> FileSystemCapabilities {
        guard let location = VirtualLocation(url) else {
            return capabilities
        }
        switch location {
        case .branch(let real), .picked(_, let real):
            return fileSystems.capabilities(for: real)

        case .list(let id, _, _):
            guard let list = lists.registered(id, as: location) else {
                return capabilities
            }
            // A list that is not prepared yet is judged by its first file; this is asked on the
            // main thread, which must not wait for the work on a long list.
            let examples = list.preparedIfReady?.examples ?? Array(list.raw.prefix(1))
            let common = Self.common(of: examples, fileSystems)
            // The files of a list can be deleted where they lie, but a list is no folder:
            // nothing can be made "in" it (a new folder, a pasted file).
            return common.contains(.write) ? common.union(.removeOnly) : common
        }
    }

    /// The real directory for a virtual folder, which is how `[..]` leaves the view; nil for
    /// every other URL, so that climbing to the root ends at the real directory.
    public func parent(of directory: URL) -> URL? {
        VirtualLocation(directory)?.realDirectory
    }

    /// Notes what the file systems of `locations` can all do, as what the virtual folder can.
    internal func noteCapabilities(of locations: [URL], for virtual: URL) {
        var common: FileSystemCapabilities = [.write, .trash]
        for urlScheme in Set(locations.map { $0.scheme ?? "file" }) {
            guard let example = locations.first(where: { ($0.scheme ?? "file") == urlScheme }),
                let provider = try? fileSystems.provider(for: example)
            else { continue }
            common.formIntersection(provider.capabilities(for: example))
        }
        synchronized {
            if noted.count >= 32 { noted.removeAll() }
            noted[virtual.locationKey] = common
        }
    }

    /// Notes the directories a walk of the virtual folder read, the ones its watcher watches.
    internal func remember(_ directories: [URL], for virtual: URL) {
        synchronized {
            if walked.count >= 16 { walked.removeAll() }
            walked[virtual.locationKey] = Array(directories.prefix(Self.watchLimit))
        }
    }

    /// The directories the last walk of the virtual folder read; empty when it was not walked
    /// (a walk that was kept read its start at least).
    internal func walkedDirectories(of virtual: URL) -> [URL] {
        synchronized { walked[virtual.locationKey] ?? [] }
    }

    /// Runs `body` under `lock`.
    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    deinit {
        // Nothing to release: the lists go with it.
    }
}

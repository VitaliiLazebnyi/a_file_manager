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
/// lists, the options and what was learned on the last walk are guarded by one lock; the walk
/// itself holds no lock and reads the directories of a level on all cores.
///
/// All mutable state is guarded by `lock`.
public final class VirtualFileSystem: FileSystemProvider, @unchecked Sendable {
    public struct Options: Equatable, Sendable {
        /// Branch view also lists the folders themselves.
        public var listsFolders = false
        /// Branch view walks into packages (`.app`) instead of listing them as one item.
        public var entersPackages = false

        public init(listsFolders: Bool = false, entersPackages: Bool = false) {
            self.listsFolders = listsFolders
            self.entersPackages = entersPackages
        }
    }

    /// A registered list: the files of a search result, or the items a selected branch starts from.
    ///
    /// The files are registered as they come, which takes no time however many there are; what
    /// has to look at each of them (leaving out a file named twice, finding the folders to
    /// watch) is done once by `prepared`, off the main thread for a long list.
    ///
    /// `result` is guarded by `lock`, `stamp` by the file system's lock; the rest is fixed in `init`.
    private final class FileList: @unchecked Sendable {
        /// What was worked out from all the files of a list.
        struct Prepared {
            /// The files, each once.
            let entries: [URL]
            /// One entry of each file system the entries are on, which is what can differ.
            let examples: [URL]
            /// The folders the files are in, as many as are watched.
            let parents: [URL]
            let isLocal: Bool
        }

        let location: VirtualLocation
        let raw: [URL]
        /// The caller said no location is in `raw` twice.
        let isUnique: Bool
        private let lock = NSLock()
        private var result: Prepared?
        /// When the list was last used (a number from the file system's counter): the least
        /// recently used one is forgotten first.
        ///
        /// Guarded by the file system's lock.
        var stamp = 0

        /// The finished work; nil when it is not done yet, whoever is doing it.
        ///
        /// Never waits.
        var preparedIfReady: Prepared? {
            guard lock.try() else {
                return nil
            }
            defer { lock.unlock() }
            return result
        }

        init(location: VirtualLocation, raw: [URL], isUnique: Bool = false) {
            self.location = location
            self.raw = raw
            self.isUnique = isUnique
        }

        /// The finished work, waiting for it when another thread is on it.
        func prepared(_ make: ([URL]) -> Prepared) -> Prepared {
            lock.lock()
            defer { lock.unlock() }
            if let result {
                return result
            }
            let made = make(raw)
            result = made
            return made
        }
    }

    /// A list is kept in memory only: after a restart, or when many newer ones were made, the
    /// location of an old one leads nowhere.
    internal struct ForgottenList: LocalizedError {
        internal let title: String
        internal var errorDescription: String? { "The list “\(title)” is no longer available." }
    }

    /// Passes the first report on at once and the ones that follow within a short time as one
    /// more report after it.
    ///
    /// The reports go out on the main thread, whichever thread the real file system reports on, and
    /// none goes out once `cancel` was called. A folder that keeps changing is reported ever less
    /// often (up to `longestWindow` apart), so that the virtual folder is not walked again all the
    /// time.
    ///
    /// All mutable state is guarded by `lock`.
    private final class Coalescer: @unchecked Sendable {
        static let window: TimeInterval = 0.5
        static let longestWindow: TimeInterval = 8
        private let lock = NSLock()
        private var isQuiet = true
        private var isDirty = false
        private var isCancelled = false
        private var wait = Coalescer.window
        private let fire: @MainActor @Sendable () -> Void

        init(_ fire: @escaping @MainActor @Sendable () -> Void) { self.fire = fire }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            isCancelled = true
        }

        func signal() {
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                return
            }
            guard isQuiet else {
                isDirty = true
                lock.unlock()
                return
            }
            isQuiet = false
            wait = Self.window
            let delay = wait
            lock.unlock()
            deliver()
            schedule(after: delay)
        }

        @MainActor
        private func settle() {
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                return
            }
            let again = isDirty
            isDirty = false
            if again {
                wait = min(wait * 2, Self.longestWindow)
            } else {
                isQuiet = true
                wait = Self.window
            }
            let delay = wait
            lock.unlock()
            guard again else {
                return
            }
            fire()
            schedule(after: delay)
        }

        private func deliver() {
            if Thread.isMainThread {
                MainActor.assumeIsolated { fire() }
            } else {
                DispatchQueue.main.async { [self] in
                    lock.lock()
                    let cancelled = isCancelled
                    lock.unlock()
                    // The main queue runs its blocks on the main thread.
                    if !cancelled { MainActor.assumeIsolated { fire() } }
                }
            }
        }

        private func schedule(after delay: TimeInterval) {
            // The main queue runs its blocks on the main thread.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in MainActor.assumeIsolated { settle() } }
        }
    }

    /// Keeps the real file systems' watchers alive for as long as the caller keeps this.
    private final class Watchers: Sendable {
        let watchers: [any WatchToken]
        private let coalescers: [Coalescer]
        private let release: @Sendable () -> Void
        init(_ watchers: [any WatchToken], coalescers: [Coalescer], release: @escaping @Sendable () -> Void) {
            self.watchers = watchers
            self.coalescers = coalescers
            self.release = release
        }
        deinit {
            // A report that is still waiting for its turn must not reach a released watcher.
            coalescers.forEach { $0.cancel() }
            release()
        }
    }

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

    public let scheme = VirtualLocation.scheme
    /// Weak: the registry holds this file system, whose work (a list prepared in the background,
    /// a listing, a watcher) can still run after the registry has gone; it then finds no file
    /// systems.
    private weak let registry: FileSystemRegistry?
    private let lock = NSLock()
    private var lists: [Int: FileList] = [:]
    /// Ids are numbered from a random start, so the location of a list from an earlier run of
    /// the program (it is stored with tabs, history and hotlist) never names another list.
    private var nextID = Int.random(in: 1_000...1_000_000_000)
    /// How many watchers look at a virtual folder of each list: a list that is shown stays.
    private var watchedLists: [Int: Int] = [:]
    private var options_ = Options()
    /// What the file system behind each virtual folder that was read can do, by its location key.
    private var noted: [String: FileSystemCapabilities] = [:]
    /// Counts the uses of lists, to find the one that was used least recently.
    private var uses = 0
    /// The directories read on the last walk of a virtual folder, by its location key.
    private var walked: [String: [URL]] = [:]

    /// The registry, or an empty one once it has gone.
    private var fileSystems: FileSystemRegistry { registry ?? FileSystemRegistry() }

    public var options: Options {
        get { synchronized { options_ } }
        set { synchronized { options_ = newValue } }
    }

    /// What every virtual folder that was read can do: the answer for a caller that does not
    /// say which location it means (`capabilities(for:)` does), so that with two different
    /// virtual folders shown it claims nothing that one of them cannot do.
    public var capabilities: FileSystemCapabilities {
        synchronized { noted.values.reduce([.write, .trash]) { $0.intersection($1) } }
    }

    public init(fileSystems: FileSystemRegistry) {
        registry = fileSystems
    }

    /// What the file systems of `locations` can all do, as far as a list of files is changed
    /// (its files are deleted, not written to).
    private static func common(of locations: [URL], _ fileSystems: FileSystemRegistry) -> FileSystemCapabilities {
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
        var names = items.map { counts[Array($0.name.utf8)] == 1 ? $0.name : path($0) }
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

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// What can be done in one virtual folder: a branch view or selected branch can do what
    /// the file system of its directory can; a list, what all the file systems of its files can.
    public func capabilities(for url: URL) -> FileSystemCapabilities {
        switch VirtualLocation(url) {
        case .branch(let real), .picked(_, let real):
            return fileSystems.capabilities(for: real)

        case .list(let id, _, _):
            guard let list = registered(id, as: VirtualLocation(url)!) else {
                return capabilities
            }
            // A list that is not prepared yet is judged by its first file; this is asked on the
            // main thread, which must not wait for the work on a long list.
            let examples = list.preparedIfReady?.examples ?? Array(list.raw.prefix(1))
            let common = Self.common(of: examples, fileSystems)
            // The files of a list can be deleted where they lie, but a list is no folder:
            // nothing can be made "in" it (a new folder, a pasted file).
            return common.contains(.write) ? common.union(.removeOnly) : common

        case nil:
            return capabilities
        }
    }

    // MARK: Registering lists

    /// The location that shows the branch view of a real directory.
    public func branch(of directory: URL) -> URL {
        VirtualLocation.branch(of: directory).url
    }

    /// Registers a list of files and returns the location that shows it.
    ///
    /// A file that is named twice is listed once. `origin` is where `[..]` leads back to. Takes no
    /// time however long the list is: the files are looked at later, on a background thread.
    public func register(files: [URL], title: String, origin: URL?) -> URL {
        register(files, isUnique: false) { .list(id: $0, title: VirtualLocation.pathComponent(title), origin: origin) }
    }

    /// The same for a list the caller knows holds no location twice (Find Files leaves out the
    /// ones it has reported): the list is not looked through for doubles, which for a list of
    /// millions saves a key per file.
    public func register(files: [URL], title: String, origin: URL?, isUnique: Bool) -> URL {
        register(files, isUnique: isUnique) {
            .list(id: $0, title: VirtualLocation.pathComponent(title), origin: origin)
        }
    }

    /// Registers the items of `directory` a selected branch view starts from, and returns the
    /// location that shows it.
    public func registerPicked(_ items: [URL], in directory: URL) -> URL {
        register(items, isUnique: false) { .picked(id: $0, in: directory) }
    }

    private func register(_ entries: [URL], isUnique: Bool, location: (Int) -> VirtualLocation) -> URL {
        let list: FileList = synchronized {
            let id = nextID
            nextID += 1
            let list = FileList(location: location(id), raw: entries, isUnique: isUnique)
            uses += 1
            list.stamp = uses
            lists[id] = list
            forgetSurplus(keeping: id)
            return list
        }
        if entries.count <= Self.inlineEntryLimit {
            _ = prepared(list)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [self] in _ = prepared(list) }
        }
        return list.location.url
    }

    /// Forgets the least recently used lists that are not shown (watched) while there are too
    /// many lists or files; when all are shown, the limits are exceeded.
    ///
    /// Under the lock.
    private func forgetSurplus(keeping id: Int) {
        var total = lists.values.reduce(0) { $0 + $1.raw.count }
        while lists.count > Self.listLimit || total > Self.entryLimit {
            guard
                let oldest = lists.filter({ $0.key != id && watchedLists[$0.key] == nil })
                    .min(by: {
                        $0.value.stamp < $1.value.stamp
                    })
            else { return }
            total -= oldest.value.raw.count
            lists[oldest.key] = nil
        }
    }

    /// Works out what has to look at every file of the list.
    ///
    /// Blocks while another thread is on it; for the background.
    private func prepared(_ list: FileList) -> FileList.Prepared {
        list.prepared { raw in
            var seen = Set<[UInt8]>()
            var entries: [URL] = []
            if !list.isUnique {
                seen.reserveCapacity(raw.count)
                entries.reserveCapacity(raw.count)
            }
            var schemes = Set<String>()
            var examples: [URL] = []
            var isLocal = true
            var parents: [URL] = []
            var parentKeys = Set<[UInt8]>()
            var providers: [String: any FileSystemProvider?] = [:]
            for url in raw where list.isUnique || seen.insert(Self.identity(of: url)).inserted {
                if !list.isUnique { entries.append(url) }
                let scheme = url.scheme ?? "file"
                if schemes.insert(scheme).inserted { examples.append(url) }
                if !url.isFileURL { isLocal = false }
                // Only as many folders as are watched are looked up.
                if parents.count < Self.watchLimit {
                    if providers[scheme] == nil { providers[scheme] = .some(try? fileSystems.provider(for: url)) }
                    if let parent = providers[scheme]??.parent(of: url),
                        parentKeys.insert(Self.identity(of: parent)).inserted
                    {
                        parents.append(parent)
                    }
                }
            }
            return FileList.Prepared(
                entries: list.isUnique ? raw : entries,
                examples: examples,
                parents: parents,
                isLocal: isLocal
            )
        }
    }

    /// The real locations a registered list or selected branch was made from; nil for every
    /// other location and for a list that was forgotten.
    ///
    /// Waits for a long list to be worked through: not for the main thread.
    public func entries(of url: URL) -> [URL]? {
        guard let location = VirtualLocation(url) else {
            return nil
        }
        switch location {
        case .picked(let id, _), .list(let id, _, _):
            return registered(id, as: location).map { prepared($0).entries }

        default:
            return nil
        }
    }

    /// The real location a location in a branch view or selected branch stands for: the file
    /// or folder that is really there, which is what an operation on it must go to.
    ///
    /// Nil for every other URL and for a list (whose entries keep their real locations).
    public func realLocation(of url: URL) -> URL? {
        switch VirtualLocation(url) {
        case .branch(let real), .picked(_, let real):
            return real

        case .list, nil:
            return nil
        }
    }

    /// The list registered as `id`, when it is the one the location says: a stored location
    /// whose number was given to another list means nothing.
    ///
    /// Counts as a use of the list.
    private func registered(_ id: Int, as location: VirtualLocation) -> FileList? {
        synchronized {
            guard let list = lists[id], list.location.url.absoluteString == location.url.absoluteString else {
                return nil
            }
            uses += 1
            list.stamp = uses
            return list
        }
    }

    // MARK: Reading

    public func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        var items: [FileItem] = []
        try list(directory, showHidden: showHidden) { batch in
            items += batch
            return true
        }
        return items
    }

    public func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        try listing(directory, showHidden: showHidden, cancellation: nil, receive: receive)
    }

    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        var items: [FileItem] = []
        try list(directory, showHidden: showHidden, cancellation: cancellation) { batch in
            items += batch
            return true
        }
        return items
    }

    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool)
        throws
    {
        try listing(directory, showHidden: showHidden, cancellation: cancellation, receive: receive)
    }

    private func listing(
        _ directory: URL,
        showHidden: Bool,
        cancellation: CancellationFlag?,
        receive: ([FileItem]) -> Bool
    ) throws {
        guard let location = VirtualLocation(directory) else { throw FileSystemError.noProvider(directory) }
        let options = self.options
        let walker = BranchWalker(
            fileSystems: fileSystems,
            showHidden: showHidden,
            listsFolders: options.listsFolders,
            entersPackages: options.entersPackages
        )
        switch location {
        case .branch(let real):
            noteCapabilities(of: [real], for: directory)
            let visited = try walker.walk(
                [BranchWalker.Start(real)],
                mustRead: true,
                keeping: Self.watchLimit,
                cancellation: cancellation,
                receive: receive
            )
            // What a stopped walk read is not the branch.
            if cancellation?.isCancelled != true { remember(visited, for: directory) }

        case .picked(let id, let real):
            guard let list = registered(id, as: location) else { throw ForgottenList(title: real.lastPathComponent) }
            let entries = prepared(list).entries
            noteCapabilities(of: [real], for: directory)
            let found = Parallel.map(entries) { self.realItem(at: $0, cancellation: cancellation) }.compactMap { $0 }
            let names = Self.uniqueNames(of: found) { self.fileSystems.displayPath($0.url) }
            var starts: [BranchWalker.Start] = []
            var files: [FileItem] = []
            for (item, name) in zip(found, names) {
                let isWalked = item.isRealDirectory && (options.entersPackages || !item.isPackage)
                if isWalked { starts.append(BranchWalker.Start(item.url, prefix: name + "/")) }
                if !isWalked || options.listsFolders { files.append(name == item.name ? item : item.named(name)) }
            }
            if cancellation?.isCancelled == true {
                return
            }
            if !files.isEmpty, !receive(files) {
                return
            }
            let visited = try walker.walk(
                starts,
                keeping: Self.watchLimit,
                cancellation: cancellation,
                receive: receive
            )
            if cancellation?.isCancelled != true { remember([real] + visited, for: directory) }

        case .list(let id, let title, _):
            guard let list = registered(id, as: location) else { throw ForgottenList(title: title) }
            let prepared = self.prepared(list)
            let entries = prepared.entries
            noteCapabilities(of: prepared.examples, for: directory)
            for from in stride(from: 0, to: entries.count, by: Self.entriesPerBatch) {
                if cancellation?.isCancelled == true {
                    return
                }
                let chunk = Array(entries[from..<min(from + Self.entriesPerBatch, entries.count)])
                // Each file is asked for on its own file system; what has vanished is left out.
                let items = Parallel.map(chunk) { url in
                    self.realItem(at: url, cancellation: cancellation)?.named(self.fileSystems.displayPath(url))
                }
                if cancellation?.isCancelled == true || !receive(items.compactMap { $0 }) {
                    return
                }
            }
        }
    }

    /// The file on its own file system.
    private func realItem(at url: URL, cancellation: CancellationFlag?) -> FileItem? {
        guard let provider = try? fileSystems.provider(for: url) else {
            return nil
        }
        return cancellation.map { provider.item(at: url, cancellation: $0) } ?? provider.item(at: url)
    }

    private func noteCapabilities(of locations: [URL], for virtual: URL) {
        var common: FileSystemCapabilities = [.write, .trash]
        for scheme in Set(locations.map { $0.scheme ?? "file" }) {
            guard let example = locations.first(where: { ($0.scheme ?? "file") == scheme }),
                let provider = try? fileSystems.provider(for: example)
            else { continue }
            common.formIntersection(provider.capabilities(for: example))
        }
        synchronized {
            if noted.count >= 32 { noted.removeAll() }
            noted[virtual.locationKey] = common
        }
    }

    private func remember(_ directories: [URL], for virtual: URL) {
        synchronized {
            if walked.count >= 16 { walked.removeAll() }
            walked[virtual.locationKey] = Array(directories.prefix(Self.watchLimit))
        }
    }

    public func item(at url: URL) -> FileItem? {
        virtualItem(at: url, cancellation: nil)
    }

    public func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        virtualItem(at: url, cancellation: cancellation)
    }

    private func virtualItem(at url: URL, cancellation: CancellationFlag?) -> FileItem? {
        switch VirtualLocation(url) {
        case .branch(let real), .picked(_, let real):
            guard let item = realItem(at: real, cancellation: cancellation) else {
                return nil
            }
            // A directory is the virtual folder itself; anything else is simply the real file.
            return item.isDirectory
                ? FileItem(
                    url: url,
                    name: item.name,
                    kind: .directory,
                    stat: .init(modified: item.modified, permissions: item.permissions)
                ) : item

        case .list(let id, let title, _):
            return registered(id, as: VirtualLocation(url)!) == nil
                ? nil : FileItem(url: url, name: title, kind: .directory, stat: .init(permissions: 0o555))

        case nil:
            return nil
        }
    }

    /// The real directory for a virtual folder, which is how `[..]` leaves the view; nil for
    /// every other URL, so that climbing to the root ends at the real directory.
    public func parent(of directory: URL) -> URL? {
        VirtualLocation(directory)?.realDirectory
    }

    // MARK: Changing
    //
    // A location below a branch view has the path of a real location. Whatever is created in
    // a branch view (a new folder, a pasted file) therefore lands in the real directory.

    private func real(_ url: URL) throws -> (provider: any FileSystemProvider, url: URL) {
        switch VirtualLocation(url) {
        case .branch(let real), .picked(_, let real):
            return (try fileSystems.provider(for: real), real)

        case .list:
            throw FileSystemError.notSupported("Changing a list of files")

        case nil:
            throw FileSystemError.noProvider(url)
        }
    }

    public func read(_ url: URL) throws -> any FileReader {
        let target = try real(url)
        return try target.provider.read(target.url)
    }

    public func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        let target = try real(url)
        return try target.provider.read(target.url, cancellation: cancellation)
    }

    public func createDirectory(at url: URL) throws {
        let target = try real(url)
        try target.provider.createDirectory(at: target.url)
    }

    public func write(_ url: URL) throws -> any FileWriter {
        let target = try real(url)
        return try target.provider.write(target.url)
    }

    public func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        let target = try real(url)
        return try target.provider.write(target.url, cancellation: cancellation)
    }

    public func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        let target = try real(url)
        return try target.provider.append(to: target.url, at: offset, cancellation: cancellation)
    }

    public func remove(_ url: URL) throws {
        let target = try real(url)
        try target.provider.remove(target.url)
    }

    public func trash(_ url: URL) throws {
        let target = try real(url)
        try target.provider.trash(target.url)
    }

    public func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        let (from, to) = (try real(source), try real(destination))
        guard from.provider === to.provider else { throw FileSystemError.crossesVolumes }
        try from.provider.move(from.url, to: to.url, replacing: replacing)
    }

    public func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        let (from, to) = (try real(source), try real(destination))
        guard from.provider === to.provider else { throw FileSystemError.crossesVolumes }
        try from.provider.copy(from.url, to: to.url, progress: progress)
    }

    public func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        let target = try real(url)
        try target.provider.setAttributes(attributes, of: target.url)
    }

    /// The folder is a virtual one at both ends: the real file systems do the work.
    ///
    /// The source may also be a real location already; a list is nothing to copy metadata from.
    public func copyMetadata(from source: URL, to destination: URL) throws {
        let target = try real(destination)
        let origin: URL
        switch VirtualLocation(source) {
        case .branch(let real), .picked(_, let real):
            origin = real

        case .list:
            throw FileSystemError.notSupported("Copying metadata")

        case nil:
            origin = source
        }
        try target.provider.copyMetadata(from: origin, to: target.url)
    }

    /// A list has nothing written to it, so there is nothing to make durable.
    public func commit(_ url: URL, cancellation: CancellationFlag) throws {
        guard VirtualLocation(url)?.isList == false else {
            return
        }
        let target = try real(url)
        try target.provider.commit(target.url, cancellation: cancellation)
    }

    public func quarantine(of url: URL) -> Data? {
        guard let target = try? real(url) else {
            return nil
        }
        return target.provider.quarantine(of: target.url)
    }

    public func setQuarantine(_ value: Data, of url: URL) throws {
        let target = try real(url)
        try target.provider.setQuarantine(value, of: target.url)
    }

    public func totalSize(of directory: URL, cancellation: CancellationFlag) -> Int64 {
        guard let target = try? real(directory) else {
            return totalSizeByListing(of: directory, cancellation: cancellation)
        }
        return target.provider.totalSize(of: target.url, cancellation: cancellation)
    }

    // MARK: Surroundings

    /// `/Users/x/dir (branch)`, `/Users/x/dir (selected branch 3)`, `Search result (list 7)`.
    public func displayPath(_ url: URL) -> String {
        switch VirtualLocation(url) {
        case .branch(let real):
            return fileSystems.displayPath(real) + " (branch)"

        case .picked(let id, let real):
            return fileSystems.displayPath(real) + " (selected branch \(id))"

        case .list(let id, let title, _):
            return "\(title) (list \(id))"

        case nil:
            return url.absoluteString
        }
    }

    /// Reads what `displayPath` writes, and the URL itself.
    public func location(from text: String) -> URL? {
        if text.lowercased().hasPrefix(scheme + ":") {
            return URL(string: text).flatMap { VirtualLocation($0) == nil ? nil : $0 }
        }
        guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else {
            return nil
        }
        let note = text[open.upperBound...].dropLast()
        let front = String(text[..<open.lowerBound])
        if note == "branch" {
            guard !front.isEmpty else {
                return nil
            }
            return branch(of: fileSystems.location(from: front, relativeTo: URL(fileURLWithPath: "/")))
        }
        for kind in ["selected branch ", "list "] where note.hasPrefix(kind) {
            guard let id = Int(note.dropFirst(kind.count)), let list = synchronized({ lists[id] }) else {
                return nil
            }
            // It must be what `displayPath` writes for the list: another text that merely ends
            // alike is not this list.
            return displayPath(list.location.url) == text ? list.location.url : nil
        }
        return nil
    }

    public func volume(of url: URL) -> VolumeInfo? {
        switch VirtualLocation(url) {
        case .branch(let real), .picked(_, let real):
            return (try? fileSystems.provider(for: real))?.volume(of: real)

        case .list(let id, _, _):
            // Asked on the main thread: a list that is not prepared yet is judged by its first file.
            guard let list = registered(id, as: VirtualLocation(url)!) else {
                return VolumeInfo(name: "Search result:", isLocal: true)
            }
            return VolumeInfo(
                name: "Search result:",
                isLocal: list.preparedIfReady?.isLocal ?? (list.raw.first?.isFileURL != false)
            )

        case nil:
            return nil
        }
    }

    /// Watches the real directories behind the virtual folders, as far as that is cheap: the
    /// directories read on the last walk of a branch (up to `watchLimit`), and the folders of
    /// the files of a list.
    ///
    /// Any change in them is reported as a change of the virtual folder, on the main thread.
    @preconcurrency
    public func watch(_ directories: [URL], onChange: @escaping @MainActor @Sendable ([URL]) -> Void) -> (
        any WatchToken
    )? {
        var watchers: [any WatchToken] = []
        var coalescers: [Coalescer] = []
        var shownLists: [Int] = []
        for virtual in directories {
            var real: [URL]
            let location = VirtualLocation(virtual)
            switch location {
            case .picked(let id, _):
                shownLists.append(id)

            case .list(let id, _, _):
                shownLists.append(id)

            default:
                break
            }
            switch location {
            case .branch(let root), .picked(_, let root):
                real = synchronized { walked[virtual.locationKey] } ?? [root]

            case .list(let id, _, _):
                // Done by the preparation of the list; a list that is not through yet is
                // looked at in its first files only, so this takes no time on the main thread.
                real =
                    registered(id, as: location!)
                    .map { list in
                        list.preparedIfReady?.parents
                            ?? parents(ofFirst: Self.parentScanLimit, of: list.raw)
                    } ?? []

            case nil:
                continue
            }
            real = Array(real.prefix(Self.watchLimit))
            // Up to `watchLimit` folders report; a busy one must not have the whole virtual
            // folder walked again for each report.
            let coalescer = Coalescer { onChange([virtual]) }
            coalescers.append(coalescer)
            for (_, group) in Dictionary(grouping: real, by: \.scheme) {
                guard let provider = try? fileSystems.provider(for: group[0]), provider !== self,
                    let watcher = provider.watch(group, onChange: { _ in coalescer.signal() })
                else { continue }
                watchers.append(watcher)
            }
        }
        guard !watchers.isEmpty else {
            coalescers.forEach { $0.cancel() }
            return nil
        }
        synchronized { for id in shownLists { watchedLists[id, default: 0] += 1 } }
        return Watchers(watchers, coalescers: coalescers) { [weak self, shownLists] in
            guard let self else {
                return
            }
            synchronized {
                for id in shownLists {
                    if let count = self.watchedLists[id] { self.watchedLists[id] = count > 1 ? count - 1 : nil }
                }
            }
        }
    }

    /// The folders of the first `count` files, each once, as many as are watched.
    private func parents(ofFirst count: Int, of files: [URL]) -> [URL] {
        var seen = Set<[UInt8]>()
        var parents: [URL] = []
        for entry in files.prefix(count) {
            guard let parent = (try? fileSystems.provider(for: entry))?.parent(of: entry),
                seen.insert(Self.identity(of: parent)).inserted
            else { continue }
            parents.append(parent)
            if parents.count >= Self.watchLimit { break }
        }
        return parents
    }
}

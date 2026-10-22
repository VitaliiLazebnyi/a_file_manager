import AFMKernel
import Foundation

/// One row of the rename list: the file as it is on disk, and the name the masks work on
/// (which differs from the file's after "next step").
internal struct RenameEntry {
    internal var item: FileItem
    internal var name: String

    internal init(_ item: FileItem) {
        self.item = item
        name = Self.diskName(of: item)
    }

    /// The name the file has in its folder.
    ///
    /// A list gathered from elsewhere (a branch view, a search result) names its items by path, on
    /// every file system; the item's own location says what it is called. (A name with a slash
    /// would otherwise be read as a folder to move into.).
    internal static func diskName(of item: FileItem) -> String {
        item.name.utf8.contains(0x2F) ? item.url.lastPathComponent : item.name
    }

    internal var diskName: String { Self.diskName(of: item) }

    internal var directory: URL { item.url.deletingLastPathComponent() }
}

/// The new names of a list and how each of them stands.
internal struct RenamePreview {
    /// How the items stand, worked out with the preview (in the background) so that whoever
    /// shows it need not count the rows.
    internal struct Counts: Equatable {
        internal var changing = 0
        internal var conflicts = 0
        internal var errors = 0
    }

    internal var names: [String?]
    /// Where each item goes; nil where there is no usable name.
    internal var targets: [URL?]
    internal var statuses: [RenameStatus]
    internal var planner: RenamePlanner
    /// The keys of everything that is in the target folders now.
    internal var existing: Set<String>
    /// What is wrong with the settings as a whole (an invalid mask or expression).
    internal var problem: any Error?

    internal var conflicts: [Int] { statuses.indices.filter { statuses[$0].isConflict } }

    internal var counts: Counts {
        var counts = Counts()
        for status in statuses {
            switch status {
            case .ready:
                counts.changing += 1

            case .duplicate, .exists:
                counts.conflicts += 1

            case .error, .invalid:
                counts.errors += 1

            case .unchanged:
                break
            }
        }
        return counts
    }
}

/// The dates inside pictures (`[T4]`), kept for as long as a session lives: a list that is
/// only put in another order does not read its files again.
///
/// Safe to use from several threads.
///
/// Unchecked `Sendable`: `dates` is guarded by `lock`.
internal final class ContentDateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [URL: Date?] = [:]

    internal func date(of url: URL) -> Date? {
        lock.lock()
        let known = dates[url]
        lock.unlock()
        if let known {
            return known
        }
        let found = ContentDate.read(url)
        lock.lock()
        dates[url] = .some(found)
        lock.unlock()
        return found
    }
}

/// What a session works out once for its list and reuses for every preview: the subjects the
/// masks look at, the folders the items are in, which folders tell letter case apart, what
/// the folders hold and the dates inside pictures.
///
/// A session replaces its cache whenever the list changes and after a run, so nothing in it
/// outlives the list it was made for. Folder contents are as they were when first looked at; a run
/// lists them afresh. Safe to use from several threads.
///
/// Unchecked `Sendable`: all mutable state is guarded by `lock`; `dates` does not change.
internal final class RenameCache: @unchecked Sendable {
    internal struct Rows {
        internal var subjects: [RenameSubject]
        internal var folders: [URL]
        internal var folderKeys: [String]
    }

    private let lock = NSLock()
    private var rows: Rows?
    private var folding: [String: Bool]
    private var keys: [String: Set<String>]
    private let dates: ContentDateStore

    internal init(
        dates: ContentDateStore = ContentDateStore(),
        folding: [String: Bool] = [:],
        keys: [String: Set<String>] = [:]
    ) {
        self.dates = dates
        self.folding = folding
        self.keys = keys
    }

    /// A cache for the same items in another order, or with some of them taken out: what the
    /// folders hold, which of them tell letter case apart and the dates in pictures stay; the
    /// rows are made again.
    ///
    /// Previews under way keep the cache they have.
    internal func forChangedOrder() -> RenameCache {
        lock.lock()
        defer { lock.unlock() }
        return RenameCache(dates: dates, folding: folding, keys: keys)
    }

    internal func rows(for entries: [RenameEntry], fileSystems: FileSystemRegistry) -> Rows {
        lock.lock()
        let known = rows
        lock.unlock()
        if let known, known.subjects.count == entries.count {
            return known
        }
        let built = Parallel.map(entries, serialBelow: RenameComputation.parallelThreshold) {
            entry -> (RenameSubject, URL, String) in
            let directory = entry.directory
            return (
                RenameComputation.subject(for: entry, directory: directory, fileSystems: fileSystems), directory,
                directory.locationKey
            )
        }
        let result = Rows(subjects: built.map(\.0), folders: built.map(\.1), folderKeys: built.map(\.2))
        lock.lock()
        rows = result
        lock.unlock()
        return result
    }

    internal func foldsCase(folderKey: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return folding[folderKey]
    }

    internal func setFoldsCase(_ folds: Bool, folderKey: String) {
        lock.lock()
        defer { lock.unlock() }
        folding[folderKey] = folds
    }

    internal func existingKeys(folderKey: String) -> Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        return keys[folderKey]
    }

    internal func setExistingKeys(_ found: Set<String>, folderKey: String) {
        lock.lock()
        defer { lock.unlock() }
        keys[folderKey] = found
    }

    /// `[T4]` for a file: read once, however often the preview is computed.
    internal func contentDate(of url: URL) -> Date? {
        dates.date(of: url)
    }
}

/// Computes previews.
///
/// Everything here blocks (it lists the target folders) and belongs on a background thread; the
/// names themselves are computed on all cores.
internal enum RenameComputation {
    /// Lists below this size are not worth spreading over the cores.
    internal static let parallelThreshold = 256

    internal static func subject(for entry: RenameEntry, fileSystems: FileSystemRegistry) -> RenameSubject {
        subject(for: entry, directory: entry.directory, fileSystems: fileSystems)
    }

    internal static func subject(for entry: RenameEntry, directory: URL, fileSystems: FileSystemRegistry)
        -> RenameSubject
    {
        RenameSubject(
            name: entry.name,
            isFolder: entry.item.isFolder,
            size: entry.item.size,
            modified: entry.item.modified,
            directoryPath: fileSystems.displayPath(directory),
            folders: directory.pathComponents.filter { $0 != "/" },
            url: entry.item.url
        )
    }

    /// Where a new name puts an item: next to where it is, or, with slashes in the name, in
    /// a folder below (or, with a slash in front, anywhere on the same file system).
    internal static func target(of entry: RenameEntry, named name: String) -> URL {
        if name.utf8.first == 0x2F {
            // From the top of the item's file system.
            var root = entry.directory
            while root.pathComponents.count > 1 { root.deleteLastPathComponent() }
            return root.appending(path: String(name.dropFirst())).standardized
        }
        if name.utf8.contains(0x2F) {
            return entry.directory.appendingPathComponent(name, isDirectory: false).standardized
        }
        // `appending(name:)` writes the name of a file URL in the form a volume stores it in
        // (an accented letter as the letter and its accent), which would turn a rename that only
        // changes how the accents are written into no rename. Such a name is put into the path as typed.
        let old = entry.diskName
        if !name.utf8.elementsEqual(old.utf8),
            name.precomposedStringWithCanonicalMapping.utf8.elementsEqual(
                old.precomposedStringWithCanonicalMapping.utf8
            ),
            let url = location(named: name, in: entry.directory)
        {
            return url
        }
        return entry.directory.appending(name: name)
    }

    /// The name in the folder exactly as it is written; nil where no location can hold it.
    private static func location(named name: String, in directory: URL) -> URL? {
        var components = URLComponents(url: directory, resolvingAgainstBaseURL: false)
        // The folder's path ends with a slash (`deletingLastPathComponent`).
        components?.path += name
        return components?.url
    }

    /// The new names only: masks, Search & Replace and case, on all cores.
    ///
    /// `subjects` are the entries' subjects when they are known already. A cancelled computation
    /// returns names that are not to be used. `isCancelled` also ends a regular expression that is
    /// working on a name; one that takes too long gives that name no new name (`<Error!>`).
    internal static func names(
        _ entries: [RenameEntry],
        settings: RenameSettings,
        context: RenameContext,
        given: [String]?,
        fileSystems: FileSystemRegistry,
        subjects: [RenameSubject]? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> (names: [String?], problem: any Error?) {
        var context = context
        context.count = entries.count
        return withoutActuallyEscaping(isCancelled) { cancelled in
            let engine = RenameEngine(settings, context: context, cancelled: cancelled)
            let names = Parallel.map(Array(entries.indices), serialBelow: parallelThreshold) { index -> String? in
                if cancelled() {
                    return nil
                }
                // A list of given names may be shorter than the list of files; the rest keep their masks.
                let given = given.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                return engine.newName(
                    for: subjects?[index] ?? subject(for: entries[index], fileSystems: fileSystems),
                    index: index,
                    given: given
                )
            }
            return (names, engine.problem ?? engine.tooSlow)
        }
    }

    /// Names, targets and collisions.
    ///
    /// `isCancelled` is asked inside the stages, so a preview nobody waits for any more ends early
    /// (with whatever it has). A `cache` of the session saves listing the same folders and building
    /// the same subjects for every keystroke. `cancellation` ends the listing of a folder that does
    /// not answer.
    internal static func preview(
        _ entries: [RenameEntry],
        settings: RenameSettings,
        context: RenameContext,
        given: [String]? = nil,
        fileSystems: FileSystemRegistry,
        cache: RenameCache = RenameCache(),
        cancellation: CancellationFlag? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> RenamePreview {
        let rows = cache.rows(for: entries, fileSystems: fileSystems)
        let (names, problem) = names(
            entries,
            settings: settings,
            context: context,
            given: given,
            fileSystems: fileSystems,
            subjects: rows.subjects,
            isCancelled: isCancelled
        )
        let placed = Parallel.map(Array(entries.indices), serialBelow: parallelThreshold) {
            index -> (RenameStatus, URL?) in
            guard let name = names[index] else {
                return (.error, nil)
            }
            if let reason = RenameEngine.invalidity(of: name) {
                return (.invalid(reason), nil)
            }
            // Compared byte for byte: a name that differs from the file's only in how an accented
            // letter is written (`[u]`, precomposing) is a rename, though Swift calls the two equal.
            if name.utf8.elementsEqual(entries[index].diskName.utf8) {
                return (.unchanged, entries[index].item.url)
            }
            return (.ready, target(of: entries[index], named: name))
        }
        var statuses = placed.map(\.0)
        let targets = placed.map(\.1)
        let sources = entries.map(\.item.url)
        var preview = RenamePreview(
            names: names,
            targets: targets,
            statuses: statuses,
            planner: RenamePlanner(),
            existing: [],
            problem: problem
        )
        guard !isCancelled(), statuses.contains(.ready) else {
            return preview
        }

        let survey = RenameSurvey(fileSystems: fileSystems, cache: cache, cancellation: cancellation)
        // The folders the items go to: their own, unless the new name says otherwise.
        var folders: [String: URL] = [:]
        for index in sources.indices where statuses[index] == .ready {
            if names[index]?.utf8.contains(0x2F) == true, let target = targets[index] {
                let folder = target.deletingLastPathComponent()
                folders[folder.locationKey] = folder
            } else {
                folders[rows.folderKeys[index]] = rows.folders[index]
            }
        }
        let planner = survey.planner(for: entries, rows: rows, targetFolders: folders)
        guard !isCancelled() else {
            return preview
        }
        let existing = survey.existingKeys(in: folders, planner: planner, isCancelled: isCancelled)
        for (index, status) in planner.conflicts(sources: sources, targets: targets, existing: existing) {
            statuses[index] = status
        }
        preview.statuses = statuses
        preview.planner = planner
        preview.existing = existing
        return preview
    }
}

/// What the planner has to know about the file systems.
///
/// Blocks; not for the main thread.
internal struct RenameSurvey {
    internal let fileSystems: FileSystemRegistry
    /// What was found out about the same folders before, if the caller keeps any.
    internal var cache: RenameCache?
    /// Ends the listing of a folder that does not answer.
    internal var cancellation: CancellationFlag?

    internal init(fileSystems: FileSystemRegistry, cache: RenameCache? = nil, cancellation: CancellationFlag? = nil) {
        self.fileSystems = fileSystems
        self.cache = cache
        self.cancellation = cancellation
    }

    /// The keys of every entry of the given folders (by `locationKey`).
    ///
    /// A folder that does not exist yet has none.
    internal func existingKeys(
        in folders: [String: URL],
        planner: RenamePlanner,
        isCancelled: @Sendable () -> Bool
    ) -> Set<String> {
        let listed = Parallel.map(Array(folders)) { folderKey, folder -> Set<String> in
            if let known = cache?.existingKeys(folderKey: folderKey) {
                return known
            }
            guard !isCancelled(), let provider = try? fileSystems.provider(for: folder),
                let items = try? cancellation.map({ try provider.list(folder, showHidden: true, cancellation: $0) })
                    ?? provider.list(folder, showHidden: true)
            else { return [] }
            // A listing that was cut short by the cancellation is not what the folder holds.
            guard cancellation?.isCancelled != true else {
                return []
            }
            let found = Set(items.map { planner.key($0.url) })
            cache?.setExistingKeys(found, folderKey: folderKey)
            return found
        }
        guard listed.count > 1 else {
            return listed.first ?? []
        }
        return listed.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    /// The planner for a run: each folder is judged on its own, by the items in it, as it
    /// is the volume that decides (a list may hold items of several).
    ///
    /// A folder that holds none of the items takes the verdict of the nearest folder above it that
    /// does.
    internal func planner(for entries: [RenameEntry], rows: RenameCache.Rows, targetFolders: [String: URL])
        -> RenamePlanner
    {
        var samples: [String: [FileItem]] = [:]
        var sourceFolders: [String: URL] = [:]
        for index in entries.indices {
            let key = rows.folderKeys[index]
            sourceFolders[key] = rows.folders[index]
            if samples[key, default: []].count < 16, cache?.foldsCase(folderKey: key) == nil {
                samples[key, default: []].append(entries[index].item)
            }
        }
        var verdicts: [String: Bool] = [:]
        func verdict(_ key: String) -> Bool? {
            if let found = verdicts[key] ?? cache?.foldsCase(folderKey: key) {
                return found
            }
            guard let items = samples[key] else {
                return nil
            }
            let found = foldsCase(items)
            cache?.setFoldsCase(found, folderKey: key)
            verdicts[key] = found
            return found
        }
        var folded = Set<String>()
        var allFolders = sourceFolders
        allFolders.merge(targetFolders) { first, _ in first }
        for (key, folder) in allFolders {
            var current = folder
            var folds = verdict(key)
            while folds == nil, current.path.count > 1 {
                current = current.deletingLastPathComponent()
                folds = verdict(current.locationKey)
            }
            // A folder away from every source folder (a rename that moves items there): a
            // local one is asked of its volume, else it is taken to tell the cases apart.
            if folds == nil { folds = Self.volumeFoldsCase(folder) }
            if folds == true { folded.insert(key) }
        }
        return folded.isEmpty
            ? RenamePlanner()
            : folded.count == allFolders.count ? RenamePlanner(foldsCase: true) : RenamePlanner(foldedFolders: folded)
    }

    /// What a local volume says about letter case in names; nil for anything else or when it does not say.
    internal static func volumeFoldsCase(_ folder: URL) -> Bool? {
        guard folder.isFileURL else {
            return nil
        }
        // The nearest folder that exists answers for one that does not exist yet (the top always exists).
        var current = folder
        while !FileManager.default.fileExists(atPath: current.path) { current.deleteLastPathComponent() }
        let values = try? current.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames.map { !$0 }
    }

    /// Whether the file system of the items takes names that differ only in letter case for
    /// the same file.
    ///
    /// Found out by asking for one of the items under a differently cased name; no provider says it
    /// of itself.
    internal func foldsCase(_ items: [FileItem]) -> Bool {
        for item in items.prefix(16) {
            let name = RenameEntry.diskName(of: item)
            let swapped = name == name.uppercased() ? name.lowercased() : name.uppercased()
            guard swapped != name, let provider = try? fileSystems.provider(for: item.url) else { continue }
            let directory = item.url.deletingLastPathComponent()
            if cancellation?.isCancelled == true {
                return false
            }
            guard
                let found = cancellation.map({
                    provider.item(at: directory.appending(name: swapped), cancellation: $0)
                })
                    ?? provider.item(at: directory.appending(name: swapped))
            else { return false }
            // A file that really has the other spelling proves nothing; try the next item. On the
            // local disk one file under both spellings is told by its identity (no listing of the
            // folder at all); otherwise the folder is listed only as far as the other spelling.
            if item.url.isFileURL, RenameRunner.isSameFileOnDisk(item.url, directory.appending(name: swapped)) == true {
                return true
            }
            var exists = false
            let receive: ([FileItem]) -> Bool = { batch in
                if batch.contains(where: { $0.name == swapped }) { exists = true }
                return !exists
            }
            if let cancellation {
                _ = try? provider.list(directory, showHidden: true, cancellation: cancellation, receive: receive)
            } else {
                _ = try? provider.list(directory, showHidden: true, receive: receive)
            }
            if exists { continue }
            return found.size == item.size && found.isDirectory == item.isDirectory
        }
        return false
    }
}

/// A rename that was carried out, for Undo and the result log.
internal struct RenamedItem: Codable, Equatable {
    internal var from: URL
    internal var to: URL
}

/// What a run did.
internal struct RenameRunResult {
    internal var renamed: [RenamedItem] = []
    /// Item index and what went wrong.
    internal var failures: [(item: Int, message: String)] = []
    internal var cancelled = false
}

/// Carries out the steps of a plan through the file-system providers, one after the other.
///
/// Used on one thread, the job's.
internal final class RenameRunner {
    private let fileSystems: FileSystemRegistry
    private let cancellation: CancellationFlag
    /// Called before each step with the number of items done so far.
    internal var onProgress: ((_ step: RenameStep, _ done: Int) -> Void)?

    internal init(fileSystems: FileSystemRegistry, cancellation: CancellationFlag = CancellationFlag()) {
        self.fileSystems = fileSystems
        self.cancellation = cancellation
    }

    /// Whether the two locations are in one folder and their names are the same letters,
    /// differing only in how accents are written.
    internal static func differsInNormalizationOnly(_ first: URL, _ second: URL) -> Bool {
        guard first.deletingLastPathComponent().isSameLocation(as: second.deletingLastPathComponent()) else {
            return false
        }
        let (a, b) = (first.lastPathComponent, second.lastPathComponent)
        return !a.utf8.elementsEqual(b.utf8)
            && a.precomposedStringWithCanonicalMapping.utf8.elementsEqual(b.precomposedStringWithCanonicalMapping.utf8)
    }

    /// Whether two locations are one file (same device and inode).
    ///
    /// Locations that are not on the local disk cannot be asked and are taken at the planner's
    /// word. A target that is not there is no file at all: the volume tells upper from lower case
    /// after all, and the rename is an ordinary one that replaces nothing.
    internal static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        guard first.isFileURL, second.isFileURL else {
            return true
        }
        func identity(_ url: URL) -> (dev_t, ino_t)? {
            var info = stat()
            return lstat(url.path, &info) == 0 ? (info.st_dev, info.st_ino) : nil
        }
        guard let target = identity(second) else {
            return false
        }
        guard let source = identity(first) else {
            return false
        }
        return source == target
    }

    /// Whether two local locations are one file (device and inode); nil when either cannot be
    /// asked, and when the answer "yes" could be two names of a file with several links (the
    /// folder's listing tells those apart).
    internal static func isSameFileOnDisk(_ first: URL, _ second: URL) -> Bool? {
        func identity(_ url: URL) -> (dev_t, ino_t, nlink_t)? {
            var info = stat()
            return lstat(url.path, &info) == 0 ? (info.st_dev, info.st_ino, info.st_nlink) : nil
        }
        guard let one = identity(first), let other = identity(second) else {
            return nil
        }
        guard one.0 == other.0, one.1 == other.1 else {
            return false
        }
        return one.2 > 1 ? nil : true
    }

    internal func run(_ steps: [RenameStep], sources: [URL]) -> RenameRunResult {
        var result = RenameRunResult()
        var failed = Set<Int>()
        /// Items that sit under a temporary name right now.
        var parked: [Int: RenameStep] = [:]
        var madeFolders = Set<String>()
        var done = 0

        // Each item fails once: the steps of an item that failed are not tried.
        func fail(_ item: Int, _ error: any Error) {
            failed.insert(item)
            result.failures.append((item, error.localizedDescription))
        }

        func move(_ step: RenameStep) throws {
            let provider = try fileSystems.provider(for: step.from)
            let folder = step.to.deletingLastPathComponent()
            if !folder.isSameLocation(as: step.from.deletingLastPathComponent()),
                madeFolders.insert(folder.locationKey).inserted
            {
                // Missing target folders are created; Undo does not remove them.
                try fileSystems.provider(for: folder).createDirectory(at: folder)
            }
            // A name that differs only in how an accented letter is written (precomposed or not):
            // the volume takes both for the same name, so there is no rename it would do in one
            // step without replacing. It goes by way of a temporary name instead, which no volume
            // takes for the file's own, and never as a replacement of "itself" (a file system
            // that cleans up after such a replacement could take the file away).
            if Self.differsInNormalizationOnly(step.from, step.to) {
                let temporary = step.from.deletingLastPathComponent()
                    .appending(
                        name: ".afm-nf-\(UUID().uuidString.prefix(8)).tmp"
                    )
                try provider.move(step.from, to: temporary, replacing: false)
                do {
                    try provider.move(temporary, to: step.to, replacing: false)
                } catch {
                    try? provider.move(temporary, to: step.from, replacing: false)
                    throw error
                }
                return
            }
            // Never onto another file: only a change of letter case lands on the file itself, and
            // that is checked, not assumed, so that a wrong guess about the volume cannot
            // overwrite a different file (it is reported as a collision instead).
            try provider.move(
                step.from,
                to: step.to,
                replacing: step.ontoItself && Self.isSameFile(step.from, step.to)
            )
        }

        for step in steps {
            if cancellation.isCancelled {
                result.cancelled = true
                break
            }
            guard !failed.contains(step.item) else { continue }
            onProgress?(step, done)
            do {
                try move(step)
                switch step.kind {
                case .park:
                    parked[step.item] = step

                case .direct, .unpark:
                    parked[step.item] = nil
                    result.renamed.append(RenamedItem(from: sources[step.item], to: step.to))
                    done += 1
                }
            } catch {
                fail(step.item, error)
            }
        }
        // Nothing stays under a temporary name: a parked item whose turn never came goes on
        // to its new name if that is free by now, else back to its old one.
        for (item, park) in parked.sorted(by: { $0.key < $1.key }) {
            let final = steps.first { $0.item == item && $0.kind == .unpark }
            if let final, !failed.contains(item), (try? move(final)) != nil {
                result.renamed.append(RenamedItem(from: sources[item], to: final.to))
                continue
            }
            do {
                try move(RenameStep(item: item, from: park.to, to: park.from, kind: .unpark, ontoItself: false))
            } catch {
                fail(
                    item,
                    RenameRunError.leftUnderTemporaryName(park.to.lastPathComponent, error.localizedDescription)
                )
            }
        }
        return result
    }
}

internal enum RenameRunError: LocalizedError {
    case leftUnderTemporaryName(String, String)

    internal var errorDescription: String? {
        switch self {
        case .leftUnderTemporaryName(let name, let reason):
            return "The file was left under the temporary name \(name): \(reason)"
        }
    }
}

/// The result log (spec 19 › Multi-Rename result log): one line per renamed file, the old
/// full path and the new name, both quoted and joined by ` -> `.
internal enum RenameLog {
    internal static let fileName = "renlog.txt"

    /// Writes the log where only the user can read it: a folder and a file of their own, never
    /// one in a place that others can write to.
    internal static func write(_ renamed: [RenamedItem], to url: URL, fileSystems: FileSystemRegistry) {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard (try? Data(text(renamed, fileSystems: fileSystems).utf8).write(to: url, options: .atomic)) != nil else {
            return
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    internal static func text(_ renamed: [RenamedItem], fileSystems: FileSystemRegistry) -> String {
        renamed.map { item -> String in
            // A file that moved into another folder is logged with its path from the old one.
            let oldFolder = item.from.deletingLastPathComponent()
            let newName =
                item.to.deletingLastPathComponent().isSameLocation(as: oldFolder)
                ? item.to.lastPathComponent
                : item.to.isInside(oldFolder)
                    ? String(item.to.path.dropFirst(oldFolder.path.count).drop(while: { $0 == "/" }))
                    : fileSystems.displayPath(item.to)
            return "\"\(fileSystems.displayPath(item.from))\" -> \"\(newName)\"\n"
        }
        .joined()
    }
}

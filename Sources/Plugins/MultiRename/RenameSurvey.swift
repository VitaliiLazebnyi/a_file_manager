import AFMKernel
import Foundation

/// What the planner has to know about the file systems.
///
/// Blocks; not for the main thread.
internal struct RenameSurvey {
    /// The file systems the items are on.
    internal let fileSystems: FileSystemRegistry
    /// What was found out about the same folders before, if the caller keeps any.
    internal var cache: RenameCache?
    /// Ends the listing of a folder that does not answer.
    internal var cancellation: CancellationFlag?

    /// What a local volume says about letter case in names; nil for anything else or when it does not say.
    internal static func volumeCaseFolding(_ folder: URL) -> CaseFolding? {
        guard folder.isFileURL else {
            return nil
        }
        // The nearest folder that exists answers for one that does not exist yet (the top always exists).
        var current = folder
        while !FileManager.default.fileExists(atPath: current.path) {
            current.deleteLastPathComponent()
        }
        let values = try? current.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames.map { $0 ? .distinct : .folded }
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
            if let known = cache?.contents(folderKey: folderKey) {
                return known.keys
            }
            guard !isCancelled(), let provider = try? fileSystems.provider(for: folder),
                let items = try? cancellation.map({ try provider.list(folder, showHidden: true, cancellation: $0) })
                    ?? provider.list(folder, showHidden: true)
            else {
                return []
            }
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
            if samples[key, default: []].count < 16, cache?.folding(folderKey: key) == nil {
                samples[key, default: []].append(entries[index].item)
            }
        }
        var verdicts: [String: CaseFolding] = [:]
        func verdict(_ key: String) -> CaseFolding? {
            if let found = verdicts[key] ?? cache?.folding(folderKey: key) {
                return found
            }
            guard let items = samples[key] else {
                return nil
            }
            let found: CaseFolding = foldsCase(items) ? .folded : .distinct
            cache?.setFolding(found, folderKey: key)
            verdicts[key] = found
            return found
        }
        var folded = Set<String>()
        var allFolders = sourceFolders
        allFolders.merge(targetFolders) { first, _ in first }
        for (key, folder) in allFolders {
            var current = folder
            var folding = verdict(key)
            while folding == nil, current.path.count > 1 {
                current = current.deletingLastPathComponent()
                folding = verdict(current.locationKey)
            }
            // A folder away from every source folder (a rename that moves items there): a
            // local one is asked of its volume, else it is taken to tell the cases apart.
            if folding == nil {
                folding = Self.volumeCaseFolding(folder)
            }
            if folding == .folded {
                folded.insert(key)
            }
        }
        return folded.isEmpty
            ? RenamePlanner()
            : folded.count == allFolders.count ? RenamePlanner(foldsCase: true) : RenamePlanner(foldedFolders: folded)
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
            guard swapped != name, let provider = try? fileSystems.provider(for: item.url) else {
                continue
            }
            let directory = item.url.deletingLastPathComponent()
            if cancellation?.isCancelled == true {
                return false
            }
            guard
                let found = cancellation.map({ flag in
                    provider.item(at: directory.appending(name: swapped), cancellation: flag)
                })
                    ?? provider.item(at: directory.appending(name: swapped))
            else {
                return false
            }
            // A file that really has the other spelling proves nothing; try the next item. On the
            // local disk one file under both spellings is told by its identity (no listing of the
            // folder at all); otherwise the folder is listed only as far as the other spelling.
            if item.url.isFileURL, RenameRunner.sameness(item.url, directory.appending(name: swapped)) == .same {
                return true
            }
            if holds(swapped, in: directory, provider: provider) {
                continue
            }
            return found.size == item.size && found.isDirectory == item.isDirectory
        }
        return false
    }

    /// Whether the listing of `directory` has an entry named exactly `name`; the listing stops there.
    private func holds(_ name: String, in directory: URL, provider: any FileSystemProvider) -> Bool {
        var exists = false
        let receive: ([FileItem]) -> Bool = { batch in
            if batch.contains(where: { $0.name == name }) {
                exists = true
            }
            return !exists
        }
        if let cancellation {
            _ = try? provider.list(directory, showHidden: true, cancellation: cancellation, receive: receive)
        } else {
            _ = try? provider.list(directory, showHidden: true, receive: receive)
        }
        return exists
    }
}

import AFMKernel
import Foundation

/// Computes previews.
///
/// Everything here blocks (it lists the target folders) and belongs on a background thread; the
/// names themselves are computed on all cores.
internal enum RenameComputation {
    /// Lists below this size are not worth spreading over the cores.
    internal static let parallelThreshold = 256

    /// What the masks look at for `entry`.
    internal static func subject(for entry: RenameEntry, fileSystems: FileSystemRegistry) -> RenameSubject {
        subject(for: entry, directory: entry.directory, fileSystems: fileSystems)
    }

    /// What the masks look at for `entry`, which is in `directory`.
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
            while root.pathComponents.count > 1 {
                root.deleteLastPathComponent()
            }
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

    /// The new names only: masks, Search & Replace and case, on all cores.
    ///
    /// `subjects` are the entries' subjects when they are known already (empty: they are made here). A
    /// cancelled computation returns names that are not to be used. `isCancelled` also ends a regular
    /// expression that is working on a name; one that takes too long gives that name no new name
    /// (`<Error!>`).
    internal static func names(
        _ request: RenameRequest,
        fileSystems: FileSystemRegistry,
        subjects: [RenameSubject],
        isCancelled: @Sendable () -> Bool
    ) -> (names: [String?], problem: (any Error)?) {
        let (entries, given) = (request.entries, request.given)
        var context = request.context
        context.count = entries.count
        return withoutActuallyEscaping(isCancelled) { cancelled in
            let engine = RenameEngine(request.settings, context: context, cancelled: cancelled)
            let names = Parallel.map(Array(entries.indices), serialBelow: parallelThreshold) { index -> String? in
                if cancelled() {
                    return nil
                }
                // A list of given names may be shorter than the list of files; the rest keep their masks.
                return engine.newName(
                    for: subjects.indices.contains(index)
                        ? subjects[index] : subject(for: entries[index], fileSystems: fileSystems),
                    index: index,
                    given: given.indices.contains(index) ? given[index] : nil
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
        _ request: RenameRequest,
        fileSystems: FileSystemRegistry,
        cache: RenameCache,
        cancellation: CancellationFlag?,
        isCancelled: @Sendable () -> Bool
    ) -> RenamePreview {
        let entries = request.entries
        let rows = cache.rows(for: entries, fileSystems: fileSystems)
        let (names, problem) = names(
            request,
            fileSystems: fileSystems,
            subjects: rows.subjects,
            isCancelled: isCancelled
        )
        let placed = place(entries, named: names)
        var statuses = placed.map(\.status)
        let targets = placed.map(\.target)
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

    /// How each entry stands with its new name, and where the name puts it, on all cores.
    private static func place(
        _ entries: [RenameEntry],
        named names: [String?]
    ) -> [(status: RenameStatus, target: URL?)] {
        Parallel.map(Array(entries.indices), serialBelow: parallelThreshold) { index -> (RenameStatus, URL?) in
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
    }

    /// The name in the folder exactly as it is written; nil where no location can hold it.
    private static func location(named name: String, in directory: URL) -> URL? {
        var components = URLComponents(url: directory, resolvingAgainstBaseURL: false)
        // The folder's path ends with a slash (`deletingLastPathComponent`).
        components?.path += name
        return components?.url
    }
}

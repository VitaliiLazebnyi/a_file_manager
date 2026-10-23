import AFMKernel
import Foundation

/// Deciding, before anything is written, what goes where.
extension Unpacker {
    /// True when `url` is a place below `folder`, by the bytes of the two paths once `.` and
    /// `..` are taken out of them (the kernel's check for paths from outside).
    internal static func lies(_ url: URL, below folder: URL) -> Bool {
        PathSafety.isContained(url, in: folder)
    }

    /// The members `source` takes: the selected ones with everything in their folders, or all
    /// below its base.
    private static func entries(of source: Source) -> [ArchiveEntry] {
        let archive = source.archive
        switch source.selection {
        case .all:
            return source.base.isEmpty ? archive.entries : archive.descendants(of: source.base)

        case .paths(let paths):
            return paths.flatMap { path -> [ArchiveEntry] in
                guard let entry = archive.entry(path) else {
                    return []
                }
                return [entry] + (entry.isDirectory ? archive.descendants(of: path) : [])
            }
        }
    }

    /// Decides what goes where and settles every name collision, before anything is written.
    internal func plan(_ source: Source, into folder: URL) throws -> [Task] {
        let takesAll = FileMask(options.mask).matches("a.b") && FileMask(options.mask).matches("a")
        let mask = FileMask(options.mask)
        var tasks: [Task] = []
        var taken = Set<String>()
        for entry in Self.entries(of: source) {
            try checkCancelled()
            // Folders come along by themselves when everything is wanted; with a mask or
            // without paths only files are taken, and their folders are made as needed.
            if entry.isDirectory {
                guard takesAll, options.keepsPaths else { continue }
            } else if !takesAll, !mask.matches(entry.name) {
                continue
            }
            let relative = relativePath(of: entry, below: source.base)
            // The names are cut at the byte `/`, as the disk cuts them. The archive's
            // directory lets no path through that leads outside (`ArchiveTree.normalized`);
            // the place it comes to is checked here once more, whatever the path looked like.
            let names = ArchiveTree.names(of: relative)
            let target = names.reduce(folder) { $0.appending(name: $1) }
            guard !names.isEmpty, names.allSatisfy(PathSafety.isSafeName), Self.lies(target, below: folder) else {
                result.problems.append("\(entry.path): the name leads outside the folder that is unpacked into")
                continue
            }
            guard taken.insert(target.locationKey).inserted else { continue }
            if let task = try task(for: entry, at: target, names: names, below: folder, shownAs: relative) {
                tasks.append(task)
            }
        }
        return tasks
    }

    /// The path `entry` gets below the target: its own name without paths, otherwise its path
    /// relative to `base` (the whole path when it lies elsewhere).
    private func relativePath(of entry: ArchiveEntry, below base: String) -> String {
        if !options.keepsPaths {
            return entry.name
        }
        var relative = entry.path
        if let below = ArchiveTree.relative(relative, to: base) {
            relative = below
        }
        return relative
    }

    /// The task that writes `entry` to `target` (reached by `names` from `folder`); nil leaves the
    /// member out: a folder stands there, or the user does not want the file that does replaced.
    ///
    /// A folder of the archive never replaces anything; `relative` names the member in a problem.
    private func task(
        for entry: ArchiveEntry,
        at target: URL,
        names: [String],
        below folder: URL,
        shownAs relative: String
    ) throws -> Task? {
        guard !entry.isDirectory, let existing = fileSystems.item(at: target) else {
            return Task(entry: entry, target: target, replaces: false, root: folder, names: names)
        }
        if existing.isRealDirectory {
            result.problems.append("\(relative): a folder with this name exists")
            return nil
        }
        guard try mayOverwrite(existing, with: entry) else {
            return nil
        }
        return Task(entry: entry, target: target, replaces: true, root: folder, names: names)
    }

    private func mayOverwrite(_ existing: FileItem, with entry: ArchiveEntry) throws -> Bool {
        if overwriteAll {
            return true
        }
        if skipAll {
            return false
        }
        switch askConflict(existing, entry) {
        case .overwrite:
            return true

        case .overwriteAll:
            overwriteAll = true
            return true

        case .skip:
            return false

        case .skipAll:
            skipAll = true
            return false

        case .cancel:
            throw ArchiveError.cancelled
        }
    }
}

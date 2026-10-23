import AFMKernel
import Foundation

/// Carries out the steps of a plan through the file-system providers, one after the other.
///
/// Used on one thread, the job's.
internal final class RenameRunner {
    /// What the local disk says about two locations.
    internal enum Sameness {
        /// Two files.
        case different
        /// One file under two names.
        case same
        /// Either cannot be asked, or the two may be names of one file with several links.
        case unknown
    }

    /// What a run has done so far.
    private struct RunState {
        var result = RenameRunResult()
        /// Items whose steps are not tried any more.
        var failed = Set<Int>()
        /// Items that sit under a temporary name right now.
        var parked: [Int: RenameStep] = [:]
        /// The folders the run made for items that move into them.
        var madeFolders = Set<String>()
        var done = 0

        /// Each item fails once: the steps of an item that failed are not tried.
        mutating func fail(_ item: Int, _ error: any Error) {
            failed.insert(item)
            result.failures.append((item, error.localizedDescription))
        }
    }

    /// Called before each step with the number of items done so far.
    internal var onProgress: ((_ step: RenameStep, _ done: Int) -> Void)?
    private let fileSystems: FileSystemRegistry
    private let cancellation: CancellationFlag

    /// A runner through `fileSystems` that stops between two steps when `cancellation` says so.
    internal init(fileSystems: FileSystemRegistry, cancellation: CancellationFlag) {
        self.fileSystems = fileSystems
        self.cancellation = cancellation
    }

    /// Whether the two locations are in one folder and their names are the same letters,
    /// differing only in how accents are written.
    internal static func differsInNormalizationOnly(_ first: URL, _ second: URL) -> Bool {
        guard first.deletingLastPathComponent().isSameLocation(as: second.deletingLastPathComponent()) else {
            return false
        }
        let (firstName, secondName) = (first.lastPathComponent, second.lastPathComponent)
        return !firstName.utf8.elementsEqual(secondName.utf8)
            && firstName.precomposedStringWithCanonicalMapping.utf8.elementsEqual(
                secondName.precomposedStringWithCanonicalMapping.utf8
            )
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

    /// Whether two local locations are one file (device and inode): unknown when either cannot be
    /// asked, and when the answer "yes" could be two names of a file with several links (the
    /// folder's listing tells those apart).
    internal static func sameness(_ first: URL, _ second: URL) -> Sameness {
        struct Identity {
            var device: dev_t
            var inode: ino_t
            var links: nlink_t
        }
        func identity(_ url: URL) -> Identity? {
            var info = stat()
            return lstat(url.path, &info) == 0
                ? Identity(device: info.st_dev, inode: info.st_ino, links: info.st_nlink) : nil
        }
        guard let one = identity(first), let other = identity(second) else {
            return .unknown
        }
        guard one.device == other.device, one.inode == other.inode else {
            return .different
        }
        return one.links > 1 ? .unknown : .same
    }

    /// Carries out `steps` for the items at `sources`; what is parked when the steps end goes on to
    /// its new name if that is free, else back.
    internal func run(_ steps: [RenameStep], sources: [URL]) -> RenameRunResult {
        var state = RunState()
        for step in steps {
            if cancellation.isCancelled {
                state.result.cancelled = true
                break
            }
            guard !state.failed.contains(step.item) else {
                continue
            }
            onProgress?(step, state.done)
            do {
                try move(step, madeFolders: &state.madeFolders)
                switch step.kind {
                case .park:
                    state.parked[step.item] = step

                case .direct, .unpark:
                    state.parked[step.item] = nil
                    state.result.renamed.append(RenamedItem(from: sources[step.item], destination: step.destination))
                    state.done += 1
                }
            } catch {
                state.fail(step.item, error)
            }
        }
        settleParked(&state, steps: steps, sources: sources)
        return state.result
    }

    /// Nothing stays under a temporary name: a parked item whose turn never came goes on
    /// to its new name if that is free by now, else back to its old one.
    private func settleParked(_ state: inout RunState, steps: [RenameStep], sources: [URL]) {
        for (item, park) in state.parked.sorted(by: { $0.key < $1.key }) {
            let final = steps.first { $0.item == item && $0.kind == .unpark }
            if let final, !state.failed.contains(item), (try? move(final, madeFolders: &state.madeFolders)) != nil {
                state.result.renamed.append(RenamedItem(from: sources[item], destination: final.destination))
                continue
            }
            do {
                try move(
                    RenameStep(
                        item: item,
                        from: park.destination,
                        destination: park.from,
                        kind: .unpark,
                        ontoItself: false
                    ),
                    madeFolders: &state.madeFolders
                )
            } catch {
                state.fail(
                    item,
                    RenameRunError.leftUnderTemporaryName(
                        park.destination.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }
    }

    /// One step through the provider of its item; a missing target folder is made first (once per run).
    private func move(_ step: RenameStep, madeFolders: inout Set<String>) throws {
        let provider = try fileSystems.provider(for: step.from)
        let folder = step.destination.deletingLastPathComponent()
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
        if Self.differsInNormalizationOnly(step.from, step.destination) {
            let temporary = step.from.deletingLastPathComponent()
                .appending(name: ".afm-nf-\(UUID().uuidString.prefix(8)).tmp")
            try provider.move(step.from, to: temporary, replacing: false)
            do {
                try provider.move(temporary, to: step.destination, replacing: false)
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
            to: step.destination,
            replacing: step.ontoItself && Self.isSameFile(step.from, step.destination)
        )
    }

    deinit {
        // Nothing to release.
    }
}

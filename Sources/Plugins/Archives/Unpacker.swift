import AFMKernel
import Foundation

/// Unpack (spec 08 › Unpack): writes members of archives into a folder of any file system.
///
/// **Threading.** `run` blocks and is meant for a job's thread. Questions are settled first,
/// on that thread; then the members of an archive that can be read at any position are
/// unpacked on all cores at once, while archives that are one compressed stream are unpacked
/// in a single pass.
///
/// Unchecked: what changes (the answers to questions, the result, the counts, the open
/// folders) is touched only by the thread that calls `run`; the members that are written on
/// all cores use only what is fixed in `init` and `bytesDone` (which guards itself).
internal final class Unpacker: @unchecked Sendable {
    /// What to take out of one archive: all of it, or what was selected in a panel.
    internal struct Source {
        /// The archive the members come from.
        internal let archive: OpenArchive
        /// The folder inside the archive that paths are kept relative to.
        internal var base = ""
        /// The selected members (folders with everything in them).
        internal var selection = MemberChoice.all
    }

    /// One member to write, and where it goes.
    internal struct Task {
        /// The member of the archive.
        internal let entry: ArchiveEntry
        /// The place it is written to.
        internal let target: URL
        /// Whether a file that stands at `target` is replaced (the user said so).
        internal let replaces: Bool
        /// The folder this archive is unpacked into: nothing is written outside it.
        internal let root: URL
        /// The names from `root` down to `target`.
        internal let names: [String]
    }

    /// The file systems the targets are reached through.
    internal let fileSystems: FileSystemRegistry
    /// The job's monitor: cancellation, progress and questions.
    internal let monitor: any JobMonitor
    /// How the job is to work.
    internal let options: UnpackOptions
    /// Asks the user what to do about a file that exists; called on the job's thread.
    internal let askConflict: (_ existing: FileItem, _ entry: ArchiveEntry) -> UnpackConflictChoice
    /// True once existing files are replaced without asking (an option, or the user's answer).
    internal var overwriteAll: Bool
    /// True once existing files are left without asking (the user's answer).
    internal var skipAll = false
    /// What has been done so far.
    internal var result = UnpackResult()
    /// The bytes written so far, by all threads.
    internal let bytesDone = SharedCounter()
    /// The members written or passed over so far.
    internal var itemsDone = 0
    /// The members and bytes the archives claim, for the progress display.
    internal var total = (items: 0, bytes: Int64(0))
    /// The lines the progress display shows: which archive goes where.
    internal var lines: [String] = []
    /// Called on the writing thread when the folder a member goes into is open and before
    /// the member's file is made (tests: what is done to the target folder meanwhile).
    internal let whileUnpacking: (@Sendable (ArchiveEntry) -> Void)?
    /// Whether a path lies on a disk of this machine; a target elsewhere is written by path,
    /// through its file system.
    ///
    /// Set before `run`.
    internal var isOnLocalVolume: (String) -> Bool = Volume.isOnLocalVolume

    /// The folders of this machine's disks that are unpacked into, open; see `UnpackFolder`.
    ///
    /// A target elsewhere (a server, another archive, a network volume, where a call may hang and
    /// has to be given up through the file system's own means) has none: there the members are
    /// written by path through its file system, after a look for links on the way.
    internal var roots: [String: UnpackFolder] = [:]

    /// An Unpack that has not started; `run` does the work.
    ///
    /// `whileUnpacking` is for tests (see the property); `askConflict` is asked about every file
    /// that exists, unless `options` say to overwrite.
    internal init(
        fileSystems: FileSystemRegistry,
        monitor: any JobMonitor,
        options: UnpackOptions,
        whileUnpacking: (@Sendable (ArchiveEntry) -> Void)?,
        askConflict: @escaping (_ existing: FileItem, _ entry: ArchiveEntry) -> UnpackConflictChoice
    ) {
        self.fileSystems = fileSystems
        self.monitor = monitor
        self.options = options
        self.whileUnpacking = whileUnpacking
        self.askConflict = askConflict
        overwriteAll = options.overwrites
    }

    /// Unpacks `sources` into the folder `target` and says what came of it.
    ///
    /// Blocks; meant for a job's thread. Everything is planned (and every question asked) before
    /// the first member is written.
    internal func run(_ sources: [Source], into target: URL) -> UnpackResult {
        let destination = ArchiveURL.resolved(target)
        do {
            var work: [(archive: OpenArchive, tasks: [Task])] = []
            for source in sources {
                let name = source.archive.name
                // `photos.tar.gz` unpacks into `photos`.
                let ownName = ArchiveFormat.splitKnownExtension(name)?.base ?? FileItem.split(name).base
                let folder = options.separateFolders ? destination.appending(name: ownName) : destination
                work.append((source.archive, try plan(source, into: folder)))
            }
            // The sizes are what the archives claim; their sum must not run over.
            total = work.flatMap(\.tasks)
                .reduce(into: (0, Int64(0))) { sum, task in
                    sum = (sum.0 + 1, sum.1.addingSaturated(max(0, task.entry.size)))
                }
            for (archive, tasks) in work {
                try checkCancelled()
                // One operation for the passwords: the user is asked once, and only when
                // something that is to be unpacked is encrypted.
                try archive.withPasswordScope {
                    try ArchiveTester.unlock(archive, members: .paths(tasks.map(\.entry.path)))
                    lines = [
                        "Unpacking: \(fileSystems.displayPath(archive.archiveURL))",
                        "To: \(fileSystems.displayPath(destination))"
                    ]
                    try unpack(tasks, from: archive)
                }
            }
        } catch ArchiveError.cancelled {
            result.cancelled = true
        } catch {
            result.problems.append(error.localizedDescription)
        }
        report()
        return result
    }

    /// Throws `ArchiveError.cancelled` once the job is cancelled.
    internal func checkCancelled() throws {
        if monitor.cancellation.isCancelled { throw ArchiveError.cancelled }
    }

    /// Shows the progress so far.
    internal func report() {
        monitor.report(
            JobProgress(
                lines: lines,
                itemsDone: itemsDone,
                itemsTotal: total.items,
                bytesDone: bytesDone.value,
                bytesTotal: total.bytes
            )
        )
    }

    deinit {
        // Nothing to release.
    }
}

import AFMKernel
import Foundation

/// Pack (spec 08 › Pack): builds archives from files of any file system.
///
/// **Threading.** `run` blocks and is meant for a job's thread. Reading the sources and
/// writing the archive happen there; compression is spread over all cores (`ZipPacker`,
/// `ParallelCompressor`).
internal final class Packer {
    /// One thing to store: where it comes from and the path it gets in the archive.
    internal struct Member {
        /// The file or folder that is stored.
        internal let item: FileItem
        /// The path it gets in the archive.
        internal let path: String
    }

    /// One archive to write: where, for which operands, with which members.
    private struct Plan {
        let archive: URL
        let sources: [FileItem]
        let members: [Member]
    }

    private static let processMask: mode_t = {
        let mask = umask(0)
        umask(mask)
        return mask
    }()

    /// The file systems the sources and the archive are reached through.
    internal let fileSystems: FileSystemRegistry
    /// The open archives, through which an existing archive is changed.
    internal let store: ArchiveStore
    /// The job's monitor: cancellation and progress.
    internal let monitor: any JobMonitor
    /// How the job is to work.
    internal let options: PackOptions
    /// The members and bytes packed so far, for the progress display.
    internal var done = (items: 0, bytes: Int64(0))
    /// The members and bytes to pack.
    internal var total = (items: 0, bytes: Int64(0))
    /// The lines the progress display shows: what goes where.
    internal var lines: [String] = []
    private var lastReport = Date.distantPast
    /// The rights of an archive that is created (one that is replaced keeps its own).
    internal var newMode: mode_t = 0o600
    /// Asked before an existing archive is replaced (ZIP archives are added to instead);
    /// false cancels.
    ///
    /// Called on the job's thread.
    internal var confirmReplace: ((URL) -> Bool)?

    /// A Pack that has not started; `run` does the work.
    internal init(fileSystems: FileSystemRegistry, store: ArchiveStore, monitor: any JobMonitor, options: PackOptions) {
        self.fileSystems = fileSystems
        self.store = store
        self.monitor = monitor
        self.options = options
    }

    /// The name of the archive made for one operand: a folder or file gives `name.zip`; the
    /// single-file compressors keep the whole name (`a.txt` → `a.txt.gz`), spec 08 › Target string.
    internal static func archiveName(for source: FileItem, format: ArchiveFormat) -> String {
        if case .compressedFile = format {
            return source.name + "." + format.defaultExtension
        }
        return (source.isFolder || source.baseName.isEmpty ? source.name : source.baseName) + "."
            + format.defaultExtension
    }

    /// The rights a new archive gets: the user's own, and those of group and others only as
    /// far as every file packed into it grants them.
    ///
    /// An archive of private files is not readable by everyone on the machine.
    internal static func mode(for members: [Member]) -> mode_t {
        let shared = members.filter { !$0.item.isDirectory }.reduce(UInt16(0o044)) { $0 & $1.item.permissions }
        return mode_t(0o600 | shared) & ~processMask
    }

    /// Packs `sources` into the archive at `archive` (below `innerFolder` when it is an
    /// existing ZIP), or with `separateArchives` into one archive per source in the folder of
    /// `archive`.
    internal func run(_ sources: [FileItem], archive: URL, innerFolder: String) -> PackResult {
        var result = PackResult()
        do {
            let plans = try plans(for: sources, archive: archive)
            // Sizes may come from another archive's directory, which may claim anything.
            total = plans.flatMap(\.members)
                .reduce(into: (0, Int64(0))) { sum, member in
                    sum = (sum.0 + 1, sum.1.addingSaturated(member.item.isDirectory ? 0 : max(0, member.item.size)))
                }
            for plan in plans {
                try checkCancelled()
                let added = try pack(plan.members, into: plan.archive, innerFolder: innerFolder)
                result.archives.append(plan.archive)
                if options.verifies, options.format == .zip { try verify(plan.archive, members: added) }
                if options.movesSources {
                    // The sources are the only other copy: they go when the archive holds the data.
                    try commit(plan.archive)
                    try deleteSources(plan.members, operands: plan.sources)
                }
                result.completed += plan.sources.map(\.url)
            }
        } catch ArchiveError.cancelled {
            result.cancelled = true
        } catch {
            result.failure = error
        }
        return result
    }

    /// The archives to write: one at `archive`, or with `separateArchives` one per source.
    private func plans(for sources: [FileItem], archive: URL) throws -> [Plan] {
        guard options.separateArchives else {
            return [Plan(archive: archive, sources: sources, members: try collect(sources, skippingBase: false))]
        }
        let folder = archive.deletingLastPathComponent()
        return try sources.map { source in
            Plan(
                archive: folder.appending(name: Self.archiveName(for: source, format: options.format)),
                sources: [source],
                members: try collect([source], skippingBase: options.skipsBaseFolder)
            )
        }
    }

    /// Throws `ArchiveError.cancelled` once the job is cancelled.
    internal func checkCancelled() throws {
        if monitor.cancellation.isCancelled { throw ArchiveError.cancelled }
    }

    /// Shows the progress so far; without `force` at most twenty times a second.
    internal func report(force: Bool) {
        // A report for each of a hundred thousand small files would only slow the job down.
        guard force || Date().timeIntervalSince(lastReport) > 0.05 else {
            return
        }
        lastReport = Date()
        monitor.report(
            JobProgress(
                lines: lines,
                itemsDone: done.items,
                itemsTotal: total.items,
                bytesDone: done.bytes,
                bytesTotal: total.bytes
            )
        )
    }

    /// The files and folders to store with their paths (spec 08 › Options, "Path names × recursion").
    internal func collect(_ sources: [FileItem], skippingBase: Bool) throws -> [Member] {
        var members: [Member] = []
        func walk(_ item: FileItem, path: String, depth: Int) throws {
            try checkCancelled()
            guard item.isRealDirectory else {
                // A link to a folder on a file system that cannot say where it points is left out.
                if item.isDirectory, !item.url.isFileURL {
                    return
                }
                members.append(Member(item: item, path: options.storesPaths ? path : item.name))
                return
            }
            let isSkippedBase = skippingBase && depth == 0
            if options.storesPaths, !isSkippedBase { members.append(Member(item: item, path: path)) }
            // (Below the top only with recursion: without, the loop below passes over folders.)
            let children = Sorter.sorted(
                try fileSystems.provider(for: item.url).list(item.url, showHidden: true),
                byName: \.name
            )
            for child in children {
                // Without recursion only the files directly inside a selected folder are taken.
                if child.isRealDirectory, !options.recurses { continue }
                try walk(child, path: isSkippedBase ? child.name : path + "/" + child.name, depth: depth + 1)
            }
        }
        for source in sources { try walk(source, path: source.name, depth: 0) }
        // Without paths, files of different folders can meet under one name; an archive
        // would keep one of them, and Move to archive would then delete the other for good.
        var taken = Set<String>()
        for member in members where !taken.insert(member.path).inserted {
            throw ArchiveError.nameCollision(member.path)
        }
        return members
    }

    /// Where a symbolic link on the local disk points; nil for everything else.
    internal func linkTarget(of item: FileItem) -> String? {
        guard item.isSymlink, item.url.isFileURL else {
            return nil
        }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path)
    }

    /// Reads a source file in blocks of exactly `size` (the last one shorter), counting progress.
    internal func blocks(of item: FileItem, size: Int) throws -> (next: () throws -> Data?, close: () -> Void) {
        let reader = try fileSystems.provider(for: item.url).read(item.url, cancellation: monitor.cancellation)
        // A read that waits on a server ends when the job is cancelled.
        let tie = monitor.cancellation.interrupting(reader)
        var ended = false
        return (
            { [self] in
                guard !ended else {
                    return nil
                }
                try checkCancelled()
                var block = Data()
                while block.count < size {
                    guard let more = try reader.read(upToCount: size - block.count) else {
                        ended = true
                        break
                    }
                    block.append(more)
                }
                done.bytes += Int64(block.count)
                report(force: false)
                return block.isEmpty ? nil : block
            },
            {
                reader.close()
                withExtendedLifetime(tie) {
                    // Only kept alive up to here.
                }
            }
        )
    }

    deinit {
        // Nothing to release.
    }
}

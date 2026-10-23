import AFMKernel
import Foundation

/// Writing the planned members of one archive: folders first, then the files.
extension Unpacker {
    /// A file to write, with the open folder it goes below (nil: written by path).
    internal typealias FileTask = (task: Task, root: UnpackFolder?)

    /// Writes `tasks` from `archive`; a member that fails is a line in the result, the others
    /// go on.
    internal func unpack(_ tasks: [Task], from archive: OpenArchive) throws {
        roots = [:]
        defer { roots = [:] }
        let quarantine = archive.quarantine
        let files = makeFolders(tasks, quarantine: quarantine)
        if archive.allowsParallelReads {
            unpackOnAllCores(files, from: archive, quarantine: quarantine)
        } else {
            try unpackInOnePass(files, from: archive, quarantine: quarantine)
        }
        try checkCancelled()
    }

    /// The folder `root` held open, when it lies on a disk of this machine; made when missing.
    private func openRoot(_ root: URL) throws -> UnpackFolder? {
        if let known = roots[root.locationKey] {
            return known
        }
        guard root.isFileURL else {
            return nil
        }
        // Made as it is: only what lies below it comes from the archive.
        try fileSystems.provider(for: root).createDirectory(at: root, cancellation: monitor.cancellation)
        guard isOnLocalVolume(Durable.realFile(root).path) else {
            return nil
        }
        let folder = try UnpackFolder(root)
        roots[root.locationKey] = folder
        return folder
    }

    /// Makes the folders of `tasks`, in order, so the files find them, and returns the files that
    /// are left to write.
    ///
    /// What lies below a folder that could not be made is not tried: the folder's line says why
    /// none of it arrived.
    private func makeFolders(_ tasks: [Task], quarantine: Data?) -> [FileTask] {
        var made = Set<String>()
        var files: [FileTask] = []
        var failed: [String] = []
        func liesInFailed(_ task: Task) -> Bool {
            failed.contains { task.target.path.utf8.starts(with: $0.utf8) }
        }
        for task in tasks {
            if !failed.isEmpty, liesInFailed(task) {
                itemsDone += 1
                continue
            }
            do {
                let root = try openRoot(task.root)
                if task.entry.isDirectory {
                    if let root {
                        // A folder from the archive (an application is one) carries the mark too.
                        try root.makeFolder(task.names, quarantine: quarantine)
                    } else {
                        try makeFolder(task.target, below: task.root, made: &made)
                        Quarantine.apply(quarantine, to: task.target)
                    }
                    itemsDone += 1
                    result.unpacked += 1
                } else {
                    // (Below an open folder the folders above a file are made as it is written.)
                    if root == nil {
                        try makeFolder(task.target.deletingLastPathComponent(), below: task.root, made: &made)
                    }
                    files.append((task, root))
                }
                if result.firstTarget == nil { result.firstTarget = task.target }
            } catch {
                result.problems.append("\(task.entry.path): \(error.localizedDescription)")
                if task.entry.isDirectory { failed.append(task.target.path + "/") }
            }
        }
        if !failed.isEmpty {
            files.removeAll { file in liesInFailed(file.task) }
        }
        return files
    }

    /// Writes the files of an archive that can be read at any position, on all cores.
    ///
    /// Symbolic links are made last, one by one, when every file is in its place: while the files
    /// are written on all cores at once, no link that the archive itself brings stands in the
    /// target yet, and the outcome does not depend on which thread came first.
    private func unpackOnAllCores(_ files: [FileTask], from archive: OpenArchive, quarantine: Data?) {
        let cancellation = monitor.cancellation
        let links = files.filter(\.task.entry.isSymbolicLink)
        let plain = files.filter { !$0.task.entry.isSymbolicLink }
        let outcomes = Background.run(
            { [self] in
                // Nil when the file arrived, empty when it was cancelled, else the problem.
                let one: @Sendable (FileTask) -> String? = { file in
                    let (task, root) = file
                    guard !cancellation.isCancelled else {
                        return ""
                    }
                    do {
                        // Cancel also ends the opening of a member, and a read that hangs.
                        let slot = InterruptSlot()
                        let registration = cancellation.onCancel { [weak slot] in slot?.interrupt() }
                        defer {
                            withExtendedLifetime(registration) {
                                // Only kept alive up to here.
                            }
                        }
                        let stream = try archive.open(task.entry, slot: slot)
                        defer { stream.close() }
                        try self.write(task, into: root, from: stream, quarantine: quarantine)
                        return nil
                    } catch ArchiveError.cancelled {
                        return ""
                    } catch {
                        return "\(task.entry.path): \(error.localizedDescription)"
                    }
                }
                return Parallel.map(plain, one) + links.map(one)
            },
            tick: report
        )
        result.unpacked += outcomes.filter { $0 == nil }.count
        itemsDone += outcomes.count
        result.problems += outcomes.compactMap(\.self).filter { !$0.isEmpty }
    }

    /// Writes the files of an archive that is one compressed stream, in a single pass through it.
    private func unpackInOnePass(_ files: [FileTask], from archive: OpenArchive, quarantine: Data?) throws {
        // (The pass hands over exactly the entries it was given, each of them once.)
        let byOrder = Dictionary(uniqueKeysWithValues: files.map { ($0.task.entry.order, $0) })
        let wanted = files.map(\.task.entry)
        // Read to the end of the stream when anything is read from it: only there is its
        // checksum checked, which vouches for the members written too (TAR has none).
        try archive.readInOnePass(
            wanted,
            cancellation: monitor.cancellation,
            throughTheEnd: !wanted.isEmpty
        ) { entry, stream in
            try checkCancelled()
            if let (task, root) = byOrder[entry.order] {
                do {
                    try write(task, into: root, from: stream, quarantine: quarantine)
                    result.unpacked += 1
                } catch ArchiveError.cancelled {
                    throw ArchiveError.cancelled
                } catch {
                    result.problems.append("\(entry.path): \(error.localizedDescription)")
                }
            }
            itemsDone += 1
            report()
        }
    }
}

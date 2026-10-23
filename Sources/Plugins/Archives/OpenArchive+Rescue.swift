import AFMKernel
import Foundation

/// Saving what could not be written.
extension OpenArchive {
    /// The last resort when changes cannot be written and the program is about to quit: the
    /// members that exist only in temporary files are written into an archive of their own,
    /// next to the archive or in the recovery folder.
    ///
    /// When that fails too (or `quickly`, when there is no time left to copy them), their
    /// compressed data is left on the disk instead of being cleared away with the temporary folder,
    /// with a list that says which file is which member. Members still under a job's temporary name
    /// are not saved: their job did not finish them, and its source is where it was.
    ///
    /// Waits for a write that is under way no longer than until `deadline`; then the data is kept as it is.
    internal func rescue(quickly: Bool, before deadline: Date) -> RescueOutcome {
        let holdsGate = gate.lock(long: true, before: deadline)
        defer { if holdsGate { gate.unlock() } }
        let fresh = locked {
            tree.ordered.compactMap { entry -> (path: String, record: ZipRecord)? in
                guard case .zip(let record) = entry.content, !record.isInArchive, !entry.isDirectory,
                    !Self.isTransfer(entry)
                else { return nil }
                return (entry.path, record)
            }
        }
        guard !fresh.isEmpty else {
            return .nothingToSave
        }
        let base = ArchiveFormat.splitKnownExtension(name)?.base ?? FileItem.split(name).base
        let folders =
            (fetchedCopy == nil ? [localURL.deletingLastPathComponent()] : [])
            + (environment.recoveryFolder.map { folder in [folder] } ?? [])
        for folder in folders where holdsGate && !quickly {
            if let saved = save(fresh, in: folder, base: base) {
                return .saved(saved)
            }
        }
        return .kept(keep(fresh))
    }

    /// Writes the members into a new archive in `folder`, named after the archive (`base`);
    /// returns it, or nil when it could not be written.
    private func save(_ fresh: [(path: String, record: ZipRecord)], in folder: URL, base: String) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(base) (unsaved changes).zip", isDirectory: false)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (unsaved changes \(number)).zip", isDirectory: false)
            number += 1
        }
        guard let output = try? OutputFile(creating: url, mode: 0o600) else {
            return nil
        }
        do {
            let writer = ZipWriter(output, limits: environment.limits)
            for member in fresh { try writer.copyMember(member.record, check: nil) }
            try writer.finish(comment: Data())
            try output.close(durably: true)
            return url
        } catch {
            try? output.close(durably: false)
            unlink(url.path)
            return nil
        }
    }

    /// Keeps the temporary files of the members, with a list of which file is which member;
    /// returns the folder they are kept in.
    private func keep(_ fresh: [(path: String, record: ZipRecord)]) -> URL {
        // Raw compressed data under made-up names is of little use without this list.
        var index =
            "Unsaved members of \(archiveURL.absoluteString)\n"
            + "file\tmember\tmethod (0 stored, 8 deflate, 99 AES)\tCRC-32\tsize\n"
        var kept: URL?
        for member in fresh {
            guard case .spool(let temporary) = member.record.source else { continue }
            temporary.keep()
            kept = kept ?? temporary.url.deletingLastPathComponent()
            let crc = String(format: "%08x", member.record.crc)
            index +=
                "\(temporary.url.lastPathComponent)\t\(member.path)\t\(member.record.method)\t\(crc)"
                + "\t\(member.record.uncompressedSize)\n"
        }
        let folder = kept ?? environment.scratch.url
        environment.scratch.keep()
        let list = folder.appendingPathComponent("index-\(instance).txt", isDirectory: false)
        try? Data(index.utf8).write(to: list)
        return folder
    }
}

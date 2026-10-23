import AFMKernel
import Foundation

/// What follows the writing of an archive: its test, its commit, the deletion of the sources.
extension Packer {
    /// Tests the new archive at once (spec 08 › After packing).
    ///
    /// A failure is reported and the archive stays; the sources are then not deleted. Of an archive
    /// that was added to, `members` names the new members: what it held before was not written again
    /// and is not read again.
    internal func verify(_ archive: URL, members: MemberChoice) throws {
        lines = ["Testing: \(fileSystems.displayPath(archive))"]
        report(force: true)
        let open = try store.archive(at: ArchiveURL.resolved(archive), cancellation: monitor.cancellation)
        if let password = options.password { open.usePassword(password) }
        let problems = ArchiveTester.test(open, cancellation: monitor.cancellation, counter: nil, members: members)
        try checkCancelled()
        if let first = problems.first { throw ArchiveError.damaged("the new archive failed its test (\(first))") }
    }

    /// Makes the new archive durable where it lies, when its file system keeps writes back
    /// (an archive in a ZIP, on a server): a failure ends the pack with the sources in place.
    internal func commit(_ place: URL) throws {
        let archive = ArchiveURL.resolved(place)
        let provider = try fileSystems.provider(for: archive)
        guard provider.capabilities(for: archive).contains(.deferredWrites) else {
            return
        }
        try provider.commit(archive, cancellation: monitor.cancellation)
        try checkCancelled()
    }

    /// Move to archive: exactly the files that were packed are deleted, then the folders that
    /// are empty afterwards.
    internal func deleteSources(_ members: [Member], operands: [FileItem]) throws {
        var folders: [URL] = operands.filter(\.isRealDirectory).map(\.url)
        for member in members {
            try checkCancelled()
            if member.item.isRealDirectory {
                folders.append(member.item.url)
            } else {
                try fileSystems.provider(for: member.item.url)
                    .remove(
                        member.item.url,
                        cancellation: monitor.cancellation
                    )
            }
        }
        // Deepest first; a folder that still holds something (not packed) stays.
        for folder in folders.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            try? fileSystems.provider(for: folder).remove(folder)
        }
    }
}

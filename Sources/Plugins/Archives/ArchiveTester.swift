import AFMKernel
import Foundation

/// Test archive (spec 08 › Test): reads every member to its end.
///
/// ZIP members are checked against their CRC, compressed streams against their own checksums, TAR
/// headers against theirs.
internal enum ArchiveTester {
    /// One test of one archive; any thread.
    internal struct Run {
        /// The archive that is tested.
        internal let archive: OpenArchive
        /// Set when the test is to end early.
        internal let cancellation: CancellationFlag
        /// Receives the bytes read, for a progress display.
        internal let counter: SharedCounter?

        /// What `work` found wrong with `entry`; nothing once the test is cancelled.
        internal func problem(with entry: ArchiveEntry, _ work: () throws -> Void) -> String? {
            guard !cancellation.isCancelled else {
                return nil
            }
            do {
                try work()
                return nil
            } catch ArchiveError.cancelled {
                return nil
            } catch {
                return "\(entry.path): \(error.localizedDescription)"
            }
        }

        /// Reads `stream` to its end; `entry` says how long it must be, when it knows.
        internal func readThrough(_ stream: any ByteStream, of entry: ArchiveEntry) throws {
            var read: Int64 = 0
            while let block = try stream.read(upToCount: 1 << 20) {
                if cancellation.isCancelled { throw ArchiveError.cancelled }
                read += Int64(block.count)
                counter?.add(Int64(block.count))
            }
            if entry.sizeIsExact, read != entry.size {
                throw ArchiveError.damaged("\(read) bytes instead of \(entry.size)")
            }
        }

        /// Tests `members` on all cores, each read from its own place in the archive.
        internal func onAllCores(_ members: [ArchiveEntry]) -> [String] {
            Parallel.map(members) { entry -> String? in
                problem(with: entry) {
                    // Cancel also ends the opening of a member, and a read that hangs.
                    let slot = InterruptSlot()
                    let registration = cancellation.onCancel { [weak slot] in slot?.interrupt() }
                    defer {
                        withExtendedLifetime(registration) {
                            // Only kept alive up to here.
                        }
                    }
                    let stream = try archive.open(entry, slot: slot)
                    defer { stream.close() }
                    try readThrough(stream, of: entry)
                }
            }
            .compactMap(\.self)
        }

        /// Tests `members` in one pass through the archive, to its end.
        internal func inOnePass(_ members: [ArchiveEntry]) -> [String] {
            var problems: [String] = []
            do {
                try archive.readInOnePass(members, cancellation: cancellation, throughTheEnd: true) { entry, stream in
                    if let found = problem(with: entry, { try readThrough(stream, of: entry) }) {
                        problems.append(found)
                    }
                }
            } catch ArchiveError.cancelled {
                // A cancelled test reports what it found up to then.
            } catch {
                problems.append(error.localizedDescription)
            }
            return problems
        }
    }

    /// Asks for the password once, before several threads would each ask for it; and only
    /// when one of the members that are wanted (`members`) is encrypted.
    internal static func unlock(_ archive: OpenArchive, members: MemberChoice) throws {
        guard let encrypted = members.pick(from: archive.entries).first(where: Self.isLockedFile) else {
            return
        }
        try archive.open(encrypted, slot: nil).close()
    }

    /// True for an encrypted file: what asks for a password when it is read.
    private static func isLockedFile(_ entry: ArchiveEntry) -> Bool {
        entry.isEncrypted && !entry.isDirectory
    }

    /// The problems found, one line per damaged member; empty when the archive is sound.
    ///
    /// Members that can be read independently are tested on all cores. `counter` receives the bytes
    /// read, for a progress display. Only the chosen `members` are read. Blocks; meant for a job's
    /// thread.
    internal static func test(
        _ archive: OpenArchive,
        cancellation: CancellationFlag,
        counter: SharedCounter?,
        members: MemberChoice
    ) -> [String] {
        // One operation: once the user has declined to give a password, no member asks again.
        archive.withPasswordScope {
            testInScope(archive, cancellation: cancellation, counter: counter, members: members)
        }
    }

    private static func testInScope(
        _ archive: OpenArchive,
        cancellation: CancellationFlag,
        counter: SharedCounter?,
        members choice: MemberChoice
    ) -> [String] {
        do { try unlock(archive, members: choice) } catch { return [error.localizedDescription] }
        let members = choice.pick(from: archive.entries).filter { !$0.isDirectory }
        let run = Run(archive: archive, cancellation: cancellation, counter: counter)
        // An archive that is one compressed stream is tested in a pass through the stream in its
        // file, to its end, for the stream's own checks; members it has a copy of come from there.
        if archive.allowsParallelReads, !archive.isOneStream {
            return run.onAllCores(members)
        }
        return run.inOnePass(members)
    }
}

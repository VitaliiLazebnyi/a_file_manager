import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2: archives the store lets go never take or lose a change.
@Suite
internal struct Review2ArchivesLetGoTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    // MARK: Archives the store lets go (A021, A024, A028, A072)

    /// An archive the store has let go takes no change; the change goes to its successor and is written (A021).
    @Test
    internal func aChangeNeverLandsInAnArchiveTheStoreHasLetGo() throws {
        let archive = try makeZip()
        let first = try bench.store.archive(at: archive, cancellation: nil)
        // With something waiting, or a writer open, the archive is not let go.
        let writer = try bench.zip.write(bench.inside(archive, "tree/held.txt", scheme: ArchiveURL.writableScheme))
        #expect(!first.retireIfIdle())
        try writer.write(Data("held".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(!first.retireIfIdle() && bench.store.flushAll(cancellation: nil).isEmpty)
        // Let go when idle (as eviction does), it takes no change any more…
        #expect(first.retireIfIdle() && !first.isCurrent(cancellation: nil))
        #expect { try first.write("tree/lost.txt", level: nil, password: nil) } throws: { error in
            if case ArchiveError.retired = error {
                return true
            }
            return false
        }
        #expect(throws: ArchiveError.self) { try first.remove("tree/readme.txt") }
        // …and the change that comes through the file system is made in its successor,
        // where the store finds it: a commit writes it.
        try write("kept", to: bench.inside(archive, "tree/kept.txt", scheme: ArchiveURL.writableScheme))
        let second = try bench.store.archive(at: archive, cancellation: nil)
        #expect(second !== first && second.hasPendingChanges && !first.hasPendingChanges)
        try bench.zip.commit(
            bench.inside(archive, "", scheme: ArchiveURL.writableScheme),
            cancellation: CancellationFlag()
        )
        #expect(listed(archive).contains("tree/kept.txt") && listed(archive).contains("tree/held.txt"))
    }

    /// Opening many archives never lets go of one with changes waiting (A024).
    @Test
    internal func openingManyArchivesNeverDropsOneWithChangesWaiting() throws {
        let archive = try makeZip()
        try write("waiting", to: bench.inside(archive, "tree/waiting.txt", scheme: ArchiveURL.writableScheme))
        let busy = try bench.store.archive(at: archive, cancellation: nil)
        for index in 0..<30 {
            let other = box.url("other\(index).zip")
            try FileManager.default.copyItem(at: archive, to: other)
            _ = try bench.store.archive(at: other, cancellation: nil)
        }
        #expect(try bench.store.archive(at: archive, cancellation: nil) === busy && busy.hasPendingChanges)
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && listed(archive).contains("tree/waiting.txt"))
    }

    /// Writers on many threads and archives let go meanwhile lose no file that was written without an error.
    @Test
    internal func writersAndEvictionRaceWithoutLosingAFile() throws {
        let archives = try (0..<16)
            .map { index -> URL in
                let url = box.url("race\(index).zip")
                if index == 0 {
                    try box.file("seed/a.txt", "seed")
                    #expect(runTool("/usr/bin/zip", ["-qr", "race0.zip", "seed"], in: box.root).status == 0)
                } else {
                    try FileManager.default.copyItem(at: box.url("race0.zip"), to: url)
                }
                return url
            }
        // Threads write into some archives while others are opened, which lets the least
        // recently used go. Whatever a write returned without an error must be in the file
        // after the changes were written.
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var written: [(archive: URL, name: String)] = []
        // Guarded by `lock`.
        nonisolated(unsafe) var failures: [String] = []
        let (shared, total) = (bench, 240)
        DispatchQueue.concurrentPerform(iterations: total) { index in
            let archive = archives[index % archives.count]
            if index.isMultiple(of: 3) {
                _ = try? shared.store.archive(at: archives[(index * 7) % archives.count], cancellation: nil)
                return
            }
            let name = "w\(index).txt"
            do {
                let url = shared.inside(archive, "seed/" + name, scheme: ArchiveURL.writableScheme)
                let writer = try shared.zip.write(url)
                try writer.write(Data("payload \(index)".utf8))
                try writer.close(attributes: FileAttributes())
                lock.lock()
                written.append((archive, name))
                lock.unlock()
            } catch {
                lock.lock()
                failures.append("\(name): \(error)")
                lock.unlock()
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(3))")
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && !bench.store.hasPendingChanges)
        var names: [URL: Set<String>] = [:]
        for archive in archives { names[archive] = Set(listed(archive)) }
        let missing = written.filter { names[$0.archive]?.contains("seed/" + $0.name) != true }
        #expect(
            missing.isEmpty && written.count == total - total / 3,
            "\(missing.count) of \(written.count) writes are missing"
        )
    }
}

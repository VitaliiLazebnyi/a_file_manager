import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2, integration: the kernel calls that arrived after the archives pass was
/// over, now used by the archives plugin.
///
/// A commit that asks while it runs (F046), and folders that an unpacking by path makes for
/// itself alone (L043).
@Suite
internal struct Review2IntegrationArchivesTests {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench
    /// The sandbox the archives are made in.
    internal var box: Sandbox { bench.box }

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// A ZIP of empty files under the given names, written by the plugin's own writer.
    private func writeZip(_ name: String, members: [String]) throws -> URL {
        let url = box.url(name)
        let output = try OutputFile(creating: url, mode: 0o600)
        let writer = ZipWriter(output, limits: .standard)
        for member in members {
            let record = ZipRecord.new(
                name: member,
                isDirectory: false,
                modified: Date(),
                permissions: 0o644,
                isSymbolicLink: false
            )
            try writer.end(try writer.begin(record, localExtra: nil, expectedSize: nil), record, headerChanged: false)
        }
        try writer.finish(comment: Data())
        try output.close(durably: false)
        return url
    }

    /// Writes `text` to the member at `url` through the archive's file system.
    private func write(_ text: String, to url: URL) throws {
        let writer = try bench.fileSystems.provider(for: url).write(url)
        try writer.write(Data(text.utf8))
        try writer.close(attributes: FileAttributes())
    }

    // MARK: F046 — the commit of an archive asks between its members

    /// The commit of a ZIP asks before every member it writes, with figures that only grow (F046).
    @Test
    internal func theCommitOfAnArchiveAsksBetweenTheMembersItWrites() throws {
        let url = try writeZip("commit.zip", members: (0..<40).map { "old-\($0).txt" })
        for number in 0..<20 {
            try write("new \(number)", to: bench.inside(url, "new-\(number).txt", scheme: ArchiveURL.writableScheme))
        }
        // (A member that was there is given another name, so the file is written anew.)
        try bench.zip.remove(bench.inside(url, "old-0.txt", scheme: ArchiveURL.writableScheme))
        var asked: [(done: Int64, total: Int64)] = []
        let root = bench.inside(url, "", scheme: ArchiveURL.writableScheme)
        try bench.zip.commit(root, cancellation: CancellationFlag()) { done, total in
            asked.append((done, total))
            return true
        }
        // Once before every member that is written, with figures that only grow.
        #expect(asked.count >= 59, "\(asked.count)")
        #expect(zip(asked, asked.dropFirst()).allSatisfy { $0.done <= $1.done })
        #expect(asked.allSatisfy { $0.total > 0 })
        let names = Set(
            try ZipDirectory.read(RandomAccessFile(url, shownAs: nil), maxEntries: .max, check: nil).records.map(\.name)
        )
        #expect(names.count == 59 && names.contains("new-19.txt") && !names.contains("old-0.txt"))
    }

    /// A commit ended while it runs leaves the file as it was, keeps what waited, and can be made again.
    @Test
    internal func aCommitThatIsEndedWhileItRunsHasChangedNothingAndCanBeMadeAgain() throws {
        let url = try writeZip("stopped.zip", members: (0..<30).map { "old-\($0).txt" })
        let root = bench.inside(url, "", scheme: ArchiveURL.writableScheme)
        for number in 0..<10 {
            try write("new \(number)", to: bench.inside(url, "new-\(number).txt", scheme: ArchiveURL.writableScheme))
        }
        let before = try Data(contentsOf: url)
        var asked = 0
        #expect(throws: CocoaError.self) {
            try bench.zip.commit(root, cancellation: CancellationFlag()) { _, _ in
                asked += 1
                return asked < 5
            }
        }
        #expect(asked == 5)
        // The file is the one it was; what waited still waits and is still shown.
        #expect(try Data(contentsOf: url) == before)
        #expect(try bench.zip.list(root, showHidden: true).count == 40)
        try bench.zip.commit(root, cancellation: CancellationFlag()) { _, _ in true }
        #expect(
            try ZipDirectory.read(RandomAccessFile(url, shownAs: nil), maxEntries: .max, check: nil).records.count == 40
        )
        // Nothing of the attempt that was ended is left next to the archive.
        #expect(
            try !FileManager.default.contentsOfDirectory(atPath: box.root.path).contains { $0.contains(".afm-zip") }
        )
    }

    // MARK: A wrong password for the old encryption is a wrong password

    /// The old ZIP encryption proves a password with one byte: one wrong password in 256 passes.
    ///
    /// The member then decrypts to noise, and the user was told the archive is damaged
    /// (`encryptedZipsAskForThePassword` failed that way once in the final runs: it gives three
    /// wrong answers and expects "wrong password"). Many wrong passwords here, so that some pass
    /// the byte: none may be reported as damage, and none may open anything.
    @Test
    internal func noWrongPasswordForTheOldEncryptionIsTakenForADamagedArchive() throws {
        let tree = try bench.makeTree("tree")
        let own = box.url("own.zip")
        try bench.pack([tree], to: own, innerFolder: "") { options in
            options.password = "open sesame"
            options.encryption = .legacy
        }
        var damaged: [String] = []
        var opened: [String] = []
        for number in 0..<1_500 {
            let fresh = try ArchiveBench()
            let candidate = "wrong-\(number)"
            fresh.passwords.set([candidate])
            do {
                _ = try fresh.read(fresh.inside(own, "tree/readme.txt", scheme: ArchiveURL.writableScheme))
                opened.append(candidate)
            } catch ArchiveError.damaged {
                damaged.append(candidate)
            } catch {
                // "Wrong password", or "a password is needed" when no further answer comes.
            }
        }
        #expect(damaged.isEmpty && opened.isEmpty, "damaged: \(damaged), opened: \(opened)")
        // The right one still opens it.
        let fresh = try ArchiveBench()
        fresh.passwords.set(["wrong-1", "open sesame"])
        #expect(
            try fresh.read(fresh.inside(own, "tree/readme.txt", scheme: ArchiveURL.writableScheme))
                == Data(contentsOf: tree.appendingPathComponent("readme.txt"))
        )
    }

    // MARK: L043 — by path (a target that is not a disk of this machine), folders are made exclusively

    /// Unpacking by path makes the folders it needs exclusively, and uses a folder that was there (L043).
    @Test
    internal func foldersOfATargetThatIsNotALocalDiskAreMadeForThisUnpackingAlone() throws {
        let hooked = IntegrationHookedMemory()
        bench.fileSystems.register(hooked)
        hooked.base.addFile("/target/there/kept.txt", "kept")
        let archive = try writeZip("tree.zip", members: ["there/a.txt", "new/deep/b.txt", "new/c.txt", "top.txt"])
        let unpacker = Unpacker(
            fileSystems: bench.fileSystems,
            monitor: bench.monitor,
            options: UnpackOptions(),
            whileUnpacking: nil
        ) { _, _ in
            .overwrite
        }
        let result = unpacker.run(
            [Unpacker.Source(archive: try bench.store.archive(at: archive, cancellation: nil))],
            into: hooked.base.url("/target")
        )
        #expect(result.problems.isEmpty, "\(result.problems)")
        #expect(
            Set(hooked.base.allPaths.filter { $0.hasPrefix("/target/") && !$0.contains(".afm-") })
                .isSuperset(of: [
                    "/target/there/a.txt", "/target/there/kept.txt", "/target/new/deep/b.txt", "/target/new/c.txt",
                    "/target/top.txt"
                ])
        )
        // The folder that was there is used as it is; the two that were not are made exclusively, once each.
        #expect(hooked.madeExclusively.sorted() == ["/target/new", "/target/new/deep"])
    }

    /// Something that takes a folder's name before the folder is made is not written through; the rest arrives.
    @Test
    internal func whatAppearsUnderAFoldersNameBeforeItIsMadeIsNotWrittenThrough() throws {
        let hooked = IntegrationHookedMemory()
        bench.fileSystems.register(hooked)
        hooked.base.addDirectory("/target")
        // Between the look ("nothing there") and the making of the folder, something else takes the name.
        hooked.beforeMaking = { [base = hooked.base] url in
            if url.lastPathComponent == "dir" { base.addFile("/target/dir", "somebody else's") }
        }
        let archive = try writeZip("planted.zip", members: ["dir/a.txt", "dir/b.txt", "plain.txt"])
        let unpacker = Unpacker(
            fileSystems: bench.fileSystems,
            monitor: bench.monitor,
            options: UnpackOptions(),
            whileUnpacking: nil
        ) { _, _ in
            .overwrite
        }
        let result = unpacker.run(
            [Unpacker.Source(archive: try bench.store.archive(at: archive, cancellation: nil))],
            into: hooked.base.url("/target")
        )
        // The members of that folder are refused, each with its line; the other one arrives.
        #expect(
            result.problems.count == 2 && result.problems.allSatisfy { $0.contains("not a folder") },
            "\(result.problems)"
        )
        #expect(hooked.base.contents("/target/dir") == "somebody else's")
        #expect(hooked.base.contents("/target/plain.txt") != nil)
        #expect(!hooked.base.allPaths.contains { $0.hasPrefix("/target/dir/") })
    }
}

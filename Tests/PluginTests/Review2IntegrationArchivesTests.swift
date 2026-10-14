import AFMKernel
@testable import ArchivesPlugin
import Foundation
import TestSupport
import Testing

// Review round 2, integration: the kernel calls that arrived after the archives pass was
// over, now used by the archives plugin — a commit that asks while it runs (F046), and
// folders that an unpacking by path makes for itself alone (L043).

/// A file system over memory with a moment to interfere right before a folder is made
/// exclusively. Every call is forwarded to `base`.
final class IntegrationHookedMemory: FileSystemProvider {
    let base = MemoryFileSystem(scheme: "hooked")
    var scheme: String { base.scheme }
    var capabilities: FileSystemCapabilities { base.capabilities }
    let readsRootedPaths = true
    var beforeMaking: ((URL) -> Void)?
    private let lock = NSLock()
    private var exclusive: [String] = []

    /// The folders that were made exclusively.
    var madeExclusively: [String] { lock.withLock { exclusive } }

    func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url) }
    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] { try base.list(directory, showHidden: showHidden) }
    func item(at url: URL) -> FileItem? { base.item(at: url) }
    func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    func read(_ url: URL) throws -> FileReader { try base.read(url) }
    func write(_ url: URL) throws -> FileWriter { try base.write(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws { try base.move(source, to: destination, replacing: replacing) }
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws { try base.copy(source, to: destination, progress: progress) }
    func setAttributes(_ attributes: FileAttributes, of url: URL) throws { try base.setAttributes(attributes, of: url) }
    func displayPath(_ url: URL) -> String { base.displayPath(url) }
    func location(from text: String) -> URL? { base.location(from: text) }
    func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func createDirectory(at url: URL, exclusive: Bool) throws {
        if exclusive {
            beforeMaking?(url)
            lock.withLock { self.exclusive.append(url.path) }
        }
        try base.createDirectory(at: url, exclusive: exclusive)
    }
    func createDirectory(at url: URL, exclusive: Bool, cancellation: CancellationFlag) throws {
        try createDirectory(at: url, exclusive: exclusive)
    }
}

@Suite struct Review2IntegrationArchives {
    let bench: ArchiveBench
    var box: Sandbox { bench.box }

    init() throws {
        bench = try ArchiveBench()
    }

    private func writeZip(_ name: String, members: [String]) throws -> URL {
        let url = box.url(name)
        let output = try OutputFile(creating: url)
        let writer = ZipWriter(output)
        for member in members {
            let record = ZipRecord.new(name: member, isDirectory: false, modified: Date(), permissions: 0o644)
            try writer.end(try writer.begin(record), record, headerChanged: false)
        }
        try writer.finish()
        try output.close()
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        let writer = try bench.fileSystems.provider(for: url).write(url)
        try writer.write(Data(text.utf8))
        try writer.close(attributes: FileAttributes())
    }

    // MARK: F046 — the commit of an archive asks between its members

    @Test func theCommitOfAnArchiveAsksBetweenTheMembersItWrites() throws {
        let url = try writeZip("commit.zip", members: (0..<40).map { "old-\($0).txt" })
        for number in 0..<20 { try write("new \(number)", to: bench.inside(url, "new-\(number).txt")) }
        // (A member that was there is given another name, so the file is written anew.)
        try bench.zip.remove(bench.inside(url, "old-0.txt"))
        var asked: [(done: Int64, total: Int64)] = []
        try bench.zip.commit(bench.inside(url), cancellation: CancellationFlag()) { done, total in
            asked.append((done, total))
            return true
        }
        // Once before every member that is written, with figures that only grow.
        #expect(asked.count >= 59, "\(asked.count)")
        #expect(zip(asked, asked.dropFirst()).allSatisfy { $0.done <= $1.done })
        #expect(asked.allSatisfy { $0.total > 0 })
        let names = Set(try ZipDirectory.read(RandomAccessFile(url)).records.map(\.name))
        #expect(names.count == 59 && names.contains("new-19.txt") && !names.contains("old-0.txt"))
    }

    @Test func aCommitThatIsEndedWhileItRunsHasChangedNothingAndCanBeMadeAgain() throws {
        let url = try writeZip("stopped.zip", members: (0..<30).map { "old-\($0).txt" })
        for number in 0..<10 { try write("new \(number)", to: bench.inside(url, "new-\(number).txt")) }
        let before = try Data(contentsOf: url)
        var asked = 0
        #expect(throws: CocoaError.self) {
            try bench.zip.commit(bench.inside(url), cancellation: CancellationFlag()) { _, _ in
                asked += 1
                return asked < 5
            }
        }
        #expect(asked == 5)
        // The file is the one it was; what waited still waits and is still shown.
        #expect(try Data(contentsOf: url) == before)
        #expect(try bench.zip.list(bench.inside(url), showHidden: true).count == 40)
        try bench.zip.commit(bench.inside(url), cancellation: CancellationFlag()) { _, _ in true }
        #expect(try ZipDirectory.read(RandomAccessFile(url)).records.count == 40)
        // Nothing of the attempt that was ended is left next to the archive.
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.path).filter { $0.contains(".afm-zip") }.isEmpty)
    }

    // MARK: A wrong password for the old encryption is a wrong password

    /// The old ZIP encryption proves a password with one byte: one wrong password in 256 passes.
    /// The member then decrypts to noise, and the user was told the archive is damaged
    /// (`encryptedZipsAskForThePassword` failed that way once in the final runs: it gives three
    /// wrong answers and expects "wrong password"). Many wrong passwords here, so that some
    /// pass the byte: none may be reported as damage, and none may open anything.
    @Test func noWrongPasswordForTheOldEncryptionIsTakenForADamagedArchive() throws {
        let tree = try bench.makeTree()
        let own = box.url("own.zip")
        try bench.pack([tree], to: own) { $0.password = "open sesame"; $0.encryption = .legacy }
        var damaged: [String] = []
        var opened: [String] = []
        for number in 0..<1_500 {
            let fresh = try ArchiveBench()
            let candidate = "wrong-\(number)"
            fresh.passwords.set([candidate])
            do {
                _ = try fresh.read(fresh.inside(own, "tree/readme.txt"))
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
        #expect(try fresh.read(fresh.inside(own, "tree/readme.txt")) == Data(contentsOf: tree.appendingPathComponent("readme.txt")))
    }

    // MARK: L043 — by path (a target that is not a disk of this machine), folders are made exclusively

    @Test func foldersOfATargetThatIsNotALocalDiskAreMadeForThisUnpackingAlone() throws {
        let hooked = IntegrationHookedMemory()
        bench.fileSystems.register(hooked)
        hooked.base.addFile("/target/there/kept.txt", "kept")
        let archive = try writeZip("tree.zip", members: ["there/a.txt", "new/deep/b.txt", "new/c.txt", "top.txt"])
        let unpacker = Unpacker(fileSystems: bench.fileSystems, monitor: bench.monitor, options: UnpackOptions()) { _, _ in .overwrite }
        let result = unpacker.run([Unpacker.Source(archive: try bench.store.archive(at: archive))], into: hooked.base.url("/target"))
        #expect(result.problems.isEmpty, "\(result.problems)")
        #expect(Set(hooked.base.allPaths.filter { $0.hasPrefix("/target/") && !$0.contains(".afm-") })
            .isSuperset(of: ["/target/there/a.txt", "/target/there/kept.txt", "/target/new/deep/b.txt", "/target/new/c.txt", "/target/top.txt"]))
        // The folder that was there is used as it is; the two that were not are made exclusively, once each.
        #expect(hooked.madeExclusively.sorted() == ["/target/new", "/target/new/deep"])
    }

    @Test func whatAppearsUnderAFoldersNameBeforeItIsMadeIsNotWrittenThrough() throws {
        let hooked = IntegrationHookedMemory()
        bench.fileSystems.register(hooked)
        hooked.base.addDirectory("/target")
        // Between the look ("nothing there") and the making of the folder, something else takes the name.
        hooked.beforeMaking = { [base = hooked.base] url in
            if url.lastPathComponent == "dir" { base.addFile("/target/dir", "somebody else's") }
        }
        let archive = try writeZip("planted.zip", members: ["dir/a.txt", "dir/b.txt", "plain.txt"])
        let unpacker = Unpacker(fileSystems: bench.fileSystems, monitor: bench.monitor, options: UnpackOptions()) { _, _ in .overwrite }
        let result = unpacker.run([Unpacker.Source(archive: try bench.store.archive(at: archive))], into: hooked.base.url("/target"))
        // The members of that folder are refused, each with its line; the other one arrives.
        #expect(result.problems.count == 2 && result.problems.allSatisfy { $0.contains("not a folder") }, "\(result.problems)")
        #expect(hooked.base.contents("/target/dir") == "somebody else's")
        #expect(hooked.base.contents("/target/plain.txt") != nil)
        #expect(hooked.base.allPaths.filter { $0.hasPrefix("/target/dir/") }.isEmpty)
    }
}

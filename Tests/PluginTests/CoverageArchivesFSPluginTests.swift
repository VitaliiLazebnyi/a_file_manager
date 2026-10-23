import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The plugin started in a kernel: the password questions, the reports and refreshes of the
/// delayed writes, the eject, and what quitting and the shell's hooks do with changes that
/// cannot be written.
@MainActor
@Suite
internal struct CoverageArchivesFSPluginTests {
    /// A clock for the delayed writes that the test turns by hand.
    ///
    /// Unchecked: what is due is guarded by `lock`.
    private final class HandClock: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [@Sendable () -> Void] = []

        func schedule(_ work: @escaping @Sendable () -> Void) {
            lock.withLock { waiting.append(work) }
        }

        /// What was scheduled since the last call, in order.
        func take() -> [@Sendable () -> Void] {
            lock.withLock {
                defer { waiting = [] }
                return waiting
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    private let box: Sandbox
    private let archives = ArchivesPlugin(flushDelay: 0, launchesApplications: false)
    private let bench: TestBench
    private let clock = HandClock()

    private var interaction: ScriptedInteraction { bench.interaction }

    /// A folder with a ZIP in the left panel, and the plugin started with a clock the test turns.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/tree/readme.txt", "read me")
        try box.file("A/tree/notes.txt", "notes")
        try box.folder("B")
        #expect(runTool("/usr/bin/zip", ["-qr", "tree.zip", "tree"], in: box.url("A")).status == 0)
        bench = TestBench(
            plugins: [archives],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        let handClock = clock
        archives.environment.schedule = { _, _, work in handClock.schedule(work) }
        archives.environment.immediateWriteLimit = 0
        archives.environment.recoveryFolder = box.url("recovery")
    }

    private func inside(_ archive: String, _ path: String = "") -> URL {
        ArchiveURL.make(scheme: ArchiveURL.writableScheme, archive: box.url(archive), innerPath: path)
    }

    private func write(_ text: String, to url: URL) throws {
        let writer = try bench.kernel.fileSystems.provider(for: url).write(url)
        try writer.write(Data(text.utf8))
        try writer.close(attributes: FileAttributes())
    }

    private func listed(_ archive: String) -> [String] {
        runTool("/usr/bin/unzip", ["-Z1", box.url(archive).path]).output.split(separator: "\n").map(String.init)
    }

    /// A copy of the test archive in a folder of its own, which the test can make read-only.
    private func lockable(_ folder: String) throws -> String {
        try box.folder(folder)
        try FileManager.default.copyItem(at: box.url("A/tree.zip"), to: box.url("\(folder)/tree.zip"))
        return "\(folder)/tree.zip"
    }

    /// Lets the main actor run until `done` holds: what other threads hand to the main queue arrives.
    private func waitOnMain(until done: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: Wait.ceiling)
        while !done(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return done()
    }

    /// The password of an encrypted member is asked for with the kernel's forms: a wrong one
    /// is asked for again, an empty answer gives up, the right one reads the member.
    @Test
    internal func anEncryptedMemberAsksForItsPasswordThroughTheKernel() throws {
        try box.file("A/secret.txt", "the secret text")
        #expect(
            runTool("/usr/bin/zip", ["-q", "-P", "secret", "locked.zip", "secret.txt"], in: box.url("A")).status == 0
        )
        archives.environment.passwordRefusalMemory = 0
        let member = inside("A/locked.zip", "secret.txt")
        let provider = try bench.kernel.fileSystems.provider(for: member)
        interaction.formAnswers = [.values(["password": .text("wrong")]), .values(["password": .text("")])]
        #expect(throws: ArchiveError.self) { _ = try provider.read(member) }
        #expect(interaction.log == ["form: Password", "form: Wrong password"])
        interaction.formAnswers = [.values(["password": .text("secret")])]
        let reader = try provider.read(member)
        defer { reader.close() }
        #expect(try reader.read(upToCount: 100) == Data("the secret text".utf8))
    }

    /// A delayed write that fails is reported once, whether the clock fires on the main
    /// thread or on another.
    @Test
    internal func aDelayedWriteThatFailsIsReported() async throws {
        let first = try lockable("L1")
        let second = try lockable("L2")
        try write("kept back", to: inside(first, "tree/added.txt"))
        let onMain = clock.take()
        try write("kept back", to: inside(second, "tree/added.txt"))
        let elsewhere = clock.take()
        #expect(!onMain.isEmpty && !elsewhere.isEmpty)
        for folder in ["L1", "L2"] {
            #expect(chmod(box.url(folder).path, 0o555) == 0)
        }
        defer {
            for folder in ["L1", "L2"] {
                chmod(box.url(folder).path, 0o755)
            }
        }
        onMain[0]()
        #expect(interaction.log.contains("inform: The changes to tree.zip could not be written!"))
        let reported = interaction.log.count
        let fired = elsewhere[0]
        Thread.detachNewThread { fired() }
        #expect(await waitOnMain { interaction.log.count > reported })
        #expect(interaction.log.last == "inform: The changes to tree.zip could not be written!")
        #expect(archives.hasPendingChanges)
    }

    /// After a delayed write, the panel that shows the folder of the archive shows its new size.
    @Test
    internal func aDelayedWriteRefreshesThePanelsThatShowTheArchive() async throws {
        let size = { bench.left.model.items.first { $0.name == "tree.zip" }?.size }
        let before = size()
        try write(String(repeating: "more ", count: 1_000), to: inside("A/tree.zip", "tree/added.txt"))
        clock.take().first?()
        #expect(listed("A/tree.zip").contains("tree/added.txt") && !archives.hasPendingChanges)
        #expect(await waitOnMain { size() != before })
    }

    /// Ejecting a volume lets go of the archives that lie on it.
    @Test
    internal func ejectingAVolumeLetsGoOfTheArchivesOnIt() throws {
        _ = try archives.store.archive(at: box.url("A/tree.zip"), cancellation: nil)
        #expect(archives.store.openArchive(at: box.url("A/tree.zip")) != nil)
        try bench.kernel.fileSystems.closeFiles(on: box.url("A"), cancellation: CancellationFlag())
        #expect(archives.store.openArchive(at: box.url("A/tree.zip")) == nil)
    }

    /// Changes that cannot be written when the program quits are reported; new members are
    /// saved in an archive of their own, renames and deletions have nothing to save.
    @Test
    internal func quittingSavesWhatCanBeSavedAndReportsTheRest() throws {
        let added = try lockable("L1")
        let removed = try lockable("L2")
        try write("added", to: inside(added, "tree/added.txt"))
        try bench.kernel.fileSystems.provider(for: inside(removed)).remove(inside(removed, "tree/notes.txt"))
        for folder in ["L1", "L2"] {
            #expect(chmod(box.url(folder).path, 0o555) == 0)
        }
        defer {
            for folder in ["L1", "L2"] {
                chmod(box.url(folder).path, 0o755)
            }
        }
        archives.stop()
        #expect(interaction.log.filter { $0 == "inform: The changes to tree.zip could not be written!" }.count == 2)
        let saved = box.url("recovery/tree (unsaved changes).zip")
        #expect(runTool("/usr/bin/unzip", ["-Z1", saved.path]).output.contains("tree/added.txt"))
        #expect(listed(added).contains("tree/added.txt") == false && listed(removed).contains("tree/notes.txt"))
    }

    /// The shell's hook writes what waits and hands the failures to the main thread, one line
    /// per archive; so does the direct write.
    @Test
    internal func thePendingChangesAreWrittenOnRequestAndFailuresListed() async throws {
        let archive = try lockable("L1")
        try write("kept back", to: inside(archive, "tree/added.txt"))
        #expect(chmod(box.url("L1").path, 0o555) == 0)
        defer { chmod(box.url("L1").path, 0o755) }
        let failures = Shared<[[String]]>([])
        archives.writePendingChanges(cancellation: CancellationFlag()) { lines in failures.modify { $0.append(lines) } }
        #expect(await waitOnMain { !failures.value.isEmpty })
        #expect(failures.value.count == 1 && failures.value.first?.count == 1)
        #expect(failures.value.first?.first?.hasPrefix("tree.zip: ") == true)
        #expect(archives.flushPendingChanges().first?.hasPrefix("tree.zip: ") == true)
    }

    /// The location Enter opens an archive at: the writable scheme for a ZIP on the disk, the
    /// read-only one for other formats.
    @Test
    internal func theLocationOfAnArchiveIsTheOneEnterOpens() {
        let kernel = bench.kernel
        #expect(archives.location(ofArchive: box.url("A/tree.zip"), in: kernel) == inside("A/tree.zip"))
        #expect(archives.location(ofArchive: box.url("A/tree.tgz"), in: kernel).scheme == ArchiveURL.readOnlyScheme)
    }
}

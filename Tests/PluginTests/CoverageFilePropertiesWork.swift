import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// The work of file properties beyond the other suites: attribute changes that are cancelled,
/// refused or cannot be worked out, and comment files that are read or written while a job is
/// cancelled or a file system fails.
@Suite
internal struct CoverageFilePropertiesWork {
    /// The files in memory: `/T` with two files and a folder.
    private let memory = MemoryFileSystem()
    /// The memory files behind a layer that fails what a test names.
    private let files: CoverageSmallFiles
    /// The local file system and the layer.
    private let fileSystems = FileSystemRegistry()

    /// A change of permissions and of the folders' contents.
    private var recursive: AttributeChange {
        AttributeChange(permissions: .absolute(0o600, keepingSpecialBits: false), recurse: true)
    }

    /// The files and the registry.
    internal init() {
        memory.addFile("/T/a.txt", "a", modified: Date(timeIntervalSince1970: 1_612_051_200))
        memory.addFile("/T/b.txt", "b")
        memory.addFile("/T/sub/c.txt", "c")
        files = CoverageSmallFiles(memory)
        fileSystems.register(LocalFileSystem())
        fileSystems.register(files)
    }

    /// The item of a memory path.
    private func item(_ path: String) throws -> FileItem {
        try #require(memory.item(at: memory.url(path)))
    }

    /// An owner by name is looked up once and set; a group that does not exist fails every item.
    @Test
    internal func ownersAndGroupsByName() throws {
        let box = try Sandbox()
        try box.file("mine.txt")
        let mine = try #require(fileSystems.item(at: box.url("mine.txt")))
        let owned = AttributeJob(change: AttributeChange(owner: NSUserName()), fileSystems: fileSystems).run([mine])
        #expect(owned.changed == 1 && owned.failed == 0)
        let grouped = AttributeJob(change: AttributeChange(group: "afm-no-such-group"), fileSystems: fileSystems)
            .run([mine, mine])
        #expect(grouped.failed == 2 && grouped.failures == ["There is no group called afm-no-such-group."])
    }

    /// A job cancelled before it starts changes nothing; one cancelled while it works stops,
    /// and what failed because of the cancel is no failure.
    @Test
    internal func cancelledJobsStop() throws {
        let flag = CancellationFlag()
        flag.cancel()
        let early = AttributeJob(change: recursive, fileSystems: fileSystems, cancellation: flag).run([try item("/T")])
        #expect(early.changed == 0 && early.cancelled)
        let stopping = CancellationFlag()
        files.onCall = { call in if call == .setAttributes { stopping.cancel() } }
        let stopped = AttributeJob(change: recursive, fileSystems: fileSystems, cancellation: stopping)
            .run([try item("/T")])
        #expect(stopped.changed == 1 && stopped.failed == 0 && stopped.cancelled)
        let failing = CancellationFlag()
        files.onCall = nil
        files.fails = [.setAttributes]
        files.onFailure = { _ in failing.cancel() }
        let failed = AttributeJob(change: recursive, fileSystems: fileSystems, cancellation: failing)
            .run([try item("/T/a.txt")])
        #expect(failed.failed == 0 && failed.cancelled)
    }

    /// A folder that cannot be listed is changed first and then left; a cancel while it is
    /// changed stops the job there.
    @Test
    internal func foldersThatCannotBeListed() throws {
        memory.unreadable = ["/T"]
        let left = AttributeJob(change: recursive, fileSystems: fileSystems).run([try item("/T")])
        #expect(left.changed == 1 && files.changedAttributes == ["/T"])
        let stopping = CancellationFlag()
        files.onCall = { call in if call == .setAttributes { stopping.cancel() } }
        let stopped = AttributeJob(change: recursive, fileSystems: fileSystems, cancellation: stopping)
            .run([try item("/T")])
        #expect(stopped.changed == 1 && stopped.cancelled)
    }

    /// A change that starts from what an item has now takes the listed item when it cannot be
    /// asked again, and stops when the job is cancelled meanwhile; a date that does not exist
    /// fails; a date that changes nothing is no change of the date.
    @Test
    internal func changesThatStartFromTheItem() throws {
        let relative = try #require(PermissionChange("u+x"))
        files.fails = [.item]
        let listed = AttributeJob(change: AttributeChange(permissions: relative), fileSystems: fileSystems)
            .run([try item("/T/b.txt")])
        #expect(listed.changed == 1)
        files.fails = []
        let stopping = CancellationFlag()
        files.onCall = { call in if call == .item { stopping.cancel() } }
        let stopped = AttributeJob(
            change: AttributeChange(permissions: relative),
            fileSystems: fileSystems,
            cancellation: stopping
        )
        .run([try item("/T/b.txt")])
        #expect(stopped.changed == 0 && stopped.failed == 0 && stopped.cancelled)
        files.onCall = nil
        // 31 January with the month made February: there is no such day.
        let february = try #require(TimestampChange(date: "yyyy-02-dd", time: ""))
        var change = AttributeChange(timestamp: february)
        let impossible = AttributeJob(change: change, fileSystems: fileSystems).run([try item("/T/a.txt")])
        #expect(
            impossible.failed == 1 && impossible.failures.first?.hasSuffix("does not exist in the calendar.") == true
        )
        change.timestamp = TimestampChange(date: "", time: "")
        change.permissions = .absolute(0o640, keepingSpecialBits: false)
        #expect(AttributeJob(change: change, fileSystems: fileSystems).run([try item("/T/a.txt")]).changed == 1)
    }

    /// The comment store keeps a limited memory, and a reader can be told how long to wait.
    @Test
    internal func theCommentStoreForgetsWhatIsTooMuch() {
        let store = CommentStore(fileSystems: fileSystems)
        store.waitLimit = 0.5
        #expect(store.waitLimit == 0.5)
        for index in 0...257 { _ = store.comments(in: memory.url("/many/\(index)")) }
        for index in 0...4_097 { store.forget(memory.url("/many/\(index)")) }
        memory.addFile("/T/descript.ion", "a.txt first\r\n")
        #expect(store.comments(in: memory.url("/T")) == ["a.txt": "first"])
    }

    /// A comment file is not taken from a reading the job's cancel cut short, nor when it is
    /// too large to be one.
    @Test
    internal func readingsCutShortOrTooLarge() {
        let store = CommentStore(fileSystems: fileSystems)
        memory.addFile("/T/descript.ion", "a.txt first\r\n")
        let flag = CancellationFlag()
        files.onCall = { call in if call == .read { flag.cancel() } }
        #expect(store.load(memory.url("/T"), cancellation: flag).isEmpty)
        files.onCall = nil
        memory.addFile("/T/sub/descript.ion", String(repeating: "x", count: 16 * 1_024 * 1_024 + 1))
        #expect(store.load(memory.url("/T/sub")).isEmpty)
    }

    /// For a change, a comment file that cannot be read whole is not used, and a cancel says so.
    @Test
    internal func commentFilesForAChange() throws {
        let store = CommentStore(fileSystems: fileSystems)
        memory.addFile("/T/descript.ion", "a.txt first\r\n")
        files.fails = [.read]
        #expect(throws: CommentFileError.self) { try store.loadForUpdate(memory.url("/T")) }
        let failing = CancellationFlag()
        files.onFailure = { _ in failing.cancel() }
        #expect(throws: CocoaError.self) { try store.loadForUpdate(memory.url("/T"), cancellation: failing) }
        files.fails = []
        files.onFailure = nil
        let reading = CancellationFlag()
        files.onCall = { call in if call == .read { reading.cancel() } }
        #expect(throws: CocoaError.self) { try store.loadForUpdate(memory.url("/T"), cancellation: reading) }
    }

    /// A comment that cannot be written leaves the old file; a cancel just before writing
    /// writes nothing.
    @Test
    internal func commentsThatCannotBeWritten() throws {
        let store = CommentStore(fileSystems: fileSystems)
        memory.addFile("/T/descript.ion", "a.txt first\r\n")
        files.fails = [.write]
        #expect(throws: CoverageSmallFiles.Failure.self) {
            try store.setComment("second", for: "b.txt", in: memory.url("/T"), hidden: false)
        }
        files.fails = []
        let flag = CancellationFlag()
        files.onCall = { call in if call == .item { flag.cancel() } }
        #expect(throws: CocoaError.self) {
            try store.setComment("second", for: "b.txt", in: memory.url("/T"), hidden: false, cancellation: flag)
        }
        #expect(memory.contents("/T/descript.ion") == "a.txt first\r\n")
        #expect(!memory.allPaths.contains { $0.hasSuffix(".tmp") })
    }

    /// A local file that has gone is measured by its listed size; a folder whose listing fails
    /// because of the cancel counts nothing.
    @Test
    internal func measuringWhatHasGoneOrWasCancelled() throws {
        let box = try Sandbox()
        try box.file("gone.txt", "12345")
        let gone = try #require(fileSystems.item(at: box.url("gone.txt")))
        try FileManager.default.removeItem(at: box.url("gone.txt"))
        let measured = SpaceCalculator(fileSystems: fileSystems).measure([gone])
        #expect(measured.first?.allocated == 5)
        let flag = CancellationFlag()
        files.fails = [.list]
        files.onFailure = { _ in flag.cancel() }
        #expect(
            SpaceCalculator(fileSystems: fileSystems, cancellation: flag).measure(directory: memory.url("/T"))
                == SpaceTotals()
        )
    }
}

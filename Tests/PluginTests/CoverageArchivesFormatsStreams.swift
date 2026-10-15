import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The streams under the archive formats: files read at any position, files written front to
/// back, the requests that end a read.
@Suite
internal struct CoverageArchivesFormatsStreams {
    private typealias Support = CoverageArchivesFormatsSupport

    private let box: Sandbox

    /// A new folder for each test.
    internal init() throws {
        box = try Sandbox()
    }

    // MARK: Reading

    /// The stream that skips by reading reports a skip past its end as damage.
    @Test
    internal func skippingPastTheEndOfAStreamIsDamage() {
        let stream = DataStream(Data([1, 2, 3]))
        #expect(
            Support.failure { try stream.skip(5) } == ArchiveError.damaged("unexpected end of data").errorDescription
        )
    }

    /// A stream in memory goes on at the position it is sent to, and past its end there is nothing.
    @Test
    internal func aDataStreamContinuesWhereItIsSent() {
        let stream = DataStream(Data([1, 2, 3, 4]))
        #expect(stream.read(upToCount: 2) == Data([1, 2]))
        stream.seek(to: 1)
        #expect(stream.read(upToCount: 10) == Data([2, 3, 4]))
        stream.seek(to: 99)
        #expect(stream.read(upToCount: 10) == nil)
    }

    /// A file that is not there says so, with its path.
    @Test
    internal func aMissingFileCannotBeOpened() {
        let missing = box.url("missing.bin")
        #expect(Support.failure { _ = try RandomAccessFile(missing) } == Support.systemError(ENOENT, missing.path))
    }

    /// A read of more than the memory holds fails with an error instead of a crash.
    @Test
    internal func aReadLargerThanTheMemoryFailsWithoutACrash() throws {
        // A file with a hole of a petabyte: nothing of it is on the disk, but a read of all of
        // it asks for more memory than there is.
        let url = box.url("hole.bin")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1 << 50)
        try handle.close()
        let file = try RandomAccessFile(url)
        #expect(Support.failure { _ = try file.read(at: 0, count: .max) } == Support.systemError(ENOMEM, url.path))
        // A part of it reads as zeros.
        #expect(try file.read(at: 1 << 40, count: 4) == Data(count: 4))
    }

    /// A folder opened as a file has a size but no contents to read.
    @Test
    internal func aFolderOpenedAsAFileCannotBeRead() throws {
        let folder = try box.folder("folder")
        try box.file("folder/inside.txt")
        let file = try RandomAccessFile(folder)
        #expect(file.size > 0)
        #expect(Support.failure { _ = try file.read(at: 0, count: 10) } == Support.systemError(EISDIR, folder.path))
    }

    /// A file that becomes shorter after it was opened ends where it ends now.
    @Test
    internal func aFileThatShrankAfterItWasOpenedEndsEarly() throws {
        let url = try box.file("shrinks.txt", "0123456789")
        let file = try RandomAccessFile(url)
        let stream = FileRangeStream(file)
        #expect(try stream.read(upToCount: 4) == Data("0123".utf8))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.close()
        #expect(file.size == 10)
        #expect(try file.read(at: 0, count: 10).isEmpty)
        #expect(try stream.read(upToCount: 4) == nil)
    }

    /// Numbers read past the end of a block are zero, and the reader stays at the end.
    @Test
    internal func numbersReadPastTheEndAreZero() {
        var reader = ByteReader(Data([0x34, 0x12, 0x78]))
        #expect(reader.u16() == 0x1234)
        #expect(reader.u16() == 0x78)
        #expect(reader.remaining == 0 && reader.u32() == 0 && reader.bytes(4).isEmpty)
    }

    // MARK: Requests to stop

    /// A request runs each handler once, and a handler that comes after it at once.
    @Test
    internal func aRequestRunsEachHandlerOnceAndLateOnesAtOnce() {
        let interrupt = StreamInterrupt()
        let counter = SharedCounter()
        interrupt.onSet { counter.add(1) }
        interrupt.set()
        interrupt.set()
        #expect(counter.value == 1 && interrupt.isSet)
        interrupt.onSet { counter.add(10) }
        #expect(counter.value == 11)
        #expect(Support.failure { try interrupt.check() } == ArchiveError.cancelled.errorDescription)
    }

    /// A request follows a cancellation for as long as the tie is held; without a flag there is none.
    @Test
    internal func aRequestFollowsACancellationWhileTheTieIsHeld() {
        let interrupt = StreamInterrupt()
        let flag = CancellationFlag()
        let tie = interrupt.following(flag)
        #expect(!interrupt.isSet)
        withExtendedLifetime(tie) { flag.cancel() }
        #expect(interrupt.isSet)
        #expect(StreamInterrupt().following(nil) == nil)
    }

    // MARK: Copies kept on the side

    /// A copy is given up, and its room freed, when it would pass its limit or the volume fills.
    @Test
    internal func aCopyIsGivenUpAtItsLimitOrWhenTheRoomRunsOut() throws {
        let data = Data(repeating: 7, count: 100)
        let small = try OutputFile(creating: box.url("small.copy"))
        let tooSmall = TeeStream(DataStream(data), to: small, limit: 50)
        #expect(try tooSmall.readFully(100) == data)
        #expect(!tooSmall.isComplete && small.position == 0)
        try small.close()
        #expect(try Data(contentsOf: box.url("small.copy")).isEmpty)

        let full = try OutputFile(creating: box.url("full.copy"))
        let watch = SpaceWatch(folder: box.root, reserve: 0, step: 10) { _, _ in false }
        let noRoom = TeeStream(DataStream(data), to: full, limit: .max, room: watch)
        #expect(try noRoom.readFully(100) == data)
        #expect(!noRoom.isComplete)
        // Once full, the watch does not look again.
        #expect(!watch.allows(1))
        try full.close()
    }

    /// A copy the disk refuses is given up while the data still goes through.
    @Test
    internal func aCopyIsGivenUpWhenTheDiskRefusesIt() throws {
        // A file that stands at the largest size its volume allows takes no further byte.
        let url = try box.file("at-the-end.copy", "")
        let output = try OutputFile(extending: url, from: UInt64(Support.largestFileSize(in: box.root)))
        let block = Data(repeating: 1, count: 1 << 16)
        let tee = TeeStream(DataStream(block), to: output, limit: .max)
        #expect(try tee.read(upToCount: 1 << 16) == block)
        #expect(!tee.isComplete)
        try output.close()
    }

    // MARK: Writing

    /// A new file is made only where nothing is yet.
    @Test
    internal func aNewFileMustNotExistYet() throws {
        let url = try box.file("there.txt")
        #expect(
            Support.failure { _ = try OutputFile(creating: url) }
                == FileSystemError.alreadyExists(url.path).errorDescription
        )
        let nowhere = box.url("no/such/folder.txt")
        #expect(Support.failure { _ = try OutputFile(creating: nowhere) } == Support.systemError(ENOENT, nowhere.path))
    }

    /// Only an existing plain file is continued, and only at an offset a file can have.
    @Test
    internal func onlyAnExistingPlainFileCanBeContinued() throws {
        let missing = box.url("missing.txt")
        #expect(
            Support.failure { _ = try OutputFile(extending: missing, from: 0) }
                == Support.systemError(ENOENT, missing.path)
        )
        let device = URL(fileURLWithPath: "/dev/null")
        #expect(
            Support.failure { _ = try OutputFile(extending: device, from: 0) }
                == Support.systemError(EINVAL, device.path)
        )
        let file = try box.file("plain.txt", "abc")
        #expect(Support.failure { _ = try OutputFile(extending: file, from: .max) } != nil)
        #expect(
            Support.failure { _ = try OutputFile(extending: file, from: UInt64(Int64.max)) }
                == Support.systemError(EFBIG, file.path)
        )
        #expect(try Data(contentsOf: file) == Data("abc".utf8))
    }

    /// A write the disk refuses fails with the disk's reason; closing twice does nothing more.
    @Test
    internal func aWriteTheDiskRefusesFails() throws {
        let url = box.url("refused.bin")
        let output = try OutputFile(creating: url)
        try output.write(Data("head".utf8))
        #expect(
            Support.failure { try output.rewrite(Data("x".utf8), at: UInt64(Int64.max - 1)) }
                == Support.systemError(EFBIG, url.path)
        )
        try output.close()
        try output.close(durably: true)
        #expect(try Data(contentsOf: url) == Data("head".utf8))
    }

    /// A descriptor that knows no barrier is synced plainly, and one that is no descriptor not at all.
    @Test
    internal func aDescriptorThatKnowsNoBarrierIsSyncedPlainly() {
        let device = open("/dev/null", O_WRONLY)
        defer { close(device) }
        #expect(Durable.sync(device))
        #expect(!Durable.sync(-1))
    }

    /// A path that leads nowhere is taken as it is, and has no folder to make durable.
    @Test
    internal func aPathThatLeadsNowhereIsTakenAsItIs() {
        let missing = box.url("no/such/file.zip")
        #expect(Durable.realFile(missing) == missing)
        Durable.syncFolder(of: missing)
        #expect(!box.exists("no"))
    }
}

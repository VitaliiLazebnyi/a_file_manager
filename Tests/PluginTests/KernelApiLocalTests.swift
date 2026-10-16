import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// The calls the provider interface gained, as the local disks answer them.
@Suite struct KernelApiOnLocalDisks {
    let local = LocalFileSystem()

    private func status(_ url: URL) -> stat {
        var st = stat()
        lstat(url.path, &st)
        return st
    }

    private func attribute(_ name: String, of url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var value = Data(count: size)
        let got = value.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return got >= 0 ? value.prefix(got) : nil
    }

    private func setAttribute(_ name: String, _ value: Data, of url: URL) -> Bool {
        value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) } == 0
    }

    private func setCreated(_ date: Date, of url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.creationDate = date
        try url.setResourceValues(values)
    }

    // MARK: Cancellation

    @Test func aCancelledListingStopsBeforeTheNextBuffer() throws {
        let box = try Sandbox()
        // More names than one buffer holds, so the listing comes in several pieces.
        let count = 9_000
        for index in 0..<count {
            let descriptor = open(
                box.url("a-rather-long-name-to-fill-the-buffer-sooner-\(index).dat").path,
                O_WRONLY | O_CREAT,
                0o644
            )
            #expect(descriptor >= 0)
            close(descriptor)
        }
        var (pieces, whole) = (0, 0)
        try local.list(box.root, showHidden: true, cancellation: CancellationFlag()) {
            whole += $0.count
            pieces += 1
            return true
        }
        #expect(whole == count && pieces > 1)
        let flag = CancellationFlag()
        var received = 0
        try local.list(box.root, showHidden: true, cancellation: flag) { batch in
            received += batch.count
            flag.cancel()
            return true
        }
        #expect(received > 0 && received < count)
        // Set before the start, nothing is read; without a flag everything is, as ever.
        #expect(try local.list(box.root, showHidden: true, cancellation: flag).isEmpty)
        #expect(try local.list(box.root, showHidden: true).count == count)
        #expect(local.totalSize(of: box.root, cancellation: flag) == 0)
    }

    // MARK: Continuing a file

    @Test func aFileIsContinuedInPlace() throws {
        let box = try Sandbox()
        let file = try box.file("part.bin", "0123456789")
        #expect(
            local.capabilities.contains(.append) && local.capabilities(for: file).contains([.write, .trash, .append])
        )
        let inode = status(file).st_ino
        // Resume: cut to what is known to be good, and go on from there.
        let resumed = try local.append(to: file, at: 4, cancellation: CancellationFlag())
        #expect(box.read("part.bin") == "0123")
        try resumed.write(Data("ab".utf8))
        try resumed.write(Data("cd".utf8))
        try resumed.close(
            attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_000_000), permissions: 0o600)
        )
        #expect(box.read("part.bin") == "0123abcd" && status(file).st_ino == inode)
        #expect(
            local.item(at: file)?.modified == Date(timeIntervalSince1970: 1_000_000)
                && local.item(at: file)?.permissions == 0o600
        )
        // At its full length nothing is cut; Append goes on at the end, whatever that is.
        try local.append(to: file, at: 8, cancellation: CancellationFlag()).close(attributes: FileAttributes())
        #expect(box.read("part.bin") == "0123abcd")
        let appended = try local.append(to: file, at: nil, cancellation: CancellationFlag())
        try appended.write(Data("!".utf8))
        try appended.close(attributes: FileAttributes())
        #expect(box.read("part.bin") == "0123abcd!" && status(file).st_ino == inode)
        // A file shorter than what should be kept, no file, a folder: nothing is touched.
        #expect(throws: (any Error).self) { try local.append(to: file, at: 10, cancellation: CancellationFlag()) }
        #expect(throws: (any Error).self) { try local.append(to: file, at: -1, cancellation: CancellationFlag()) }
        #expect(throws: (any Error).self) {
            try local.append(to: box.url("none.bin"), at: 0, cancellation: CancellationFlag())
        }
        #expect(throws: (any Error).self) { try local.append(to: box.root, at: nil, cancellation: CancellationFlag()) }
        #expect(box.read("part.bin") == "0123abcd!" && !box.exists("none.bin"))
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: CocoaError.self) { try local.append(to: file, at: 0, cancellation: flag) }
        #expect(box.read("part.bin") == "0123abcd!")
    }

    // MARK: Metadata

    @Test func aFoldersTagsHiddenFlagAndCreationDateSurvive() throws {
        let box = try Sandbox()
        let source = try box.folder("source")
        let copy = try box.folder("copy")
        let tags = try PropertyListSerialization.data(
            fromPropertyList: ["Red\n6", "Project"],
            format: .binary,
            options: 0
        )
        #expect(setAttribute("com.apple.metadata:_kMDItemUserTags", tags, of: source))
        #expect(setAttribute("user.note", Data("kept".utf8), of: source))
        #expect(setAttribute("user.stale", Data("old".utf8), of: copy))
        let created = Date(timeIntervalSince1970: 986_400_000)
        try setCreated(created, of: source)
        #expect(chflags(source.path, UInt32(UF_HIDDEN)) == 0)
        // What `setAttributes` has given the copy stays: this call carries the rest.
        try box.file("copy/inside.txt")
        try local.setAttributes(
            FileAttributes(modified: Date(timeIntervalSince1970: 1_500_000_000), permissions: 0o750),
            of: copy
        )
        try local.copyMetadata(from: source, to: copy)
        #expect(
            attribute("com.apple.metadata:_kMDItemUserTags", of: copy) == tags
                && attribute("user.note", of: copy) == Data("kept".utf8)
        )
        #expect(status(copy).st_flags & UInt32(UF_HIDDEN) != 0 && local.item(at: copy)?.isHidden == true)
        #expect(try copy.resourceValues(forKeys: [.creationDateKey]).creationDate == created)
        #expect(
            local.item(at: copy)?.modified == Date(timeIntervalSince1970: 1_500_000_000)
                && local.item(at: copy)?.permissions == 0o750
        )
        #expect(box.read("copy/inside.txt") == "x")
        // Files and links take it the same way; a link is not followed.
        let file = try box.file("a.txt")
        let other = try box.file("b.txt", "other")
        #expect(setAttribute("user.note", Data("file".utf8), of: file))
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: other)
        try local.copyMetadata(from: file, to: box.url("link"))
        #expect(attribute("user.note", of: other) == nil && box.read("b.txt") == "other")
        try local.copyMetadata(from: file, to: other)
        #expect(attribute("user.note", of: other) == Data("file".utf8) && box.read("b.txt") == "other")
        // From elsewhere, or to nothing: an error the caller may pass over.
        #expect(throws: FileSystemError.self) { try local.copyMetadata(from: URL(string: "mem:///x")!, to: copy) }
        #expect(throws: (any Error).self) { try local.copyMetadata(from: source, to: box.url("missing")) }
    }

    @Test func aLockComesLastAndTheCopyCanStillBeTakenAway() throws {
        let box = try Sandbox()
        // The folder is made under a temporary name, as a job does with a file: still unfinished.
        let source = try box.folder("locked")
        let copy = try box.folder(".afm-copy.tmp")
        defer { for name in ["locked", ".afm-copy.tmp", "renamed"] { chflags(box.url(name).path, 0) } }
        #expect(setAttribute("user.note", Data("kept".utf8), of: source))
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE | UF_HIDDEN)) == 0)
        // Called when the folder is filled, as it must be.
        try box.file(".afm-copy.tmp/inside.txt")
        try local.copyMetadata(from: source, to: copy)
        #expect(attribute("user.note", of: copy) == Data("kept".utf8))
        #expect(status(copy).st_flags & UInt32(UF_IMMUTABLE | UF_HIDDEN) == UInt32(UF_IMMUTABLE | UF_HIDDEN))
        // Locked like the source: nothing more goes in…
        #expect(open(box.url(".afm-copy.tmp/more.txt").path, O_WRONLY | O_CREAT, 0o644) < 0)
        // …but whoever made the copy can still rename it, as a job does with a temporary name.
        try local.move(copy, to: box.url("renamed"), replacing: false)
        #expect(
            status(box.url("renamed")).st_flags & UInt32(UF_IMMUTABLE) != 0 && box.read("renamed/inside.txt") == "x"
        )
    }

    // MARK: Quarantine

    @Test func theQuarantineMarkIsReadAndSet() throws {
        let box = try Sandbox()
        let marked = try box.file("download.zip")
        let plain = try box.file("out.txt")
        let folder = try box.folder("out")
        let mark = Data("0081;65f0a1b2;Safari;".utf8)
        #expect(local.quarantine(of: marked) == nil)
        #expect(setAttribute("com.apple.quarantine", mark, of: marked))
        #expect(
            local.quarantine(of: marked) == mark && local.quarantine(of: plain) == nil
                && local.quarantine(of: box.url("missing")) == nil
        )
        try local.setQuarantine(mark, of: plain)
        try local.setQuarantine(mark, of: folder)
        #expect(
            attribute("com.apple.quarantine", of: plain) == mark && local.quarantine(of: folder) == mark
                && box.read("out.txt") == "x"
        )
        #expect(throws: (any Error).self) { try local.setQuarantine(mark, of: box.url("missing")) }
    }

    // MARK: Free space

    @Test func aStaleFreeSpaceFigureIsAnsweredAtOnceAndCorrectedBehind() async throws {
        let box = try Sandbox()
        // The disk says what the test tells it to. (The real figures move by gigabytes while
        // other programs write, which no margin allows for.)
        let (plain, spare): (Int64, Int64) = (100 << 30, 7 << 30)
        var probes = LocalProbes()
        probes.freeSpace = { _ in (available: plain, important: plain + spare) }
        let local = LocalFileSystem(probes: probes)
        var info = statfs()
        #expect(statfs(box.root.path, &info) == 0)
        let mountPoint = withUnsafeBytes(of: &info.f_mntonname) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        func known() -> Int64? {
            local.spareLock.lock()
            defer { local.spareLock.unlock() }
            return local.spareSpace[mountPoint]?.bytes
        }
        // The first question waits for the figure the Finder shows, and remembers the difference.
        #expect(local.volume(of: box.root)?.freeBytes == plain + spare)
        #expect(known() == spare)

        final class Heard: @unchecked Sendable {
            let lock = NSLock()
            var roots: [URL] = []
        }
        let heard = Heard()
        let observer = NotificationCenter.default.addObserver(
            forName: FileSystemRegistry.volumeInfoDidChange,
            object: local,
            queue: nil
        ) { note in
            guard Thread.isMainThread, let root = note.userInfo?[FileSystemRegistry.volumeRootKey] as? URL else {
                return
            }
            heard.lock.lock()
            heard.roots.append(root)
            heard.lock.unlock()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        func wasHeard() -> Bool {
            heard.lock.lock()
            defer { heard.lock.unlock() }
            return heard.roots.contains { $0.path == mountPoint }
        }

        // A measurement that is old and, by now, a gigabyte and a half off.
        let wrong = spare + 3 << 29
        local.spareLock.withLock {
            local.spareSpace[mountPoint] = (
                wrong, DispatchTime.now().uptimeNanoseconds - 600_000_000_000, false, info.f_fsid
            )
        }
        // Answered from what is known, without waiting for the system…
        #expect(local.volume(of: box.root)?.freeBytes == plain + wrong)
        // …and put right behind the scenes, which is announced on the main thread.
        // (Waited for as a condition: the queues are busy while every test runs at once.)
        let patience = Date(timeIntervalSinceNow: Wait.ceiling)
        while !wasHeard(), Date() < patience { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(wasHeard())
        #expect(local.volume(of: box.root)?.freeBytes == plain + spare)
        #expect(known() == spare)
    }
}

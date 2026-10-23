import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// The virtual file system: what each of its locations can do, branch walks that are cancelled
/// or cross volumes, calls passed on to the real file systems, and picked views of same-named
/// files.
@Suite
internal struct VirtualFoldersAdoption {
    /// A memory file system, one of the two the virtual one reads.
    internal let memory = MemoryFileSystem()
    /// The real file systems: the local disk and `memory`.
    internal let registry = FileSystemRegistry()
    /// The virtual file system over `registry`.
    internal let virtual: VirtualFileSystem

    /// The virtual file system over the local disk and `memory`.
    internal init() {
        registry.register(LocalFileSystem())
        registry.register(memory)
        virtual = VirtualFileSystem(fileSystems: registry)
    }

    /// The names of everything `url` lists, hidden files too, sorted.
    internal func names(_ url: URL) throws -> [String] {
        try virtual.list(url, showHidden: true).map(\.name).sorted()
    }

    /// Each location of the virtual file system reports what its own file system can do, however the views mix them.
    @Test
    internal func eachLocationReportsWhatItsOwnFileSystemCanDo() throws {
        let box = try Sandbox()
        try box.file("L/a.txt")
        memory.addFile("/R/b.txt")
        memory.capabilitiesAt = { _ in [] }
        let local = virtual.capabilities(for: virtual.branch(of: box.url("L")))
        let readOnly = virtual.capabilities(for: virtual.branch(of: memory.url("/R")))
        #expect(local.contains(.write) && local.contains(.trash))
        #expect(readOnly.isEmpty)
        // The same holds for selected branches and lists, whatever was read last.
        let picked = virtual.registerPicked([memory.url("/R/b.txt")], in: memory.url("/R"))
        #expect(virtual.capabilities(for: picked).isEmpty)
        let mixed = virtual.register(files: [box.url("L/a.txt"), memory.url("/R/b.txt")], title: "Found", origin: nil)
        #expect(virtual.capabilities(for: mixed).isEmpty)
        let localList = virtual.register(files: [box.url("L/a.txt")], title: "Local", origin: nil)
        // (A list's files can be deleted and trashed where they lie; nothing can be made "in" a list.)
        #expect(virtual.capabilities(for: localList) == [.write, .trash, .removeOnly])
        _ = try names(virtual.branch(of: memory.url("/R")))
        #expect(virtual.capabilities(for: virtual.branch(of: box.url("L"))) == local)
        #expect(virtual.capabilities(for: URL(fileURLWithPath: "/tmp")) == virtual.capabilities)
    }

    /// A cancelled branch walk of a tree whose listings stall ends, and leaves no half branch behind.
    @Test
    internal func aCancelledBranchWalkOfAStalledTreeEndsAndLeavesNothingBehind() throws {
        memory.addFile("/S/a/f.txt")
        memory.stallsListings = true
        let flag = CancellationFlag()
        let finished = DispatchSemaphore(value: 0)
        let branch = virtual.branch(of: memory.url("/S"))
        let walker = virtual
        Thread.detachNewThread {
            _ = try? walker.list(branch, showHidden: false, cancellation: flag) { _ in true }
            finished.signal()
        }
        #expect(Wait.until { memory.listRequests(for: "/S") > 0 })
        flag.cancel()
        let ended = finished.wait(timeout: .now() + Wait.ceiling) == .success
        memory.releaseStalls()
        #expect(ended)
        // A walk that was given up is no branch: the same walk without a flag reads it all.
        #expect(try names(branch) == ["a/f.txt"])
    }

    /// A walk with a cancellation flag that is never set lists what a walk without one lists.
    @Test
    internal func aWalkWithAFlagThatIsNeverSetListsAsWithout() throws {
        memory.addFile("/W/a/f.txt")
        memory.addFile("/W/g.txt")
        let branch = virtual.branch(of: memory.url("/W"))
        let flagged = try virtual.list(branch, showHidden: false, cancellation: CancellationFlag()).map(\.name).sorted()
        let plain = try names(branch)
        #expect(flagged == ["a/f.txt", "g.txt"] && flagged == plain)
    }

    /// Reads, writes, commits, quarantine and metadata go to the real file system with real locations.
    @Test
    internal func callsAreForwardedToTheRealFileSystem() throws {
        memory.capabilities = [.write, .append, .deferredWrites]
        memory.keepsMetadata = true
        memory.quarantineValue = Data("0083;5e;Safari;".utf8)
        memory.addFile("/F/one.txt", "hello")
        memory.addDirectory("/F/dir")
        memory.addDirectory("/G/copy")
        let branch = virtual.branch(of: memory.url("/F"))
        let flag = CancellationFlag()

        let reader = try virtual.read(VirtualLocation.branch(real: memory.url("/F/one.txt")).url, cancellation: flag)
        #expect(try reader.read(upToCount: 10) == Data("hello".utf8))
        reader.close()
        let writer = try virtual.write(VirtualLocation.branch(real: memory.url("/F/new.txt")).url, cancellation: flag)
        try writer.write(Data("abc".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(memory.contents("/F/new.txt") == "abc")
        let appender = try virtual.append(
            to: VirtualLocation.branch(real: memory.url("/F/new.txt")).url,
            at: 1,
            cancellation: flag
        )
        try appender.write(Data("Z".utf8))
        try appender.close(attributes: FileAttributes())
        #expect(memory.contents("/F/new.txt") == "aZ")

        try virtual.commit(branch, cancellation: flag)
        #expect(memory.commits == ["/F"])
        #expect(virtual.quarantine(of: branch) == memory.quarantineValue)
        try virtual.setQuarantine(Data("q".utf8), of: VirtualLocation.branch(real: memory.url("/F/dir")).url)
        #expect(memory.quarantineMarks["/F/dir"] == Data("q".utf8))

        // Both ends are translated; the real file system gets real locations.
        try virtual.copyMetadata(
            from: VirtualLocation.branch(real: memory.url("/F/dir")).url,
            to: VirtualLocation.branch(real: memory.url("/G/copy")).url
        )
        #expect(memory.metadataCopies.map(\.to) == ["/G/copy"] && memory.metadataCopies.first?.from.scheme == "mem")
        let list = virtual.register(files: [memory.url("/F/one.txt")], title: "Found", origin: nil)
        #expect(throws: FileSystemError.self) {
            try virtual.copyMetadata(from: list, to: VirtualLocation.branch(real: memory.url("/G/copy")).url)
        }

        #expect(
            virtual.item(at: VirtualLocation.branch(real: memory.url("/F/one.txt")).url, cancellation: flag)?.name
                == "one.txt"
        )
        flag.cancel()
        #expect(virtual.item(at: VirtualLocation.branch(real: memory.url("/F/one.txt")).url, cancellation: flag) == nil)
        #expect(virtual.totalSize(of: branch, cancellation: CancellationFlag()) == 7)
    }

    /// Files of the same name in a picked view get names of their own and stay the real files.
    @Test
    internal func sameNamedFilesOfAPickedViewHaveNamesOfTheirOwn() throws {
        memory.addFile("/X/a/same.txt", "1")
        memory.addFile("/X/b/same.txt", "22")
        memory.addFile("/X/c/other.txt", "3")
        let picked = virtual.registerPicked(
            [memory.url("/X/a/same.txt"), memory.url("/X/b/same.txt"), memory.url("/X/c/other.txt")],
            in: memory.url("/X")
        )
        let items = try virtual.list(picked, showHidden: true)
        #expect(Set(items.map { Array($0.name.utf8) }).count == 3)
        #expect(items.filter { $0.name.hasSuffix("same.txt") }.count == 2 && items.contains { $0.name == "other.txt" })
        // Whatever the name says, the entry is the real file.
        #expect(Set(items.map(\.url.path)) == ["/X/a/same.txt", "/X/b/same.txt", "/X/c/other.txt"])
    }

    /// The contents of same-named folders of a picked view are kept apart.
    @Test
    internal func foldersOfAPickedViewKeepTheirContentsApart() throws {
        memory.addFile("/Y/p/dir/in.txt")
        memory.addFile("/Y/q/dir/in.txt")
        let picked = virtual.registerPicked([memory.url("/Y/p/dir"), memory.url("/Y/q/dir")], in: memory.url("/Y"))
        let items = try virtual.list(picked, showHidden: true)
        #expect(
            items.count == 2 && Set(items.map(\.name)).count == 2
                && Set(items.map(\.url.path)) == ["/Y/p/dir/in.txt", "/Y/q/dir/in.txt"]
        )
    }

    /// Moving, copying and removing the files of a picked view act on the real files.
    @Test
    internal func operationsOnAPickedViewActOnTheRealFiles() throws {
        let box = try Sandbox()
        try box.file("a/same.txt", "1")
        try box.file("b/same.txt", "2")
        let picked = virtual.registerPicked([box.url("a/same.txt"), box.url("b/same.txt")], in: box.root)
        let items = try virtual.list(picked, showHidden: true)
        let second = try #require(items.first { $0.url.path.hasSuffix("b/same.txt") })
        let local = try registry.provider(for: second.url)
        try local.move(second.url, to: box.url("b/renamed.txt"), replacing: false)
        let first = try #require(items.first { $0.url.path.hasSuffix("a/same.txt") })
        try local.copy(first.url, to: box.url("copy.txt")) { _ in true }
        try local.remove(first.url)
        #expect(box.read("b/renamed.txt") == "2" && box.read("copy.txt") == "1" && !box.exists("a/same.txt"))
    }

    /// Two names that differ only in their Unicode normalisation are two files in lists and views.
    @Test
    internal func twoNamesThatDifferOnlyInNormalisationAreTwoFiles() throws {
        let (composed, decomposed) = ("caf\u{e9}.txt", "cafe\u{301}.txt")
        memory.addFile("/N/" + composed)
        memory.addFile("/N/" + decomposed)
        let urls = [memory.url("/N/" + composed), memory.url("/N/" + decomposed), memory.url("/N/" + composed)]
        let list = virtual.register(files: urls, title: "Twins", origin: nil)
        #expect(virtual.entries(of: list).count == 2)
        let picked = virtual.registerPicked(urls, in: memory.url("/N"))
        #expect(virtual.entries(of: picked).count == 2)
        let shown = try virtual.list(picked, showHidden: true)
        #expect(Set(shown.map { Array($0.name.utf8) }).count == 2)
    }

    /// A branch walk does not enter a volume mounted below it, but lists one it starts on.
    @Test
    internal func aBranchWalkStaysOnItsVolume() throws {
        let box = try Sandbox()
        try box.file("plain/a.txt")
        guard let image = MountedImage(in: box, at: "mounted") else {
            // Shown as skipped, not as passed: nothing was checked.
            // Fails rather than skips: a skip would leave what the test covers to chance.
            Issue.record("a disk image cannot be attached here (hdiutil)")
            return
        }
        try Data("m".utf8).write(to: image.mountPoint.appendingPathComponent("inside.txt"))
        #expect(BranchWalker.isMountPoint(image.mountPoint.path) && !BranchWalker.isMountPoint(box.url("plain").path))
        #expect(try names(virtual.branch(of: box.root)) == ["mounted.dmg", "plain/a.txt"])
        // Started on the volume itself, the walk lists it.
        #expect(try names(virtual.branch(of: image.mountPoint)).contains("inside.txt"))
        #expect(BranchWalker.isMountPoint("/") && !BranchWalker.isMountPoint("/Users"))
    }
}

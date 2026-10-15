import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// What the other suites leave: calls a flag ends, removals and moves that cannot be done, copies that end half way.
@MainActor
@Suite
internal struct CoverageLocalMore {
    /// A listing cancelled before a read ends quietly.
    @Test
    internal func aListingCancelledBeforeAReadEndsQuietly() throws {
        let box = try Sandbox()
        try box.file("a.txt")
        let flag = CancellationFlag()
        // The second question is the first read of the folder.
        let local = CoverageLocalProbes.asking { path, count in if path == box.root.path, count == 1 { flag.cancel() } }
        #expect(try local.list(box.root, showHidden: true, cancellation: flag).isEmpty)
    }

    /// A file opened for a flag that is set meanwhile is not opened.
    @Test
    internal func aFileOpenedForAFlagThatIsSetMeanwhileIsNotOpened() throws {
        let box = try Sandbox()
        let file = try box.file("a.txt")
        let flag = CancellationFlag()
        let local = CoverageLocalProbes.asking { path, _ in if path == file.path { flag.cancel() } }
        #expect { try local.read(file, cancellation: flag) } throws: { ($0 as? CocoaError)?.code == .userCancelled }
    }

    /// A removal below a root needs the way down and the item.
    @Test
    internal func aRemovalBelowARootNeedsTheWayDownAndTheItem() throws {
        let box = try Sandbox()
        #expect {
            try LocalFileSystem()
                .remove(
                    URL(fileURLWithPath: "/afm-coverage-none/x"),
                    below: URL(fileURLWithPath: "/"),
                    cancellation: CancellationFlag()
                )
        } throws: { error in
            CoverageLocalProbes.code(error) == Int(ENOENT)
        }
        #expect {
            try LocalFileSystem().remove(box.url("missing"), below: box.root, cancellation: CancellationFlag())
        } throws: { error in
            CoverageLocalProbes.code(error) == Int(ENOENT)
        }
    }

    /// A move checked first that fails says why.
    @Test
    internal func aMoveCheckedFirstThatFailsSaysWhy() throws {
        let box = try Sandbox()
        let local = CoverageLocalProbes.failing("renamex_np", endingIn: "missing.txt", ENOTSUP)
        #expect { try local.move(box.url("missing.txt"), to: box.url("free.txt"), replacing: false) } throws: { error in
            CoverageLocalProbes.code(error) == Int(ENOENT)
        }
    }

    /// An own locked copy that cannot be moved stays locked where it was.
    @Test
    internal func anOwnLockedCopyThatCannotBeMovedStaysLockedWhereItWas() throws {
        let box = try Sandbox()
        let local = LocalFileSystem()
        let folder = try box.folder("folder")
        let source = try box.file("source.txt", "locked")
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(source.path, 0) }
        let copy = folder.appendingPathComponent(".copy.tmp")
        try local.copy(source, to: copy) { _ in true }
        #expect(chflags(folder.path, UInt32(UF_IMMUTABLE)) == 0)
        defer {
            chflags(folder.path, 0)
            chflags(copy.path, 0)
        }
        let target = folder.appendingPathComponent("final.txt")
        #expect { try local.move(copy, to: target, replacing: false) } throws: { error in
            CoverageLocalProbes.code(error) == Int(EPERM)
        }
        #expect(CoverageLocalProbes.isLocked(copy))
    }

    /// An unreadable locked file under the name of an own copy stays locked.
    @Test
    internal func anUnreadableLockedFileUnderTheNameOfAnOwnCopyStaysLocked() throws {
        let box = try Sandbox()
        let local = LocalFileSystem()
        let source = try box.file("source.txt", "locked")
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(source.path, 0) }
        let copy = box.url(".copy.tmp")
        try local.copy(source, to: copy) { _ in true }
        chflags(copy.path, 0)
        try FileManager.default.removeItem(at: copy)
        try box.file(".copy.tmp", "the user's")
        #expect(chmod(copy.path, 0) == 0 && chflags(copy.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(copy.path, 0) }
        #expect { try local.remove(copy) } throws: { CoverageLocalProbes.code($0) == Int(EPERM) }
        #expect(CoverageLocalProbes.isLocked(copy))
    }

    /// A copy needs its source and a free name.
    @Test
    internal func aCopyNeedsItsSourceAndAFreeName() throws {
        let box = try Sandbox()
        #expect { try LocalFileSystem().copy(box.url("missing"), to: box.url("copy")) { _ in true } } throws: { error in
            CoverageLocalProbes.code(error) == Int(ENOENT)
        }
        // Another program takes the name between the look and the copy.
        let source = try box.file("a.txt")
        let target = box.url("b.txt")
        let local = CoverageLocalProbes.asking { path, count in
            if path == source.path, count == 1 { try? Data().write(to: target) }
        }
        #expect(throws: FileSystemError.self) { try local.copy(source, to: target) { _ in true } }
        #expect(box.read("b.txt")?.isEmpty == true)
    }

    /// A copy cancelled just before it begins is not made.
    @Test
    internal func aCopyCancelledJustBeforeItBeginsIsNotMade() throws {
        let box = try Sandbox()
        let source = try box.file("a.txt")
        let flag = CancellationFlag()
        let local = CoverageLocalProbes.asking { path, count in if path == source.path, count == 1 { flag.cancel() } }
        #expect { try local.copy(source, to: box.url("b.txt"), cancellation: flag) { _ in true } } throws: { error in
            (error as? CocoaError)?.code == .userCancelled
        }
        #expect(!box.exists("b.txt"))
    }

    /// Metadata needs its source.
    @Test
    internal func metadataNeedsItsSource() throws {
        let box = try Sandbox()
        let destination = try box.file("b.txt")
        #expect { try LocalFileSystem().copyMetadata(from: box.url("missing"), to: destination) } throws: { error in
            CoverageLocalProbes.code(error) == Int(ENOENT)
        }
    }

    /// Links with dots in their text lead where they say.
    @Test
    internal func linksWithDotsInTheirTextLeadWhereTheySay() throws {
        let box = try Sandbox()
        try box.file("folder/a.txt", "12")
        let link = box.url("folder/link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "./a.txt")
        #expect(LinkResolver().resolve(link.path)?.size == 2)
    }

    /// A tree whose read fails at once counts as nothing.
    @Test
    internal func aTreeWhoseReadFailsAtOnceCountsAsNothing() throws {
        let box = try Sandbox()
        try box.file("a.txt", "12345")
        let local = CoverageLocalProbes.failing("getattrlistbulk", endingIn: box.root.lastPathComponent, EIO)
        #expect(local.totalSize(of: box.root, cancellation: CancellationFlag()) == 0)
        // An entry that failed and turns out to be a link counts for nothing.
        try FileManager.default.createSymbolicLink(atPath: box.url("link").path, withDestinationPath: "a.txt")
        var entry = LocalFileSystem.Entry()
        entry.name = "link"
        entry.failed = true
        #expect(LocalFileSystem.measured(entry, in: box.root.path) == nil)
    }

    /// A volume that comes or goes has the places read again.
    @Test
    internal func aVolumeThatComesOrGoesHasThePlacesReadAgain() throws {
        let box = try Sandbox()
        var probes = LocalProbes()
        probes.home = box.root
        let local = LocalFileSystem(probes: probes)
        #expect(Wait.until(seconds: 60) { local.places().contains { $0.kind == .internalDisk } })
        try box.folder("Library/Mobile Documents/com~apple~CloudDocs")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
        #expect(Wait.until(seconds: 60) { local.places().contains { $0.name == "iCloud Drive" } })
    }

    /// The plugin registers the file system of the Mac.
    @Test
    internal func thePluginRegistersTheFileSystemOfTheMac() {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        let plugin = LocalFileSystemPlugin()
        kernel.load([plugin])
        #expect(plugin.name == "Local file system")
        #expect((try? kernel.fileSystems.provider(for: URL(fileURLWithPath: "/"))) is LocalFileSystem)
    }
}

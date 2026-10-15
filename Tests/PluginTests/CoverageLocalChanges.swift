import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Removing, moving and copying, where locks, other volumes and the system get in the way.
@Suite
internal struct CoverageLocalChanges {
    /// An own locked copy below a root is removed.
    @Test
    internal func anOwnLockedCopyBelowARootIsRemoved() throws {
        let box = try Sandbox()
        let local = LocalFileSystem()
        let copy = try CoverageLocalProbes.lockedCopy(in: box, named: ".copy.tmp", local)
        try local.remove(copy, below: box.root, cancellation: CancellationFlag())
        #expect(!box.exists(".copy.tmp"))
    }

    /// An own locked copy in a locked folder stays as locked as it was.
    @Test
    internal func anOwnLockedCopyInALockedFolderStaysAsLockedAsItWas() throws {
        let box = try Sandbox()
        let local = LocalFileSystem()
        let folder = try box.folder("folder")
        let copy = try CoverageLocalProbes.lockedCopy(in: box, folder: "folder", named: ".copy.tmp", local)
        #expect(chflags(folder.path, UInt32(UF_IMMUTABLE)) == 0)
        defer {
            chflags(folder.path, 0)
            chflags(copy.path, 0)
        }
        #expect { try local.remove(copy, below: box.root, cancellation: CancellationFlag()) } throws: { error in
            CoverageLocalProbes.code(error) == Int(EPERM)
        }
        #expect(CoverageLocalProbes.isLocked(copy))
        #expect { try local.remove(copy) } throws: { CoverageLocalProbes.code($0) == Int(EPERM) }
        #expect(CoverageLocalProbes.isLocked(copy))
    }

    /// A removal cancelled while the own copy is unlocked locks it again.
    @Test
    internal func aRemovalCancelledWhileTheOwnCopyIsUnlockedLocksItAgain() throws {
        let box = try Sandbox()
        let flag = CancellationFlag()
        let asked = Shared(0)
        let target = box.url(".copy.tmp")
        var probes = LocalProbes()
        probes.willAsk = { path in
            guard path == target.path else {
                return
            }
            asked.modify { $0 += 1 }
            // The look, the removal, then the second removal after the lock was taken off.
            if asked.value == 3 { flag.cancel() }
        }
        let local = LocalFileSystem(probes: probes)
        let copy = try CoverageLocalProbes.lockedCopy(in: box, named: ".copy.tmp", local)
        defer { chflags(copy.path, 0) }
        asked.value = 0
        #expect { try local.remove(copy, cancellation: flag) } throws: { ($0 as? CocoaError)?.code == .userCancelled }
        #expect(box.exists(".copy.tmp") && CoverageLocalProbes.isLocked(copy))
    }

    /// A locked copy that is no longer the own one stays locked.
    @Test
    internal func aLockedCopyThatIsNoLongerTheOwnOneStaysLocked() throws {
        let box = try Sandbox()
        let local = LocalFileSystem()
        // Remembered too long ago: the user's by now.
        let old = try CoverageLocalProbes.lockedCopy(in: box, named: ".old.tmp", local)
        defer { chflags(old.path, 0) }
        local.lockedLock.withLock {
            local.lockedCopies[old.path]?.made = DispatchTime.now().uptimeNanoseconds &- 7 * 3_600 * 1_000_000_000
        }
        #expect { try local.remove(old) } throws: { CoverageLocalProbes.code($0) == Int(EPERM) }
        #expect(local.lockedLock.withLock { local.lockedCopies[old.path] } == nil)
        // Another file under the copy's name, locked by the user.
        let other = try CoverageLocalProbes.lockedCopy(in: box, named: ".other.tmp", local)
        chflags(other.path, 0)
        try FileManager.default.removeItem(at: other)
        try box.file(".other.tmp", "the user's")
        #expect(chflags(other.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(other.path, 0) }
        #expect { try local.remove(other) } throws: { CoverageLocalProbes.code($0) == Int(EPERM) }
        #expect(box.read(".other.tmp") == "the user's")
    }

    /// An own locked copy that cannot be read is unlocked by name.
    @Test
    internal func anOwnLockedCopyThatCannotBeReadIsUnlockedByName() throws {
        let box = try Sandbox()
        let local = LocalFileSystem()
        let copy = try CoverageLocalProbes.lockedCopy(in: box, named: ".copy.tmp", local)
        chflags(copy.path, 0)
        #expect(chmod(copy.path, 0) == 0)
        #expect(chflags(copy.path, UInt32(UF_IMMUTABLE)) == 0)
        try local.remove(copy)
        #expect(!box.exists(".copy.tmp"))
    }

    /// An item goes to the trash.
    @Test
    internal func anItemGoesToTheTrash() throws {
        let box = try Sandbox()
        let name = "afm-coverage-\(UUID().uuidString).txt"
        let file = try box.file(name)
        // The system's affair: the item goes, or the system says why it cannot (a user without a Trash).
        do {
            try LocalFileSystem().trash(file)
            #expect(!box.exists(name))
            let trash = try FileManager.default.url(
                for: .trashDirectory,
                in: .userDomainMask,
                appropriateFor: file,
                create: false
            )
            try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }
}

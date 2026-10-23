import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Moving, copying and the metadata of items, where locks and the system get in the way.
@Suite
internal struct CoverageLocalMoves {
    /// A volume that cannot rename exclusively is checked first.
    @Test
    internal func aVolumeThatCannotRenameExclusivelyIsCheckedFirst() throws {
        let box = try Sandbox()
        let source = try box.file("a.txt", "a")
        try box.file("taken.txt", "taken")
        let local = CoverageLocalProbes.failing("renamex_np", endingIn: "a.txt", ENOTSUP)
        #expect(throws: FileSystemError.self) { try local.move(source, to: box.url("taken.txt"), replacing: false) }
        try local.move(source, to: box.url("free.txt"), replacing: false)
        #expect(box.read("free.txt") == "a" && box.read("taken.txt") == "taken")
    }

    /// A move cancelled while the own copy is unlocked locks it again.
    @Test
    internal func aMoveCancelledWhileTheOwnCopyIsUnlockedLocksItAgain() throws {
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
            if asked.value == 2 { flag.cancel() }
        }
        let local = LocalFileSystem(probes: probes)
        let copy = try CoverageLocalProbes.lockedCopy(in: box, named: ".copy.tmp", local)
        defer { chflags(copy.path, 0) }
        asked.value = 0
        let final = box.url("final.txt")
        #expect { try local.move(copy, to: final, replacing: false, cancellation: flag) } throws: { error in
            (error as? CocoaError)?.code == .userCancelled
        }
        #expect(!box.exists("final.txt") && CoverageLocalProbes.isLocked(copy))
    }

    /// The other name of a file that cannot be taken away is an error.
    @Test
    internal func theOtherNameOfAFileThatCannotBeTakenAwayIsAnError() throws {
        let box = try Sandbox()
        let first = try box.file("first.txt", "one file")
        try FileManager.default.linkItem(at: first, to: box.url("second.txt"))
        let local = CoverageLocalProbes.failing("unlink", endingIn: "first.txt", EIO)
        #expect { try local.move(first, to: box.url("second.txt"), replacing: true) } throws: { error in
            CoverageLocalProbes.code(error) == Int(EIO)
        }
        let crossing = CoverageLocalProbes.failing("rename", endingIn: "first.txt", EXDEV)
        #expect { try crossing.move(first, to: box.url("third.txt"), replacing: true) } throws: { error in
            if case .crossesVolumes = error as? FileSystemError { true } else { false }
        }
    }

    /// The stored name and the temporary names are told apart.
    @Test
    internal func theStoredNameAndTheTemporaryNamesAreToldApart() throws {
        let box = try Sandbox()
        #expect(LocalFileSystem.storedName(of: box.url("missing")).isEmpty)
        try box.file("Name.txt")
        #expect(LocalFileSystem.storedName(of: box.url("name.txt")) == Array("Name.txt".utf8))
        for name in [".a.tmp", ".a.afm-save", ".afm-part"] {
            #expect(LocalFileSystem.isTemporaryName(box.url(name)))
        }
        for name in ["a.tmp", ".a.txt"] {
            #expect(!LocalFileSystem.isTemporaryName(box.url(name)))
        }
    }

    /// A copy whose caller has left reports to nobody and stops.
    @Test
    internal func aCopyWhoseCallerHasLeftReportsToNobodyAndStops() {
        let seen = Shared<[Int64]>([])
        let report = LocalFileSystem.CopyReport { copied in
            seen.modify { $0.append(copied) }
            return true
        }
        #expect(report(5))
        report.detach()
        #expect(!report(9))
        #expect(seen.value == [5])
    }

    /// A copied locked file that cannot be looked at afterwards is not remembered.
    @Test
    internal func aCopiedLockedFileThatCannotBeLookedAtAfterwardsIsNotRemembered() throws {
        let box = try Sandbox()
        let local = CoverageLocalProbes.failing("lstat", endingIn: ".copy.tmp", EIO)
        let copy = try CoverageLocalProbes.lockedCopy(in: box, named: ".copy.tmp", local)
        defer { chflags(copy.path, 0) }
        #expect { try local.remove(copy) } throws: { CoverageLocalProbes.code($0) == Int(EPERM) }
    }

    /// A lock that cannot be taken off stops the change.
    @Test
    internal func aLockThatCannotBeTakenOffStopsTheChange() throws {
        let box = try Sandbox()
        let file = try box.file("a.txt")
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }
        let local = CoverageLocalProbes.failing("lchflags", endingIn: "a.txt", EPERM)
        #expect { try local.setAttributes(FileAttributes(permissions: 0o644), of: file) } throws: { error in
            CoverageLocalProbes.code(error) == Int(EPERM)
        }
        #expect(CoverageLocalProbes.isLocked(file))
    }

    /// Metadata is copied only between items that are there.
    @Test
    internal func metadataIsCopiedOnlyBetweenItemsThatAreThere() throws {
        let box = try Sandbox()
        let source = try box.file("a.txt")
        let relative = try #require(URL(string: "relative-name"))
        #expect { try LocalFileSystem().copyMetadata(from: relative, to: source) } throws: { error in
            (error as? FileSystemError)?.localizedDescription.contains("another file system") == true
        }
        #expect { try LocalFileSystem().copyMetadata(from: source, to: box.url("missing")) } throws: { error in
            CoverageLocalProbes.code(error) == Int(ENOENT)
        }
    }

    /// Each failure of copying metadata is reported, the first one first.
    @Test
    internal func eachFailureOfCopyingMetadataIsReportedTheFirstFirst() throws {
        let box = try Sandbox()
        let source = try box.file("a.txt")
        #expect(chflags(source.path, UInt32(UF_HIDDEN)) == 0)
        let destination = try box.file("b.txt")
        // Made a moment later: another date of creation.
        var times = [timespec(tv_sec: 1_000, tv_nsec: 0)]
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        #expect(setattrlist(source.path, &request, &times, MemoryLayout<timespec>.size, 0) == 0)
        var probes = LocalProbes()
        probes.fault = { call, path in
            guard path.hasSuffix("b.txt") else {
                return nil
            }
            return ["copyfile": EIO, "setattrlist": EPERM, "lchflags": EACCES][call]
        }
        #expect { try LocalFileSystem(probes: probes).copyMetadata(from: source, to: destination) } throws: { error in
            CoverageLocalProbes.code(error) == Int(EIO)
        }
        for (call, code) in [("setattrlist", EPERM), ("lchflags", EACCES)] {
            let fresh = try box.file("\(call)-b.txt")
            let local = CoverageLocalProbes.failing(call, endingIn: "b.txt", code)
            #expect { try local.copyMetadata(from: source, to: fresh) } throws: { error in
                CoverageLocalProbes.code(error) == Int(code)
            }
        }
    }

    /// A quarantine mark that goes while it is read is none.
    @Test
    internal func aQuarantineMarkThatGoesWhileItIsReadIsNone() throws {
        let box = try Sandbox()
        let file = try box.file("a.txt")
        try LocalFileSystem().setQuarantine(Data("0081;00000000;Test;".utf8), of: file)
        #expect(LocalFileSystem().quarantine(of: file) == Data("0081;00000000;Test;".utf8))
        #expect(CoverageLocalProbes.failing("getxattr", endingIn: "a.txt", ENOATTR).quarantine(of: file) == nil)
    }
}

import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Copies to another volume: the system copies block by block, reports its progress and can be stopped.
@Suite(.serialized)
internal struct CoverageLocalOtherVolume {
    /// A file of `size` bytes that cannot be stored sparsely.
    private static func file(_ box: Sandbox, _ name: String, size: Int) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: size)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7) }
        let url = box.url(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// A copy to another volume reports its progress.
    @Test
    internal func aCopyToAnotherVolumeReportsItsProgress() throws {
        let box = try Sandbox()
        guard let image = CoverageCoreDiskImage(in: box, name: "AFMCopy") else {
            try Test.cancel("a disk image cannot be attached here (hdiutil)")
        }
        let source = try Self.file(box, "big.bin", size: 3_000_000)
        var reported: [Int64] = []
        try LocalFileSystem()
            .copy(source, to: image.mountPoint.appendingPathComponent("big.bin")) { copied in
                reported.append(copied)
                return true
            }
        #expect(!reported.isEmpty && reported.last ?? 0 <= 3_000_000)
        #expect(try Data(contentsOf: image.mountPoint.appendingPathComponent("big.bin")).count == 3_000_000)
    }

    /// A stopped copy to another volume leaves nothing.
    @Test
    internal func aStoppedCopyToAnotherVolumeLeavesNothing() throws {
        let box = try Sandbox()
        guard let image = CoverageCoreDiskImage(in: box, name: "AFMStop") else {
            try Test.cancel("a disk image cannot be attached here (hdiutil)")
        }
        let source = try Self.file(box, "big.bin", size: 3_000_000)
        let target = image.mountPoint.appendingPathComponent("big.bin")
        #expect { try LocalFileSystem().copy(source, to: target) { _ in false } } throws: { error in
            (error as? CocoaError)?.code == .userCancelled
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        // What cannot be removed at once is unlocked first.
        let local = CoverageLocalProbes.failing("unlink", endingIn: "again.bin", EPERM)
        let again = image.mountPoint.appendingPathComponent("again.bin")
        #expect { try local.copy(source, to: again) { _ in false } } throws: { error in
            (error as? CocoaError)?.code == .userCancelled
        }
        #expect(!FileManager.default.fileExists(atPath: again.path))
    }

    /// It used to go on for ever: the system was told to try the failed write again, and again.
    @Test
    internal func aCopyThatDoesNotFitEndsWithTheErrorAndLeavesNothing() throws {
        let box = try Sandbox()
        guard let image = CoverageCoreDiskImage(in: box, name: "AFMFull", megabytes: 4) else {
            try Test.cancel("a disk image cannot be attached here (hdiutil)")
        }
        let source = try Self.file(box, "big.bin", size: 6_000_000)
        let target = image.mountPoint.appendingPathComponent("big.bin")
        #expect { try LocalFileSystem().copy(source, to: target) { _ in true } } throws: { error in
            CoverageLocalProbes.code(error) == Int(ENOSPC)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// A copy cancelled while its extended attributes are copied leaves nothing.
    @Test
    internal func aCopyCancelledWhileItsExtendedAttributesAreCopiedLeavesNothing() throws {
        let box = try Sandbox()
        guard let image = CoverageCoreDiskImage(in: box, name: "AFMAttributes", megabytes: 64) else {
            try Test.cancel("a disk image cannot be attached here (hdiutil)")
        }
        let source = try box.file("attributes.txt", "attributes")
        for index in 0..<2 {
            #expect(setxattr(source.path, "com.example.coverage.\(index)", "value", 5, 0, 0) == 0)
        }
        for (name, held) in [("plain.txt", false), ("held.txt", true)] {
            // Stopped when the first attribute has been copied: the file is there, its data not yet.
            var probes = LocalProbes()
            probes.copyStops = { what, stage in what == COPYFILE_COPY_XATTR && stage == COPYFILE_FINISH }
            // The removal is refused at first, as for a file that was locked meanwhile.
            probes.fault = { call, path in held && call == "unlink" && path.hasSuffix(name) ? EPERM : nil }
            let local = LocalFileSystem(probes: probes)
            let target = image.mountPoint.appendingPathComponent(name)
            let flag = CancellationFlag()
            #expect { try local.copy(source, to: target, cancellation: flag) { _ in true } } throws: { error in
                (error as? CocoaError)?.code == .userCancelled
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    /// A locked copy on another volume keeps the date of creation and stays the own one.
    @Test
    internal func aLockedCopyOnAnotherVolumeKeepsTheDateOfCreationAndStaysTheOwnOne() throws {
        let box = try Sandbox()
        guard let image = CoverageCoreDiskImage(in: box, name: "AFMLock") else {
            try Test.cancel("a disk image cannot be attached here (hdiutil)")
        }
        let source = try box.file("locked.txt", "locked")
        var times = [timespec(tv_sec: 1_000_000, tv_nsec: 0)]
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        #expect(setattrlist(source.path, &request, &times, MemoryLayout<timespec>.size, 0) == 0)
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(source.path, 0) }
        let local = LocalFileSystem()
        let copy = image.mountPoint.appendingPathComponent(".locked.txt.tmp")
        try local.copy(source, to: copy) { _ in true }
        var info = stat()
        #expect(lstat(copy.path, &info) == 0)
        #expect(info.st_birthtimespec.tv_sec == 1_000_000 && info.st_flags & UInt32(UF_IMMUTABLE) != 0)
        try local.move(copy, to: image.mountPoint.appendingPathComponent("locked.txt"), replacing: false)
        chflags(image.mountPoint.appendingPathComponent("locked.txt").path, 0)
    }
}

import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// What the archives ask the disk without opening an archive: room, volumes, what lies at a
/// path; and what they read from a GZIP header and take as settings by default.
@Suite
internal struct CoverageArchivesVolumeTests {
    private let box: Sandbox

    /// A folder of its own for each test.
    internal init() throws {
        box = try Sandbox()
    }

    /// Checks that room is found where the disk has it, missing where it has none, and
    /// assumed where the disk cannot be asked.
    @Test
    internal func roomIsAskedOfTheDiskAndOfTheSystem() {
        #expect(Volume.hasRoom(for: 1, at: box.root))
        // More than any disk holds: the system is asked whether it can make room, and cannot.
        #expect(!Volume.hasRoom(for: .max, at: box.root))
        // A volume without free space, which has nothing to make room from either.
        #expect(!Volume.hasRoom(for: 1, at: URL(fileURLWithPath: "/dev")))
        // A place that cannot be asked is not held against a write.
        #expect(Volume.hasRoom(for: 1, at: box.url("nowhere/at/all")))
    }

    /// Checks that a volume and a signature are found for what exists, and nothing for what does not.
    @Test
    internal func volumesAndSignaturesOfMissingPathsAreNil() throws {
        let file = try box.file("present.txt", "here")
        #expect(Volume.device(of: file.path) != nil && Volume.device(of: box.url("absent").path) == nil)
        #expect(FileSignature.of(file.path)?.size == 4 && FileSignature.of(box.url("absent").path) == nil)
    }

    /// Checks which paths count as lying on the disks of this machine, from the table of mounts.
    @Test
    internal func localVolumesAreToldFromTheMountTable() {
        #expect(Volume.isOnLocalVolume("/"))
        #expect(Volume.isOnLocalVolume("/System/Volumes/Data"))
        #expect(Volume.isOnLocalVolume("/System/Volumes/Data/private"))
        // A name that merely starts like a mount point is not inside it.
        #expect(Volume.isOnLocalVolume("/System/Volumes/DataOther"))
        // The home folders are mounted on demand (autofs): asking them may wait for a server.
        #expect(!Volume.isOnLocalVolume("/System/Volumes/Data/home/somebody"))
        #expect(!Volume.isOnLocalVolume("relative/path"))
    }

    /// Checks what a walk over the local disks finds at a path: files, folders, other things,
    /// nothing, and where it stops because the path leaves the local disks.
    @Test
    internal func whatLiesAtALocalPathIsFoundWithoutAskingServers() throws {
        let file = try box.file("folder/file.txt")
        #expect(Volume.kind(ofLocalPath: "/") == .directory)
        #expect(Volume.kind(ofLocalPath: file.path) == .regularFile)
        #expect(Volume.kind(ofLocalPath: file.deletingLastPathComponent().path) == .directory)
        #expect(Volume.kind(ofLocalPath: box.url("missing").path) == .missing)
        #expect(Volume.kind(ofLocalPath: file.path + "/below") == .missing)
        #expect(mkfifo(box.url("pipe").path, 0o600) == 0)
        #expect(Volume.kind(ofLocalPath: box.url("pipe").path) == .other)
        // Links are followed by hand, relative and absolute ones.
        try FileManager.default.createSymbolicLink(atPath: box.url("near").path, withDestinationPath: "folder")
        try FileManager.default.createSymbolicLink(
            atPath: box.url("far").path,
            withDestinationPath: file.deletingLastPathComponent().path
        )
        #expect(Volume.kind(ofLocalPath: box.url("near/file.txt").path) == .regularFile)
        #expect(Volume.kind(ofLocalPath: box.url("far/file.txt").path) == .regularFile)
        #expect(Volume.kind(ofLocalPath: box.url("near").path) == .directory)
        // Links that lead to each other end in nothing.
        try FileManager.default.createSymbolicLink(atPath: box.url("ping").path, withDestinationPath: "pong")
        try FileManager.default.createSymbolicLink(atPath: box.url("pong").path, withDestinationPath: "ping")
        #expect(Volume.kind(ofLocalPath: box.url("ping").path) == .missing)
        // `/home` leads to the home folders mounted on demand: the walk stops there.
        #expect(Volume.kind(ofLocalPath: "/home/somebody/file.zip") == .unasked)
    }

    /// Checks the optional fields of a GZIP header: the stored name (behind an extra field,
    /// and in Latin-1 when it is not UTF-8) and the time.
    @Test
    internal func theNameAndTimeOfAGzipHeaderAreRead() {
        #expect(GzipHeader(Data([0x1F, 0x8B, 8])) == nil)
        #expect(GzipHeader(Data(repeating: 0, count: 20)) == nil)
        // Flags: an extra field (4) and a name (8); the time 1 000 000 000.
        let time: [UInt8] = [0x00, 0xCA, 0x9A, 0x3B]
        let latin: [UInt8] = [0x1F, 0x8B, 8, 4 | 8] + time + [0, 3] + [2, 0, 0xAA, 0xBB] + [0x4D, 0xFC, 0x6C, 0x6C, 0]
        let header = GzipHeader(Data(latin))
        #expect(header?.name == "Müll" && header?.modified == Date(timeIntervalSince1970: 1_000_000_000))
        // No time, a UTF-8 name.
        let plain: [UInt8] = [0x1F, 0x8B, 8, 8, 0, 0, 0, 0, 0, 3] + Array("data.txt".utf8) + [0]
        #expect(GzipHeader(Data(plain))?.name == "data.txt" && GzipHeader(Data(plain))?.modified == nil)
    }

    /// Checks what an environment does before the plugin has set it up: no file systems, no
    /// password, no one to tell of a failure.
    @Test
    internal func anEnvironmentThatWasNotSetUpAnswersWithNothing() {
        let environment = ArchiveEnvironment()
        #expect(environment.fileSystems() == nil)
        #expect(environment.askPassword("secret.zip", false) == nil)
        environment.reportFailure(CocoaError(.fileWriteUnknown), "secret.zip")
        #expect(environment.readerParkTime == 10)
    }
}

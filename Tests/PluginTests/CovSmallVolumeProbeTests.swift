import Foundation
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// What the system answers a branch walk about the disks: the disk and entry of a path, with
/// links followed or not, nothing for a path that is not there, mount points, and where a walk
/// crosses onto other disks.
@Suite
internal struct CovSmallVolumeProbeTests {
    /// A path and a link to it are the same entry when the link is followed, and two when not; a
    /// path that is not there has none.
    @Test
    internal func identitiesOfPathsAndLinks() throws {
        let box = try Sandbox()
        try box.file("file.txt", "x")
        let file = box.url("file.txt").path
        let link = box.url("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
        let probe = VolumeProbe.system
        let real = try #require(probe.identity(file, false))
        let followed = try #require(probe.identity(link, true))
        let own = try #require(probe.identity(link, false))
        #expect(followed.device == real.device && followed.inode == real.inode && own.inode != real.inode)
        #expect(probe.identity(box.url("missing").path, true) == nil)
        #expect(probe.identity(box.url("missing").path, false) == nil)
    }

    /// The root is a mount point and a walk from it crosses disks; a folder below it is neither.
    @Test
    internal func mountPointsAndCrossings() throws {
        let box = try Sandbox()
        let probe = VolumeProbe.system
        #expect(probe.isMountPoint("/") && probe.crossesDisks("/"))
        #expect(!probe.isMountPoint(box.root.path) && !probe.crossesDisks(box.root.path))
        #expect(!probe.isMountPoint(box.url("missing").path))
    }
}

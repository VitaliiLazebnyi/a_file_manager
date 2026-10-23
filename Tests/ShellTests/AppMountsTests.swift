import Testing

@testable import AFMShell

/// The volumes of the local file system and the one a path lies on.
@Suite
internal struct AppMountsTests {
    /// The mounts of a machine with a data volume, a stick and a share.
    private let volumes = [
        Mounts.Volume(path: "/", isLocal: true),
        Mounts.Volume(path: "/System/Volumes/Data", isLocal: true),
        Mounts.Volume(path: "/Volumes/Stick", isLocal: true),
        Mounts.Volume(path: "/Volumes/Share", isLocal: false)
    ]

    /// A path lies on the volume with the longest mount point that holds it, not one whose name merely begins alike.
    @Test
    internal func aPathLiesOnTheVolumeWithTheLongestMountPointThatHoldsIt() {
        #expect(Mounts.volume(of: "/Volumes/Stick/photos", among: volumes)?.path == "/Volumes/Stick")
        #expect(Mounts.volume(of: "/Volumes/Stick", among: volumes)?.path == "/Volumes/Stick")
        #expect(Mounts.volume(of: "/Volumes/Sticky/a", among: volumes)?.path == "/")
        #expect(Mounts.volume(of: "/System/Volumes/Data/Users", among: volumes)?.path == "/System/Volumes/Data")
        #expect(Mounts.volume(of: "/Volumes/Stick/a", among: []) == nil)
    }

    /// A path on a share is not local; one on no known volume counts as local.
    @Test
    internal func aShareIsNotLocalAndAnUnknownVolumeIs() {
        #expect(!Mounts.isLocal(path: "/Volumes/Share/doc.txt", among: volumes))
        #expect(Mounts.isLocal(path: "/Volumes/Stick/doc.txt", among: volumes))
        #expect(Mounts.isLocal(path: "/anywhere", among: []))
    }

    /// The system's own list has the root, which is local, and is kept for a moment.
    @Test
    internal func theSystemsListHasTheRoot() {
        let mounted = Mounts.volumes()
        #expect(mounted.contains(Mounts.Volume(path: "/", isLocal: true)))
        #expect(Mounts.volumes() == mounted)
        #expect(Mounts.isLocal(path: "/usr/bin"))
    }
}

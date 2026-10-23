import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// The places: an iCloud Drive that is there or not, volumes that do not answer, readings that are given up.
@Suite(.serialized)
internal struct CoverageLocalPlaces {
    /// A reading that ends in time is not given up when its time is up.
    @Test
    internal func aReadingThatEndsInTimeIsNotGivenUp() throws {
        let box = try Sandbox()
        var probes = LocalProbes()
        probes.home = box.root
        probes.placesPatience = 0.2
        let local = LocalFileSystem(probes: probes)
        #expect(Wait.until { local.places().contains { $0.kind == .internalDisk } })
        // The moment the reading had is over: it was not given up, as it had ended.
        let over = Date(timeIntervalSinceNow: 0.4)
        #expect(Wait.until { Date() > over })
        #expect(local.abandonedReadings == 0)
    }

    /// iCloud Drive is a place where it is there.
    @Test
    internal func iCloudDriveIsAPlaceWhereItIsThere() throws {
        let box = try Sandbox()
        try box.folder("with/Library/Mobile Documents/com~apple~CloudDocs")
        try box.folder("without")
        var probes = LocalProbes()
        probes.home = box.url("with")
        let with = LocalFileSystem(probes: probes)
        probes.home = box.url("without")
        let without = LocalFileSystem(probes: probes)
        #expect(with.places().first?.url == box.url("with"))
        #expect(Wait.until { with.places().contains { $0.name == "iCloud Drive" } })
        #expect(Wait.until { without.places().contains { $0.kind == .internalDisk } })
        #expect(!without.places().contains { $0.name == "iCloud Drive" })
    }

    /// The kind of a volume follows what the system says of it.
    @Test
    internal func theKindOfAVolumeFollowsWhatTheSystemSaysOfIt() {
        #expect(
            LocalFileSystem.volumeKind(
                path: "/",
                isInternal: false,
                isLocal: false,
                isRemovable: false,
                isEjectable: false
            )
                == .internalDisk
        )
        #expect(
            LocalFileSystem.volumeKind(
                path: "/V",
                isInternal: true,
                isLocal: true,
                isRemovable: false,
                isEjectable: false
            )
                == .internalDisk
        )
        #expect(
            LocalFileSystem.volumeKind(
                path: "/V",
                isInternal: true,
                isLocal: true,
                isRemovable: true,
                isEjectable: false
            )
                == .externalDisk
        )
        #expect(
            LocalFileSystem.volumeKind(
                path: "/V",
                isInternal: false,
                isLocal: false,
                isRemovable: false,
                isEjectable: false
            )
                == .externalDisk
        )
    }

    /// A volume that does not answer is listed by its folder name.
    @Test
    internal func aVolumeThatDoesNotAnswerIsListedByItsFolderName() throws {
        let box = try Sandbox()
        guard let image = CoverageCoreDiskImage(in: box, name: "AFMSilent", browsable: true) else {
            // Fails rather than skips: a skip would leave what the test covers to chance.
            Issue.record("a disk image cannot be attached here (hdiutil)")
            return
        }
        let gate = CoverageCoreGate()
        defer { gate.open() }
        var probes = LocalProbes()
        probes.willAsk = { path in if path == image.systemPath { gate.pass() } }
        probes.volumePatience = 0.2
        let places = LocalFileSystem.readPlaces(previous: [], probes, asking: Locked([]))
        let place = try #require(places.first { $0.url.path == image.systemPath })
        #expect(place.name == "AFMSilent-mount" && place.kind == .externalDisk)
        // What was known of it before is shown instead.
        let known = Place(name: "AFMSilent", url: place.url, kind: .externalDisk)
        let again = LocalFileSystem.readPlaces(previous: [known], probes, asking: Locked([]))
        #expect(again.first { $0.url.path == image.systemPath }?.name == "AFMSilent")
    }

    /// A volume that goes while it is asked is listed by its folder name.
    @Test
    internal func aVolumeThatGoesWhileItIsAskedIsListedByItsFolderName() throws {
        let box = try Sandbox()
        guard let image = CoverageCoreDiskImage(in: box, name: "AFMGone", browsable: true) else {
            // Fails rather than skips: a skip would leave what the test covers to chance.
            Issue.record("a disk image cannot be attached here (hdiutil)")
            return
        }
        var probes = LocalProbes()
        probes.willAsk = { path in if path == image.systemPath { image.detach() } }
        let places = LocalFileSystem.readPlaces(previous: [], probes, asking: Locked([]))
        let place = try #require(places.first { $0.url.path == image.systemPath })
        #expect(place.name == "AFMGone-mount" && place.kind == .externalDisk)
    }

    /// Readings that take too long are given up and no more than two are left.
    @Test
    internal func readingsThatTakeTooLongAreGivenUpAndNoMoreThanTwoAreLeft() throws {
        let box = try Sandbox()
        guard let image = CoverageCoreDiskImage(in: box, name: "AFMLate", browsable: true) else {
            // Fails rather than skips: a skip would leave what the test covers to chance.
            Issue.record("a disk image cannot be attached here (hdiutil)")
            return
        }
        let (root, late) = (CoverageCoreGate(), CoverageCoreGate())
        let blocksImage = Shared(false)
        let (answered, asked) = (Signal<Bool>(), Signal<Bool>())
        defer {
            root.open()
            late.open()
        }
        var probes = LocalProbes()
        probes.willAsk = { path in
            if path == "/" { root.pass() }
            guard path == image.systemPath else {
                return
            }
            guard blocksImage.value else {
                return answered.set(true)
            }
            asked.set(true)
            late.pass()
        }
        probes.placesPatience = 2
        probes.volumePatience = 60
        // The first reading waits for the start-up disk. Asked again meanwhile, the list is read once more
        // when the first is given up; that reading waits for the disk image.
        let local = LocalFileSystem(probes: probes)
        #expect(answered.wait() == true)
        blocksImage.value = true
        local.refreshPlaces()
        #expect(asked.wait() == true)
        #expect(Wait.until { local.abandonedReadings == 2 })
        // Two readings are stuck: no third is begun.
        local.refreshPlaces()
        #expect(local.abandonedReadings == 2)
        root.open()
        late.open()
        #expect(Wait.until { local.abandonedReadings == 0 })
    }
}

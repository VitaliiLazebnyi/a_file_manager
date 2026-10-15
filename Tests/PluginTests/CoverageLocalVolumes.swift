import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// What a volume is said to be when it does not answer, and its free space when the system's figures are odd.
@Suite
internal struct CoverageLocalVolumes {
    /// A volume that does not answer is named after its mount point.
    @Test
    internal func aVolumeThatDoesNotAnswerIsNamedAfterItsMountPoint() throws {
        let box = try Sandbox()
        let gate = CoverageCoreGate()
        defer { gate.open() }
        var probes = LocalProbes()
        probes.willAsk = { path in if path.hasPrefix(box.root.path) { gate.pass() } }
        probes.volumePatience = 0.2
        let local = LocalFileSystem(probes: probes)
        let mount = MountTable.shared.mount(containing: box.root.path)
        let info = try #require(local.volume(of: box.url("a.txt")))
        #expect(info.name == URL(fileURLWithPath: mount.path).lastPathComponent)
        #expect(info.isLocal)
    }

    /// A volume that cannot be asked has no figures.
    @Test
    internal func aVolumeThatCannotBeAskedHasNoFigures() throws {
        let box = try Sandbox()
        let local = CoverageLocalProbes.failing("statfs", endingIn: box.root.lastPathComponent, EIO)
        #expect(local.volume(of: box.root) == nil)
    }

    /// A free space for important uses of nothing is the free space.
    @Test
    internal func aFreeSpaceForImportantUsesOfNothingIsTheFreeSpace() throws {
        let box = try Sandbox()
        #expect(CoverageLocalProbes.spaced { _ in (100, 0) }.volume(of: box.root)?.freeBytes == 100)
        #expect(CoverageLocalProbes.spaced { _ in (nil, 500) }.volume(of: box.root)?.freeBytes == 500)
    }

    /// What was measured of another volume or does not add up is not used.
    @Test
    internal func whatWasMeasuredOfAnotherVolumeOrDoesNotAddUpIsNotUsed() throws {
        let box = try Sandbox()
        let (mount, volume) = CoverageLocalProbes.mount(of: box.root)
        let now = DispatchTime.now().uptimeNanoseconds
        let other = CoverageLocalProbes.spaced { _ in (100, 300) }
        other.spareLock.withLock { other.spareSpace[mount] = (7, now, false, fsid_t(val: (1, 2))) }
        #expect(other.volume(of: box.root)?.freeBytes == 300)
        let negative = CoverageLocalProbes.spaced { _ in (100, 300) }
        negative.spareLock.withLock { negative.spareSpace[mount] = (-1_000, now, false, volume) }
        #expect(negative.volume(of: box.root)?.freeBytes == 100)
    }

    /// A measurement taken again forgets what the system no longer says.
    @Test
    internal func aMeasurementTakenAgainForgetsWhatTheSystemNoLongerSays() throws {
        let box = try Sandbox()
        let old = DispatchTime.now().uptimeNanoseconds &- 4_000_000_000
        // What the system says, one answer per question; the last one stays.
        let answers = Shared<[(available: Int64?, important: Int64?)]>([(100, 150), (100, 0)])
        let figures: @Sendable (String) -> (available: Int64?, important: Int64?) = { _ in
            var answer: (available: Int64?, important: Int64?) = (nil, nil)
            answers.modify { queue in
                answer = queue[0]
                if queue.count > 1 { queue.removeFirst() }
            }
            return answer
        }
        let (mount, volume) = CoverageLocalProbes.mount(of: box.root)
        let local = CoverageLocalProbes.spaced(figures)
        local.spareLock.withLock { local.spareSpace[mount] = (50, old, false, volume) }
        let free = local.volume(of: box.root)?.freeBytes
        // The old difference, and behind the scenes a new measurement: nothing important is free any more.
        #expect(free == 150)
        #expect(Wait.until(seconds: 60) { local.spareLock.withLock { local.spareSpace[mount]?.isMeasuring == false } })
        #expect(local.spareLock.withLock { local.spareSpace[mount]?.bytes } == nil)
        // And when the plain figure is gone too, the measurement is forgotten.
        answers.value = [(100, 0), (nil, 0)]
        local.spareLock.withLock { local.spareSpace[mount]?.measured = old }
        _ = local.volume(of: box.root)
        #expect(Wait.until(seconds: 60) { local.spareLock.withLock { local.spareSpace[mount] == nil } })
    }
}
